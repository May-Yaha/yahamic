import SwiftUI
import DeskCore

// 菜单栏下拉面板,控制中心风格:设备模块(现在只有麦克风)、开关小方块、输出、日志。
struct MenuPanelView: View {
    @EnvironmentObject private var model: HomeModel
    @State private var showLogs = false

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
                    onToggleMute: model.toggleMute,
                    onSetPaused: model.setLinkPaused,
                    onReconnect: model.reconnect,
                    onOpenBluetooth: model.openBluetoothSettings)
            CloudCard(cloud: model.cloud)
            settings
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
            Image(systemName: "house.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Yaha Desk").font(.headline)
                Text("yahaops 桌面设备").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("v\(model.version)").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: PanelSpacing.section) {
            HStack(spacing: PanelSpacing.section) {
                Toggle("按住讲话", isOn: $model.pttEnabled)
                    .toggleStyle(TileToggleStyle(
                        symbol: "hand.tap.fill",
                        detail: model.pttEnabled ? (model.fnAvailable ? "按住才送声" : "等待权限…") : "麦克风常开"))
                Toggle("开机自启", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }))
                    .toggleStyle(TileToggleStyle(symbol: "power"))
            }
            Toggle("本地转文字", isOn: $model.localSTTEnabled)
                .toggleStyle(TileToggleStyle(symbol: "text.bubble.fill", detail: model.localSTTState.detail))
            if model.pttEnabled {
                HStack(spacing: PanelSpacing.row) {
                    CircleIcon(symbol: "keyboard", tint: .accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("讲话键").font(.subheadline.weight(.medium))
                        Picker("讲话键", selection: $model.talkKey) {
                            ForEach(TalkKey.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                    }
                    Spacer(minLength: 0)
                    Text("HHKB 的 Fn 收不到").font(.caption2).foregroundStyle(.tertiary)
                }
                .controlTile()
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            HStack(spacing: PanelSpacing.row) {
                CircleIcon(symbol: "speaker.wave.2.fill", tint: .accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("输出到").font(.subheadline.weight(.medium))
                    Picker("输出到", selection: $model.outputDeviceName) {
                        ForEach(deviceNames, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
                Spacer(minLength: 0)
            }
            .controlTile()
            if !model.installedIMEs.isEmpty { imeTile }
        }
        // 权限行显隐过渡:淡入+顶部移入,可打断
        .animation(.snappy(duration: 0.25), value: model.pttEnabled)
        .animation(.snappy(duration: 0.25), value: model.fnAvailable)
        .animation(.snappy(duration: 0.25), value: model.listenPermission.granted)
    }

    /// 听写输入法一键接入:切系统默认输入 + 打开输入法设置;快捷键只能用户自己设,这里给出要设成什么。
    private var imeTile: some View {
        let linked = model.defaultInput == model.outputDeviceName
        return VStack(alignment: .leading, spacing: PanelSpacing.row) {
            HStack(spacing: PanelSpacing.row) {
                CircleIcon(symbol: "character.bubble.fill", tint: linked ? .green : nil)
                VStack(alignment: .leading, spacing: 1) {
                    Text("听写输入法").font(.subheadline.weight(.medium))
                    Text("系统输入:\(model.defaultInput)").font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                ForEach(model.installedIMEs, id: \.self) { ime in
                    Button("接入\(ime.title)") { model.connectIME(ime) }.controlSize(.small)
                }
            }
            if linked {
                Text("在输入法设置里:麦克风选「\(model.outputDeviceName)」或「跟随系统」,语音输入快捷键设为长按\(model.talkKey.title)")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let previous = model.previousInput {
                    Button("还原系统输入为 \(previous)") { model.restoreInput() }.controlSize(.small)
                }
            }
        }
        .controlTile()
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
