import AVFoundation
import DeskProtocol
import Foundation

@MainActor
final class RecordingStore: ObservableObject {
    @Published private(set) var items: [PanFiles.Item] = []
    @Published private(set) var loggedIn = PanKeychain.load() != nil
    @Published private(set) var busy = false
    @Published private(set) var playingID: UInt64?
    @Published var message = ""

    private var player: AVPlayer?
    private var localFile: URL?
    private var playbackObservers: [NSObjectProtocol] = []
    private var generation = 0

    var token: String? {
        guard let saved = PanKeychain.load(), saved.valid() else { return nil }
        return saved.token
    }

    func login() async {
        guard !busy else { return }
        generation &+= 1
        let request = generation
        busy = true
        do {
            let value = try await PanLoginWindow.run()
            guard request == generation else { return }
            guard PanKeychain.save(value) else { throw DeskProtocolError("钥匙串保存失败") }
            loggedIn = true
            message = "网盘登录成功"
            busy = false
            await refresh()
        } catch {
            guard request == generation else { return }
            busy = false
            message = error is CancellationError ? "已取消登录" : error.localizedDescription
        }
    }

    func logout() {
        stop()
        guard PanKeychain.delete() else { message = "退出失败，请重试"; return }
        loggedIn = false
        items = []
        message = "已退出网盘"
    }

    /// Renews the 30-day token through the hub when 7 days or less remain; called before every list refresh.
    func renew() async {
        await PanKeychain.renewIfDue()
        loggedIn = PanKeychain.load() != nil
    }

    func refresh() async {
        await renew()
        guard let token else {
            if loggedIn { message = "网盘登录已过期，请重新登录" }
            loggedIn = false
            return
        }
        guard !busy else { return }
        let request = generation
        busy = true
        defer { if request == generation { busy = false } }
        do {
            let fresh = try await PanFiles(token: token).recent()
            guard Self.acceptsResult(request: request, current: generation, loggedIn: loggedIn) else { return }
            items = fresh
            message = items.isEmpty ? "还没有录音" : ""
        } catch {
            guard request == generation else { return }
            message = error.localizedDescription
        }
    }

    func play(_ item: PanFiles.Item) async {
        if playingID == item.id { stop(); return }
        guard let token, !busy else { return }
        stop()
        let request = generation
        busy = true
        defer { if request == generation { busy = false } }
        do {
            message = "正在准备录音"
            let url = try await PanFiles(token: token).download(item)
            var unownedFile: URL? = url
            defer { if let unownedFile { Self.removeDownloadedFile(unownedFile) } }
            guard Self.acceptsResult(request: request, current: generation, loggedIn: loggedIn) else {
                return
            }
            guard try await AVURLAsset(url: url).load(.isPlayable) else {
                throw DeskProtocolError("网盘录音无法播放")
            }
            guard Self.acceptsResult(request: request, current: generation, loggedIn: loggedIn) else {
                return
            }
            localFile = url
            unownedFile = nil
            let playerItem = AVPlayerItem(url: url)
            player = AVPlayer(playerItem: playerItem)
            observe(playerItem)
            player?.play()
            playingID = item.id
            message = ""
        } catch {
            guard request == generation else { return }
            message = error.localizedDescription
        }
    }

    func stop() {
        generation &+= 1
        busy = false
        resetPlayback()
    }

    nonisolated static func acceptsResult(request: Int, current: Int, loggedIn: Bool) -> Bool {
        request == current && loggedIn
    }

    nonisolated static func removeDownloadedFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func observe(_ item: AVPlayerItem) {
        let center = NotificationCenter.default
        playbackObservers = [
            center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.stop() }
            },
            center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
                let failure = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
                    ?? "网盘录音播放失败"
                Task { @MainActor in
                    self?.stop()
                    self?.message = failure
                }
            },
        ]
    }

    private func resetPlayback() {
        player?.pause()
        player = nil
        playingID = nil
        for observer in playbackObservers { NotificationCenter.default.removeObserver(observer) }
        playbackObservers.removeAll()
        if let localFile { Self.removeDownloadedFile(localFile) }
        localFile = nil
    }
}
