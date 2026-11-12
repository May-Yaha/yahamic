import AppKit
import SwiftUI

// 视频字幕浮层:贴在前台窗口(播放器、浏览器)内底部居中,原文一行、译文一行。
// 与讲话浮层同款非激活、不接鼠标的玻璃面板,不抢焦点、不挡点击。
@MainActor
final class SubtitleOverlay: ObservableObject {
    static let defaultFontSize = 22.0
    static let fontSizes = 14.0...44.0
    @Published private(set) var caption: CaptionQueue.Caption?
    @Published private(set) var width: CGFloat = 900
    @Published var fontSize = defaultFontSize {
        didSet { if caption != nil { place() } }
    }

    private var panel: OverlayPanel?

    /// 主字幕两行 + 对照一行 + 内边距,随字号变。
    var height: CGFloat { (fontSize * 1.3 * 2 + fontSize * 0.7 * 1.3 + 32).rounded() }

    func show(_ caption: CaptionQueue.Caption) {
        self.caption = caption
        place()
    }

    func hide() {
        caption = nil
        panel?.orderOut(nil)
    }

    /// 每次刷新都重新对准前台窗口:切窗口、拖动、进全屏都跟得上。
    private func place() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let frame: NSRect
        if let window = Self.frontWindow() {
            let width = min(window.width - 40, maxWidth)
            frame = NSRect(x: window.midX - width / 2, y: window.minY + 48, width: width, height: height)
        } else {
            let mouse = NSEvent.mouseLocation
            let area = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
            let width = min(area.width - 40, maxWidth)
            frame = NSRect(x: area.midX - width / 2, y: area.minY + 48, width: width, height: height)
        }
        if width != frame.width { width = frame.width }
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
    }

    /// 一行约 50 个拉丁字母(25 个汉字),字大了浮层跟着宽。
    private var maxWidth: CGFloat { max(900, fontSize * 26) }

    /// 前台 App(不是本 App)在屏上的最大普通窗口,换成 AppKit 坐标(左下原点)。
    private static func frontWindow() -> NSRect? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]],
              let mainHeight = NSScreen.screens.first?.frame.height
        else { return nil }
        let bounds = list.compactMap { info -> CGRect? in
            guard info[kCGWindowOwnerPID as String] as? pid_t == front.processIdentifier,
                  info[kCGWindowLayer as String] as? Int == 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict), rect.width > 200, rect.height > 150
            else { return nil }
            return rect
        }
        guard let best = bounds.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        return NSRect(x: best.minX, y: mainHeight - best.maxY, width: best.width, height: best.height)
    }

    private func makePanel() -> OverlayPanel {
        let panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: SubtitleView(overlay: self))
        return panel
    }
}

private struct SubtitleView: View {
    @ObservedObject var overlay: SubtitleOverlay

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if let caption = overlay.caption {
                let size = overlay.fontSize
                VStack(spacing: 4) {
                    // 有译文时译文是主字幕,原文缩小放下面对照。
                    if caption.translation.isEmpty {
                        CaptionText(text: caption.original, font: .system(size: size, weight: .medium), lines: 2)
                    } else {
                        Text(caption.translation).font(.system(size: size, weight: .medium))
                            .lineLimit(2).truncationMode(.head)
                        Text(caption.original).font(.system(size: size * 0.7)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
                .id(caption.id)  // 换句整屏淡入淡出;同一句里长字走 CaptionText 打字动效
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: overlay.caption?.id)
        .frame(width: overlay.width, height: overlay.height)
    }
}
