import SwiftUI

struct CloudCard: View {
    @ObservedObject var cloud: CloudSync
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        HStack(spacing: PanelSpacing.row) {
            CircleIcon(symbol: "rectangle.on.rectangle", tint: cloud.clientID == nil ? nil : .accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("设备联网与授权").font(.subheadline.weight(.medium))
                Text(cloud.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button("设置…") { openWindow(id: "device-setup"); NSApp.activate() }.controlSize(.small)
        }
        .controlTile()
    }
}
