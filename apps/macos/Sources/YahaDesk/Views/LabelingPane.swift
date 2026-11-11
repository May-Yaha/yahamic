import AVFoundation
import DeskShared
import SwiftUI

/// 设置窗口「标注」页:先用 AI 润色的接口和模型批量校对,再一条条过待校对的录音。
/// 每条自动播放本机 WAV,文字框预填 AI 结果;回车采用并跳到下一条,⌘→ 跳过,⌘P 重听。
struct LabelingPane: View {
    @ObservedObject var training: TrainingSet
    @ObservedObject var aiPolish: AIPolish
    var panLoggedIn: Bool
    @State private var path: String?
    @State private var text = ""
    @State private var skipped: Set<String> = []
    @State private var player: AVAudioPlayer?
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var queue: [TrainingSet.Row] { training.pending.filter { !skipped.contains($0.path) } }
    private var row: TrainingSet.Row? { path.flatMap { training.rows[$0] } }

    var body: some View {
        Group { sections }
            .onAppear { if path == nil { next() } }
            .onChange(of: training.pending.count) { if path == nil { next() } }  // 批量校对边跑边出待校对
            .onDisappear { player?.stop() }
    }

    @ViewBuilder private var sections: some View {
        Section {
            LabeledContent("批量校对") {
                HStack {
                    if training.busy { ProgressView().controlSize(.small) }
                    Button(training.busy ? "运行中" : "开始") { Task { _ = await training.build(); next() } }
                        .disabled(training.busy || !panLoggedIn || !aiPolish.hasKey)
                    Button { NSWorkspace.shared.open(training.folder) } label: { Image(systemName: "folder") }
                        .help("打开训练数据目录").accessibilityLabel("打开训练数据目录")
                }
            }
            Text(training.message ?? "已校对 \(training.count("human")),自动一致 \(training.count("agree")),AI 采用 \(training.count("ai")),待校对 \(training.count("review")),跳过 \(training.count("skip"))")
                .foregroundStyle(.secondary)
            if !aiPolish.hasKey { Text("先在「AI 润色」填 API Key").foregroundStyle(.orange) }
        } footer: {
            Text("用「AI 润色」里的接口和模型(\(aiPolish.model)):本地模型整段重转,AI 对照讲话时的文字只纠错。三份一致或 AI 只改了几个字的自动采用,没声音或 AI 没给结果的跳过,AI 改动大的留在下面可选确认;换了模型再跑会重新校对。数据只存本机。")
        }
        if let row {
            Section {
                TextEditor(text: $text).font(.title3).frame(minHeight: 90).focused($focused)
                    .onKeyPress(.return, phases: .down) { press in
                        guard !press.modifiers.contains(.shift) else { return .ignored }  // ⇧⏎ 换行
                        Task { await accept() }
                        return .handled
                    }
                candidate("AI", row.corrected)
                candidate("讲话时", row.live)
                candidate("整段重转", row.offline)
                if let error { Text(error).foregroundStyle(.orange) }
                HStack {
                    Button { play(row) } label: { Label("重听", systemImage: "play.fill") }
                        .keyboardShortcut("p")
                    Spacer()
                    Button("跳过") { skipped.insert(row.path); next() }
                        .keyboardShortcut(.rightArrow)
                    if saving { ProgressView().controlSize(.small) }
                    Button("采用 ⏎") { Task { await accept() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("\(row.path.split(separator: "/").suffix(2).joined(separator: " ")) · \(String(format: "%.1f", row.seconds)) 秒 · 还剩 \(queue.count) 条")
            } footer: {
                Text("改好按回车保存为这段录音的标注(网盘 .label.txt,原文保留),⇧⏎ 换行;点下面的候选可整句替换。")
            }
        } else if !training.busy && training.count("review") > 0 {
            Section { Button("从头再过跳过的 \(skipped.count) 条") { skipped = []; next() } }
        }
    }

    /// 点一下用这份候选替换文字框。
    @ViewBuilder private func candidate(_ name: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            Button { text = value; focused = true } label: {
                LabeledContent(name) { Text(value).multilineTextAlignment(.trailing).textSelection(.enabled) }
            }
            .buttonStyle(.plain)
        }
    }

    private func accept() async {
        guard let row, !saving else { return }
        saving = true
        defer { saving = false }
        do {
            try await training.confirm(text, for: row.path)
            error = nil
            next()
        } catch { self.error = error.localizedDescription }
    }

    private func next() {
        player?.stop()
        guard let row = queue.first else { path = nil; player = nil; return }
        path = row.path
        text = row.corrected ?? row.offline ?? row.live ?? ""
        focused = true
        play(row)
    }

    private func play(_ row: TrainingSet.Row) {
        player?.stop()
        player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: row.audio))
        player?.play()
    }
}
