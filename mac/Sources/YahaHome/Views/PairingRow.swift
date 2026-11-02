import SwiftUI

/// 配对码行:App 生成、存钥匙串;设备配网页必须填同一个码,否则连不上。
struct PairingRow: View {
    let code: String
    let deviceOnline: Bool
    let onCopy: () -> Void
    let onRegenerate: () -> Void

    @State private var copied = false
    @State private var confirmRegenerate = false

    var body: some View {
        VStack(alignment: .leading, spacing: PanelSpacing.inner) {
            HStack(spacing: PanelSpacing.inner) {
                Text("配对码")
                Spacer()
                Text(code)
                    .font(.system(.body, design: .monospaced).weight(.medium))
                    .textSelection(.enabled)
                Button {
                    onCopy()
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("复制配对码")
                Button { confirmRegenerate = true } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .help("生成新配对码")
                .confirmationDialog("生成新配对码?", isPresented: $confirmRegenerate) {
                    Button("生成新码", role: .destructive, action: onRegenerate)
                } message: {
                    Text("当前设备会断开,需要在设备配网页重新填入新码。")
                }
            }
            if !deviceOnline {
                Text("设备配网页(长按设备按键 5 秒进入)里填同一个码")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
