import AppKit
import SwiftUI

// 视频字幕浮层:贴在前台窗口(播放器、浏览器)内底部居中,原文一行、译文一行。
// 与讲话浮层同款非激活、不接鼠标的玻璃面板,不抢焦点、不挡点击。
@MainActor
final class SubtitleOverlay: ObservableObject {
    static let height: CGFloat = 110
    @Published private(set) var original = ""
    @Published private(set) var translation = ""
    @Published private(set) var width: CGFloat = 900

    private var panel: OverlayPanel?

    func show(original: String, translation: String) {
        self.original = original
        self.translation = translation
        place()
    }

    func hide() {
        original = ""
        translation = ""
        panel?.orderOut(nil)
    }

    /// 每次刷新都重新对准前台窗口:切窗口、拖动、进全屏都跟得上。
    private func place() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let frame: NSRect
        if let window = Self.frontWindow() {
            let width = min(window.width - 40, 900)
            frame = NSRect(x: window.midX - width / 2, y: window.minY + 48, width: width, height: Self.height)
        } else {
            let mouse = NSEvent.mouseLocation
            let area = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
            let width = min(area.width - 40, 900)
            frame = NSRect(x: area.midX - width / 2, y: area.minY + 48, width: width, height: Self.height)
        }
        if width != frame.width { width = frame.width }
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
    }

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
        let panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: Self.height),
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
            if !overlay.original.isEmpty {
                VStack(spacing: 4) {
                    // 有译文时译文是主字幕,原文缩小放下面对照。
                    if overlay.translation.isEmpty {
                        CaptionText(text: overlay.original, font: .title3.weight(.medium), lines: 2)
                    } else {
                        Text(overlay.translation).font(.title3.weight(.medium))
                            .lineLimit(2).truncationMode(.head)
                        Text(overlay.original).font(.callout).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: overlay.translation)
        .frame(width: overlay.width, height: SubtitleOverlay.height)
    }
}
