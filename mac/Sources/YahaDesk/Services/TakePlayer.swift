import AVFoundation
import DeskProtocol
import Foundation

/// Plays backed-up takes from Pan for the mini player on Mac and iPhone, and loads each take's dictation text.
/// One take at a time: the audio is downloaded to a temporary file, played, and deleted when playback ends.
@MainActor
final class TakePlayer: ObservableObject {
    @Published private(set) var current: PanFiles.Take?
    @Published private(set) var playing = false
    @Published private(set) var loading = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var texts: [UInt64: String] = [:]  // by take id
    @Published var message = ""

    var token: () -> String?
    private var player: AVPlayer?
    private var file: URL?
    private var observers: [NSObjectProtocol] = []
    private var ticker: Any?
    private var generation = 0
    private var fetching: Set<UInt64> = []

    init(token: @escaping () -> String?) { self.token = token }

    /// Tapping the current take pauses or resumes it; another take replaces it.
    func play(_ take: PanFiles.Take) async {
        if current?.id == take.id, player != nil { toggle(); return }
        guard let token = token() else { message = "网盘登录已过期，请重新登录"; return }
        stop()
        let request = generation
        current = take
        loading = true
        defer { if request == generation { loading = false } }
        do {
            let url = try await PanFiles(token: token).download(take.audio)
            guard request == generation else { try? FileManager.default.removeItem(at: url); return }
            guard try await AVURLAsset(url: url).load(.isPlayable) else {
                try? FileManager.default.removeItem(at: url)
                throw DeskProtocolError("网盘录音无法播放")
            }
            guard request == generation else { try? FileManager.default.removeItem(at: url); return }
            file = url
            start(AVPlayerItem(url: url))
            message = ""
        } catch {
            guard request == generation else { return }
            current = nil
            message = error.localizedDescription
        }
    }

    func toggle() {
        guard let player else { return }
        if playing { player.pause() } else {
            if duration > 0, position >= duration - 0.05 { player.seek(to: .zero) }
            player.play()
        }
        playing.toggle()
    }

    func seek(to seconds: Double) {
        position = seconds
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Closes the mini player and deletes the downloaded file.
    func stop() {
        generation &+= 1
        loading = false
        player?.pause()
        if let ticker { player?.removeTimeObserver(ticker) }
        ticker = nil
        player = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
        current = nil
        playing = false
        position = 0
        duration = 0
    }

    /// Loads the take's dictation text once; takes without text and failed loads stay out of `texts`.
    func loadText(_ take: PanFiles.Take) async {
        guard let item = take.transcript, texts[take.id] == nil, !fetching.contains(take.id), let token = token() else { return }
        fetching.insert(take.id)
        defer { fetching.remove(take.id) }
        if let text = try? await PanFiles(token: token).text(item) {
            texts[take.id] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Hand-corrected text replaces the take's `.txt` on Pan (created when missing): the label used for fine-tuning.
    func saveText(_ text: String, for take: PanFiles.Take) async throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DeskProtocolError("文字不能为空") }
        guard let token = token() else { throw DeskProtocolError("网盘登录已过期，请重新登录") }
        let path = take.transcript?.path ?? String(take.path.dropLast(".opus".count)) + ".txt"
        _ = try await PanFiles(token: token).upload(Data(text.utf8), to: path, modified: take.mtime, overwrite: true)
        texts[take.id] = text
    }

    private func start(_ item: AVPlayerItem) {
        let player = AVPlayer(playerItem: item)
        self.player = player
        ticker = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.position = time.seconds
                if let d = self.player?.currentItem?.duration.seconds, d.isFinite { self.duration = d }
            }
        }
        let center = NotificationCenter.default
        observers = [
            // Ended: stays in the bar at the end so it can be replayed.
            center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.playing = false
                    if let self, self.duration > 0 { self.position = self.duration }
                }
            },
            center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
                let failure = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
                MainActor.assumeIsolated {
                    self?.stop()
                    self?.message = failure ?? "网盘录音播放失败"
                }
            },
        ]
        player.play()
        playing = true
    }

    /// `0:07` style elapsed / total label.
    nonisolated static func clock(_ seconds: Double) -> String {
        let s = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}
