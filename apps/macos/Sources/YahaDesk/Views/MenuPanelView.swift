import SwiftUI
import DeskCore

// 菜单栏下拉面板,控制中心风格:提醒 → 麦克风(主角)→ 讲话 → 转文字 → 输出 → 联网入口与日志。
struct MenuPanelView: View {
    @EnvironmentObject private var model: HomeModel
    @State private var showLogs = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: PanelSpacing.section) {
            header
            if model.blackHoleMissing {
                BlackHoleCard(state: model.blackHoleInstall,
                              onInstall: model.installBlackHole,
                              onCopy: model.copyBlackHoleCommand,
                              onOpenTerminal: model.openTerminal)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if model.needsAccessibility {
                PermissionCard(permission: model.listenPermission,
                               onRequest: model.requestListenPermission,
                               onOpen: model.openListenPermissionSettings)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            MicCard(device: model.mic, audioError: model.audioError,
                    pttEnabled: model.pttEnabled, fnAvailable: model.fnAvailable,
                    talkKeyName: model.talkKey.title,
                    phoneMic: model.phoneMic,
                    onSelectSource: { model.selectSource(phone: $0) },
                    onToggleMute: model.toggleMute,
                    onSetPaused: model.setLinkPaused,
                    onReconnect: model.reconnect,
                    onOpenBluetooth: model.openBluetoothSettings)
            settings
            Divider()
            CloudCard(cloud: model.cloud)
            footer
        }
        .padding(PanelSpacing.cardPadding)
        .frame(width: 320)
        // 权限卡片显隐过渡:snappy 可打断,不阻塞操作
        .animation(.snappy(duration: 0.25), value: model.needsAccessibility)
        .animation(.snappy(duration: 0.25), value: model.blackHoleMissing)
        .onAppear {
            model.refreshOutputs()
        }
    }

    private var header: some View {
        HStack(spacing: PanelSpacing.row) {
            Text("Yaha Desk").font(.headline)
            Text("v\(model.version)").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Button { openWindow(id: "device-setup"); NSApp.activate() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("设备设置")
                .accessibilityLabel("设备设置")
        }
    }

    /// 按任务顺序分三组:讲话 → 转文字 → 输出。只在某个选项下才有意义的开关跟着它显隐,不常驻成灰块。
    private var settings: some View {
        VStack(alignment: .leading, spacing: PanelSpacing.row) {
            SectionTitle("讲话")
            talkTile
            SectionTitle("转文字").padding(.top, PanelSpacing.inner)
            VStack(alignment: .leading, spacing: PanelSpacing.inner) {
                Picker("转文字", selection: dictation) {
                    ForEach(Dictation.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(dictationDetail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.leading, PanelSpacing.inner)
            }
            if model.localSTTEnabled {
                HStack(spacing: PanelSpacing.section) {
                    Toggle("二次确认", isOn: $model.dictationConfirm)
                        .toggleStyle(TileToggleStyle(
                            symbol: "checkmark.bubble.fill",
                            detail: model.dictationConfirm ? "改完回车插入" : "说完直接插入", color: .cyan))
                    Toggle("AI 润色", isOn: $model.aiPolishEnabled)
                        .toggleStyle(TileToggleStyle(
                            symbol: "wand.and.sparkles",
                            detail: !model.aiPolish.hasKey ? "先在设置里填 Key"
                                : model.aiPolishEnabled ? "整理后插入" : "插入原文", color: .orange))
                        .disabled(!model.aiPolish.hasKey)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            SectionTitle("视频字幕").padding(.top, PanelSpacing.inner)
            HStack(spacing: PanelSpacing.section) {
                Toggle("视频字幕", isOn: $model.liveCaptionEnabled)
                    .toggleStyle(TileToggleStyle(
                        symbol: "captions.bubble.fill",
                        detail: model.liveCaptionEnabled ? "识别本机播放的声音" : "关闭", color: .teal))
                if model.liveCaptionEnabled {
                    Toggle("翻译", isOn: $model.captionTranslate)
                        .toggleStyle(TileToggleStyle(
                            symbol: "character.bubble.fill",
                            detail: model.captionTranslate ? "译成" + captionTargetName : "只显示原文", color: .indigo))
                        .transition(.opacity)
                }
            }
            if model.liveCaptionEnabled && model.captionTranslate {
                Picker("译成", selection: $model.captionTarget) {
                    ForEach(HomeModel.captionTargets, id: \.id) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            SectionTitle("输出").padding(.top, PanelSpacing.inner)
            HStack(spacing: PanelSpacing.row) {
                CircleIcon(symbol: "speaker.wave.2.fill", tint: .accentColor)
                Text("输出到").font(.subheadline.weight(.medium))
                Spacer(minLength: 0)
                Picker("输出到", selection: $model.outputDeviceName) {
                    ForEach(deviceNames, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            .controlTile()
            // 同时作用于 BlackHole 一路和本地转文字,所以放输出组。
            Toggle("只留本人声音", isOn: $model.ownVoiceOnly)
                .toggleStyle(TileToggleStyle(
                    symbol: "person.wave.2.fill",
                    detail: !model.voiceProfile.ready ? "先在设置里录声纹"
                        : model.ownVoiceOnly ? "过滤他人语段" : "不过滤", color: .purple))
                .disabled(!model.voiceProfile.ready)
        }
        .animation(.snappy(duration: 0.25), value: model.pttEnabled)
        .animation(.snappy(duration: 0.25), value: model.localSTTEnabled)
        .animation(.snappy(duration: 0.25), value: model.liveCaptionEnabled)
        .animation(.snappy(duration: 0.25), value: model.captionTranslate)
    }

    private var captionTargetName: String {
        HomeModel.captionTargets.first { $0.id == model.captionTarget }?.name ?? model.captionTarget
    }

    /// 按住讲话开关 + 讲话键合成一块:圆形图标是开关,打开后右侧可选讲话键。
    private var talkTile: some View {
        HStack(spacing: PanelSpacing.row) {
            Button { model.pttEnabled.toggle() } label: {
                HStack(spacing: PanelSpacing.row) {
                    CircleIcon(symbol: "hand.tap.fill", tint: model.pttEnabled ? .accentColor : nil)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("按住讲话").font(.subheadline.weight(.medium))
                        Text(model.pttEnabled ? (model.fnAvailable ? "按住才送声" : "等待键盘权限…") : "麦克风常开")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(model.pttEnabled ? "开" : "关")
            if model.pttEnabled {
                Picker("讲话键", selection: $model.talkKey) {
                    ForEach(TalkKey.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .help("讲话键;HHKB 的 Fn 收不到,换一个修饰键")
                .transition(.opacity)
            }
        }
        .controlTile()
    }

    private enum Dictation: CaseIterable {
        case off, local, doubao
        var title: String {
            switch self {
            case .off: "关"
            case .local: "本地"
            case .doubao: "豆包"
            }
        }
    }

    /// 本地转文字与豆包互斥(见 HomeModel),合成一个三选一。
    private var dictation: Binding<Dictation> {
        Binding {
            model.localSTTEnabled ? .local : model.doubaoEnabled ? .doubao : .off
        } set: {
            switch $0 {
            case .off: model.localSTTEnabled = false; model.doubaoEnabled = false
            case .local: model.localSTTEnabled = true
            case .doubao: if model.doubaoInstalled { model.doubaoEnabled = true }
            }
        }
    }

    private var dictationDetail: String {
        if model.localSTTEnabled { return "本地 Qwen3 · " + model.localSTTState.detail }
        if model.doubaoEnabled { return "豆包输入法识别上屏" }
        return model.doubaoInstalled ? "只送声,不转文字" : "只送声,不转文字;豆包输入法本机未安装"
    }

    private var deviceNames: [String] {
        var names = model.outputs.map(\.name)
        if !names.contains(model.outputDeviceName) { names.insert(model.outputDeviceName, at: 0) }
        return names
    }

    /// footer 单行:左侧「日志」DisclosureGroup,右侧开机自启与「退出」。
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
                HStack {
                    Button("打开完整日志") { model.openLog() }.controlSize(.small)
                    Button("清理日志") { model.clearLog() }.controlSize(.small)
                }
            } label: {
                Text("日志").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            // 一次性配置,放底部不和高频开关抢位置。
            Toggle("开机自启", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.checkbox).font(.caption).controlSize(.small)
            Button("退出") { model.quit() }.controlSize(.small)
        }
    }
}
