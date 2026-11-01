// libopus C API 直接绑定(brew install opus;/opt/homebrew/lib/libopus.dylib)。
// SwiftPM 的 systemLibrary 在 macOS + Homebrew 下找不到头文件,直接声明符号。
@_silgen_name("opus_decoder_create")
private func c_opus_decoder_create(_ Fs: Int32, _ channels: Int32,
                                   _ error: UnsafeMutablePointer<Int32>?) -> OpaquePointer?
@_silgen_name("opus_decode")
private func c_opus_decode(_ st: OpaquePointer?, _ data: UnsafePointer<UInt8>?,
                           _ len: Int32, _ pcm: UnsafeMutablePointer<Int16>,
                           _ frame_size: Int32, _ decode_fec: Int32) -> Int32
@_silgen_name("opus_decoder_destroy")
private func c_opus_decoder_destroy(_ st: OpaquePointer?)

import CryptoKit
import Darwin
import dnssd
import Dispatch
import Foundation

// —— 传输层:BSD socket UDP ——
// 不用 NWListener/NWConnection:多次重启 daemon 后,NW 的 UDP 会话在系统层
// 出现粘滞,新实例收不到设备的重连包;BSD socket + DispatchSource 行为可预期,
// Bonjour 另走 dnssd 注册。
final class UdpTransport {
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue: DispatchQueue
    private let onPacket: (Data, sockaddr_in) -> Void

    init(port: UInt16, queue: DispatchQueue,
         onPacket: @escaping (Data, sockaddr_in) -> Void) throws {
        self.queue = queue
        self.onPacket = onPacket
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw NSError(domain: "udp", code: Int(errno)) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var any = sockaddr_in()
        any.sin_family = sa_family_t(AF_INET)
        any.sin_port = port.bigEndian
        any.sin_addr = in_addr(s_addr: in_addr_t(0))  // INADDR_ANY
        let bound = withUnsafePointer(to: &any) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = Int(errno)
            close(fd)
            fd = -1
            throw NSError(domain: "udp-bind", code: code)
        }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.drain() }
        src.resume()
        source = src
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 2048)
        var from = sockaddr_in()
        var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = buffer.withUnsafeMutableBytes { raw -> Int in
            withUnsafeMutablePointer(to: &from) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, raw.baseAddress, 2048, 0, $0, &fromLen)
                }
            }
        }
        guard got > 0 else { return }
        onPacket(Data(buffer[0..<got]), from)
    }

    func send(_ data: Data, to address: sockaddr_in) {
        data.withUnsafeBytes { raw in
            withUnsafePointer(to: address) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(fd, raw.baseAddress, raw.count, 0, $0,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    deinit {
        source?.cancel()
        if fd >= 0 { close(fd) }
    }
}

func addressKey(_ a: sockaddr_in) -> String {
    let bytes = withUnsafeBytes(of: a.sin_addr.s_addr) { Array($0) }
    return "\(bytes[0]).\(bytes[1]).\(bytes[2]).\(bytes[3]):\(UInt16(bigEndian: a.sin_port))"
}

// Bonjour 注册(_yahamic._tcp),dnssd C API:进程多次非正常退出后
// NWListener.service 会静默失效;这里行为明确,且成功时有回调确认。
final class Bonjour {
    final class Box {
        let handler: (String) -> Void
        init(_ handler: @escaping (String) -> Void) { self.handler = handler }
    }

    private var ref: DNSServiceRef?
    private var box: Box
    private let queue: DispatchQueue

    init?(name: String, type: String, port: UInt16, queue: DispatchQueue,
          onRegistered: @escaping (String) -> Void) {
        self.queue = queue
        let handler = Box(onRegistered)
        self.box = handler
        var dnsRef: DNSServiceRef?
        let status = DNSServiceRegister(
            &dnsRef, 0, UInt32(kDNSServiceInterfaceIndexAny),
            name, type, "local.", nil,
            port.bigEndian, 0, nil,
            { _, _, errorCode, registered, _, _, context in
                guard let context else { return }
                let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
                if errorCode == kDNSServiceErr_NoError, let registered {
                    box.handler(String(cString: registered))
                } else if errorCode != kDNSServiceErr_NoError {
                    print("Bonjour 注册错误:\(errorCode)")
                }
            },
            Unmanaged.passUnretained(handler).toOpaque()
        )
        guard status == kDNSServiceErr_NoError, let dnsRef else { return nil }
        ref = dnsRef
        DNSServiceSetDispatchQueue(dnsRef, queue)
    }

    deinit {
        if let ref { DNSServiceRefDeallocate(ref) }
    }
}

// 设备侧到 Mac 的上行链路:一个 UDP 端口 + Bonjour 广播(_yahamic._tcp,
// 设备用 mDNS 找到这里),处理 hello/welcome 握手、音频入抖动缓冲、
// 静音状态与保活。协议与固件 firmware/main/uplink.cpp 一一对应。
// 状态通过 onState 回调给界面(菜单栏 App)或日志(命令行)。
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
        /// 累计丢帧/跳帧数(接收侧本地统计,非设备遥测透传):乱序或过旧的帧直接
        /// 丢弃、正常跳号(丢包)按缺口计入(xiaozhi 做法:不补静音),口径见 ingestAudio。
        public var droppedFrames = 0
        /// 采集链路分阶段诊断计数(单调累计,详见 Diag)。
        public var diag = Diag()
        public init() {}
    }

    /// 分阶段诊断计数:定位「设备串口 live 且持续采集,但 App 侧 fps=0、
    /// capture samples=0」——看计数停在哪一级,断点就在哪一级:
    ///   rxPackets 不涨        → 网络/端口层(包根本没到)
    ///   rxIgnoredInactive 涨  → 源地址与活跃会话不匹配(被 guard fromActive 丢弃)
    ///   audioPackets 涨、decodedFrames 不涨 → 序号丢弃(下方 drop* 分类同步涨)
    ///                          或解码失败(decodeErrors 同步涨)
    ///   enqueuedFrames 涨、outputFrames 不涨 → 渲染侧断点(AudioSink 未消费)
    /// 序号异常丢帧按四类归因:dropLate=迟到乱序、dropDuplicate=同号重发、
    /// dropJump=跳号(多为网络丢包,按缺口计)、dropReset=序号大跳变/回绕
    /// (疑似设备重启但未重新握手)。
    /// 注意:这些计数用于定位与验证,不代表真机零帧问题已修复。
    public struct Diag: Equatable {
        public var rxPackets = 0          // 收包:协议解析成功
        public var rxInvalid = 0          // 收包:解析失败(非本协议或截断)
        public var rxIgnoredInactive = 0  // 来自非活跃地址被静默丢弃(audio/status)
        public var audioPackets = 0       // 活跃设备音频包(进入 ingestAudio)
        public var decodeErrors = 0       // 解码失败/解码器缺失/空负载
        public var decodedFrames = 0      // Opus 解码成功
        public var enqueuedFrames = 0     // 入队抖动缓冲
        public var outputFrames = 0       // 输出:渲染侧实际消费的 60ms 帧(AudioSink 回报,emit 时填入)
        public var dropLate = 0           // 序号异常丢帧:迟到(乱序旧帧,直接丢弃)
        public var dropDuplicate = 0      // 重复(序号与上一帧相同,网络重发)
        public var dropJump = 0           // 跳变(正常跳号,按缺口计入;多为丢包)
        public var dropReset = 0          // 重置(序号大跳变/回绕,按单帧丢弃)
        public var rehandshakes = 0       // 同地址重新握手(设备疑似重启)触发流状态重置
        public init() {}
    }

    public var onState: ((State) -> Void)?
    public var onLog: ((String) -> Void)?
    /// 音频流抽头(诊断/录制用):每帧回调解码后的 16 kHz 单声道 S16LE PCM
    /// (Opus 解码结果,非网络原始包)。复用主链路的解码结果(不额外解码、
    /// 不扰动播放时序),capture 落盘即 WAV 数据区。
    /// 注意:在本类内部串行队列上回调。
    public var onAudioTap: ((Data) -> Void)?
    /// 音频出口(可选):只用来同步「流活跃」标记(internal 接口 beginStream/
    /// endStream),让断供计数只在真实送声期间累计。调用方创建后接线。
    public weak var audioSink: AudioSink?

    private let port: UInt16
    private let token: String?
    private let jitter: JitterBuffer
    private let verbose: Bool
    public var pushToTalk: Bool  // 界面可随时切换:影响下一次设备上线时是否先静音
    private let queue = DispatchQueue(label: "yahamic.uplink")

    private var transport: UdpTransport?
    private var bonjour: Bonjour?
    private var activeAddr: sockaddr_in?
    private var activeKey = ""
    private var activeName = ""
    private var lastHeard = Date.distantPast
    private var muted = false
    private var outSeq: UInt32 = 0
    private let startedAt = Date()

    private var lastSeq: UInt32?
    private var frames = 0
    private var droppedFrames = 0  // 乱序/过旧的帧直接丢弃(xiaozhi 做法:不补静音)
    private var diag = Diag()      // 分阶段诊断计数,只在本类串行队列上读写
    private var lastDiagSample = Diag()  // 上次状态行的诊断快照(算增量用)
    private var lastAnomalyLogAt = Date.distantPast  // 异常聚合日志节流(≥10s)
    private var opusDecoder: OpaquePointer?
    private var lastStatusAt = Date()
    private var lastStatusFrames = 0
    private var levelDb = -120.0
    private var fps = 0

    private var keepAliveTimer: DispatchSourceTimer?

    public init(port: UInt16 = 7717, token: String?, jitter: JitterBuffer, verbose: Bool,
                pushToTalk: Bool = true) {
        self.port = port
        self.token = token
        self.jitter = jitter
        self.verbose = verbose
        self.pushToTalk = pushToTalk
    }

    public func start() {
        do {
            let udp = try UdpTransport(port: port, queue: queue) { [weak self] data, from in
                self?.handle(data, from: from)
            }
            transport = udp
        } catch {
            log("无法监听端口 \(port)(\(error.localizedDescription))")
            return
        }
        let instance = "yahamic-" + String(format: "%04x", UInt32.random(in: 0..<0x10000))
        let serviceType = "_yahamic._tcp"
        let servicePort = port
        if let advertised = Bonjour(name: instance, type: serviceType, port: servicePort,
                                    queue: queue, onRegistered: { [weak self] registered in
            guard let self else { return }
            self.log("Bonjour 已注册:\(registered)(\(serviceType):\(servicePort))")
            self.emit()
        }) {
            bonjour = advertised
        } else {
            log("⚠️ Bonjour 注册失败:设备将无法自动发现这台 Mac")
        }
        // Opus 解码器(16 kHz 单声道,与固件端编码器匹配)。
        var opusError: Int32 = 0
        opusDecoder = c_opus_decoder_create(16000, 1, &opusError)
        if opusError != 0 {
            log("⚠️ Opus 解码器创建失败 (error \(opusError))")
            opusDecoder = nil
        }
        log("就绪:UDP 端口 \(port)" + (token != nil ? ",配对码校验开启" : ""))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        keepAliveTimer = timer
        emit()
    }

    /// 遥控设备静音(协议 type 6):Fn 松开/按下,或界面上的开关。
    public func sendControl(muted: Bool) {
        queue.async { [weak self] in
            guard let self, let address = self.activeAddr else { return }
            self.outSeq &+= 1
            self.send(Wire.build(type: Wire.control, flags: muted ? 1 : 0, seq: self.outSeq,
                                 ts: self.nowTs(),
                                 payload: Data((muted ? "muted 1\n" : "muted 0\n").utf8)),
                      to: address)
        }
    }

    /// 请求设备回传一帧屏幕(排障/查看 UI;截图经日志口,由串口侧收集)。
    public func sendDump() {
        queue.async { [weak self] in
            guard let self, let address = self.activeAddr else { return }
            self.outSeq &+= 1
            self.send(Wire.build(type: Wire.control, seq: self.outSeq, ts: self.nowTs(),
                                 payload: Data("dump 1\n".utf8)), to: address)
        }
    }

    /// 仪表盘数据下发(协议 type 7):设备空闲屏的大字时钟 + 2x2 仪表数据源。
    /// 载荷 10 字节小端:epoch(uint32,UTC 秒)+ 时区偏移(int16,分钟,
    /// TimeZone.current 现取,DST 变化随每包自动带上)+ cpu/mem/鼠标电量/键盘
    /// 电量各 uint8(无效 255)——字段顺序/宽度与固件端
    /// firmware/main/uplink.cpp 的 DashboardPayload 逐一对应。
    /// 内部投递到本类串行队列执行,所有 UDP 帧(keepalive/control/音频 ACK 之外
    /// 的下行帧)在同一队列串行化,多路并发调用不会造成 socket 帧交织;
    /// 握手未完成(activeAddr 为空)时直接丢弃,天然满足「仅握手后发送」。
    public func sendDashboard(_ snapshot: MetricsSnapshot) {
        queue.async { [weak self] in
            guard let self, let address = self.activeAddr else { return }
            var payload = Data()
            payload.reserveCapacity(10)
            var epoch = UInt32(Date().timeIntervalSince1970).littleEndian
            var tz = Int16(clamping: TimeZone.current.secondsFromGMT() / 60).littleEndian
            withUnsafeBytes(of: &epoch) { payload.append(contentsOf: $0) }
            withUnsafeBytes(of: &tz) { payload.append(contentsOf: $0) }
            payload.append(contentsOf: [snapshot.cpuPercent, snapshot.memoryPercent,
                                        snapshot.mouseBattery, snapshot.keyboardBattery])
            self.outSeq &+= 1
            self.send(Wire.build(type: Wire.dashboard, seq: self.outSeq,
                                 ts: self.nowTs(), payload: payload), to: address)
        }
    }

    /// 关闭端口与广播(改设置后重建链路用);设备会在几秒内自己重新握手。
    public func stop() {
        queue.sync {
            keepAliveTimer?.cancel()
            keepAliveTimer = nil
            bonjour = nil
            transport = nil
            activeAddr = nil
            activeKey = ""
            activeName = ""
            audioSink?.endStream()
        }
    }

    // MARK: - 保活与状态

    private func tick() {
        guard let address = activeAddr else { return }
        if Date().timeIntervalSince(lastHeard) > 10 {
            dropActive("失联超过 10 秒")
            return
        }
        outSeq &+= 1
        send(Wire.build(type: Wire.keepalive, seq: outSeq, ts: nowTs()), to: address)
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

    /// 异常路径的节流聚合日志:正常播放(无序号/解码异常且音频包持续到达)完全
    /// 不打印;出现异常时最多每 10 秒一行。行内同时给出收包/解码/入队/输出增量
    /// 与序号异常分类累计,凭它可区分「收不到包」(收包/音频包增量为 0)与
    /// 「解码/序号丢弃」(音频包在涨但解码/入队不涨,看 迟/重/跳/置/失败 哪项在涨)。
    /// 只在已连接时被调用(updateMetrics 由 tick 驱动)。
    private func logDiagAnomaliesIfNeeded() {
        let prev = lastDiagSample
        let rxDelta = diag.rxPackets - prev.rxPackets
        let audioDelta = diag.audioPackets - prev.audioPackets
        let decodedDelta = diag.decodedFrames - prev.decodedFrames
        let decodeErrDelta = diag.decodeErrors - prev.decodeErrors
        let lateDelta = diag.dropLate - prev.dropLate
        let dupDelta = diag.dropDuplicate - prev.dropDuplicate
        let jumpDelta = diag.dropJump - prev.dropJump
        let resetDelta = diag.dropReset - prev.dropReset
        // 跳号偶发是正常网络丢包,持续大量才报;其余类别出现即报。
        let abnormal = lateDelta > 0 || dupDelta > 0 || resetDelta > 0
            || decodeErrDelta > 0 || jumpDelta > 8
        // 未静音却整秒没有音频包:包没到这个进程(网络/源地址/设备侧断流)。
        let starving = !muted && audioDelta == 0
        guard abnormal || starving else { return }
        guard Date().timeIntervalSince(lastAnomalyLogAt) >= 10 else { return }
        lastAnomalyLogAt = Date()
        log(String(
            format: "诊断(%@) │ 收包 Δ%d(无效 Δ%d 非活跃 Δ%d)│ 音频包 Δ%d │ 解码 Δ%d(失败 Δ%d)│ 入队 Δ%d │ 输出 %d 帧 │ 序号丢累计 迟%d 重%d 跳%d 置%d",
            abnormal ? "丢帧" : "断流",
            rxDelta, diag.rxInvalid - prev.rxInvalid, diag.rxIgnoredInactive - prev.rxIgnoredInactive,
            audioDelta, decodedDelta, decodeErrDelta,
            diag.enqueuedFrames - prev.enqueuedFrames,
            audioSink?.outputFrameCount ?? 0,
            diag.dropLate, diag.dropDuplicate, diag.dropJump, diag.dropReset))
    }

    private func emit() {
        guard let onState else { return }
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
        d.outputFrames = audioSink?.outputFrameCount ?? 0  // 渲染侧回报,不进 self.diag
        s.diag = d
        onState(s)
    }

    // MARK: - 报文

    private func handle(_ data: Data, from address: sockaddr_in) {
        guard let packet = Wire.parse(data) else {
            diag.rxInvalid += 1
            return
        }
        diag.rxPackets += 1
        let key = addressKey(address)
        let fromActive = key == activeKey
        switch packet.type {
        case Wire.hello:
            handleHello(packet, from: address, key: key)
        case Wire.audio:
            guard fromActive else { diag.rxIgnoredInactive += 1; return }
            lastHeard = Date()
            // 静音后到达的尾部音频仍需解码播放以保留话尾,但不能把 UI 和
            // 渲染会话重新置为送声;只有设备的 status muted=0 才取消静音。
            if !muted { audioSink?.beginStream() }
            ingestAudio(packet)
        case Wire.status:
            guard fromActive else { diag.rxIgnoredInactive += 1; return }
            lastHeard = Date()
            let nowMuted = packet.flags & 1 == 1 || fields(packet.payload)["muted"] == "1"
            if nowMuted != muted {
                muted = nowMuted
                if muted {
                    audioSink?.endStream()  // 静默期:回调空转不再计断供
                    // 不清缓冲:Fn 松开的瞬间里面还有你这句话的尾巴(~130ms),
                    // 扔掉它会让听写引擎丢失句尾、把已识别内容重复一遍。
                    // 让它自然播空(约 130ms 后转静音)。
                    log("🔇 \(activeName) 已静音(设备侧采集关闭)")
                } else {
                    log("🎙 \(activeName) 取消静音")
                }
                emit()
            }
        default:
            break
        }
    }

    private func handleHello(_ packet: Wire.Packet, from address: sockaddr_in, key: String) {
        let f = fields(packet.payload)
        let name = f["name"] ?? "yahamic"
        // 这里不能刷新 lastHeard:换端口重连的设备每个 hello 都会给"旧会话"续命,
        // "旧设备还在线"永远成立,新 hello 永远被拒(死锁)。

        if f["rate"] != "16000" || f["ch"] != "1" || f["bits"] != "16" || f["frame"] != "60" || f["codec"] != "opus" {
            replyRefused(address, reason: "unsupported audio params")
            log("拒绝 \(name):音频参数不受支持(\(f["rate"] ?? "?") Hz)")
            return
        }
        if token != nil {
            guard let nonce = f["nonce"], let got = f["proof"],
                  got == proof(nonce: nonce)
            else {
                replyRefused(address, reason: "bad pairing code")
                log("拒绝 \(name):配对码不匹配(检查设备配网页与配对码设置)")
                return
            }
        }

        if key != activeKey {
            // 同名设备(名字含 MAC 后两字节)= 同一台换了端口/重启后重连:直接接管。
            // 接收会话是「activeAddr/activeKey + Uplink 序号基线 lastSeq + jitter +
            // AudioSink 会话状态」的统称:UDP socket 本身绑定本机固定端口,设备换的
            // 是源端口,无需重建 socket;旧会话状态必须全部作废,否则新端口的帧会
            // 沿用旧序号基线被判迟到/重复而持续丢弃——真机现象「长期零帧,App 重启
            // 且设备换 UDP 端口后才恢复 16 帧/s」对应的代码层修复(未经真机验证,
            // 真机是否完全解决靠 State.diag 分阶段计数继续观察)。
            let sameDevice = !activeName.isEmpty && name == activeName
            if !sameDevice && !activeKey.isEmpty && Date().timeIntervalSince(lastHeard) < 10 {
                log("忽略 \(name):当前 \(activeName) 还在线")
                replyRefused(address, reason: "another device is active")
                return
            }
            let previousKey = activeKey
            activeAddr = address
            activeKey = key
            activeName = name
            jitter.clear()
            audioSink?.resetSession()  // 换会话:渲染侧会话/预缓冲状态作废,等新音频帧再开播
            lastSeq = nil              // 序号基线重置:新会话首帧无条件接受
            muted = false
            frames = 0
            if sameDevice {
                log("🔄 \(name) 重连:\(previousKey.isEmpty ? "(无旧会话)" : previousKey) → \(key),接收会话、序号基线与预缓冲状态已重置")
            } else {
                log("🎤 \(name) 上线(\(key))")
            }
            // 上线即同步模式:push-to-talk 先静音;常开模式则确保在送声
            // (设备可能带着上次的静音状态回来,必须补发一次)。
            sendControl(muted: pushToTalk)
            if pushToTalk, !sameDevice { log("按住 Fn 键讲话,松开静音") }
        } else if lastSeq != nil {
            // 同地址重新握手(设备疑似重启):固件只在握手期发 hello(500ms 间隔,
            // 收到 welcome 即停),live 期间不会再发;「went quiet」重连会强制换源
            // 端口,所以能走到这里的同 key hello 基本等于「设备带着同一个临时端口
            // 重启了」(firmware open_socket() bind 端口 0,lwIP 冷启动后大概率
            // 分到同一个临时端口)。固件 seq 是开机归零的全局计数器
            // (firmware/main/uplink.cpp),重启后从 1 重排;若不重置 lastSeq,
            // 新帧相对旧 lastSeq 的缺口 >1000,会被 ingestAudio 按「过旧帧」永久
            // 丢弃(每帧只 +1,缺口不收敛)——表现为设备串口 live 且持续采集,
            // 而 Mac 侧 fps=0、capture samples=0,只有 droppedFrames 在涨。
            // 这是真机零帧基线的一个明确代码层原因;修复保证序号状态随重握手
            // 重置,但不等于宣称真机零帧已全部解决(仍可能有网络层因素,靠
            // State.diag 的分阶段计数继续观察)。
            diag.rehandshakes += 1
            lastSeq = nil
            jitter.clear()
            audioSink?.resetSession()  // 渲染侧会话/预缓冲状态一并作废,等新音频帧再开播
            // 设备重启后是全新状态(未静音),重新同步模式。
            sendControl(muted: pushToTalk)
            log("🔄 \(name) 重新握手(同地址 \(key),疑似重启):序号基线、抖动缓冲与渲染会话已重置")
        }
        lastHeard = Date()
        lastAnomalyLogAt = Date()  // 握手后 10s 宽限:等静音同步与首帧,避免误报断流

        var payload = "ok 1\nhost \(Host.current().localizedName ?? "Mac")\n"
        if token != nil, let nonce = f["nonce"] {
            payload += "proof \(proof(nonce: nonce, suffix: "welcome"))\n"
        }
        outSeq &+= 1
        send(Wire.build(type: Wire.welcome, seq: outSeq, ts: nowTs(),
                        payload: Data(payload.utf8)), to: address)
        emit()
    }

    private func replyRefused(_ address: sockaddr_in, reason: String) {
        outSeq &+= 1
        send(Wire.build(type: Wire.welcome, seq: outSeq, ts: nowTs(),
                        payload: Data("ok 0\nerr \(reason)\n".utf8)), to: address)
    }

    private func ingestAudio(_ packet: Wire.Packet) {
        diag.audioPackets += 1
        let payload = packet.payload
        guard payload.count > 0, let decoder = opusDecoder else {
            diag.decodeErrors += 1
            return
        }

        // xiaozhi 做法:丢旧不补静。乱序或过旧的帧直接跳过,让抖动缓冲自然
        // 排空;绝不人为插入静音(静音间隙会让听写引擎把已识别内容重复输出)。
        if let last = lastSeq {
            let expected = last &+ 1
            if packet.seq != expected {
                let dist = Int32(bitPattern: packet.seq &- last)  // 相对上一帧的有符号距离
                if dist == 0 {
                    // 同号重发:重复帧,直接丢
                    droppedFrames += 1
                    diag.dropDuplicate += 1
                    return
                }
                if dist < 0 {
                    // 乱序旧帧:迟到,直接丢
                    droppedFrames += 1
                    diag.dropLate += 1
                    return
                }
                if dist > 1000 {
                    // 序号大跳变/回绕(疑似设备重启但未重新握手):按单帧丢弃
                    droppedFrames += 1
                    diag.dropReset += 1
                    return
                }
                // 正常跳号:当前帧与上一帧之间有 dist-1 个缺失序号,不补静音。
                droppedFrames += Int(dist - 1)
                diag.dropJump += Int(dist - 1)
            }
        }
        lastSeq = packet.seq
        frames += 1

        // Opus 解码 → PCM → 抖动缓冲。
        var pcm = [Int16](repeating: 0, count: 960)  // 60ms @ 16kHz
        let decodedSamples = payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32 in
            guard let base = raw.baseAddress else { return 0 }
            return c_opus_decode(decoder, base.assumingMemoryBound(to: UInt8.self), Int32(payload.count), &pcm, 960, 0)
        }
        guard decodedSamples > 0 else {
            diag.decodeErrors += 1
            return
        }
        diag.decodedFrames += 1
        let n = Int(decodedSamples)
        // 诊断抽头:解码后的 16 kHz 单声道 S16LE PCM(Int16 本机序即小端)。
        // 直接复用上面的解码结果,不额外解码、不做重采样,主播放时序不受影响。
        if let onAudioTap {
            pcm[0..<n].withUnsafeBufferPointer { buf in
                onAudioTap(Data(UnsafeRawBufferPointer(buf)))
            }
        }
        var sumSq: Double = 0
        pcm[0..<n].withUnsafeBufferPointer { buf in
            for s in buf {
                let v = Double(s)
                sumSq += v * v
            }
            jitter.push(UnsafeBufferPointer(start: buf.baseAddress, count: n))
        }
        diag.enqueuedFrames += 1
        if n > 0 {
            let rms = (sumSq / Double(n)).squareRoot()
            levelDb = 20 * log10(max(rms / 32768, 1e-6))
        }
    }

    // MARK: - 杂项

    private func send(_ data: Data, to address: sockaddr_in) {
        transport?.send(data, to: address)
    }

    private func nowTs() -> UInt32 {
        UInt32(Date().timeIntervalSince(startedAt) * 1000)
    }

    private func dropActive(_ reason: String) {
        guard activeAddr != nil else { return }
        log("设备下线:\(reason)")
        activeAddr = nil
        activeKey = ""
        activeName = ""
        jitter.clear()
        audioSink?.endStream()
        fps = 0
        emit()
    }

    private func fields(_ payload: Data) -> [String: String] {
        var out: [String: String] = [:]
        let text = String(decoding: payload, as: UTF8.self)
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2 { out[String(parts[0])] = String(parts[1]) }
        }
        return out
    }

    private func proof(nonce: String, suffix: String = "") -> String {
        let base = (token ?? "") + nonce + suffix
        return SHA256.hash(data: Data(base.utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func log(_ message: String) {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(time)] \(message)"
        if let onLog {
            onLog(line)
        } else {
            print(line)
            fflush(stdout)
        }
    }
}

// MARK: - 报文编解码(小端,12 字节头,详见 README「协议」)

enum Wire {
    static let hello: UInt8 = 1
    static let welcome: UInt8 = 2
    static let audio: UInt8 = 3
    static let status: UInt8 = 4
    static let keepalive: UInt8 = 5
    static let control: UInt8 = 6
    static let dashboard: UInt8 = 7

    struct Packet {
        let type: UInt8
        let flags: UInt8
        let seq: UInt32
        let ts: UInt32
        let payload: Data
    }

    static func parse(_ data: Data) -> Packet? {
        guard data.count >= 12 else { return nil }
        let bytes = [UInt8](data.prefix(12))
        guard bytes[0] == 0x59, bytes[1] == 1 else { return nil }
        let seq = data.subdata(in: 4..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let ts = data.subdata(in: 8..<12).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return Packet(type: bytes[2], flags: bytes[3], seq: seq, ts: ts,
                      payload: data.count > 12 ? data.subdata(in: 12..<data.count) : Data())
    }

    static func build(type: UInt8, flags: UInt8 = 0, seq: UInt32, ts: UInt32,
                      payload: Data = Data()) -> Data {
        var data = Data([0x59, 1, type, flags])
        var leSeq = seq.littleEndian
        var leTs = ts.littleEndian
        withUnsafeBytes(of: &leSeq) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &leTs) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }
}
