import AppKit
import SwiftUI

// 讲话浮层:按住讲话键满 1 秒后在鼠标指针下方出现的玻璃胶囊,松开 0.3 秒后消失
// (形态参考 VoiceInk Mini Recorder / Handy overlay)。听写时视线在光标处,
// 菜单栏面板是收着的,所以开麦与否、实时字幕都在这里看。
// NSPanel 不激活、不接鼠标:本地转文字要往当前光标处出字。只有松开后的修改阶段临时接键盘
// (非激活面板成为 key,原 App 仍是前台),插入或放弃后立即交还。
@MainActor
final class TalkOverlay: ObservableObject {
    enum Phase { case hidden, arming, live, offline, transcribing, polishing, review }

    static let barCount = 9
    static let holdDelay: TimeInterval = 1  // 按住不到 1 秒当误触:浮层不出现,也不转文字
    static let size = NSSize(width: 440, height: 150)
    @Published private(set) var phase = Phase.hidden
    @Published private(set) var levels = [Double](repeating: 0, count: barCount)  // 0..1,最新在右
    @Published private(set) var startedAt = Date()
    @Published var text = ""  // 讲话时是实时字幕,松开后是可改的定稿

    private var keyDown = false
    private var panel: OverlayPanel?
    private var hideWork: DispatchWorkItem?
    private var showWork: DispatchWorkItem?
    private var decision: CheckedContinuation<String?, Never>?

    /// 讲话键按下/松开(FnListener 回调)。按下时按设备状态选阶段:离线 / 等开麦 / 送声。
    func setKey(_ down: Bool, online: Bool, muted: Bool) {
        guard phase != .review else { return }  // 修改中讲话键只管送声,不打断草稿
        if down && !keyDown {
            text = ""
            startedAt = Date()
            levels = [Double](repeating: 0, count: Self.barCount)
            let work = DispatchWorkItem { [weak self] in self?.show() }
            showWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDelay, execute: work)
        }
        keyDown = down
        guard down else {
            showWork?.cancel()
            scheduleHide()
            return
        }
        hideWork?.cancel()
        phase = !online ? .offline : (muted ? .arming : .live)
    }

    /// 链路状态变了(设备回报取消静音、掉线):按住期间跟着切阶段。
    func linkChanged(online: Bool, muted: Bool) {
        guard keyDown else { return }
        setKey(true, online: online, muted: muted)
    }

    func setTranscribing() {
        keyDown = false
        showWork?.cancel()
        hideWork?.cancel()
        phase = .transcribing
        show()
    }

    /// 转写完、等 AI 润色:胶囊换成润色动效,字幕框扫光。
    func setPolishing() {
        guard phase == .transcribing else { return }
        phase = .polishing
    }

    func finishTranscribing() {
        resolve(nil)
        scheduleHide(after: 0.6)
    }

    /// 松开后展示定稿等人确认:回车返回(可能改过的)文字,Esc 返回 nil。
    func review(_ draft: String) async -> String? {
        resolve(nil)
        hideWork?.cancel()
        showWork?.cancel()
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

    /// 讲话中的实时字幕;松开后的定稿也经这里替换最后一轮字幕。
    func showPartial(_ partial: String) {
        guard phase == .live || phase == .transcribing || phase == .polishing else { return }
        text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
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
        // 胶囊顶边在鼠标指针下方 24pt,字幕/修改框接在胶囊下面;贴边时收进屏幕可见区。面板其余部分透明。
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let area = screen.visibleFrame
            let x = min(max(mouse.x - size.width / 2, area.minX), area.maxX - size.width)
            let y = min(max(mouse.y - 24 - size.height, area.minY), area.maxY - size.height)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        let reviewing = phase == .review
        panel.keyable = reviewing
        panel.ignoresMouseEvents = !reviewing
        guard reviewing else { return panel.orderFrontRegardless() }
        panel.makeKeyAndOrderFront(nil)
        // macOS 聚焦输入框会全选,一敲字就把整句替换掉;光标挪到末尾。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            (panel.firstResponder as? NSTextView)?.moveToEndOfDocument(nil)
        }
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

/// AI 润色时扫过字幕框的一道光,1.2 秒一趟。
private struct Shimmer: View {
    @State private var x: CGFloat = -0.5

    var body: some View {
        GeometryReader { geometry in
            LinearGradient(colors: [.clear, .orange.opacity(0.3), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: geometry.size.width * 0.5)
                .offset(x: x * geometry.size.width)
                .onAppear { withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { x = 1 } }
        }
        .clipped()
        .allowsHitTesting(false)
    }
}

/// 只在修改阶段可成为 key:非激活面板接键盘时,前台 App 不变。
final class OverlayPanel: NSPanel {
    var keyable = false
    override var canBecomeKey: Bool { keyable }
}

private struct TalkOverlayView: View {
    @ObservedObject var overlay: TalkOverlay
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            capsule
            if overlay.phase == .review {
                ReviewCard(overlay: overlay)
            } else if !overlay.text.isEmpty, [.live, .transcribing, .polishing].contains(overlay.phase) {
                CaptionText(text: overlay.text)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .overlay { if overlay.phase == .polishing && !reduceMotion { Shimmer() } }
                    .glassEffect(.regular, in: .rect(cornerRadius: 14))
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
            Spacer(minLength: 0)
        }
        .animation(.smooth(duration: 0.25), value: overlay.text)  // 字幕框随字数平滑长高
        .animation(.smooth(duration: 0.25), value: overlay.phase)
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
            case .polishing:
                Image(systemName: "wand.and.sparkles").font(.caption).foregroundStyle(.orange)
                    .symbolEffect(.variableColor.iterative.reversing)
                Text("AI 润色中").font(.caption2)
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
        case .offline, .polishing: return .orange
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

/// 实时字幕:模型每轮一次吐出一截字,这里按匀速打字把新增的字逐个显出来(前沿两个字渐隐过渡),
/// 不跟着整截跳出。模型改写已显示的字时直接换字,不重放动画,免得整行闪。
/// 视频字幕(SubtitleOverlay)也用它。
struct CaptionText: View {
    let text: String
    var font: Font = .callout
    var lines = 3
    @State private var shown = ""
    @State private var revealed = 0.0  // 已显出的字数,动画中是小数

    var body: some View {
        Text(shown)
            .font(font)
            .lineLimit(lines)
            .truncationMode(.head)  // 长句只看最新的部分
            .textRenderer(TypingReveal(count: shown.count, revealed: revealed))
            .onAppear { update(text) }
            .onChange(of: text) { _, new in update(new) }
    }

    private func update(_ new: String) {
        shown = new
        let target = Double(new.count)
        guard target > revealed else {
            revealed = target  // 字变少:模型收回了尾巴,直接跟上
            return
        }
        // 约 25 字/秒,一截太长时压到 0.6 秒内打完,别落后于下一轮字幕。
        let duration = min(0.6, max(0.12, (target - revealed) * 0.04))
        withAnimation(.linear(duration: duration)) { revealed = target }
    }
}

/// 按字形从末尾数:截掉开头(truncationMode .head)也不影响哪些字还没显出。
private struct TypingReveal: TextRenderer, Animatable {
    var count: Int
    var revealed: Double
    var animatableData: Double {
        get { revealed }
        set { revealed = newValue }
    }

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        let pending = Double(count) - revealed  // 末尾还没显出的字数
        let glyphs = Array(layout.flatMap { $0 }.flatMap { $0 })
        for (i, glyph) in glyphs.enumerated() {
            let fromEnd = Double(glyphs.count - 1 - i)
            let opacity = min(1, max(0, (fromEnd - pending + 2) / 2))
            guard opacity < 1 else {
                ctx.draw(glyph)
                continue
            }
            guard opacity > 0 else { continue }
            var g = ctx
            g.opacity = opacity
            g.addFilter(.blur(radius: (1 - opacity) * 1.5))
            g.draw(glyph)
        }
    }
}

/// 松开后的定稿:改完回车插入,Esc 放弃。
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
                Text("回车插入 · Esc 取消")
                    .font(.caption2).foregroundStyle(.secondary)
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
