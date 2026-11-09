import AppKit
import SwiftUI

// 讲话浮层:按住讲话键满 1 秒后在屏幕底部居中出现的玻璃胶囊,松开 0.3 秒后消失
// (形态参考 VoiceInk Mini Recorder / Handy overlay)。听写时视线在光标处,
// 菜单栏面板是收着的,所以开麦与否、实时字幕都在这里看。
// NSPanel 不激活、不接鼠标:本地转文字要往当前光标处出字。只有松开后的修改阶段临时接键盘
// (非激活面板成为 key,原 App 仍是前台),插入或放弃后立即交还。
@MainActor
final class TalkOverlay: ObservableObject {
    enum Phase { case hidden, arming, live, offline, transcribing, review }

    static let barCount = 9
    static let holdDelay: TimeInterval = 1  // 按住不到 1 秒当误触:浮层不出现,也不转文字
    static let size = NSSize(width: 440, height: 150)
    nonisolated static let autoInsert: TimeInterval = 1.5  // 松开后不动键盘鼠标,这么久后自动插入
    @Published private(set) var phase = Phase.hidden
    @Published private(set) var levels = [Double](repeating: 0, count: barCount)  // 0..1,最新在右
    @Published private(set) var startedAt = Date()
    @Published var text = ""  // 讲话时是实时字幕,松开后是可改的定稿
    @Published private(set) var editing = false  // 修改阶段碰过键盘或鼠标:不再自动插入

    private var keyDown = false
    private var panel: OverlayPanel?
    private var hideWork: DispatchWorkItem?
    private var showWork: DispatchWorkItem?
    private var decision: CheckedContinuation<String?, Never>?
    private var autoWork: DispatchWorkItem?
    private var monitor: Any?

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

    func finishTranscribing() {
        resolve(nil)
        scheduleHide(after: 0.6)
    }

    /// 松开后展示定稿:不动就在 autoInsert 秒后返回原文;动了键盘鼠标就等回车(返回改过的文字)或 Esc(nil)。
    func review(_ draft: String, autoInsertAfter delay: TimeInterval = autoInsert) async -> String? {
        resolve(nil)
        hideWork?.cancel()
        showWork?.cancel()
        text = draft
        editing = false
        phase = .review
        show()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            self?.beginEditing()
            return event
        }
        let work = DispatchWorkItem { [weak self] in self?.confirm() }
        autoWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return await withCheckedContinuation { decision = $0 }
    }

    func beginEditing() {
        autoWork?.cancel()
        editing = true
    }

    func confirm() { resolve(text) }
    func cancel() { resolve(nil) }

    private func resolve(_ result: String?) {
        guard let decision else { return }
        self.decision = nil
        autoWork?.cancel()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel?.keyable = false
        panel?.ignoresMouseEvents = true
        phase = .hidden
        panel?.orderOut(nil)
        decision.resume(returning: result)
    }

    /// 讲话中的实时字幕;松开后的定稿也经这里替换最后一轮字幕。
    func showPartial(_ partial: String) {
        guard phase == .live || phase == .transcribing else { return }
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
        // 跟着鼠标所在的屏幕;胶囊底边在 Dock 之上 40pt,面板其余部分透明。
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.minY + 40))
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

/// 只在修改阶段可成为 key:非激活面板接键盘时,前台 App 不变。
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
            } else if !overlay.text.isEmpty, overlay.phase == .live || overlay.phase == .transcribing {
                CaptionText(text: overlay.text)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassEffect(.regular, in: .rect(cornerRadius: 14))
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }
            capsule
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

/// 实时字幕:每次刷新只让新出现或被改写的字浮现(由虚变实、由模糊到清晰、轻微上移),已有的字不动。
private struct CaptionText: View {
    let text: String
    @State private var shown = ""
    @State private var fresh = 0  // 末尾正在浮现的字数
    @State private var progress = 1.0

    var body: some View {
        Text(shown)
            .font(.callout)
            .lineLimit(3)
            .truncationMode(.head)  // 长句只看最新的部分
            .textRenderer(FreshGlyphs(fresh: fresh, progress: progress))
            .onAppear { update(text) }
            .onChange(of: text) { _, new in update(new) }
    }

    private func update(_ new: String) {
        let kept = zip(shown, new).prefix { $0 == $1 }.count
        shown = new
        fresh = new.count - kept
        progress = 0
        withAnimation(.easeOut(duration: 0.35)) { progress = 1 }
    }
}

/// 按字形从末尾数:截掉开头(truncationMode .head)也不影响哪些字是新的。
private struct FreshGlyphs: TextRenderer, Animatable {
    var fresh: Int
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        let glyphs = layout.flatMap { $0 }.flatMap { $0 }
        let first = glyphs.count - fresh
        for (i, glyph) in glyphs.enumerated() {
            guard i >= first, progress < 1 else {
                ctx.draw(glyph)
                continue
            }
            // 越靠后的字起步越晚,连起来像一个个打出来。
            let stagger = fresh > 1 ? Double(i - first) / Double(fresh) * 0.5 : 0
            let p = min(1, max(0, (progress - stagger) / (1 - stagger)))
            var g = ctx
            g.opacity = p
            g.addFilter(.blur(radius: (1 - p) * 4))
            g.translateBy(x: 0, y: (1 - p) * 5)
            g.draw(glyph)
        }
    }
}

/// 松开后的定稿:不动就自动插入;碰了键盘就停下,改完回车插入,Esc 放弃。
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
                Text(overlay.editing ? "回车插入 · Esc 取消" : "即将插入 · 按任意键修改")
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
