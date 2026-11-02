import SwiftUI

/// 缺 BlackHole 时显示在面板最上面:一键安装为主路径,复制终端命令为备选。
struct BlackHoleCard: View {
    let state: BlackHoleInstallState
    let onInstall: () -> Void
    let onCopy: () -> Void
    let onOpenTerminal: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("还差一步:安装虚拟麦克风 BlackHole", systemImage: "waveform.badge.plus")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text("设备的声音经 BlackHole 交给其他应用(听写、会议、录音)。免费开源,约 100 KB,只需装一次。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(action: onInstall) {
                    Text(state.busy ? "安装中…" : "一键安装")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
                .disabled(state.busy)
                if state.busy {
                    ProgressView().controlSize(.small)
                    Text(progressText).font(.caption).foregroundStyle(.secondary)
                }
            }
            if case .failed(let why) = state {
                Label(why, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    Text(BlackHoleSetup.terminalCommand)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.quinary))
                    HStack {
                        Button(copied ? "已复制" : "复制命令") {
                            onCopy()
                            copied = true
                            Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                        }
                        Button("打开终端", action: onOpenTerminal)
                        Spacer()
                        Text("粘贴回车,装好后自动接上").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .controlSize(.small)
                }
            } label: {
                Text("改用终端安装").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.12)))
    }

    private var progressText: String {
        switch state {
        case .downloading: return "下载并校验安装包"
        case .installing: return "等待管理员授权"
        case .waiting: return "等待音频服务加载"
        default: return ""
        }
    }
}
