import Foundation
import os
import YahamicCore

// 权限诊断日志通道:统一日志系统里 subsystem 过滤可见(启动状态、状态转换)。
let fnPermLog = Logger(subsystem: "com.yaha.yahamicd", category: "fn-permission")

setvbuf(stdout, nil, _IOLBF, 0)  // launchd 下 stdout 不是终端,强制行缓冲

// yahamicd:Mac mini 端的无线麦克风接收守护进程。
//   yahamicd [--port 7717] [--token 配对码] [--device BlackHole]
//           [--jitter-ms 60] [--list-devices] [--verbose]

var port: UInt16 = 7717
var token: String?
var deviceNeedle = "BlackHole"
var jitterMs = 60
var verbose = false
var listDevices = false
var pushToTalk = true

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--port":
        if let p = UInt16(args.first ?? "") { port = p; args.removeFirst() }
    case "--token":
        if let t = args.first { token = t; args.removeFirst() }
    case "--device":
        if let d = args.first, !d.isEmpty { deviceNeedle = d; args.removeFirst() }
    case "--jitter-ms":
        if let j = Int(args.first ?? "") { jitterMs = max(20, min(j, 500)); args.removeFirst() }
    case "--list-devices":
        listDevices = true
    case "--no-ptt":
        pushToTalk = false
    case "--verbose", "-v":
        verbose = true
    case "--help", "-h":
        print("""
        yahamicd —— Mac mini 的无线麦克风接收端(与 yahamic 固件配套)

        用法: yahamicd [选项]
          --port <N>        UDP 端口与广播端口(默认 7717)
          --token <配对码>   与设备配网页里一致的配对码(建议设置)
          --device <名称>   虚拟麦克风设备名(默认含 "BlackHole" 的第一个)
          --jitter-ms <N>   抖动缓冲目标毫秒数(默认 60,越小越低延迟)
          --no-ptt          关闭「按住 Fn 讲话」(默认开启:设备平时静音)
          --list-devices    列出可写的输出设备后退出
          --verbose, -v     每秒打印电平/缓冲/丢包状态行
        """)
        exit(0)
    default:
        print("未知参数:\(arg)(--help 看用法)")
        exit(2)
    }
}

if listDevices {
    print("可写的输出设备(虚拟麦克风 = 它们的「输出」侧):")
    for device in outputDevices().sorted(by: { $0.name < $1.name }) {
        let padded = device.name.padding(toLength: 30, withPad: " ", startingAt: 0)
        print("  \(padded) \(Int(device.sampleRate)) Hz")
    }
    exit(0)
}

guard let device = findOutputDevice(named: deviceNeedle) else {
    print("""
    找不到输出设备「\(deviceNeedle)」。

    yahamicd 把设备音频写进虚拟麦克风的输出侧,应用再选它当输入。最常用的
    虚拟麦克风是 BlackHole,安装:

        brew install blackhole-2ch

    装好后用 --list-devices 查看,或用 --device 指定其它环回设备。
    """)
    exit(1)
}

let jitter = JitterBuffer(ms: jitterMs * 4)  // 容量给目标水位的 4 倍
guard let sink = AudioSink(device: device, jitter: jitter, targetMs: jitterMs) else {
    print("无法启动音频设备「\(device.name)」(可能被独占或权限受限)")
    exit(1)
}

print("""
yahamicd 已启动
  虚拟麦克风: \(sink.deviceName)(\(Int(sink.sampleRate)) Hz)
  抖动缓冲:   \(jitterMs) ms
  配对码:     \(token ?? "未设置(局域网信任模式,建议用 --token)")
设备开机后会自动找到这台 Mac。Ctrl-C 退出。
""")

// SIGINT/SIGTERM 走 DispatchSource 在主队列处理(signal() 的 C 回调里不能
// 安全跑 Swift 代码),退出前显式停 Fn tap 与链路,不依赖进程终止兜底。
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
var signalSources: [DispatchSourceSignal] = []  // 必须持有,否则 source 被释放即取消

let uplink = Uplink(port: port, token: token, jitter: jitter, verbose: verbose,
                    pushToTalk: pushToTalk)
uplink.audioSink = sink  // 接线:断供事件计数需要「流活跃」标记

// 低噪声诊断汇总:连接期间每 30 秒一行(--verbose 的每秒状态行之外的常开通道)。
// 凭计数区分「收不到包」(收包/音频包不涨)与「解码/序号丢弃」(音频包涨但
// 解码/入队不涨,看 迟/重/跳/置 哪类在涨);异常时 Uplink 另有 ≥10s 节流的即时日志。
var lastDiagSummaryAt = Date.distantPast
uplink.onState = { state in
    guard state.connected else { return }
    let now = Date()
    guard now.timeIntervalSince(lastDiagSummaryAt) >= 30 else { return }
    lastDiagSummaryAt = now
    let d = state.diag
    let time = DateFormatter.localizedString(from: now, dateStyle: .none, timeStyle: .medium)
    print(String(
        format: "[%@] 诊断 │ 收包 %d(无效 %d 非活跃 %d)│ 音频包 %d │ 解码 %d(失败 %d)│ 入队 %d │ 输出 %d │ 序号丢 迟%d 重%d 跳%d 置%d │ 重握手 %d",
        time, d.rxPackets, d.rxInvalid, d.rxIgnoredInactive, d.audioPackets,
        d.decodedFrames, d.decodeErrors, d.enqueuedFrames, d.outputFrames,
        d.dropLate, d.dropDuplicate, d.dropJump, d.dropReset, d.rehandshakes))
    fflush(stdout)
}
uplink.start()

// 仪表盘上报(协议 type 7):设备空闲屏的大字时钟 + 2x2 仪表(CPU/内存/
// 键鼠电量)数据源,3s 级周期采样下发。
let metricsCollector = MetricsCollector()
// why 挂在主 RunLoop Timer 而不是另开 DispatchQueue 定时器:采集
// (host_processor_info / host_statistics64 / IOKit)与网络写分离——Timer 只负责
// 采样,真正的 socket 写由 Uplink.sendDashboard 内部投递到 uplink 的串行队列
// 执行,与 0.5s keepalive、control 等所有下行帧在同一队列串行化,不会出现
// 两条并发路径向同一 socket 写包造成帧交织;且握手未完成时 sendDashboard
// 按 activeAddr 判空直接丢弃,天然满足「仅握手完成后发送」。
var metricsTimer: Timer? = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
    uplink.sendDashboard(metricsCollector.sample())
}
metricsTimer?.fire()  // 立即采一帧;未握手时会被静默丢弃,等下个周期

// 全局变量持有监听器,退出前经信号处理器显式 stop();即使遗漏,
// FnListener 内部的 passRetained 自保也保证不会野指针崩溃(只是泄漏)。
var fnListener: FnListener?
var fnPermTimer: Timer?
var lastFnPermission: ListenPermission?

// 预检权限并在已授权时(重)建 tap。权限状态转换都写日志;授权后经低频
// 重查自动恢复,无需重启进程,恢复后立即停止轮询。
func tryStartFnListener(uplink: Uplink) {
    guard pushToTalk, fnListener == nil else { return }
    let status = ListenPermission.preflight()
    if status != lastFnPermission {
        lastFnPermission = status
        fnPermLog.log("键盘事件权限状态:\(status.description, privacy: .public)")
        print("  键盘事件权限: \(status.description)")
        fflush(stdout)
    }
    guard status.granted else { return }
    if let listener = FnListener(onChange: { down in
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        print("[\(time)] Fn \(down ? "按下 → 设备送声" : "松开 → 设备静音")")
        fflush(stdout)
        uplink.sendControl(muted: !down)  // 按住 = 讲话,松开 = 静音
    }) {
        fnListener = listener
        fnPermLog.log("键盘事件权限已齐备,Fn tap 已建立")
        fnPermTimer?.invalidate()  // 授权恢复,停止轮询
        fnPermTimer = nil
    } else {
        // tapCreate 失败(权限刚被收回等):FnListener 内部已成对 release,无残留。
        fnPermLog.error("Fn tap 创建失败(权限预检为已授权)")
    }
}

if pushToTalk {
    let status = ListenPermission.preflight()
    lastFnPermission = status
    fnPermLog.log("启动时键盘事件权限:\(status.description, privacy: .public)")
    if status.granted {
        tryStartFnListener(uplink: uplink)
        if fnListener != nil {
            print("  按住 Fn:  已启用(按住讲话,松开静音)\n")
        }
    } else {
        print("""
        ⚠️ 「按住 Fn 讲话」不可用:\(status.description)。
        \(status.guidance),加入并勾选 yahamicd(或它所在的终端 App)。
        授权后 5 秒内自动恢复,无需重启;设备仍可用自身按键静音。
        改用其它工具启动时注意继承同样的授权。
        """)
        fflush(stdout)
        _ = ListenPermission.request()  // 缺哪项申请哪项(可能弹系统框)
        fnPermTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            tryStartFnListener(uplink: uplink)
        }
    }
}

for sig in [SIGINT, SIGTERM] {
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        fnListener?.stop()  // 显式摘掉 tap:invalidate + 成对 release
        fnPermTimer?.invalidate()
        metricsTimer?.invalidate()
        uplink.stop()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

RunLoop.main.run()  // 转动主 RunLoop:Fn 事件源在这里回调
