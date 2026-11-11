import SwiftUI

/// 联网与授权只是去设置窗口的入口,做成一行,不和高频模块同权重。
struct CloudCard: View {
    @ObservedObject var cloud: CloudSync
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button { openWindow(id: "device-setup"); NSApp.activate() } label: {
            HStack(spacing: PanelSpacing.row) {
                CircleIcon(symbol: "rectangle.on.rectangle", tint: cloud.clientID == nil ? nil : .accentColor, size: 24)
                Text("设备联网与授权").font(.subheadline)
                Spacer(minLength: 0)
                Text(cloud.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
