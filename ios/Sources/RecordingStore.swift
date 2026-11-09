import DeskProtocol
import Foundation

@MainActor
final class RecordingStore: ObservableObject {
    @Published private(set) var items: [PanFiles.Take] = []
    @Published private(set) var loggedIn = PanKeychain.load() != nil
    @Published private(set) var busy = false
    @Published var message = ""

    let player = TakePlayer { PanKeychain.load().flatMap { $0.valid() ? $0.token : nil } }
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
        generation &+= 1
        busy = false
        player.stop()
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
            items = PanFiles.takes(fresh)
            message = items.isEmpty ? "还没有录音" : ""
        } catch {
            guard request == generation else { return }
            message = error.localizedDescription
        }
    }

    nonisolated static func acceptsResult(request: Int, current: Int, loggedIn: Bool) -> Bool {
        request == current && loggedIn
    }
}
