import AppKit
import SwiftUI

// 讲话浮层:按住讲话键时在屏幕底部居中出现的玻璃胶囊,松开 0.3 秒后消失
// (形态参考 VoiceInk Mini Recorder / Handy overlay)。听写时视线在光标处,
// 菜单栏面板是收着的,所以开麦与否要在这里看。
// NSPanel 不激活:本地转文字要往当前光标处出字。只有确认阶段临时接键盘(非激活面板成为 key,
// 原 App 仍是前台),回车/Esc 后立即交还。
@MainActor
final class TalkOverlay: ObservableObject {
    enum Phase { case hidden, arming, live, offline, transcribing, review }

    static let barCount = 9
    static let size = NSSize(width: 440, height: 150)
    @Published private(set) var phase = Phase.hidden
    @Published private(set) var levels = [Double](repeating: 0, count: barCount)  // 0..1,最新在右
    @Published private(set) var startedAt = Date()
    @Published var text = ""  // 讲话时是实时字幕,确认阶段是可改的草稿

    private var keyDown = false
    private var panel: OverlayPanel?
    private var hideWork: DispatchWorkItem?
    private var decision: CheckedContinuation<String?, Never>?

    /// 讲话键按下/松开(FnListener 回调)。按下时按设备状态选阶段:离线 / 等开麦 / 送声。
    func setKey(_ down: Bool, online: Bool, muted: Bool) {
        guard phase != .review else { return }  // 确认中讲话键只管送声,不打断草稿
        if down && !keyDown {
            text = ""
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

    func finishTranscribing() {
        resolve(nil)
        scheduleHide(after: 0.6)
    }

    /// 讲话中的实时字幕。
    func showPartial(_ partial: String) {
        guard phase == .live || phase == .transcribing else { return }
        text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 展示转写结果等用户确认:回车返回(可能改过的)文字,Esc 返回 nil。
    func review(_ draft: String) async -> String? {
        resolve(nil)
        hideWork?.cancel()
        text = draft
        phase = .review
        show()
        return await withCheckedContinuation { decision = $0 }
    }

    func confirm() { resolve(text) }
    func cancel() { resolve(nil) }

    private func resolve(_ result: String?) {
        guard let decision else { return }
        self.decision = nil
        panel?.keyable = false
        panel?.ignoresMouseEvents = true
        phase = .hidden
        panel?.orderOut(nil)
        decision.resume(returning: result)
    }

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
        let size = Self.size
        let panel = self.panel ?? makePanel(size: size)
        self.panel = panel
        // 跟着鼠标所在的屏幕;胶囊底边在 Dock 之上 40pt,面板其余部分透明。
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.minY + 40))
        }
        let reviewing = phase == .review
        panel.keyable = reviewing
        panel.ignoresMouseEvents = !reviewing
        if reviewing { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }
    }

    private func makePanel(size: NSSize) -> OverlayPanel {
        let panel = OverlayPanel(contentRect: NSRect(origin: .zero, size: size),
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

/// 只在确认阶段可成为 key:非激活面板接键盘时,前台 App 不变。
final class OverlayPanel: NSPanel {
    var keyable = false
    override var canBecomeKey: Bool { keyable }
}

private struct TalkOverlayView: View {
    @ObservedObject var overlay: TalkOverlay

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            if overlay.phase == .review {
                ReviewCard(overlay: overlay)
            } else {
                if !overlay.text.isEmpty, overlay.phase == .live || overlay.phase == .transcribing {
                    Text(overlay.text)
                        .font(.callout)
                        .lineLimit(3)
                        .truncationMode(.head)  // 长句只看最新的部分
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .glassEffect(.regular, in: .rect(cornerRadius: 14))
                }
                capsule
            }
        }
        .frame(width: TalkOverlay.size.width, height: TalkOverlay.size.height)
    }

    private var capsule: some View {
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
            case .offline, .hidden, .review:
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
        case .transcribing, .review: return .blue
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

/// 转写结果确认:可直接改字,回车插入到原输入框,Esc 放弃。
private struct ReviewCard: View {
    @ObservedObject var overlay: TalkOverlay
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("", text: $overlay.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.callout)
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit { overlay.confirm() }
                .onExitCommand { overlay.cancel() }
            HStack {
                Text("回车插入 · Esc 取消").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { overlay.cancel() }.controlSize(.small)
                Button("插入") { overlay.confirm() }.controlSize(.small).buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .frame(width: TalkOverlay.size.width - 20)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .onAppear { focused = true }
    }
}
