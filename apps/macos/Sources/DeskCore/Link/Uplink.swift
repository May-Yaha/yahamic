import CoreBluetooth
import Dispatch
import Foundation
import DeskProtocol

// 设备到 Mac 的 BLE 直连(协议 v3,规范见 README「协议 v3」,固件侧 firmware/main/uplink.cpp):
// 扫描 yahadesk service → 连接 → 读 info → 订阅 audio/status → 写当前静音状态。
// 链路加密与配对全交给系统蓝牙(LE Secure Connections + 设备屏幕上的 6 位数),这里不碰密钥。
// CBCentralManager 与全部可变状态都在 queue 上;对外属性的 setter 也经 queue.sync 落地,
// 所以不要在 onState/onLog 回调里同步设置这些属性(会死锁)。
public final class Uplink: NSObject, @unchecked Sendable {
    /// Provisioning remains bound to one authenticated connection, including across reconnects.
    public struct Connection: Equatable, Sendable {
        public let peripheralID: UUID
        public let sessionID: UUID
        public init(peripheralID: UUID, sessionID: UUID = UUID()) {
            self.peripheralID = peripheralID; self.sessionID = sessionID
        }
    }

    /// 给界面用的链路快照(onState 在内部串行队列上回调,界面侧自行切主线程)。
    public struct State: Equatable {
        public var connected = false    // 已订阅 audio(链路已加密认证)
        /// 设备删了这台 Mac 的配对而系统还留着:App 无法自愈,要在系统蓝牙设置里移除设备后重配。
        public var pairingLost = false
        public var connection: Connection?
        public var deviceName = ""
        public var firmware = ""        // info 特征的 fw
        public var supportsCloud = false
        public var cloud = DeviceCloudState()
        public var supportsWiFiScan = false
        public var supportsPan = false      // 固件有 identity 特征(网盘绑定)
        public var wifiNetworks: WiFiScan?   // 设备最近一次扫描结果;旧固件或尚未扫描为 nil
        public var rssi = 0             // dBm,每秒读一次;未连接为 0
        public var muted = false
        public var levelDb: Double = -120
        public var framesPerSecond = 0
        public var bufferMs: Double = 0
        public var overflows = 0
        /// 断供事件数:流活跃且已开播时缓冲耗尽,每段持续断供计 1 次(口径见 AudioSink)。
        public var underruns = 0
        /// 累计丢帧数:seq 跳号按缺口计(不补静音),口径见 FrameAssembler。
        public var droppedFrames = 0
        /// 采集链路分阶段诊断计数(单调累计,详见 Diag)。
        public var diag = Diag()
        public init() {}
    }

    /// 分阶段诊断计数:看计数停在哪一级,断点就在哪一级:
    ///   rxPackets 不涨        → 链路层(没订阅上或设备没发)
    ///   rxInvalid 涨          → 分片截断/不连续(设备发送队列满丢了中间片)
    ///   audioPackets 涨、decodedFrames 不涨 → 解码失败
    ///   enqueuedFrames 涨、outputFrames 不涨 → 渲染侧断点(AudioSink 未消费)
    /// dropJump = seq 跳号的帧数(设备发送队列满整帧丢弃)。
    public struct Diag: Equatable {
        public var rxPackets = 0          // audio 通知数(分片)
        public var rxInvalid = 0          // 截断或分片不连续而扔掉的通知
        public var audioPackets = 0       // 重组出的完整帧
        public var decodeErrors = 0       // 解码失败/解码器缺失/空负载
        public var decodedFrames = 0      // Opus 解码成功
        public var enqueuedFrames = 0     // 入队抖动缓冲
        public var outputFrames = 0       // 输出:渲染侧实际消费的 60ms 帧(emit 时填入)
        public var dropJump = 0
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
    /// 设置后解码 PCM 不再直接进抖动缓冲,交给它处理后自行写入(只留本人声音用);在内部串行队列上回调。
    public var onPlayback: ((Data) -> Void)? {
        get { queue.sync { playbackHandler } }
        set { queue.sync { playbackHandler = newValue } }
    }
    /// 原始 Opus 帧与其解码样本数(16 kHz),录音备份用;只回调解码成功的帧,在内部串行队列上回调。
    public var onOpus: ((Data, Int) -> Void)? {
        get { queue.sync { opusHandler } }
        set { queue.sync { opusHandler = newValue } }
    }
    /// 每帧电平(dBFS,约 16 Hz),给讲话浮层画电平条;在内部串行队列上回调。
    public var onLevel: ((Double) -> Void)? {
        get { queue.sync { levelHandler } }
        set { queue.sync { levelHandler = newValue } }
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
    /// 手机麦克风开关:设备模式下配对过的 iPhone 开始广播报 true、5 秒没再看到报 false;
    /// 手机模式下 iPhone 撤掉服务(点了停止)报 false。在内部串行队列上回调。
    public var onPhoneMic: ((Bool) -> Void)? {
        get { queue.sync { phoneHandler } }
        set { queue.sync { phoneHandler = newValue } }
    }

    private var stateHandler: ((State) -> Void)?
    private var phoneHandler: ((Bool) -> Void)?
    private var logHandler: ((String) -> Void)?
    private var tapHandler: ((Data) -> Void)?
    private var playbackHandler: ((Data) -> Void)?
    private var opusHandler: ((Data, Int) -> Void)?
    private var levelHandler: ((Double) -> Void)?
    private weak var sink: AudioSink?
    private var ptt: Bool

    private let jitter: JitterBuffer
    private let verbose: Bool
    private let queue = DispatchQueue(label: "yahadesk.uplink")
    /// 声源:桌面设备,或打开了「手机当麦克风」的 iPhone(另一个 service,只有 info/audio/status/control)。
    private let service: CBUUID
    private let rememberedKey: String
    private let phone: Bool
    private var phoneSeenAt: Date?  // 设备模式下最近一次看到配对过的 iPhone 广播手机麦克风

    private var central: CBCentralManager?
    private var timer: DispatchSourceTimer?
    private var opus: OpusFrameDecoder?
    private var peripheral: CBPeripheral?
    private var chars: [CBUUID: CBCharacteristic] = [:]
    private var live = false
    private var connection: Connection?
    private var rssi = 0
    private var assembler = FrameAssembler()
    private var firmware = ""
    private var cloudCapability = false
    private var cloudState = DeviceCloudState()
    private var cloudRereading = false  // 通知被截断后已补读一次,补读也解不开就不再读
    private var wifiNetworks: WiFiScan?
    private var provisionPending: (id: UUID, target: Connection, characteristic: CBCharacteristic,
                                   completion: CheckedContinuation<Void, Error>)?
    private var identityPending: (id: UUID, completion: CheckedContinuation<Data, Error>)?
    private var muted = true            // 设备上报的静音状态(设备开机/断链都是静音)
    private var pairingLost = false

    private var frames = 0
    private var droppedFrames = 0
    private var diag = Diag()
    private var lastDiagSample = Diag()
    private var lastAnomalyLogAt = Date.distantPast
    private var lastStatusAt = Date()
    private var lastStatusFrames = 0
    private var levelDb = -120.0
    private var fps = 0

    public init(jitter: JitterBuffer, verbose: Bool, pushToTalk: Bool = true, phone: Bool = false) {
        self.jitter = jitter
        self.verbose = verbose
        self.ptt = pushToTalk
        self.phone = phone
        service = CBUUID(string: phone ? Wire.phoneService : Wire.service)
        rememberedKey = phone ? "yahadesk.phone" : "yahadesk.peripheral"
        super.init()
    }

    /// 创建 CBCentralManager(首次会弹蓝牙权限框),蓝牙就绪后自动连接。
    public func start() {
        queue.sync {
            guard central == nil else { return }
            opus = OpusFrameDecoder()
            if opus == nil { log("⚠️ Opus 解码器创建失败") }
            central = CBCentralManager(delegate: self, queue: queue)
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 1, repeating: 1)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
            log("就绪:蓝牙直连,协议 v\(Wire.version)")
            emit()
        }
    }

    /// 断开并释放蓝牙(改设置后重建链路用)。
    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            central?.stopScan()
            if let peripheral { central?.cancelPeripheralConnection(peripheral) }
            dropActive("App 断开")
            peripheral = nil  // stop() 之后的断开回调对不上 peripheral,不再重连
            central = nil
        }
    }

    /// 遥控设备静音:Fn 松开/按下,或界面上的开关。control 写带响应,链路层可靠。
    public func sendControl(muted: Bool) {
        queue.async { [weak self] in self?.write(Wire.muteCommand(muted), to: Wire.control) }
    }

    /// 请求设备回传一帧屏幕(排障/查看 UI;截图经日志口,由串口侧收集)。
    public func sendDump() {
        queue.async { [weak self] in self?.write(Wire.dumpCommand, to: Wire.control) }
    }

    /// 仪表盘数据下发(布局见 Wire.dashboard,与固件 DashboardPayload 逐一对应)。未上线时丢弃。
    public func sendDashboard(_ snapshot: MetricsSnapshot) {
        queue.async { [weak self] in
            var payload = Wire.dashboard(
                epoch: UInt32(truncatingIfNeeded: Int64(Date().timeIntervalSince1970)),
                tzMinutes: Int16(clamping: TimeZone.current.secondsFromGMT() / 60),
                cpu: snapshot.cpuPercent, mem: snapshot.memoryPercent,
                mouse: snapshot.mouseBattery, keyboard: snapshot.keyboardBattery)
            // Firmware with `cloud 1` (0.2.0+) also accepts the 12-byte form with Mac battery/power.
            if self?.cloudCapability == true { payload.append(contentsOf: [snapshot.macBattery, snapshot.macPower]) }
            self?.write(payload, to: Wire.dashboard, withResponse: false)
        }
    }

    /// 云端卡片(AI 日报、agent 消息):ttl 秒后设备自行清除,ttl = 0 立即清除。
    /// 未上线返回 false,由调用方下一轮重发;固件没有 card 特征时直接丢弃并返回 true,不堵住后面的指令。
    public func sendCard(ttl: UInt16, title: String, body: String) -> Bool {
        queue.sync {
            guard live else { return false }
            guard chars[CBUUID(string: Wire.card)] != nil else { return true }
            write(Wire.card(ttl: ttl, title: title, body: body), to: Wire.card)
            return true
        }
    }

    /// Reports success only after the authenticated GATT write response.
    public func provision(_ command: ProvisioningCommand, to target: Connection) async throws {
        let data = try command.encoded(), id = UUID()
        let cancellation = ProvisionCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, Error>) in
                queue.async {
                    guard !cancellation.isCancelled, self.live, self.connection == target,
                          let peripheral = self.peripheral, peripheral.identifier == target.peripheralID else {
                        completion.resume(throwing: DeskProtocolError("设备连接已改变，请重新操作")); return
                    }
                    guard self.cloudCapability,
                          let characteristic = self.chars[CBUUID(string: Wire.provision)] else {
                        completion.resume(throwing: DeskProtocolError("当前固件不支持联网配置，请先升级固件")); return
                    }
                    guard self.provisionPending == nil else {
                        completion.resume(throwing: DeskProtocolError("设备正在保存上一项设置")); return
                    }
                    self.provisionPending = (id, target, characteristic, completion)
                    peripheral.writeValue(data, for: characteristic, type: .withResponse)
                    self.queue.asyncAfter(deadline: .now() + 15) {
                        guard self.provisionPending?.id == id else { return }
                        self.failProvisionAndReconnect(DeskProtocolError("设备保存超时，请等待重连后重试"))
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
            self.queue.async {
                if self.provisionPending?.id == id { self.failProvisionAndReconnect(CancellationError()) }
            }
        }
    }

    /// Factory cert DER from the encrypted `identity` characteristic; empty when the device has no factory identity.
    public func readIdentity(from target: Connection) async throws -> Data {
        let id = UUID()
        return try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Data, Error>) in
            queue.async {
                guard self.live, self.connection == target, let peripheral = self.peripheral,
                      peripheral.identifier == target.peripheralID else {
                    completion.resume(throwing: DeskProtocolError("设备连接已改变，请重新操作")); return
                }
                guard let characteristic = self.chars[CBUUID(string: Wire.identity)] else {
                    completion.resume(throwing: DeskProtocolError("当前固件不支持网盘绑定，请先升级固件")); return
                }
                guard self.identityPending == nil else {
                    completion.resume(throwing: DeskProtocolError("正在读取设备出厂身份")); return
                }
                self.identityPending = (id, completion)
                peripheral.readValue(for: characteristic)
                self.queue.asyncAfter(deadline: .now() + 10) { self.finishIdentity(.failure(DeskProtocolError("读取设备出厂身份超时")), request: id) }
            }
        }
    }

    private func finishIdentity(_ result: Result<Data, Error>, request id: UUID? = nil) {
        guard let pending = identityPending, id == nil || pending.id == id else { return }
        identityPending = nil
        pending.completion.resume(with: result)
    }

    private func failProvisionAndReconnect(_ error: Error) {
        provisionPending?.completion.resume(throwing: error)
        provisionPending = nil
        // A late response has no request ID. Disconnect before accepting another provisioning write.
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        dropActive("设置写入未确认")
    }

    private func write(_ data: Data, to uuid: String, withResponse: Bool = true) {
        guard live, let peripheral, let c = chars[CBUUID(string: uuid)] else { return }
        if !withResponse && !peripheral.canSendWriteWithoutResponse { return }  // 下一秒还会再发
        peripheral.writeValue(data, for: c, type: withResponse ? .withResponse : .withoutResponse)
    }

    // MARK: - 状态

    private func tick() {
        if let seen = phoneSeenAt, Date().timeIntervalSince(seen) > 5 {
            phoneSeenAt = nil
            phoneHandler?(false)
        }
        guard live, let peripheral else { return }
        peripheral.readRSSI()
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
                format: "%@ │ %5.1f dB │ 缓冲 %3.0f ms │ %d 帧/s │ 溢 %d 欠 %d 丢 %d │ RSSI %d",
                muted ? "静音" : "送声", levelDb, Double(jitter.count) / 16.0, fps,
                stats.overflows, stats.underruns, droppedFrames, rssi))
        }
        emit()
    }

    /// 异常路径的节流聚合日志:正常播放完全不打印;出现异常时最多每 10 秒一行。
    private func logDiagAnomaliesIfNeeded() {
        let prev = lastDiagSample
        let audioDelta = diag.audioPackets - prev.audioPackets
        let decodeErrDelta = diag.decodeErrors - prev.decodeErrors
        // 偶发跳号是发送队列满,持续大量才报;解码失败与残帧出现即报。
        let abnormal = decodeErrDelta > 0 || diag.rxInvalid > prev.rxInvalid
            || diag.dropJump - prev.dropJump > 8
        // 未静音却整秒没有完整帧:设备侧断流或信号太弱。
        let starving = !muted && audioDelta == 0
        guard abnormal || starving else { return }
        guard Date().timeIntervalSince(lastAnomalyLogAt) >= 10 else { return }
        lastAnomalyLogAt = Date()
        log(String(
            format: "诊断(%@) │ 通知 Δ%d(残 Δ%d)│ 帧 Δ%d │ 解码 Δ%d(失败 Δ%d)│ 入队 Δ%d │ 输出 %d 帧 │ 跳号累计 %d │ RSSI %d",
            abnormal ? "丢帧" : "断流",
            diag.rxPackets - prev.rxPackets, diag.rxInvalid - prev.rxInvalid,
            audioDelta, diag.decodedFrames - prev.decodedFrames, decodeErrDelta,
            diag.enqueuedFrames - prev.enqueuedFrames,
            sink?.outputFrameCount ?? 0, diag.dropJump, rssi))
    }

    private func emit() {
        guard let stateHandler else { return }
        var s = State()
        s.connected = live
        s.pairingLost = pairingLost
        s.connection = connection
        s.deviceName = live ? peripheral?.name ?? "yahadesk" : ""
        s.firmware = live ? firmware : ""
        s.supportsCloud = live && cloudCapability && chars[CBUUID(string: Wire.provision)] != nil
        s.cloud = cloudState
        s.supportsWiFiScan = s.supportsCloud && chars[CBUUID(string: Wire.networks)] != nil
        s.supportsPan = s.supportsCloud && chars[CBUUID(string: Wire.identity)] != nil
        s.wifiNetworks = live ? wifiNetworks : nil
        s.rssi = live ? rssi : 0
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

    // MARK: - 上行数据

    /// audio 订阅生效:新会话。设备的 seq 跨连接不归零,重组器与缓冲全部重来。
    private func goLive() {
        guard let peripheral else { return }
        connection = Connection(peripheralID: peripheral.identifier)
        live = true
        pairingLost = false
        assembler.reset()
        jitter.clear()
        sink?.resetSession()
        muted = true  // 设备上线默认静音,随后的 status 会报真实状态
        frames = 0
        lastAnomalyLogAt = Date()  // 上线后 10s 宽限:等静音同步与首帧,避免误报断流
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: rememberedKey)
        log("🎤 \(peripheral.name ?? "yahadesk") 上线(蓝牙已加密)")
        if ptt { log("按住讲话键讲话,松开静音") }
        // 上线即同步模式:push-to-talk 先静音,常开模式开麦。
        write(Wire.muteCommand(ptt), to: Wire.control)
        emit()
    }

    private func handleAudio(_ packet: Data) {
        diag.rxPackets += 1
        let invalidBefore = assembler.invalid
        let frame = assembler.push(packet)
        diag.rxInvalid += assembler.invalid - invalidBefore
        guard let frame else { return }
        diag.dropJump += frame.gap
        droppedFrames += frame.gap
        // 静音后到达的尾部音频仍需解码播放以保留话尾,但不能把渲染会话重新置为送声;
        // 只有设备的 status muted 0 才取消静音。
        if !muted { sink?.beginStream() }
        ingestAudio(frame.opus)
    }

    private func handleStatus(_ value: Data) {
        guard let first = value.first else { return }
        let nowMuted = first != 0
        guard nowMuted != muted else { return }
        muted = nowMuted
        let name = peripheral?.name ?? "yahadesk"
        if muted {
            sink?.endStream()  // 静默期:回调空转不再计断供
            // 不清缓冲:Fn 松开的瞬间里面还有这句话的尾巴(~130ms),扔掉会让
            // 听写引擎丢失句尾、把已识别内容重复一遍。让它自然播空。
            log("🔇 \(name) 已静音(设备侧采集关闭)")
        } else {
            log("🎙 \(name) 取消静音")
        }
        emit()
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
        opusHandler?(payload, n)
        var sumSq: Double = 0
        pcm[0..<n].withUnsafeBufferPointer { buf in
            // 诊断抽头:解码后的 16 kHz 单声道 S16LE PCM(Int16 本机序即小端)。
            tapHandler?(Data(UnsafeRawBufferPointer(buf)))
            for s in buf {
                let v = Double(s)
                sumSq += v * v
            }
            if let playbackHandler { playbackHandler(Data(UnsafeRawBufferPointer(buf))) } else { jitter.push(buf) }
        }
        diag.enqueuedFrames += 1
        let rms = (sumSq / Double(n)).squareRoot()
        levelDb = 20 * log10(max(rms / 32768, 1e-6))
        levelHandler?(levelDb)
    }

    // MARK: - 连接管理

    private var remembered: UUID? {
        UserDefaults.standard.string(forKey: rememberedKey).flatMap(UUID.init(uuidString:))
    }
    /// 设备模式下留意的 iPhone:只认配对过(当过声源)的那台,没配过就不额外扫描。
    private var watchedPhone: UUID? {
        phone ? nil : UserDefaults.standard.string(forKey: "yahadesk.phone").flatMap(UUID.init(uuidString:))
    }
    private var connectingSince = Date.distantPast
    private var reportedError = false

    /// 未上线时一直扫描(允许重复上报,换设备时才能在超时后再次看到它);上线后只留意手机麦克风。
    private func connectOrScan() {
        guard let central, central.state == .poweredOn else { return }
        if peripheral == nil, let id = remembered,
           let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(p)
        }
        scan(live ? [] : [service])
    }

    private func scan(_ services: [CBUUID]) {
        let services = services + (watchedPhone == nil ? [] : [CBUUID(string: Wire.phoneService)])
        central?.stopScan()
        guard !services.isEmpty else { return }
        central?.scanForPeripherals(withServices: services, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    /// connect 没有超时:设备不在范围内时挂起,回来后系统自动连上。
    private func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        connectingSince = Date()
        reportedError = false
        central?.connect(p)
    }

    private func dropActive(_ reason: String) {
        if live { log("设备下线:\(reason)") }
        live = false
        connection = nil
        provisionPending?.completion.resume(throwing: DeskProtocolError("设备已断开，设置未确认"))
        provisionPending = nil
        finishIdentity(.failure(DeskProtocolError("设备已断开，未读到出厂身份")))
        cloudCapability = false; cloudState = DeviceCloudState(); cloudRereading = false; wifiNetworks = nil
        chars.removeAll()
        assembler.reset()
        jitter.clear()
        sink?.endStream()
        muted = true  // 设备断链即静音
        fps = 0
        rssi = 0
        emit()
    }

    /// 读写失败只报一次(配对被拒、设备重刷后 bond 不一致时会连续失败)。
    private func report(_ what: String, _ error: Error) {
        if (error as? CBError)?.code == .peerRemovedPairingInformation, !pairingLost {
            pairingLost = true
            emit()
        }
        guard !reportedError else { return }
        reportedError = true
        log("⚠️ \(what)失败:\(error.localizedDescription)。若设备重刷过,在系统设置 → 蓝牙里忽略 yahadesk 后重连")
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

// 回调都在 queue 上(CBCentralManager 用的就是它)。
extension Uplink: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            connectOrScan()
        case .unauthorized:
            log("⚠️ 没有蓝牙权限:系统设置 → 隐私与安全性 → 蓝牙,允许 Yaha Desk")
        case .poweredOff:
            log("蓝牙已关闭,打开后自动重连")
        default:
            break
        }
        if central.state != .poweredOn {
            dropActive("蓝牙不可用")
            peripheral = nil  // 蓝牙重开后外设对象作废,重新取
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                               advertisementData: [String: Any], rssi: NSNumber) {
        let phoneService = CBUUID(string: Wire.phoneService)
        // iPhone 退到后台时服务 UUID 改放在 overflow 区。
        let advertised = [CBAdvertisementDataServiceUUIDsKey, CBAdvertisementDataOverflowServiceUUIDsKey]
            .flatMap { advertisementData[$0] as? [CBUUID] ?? [] }
        if !phone, advertised.contains(phoneService) {
            guard p.identifier == watchedPhone else { return }  // 别人的或没配过的 iPhone 不理
            if phoneSeenAt == nil { phoneHandler?(true) }
            phoneSeenAt = Date()
            return
        }
        if let current = peripheral {
            guard current.state != .connected, p.identifier != current.identifier else { return }
            // 记住的设备优先;它 5 秒没连上(不在附近)才换成新发现的设备。
            guard p.identifier == remembered || Date().timeIntervalSince(connectingSince) > 5 else { return }
            central.cancelPeripheralConnection(current)
        }
        log("发现 \(p.name ?? "yahadesk"),连接中(首次连接按设备屏幕上的 6 位数字配对)")
        connect(p)
    }

    public func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard p === peripheral else { return }
        p.discoverServices([service])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard p === peripheral else { return }
        if let error { report("连接", error) }
        central.connect(p)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral,
                               error: Error?) {
        guard p === peripheral else { return }
        if let error, (error as? CBError)?.code == .peerRemovedPairingInformation { report("连接", error) }
        if phone, live { phoneHandler?(false) }  // iPhone 点了停止或走远:交回设备,它还在广播会再切回来
        dropActive(error?.localizedDescription ?? "已断开")
        connect(p)
        connectOrScan()
    }
}

extension Uplink: CBPeripheralDelegate {
    /// The device sends Service Changed after each boot; reconnecting rediscovers the new table.
    public func peripheral(_ p: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard p === peripheral, invalidatedServices.contains(where: { $0.uuid == service }) else { return }
        log("设备服务表已更新，重新连接")
        central?.cancelPeripheralConnection(p)
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard p === peripheral else { return }
        guard let service = p.services?.first(where: { $0.uuid == self.service }) else {
            if let error { report("发现服务", error) }
            return
        }
        let ids = [Wire.info, Wire.audio, Wire.status, Wire.control, Wire.dashboard, Wire.card, Wire.provision, Wire.cloudState,
                   Wire.networks, Wire.identity]
            .map { CBUUID(string: $0) }
        p.discoverCharacteristics(ids, for: service)
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard p === peripheral else { return }
        for c in service.characteristics ?? [] { chars[c.uuid] = c }
        guard let info = chars[CBUUID(string: Wire.info)], let audio = chars[CBUUID(string: Wire.audio)],
              let status = chars[CBUUID(string: Wire.status)], chars[CBUUID(string: Wire.control)] != nil
        else {
            log("⚠️ \(p.name ?? "yahadesk") 缺少协议 v\(Wire.version) 特征,固件版本不匹配?")
            return
        }
        // 特征都要求加密认证:未配对时第一次读会触发系统配对框。
        p.readValue(for: info)
        p.setNotifyValue(true, for: status)
        p.setNotifyValue(true, for: audio)
        if let cloud = chars[CBUUID(string: Wire.cloudState)] { p.setNotifyValue(true, for: cloud); p.readValue(for: cloud) }
    }

    public func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard p === peripheral, c === chars[c.uuid] else { return }
        if let error { return report("订阅", error) }
        if c.uuid == CBUUID(string: Wire.status), c.isNotifying { p.readValue(for: c) }
        if c.uuid == CBUUID(string: Wire.audio), c.isNotifying, !live {
            goLive()
            scan([])
        }
    }

    public func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard p === peripheral, c === chars[c.uuid] else { return }
        if c.uuid == CBUUID(string: Wire.identity) {
            // Empty value (no factory partition) is a valid answer; CoreBluetooth reports it as nil or empty.
            if error != nil { return finishIdentity(.failure(DeskProtocolError("读取设备出厂身份失败"))) }
            return finishIdentity(.success(c.value ?? Data()))
        }
        if let error { return report("读取", error) }
        guard let value = c.value else { return }
        switch c.uuid {
        case CBUUID(string: Wire.audio):
            handleAudio(value)
        case CBUUID(string: Wire.status):
            handleStatus(value)
        case CBUUID(string: Wire.info):
            let f = Fields.parse(value)
            firmware = String((f["fw"] ?? "").prefix(32))
            cloudCapability = f["cloud"] == "1"
            emit()
            log("设备固件 \(f["fw"] ?? "?"),\(f["rate"] ?? "?") Hz,\(f["frame"] ?? "?") ms \(f["codec"] ?? "?")")
        case CBUUID(string: Wire.cloudState):
            if value.count <= 512, let state = try? JSONDecoder().decode(DeviceCloudState.self, from: value) {
                // A finished scan bumps wifi_scan; the list itself is a separate read-only characteristic.
                if state.wifiScan > 0, state.wifiScan != wifiNetworks?.scan,
                   let networks = chars[CBUUID(string: Wire.networks)] { p.readValue(for: networks) }
                cloudState = state
                cloudRereading = false
                emit()
            } else if !cloudRereading {
                // 通知只带 MTU−3 字节,带 proof 的状态会被截断成坏 JSON;读可以长读到 512 字节。
                cloudRereading = true
                p.readValue(for: c)
            } else {
                cloudRereading = false
            }
        case CBUUID(string: Wire.networks):
            if value.count <= 512, let scan = try? JSONDecoder().decode(WiFiScan.self, from: value) {
                wifiNetworks = scan
                emit()
            }
        default:
            break
        }
    }

    public func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        guard p === peripheral else { return }
        if c.uuid == CBUUID(string: Wire.provision), let pending = provisionPending {
            guard pending.target == connection, p.identifier == pending.target.peripheralID,
                  c === pending.characteristic else { return }
            provisionPending = nil
            if error != nil { pending.completion.resume(throwing: DeskProtocolError("设备拒绝了设置，请检查配置后重试")) }
            else {
                pending.completion.resume()
                if let state = chars[CBUUID(string: Wire.cloudState)] { p.readValue(for: state) }
            }
            return
        }
        if let error { report("写入", error) }
    }

    public func peripheral(_ p: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard p === peripheral else { return }
        if error == nil { rssi = RSSI.intValue }
    }
}

private final class ProvisionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
