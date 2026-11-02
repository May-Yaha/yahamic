import SwiftUI

/// 语义状态色收口:菜单面板内所有状态色只允许从这里取。
/// 四态映射:开麦=系统绿、已静音=系统红、离线=系统灰、权限或音频异常=系统橙。
/// 全部基于系统语义色(.green/.red/.gray/.orange 本身就是系统动态色),
/// 深浅色外观下的对比度与色相交由系统自动适配;填充一律用 opacity 调深浅,
/// 不引入任何硬编码 RGB,避免风格漂移与深色模式翻车。
enum MenuStatusTint {
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
enum PanelSpacing {
    static let section: CGFloat = 12   // 大区块之间
    static let row: CGFloat = 8        // 组内行距
    static let inner: CGFloat = 4      // 元素内部
    static let cardPadding: CGFloat = 12
    static let cardRadius: CGFloat = 12
}
