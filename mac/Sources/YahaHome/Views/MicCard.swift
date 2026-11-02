import SwiftUI
import YahamicCore

/// 麦克风设备卡片:状态胶囊、名字、自定义电平条、玻璃静音主按钮。
/// 面板唯一主角区块:卡片内不再叠 glassEffect,玻璃质感只留给主按钮。
struct MicCard: View {
    let device: MicDevice
    let audioError: String?
    let pttEnabled: Bool
    let fnAvailable: Bool
    let onToggleMute: () -> Void

    /// 状态色四态:音频异常=橙、离线=灰、静音=红、开麦=绿,
    /// 统一引用文件级 MenuStatusTint,不与 ListenPermissionRow/PermissionCard 各自为政。
    private var statusTint: MenuStatusTint {
        if audioError != nil { return .warning }
        guard device.isOnline else { return .offline }
        return device.state.muted ? .muted : .live
    }

    /// 状态短词:与状态色一一对应,配合胶囊内图标形成 形状+文字+颜色 三重表达,
    /// 色盲场景下不依赖纯色也能读懂状态。
    private var statusWord: String {
        if audioError != nil { return "音频异常" }
        guard device.isOnline else { return "离线" }
        return device.state.muted ? "已静音" : "开麦"
    }

    /// 状态胶囊内的小图标:异常=警告三角、离线=斜杠 mic、静音=斜杠填充 mic、开麦=mic。
    private var statusIcon: String {
        if audioError != nil { return "exclamationmark.triangle.fill" }
        guard device.isOnline else { return "mic.slash" }
        return device.state.muted ? "mic.slash.fill" : "mic.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: PanelSpacing.row) {
                Image(systemName: device.isOnline
                      ? (device.state.muted ? "mic.slash.fill" : "mic.fill") : "mic.slash")
                    .font(.system(size: 22))
                    .foregroundStyle(statusTint.color)
                    .frame(width: 28)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: device.state.muted)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: PanelSpacing.inner) {
                        Text(device.title).font(.subheadline.weight(.semibold))
                        statusCapsule
                        Text(device.kind).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Text(device.statusLine).font(.caption).foregroundStyle(.secondary)
                    if device.isOnline {
                        Text(device.state.address).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                // 面板唯一强调元素:玻璃主按钮,着色跟随状态色。
                Button(device.state.muted ? "开麦" : "静音", action: onToggleMute)
                    .buttonStyle(.glassProminent)
                    .tint(statusTint.color)
                    .controlSize(.regular)
                    .disabled(!device.isOnline)
            }
            .animation(.snappy(duration: 0.2), value: statusTint)
            levelBar
            if let audioError {
                Label(audioError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(MenuStatusTint.warning.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if device.isOnline && pttEnabled && fnAvailable {
                Text(device.state.muted ? "按住 Fn 键开始讲话" : "松开 Fn 即静音")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(PanelSpacing.cardPadding)
        .background(RoundedRectangle(cornerRadius: PanelSpacing.cardRadius).fill(Color(nsColor: .controlBackgroundColor)))
        // 卡片内提示行显隐过渡:随权限/PTT 状态淡入+顶部移入,可打断
        .animation(.snappy(duration: 0.25), value: audioError != nil)
        .animation(.snappy(duration: 0.25), value: device.isOnline && pttEnabled && fnAvailable)
    }

    /// 语义状态胶囊:Capsule 底 = 状态色 12% 淡填充(MenuStatusTint.fill),
    /// 内容 = 小 SF Symbol + 短词,文字 caption 字重 .medium。
    private var statusCapsule: some View {
        Label(statusWord, systemImage: statusIcon)
            .font(.caption.weight(.medium))
            .foregroundStyle(statusTint.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(statusTint.fill))
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
