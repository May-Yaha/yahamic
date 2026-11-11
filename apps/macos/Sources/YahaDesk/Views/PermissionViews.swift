import SwiftUI
import DeskCore

/// 权限申请卡片:按住讲话缺键盘权限时显示在最上面,写明缺哪一项、去哪里开。
struct PermissionCard: View {
    let permission: ListenPermission
    let onRequest: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PanelSpacing.row) {
            Label("「按住讲话」需要键盘权限", systemImage: "lock.shield.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MenuStatusTint.warning.color)
            Text("\(permission.guidance)。允许后 2 秒内自动恢复,无需重启。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("再次申请", action: onRequest).controlSize(.small)
                Button("打开系统设置", action: onOpen).controlSize(.small)
            }
        }
        .noticeTile()
    }
}
