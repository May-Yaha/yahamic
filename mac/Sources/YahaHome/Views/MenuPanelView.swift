import SwiftUI
import YahamicCore

// 菜单栏下拉面板:设备卡片(按设备分区,现在只有麦克风)、设置、日志。
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
        .animation(.snappy(duration: 0.25), value: model.blackHoleMissing)
        .onAppear {
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

            PairingRow(code: model.pairingCode, deviceOnline: model.mic.isOnline,
                       onCopy: model.copyPairingCode, onRegenerate: model.regeneratePairingCode)

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
