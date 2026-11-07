import Combine
import Foundation
import DeskProtocol

/// Backs up every push-to-talk recording to Pan as Ogg Opus: the window runs from unmute until mute or disconnect,
/// plus 1 s for the tail frames that arrive after mute. Each file is written locally first and deleted only after
/// Pan accepts it, so a failed upload is retried later instead of lost.
@MainActor
final class RecordingBackup: ObservableObject {
    static let minimumSamples48k = 48_000  // under 1 s is a mis-press, not worth a file
    @Published private(set) var items: [PanFiles.Item] = []
    @Published private(set) var pending = 0
    @Published private(set) var message: String?
    @Published private(set) var busy = false

    var token: () -> PanToken? = PanKeychain.load
    var log: (String) -> Void = { _ in }
    var session = URLSession(configuration: .ephemeral)
    var tail: Duration = .seconds(1)
    var now: () -> Date = Date.init
    var loginExpired: () -> Void = {}
    let folder: URL

    private var writer: OggOpusWriter?
    private var started = Date()
    private var closing: Task<Void, Never>?
    private var uploading = false
    private var privateCapture = false

    init(folder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("YahaDesk/Recordings")) {
        self.folder = folder
        pending = files().count
    }

    /// From the link state: talking means connected and unmuted.
    func talking(_ on: Bool) {
        guard !privateCapture else { return }
        if on {
            guard writer == nil || closing != nil else { return }
            finish()  // a new press inside the tail window closes the previous take now
            guard token() != nil else { return }  // never logged in to Pan: nothing to back up to
            writer = OggOpusWriter()
            started = now()
        } else if writer != nil, closing == nil {
            closing = Task { [weak self, tail] in
                try? await Task.sleep(for: tail)
                guard !Task.isCancelled else { return }
                self?.finish()
            }
        }
    }

    func append(_ packet: Data, samples: Int) {
        guard !privateCapture else { return }
        writer?.append(packet, samples: samples)
    }

    /// Enrollment and diagnostics are private local captures, not ordinary talk recordings.
    func setPrivateCapture(_ active: Bool) {
        guard privateCapture != active else { return }
        privateCapture = active
        if active { finish() }
    }

    private func finish() {
        closing?.cancel()
        closing = nil
        guard let w = writer else { return }
        writer = nil
        guard w.samples48k >= Self.minimumSamples48k else { return }
        let base = folder.appendingPathComponent(Self.relativePath(started))
        var url = base, n = 0
        while FileManager.default.fileExists(atPath: url.path) {  // clock went back: keep the earlier take
            n += 1
            url = base.deletingPathExtension().appendingPathExtension("\(n).opus")
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try w.finish().write(to: url, options: .atomic)
            log(String(format: "录音 %.1f 秒,待备份到网盘", Double(w.samples48k) / 48_000))
        } catch {
            log("⚠️ 录音保存失败:\(error.localizedDescription)")
        }
        Task { await upload(); await refresh() }
    }

    /// Uploads every local recording, oldest first, including takes finished meanwhile; stops at the first failure
    /// and keeps the rest for next time.
    func upload() async {
        pending = files().count
        guard !uploading, pending > 0 else { return }
        guard let token = token(), token.valid() else {
            message = "\(pending) 段录音待备份,登录网盘后自动上传"
            return
        }
        uploading = true
        defer { uploading = false; pending = files().count }
        let pan = client(token)
        while let url = files().first {
            // Date folder + file name; a prefix cut breaks when the enumerator resolves symlinks (/var → /private/var).
            let relative = url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            do {
                let stored = try await pan.upload(Data(contentsOf: url), to: PanFiles.root + "/" + relative, modified: modified)
                log("录音已备份到网盘 \(stored)")
                message = nil
                // Can't delete: stop here instead of re-uploading it forever; the next round renames the duplicate.
                guard (try? FileManager.default.removeItem(at: url)) != nil else { return }
            } catch {
                message = error.localizedDescription
                if let f = error as? DmsClient.Failure, [-6, 111].contains(f.errno) { loginExpired() }
                log("⚠️ 录音备份失败,留在本机待重传:\(error.localizedDescription)")
                return
            }
        }
    }

    func refresh() async {
        guard !busy else { return }
        guard let token = token(), token.valid() else { message = "登录网盘后可查看已备份的录音"; return }
        busy = true
        defer { busy = false }
        do { items = try await client(token).recent() } catch { message = error.localizedDescription }
    }

    private func client(_ token: PanToken) -> PanFiles {
        let log = self.log
        return PanFiles(token: token.token, log: { line in Task { @MainActor in log(line) } }, session: session)
    }

    private func files() -> [URL] {
        let all = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        return all.filter { $0.pathExtension == "opus" }.sorted { $0.path < $1.path }
    }

    /// `YYYY-MM-DD/HHmmss.opus` in local time, both the local layout and the path under PanFiles.root.
    static func relativePath(_ date: Date, in zone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "yyyy-MM-dd/HHmmss"
        return f.string(from: date) + ".opus"
    }
}
