import AppKit
import ApplicationServices
import Combine
import Foundation
import ServiceManagement
import YahamicCore

// 控制中心的状态与生命周期:设置持久化、音频出口、设备链路、Fn 监听、日志。
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

    // —— 设置(UserDefaults)——
    @Published var pttEnabled: Bool {
        didSet {
            defaults.set(pttEnabled, forKey: "ptt")
            if started { applyPushToTalk() }
        }
    }
    @Published var outputDeviceName: String {
        didSet {
            defaults.set(outputDeviceName, forKey: "outputDevice")
            if started && sink?.deviceName != outputDeviceName { startAudio() }
        }
    }
    @Published var token: String  // 点「应用」才生效(要重建链路)
    @Published var jitterMs: Int {
        didSet { defaults.set(jitterMs, forKey: "jitterMs") }
    }

    private let defaults = UserDefaults.standard
    private var started = false
    private let jitter: JitterBuffer
    private var sink: AudioSink?
    private var uplink: Uplink?
    private var metricsCollector: MetricsCollector?  // 仪表盘采样器(type 7 数据源)
    private var metricsTimer: Timer?                 // 只建一次;链路重建不重建 Timer
    private var control: ControlServer?
    private var fn: FnListener?
    private var fnRetry: Timer?
    private var lastFnPermission: ListenPermission?  // 上次预检状态,转换时记日志
    private var permissionObservers: [NSObjectProtocol] = []  // didBecomeActive/DNC 权限恢复观察
    private var hasPromptedPermission = false  // 系统授权框每次运行至多自动弹一次
    private var logHandle: FileHandle?
    private var lastMetricAt = Date.distantPast
    let logURL: URL

    var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// 顶栏图标:离线=划线麦克风线框,静音=实心划线,送声=实心麦克风。
    var menuSymbol: String {
        guard mic.isOnline else { return "mic.slash" }
        return mic.state.muted ? "mic.slash.fill" : "mic.fill"
    }

    private init() {
        pttEnabled = defaults.object(forKey: "ptt") as? Bool ?? true
        outputDeviceName = defaults.string(forKey: "outputDevice") ?? "BlackHole"
        token = defaults.string(forKey: "token") ?? ""
        // 旧默认 60ms 在 Wi-Fi 偶发抖动下偏紧(语音转写会听到重复),迁移到 120ms。
        let stored = defaults.object(forKey: "jitterMs") as? Int ?? 60
        let effective = stored == 60 ? 120 : stored
        if stored == 60 { defaults.set(120, forKey: "jitterMs") }
        jitterMs = effective
        jitter = JitterBuffer(ms: effective * 4)

        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
        logURL = logs.appendingPathComponent("YahaHome.log")
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
        log("Yaha 家居 \(version) 启动")
        refreshOutputs()
        startAudio()
        startUplink()
        applyPushToTalk()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        startControlServer()
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

    /// 本机控制接口(127.0.0.1:7718):MCP 桥/脚本从这里驱动 App,压测全走它。
    private func startControlServer() {
        control = ControlServer(port: 7718) { [weak self] request in
            guard let self else { return ["error": "app-not-ready"] }
            return await self.handleControl(request)
        }
        if control != nil {
            log("控制接口已监听 127.0.0.1:7718(MCP/压测用)")
        }
    }

    func shutdown() {
        uplink?.stop()
        uplink = nil
        sink = nil
        // 面板退出:先显式停 tap 再丢弃实例,杜绝悬空回调;重试轮询一并停掉。
        fn?.stop()
        fn = nil
        fnRetry?.invalidate()
        fnRetry = nil
        for observer in permissionObservers { NotificationCenter.default.removeObserver(observer) }
        permissionObservers.removeAll()
    }

    func refreshOutputs() {
        outputs = YahamicCore.outputDevices().sorted { $0.name < $1.name }
    }

    private func startAudio() {
        sink = nil
        guard let device = findOutputDevice(named: outputDeviceName) else {
            audioError = "找不到输出设备「\(outputDeviceName)」。请安装 BlackHole"
                + "(brew install blackhole-2ch,装后 sudo killall coreaudiod),或在下方换一个。"
            log("⚠️ \(audioError!)")
            return
        }
        guard let opened = AudioSink(device: device, jitter: jitter, targetMs: jitterMs) else {
            audioError = "无法打开「\(device.name)」(被独占或权限受限)"
            log("⚠️ \(audioError!)")
            return
        }
        sink = opened
        uplink?.audioSink = opened  // 重接线:断供计数依赖「流活跃」标记
        audioError = nil
        if outputDeviceName != device.name { outputDeviceName = device.name }  // 存精确名
        log("音频出口:\(device.name)(\(Int(device.sampleRate)) Hz)")
    }

    private func startUplink() {
        uplink?.stop()
        let link = Uplink(token: token.isEmpty ? nil : token, jitter: jitter, verbose: false,
                          pushToTalk: pttEnabled)
        link.audioSink = sink  // 接线:断供事件计数需要「流活跃」标记
        link.onLog = { [weak self] line in
            DispatchQueue.main.async { self?.log(line, stamped: true) }
        }
        link.onState = { [weak self] state in
            DispatchQueue.main.async {
                self?.mic.state = state
                // 压测遥测:设备在线时每 10 秒记一行流指标。
                if state.connected, Date().timeIntervalSince(self?.lastMetricAt ?? .distantPast) > 10 {
                    self?.lastMetricAt = Date()
                    self?.log(String(
                        format: "指标 │ %@ │ %.0f dB │ %d 帧/s │ 缓冲 %.0f ms │ 溢 %d 欠 %d",
                        state.muted ? "静音" : "送声", state.levelDb, state.framesPerSecond,
                        state.bufferMs, state.overflows, state.underruns))
                }
            }
        }
        uplink = link
        link.start()
        startDashboardReporter()
    }

    // 仪表盘上报(协议 type 7):设备空闲屏大字时钟 + 2x2 仪表(CPU/内存/键鼠电量)
    // 的数据源,3s 周期采样。Timer 只建一次(startUplink 随链路重建会被多次调用),
    // 闭包每次读 self.uplink 属性,链路重建后自动跟到新实例,无需重建 Timer。
    // why 主 RunLoop Timer + sendDashboard 内部串行队列:采样与网络写分离,所有
    // 下行帧(keepalive/control/dashboard)在 uplink 串行队列排序,不会帧交织;
    // 未握手时 sendDashboard 按 activeAddr 判空丢弃,天然满足「仅握手后发送」
    // (与 yahamicd/main.swift 同一 idiom)。
    private func startDashboardReporter() {
        guard metricsTimer == nil else { return }
        let collector = metricsCollector ?? MetricsCollector()
        metricsCollector = collector
        let timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, let uplink = self.uplink else { return }
            uplink.sendDashboard(collector.sample())
        }
        timer.fire()  // 立即采一帧;未握手时被丢弃,等下个周期
        metricsTimer = timer
    }

    // MARK: - 操作

    func toggleMute() {
        uplink?.sendControl(muted: !mic.state.muted)
    }

    func applyToken() {
        defaults.set(token, forKey: "token")
        startUplink()
        log(token.isEmpty ? "配对码已清除,链路已重建" : "配对码已应用,链路已重建")
    }

    private func applyPushToTalk() {
        uplink?.pushToTalk = pttEnabled
        if pttEnabled {
            ensureFnListener()
            uplink?.sendControl(muted: true)   // 平时静音,按住 Fn 才讲话
        } else {
            // 关闭 Fn 监听:先停旧 tap 再丢引用,保证任意时刻至多一个活动 tap。
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

    private func ensureFnListener() {
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
            if let listener = FnListener(onChange: { [weak self] down in
                DispatchQueue.main.async {
                    self?.uplink?.sendControl(muted: !down)
                    self?.log(down ? "Fn 按下 → 送声" : "Fn 松开 → 静音")
                }
            }) {
                // 此处 fn 必为 nil(上面的 else if 守卫),旧实例已在丢弃前 stop。
                fn = listener
                fnAvailable = true
                log("按住 Fn 讲话:已启用")
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

    /// 界面上的「申请权限」按钮:再弹一次系统授权框(缺失项各弹各的)。
    func requestAccessibility() {
        requestListenPermission()
    }

    /// 面板权限状态行的「请求授权/重试」:对缺失项发起系统授权请求(输入监听
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

    // MARK: - 控制接口命令(MCP/脚本/压测)

    func handleControl(_ request: [String: Any]) async -> [String: Any] {
        switch request["cmd"] as? String ?? "" {
        case "status":
            var out: [String: Any] = [
                "version": version,
                "ptt": pttEnabled,
                "fnAvailable": fnAvailable,
                "needsAccessibility": needsAccessibility,
                "launchAtLogin": launchAtLogin,
                "outputDevice": sink?.deviceName ?? "-",
            ]
            if let audioError { out["audioError"] = audioError }
            // 「激活」阶段诊断:流是否被音频帧喂起来过(见 AudioSink.streamStats)。
            if let stats = sink?.streamStats() {
                out["streamActive"] = stats.active
                out["streamActivations"] = stats.activations
            }
            var device: [String: Any] = ["connected": mic.isOnline]
            if mic.isOnline {
                device["name"] = mic.state.deviceName
                device["address"] = mic.state.address
                device["muted"] = mic.state.muted
                device["levelDb"] = mic.state.levelDb
                device["framesPerSecond"] = mic.state.framesPerSecond
                device["bufferMs"] = mic.state.bufferMs
                device["overflows"] = mic.state.overflows
                device["underruns"] = mic.state.underruns
                // 接收侧本地统计(乱序/过旧丢弃 + 跳号缺口),非设备遥测透传。
                device["droppedFrames"] = mic.state.droppedFrames
                // 分阶段诊断计数(收包/解码/入队/重握手):定位零帧断点用,
                // 各字段口径见 Uplink.Diag。
                let d = mic.state.diag
                device["diag"] = [
                    "rxPackets": d.rxPackets,
                    "rxInvalid": d.rxInvalid,
                    "rxIgnoredInactive": d.rxIgnoredInactive,
                    "audioPackets": d.audioPackets,
                    "decodeErrors": d.decodeErrors,
                    "decodedFrames": d.decodedFrames,
                    "enqueuedFrames": d.enqueuedFrames,
                    "outputFrames": d.outputFrames,
                    "dropLate": d.dropLate,
                    "dropDuplicate": d.dropDuplicate,
                    "dropJump": d.dropJump,
                    "dropReset": d.dropReset,
                    "rehandshakes": d.rehandshakes,
                ]
            }
            out["device"] = device
            return out
        case "set_mute":
            guard let value = request["value"] as? Bool else { return ["error": "value(布尔)必填"] }
            guard mic.isOnline else { return ["error": "设备不在线"] }
            uplink?.sendControl(muted: value)
            return ["ok": true, "muted": value]
        case "set_ptt":
            guard let value = request["value"] as? Bool else { return ["error": "value(布尔)必填"] }
            pttEnabled = value
            return ["ok": true, "ptt": value]
        case "devices":
            refreshOutputs()
            return ["devices": outputs.map { $0.name }]
        case "logs":
            let tail = min(max(request["tail"] as? Int ?? 20, 1), 200)
            return ["logs": Array(logs.suffix(tail))]
        case "dump":
            guard mic.isOnline else { return ["error": "设备不在线"] }
            uplink?.sendDump()
            return ["ok": true, "note": "截图经串口日志回传(SCR 行),由串口侧重建"]
        case "capture":
            let seconds = min(max(request["seconds"] as? Int ?? 10, 1), 120)
            return await captureStream(seconds: seconds)
        case "metrics":
            let seconds = min(max(request["seconds"] as? Int ?? 10, 1), 300)
            return await collectMetrics(seconds: seconds)
        case "stress":
            let seconds = min(max(request["seconds"] as? Int ?? 30, 5), 600)
            let source = request["source"] as? String ?? "tts"
            return await runStress(seconds: seconds, source: source)
        default:
            return ["error": "未知命令;可用:status/set_mute/set_ptt/devices/logs/dump/capture/metrics/stress"]
        }
    }

    /// 采样 N 秒流指标,返回汇总(不动任何状态)。
    /// 录制设备音频 N 秒(16 kHz 单声道 S16LE,解码后 PCM)并落盘 WAV,返回路径与包络分析。
    private func captureStream(seconds: Int) async -> [String: Any] {
        guard mic.isOnline else { return ["error": "设备不在线"] }
        guard let uplink else { return ["error": "链路未启动"] }
        // 抽头回调在 Uplink 内部串行队列上触发,与这里的读取并发;用盒子封装
        // 加锁(直接在 async 上下文调 NSLock.lock/unlock 在 Swift 6 模式是错误,
        // 锁操作收进同步方法里)。否则读 count/拷贝时撞上 append 会撕裂 Data。
        let box = PCMBox()
        uplink.onAudioTap = { data in box.append(data) }
        for _ in 0..<seconds {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        uplink.onAudioTap = nil
        let captured = box.snapshot()
        let samples = captured.count / 2
        // 包络:20ms 一窗,数语音段
        let win = 320
        var bursts = 0, inBurst = false
        var peakDb = -120.0
        var i = 0
        while i + win <= samples {
            var sum = 0.0
            for j in 0..<win {
                let v = Double(Int16(littleEndian: captured.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: (i + j) * 2, as: Int16.self) }))
                sum += v * v
            }
            let db = 20 * log10(max((sum / Double(win)).squareRoot() / 32768, 1e-9))
            peakDb = max(peakDb, db)
            if db > -55 {
                if !inBurst { inBurst = true; bursts += 1 }
            } else {
                inBurst = false
            }
            i += win
        }
        let path = "/tmp/yahamic_stream_\(Int(Date().timeIntervalSince1970)).wav"
        var wav = Data()
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8((v >> 24) & 255)] }
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 255), UInt8((v >> 8) & 255)] }
        let bytes = UInt32(samples * 2)
        wav.append(contentsOf: [0x52, 0x49, 0x46, 0x46]); wav.append(contentsOf: le32(36 + bytes))
        wav.append(contentsOf: [0x57, 0x41, 0x56, 0x45])
        wav.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]); wav.append(contentsOf: le32(16))
        wav.append(contentsOf: le16(1)); wav.append(contentsOf: le16(1))
        wav.append(contentsOf: le32(16000)); wav.append(contentsOf: le32(32000))
        wav.append(contentsOf: le16(2)); wav.append(contentsOf: le16(16))
        wav.append(contentsOf: [0x64, 0x61, 0x74, 0x61]); wav.append(contentsOf: le32(bytes))
        wav.append(captured)
        try? wav.write(to: URL(fileURLWithPath: path))
        return ["path": path, "seconds": seconds, "samples": samples,
                "bursts": bursts, "peakDb": peakDb]
    }

    private func collectMetrics(seconds: Int) async -> [String: Any] {
        guard mic.isOnline else { return ["error": "设备不在线"] }
        var fps: [Int] = [], levels: [Double] = [], buffers: [Double] = []
        let startOverflows = mic.state.overflows, startUnderruns = mic.state.underruns
        let startDropped = mic.state.droppedFrames
        let startDiag = mic.state.diag
        for _ in 0..<seconds {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard mic.isOnline else { return ["error": "设备中途掉线"] }
            fps.append(mic.state.framesPerSecond)
            levels.append(mic.state.levelDb)
            buffers.append(mic.state.bufferMs)
        }
        return [
            "seconds": seconds,
            "fpsAvg": fps.reduce(0, +) / max(fps.count, 1),
            "fpsMin": fps.min() ?? 0,
            "levelDbMax": levels.max() ?? -120.0,
            "bufferMsAvg": buffers.reduce(0.0, +) / Double(max(buffers.count, 1)),
            "overflowsDelta": mic.state.overflows - startOverflows,
            "underrunsDelta": mic.state.underruns - startUnderruns,
            "droppedFrames": mic.state.droppedFrames,           // 链路全程累计丢帧/跳帧
            "droppedFramesDelta": mic.state.droppedFrames - startDropped,  // 采样窗口内新增
            // 采样窗口内的分阶段计数增量(零帧断点定位,口径见 Uplink.Diag)。
            "diagDelta": [
                "rxPackets": mic.state.diag.rxPackets - startDiag.rxPackets,
                "rxIgnoredInactive": mic.state.diag.rxIgnoredInactive - startDiag.rxIgnoredInactive,
                "audioPackets": mic.state.diag.audioPackets - startDiag.audioPackets,
                "decodeErrors": mic.state.diag.decodeErrors - startDiag.decodeErrors,
                "decodedFrames": mic.state.diag.decodedFrames - startDiag.decodedFrames,
                "enqueuedFrames": mic.state.diag.enqueuedFrames - startDiag.enqueuedFrames,
                "outputFrames": mic.state.diag.outputFrames - startDiag.outputFrames,
                "dropLate": mic.state.diag.dropLate - startDiag.dropLate,
                "dropDuplicate": mic.state.diag.dropDuplicate - startDiag.dropDuplicate,
                "dropJump": mic.state.diag.dropJump - startDiag.dropJump,
                "dropReset": mic.state.diag.dropReset - startDiag.dropReset,
                "rehandshakes": mic.state.diag.rehandshakes - startDiag.rehandshakes,
            ],
        ]
    }

    /// 压测:保存当前状态 → 常开麦克风(+可选 TTS 播放作音源)→ 采样 → 恢复。
    private func runStress(seconds: Int, source: String) async -> [String: Any] {
        guard mic.isOnline else { return ["error": "设备不在线"] }
        let savedPtt = pttEnabled
        let savedMuted = mic.state.muted
        log("压测开始:\(seconds)s,音源=\(source)(结束自动恢复原状态)")
        if pttEnabled { pttEnabled = false }       // 常开,保证全程送声
        uplink?.sendControl(muted: false)
        try? await Task.sleep(nanoseconds: 800_000_000)  // 等静音解除生效

        // TTS 音源:一段足够长的文本,结束时主动终止。
        var speaker: Process?
        if source == "tts" {
            // 编号句子:转写输出里"每句应出现一次",重复立即可数(之前的单句循环
            // 会把真实重复和听写重复混在一起,无法判读)。
            let lines = ["压力测试第一句,验证链路。", "第二句,验证渲染。",
                         "第三句,验证采集。", "第四句,验证缓冲。", "第五句,验证稳定性。"]
            let rounds = seconds / 4 + 1
            var text = ""
            for i in 0..<rounds { text += lines[i % lines.count] + " " }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            process.arguments = ["-v", "Tingting", text]
            try? process.run()
            speaker = process
        }

        var report = await collectMetrics(seconds: seconds)

        // 不在 MainActor 同步等待长文本 TTS 退出,避免压测结束时阻塞 UI 与控制接口。
        speaker?.terminate()
        // 恢复原状态(重新开启 push-to-talk 会自动回到静音待命)。
        pttEnabled = savedPtt
        if !savedPtt { uplink?.sendControl(muted: savedMuted) }
        report["source"] = source
        log("压测完成:\(report)")
        return report
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

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func openLog() {
        NSWorkspace.shared.open(logURL)
    }

    func quit() {
        NSApp.terminate(nil)
    }

    // capture 抽头的线程安全容器:锁操作收在同步方法里(async 上下文可直接调用)。
private final class PCMBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func append(_ chunk: Data) {
        lock.lock()
        storage.append(chunk)
        lock.unlock()
    }
    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
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
