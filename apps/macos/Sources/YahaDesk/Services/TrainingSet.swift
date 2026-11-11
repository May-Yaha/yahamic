import CryptoKit
import DeskCore
import DeskProtocol
import DeskShared
import Foundation

/// Fine-tuning data from the takes backed up on Pan. Each take's audio is decoded to a 16 kHz WAV and re-transcribed
/// whole by the local Qwen model; the AI polish endpoint and model set by the user then cross-check that against the
/// dictation text. A take checked by hand (`.label.txt`) is labelled as-is; one where all three texts agree is an auto
/// label; the rest wait in the 标注 pane with the AI text prefilled. Results stay on this Mac under
/// Application Support/YahaDesk/Training: manifest.jsonl (every take) and train/dev/test.jsonl for qwen3_asr_sft.
@MainActor
final class TrainingSet: ObservableObject {
    struct Row: Codable {
        var path: String  // take on Pan
        var id: UInt64?  // fs_id of the audio
        var audio: String  // local WAV
        var seconds: Double
        var live: String?  // dictation text inserted at the time
        var offline: String?  // whole take re-transcribed
        var corrected: String?  // AI cross-check of live + offline
        var aiModel: String?  // model asked for `corrected` (even when it failed); another model re-checks
        var label: String?  // checked by hand
        var status: String  // human / agree / ai / review / skip (no speech or no AI text: not retried, left out)
        var model: String
    }

    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var rows: [String: Row] = [:]  // by path

    let folder: URL
    private let speech: LocalSpeechRecognizer
    private let polish: AIPolish
    private let recordings: RecordingBackup
    private let model = LocalSpeechRecognizer.modelRepository + "@" + LocalSpeechRecognizer.modelSourceRevision

    init(speech: LocalSpeechRecognizer, polish: AIPolish, recordings: RecordingBackup,
         folder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YahaDesk/Training")) {
        self.speech = speech
        self.polish = polish
        self.recordings = recordings
        self.folder = folder
        rows = Dictionary(load().map { var r = $0; r.status = Self.status(r); return (r.path, r) }) { a, _ in a }
    }

    /// Takes waiting for a person, oldest first.
    var pending: [Row] { rows.values.filter { $0.status == "review" }.sorted { $0.path < $1.path } }

    func count(_ status: String) -> Int { rows.values.filter { $0.status == status }.count }

    /// Re-labels every listed take; each finished take is saved at once, so a re-run (or a run cut short) only redoes
    /// takes not done yet and re-reads hand labels. Shares the Qwen model with live dictation, which waits meanwhile.
    func build() async -> [String: Any] {
        guard !busy else { return ["error": "正在生成"] }
        guard let token = recordings.token(), token.valid() else { return ["error": "未登录网盘"] }
        guard polish.hasKey else { return ["error": "未填写 AI 润色的 API Key"] }
        busy = true
        defer { busy = false }
        let pan = PanFiles(token: token.token)
        let takes: [PanFiles.Take]
        // ponytail: recent() covers the newest 30 day folders, 1000 files; page it when older takes are needed.
        do { takes = PanFiles.takes(try await pan.recent(limit: 1000)) } catch {
            message = error.localizedDescription
            return ["error": error.localizedDescription]
        }
        var failed = 0
        for (i, take) in takes.enumerated() {
            message = "正在标注 \(i + 1)/\(takes.count)"
            do {
                var row = try await label(take, cached: rows[take.path].flatMap { $0.model == model ? $0 : nil }, pan)
                if row.label == nil, let human = rows[take.path]?.label { row.label = human }  // confirmed meanwhile
                row.status = Self.status(row)
                rows[take.path] = row
                try saveManifest()
            } catch {
                failed += 1
                if let f = error as? DmsClient.Failure, [-6, 111].contains(f.errno) {
                    message = error.localizedDescription
                    return ["error": error.localizedDescription]
                }
            }
        }
        do { try writeSplits() } catch {
            message = "训练数据写入失败:\(error.localizedDescription)"
            return ["error": message!]
        }
        message = "\(takes.count) 段:已校对 \(count("human")),自动一致 \(count("agree")),AI 采用 \(count("ai")),待校对 \(count("review")),"
            + "跳过 \(count("skip"))" + (failed > 0 ? ",失败 \(failed)" : "")
        return ["takes": takes.count, "human": count("human"), "agree": count("agree"), "ai": count("ai"), "review": count("review"),
                "skip": count("skip"), "failed": failed, "folder": folder.path]
    }

    /// The person's text for a take: stored as `.label.txt` beside it on Pan (the dictation `.txt` is kept), then here.
    func confirm(_ text: String, for path: String) async throws {
        let text = text.trimmed
        guard !text.isEmpty else { throw DeskProtocolError("文字不能为空") }
        guard let token = recordings.token(), token.valid() else { throw DeskProtocolError("网盘登录已过期，请重新登录") }
        _ = try await PanFiles(token: token.token)
            .upload(Data(text.utf8), to: String(path.dropLast(".opus".count)) + ".label.txt", modified: Date(), overwrite: true)
        guard var row = rows[path] else { return }
        row.label = text
        row.status = "human"
        rows[path] = row
        if let id = row.id { recordings.player.remember(text, labelFor: id) }
        try saveManifest()
        try writeSplits()
    }

    private func label(_ take: PanFiles.Take, cached: Row?, _ pan: PanFiles) async throws -> Row {
        let day = (take.path as NSString).deletingLastPathComponent.split(separator: "/").last.map(String.init) ?? "unknown"
        let name = ((take.path as NSString).lastPathComponent as NSString).deletingPathExtension
        let wav = folder.appendingPathComponent(day).appendingPathComponent(name + ".wav")
        if !FileManager.default.fileExists(atPath: wav.path) {
            let opus = try await pan.download(take.audio)
            defer { try? FileManager.default.removeItem(at: opus) }
            guard let pcm = OggOpusDecoder.pcm(try Data(contentsOf: opus)) else { throw LocalSTTError("录音解码失败") }
            try FileManager.default.createDirectory(at: wav.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PCM16Wave.data(pcm).write(to: wav, options: .atomic)
        }
        let fresh = cached?.offline == nil
        var row = cached ?? Row(path: take.path, audio: wav.path, seconds: 0, status: "review", model: model)
        row.audio = wav.path
        row.id = take.id
        if cached == nil, let item = take.transcript { row.live = try await pan.text(item).trimmed }
        if let item = take.label { row.label = try await pan.text(item).trimmed }
        if row.offline == nil {
            let pcm = try Data(contentsOf: wav).dropFirst(44)  // PCM16Wave header
            row.seconds = Double(pcm.count) / 32_000
            row.offline = try await speech.transcribe(Data(pcm)).trimmed
        }
        let aiModel = polish.model.trimmed
        // One AI try per take and model: a failure stays skipped instead of being retried every run.
        if row.label == nil, fresh || (row.aiModel != nil && row.aiModel != aiModel), let offline = row.offline {
            row.corrected = try? await polish.correct(live: row.live ?? offline, offline: offline)
            row.aiModel = aiModel
        }
        return row
    }

    /// human when checked by hand; skip without speech or AI text; agree when dictation, re-transcription and AI
    /// text match; ai when the AI text stays within a few characters of the re-transcription (homophones, terms);
    /// otherwise review: the AI rewrote or added too much (or answered instead of transcribing) to trust unchecked.
    nonisolated static func status(_ row: Row) -> String {
        if row.label != nil { return "human" }
        guard let offline = row.offline.map(normalized), !offline.isEmpty, let corrected = row.corrected.map(normalized)
        else { return "skip" }
        let texts = [row.live, row.offline, row.corrected].map { $0.map(normalized) }
        if !texts.contains(nil) && Set(texts).count == 1 { return "agree" }
        // ponytail: fixed edit budget (4 chars or 1/7 of the text), tune it once dev/test CER is measured.
        return distance(Array(corrected), Array(offline)) <= max(4, offline.count / 7) ? "ai" : "review"
    }

    /// The text a row trains on, nil when it waits for a person or is skipped.
    nonisolated static func text(_ row: Row) -> String? {
        switch row.status {
        case "human": row.label
        case "agree": row.offline
        case "ai": row.corrected
        default: nil
        }
    }

    /// Levenshtein distance in characters.
    nonisolated static func distance(_ a: [Character], _ b: [Character]) -> Int {
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var current = [i + 1]
            for (j, y) in b.enumerated() { current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (x == y ? 0 : 1))) }
            previous = current
        }
        return previous[b.count]
    }

    private func load() -> [Row] {
        guard let data = try? String(contentsOf: folder.appendingPathComponent("manifest.jsonl"), encoding: .utf8) else { return [] }
        return data.split(separator: "\n").compactMap { try? JSONDecoder().decode(Row.self, from: Data($0.utf8)) }
    }

    private func lines(_ items: [some Encodable]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Data(try items.map { String(data: try encoder.encode($0), encoding: .utf8)! + "\n" }.joined().utf8)
    }

    private func saveManifest() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try lines(rows.values.sorted { $0.path < $1.path }).write(to: folder.appendingPathComponent("manifest.jsonl"), options: .atomic)
    }

    /// Every usable row split ~8/1/1 by a hash of the take's path (stable across runs). Takes waiting for review are
    /// left out. Auto labels come from the base model's own re-transcription, so dev/test CER flatters the base model.
    /// Audio paths are relative to the folder: copy it to the training machine and run from inside it.
    private func writeSplits() throws {
        var split: [String: [[String: String]]] = ["train": [], "dev": [], "test": []]
        for row in rows.values.sorted(by: { $0.path < $1.path }) {
            guard let text = Self.text(row) else { continue }
            let bucket = Int(Array(Insecure.MD5.hash(data: Data(row.path.utf8)))[0]) % 10
            split[bucket == 0 ? "test" : bucket == 1 ? "dev" : "train", default: []]
                .append(["audio": URL(fileURLWithPath: row.audio).pathComponents.suffix(2).joined(separator: "/"),
                         "text": "language Chinese<asr_text>" + text])
        }
        for (name, items) in split {
            try lines(items).write(to: folder.appendingPathComponent(name + ".jsonl"), options: .atomic)
        }
    }

    /// Punctuation and spacing don't count as a disagreement; letter case does (`swift test` vs `Swift Test`).
    nonisolated static func normalized(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter {
            !CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines).union(.symbols).contains($0)
        }))
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
