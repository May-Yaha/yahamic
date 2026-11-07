import AuthenticationServices
import DeskProtocol
import Foundation
import Security
import UIKit

/// desk_status 的结构化输出：设备经 desk_monitor 最近一次上报的状态。
struct DeskStatus: Decodable, Equatable {
    let reported, online, muted, mac: Bool
    var reportedAt: Int64?
    var firmware, ssid, dms, panDevice: String?

    enum CodingKeys: String, CodingKey {
        case reported, online, muted, mac, firmware, ssid, dms
        case reportedAt = "reported_at", panDevice = "pan_device"
    }
}

/// 不经蓝牙：状态经 Zhi.AI 的 desk_status 读（内置公开 PKCE 应用，只有 desk.status），
/// 控制经网盘设备服务（DMS）下发；远程只能静音，不能开麦。
@MainActor
final class CloudStore: NSObject, ObservableObject {
    static let clientID = "yahadesk-ios"
    static let scope = "desk.status"
    static let redirect = URL(string: "com.yaha.desk.ios:/oauth")!
    /// 与固件 card 指令上限一致（dms_wire.h）：title+body ≤509 字节 UTF-8。
    nonisolated static let cardMax = 509

    @Published private(set) var loggedIn = DeskGrantKeychain.load() != nil
    @Published private(set) var status: DeskStatus?
    @Published private(set) var busy = false
    @Published var message = ""

    private let client = CloudClient()
    private var grant = DeskGrantKeychain.load()
    private var session: ASWebAuthenticationSession?

    func login() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let next = try await client.authorize(clientID: Self.clientID, scope: Self.scope, redirect: Self.redirect) {
                try await self.present($0)
            }
            guard DeskGrantKeychain.save(next) else { throw DeskProtocolError("钥匙串保存失败") }
            grant = next
            loggedIn = true
            message = ""
            try await fetch()
        } catch {
            message = Self.loginCanceled(error) ? "已取消登录" : error.localizedDescription
        }
    }

    func logout() {
        guard DeskGrantKeychain.delete() else { message = "退出失败，请重试"; return }
        grant = nil
        loggedIn = false
        status = nil
        message = ""
    }

    func refresh() async {
        guard loggedIn, !busy else { return }
        busy = true
        defer { busy = false }
        do { try await fetch() } catch { message = error.localizedDescription }
    }

    func mute(panToken: String?) async {
        await command("已发送静音，设备连着网盘时立即生效", panToken) { try await $0.command($1, "mute") }
    }

    /// 发送成功才返回 true，失败时表单留着让用户重试。
    @discardableResult
    func sendCard(title: String, body: String, panToken: String?) async -> Bool {
        guard Self.cardFits(title: title, body: body) else { message = "卡片标题不能为空，标题加正文不超过 \(Self.cardMax) 字节"; return false }
        return await command("卡片已发送", panToken) { try await $0.command($1, "card", args: ["title": title, "body": body]) }
    }

    func clearCards(panToken: String?) async {
        await command("已清除设备上的卡片", panToken) { try await $0.command($1, "card", args: ["clear": true]) }
    }

    func unbind(panToken: String?) async {
        await command("已解绑，设备下次上报后更新状态", panToken) { try await $0.unbind($1) }
    }

    /// 用户关掉授权页时系统回 ASWebAuthenticationSessionError.canceledLogin。
    nonisolated static func loginCanceled(_ error: Error) -> Bool {
        error is CancellationError || error is OAuthCallbackError || (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
    }

    nonisolated static func cardFits(title: String, body: String) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.utf8.count + body.utf8.count <= cardMax
    }

    /// 网盘令牌过期时 RecordingStore.token 为 nil，在这里统一提示，不拿空令牌去调接口。
    @discardableResult
    private func command(_ done: String, _ panToken: String?, _ send: (DmsClient, String) async throws -> Void) async -> Bool {
        guard !busy else { return false }
        guard let panToken else { message = Self.panExpired; return false }
        guard let device = status?.panDevice, !device.isEmpty else { message = "设备还没有绑定网盘"; return false }
        busy = true
        defer { busy = false }
        do {
            try await send(DmsClient(token: panToken), device)
            message = done
            return true
        } catch { message = error.localizedDescription; return false }
    }

    nonisolated static let panExpired = "网盘登录已过期，请重新登录"

    private func fetch() async throws {
        let data = try await client.callTool("desk_status", arguments: [:], accessToken: try await accessToken())
        status = try JSONDecoder().decode(DeskStatus.self, from: data)
    }

    private func accessToken() async throws -> String {
        guard let previous = grant else { throw DeskProtocolError("请先登录 Zhi.AI") }
        if previous.expiresAt.timeIntervalSinceNow > 60 { return previous.accessToken }
        let next = try await client.refresh(previous, scope: Self.scope)
        guard DeskGrantKeychain.save(next) else { throw DeskProtocolError("续期凭据保存失败，请重新登录") }
        grant = next
        return next.accessToken
    }

    private func present(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { done in
            let auth = ASWebAuthenticationSession(url: url, callback: .customScheme(Self.redirect.scheme!)) { url, error in
                if let url { done.resume(returning: url) } else { done.resume(throwing: error ?? CancellationError()) }
            }
            auth.presentationContextProvider = self
            session = auth
            if !auth.start() { done.resume(throwing: DeskProtocolError("无法打开授权页面")) }
        }
    }
}

extension CloudStore: @preconcurrency ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.compactMap(\.keyWindow).first ?? ASPresentationAnchor()
    }
}

/// 刷新令牌只进钥匙串，仅本机、首次解锁后可读。
enum DeskGrantKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.yaha.desk.ios.status",
         kSecAttrAccount as String: "grant"]
    }
    static func save(_ grant: OAuthGrant) -> Bool {
        guard let data = try? JSONEncoder().encode(grant) else { return false }
        _ = delete()
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        return SecItemAdd(query.merging(attrs) { _, new in new } as CFDictionary, nil) == errSecSuccess
    }
    static func load() -> OAuthGrant? {
        var item: CFTypeRef?
        let lookup = query.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { _, new in new }
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(OAuthGrant.self, from: data)
    }
    static func delete() -> Bool {
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
