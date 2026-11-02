import SwiftUI
import YahamicCore

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
