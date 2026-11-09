import AppKit
import ApplicationServices
import Combine
import Foundation
import ServiceManagement
import DeskCore
import DeskProtocol

// 控制中心的状态与生命周期:设置持久化、音频出口、设备链路、Fn 监听、日志。
// 控制接口命令见 HomeModel+Control,录制/指标/压测见 HomeModel+Diagnostics。
// 所有 @Published 只在主线程改(核心库的回调在它自己的队列上,这里切回主线程)。
@MainActor
final class HomeModel: ObservableObject {
    static let shared = HomeModel()

    // —— 设备 ——
    @Published var mic = MicDevice()

    // —— 运行状态 ——
    @Published var logs: [String] = []
    @Published var outputs: [OutputDevice] = []
    @Published var audioError: String?
    @Published var fnAvailable = false
    @Published var needsAccessibility = false  // 需要辅助功能权限(界面显示申请卡片)
    @Published private(set) var listenPermission: ListenPermission = .ok  // 键盘监听权限预检状态(面板状态行)
    @Published var launchAtLogin = false
    @Published private(set) var blackHoleMissing = false  // 选的是 BlackHole 但系统里没有(显示安装卡片)
    @Published private(set) var blackHoleInstall: BlackHoleInstallState = .idle
    @Published var localSTTState: LocalSTTState = .disabled

    // —— 设置 ——
    @Published var pttEnabled: Bool {
        didSet {
            defaults.set(pttEnabled, forKey: "ptt")
            if !pttEnabled, localSTTEnabled { localSTTEnabled = false }
            if started { applyPushToTalk() }
        }
    }
    @Published var localSTTEnabled: Bool {
        didSet {
            defaults.set(localSTTEnabled, forKey: "localSTT")
            if localSTTEnabled, !pttEnabled { pttEnabled = true }
            localSTTSettingChanged()
        }
    }
    /// 按住讲话的键。HHKB 的 Fn 不上报 macOS,改选一颗修饰键。
    @Published var talkKey: TalkKey {
        didSet {
            defaults.set(talkKey.rawValue, forKey: "talkKey")
            guard started, fn?.key != talkKey else { return }
            cancelLocalDictationForListenerChange()
            fn?.stop()  // 先停旧 tap 再重建,任意时刻至多一个活动 tap
            fn = nil
            fnAvailable = false
            ensureFnListener()
        }
    }
    @Published var outputDeviceName: String {
        didSet {
            defaults.set(outputDeviceName, forKey: "outputDevice")
            if started && sink?.deviceName != outputDeviceName { startAudio() }
        }
    }
    @Published var jitterMs: Int {
        didSet { defaults.set(jitterMs, forKey: "jitterMs") }
    }

    private let defaults = UserDefaults.standard
    var started = false
    let jitter: JitterBuffer
    private(set) var sink: AudioSink?
    private(set) var uplink: Uplink?
    private var metricsCollector: MetricsCollector?  // 仪表盘采样器(dashboard 数据源)
    private var metricsTimer: Timer?                 // 只建一次;链路重建不重建 Timer
    private var control: ControlServer?
    var audioCaptureGate = AudioCaptureGate()
    let localSpeech = LocalSpeechRecognizer()
    var localDictationCapture = LocalDictationCapture()
    var localSTTPrepareTask: Task<Void, Never>?
    var localSTTWorkTask: Task<Void, Never>?
    var localSTTStopTask: Task<Void, Never>?
    var localSTTPreviewTask: Task<Void, Never>?
    private var fn: FnListener?
    private var fnRetry: Timer?
    private var hardware: AudioHardwareWatcher?  // 设备增减/采样率变化 → 重建出口
    private var deviceWatch: Timer?  // 缺输出设备时的轮询兜底,设备出现即停
    private var lastFnPermission: ListenPermission?  // 上次预检状态,转换时记日志
    private var permissionObservers: [NSObjectProtocol] = []  // didBecomeActive/DNC 权限恢复观察
    private var hasPromptedPermission = false  // 系统授权框每次运行至多自动弹一次
    private var logHandle: FileHandle?
    private var lastMetricAt = Date.distantPast
    let logURL: URL

    var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// 正在送声(顶栏图标标红)。
    var isLive: Bool { mic.isOnline && !mic.state.muted }

    let overlay = TalkOverlay()
    let cloud = CloudSync()
    let recordings = RecordingBackup()
    let voiceProfile = VoiceProfile()
    let firmware = FirmwareInstaller()
    private var panRenewal: Task<Void, Never>?

    private init() {
        let storedPTT = defaults.object(forKey: "ptt") as? Bool ?? true
        let storedLocalSTT = defaults.object(forKey: "localSTT") as? Bool ?? true
        pttEnabled = storedLocalSTT || storedPTT
        localSTTEnabled = storedLocalSTT
        if storedLocalSTT, !storedPTT { defaults.set(true, forKey: "ptt") }
        outputDeviceName = defaults.string(forKey: "outputDevice") ?? "BlackHole"
        talkKey = defaults.string(forKey: "talkKey").flatMap(TalkKey.init(rawValue:)) ?? .fn
        // 60/120ms 基线真机仍会周期性欠载,统一迁移到 180ms;用户更高的值保留。
        let stored = defaults.object(forKey: "jitterMs") as? Int
        let effective = AudioBufferPolicy.normalizedTargetMs(stored)
        if stored != effective { defaults.set(effective, forKey: "jitterMs") }
        jitterMs = effective
        jitter = JitterBuffer(ms: effective * 4)

        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
        logURL = logs.appendingPathComponent("YahaDesk.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        logHandle = try? FileHandle(forWritingTo: logURL)
        logHandle?.seekToEndOfFile()
    }

    // MARK: - 生命周期

    func start() {
        guard !started else { return }
        started = true
        log("Yaha Desk \(version) 启动")
        refreshOutputs()
        hardware = AudioHardwareWatcher { [weak self] in
            MainActor.assumeIsolated { self?.audioHardwareChanged() }  // 监听回调在主队列
        }
        startAudio()
        startUplink()
        applyPushToTalk()
        if localSTTEnabled { prepareLocalSTT() }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        startControlServer()
        startCloud()
        recordings.log = { [unowned self] in log($0) }
        recordings.loginExpired = { [unowned self] in cloud.panLoginExpired() }
        voiceProfile.log = { [unowned self] in log($0) }
        firmware.log = { [unowned self] in log($0) }
        voiceProfile.capture = { [weak self] seconds in
            guard let self else { throw VoiceProfileError("Yaha Desk 已退出") }
            return try await self.captureVoicePCM(seconds: seconds)
        }
        cloud.renewPanToken = { [unowned self] in await PanKeychain.renewIfDue(log: { self.log($0) }) }
        // 网盘令牌 30 天有效:启动时和每 6 小时检查一次,剩 7 天内经 hub 续期,再补传上次没传完的录音。
        panRenewal = Task { [weak self] in
            while !Task.isCancelled {
                await self?.cloud.renewPan()
                await self?.recordings.upload()
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
        // 授权后无需重启即可恢复:回到前台、或系统权限变更广播
        // (com.apple.accessibility.api)时立即重查,状态转为已授权就重建 tap;
        // ensureFnListener 里的 2 秒轮询是兜底。
        permissionObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.ensureFnListener() }
        })
        permissionObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.ensureFnListener() }
        })
    }

    /// 本机控制接口(Unix socket,仅本用户可连):MCP 桥/脚本从这里驱动 App,压测全走它。
    private func startControlServer() {
        #if APP_STORE
        // 商店版不开:容器路径常超 sun_path 104 字节,外部脚本也进不了沙盒容器;压测用 dev/devid 版。
        return
        #else
        let path = ControlServer.defaultPath
        control = ControlServer(path: path) { [weak self] request in
            guard let self else { return ["error": "app-not-ready"] }
            return await self.handleControl(request)
        }
        log(control != nil ? "控制接口已监听 \(path.path)(MCP/压测用)" : "⚠️ 控制接口启动失败")
        #endif
    }

    /// yahaops 云端:每次读 self.uplink,链路重建后自动跟到新实例。
    private func startCloud() {
        cloud.sendProvision = { [unowned self] command, target in
            guard let uplink else { throw DeskProtocolError("设备未连接") }
            try await uplink.provision(command, to: target)
        }
        cloud.readIdentity = { [unowned self] target in
            guard let uplink else { throw DeskProtocolError("设备未连接") }
            return try await uplink.readIdentity(from: target)
        }
        cloud.log = { [unowned self] in log($0) }
        cloud.start()
    }

    func shutdown() {
        panRenewal?.cancel()
        cloud.stop()
        control?.stop()
        control = nil
        uplink?.stop()
        uplink = nil
        sink = nil
        hardware = nil
        // 面板退出:先显式停 tap 再丢弃实例,杜绝悬空回调;重试轮询一并停掉。
        fn?.stop()
        fn = nil
        fnRetry?.invalidate()
        fnRetry = nil
        for observer in permissionObservers { NotificationCenter.default.removeObserver(observer) }
        permissionObservers.removeAll()
    }

    func refreshOutputs() {
        outputs = DeskCore.outputDevices().sorted { $0.name < $1.name }
    }

    private func startAudio() {
        sink = nil
        hardware?.watchRate(of: nil)
        guard let device = findOutputDevice(named: outputDeviceName) else {
            blackHoleMissing = outputDeviceName.localizedCaseInsensitiveContains("BlackHole")
            audioError = blackHoleMissing
                ? "未安装虚拟麦克风 BlackHole"
                : "找不到输出设备「\(outputDeviceName)」,请在下方换一个。"
            log("⚠️ \(audioError!)")
            watchForOutputDevice()
            return
        }
        deviceWatch?.invalidate()
        deviceWatch = nil
        blackHoleMissing = false
        if blackHoleInstall != .idle { blackHoleInstall = .idle }
        guard let opened = AudioSink(device: device, jitter: jitter, targetMs: jitterMs) else {
            audioError = "无法打开「\(device.name)」(被独占或权限受限)"
            log("⚠️ \(audioError!)")
            return
        }
        sink = opened
        uplink?.audioSink = opened  // 重接线:断供计数依赖「流活跃」标记
        hardware?.watchRate(of: opened.deviceID)
        audioError = nil
        if outputDeviceName != device.name { outputDeviceName = device.name }  // 存精确名
        log("音频出口:\(device.name)(\(Int(device.sampleRate)) Hz)")
        restoreVirtualMicVolume()
    }

    /// 开播与每次开始讲话时把虚拟麦克风音量拉回 100%(被调低时听写收不到声、不出字)。
    /// 只动 BlackHole:用户选了真实扬声器/耳机时音量归用户管。
    private func restoreVirtualMicVolume() {
        guard let sink, sink.deviceName.localizedCaseInsensitiveContains("BlackHole"),
              let was = DeskCore.restoreFullVolume(of: sink.deviceID) else { return }
        log("\(sink.deviceName) 音量被调到 \(Int((was * 100).rounded()))%,已恢复 100%(否则听写收不到声)")
    }

    /// 系统设备列表或当前出口的采样率变了:出口消失、或采样率与打开时不同就重建
    /// (重建失败落回缺设备轮询);没有出口时顺便试着接上。
    private func audioHardwareChanged() {
        refreshOutputs()
        if let sink {
            let current = findOutputDevice(named: sink.deviceName)
            guard current?.id != sink.deviceID || current?.sampleRate != sink.sampleRate else { return }
            log("音频设备变化(\(sink.deviceName)),重建出口")
        } else if findOutputDevice(named: outputDeviceName) == nil {
            return
        }
        startAudio()
    }

    /// 缺输出设备期间每 3 秒查一次:App 内一键安装、终端粘贴命令、用户自己装,装好都自动接上。
    private func watchForOutputDevice() {
        guard deviceWatch == nil else { return }
        deviceWatch = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, findOutputDevice(named: self.outputDeviceName) != nil else { return }
                self.refreshOutputs()
                self.startAudio()
            }
        }
    }

    func installBlackHole() {
        #if !APP_STORE
        guard !blackHoleInstall.busy else { return }
        blackHoleInstall = .downloading
        log("开始安装 BlackHole")
        Task {
            do {
                try await BlackHoleSetup.install { [weak self] in self?.blackHoleInstall = .installing }
                blackHoleInstall = .waiting  // 设备出现后 startAudio 会把状态清回 idle
                log("BlackHole 已安装,等待音频服务加载驱动")
            } catch {
                blackHoleInstall = .failed(error.localizedDescription)
                log("⚠️ BlackHole 安装:\(error.localizedDescription)")
            }
        }
        #endif
    }

    func copyBlackHoleCommand() {
        copyToPasteboard(BlackHoleSetup.terminalCommand)
    }

    func openTerminal() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func startUplink() {
        uplink?.stop()
        let link = Uplink(jitter: jitter, verbose: false, pushToTalk: pttEnabled)
        link.audioSink = sink  // 接线:断供事件计数需要「流活跃」标记
        link.onLog = { [weak self] line in
            DispatchQueue.main.async { self?.log(line, stamped: true) }
        }
        link.onState = { [weak self] state in
            DispatchQueue.main.async { self?.linkStateChanged(state) }
        }
        // 与 onState 同一串行队列、同样切主线程,帧与静音切换的先后不乱。
        link.onOpus = { [weak self] packet, samples in
            DispatchQueue.main.async { self?.recordings.append(packet, samples: samples) }
        }
        link.onLevel = { [weak self] db in
            DispatchQueue.main.async { self?.overlay.push(level: db) }
        }
        uplink = link
        link.start()
        startDashboardReporter()
    }

    private func linkStateChanged(_ state: Uplink.State) {
        let startsTalking = state.connected && !state.muted && (mic.state.muted || !mic.state.connected)
        mic.state = state
        finishLocalDictationIfSafe(connected: state.connected, muted: state.muted)
        completePrivateAudioCaptureIfSafe(state)
        cloud.updateDeviceState(state)
        recordings.talking(state.connected && !state.muted)
        if startsTalking { restoreVirtualMicVolume() }
        overlay.linkChanged(online: state.connected, muted: state.muted)
        // 压测遥测:设备在线时每 10 秒记一行流指标。
        guard state.connected, Date().timeIntervalSince(lastMetricAt) > 10 else { return }
        lastMetricAt = Date()
        log(String(format: "指标 │ %@ │ %.0f dB │ %d 帧/s │ 缓冲 %.0f ms │ 溢 %d 欠 %d",
                   state.muted ? "静音" : "送声", state.levelDb, state.framesPerSecond,
                   state.bufferMs, state.overflows, state.underruns))
    }

    // 仪表盘上报(dashboard 特征):设备空闲屏大字时钟 + 2x2 仪表(CPU/内存/键鼠电量)
    // 的数据源,3s 周期采样。Timer 只建一次(startUplink 随链路重建会被多次调用),
    // 每次读 self.uplink,链路重建后自动跟到新实例。未上线时 sendDashboard 自己丢弃。
    private func startDashboardReporter() {
        guard metricsTimer == nil else { return }
        metricsCollector = metricsCollector ?? MetricsCollector()
        metricsTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reportDashboard() }
        }
        reportDashboard()  // 立即采一帧;未上线时被丢弃,等下个周期
    }

    private func reportDashboard() {
        guard let uplink, let metricsCollector else { return }
        uplink.sendDashboard(metricsCollector.sample())
    }

    // MARK: - 操作

    /// 暂时断开:停掉蓝牙链路(不扫描、不重连),把设备唯一的连接让给 iPhone 配置。
    /// 不持久化:恢复或重启 App 都会重新连接。
    func setLinkPaused(_ paused: Bool) {
        guard paused != mic.paused else { return }
        mic.paused = paused
        if paused {
            uplink?.stop()
            uplink = nil
            log("已暂时断开设备,可在 iPhone 上配置")
        } else {
            log("恢复连接设备")
            startUplink()
        }
    }

    /// 离线时手动重连:重建链路,重新取记住的设备并扫描(在系统设置里移除配对后用它走重新配对)。
    func reconnect() {
        log("重新连接设备")
        startUplink()
    }

    func openBluetoothSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
            NSWorkspace.shared.open(url)
        }
    }

    func toggleMute() {
        uplink?.sendControl(muted: !mic.state.muted)
    }

    private func applyPushToTalk() {
        uplink?.pushToTalk = pttEnabled
        if pttEnabled {
            ensureFnListener()
            uplink?.sendControl(muted: true)   // 平时静音,按住 Fn 才讲话
        } else {
            // 关闭 Fn 监听:先停旧 tap 再丢引用,保证任意时刻至多一个活动 tap。
            cancelLocalDictationForListenerChange()
            fn?.stop()
            fn = nil
            fnRetry?.invalidate()
            fnRetry = nil
            fnAvailable = false
            needsAccessibility = false
            uplink?.sendControl(muted: false)  // 常开麦克风
            log("按住 Fn 讲话:已关闭(麦克风常开)")
        }
    }

    func ensureFnListener() {
        guard pttEnabled else { return }
        // 辅助功能与输入监听两套授权分开评估(tapCreate 在权限刚失效时仍可能
        // "成功",预检状态才是能否收到事件的可靠依据)。缺权限 → 面板亮卡片 +
        // 弹系统授权框;有了 → 自动重建 tap 恢复。
        let status = ListenPermission.preflight()
        if status != lastFnPermission {
            log("Fn 权限状态:\(lastFnPermission?.description ?? "未评估") → \(status.description)")
            lastFnPermission = status
        }
        listenPermission = status
        needsAccessibility = !status.granted
        if !status.granted {
            if let old = fn {
                // 权限失效:先显式停 tap 再丢弃实例,等授权恢复后重建。
                cancelLocalDictationForListenerChange()
                old.stop()
                fn = nil
                fnAvailable = false
                log("⚠️ 「按住 Fn 讲话」不可用:\(status.description)。\(status.guidance)")
            }
            if !hasPromptedPermission {
                hasPromptedPermission = true
                _ = ListenPermission.request()
            }
        } else if fn == nil {
            let name = talkKey.title
            if let listener = FnListener(key: talkKey, onChange: { [weak self] down in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.handleTalkKey(down, name: name)
                }
            }) {
                // 此处 fn 必为 nil(上面的 else if 守卫),旧实例已在丢弃前 stop。
                fn = listener
                fnAvailable = true
                log("按住 \(name) 讲话:已启用")
            } else {
                log("⚠️ Fn 监听创建失败")
            }
        }
        if fnRetry == nil {  // 持续轮询:授权一到位 2 秒内恢复,被收回也能发现
            fnRetry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.ensureFnListener() }
            }
        }
    }

    /// 权限卡片的「再次申请」:对缺失项发起系统授权请求(输入监听
    /// 走 CGRequestListenEventAccess,辅助功能走 AX 弹框),随后立即重查刷新;
    /// 若已授权则立刻重建 tap,无需重启面板。
    func requestListenPermission() {
        hasPromptedPermission = true  // 这次是用户主动点的,弹完不再自动打扰
        let status = ListenPermission.request()
        listenPermission = status
        log("已向系统申请键盘事件权限(\(status.description)),请在弹出的确认框里允许")
        ensureFnListener()  // 立即重查:授权到位就当场恢复监听
    }

    /// 「打开设置」按缺失项跳到对应面板:缺输入监听跳输入监听,否则跳辅助功能。
    func openListenPermissionSettings() {
        let pane = (listenPermission == .missingInputMonitoring || listenPermission == .missingBoth)
            ? "Privacy_ListenEvent" : "Privacy_Accessibility"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = on
            log(on ? "已设置开机自启" : "已取消开机自启")
        } catch {
            log("开机自启设置失败:\(error.localizedDescription)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    func openLog() {
        NSWorkspace.shared.open(logURL)
    }

    func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - 日志

    func log(_ message: String, stamped: Bool = false) {
        let line: String
        if stamped {
            line = message  // 核心库已带时间戳
        } else {
            let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            line = "[\(time)] \(message)"
        }
        logs.append(line)
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
        if let data = (line + "\n").data(using: .utf8) { logHandle?.write(data) }
    }
}
