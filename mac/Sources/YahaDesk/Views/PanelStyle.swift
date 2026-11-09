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

// 间距 token:模块之间 10、组内行距 8、元素内部 4;模块 padding 12、圆角 16(同控制中心)。
enum PanelSpacing {
    static let section: CGFloat = 10   // 模块之间
    static let row: CGFloat = 8        // 组内行距
    static let inner: CGFloat = 4      // 元素内部
    static let cardPadding: CGFloat = 12
    static let cardRadius: CGFloat = 16
}

// 控制中心风格:每个功能是一块玻璃模块,开关是圆形图标(开 = 实色底白图标,关 = 淡灰底)。
extension View {
    /// 控制中心模块底:Liquid Glass 圆角块,宽度撑满。
    func controlTile() -> some View {
        padding(PanelSpacing.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: PanelSpacing.cardRadius))
    }
}

/// 圆形图标:tint 为 nil 表示「关」。
struct CircleIcon: View {
    let symbol: String
    var tint: Color?
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(tint == nil ? Color.primary : Color.white)
            .frame(width: size, height: size)
            .background(Circle().fill(tint ?? Color.primary.opacity(0.1)))
            .contentTransition(.symbolEffect(.replace))
    }
}

/// 控制中心的小方块开关:整块可点,圆形图标表达开关态,下面一行小字说明。
struct TileToggleStyle: ToggleStyle {
    let symbol: String
    var detail: String = ""
    /// 开态底色:每个功能一个颜色(同 iOS 设置页的彩色图标),不用状态四色,免得和开麦/静音混淆。
    var color: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: PanelSpacing.row) {
                CircleIcon(symbol: symbol, tint: configuration.isOn ? color : nil)
                VStack(alignment: .leading, spacing: 1) {
                    configuration.label.font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(detail.isEmpty ? (configuration.isOn ? "开" : "关") : detail)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .controlTile()
        .animation(.snappy(duration: 0.2), value: configuration.isOn)
    }
}
