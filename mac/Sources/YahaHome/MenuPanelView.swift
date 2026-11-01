import SwiftUI
import YahamicCore

/// 语义状态色收口:菜单面板内所有状态色只允许从这里取。
/// 四态映射:开麦=系统绿、已静音=系统红、离线=系统灰、权限或音频异常=系统橙。
/// 全部基于系统语义色(.green/.red/.gray/.orange 本身就是系统动态色),
/// 深浅色外观下的对比度与色相交由系统自动适配;填充一律用 opacity 调深浅,
/// 不引入任何硬编码 RGB,避免风格漂移与深色模式翻车。
private enum MenuStatusTint {
    case live       // 开麦中
    case muted      // 已静音
    case offline    // 设备离线
    case warning    // 权限缺失或音频异常

    /// 主色调:状态点、图标、电平条 tint。
    var color: Color {
        switch self {
        case .live: return .green
        case .muted: return .red
        case .offline: return .gray
        case .warning: return .orange
        }
    }

    /// 填充色:同一语义色 + opacity,保证深浅色下都是「淡状态色底」。
    var fill: Color { color.opacity(0.12) }
}

// 间距 token:大区块 12、组内行距 8、元素内部 4;卡片 padding 12、圆角 12。
// 同种关系同种间距,分组靠 caption 小节标签 + 留白表达,不用分隔线。
private enum PanelSpacing {
    static let section: CGFloat = 12   // 大区块之间
    static let row: CGFloat = 8        // 组内行距
    static let inner: CGFloat = 4      // 元素内部
    static let cardPadding: CGFloat = 12
    static let cardRadius: CGFloat = 12
}

// 菜单栏下拉面板:设备卡片(按设备分区,现在只有麦克风)、设置、日志。
struct MenuPanelView: View {
    @EnvironmentObject private var model: HomeModel
    @State private var showLogs = false
    @State private var tokenDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: PanelSpacing.section) {
            header
            if model.needsAccessibility {
                PermissionCard(onRequest: model.requestAccessibility,
                               onOpen: model.openAccessibilitySettings)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            MicCard(device: model.mic, audioError: model.audioError,
                    pttEnabled: model.pttEnabled, fnAvailable: model.fnAvailable,
                    onToggleMute: model.toggleMute)
            sectionLabel("设置")
            settings
            footer
        }
        .padding(PanelSpacing.cardPadding)
        .frame(width: 330)
        // 权限卡片显隐过渡:snappy 可打断,不阻塞操作
        .animation(.snappy(duration: 0.25), value: model.needsAccessibility)
        .onAppear {
            tokenDraft = model.token
            model.refreshOutputs()
        }
    }

    /// caption 小节标签:分组手段,靠标签 + 留白表达层级。
    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.caption).foregroundStyle(.secondary)
    }

    private var header: some View {
        HStack(spacing: PanelSpacing.row) {
            Image(systemName: "house.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Yaha 家居").font(.headline)
                Text("家庭硬件控制中心").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("v\(model.version)").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: PanelSpacing.row) {
            Toggle(isOn: $model.pttEnabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("按住 Fn 讲话")
                    Text(model.pttEnabled
                         ? (model.fnAvailable ? "平时静音,按住 Fn 才送声" : "等待辅助功能权限…")
                         : "关闭 = 麦克风常开")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            if model.pttEnabled && !model.fnAvailable {
                Button("打开辅助功能设置…") { model.openAccessibilitySettings() }
                    .controlSize(.small)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if model.pttEnabled {
                ListenPermissionRow(permission: model.listenPermission,
                                    onRequest: model.requestListenPermission,
                                    onOpen: model.openListenPermissionSettings)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Picker("输出到", selection: $model.outputDeviceName) {
                ForEach(deviceNames, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)

            HStack(spacing: PanelSpacing.inner) {
                SecureField("配对码(可选,需与设备配网页一致)", text: $tokenDraft)
                    .textFieldStyle(.roundedBorder)
                Button("应用") {
                    model.token = tokenDraft
                    model.applyToken()
                }
                .disabled(tokenDraft == model.token)
            }

            Toggle("开机自启", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.switch)
        }
        // 设置区显隐过渡:权限/PTT 状态变化时淡入+顶部移入,可打断
        .animation(.snappy(duration: 0.25), value: model.pttEnabled)
        .animation(.snappy(duration: 0.25), value: model.fnAvailable)
    }

    private var deviceNames: [String] {
        var names = model.outputs.map(\.name)
        if !names.contains(model.outputDeviceName) { names.insert(model.outputDeviceName, at: 0) }
        return names
    }

    /// footer 单行:左侧「日志」DisclosureGroup,右侧「退出」按钮。
    private var footer: some View {
        HStack(alignment: .top, spacing: PanelSpacing.row) {
            DisclosureGroup(isExpanded: $showLogs) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.logs.suffix(12).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 120)
                Button("打开完整日志") { model.openLog() }.controlSize(.small)
            } label: {
                Text("日志").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("退出") { model.quit() }.controlSize(.small)
        }
    }
}

/// 键盘监听权限状态行:与 ListenPermission 枚举一一对应(正常/缺输入监听/
/// 缺辅助功能/两者都缺),缺权限时提供「请求授权/重试」与「打开设置」。
struct ListenPermissionRow: View {
    let permission: ListenPermission
    let onRequest: () -> Void
    let onOpen: () -> Void

    /// 权限行状态色:正常=开麦绿,缺任意权限=告警橙,统一走文件级 helper。
    private var statusTint: MenuStatusTint { permission.granted ? .live : .warning }

    private var statusText: String {
        switch permission {
        case .ok: return "正常"
        case .missingInputMonitoring: return "缺输入监听"
        case .missingAccessibility: return "缺辅助功能"
        case .missingBoth: return "缺辅助功能与输入监听"
        }
    }

    var body: some View {
        HStack(spacing: PanelSpacing.inner) {
            Circle()
                .fill(statusTint.color)
                .frame(width: 7, height: 7)
            Text("键盘监听权限").font(.caption)
            Text(statusText).font(.caption)
                .foregroundStyle(permission.granted ? Color.secondary : statusTint.color)
            Spacer()
            if !permission.granted {
                Button("请求授权/重试", action: onRequest).controlSize(.small)
                Button("打开设置", action: onOpen).controlSize(.small)
            }
        }
    }
}

/// 权限申请卡片:「按住 Fn 讲话」缺辅助功能权限时显示在最上面。
struct PermissionCard: View {
    let onRequest: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("「按住 Fn 讲话」需要键盘权限", systemImage: "lock.shield.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MenuStatusTint.warning.color)
            Text("系统已弹出授权确认(或在 系统设置 → 隐私与安全性 → 辅助功能 里)。允许后 2 秒内自动恢复,无需重启。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("再次申请权限", action: onRequest).controlSize(.small)
                Button("打开系统设置", action: onOpen).controlSize(.small)
            }
        }
        .padding(PanelSpacing.cardPadding)
        .background(RoundedRectangle(cornerRadius: PanelSpacing.cardRadius).fill(MenuStatusTint.warning.fill))
    }
}

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
