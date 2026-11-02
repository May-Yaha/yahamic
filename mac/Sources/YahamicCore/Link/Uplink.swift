import CryptoKit
import Darwin
import Dispatch
import Foundation
import YahamicProtocol

// 设备侧到 Mac 的上行链路:一个 UDP 端口 + Bonjour 广播(_yahamic._tcp,
// 设备用 mDNS 找到这里),处理 v2 握手(hello → welcome → auth)、加密音频入抖动
// 缓冲、静音同步与保活。协议与固件 firmware/main/protocol.cpp / uplink.cpp 一一对应。
// 所有可变状态只在 queue 上读写;对外属性的 setter 也经 queue.sync 落地,
// 所以不要在 onState/onLog 回调里同步设置这些属性(会死锁)。
public final class Uplink {
    /// 给界面用的链路快照(onState 在内部串行队列上回调,界面侧自行切主线程)。
    public struct State: Equatable {
        public var connected = false
        public var deviceName = ""
        public var address = ""
        public var muted = false
        public var levelDb: Double = -120
        public var framesPerSecond = 0
        public var bufferMs: Double = 0
        public var overflows = 0
        /// 断供事件数:流活跃且已开播时缓冲耗尽,每段持续断供计 1 次(口径见 AudioSink)。
        public var underruns = 0
        /// 累计丢帧/跳帧数(接收侧本地统计):迟到、重复的包直接丢弃,
        /// 跳号(丢包)按缺口计入(xiaozhi 做法:不补静音),口径见 handleSealed。
        public var droppedFrames = 0
        /// 采集链路分阶段诊断计数(单调累计,详见 Diag)。
        public var diag = Diag()
        public init() {}
    }

    /// 分阶段诊断计数:看计数停在哪一级,断点就在哪一级:
    ///   rxPackets 不涨        → 网络/端口层(包根本没到)
    ///   rxIgnoredInactive 涨  → 源地址与活跃会话不匹配
    ///   rxBadTag 涨           → 解密失败(配对码不一致、伪造或篡改)
    ///   audioPackets 涨、decodedFrames 不涨 → 序号丢弃(drop* 同步涨)或解码失败
    ///   enqueuedFrames 涨、outputFrames 不涨 → 渲染侧断点(AudioSink 未消费)
    /// 序号按设备→Mac 方向的全部加密包统一判定(SeqTracker):dropLate=迟到乱序/重放、
    /// dropDuplicate=同号重发、dropJump=跳号(多为网络丢包,按缺口计)、
    /// dropReset=大跳变后以新序号为基线(包已接受,只计次数)。
    public struct Diag: Equatable {
        public var rxPackets = 0          // 收包:协议解析成功
        public var rxInvalid = 0          // 收包:解析失败(非本协议版本或截断)
        public var rxIgnoredInactive = 0  // 来自非活跃地址的加密包被丢弃
        public var rxBadTag = 0           // 加密包验签失败
        public var audioPackets = 0       // 活跃设备音频包(通过验签与序号判定)
        public var decodeErrors = 0       // 解码失败/解码器缺失/空负载
        public var decodedFrames = 0      // Opus 解码成功
        public var enqueuedFrames = 0     // 入队抖动缓冲
        public var outputFrames = 0       // 输出:渲染侧实际消费的 60ms 帧(emit 时填入)
        public var dropLate = 0
        public var dropDuplicate = 0
        public var dropJump = 0
        public var dropReset = 0
        public var rehandshakes = 0       // 同地址重新握手(设备疑似重启)
        public init() {}
    }

    // MARK: 对外属性(读写都经 queue)

    public var onState: ((State) -> Void)? {
        get { queue.sync { stateHandler } }
        set { queue.sync { stateHandler = newValue } }
    }
    public var onLog: ((String) -> Void)? {
        get { queue.sync { logHandler } }
        set { queue.sync { logHandler = newValue } }
    }
    /// 音频流抽头(诊断/录制用):每帧回调解码后的 16 kHz 单声道 S16LE PCM。
    /// 复用主链路的解码结果,不扰动播放时序;在内部串行队列上回调。
    public var onAudioTap: ((Data) -> Void)? {
        get { queue.sync { tapHandler } }
        set { queue.sync { tapHandler = newValue } }
    }
    /// 音频出口(可选):只用来同步「流活跃」标记,让断供计数只在真实送声期间累计。
    public var audioSink: AudioSink? {
        get { queue.sync { sink } }
        set { queue.sync { sink = newValue } }
    }
    /// 界面可随时切换:影响设备上线时先静音还是先开麦。
    public var pushToTalk: Bool {
        get { queue.sync { ptt } }
        set { queue.sync { ptt = newValue } }
    }

    private var stateHandler: ((State) -> Void)?
    private var logHandler: ((String) -> Void)?
    private var tapHandler: ((Data) -> Void)?
    private weak var sink: AudioSink?
    private var ptt: Bool

    private let port: UInt16
    private let masterKey: SymmetricKey
    private let jitter: JitterBuffer
    private let verbose: Bool
    private let hostName: String
    private let queue = DispatchQueue(label: "yahamic.uplink")
    private let startedAt = Date()

    private var transport: UdpTransport?
    private var bonjour: Bonjour?
    private var keepAliveTimer: DispatchSourceTimer?
    private var opus: OpusFrameDecoder?

    /// 已回 welcome、等 auth 的握手(按源地址)。hello 是明文,不能碰活跃会话。
    private struct Pending {
        let address: sockaddr_in
        let name: String
        let dn: Data
        let mn: Data
        let since: Date
    }
    private var pending: [String: Pending] = [:]
    private static let maxPending = 8

    private var activeAddr: sockaddr_in?
    private var activeKey = ""
    private var activeName = ""
    private var session: SessionCrypto.Session?
    private var rxSeq = SeqTracker()
    private var outSeq: UInt32 = 0
    private var lastHeard = Date.distantPast
    private var muted = true            // 设备上报的静音状态(设备开机/断链都是静音)
    private var muteCommand: (gen: UInt32, muted: Bool)?  // 最新静音指令(代号单调递增)

    private var frames = 0
    private var droppedFrames = 0
    private var diag = Diag()
    private var lastDiagSample = Diag()
    private var lastAnomalyLogAt = Date.distantPast
    private var lastStatusAt = Date()
    private var lastStatusFrames = 0
    private var levelDb = -120.0
    private var fps = 0

    /// code:配对码(≥8 位,与设备配网页一致),由调用方校验长度。
    public init(port: UInt16 = 7717, code: String, jitter: JitterBuffer, verbose: Bool,
                pushToTalk: Bool = true) {
        self.port = port
        self.masterKey = SessionCrypto.masterKey(code: code)
        self.jitter = jitter
        self.verbose = verbose
        self.ptt = pushToTalk
        self.hostName = Host.current().localizedName ?? "Mac"
    }
    public func start() {
        queue.sync {
            do {
                transport = try UdpTransport(port: port, queue: queue) { [weak self] data, from in
                    self?.handle(data, from: from)
                }
            } catch {
                log("无法监听端口 \(port)(\(error.localizedDescription))")
                return
            }
            let instance = "yahamic-" + String(format: "%04x", UInt32.random(in: 0..<0x10000))
            let serviceType = "_yahamic._tcp"
            let servicePort = port
            bonjour = Bonjour(name: instance, type: serviceType, port: servicePort, queue: queue) {
                [weak self] registered in
                guard let self else { return }
                self.log("Bonjour 已注册:\(registered)(\(serviceType):\(servicePort))")
                self.emit()
            }
            if bonjour == nil { log("⚠️ Bonjour 注册失败:设备将无法自动发现这台 Mac") }
            opus = OpusFrameDecoder()
            if opus == nil { log("⚠️ Opus 解码器创建失败") }
            log("就绪:UDP 端口 \(port),协议 v\(Wire.version)(配对码鉴权 + 加密)")
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            keepAliveTimer = timer
            emit()
        }
    }

    /// 遥控设备静音:Fn 松开/按下,或界面上的开关。指令带代号 cmd,keepalive 每 0.5s
    /// 重复带上最新指令(丢包自愈);设备只在代号变化时执行,所以不会覆盖设备按键的本地切换。
    public func sendControl(muted: Bool) {
        queue.async { [weak self] in self?.issueMute(muted) }
    }

    /// 请求设备回传一帧屏幕(排障/查看 UI;截图经日志口,由串口侧收集)。
    public func sendDump() {
        queue.async { [weak self] in
            self?.sendSealed(Wire.control, payload: Data("dump 1\n".utf8))
        }
    }

    /// 仪表盘数据下发(type 7):载荷 10 字节小端 epoch(u32,UTC 秒)+ 时区偏移
    /// (i16,分钟)+ cpu/mem/鼠标电量/键盘电量(各 u8,无效 255),与固件
    /// DashboardPayload 逐一对应。未上线时直接丢弃。
    public func sendDashboard(_ snapshot: MetricsSnapshot) {
        queue.async { [weak self] in
            var payload = Data()
            withUnsafeBytes(of: UInt32(truncatingIfNeeded: Int64(Date().timeIntervalSince1970)).littleEndian) {
                payload.append(contentsOf: $0)
            }
            withUnsafeBytes(of: Int16(clamping: TimeZone.current.secondsFromGMT() / 60).littleEndian) {
                payload.append(contentsOf: $0)
            }
            payload.append(contentsOf: [snapshot.cpuPercent, snapshot.memoryPercent,
                                        snapshot.mouseBattery, snapshot.keyboardBattery])
            self?.sendSealed(Wire.dashboard, payload: payload)
        }
    }

    /// 关闭端口与广播(改设置后重建链路用);设备会在几秒内自己重新握手。
    public func stop() {
        queue.sync {
            keepAliveTimer?.cancel()
            keepAliveTimer = nil
            bonjour = nil
            transport = nil
            pending.removeAll()
            clearActive()
            sink?.endStream()
        }
    }

    // MARK: - 保活与状态

    private func tick() {
        pending = pending.filter { Date().timeIntervalSince($0.value.since) < 10 }
        guard activeAddr != nil else { return }
        if Date().timeIntervalSince(lastHeard) > 10 {
            dropActive("失联超过 10 秒")
            return
        }
        sendSealed(Wire.keepalive, payload: commandPayload())
        updateMetrics()
    }
    private func updateMetrics() {
        let now = Date()
        let seconds = now.timeIntervalSince(lastStatusAt)
        guard seconds >= 0.9 else { return }
        fps = Int(Double(frames - lastStatusFrames) / seconds)
        lastStatusAt = now
        lastStatusFrames = frames
        logDiagAnomaliesIfNeeded()
        lastDiagSample = diag
        if verbose {
            let stats = jitter.stats()
            log(String(
                format: "%@ │ %5.1f dB │ 缓冲 %3.0f ms │ %d 帧/s │ 溢 %d 欠 %d 丢 %d(迟%d 重%d 跳%d 置%d)",
                muted ? "静音" : "送声", levelDb, Double(jitter.count) / 16.0, fps,
                stats.overflows, stats.underruns, droppedFrames,
                diag.dropLate, diag.dropDuplicate, diag.dropJump, diag.dropReset))
        }
        emit()
    }

    /// 异常路径的节流聚合日志:正常播放完全不打印;出现异常时最多每 10 秒一行,
    /// 凭收包/验签/解码/入队/输出增量区分「收不到包」与「验签/解码/序号丢弃」。
    private func logDiagAnomaliesIfNeeded() {
        let prev = lastDiagSample
        let audioDelta = diag.audioPackets - prev.audioPackets
        let decodeErrDelta = diag.decodeErrors - prev.decodeErrors
        let badTagDelta = diag.rxBadTag - prev.rxBadTag
        // 跳号偶发是正常网络丢包,持续大量才报;其余类别出现即报。
        let abnormal = diag.dropLate > prev.dropLate || diag.dropDuplicate > prev.dropDuplicate
            || diag.dropReset > prev.dropReset || decodeErrDelta > 0 || badTagDelta > 0
            || diag.dropJump - prev.dropJump > 8
        // 未静音却整秒没有音频包:包没到这个进程(网络/源地址/设备侧断流)。
        let starving = !muted && audioDelta == 0
        guard abnormal || starving else { return }
        guard Date().timeIntervalSince(lastAnomalyLogAt) >= 10 else { return }
        lastAnomalyLogAt = Date()
        log(String(
            format: "诊断(%@) │ 收包 Δ%d(无效 Δ%d 非活跃 Δ%d 验签失败 Δ%d)│ 音频包 Δ%d │ 解码 Δ%d(失败 Δ%d)│ 入队 Δ%d │ 输出 %d 帧 │ 序号累计 迟%d 重%d 跳%d 置%d",
            abnormal ? "丢帧" : "断流",
            diag.rxPackets - prev.rxPackets, diag.rxInvalid - prev.rxInvalid,
            diag.rxIgnoredInactive - prev.rxIgnoredInactive, badTagDelta,
            audioDelta, diag.decodedFrames - prev.decodedFrames, decodeErrDelta,
            diag.enqueuedFrames - prev.enqueuedFrames,
            sink?.outputFrameCount ?? 0,
            diag.dropLate, diag.dropDuplicate, diag.dropJump, diag.dropReset))
    }

    private func emit() {
        guard let stateHandler else { return }
        var s = State()
        s.connected = activeAddr != nil
        s.deviceName = activeName
        s.address = activeKey
        s.muted = muted
        s.levelDb = levelDb
        s.framesPerSecond = fps
        s.bufferMs = Double(jitter.count) / 16.0
        let stats = jitter.stats()
        s.overflows = stats.overflows
        s.underruns = stats.underruns
        s.droppedFrames = droppedFrames
        var d = diag
        d.outputFrames = sink?.outputFrameCount ?? 0  // 渲染侧回报,不进 self.diag
        s.diag = d
        stateHandler(s)
    }

    // MARK: - 报文

    private func handle(_ data: Data, from address: sockaddr_in) {
        guard let packet = Wire.parse(data) else {
            diag.rxInvalid += 1
            return
        }
        diag.rxPackets += 1
        let key = addressKey(address)
        if packet.type == Wire.hello {
            handleHello(packet, from: address, key: key)
        } else if packet.type == Wire.auth {
            handleAuth(packet, key: key)
        } else if Wire.isSealed(packet.type) {
            // 上线后的包必须来自活跃地址且验签通过;明文/伪造包一律丢弃。
            guard key == activeKey, let session else {
                diag.rxIgnoredInactive += 1
                return
            }
            guard let plain = session.open(header: packet.header, seq: packet.seq, sealed: packet.payload)
            else {
                diag.rxBadTag += 1
                return
            }
            handleSealed(packet, plain)
        }
    }
    /// hello 是明文,任何人都能发:这里只回 welcome(带 Mac 随机数 mn 和证明),
    /// 不碰活跃会话;会话切换只在 auth 验证通过后发生。
    private func handleHello(_ packet: Wire.Packet, from address: sockaddr_in, key: String) {
        let f = Fields.parse(packet.payload)
        let name = f["name"] ?? "yahamic"
        // 这里不能刷新 lastHeard:换端口重连的设备每个 hello 都会给"旧会话"续命。
        guard let dn = f["dn"].flatMap(Data.init(hex:)), dn.count == SessionCrypto.nonceSize else {
            return
        }
        if f["rate"] != "16000" || f["ch"] != "1" || f["bits"] != "16" || f["frame"] != "60" || f["codec"] != "opus" {
            replyRefused(address, dn: dn, reason: "unsupported audio params")
            log("拒绝 \(name):音频参数不受支持(\(f["rate"] ?? "?") Hz)")
            return
        }
        if anotherDeviceActive(name: name, key: key) {
            replyRefused(address, dn: dn, reason: "another device is active")
            log("忽略 \(name):当前 \(activeName) 还在线")
            return
        }
        // 设备一次握手内重复发 hello(同一个 dn):回同一个 mn,保证 welcome 幂等。
        let mn: Data
        if let p = pending[key], p.dn == dn {
            mn = p.mn
        } else {
            if pending[key] == nil, pending.count >= Self.maxPending,
               let oldest = pending.min(by: { $0.value.since < $1.value.since })?.key {
                pending[oldest] = nil
            }
            mn = SessionCrypto.randomNonce()
            pending[key] = Pending(address: address, name: name, dn: dn, mn: mn, since: Date())
        }
        let proof = SessionCrypto.mac(masterKey, "m", dn: dn, mn: mn)
        send(Wire.build(type: Wire.welcome, seq: 0, ts: nowTs(), payload: Fields.build([
            ("ok", "1"), ("host", hostName), ("dn", dn.hex), ("mn", mn.hex), ("proof", proof.hex),
        ])), to: address)
    }

    /// 设备证明它也知道配对码:验证通过才建立加密会话。
    private func handleAuth(_ packet: Wire.Packet, key: String) {
        guard let p = pending[key] else { return }  // 已上线后的重发或无主 auth:忽略
        pending[key] = nil
        guard let proof = Fields.parse(packet.payload)["proof"].flatMap(Data.init(hex:)),
              SessionCrypto.verify(masterKey, "d", dn: p.dn, mn: p.mn, proof: proof)
        else {
            replyRefused(p.address, dn: p.dn, reason: "bad pairing code")
            log("拒绝 \(p.name):配对码不匹配(检查设备配网页与 App 里的配对码)")
            return
        }
        if anotherDeviceActive(name: p.name, key: key) {
            replyRefused(p.address, dn: p.dn, reason: "another device is active")
            return
        }
        let previousKey = activeKey
        let sameDevice = !activeName.isEmpty && p.name == activeName
        if key == activeKey { diag.rehandshakes += 1 }
        activeAddr = p.address
        activeKey = key
        activeName = p.name
        // 新会话:密钥、两个方向的序号、抖动缓冲与渲染会话全部重来。
        session = SessionCrypto.Session(macSideWith: masterKey, dn: p.dn, mn: p.mn)
        rxSeq.reset()
        outSeq = 0
        jitter.clear()
        sink?.resetSession()
        muted = true  // 设备上线默认静音,随后的 status 会报真实状态
        frames = 0
        lastHeard = Date()
        lastAnomalyLogAt = Date()  // 握手后 10s 宽限:等静音同步与首帧,避免误报断流
        if sameDevice {
            log("🔄 \(p.name) 重连:\(previousKey) → \(key),会话密钥、序号与缓冲已重置")
        } else {
            log("🎤 \(p.name) 上线(\(key),已加密)")
            if ptt { log("按住 Fn 键讲话,松开静音") }
        }
        // 上线即同步模式:push-to-talk 先静音,常开模式开麦。这个包也让设备确认会话已建立。
        issueMute(ptt)
        emit()
    }

    /// 另一台(名字不同的)设备正在线且 10 秒内有包:不让新设备抢占。
    /// 同名 = 同一台换了端口/重启后重连,允许接管。
    private func anotherDeviceActive(name: String, key: String) -> Bool {
        !activeKey.isEmpty && key != activeKey && name != activeName
            && Date().timeIntervalSince(lastHeard) < 10
    }

    /// 拒绝包明文,回显设备的 dn:设备只认握手中、dn 对得上的拒绝。
    private func replyRefused(_ address: sockaddr_in, dn: Data, reason: String) {
        send(Wire.build(type: Wire.welcome, seq: 0, ts: nowTs(), payload: Fields.build([
            ("ok", "0"), ("err", reason), ("dn", dn.hex),
        ])), to: address)
    }
    /// 已验签的设备包:先过序号(去重/丢迟到/防重放),再按类型处理。
    private func handleSealed(_ packet: Wire.Packet, _ plain: Data) {
        let isAudio = packet.type == Wire.audio
        switch rxSeq.classify(packet.seq) {
        case .duplicate:
            diag.dropDuplicate += 1
            if isAudio { droppedFrames += 1 }
            return
        case .late:
            diag.dropLate += 1
            if isAudio { droppedFrames += 1 }
            return
        case .rebase:
            diag.dropReset += 1
        case .accept(let gap):
            diag.dropJump += gap
            droppedFrames += gap
        }
        lastHeard = Date()
        if isAudio {
            // 静音后到达的尾部音频仍需解码播放以保留话尾,但不能把渲染会话重新置为送声;
            // 只有设备的 status muted 0 才取消静音。
            if !muted { sink?.beginStream() }
            ingestAudio(plain)
        } else if packet.type == Wire.status {
            let nowMuted = packet.flags & 1 == 1 || Fields.parse(plain)["muted"] == "1"
            guard nowMuted != muted else { return }
            muted = nowMuted
            if muted {
                sink?.endStream()  // 静默期:回调空转不再计断供
                // 不清缓冲:Fn 松开的瞬间里面还有这句话的尾巴(~130ms),扔掉会让
                // 听写引擎丢失句尾、把已识别内容重复一遍。让它自然播空。
                log("🔇 \(activeName) 已静音(设备侧采集关闭)")
            } else {
                log("🎙 \(activeName) 取消静音")
            }
            emit()
        }
    }

    private func ingestAudio(_ payload: Data) {
        diag.audioPackets += 1
        guard payload.count > 0, let opus else {
            diag.decodeErrors += 1
            return
        }
        frames += 1
        var pcm = [Int16](repeating: 0, count: OpusFrameDecoder.maxSamples)
        let n = opus.decode(payload, into: &pcm)
        guard n > 0 else {
            diag.decodeErrors += 1
            return
        }
        diag.decodedFrames += 1
        var sumSq: Double = 0
        pcm[0..<n].withUnsafeBufferPointer { buf in
            // 诊断抽头:解码后的 16 kHz 单声道 S16LE PCM(Int16 本机序即小端)。
            tapHandler?(Data(UnsafeRawBufferPointer(buf)))
            for s in buf {
                let v = Double(s)
                sumSq += v * v
            }
            jitter.push(buf)
        }
        diag.enqueuedFrames += 1
        let rms = (sumSq / Double(n)).squareRoot()
        levelDb = 20 * log10(max(rms / 32768, 1e-6))
    }

    // MARK: - 发送

    private func issueMute(_ on: Bool) {
        muteCommand = (muteCommand.map { $0.gen &+ 1 } ?? 1, on)
        sendSealed(Wire.control, flags: on ? 1 : 0, payload: commandPayload())
    }

    /// 最新静音指令("muted X\ncmd N\n"),control 与每个 keepalive 都带。
    private func commandPayload() -> Data {
        guard let muteCommand else { return Data() }
        return Fields.build([("muted", muteCommand.muted ? "1" : "0"), ("cmd", String(muteCommand.gen))])
    }

    /// 加密发送(仅上线后):每包新序号,nonce 由序号派生,同一会话密钥下绝不重复。
    private func sendSealed(_ type: UInt8, flags: UInt8 = 0, payload: Data) {
        guard let address = activeAddr, let session else { return }
        outSeq &+= 1
        let header = Wire.header(type: type, flags: flags, seq: outSeq, ts: nowTs())
        send(header + session.seal(header: header, seq: outSeq, plaintext: payload), to: address)
    }

    private func send(_ data: Data, to address: sockaddr_in) {
        transport?.send(data, to: address)
    }

    private func nowTs() -> UInt32 {
        UInt32(truncatingIfNeeded: Int64(Date().timeIntervalSince(startedAt) * 1000))
    }

    // MARK: - 杂项

    private func clearActive() {
        activeAddr = nil
        activeKey = ""
        activeName = ""
        session = nil
        rxSeq.reset()
    }

    private func dropActive(_ reason: String) {
        guard activeAddr != nil else { return }
        log("设备下线:\(reason)")
        clearActive()
        jitter.clear()
        sink?.endStream()
        fps = 0
        emit()
    }

    private func log(_ message: String) {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(time)] \(message)"
        if let logHandler {
            logHandler(line)
        } else {
            print(line)
            fflush(stdout)
        }
    }
}
