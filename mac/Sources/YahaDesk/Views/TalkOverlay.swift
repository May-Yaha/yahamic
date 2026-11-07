import AppKit
import SwiftUI

// 讲话浮层:按住讲话键时在屏幕底部居中出现的玻璃胶囊,松开 0.3 秒后消失
// (形态参考 VoiceInk Mini Recorder / Handy overlay)。听写时视线在光标处,
// 菜单栏面板是收着的,所以开麦与否要在这里看。
// NSPanel 不激活、不接鼠标:豆包要往当前光标处出字,浮层绝不能抢焦点。
@MainActor
final class TalkOverlay: ObservableObject {
    enum Phase { case hidden, arming, live, offline, transcribing }

    static let barCount = 9
    @Published private(set) var phase = Phase.hidden
    @Published private(set) var levels = [Double](repeating: 0, count: barCount)  // 0..1,最新在右
    @Published private(set) var startedAt = Date()

    private var keyDown = false
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    /// 讲话键按下/松开(FnListener 回调)。按下时按设备状态选阶段:离线 / 等开麦 / 送声。
    func setKey(_ down: Bool, online: Bool, muted: Bool) {
        if down && !keyDown {
            startedAt = Date()
            levels = [Double](repeating: 0, count: Self.barCount)
        }
        keyDown = down
        guard down else {
            scheduleHide()
            return
        }
        hideWork?.cancel()
        phase = !online ? .offline : (muted ? .arming : .live)
        show()
    }

    /// 链路状态变了(设备回报取消静音、掉线):按住期间跟着切阶段。
    func linkChanged(online: Bool, muted: Bool) {
        guard keyDown else { return }
        setKey(true, online: online, muted: muted)
    }

    func setTranscribing() {
        keyDown = false
        hideWork?.cancel()
        phase = .transcribing
        show()
    }

    func finishTranscribing() { scheduleHide(after: 0.6) }

    /// 每帧电平(dBFS,约 16 Hz):-60..0 dB 映射到 0..1,开方提一提小音量的可见度。
    func push(level db: Double) {
        guard phase == .live else { return }
        levels.removeFirst()
        levels.append(pow(min(1, max(0, (db + 60) / 60)), 0.7))
    }

    private func scheduleHide(after delay: TimeInterval = 0.3) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.phase = .hidden
            self?.panel?.orderOut(nil)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func show() {
        let size = NSSize(width: 136, height: 32)
        let panel = self.panel ?? makePanel(size: size)
        self.panel = panel
        // 跟着鼠标所在的屏幕;放在 Dock 之上 40pt。
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.minY + 40))
        }
        panel.orderFrontRegardless()
    }

    private func makePanel(size: NSSize) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: TalkOverlayView(overlay: self))
        return panel
    }
}

private struct TalkOverlayView: View {
    @ObservedObject var overlay: TalkOverlay

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(dotColor).frame(width: 7, height: 7)
            switch overlay.phase {
            case .live:
                bars
                Spacer(minLength: 0)
                Text(timerInterval: overlay.startedAt...Date.distantFuture, countsDown: false)
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            case .arming:
                Text("连接麦克风…").font(.caption2)
                Spacer(minLength: 0)
            case .transcribing:
                ProgressView().controlSize(.mini)
                Text("正在转文字").font(.caption2)
                Spacer(minLength: 0)
            case .offline, .hidden:
                Text("设备未连接").font(.caption2)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .frame(width: 136, height: 32)
        .glassEffect(.regular, in: .capsule)
    }

    private var dotColor: Color {
        switch overlay.phase {
        case .live: return .red
        case .offline: return .orange
        case .transcribing: return .blue
        case .arming, .hidden: return .gray
        }
    }

    private var bars: some View {
        HStack(spacing: 2) {
            ForEach(Array(overlay.levels.enumerated()), id: \.offset) { _, v in
                Capsule().fill(.primary.opacity(0.8))
                    .frame(width: 2, height: 3 + 12 * v)
            }
        }
        .frame(height: 15)
        .animation(.linear(duration: 0.06), value: overlay.levels)
    }
}
