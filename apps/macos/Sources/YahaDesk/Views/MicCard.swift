import SwiftUI
import DeskCore

/// 麦克风模块(控制中心风格):圆形图标即静音开关,右侧信号,下方电平条与提示。
struct MicCard: View {
    let device: MicDevice
    let audioError: String?
    let pttEnabled: Bool
    let fnAvailable: Bool
    let talkKeyName: String
    let phoneMic: Bool
    let onSelectSource: (Bool) -> Void
    let onToggleMute: () -> Void
    let onSetPaused: (Bool) -> Void
    let onReconnect: () -> Void
    let onOpenBluetooth: () -> Void

    /// 状态色四态:音频异常=橙、离线/暂停=灰、静音=红、开麦=绿,
    /// 统一引用文件级 MenuStatusTint,与 PermissionCard 同一套色。
    private var statusTint: MenuStatusTint {
        if device.paused { return .offline }
        if audioError != nil { return .warning }
        guard device.isOnline else { return .offline }
        return device.state.muted ? .muted : .live
    }

    /// 状态短词:与状态色一一对应,配合胶囊内图标形成 形状+文字+颜色 三重表达,
    /// 色盲场景下不依赖纯色也能读懂状态。
    private var statusWord: String {
        if device.paused { return "已暂时断开" }
        if audioError != nil { return "音频异常" }
        guard device.isOnline else { return "离线" }
        return device.state.muted ? "已静音" : "开麦"
    }

    /// 状态胶囊内的小图标:暂停=断链、异常=警告三角、离线=斜杠 mic、静音=斜杠填充 mic、开麦=mic。
    private var statusIcon: String {
        if device.paused { return "pause.circle" }
        if audioError != nil { return "exclamationmark.triangle.fill" }
        guard device.isOnline else { return "mic.slash" }
        return device.state.muted ? "mic.slash.fill" : "mic.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: PanelSpacing.row + 2) {
                // 控制中心式主开关:圆形图标本身就是静音按钮,亮色 = 开麦。
                Button(action: onToggleMute) {
                    CircleIcon(symbol: statusIcon,
                               tint: device.isOnline ? statusTint.color : nil, size: 44)
                        .symbolEffect(.bounce, value: device.state.muted)
                        // 对讲机式光环:外圈状态色描边,送声时随电平发光。
                        .padding(3)
                        .overlay(Circle().strokeBorder(statusTint.color.opacity(device.isOnline ? 0.4 : 0.15), lineWidth: 2))
                        .shadow(color: statusTint == .live ? statusTint.color.opacity(0.25 + 0.5 * device.levelFraction) : .clear,
                                radius: 3 + 8 * device.levelFraction)
                        .animation(.easeOut(duration: 0.15), value: device.levelFraction)
                }
                .buttonStyle(.plain)
                .disabled(!device.isOnline)
                .help(device.state.muted ? "开麦" : "静音")
                .accessibilityLabel(device.state.muted ? "开麦" : "静音")
                VStack(alignment: .leading, spacing: 2) {
                    Text(phoneMic ? "手机麦克风" : device.title).font(.headline)
                    Text(statusWord).font(.subheadline.weight(.semibold)).foregroundStyle(statusTint.color)
                }
                Spacer()
                if device.isOnline {
                    VStack(alignment: .trailing, spacing: 2) {
                        if let battery = device.battery {
                            Label(battery.text, systemImage: battery.symbol)
                                .font(.caption2).foregroundStyle(battery.low ? MenuStatusTint.warning.color : .secondary)
                        }
                        Label("\(device.state.rssi) dBm", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(device.kind).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                // 让出设备唯一的蓝牙连接给 iPhone 配置;再点恢复。
                // 离线时也要显示:配对丢失时 Mac 仍在反复占着连接。
                Button {
                    onSetPaused(!device.paused)
                } label: {
                    Image(systemName: device.paused ? "arrow.triangle.2.circlepath" : "eject")
                }
                .buttonStyle(.borderless)
                .help(device.paused ? "恢复连接" : "暂时断开(在 iPhone 上配置时用)")
                .accessibilityLabel(device.paused ? "恢复连接" : "暂时断开")
            }
            .animation(.snappy(duration: 0.2), value: statusTint)
            // 声源一键切换;iPhone 上点开/停止也会自动跟过来(见 HomeModel.phoneMicChanged)。
            Picker("声源", selection: Binding(get: { phoneMic }, set: onSelectSource)) {
                Label("设备", systemImage: "mic.fill").tag(false)
                Label("手机", systemImage: "iphone.gen3").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(device.paused)
            levelBar
            if let audioError {
                Label(audioError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(MenuStatusTint.warning.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Text(hint).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !device.isOnline && !device.paused {
                HStack {
                    Button("重新连接", action: onReconnect)
                    if device.state.pairingLost { Button("打开蓝牙设置", action: onOpenBluetooth) }
                }
                .controlSize(.small)
            }
        }
        .controlTile()
        .animation(.snappy(duration: 0.25), value: audioError != nil)
    }

    /// 底部一行:离线给连接指引,在线给 Fn 提示,送声时给电平与帧率。
    private var hint: String {
        if phoneMic, !device.isOnline, !device.paused {
            return "在 iPhone 的 Yaha Desk 首页把声源切到“手机”;首次连接两边确认配对"
        }
        guard device.isOnline, !device.paused else { return device.statusLine }
        if !device.state.muted { return device.statusLine }
        return pttEnabled && fnAvailable ? "按住 \(talkKeyName) 开始讲话" : "点左侧图标开麦"
    }

    /// 自定义电平条:ZStack 双层 Capsule,底层 .quinary 填充、前景按 levelFraction
    /// 宽度填充并 clipShape 圆角,高 6pt,着色走语义 helper,保留 0.15s easeOut 电平动画。
    private var levelBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quinary)
                Capsule()
                    .fill(statusTint.color)
                    .frame(width: geo.size.width * device.levelFraction)
                    .clipShape(Capsule())
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.15), value: device.levelFraction)
    }
}
