import Foundation
import Security
import DeskProtocol
import AuthenticationServices
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Baidu Pan quick authorization (code grant with directory selection). The AppKey is a public client id; the
/// secret stays on hub.flyaha.top, which turns the code or a refresh token into a token pair. The app secret must
/// never appear in this app, and tokens are never logged.
/// Source: https://pan.baidu.com/union/doc/使用入门/接入授权/快速授权/
public enum PanLogin {
    /// Same Baidu app as hub (AppID 124461637); hub exchanges the code with this app's secret, so they must match.
    public static let appKey = "FQQEfWqv6Eh6cPRMmdTpJaCw070CLDgH"
    /// Registered in the Baidu console (com.yaha.desk:/… is rejected with errno 20030); Baidu redirects here directly.
    public static let redirectURI = URL(string: "yahadesk://oauth")!
    public static let tokenURL = URL(string: "https://hub.flyaha.top/api/v1/baidu-pan/desk/token")!
    public static let renewalWindow: TimeInterval = 7 * 86_400

    public enum Navigation: Equatable {
        case allow
        case reject
        case code(String)
    }

    /// The server rejected the code or refresh token: only a new login helps.
    public struct Rejected: LocalizedError { public let errorDescription: String? }

    /// No directory picker: the app only ever touches PanFiles.root, which parseToken checks against the grant.
    public static func authorizeURL(state: String) -> URL {
        var c = URLComponents(string: "https://pan.baidu.com/union/oauth/authorize")!
        c.queryItems = [.init(name: "client_id", value: appKey), .init(name: "redirect_uri", value: redirectURI.absoluteString),
                        .init(name: "scope", value: "nd_open_read,nd_open_write"), .init(name: "state", value: state)]
        return c.url!
    }

    /// Baidu returns `yahadesk://oauth?code=…&state=…`; anything else at that address is a rejection.
    public static func navigation(_ url: URL, state: String) -> Navigation {
        guard url.scheme == redirectURI.scheme else { return .allow }
        guard url.host == redirectURI.host, url.path == redirectURI.path, url.fragment == nil else { return .reject }
        return code(url.query.flatMap(fields), state: state).map(Navigation.code) ?? .reject
    }

    /// Duplicate keys, a wrong state or an error (`error=access_denied`, `errno=`) never yield a code.
    private static func code(_ fields: [String: String]?, state: String) -> String? {
        guard let fields, fields["state"] == state, fields["error"] == nil, fields["errno"] == nil,
              let code = fields["code"], !code.isEmpty else { return nil }
        return code
    }

    private static func fields(_ raw: String) -> [String: String]? {
        var fields: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = kv[0].removingPercentEncoding, fields[key] == nil else { return nil }
            guard kv.count == 1 || kv[1].removingPercentEncoding != nil else { return nil }
            fields[key] = kv.count > 1 ? kv[1].removingPercentEncoding! : ""
        }
        return fields
    }

    public static func exchange(code: String, session: URLSession = .shared, now: Date = Date()) async throws -> PanToken {
        try await token(["code": code], session: session, now: now)
    }

    /// refresh_token is single-use: the caller must save the returned pair before using it.
    public static func refresh(_ refresh: String, session: URLSession = .shared, now: Date = Date()) async throws -> PanToken {
        try await token(["refresh_token": refresh], session: session, now: now)
    }

    private static func token(_ body: [String: String], session: URLSession, now: Date) async throws -> PanToken {
        var request = URLRequest(url: tokenURL, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let data: Data
        do { (data, _) = try await session.data(for: request) } catch is CancellationError { throw CancellationError() }
        catch { throw DeskProtocolError("网络不可用，网盘授权未完成，请稍后重试") }
        return try parseToken(data, now: now)
    }

    public struct Grant: Decodable {
        public let access_token: String
        public let refresh_token: String
        public let expires_in: TimeInterval
        public let authorized_paths: [String]?
    }

    /// The hub envelope is `{code, message, data}`; 10403 means the code or refresh token is no longer usable.
    public static func parseToken(_ data: Data, now: Date) throws -> PanToken {
        struct Envelope: Decodable { let code: Int; let message: String?; let data: Grant? }
        guard let reply = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw DeskProtocolError("网盘授权服务暂时不可用，请稍后重试")
        }
        guard reply.code == 0, let g = reply.data, !g.access_token.isEmpty, !g.refresh_token.isEmpty, g.expires_in > 0 else {
            let text = reply.message ?? "网盘授权失败，请重新登录"
            throw reply.code == 10403 ? Rejected(errorDescription: text) : DeskProtocolError(text)
        }
        let paths = g.authorized_paths ?? []
        guard covers(paths) else {
            throw DeskProtocolError("授权目录不含 \(PanFiles.root)，请检查百度控制台的目录授权配置后重新登录")
        }
        return PanToken(token: g.access_token, expires: now.addingTimeInterval(g.expires_in).timeIntervalSince1970,
                        refresh: g.refresh_token, paths: paths)
    }

    /// No paths means Baidu did not limit the grant to directories.
    public static func covers(_ paths: [String], root: String = PanFiles.root) -> Bool {
        paths.isEmpty || paths.contains { root == $0 || root.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }
}

public struct PanToken: Codable, Equatable {
    public let token: String
    public let expires: TimeInterval  // unix seconds
    public var refresh: String? = nil  // nil for tokens saved by the old implicit grant
    public var paths: [String]? = nil
    public init(token: String, expires: TimeInterval, refresh: String? = nil, paths: [String]? = nil) {
        self.token = token
        self.expires = expires
        self.refresh = refresh
        self.paths = paths
    }
    public func valid(at now: Date = Date()) -> Bool { expires - now.timeIntervalSince1970 > 60 }
    public func renewalDue(at now: Date = Date()) -> Bool {
        refresh != nil && expires - now.timeIntervalSince1970 < PanLogin.renewalWindow
    }
}

public enum PanKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "yahadesk.netdisk",
         kSecAttrAccount as String: "access_token"]
    }
    public static func save(_ token: PanToken) -> Bool {
        guard let data = try? JSONEncoder().encode(token) else { return false }
        _ = delete()
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        return SecItemAdd(query.merging(attrs) { _, new in new } as CFDictionary, nil) == errSecSuccess
    }
    public static func load() -> PanToken? {
        var item: CFTypeRef?
        let lookup = query.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { _, new in new }
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(PanToken.self, from: data)
    }
    public static func delete() -> Bool {
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

extension PanKeychain {
    @MainActor private static var renewing: Task<Void, Never>?

    /// Renews the saved pair through the hub once it is inside the renewal window (or already expired). Callers on
    /// launch, foreground and timers share one in-flight refresh, because each refresh_token works only once.
    /// A rejected refresh keeps the access token until it expires; a network failure retries on the next call.
    @MainActor public static func renewIfDue(session: URLSession = .shared, log: @escaping (String) -> Void = { _ in }) async {
        if let renewing { return await renewing.value }
        guard let saved = load(), saved.renewalDue(), let refresh = saved.refresh else { return }
        let task = Task { @MainActor in
            do {
                let fresh = try await PanLogin.refresh(refresh, session: session)
                log(save(fresh) ? "网盘授权已续期" : "⚠️ 网盘授权续期后钥匙串保存失败，请重新登录网盘")
            } catch let rejected as PanLogin.Rejected {
                _ = save(PanToken(token: saved.token, expires: saved.expires, paths: saved.paths))
                log("⚠️ 网盘授权续期被拒绝：\(rejected.localizedDescription)")
            } catch {
                log("网盘授权续期暂未完成，稍后重试：\(error.localizedDescription)")
            }
        }
        renewing = task
        await task.value
        renewing = nil
    }
}

/// Same flow on Mac and iOS: the system browser sheet opens the authorize page and catches the `yahadesk://` callback.
@MainActor
public final class PanLoginWindow: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let state = OAuthPKCE.random()
    #if os(macOS)
    private let fallbackAnchor = NSWindow()
    #endif
    private var session: ASWebAuthenticationSession?
    private var completion: CheckedContinuation<String, Error>?
    private static var current: PanLoginWindow?

    /// Browser login yields a one-time code (10 minutes); the hub exchanges it for the token pair.
    public static func run() async throws -> PanToken {
        current?.finish(.failure(CancellationError()))
        let login = PanLoginWindow()
        current = login
        let code = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { completion in
                login.completion = completion
                login.show()
            }
        } onCancel: {
            Task { @MainActor in login.finish(.failure(CancellationError())) }
        }
        return try await PanLogin.exchange(code: code)
    }

    /// Some browsers launch the Baidu 302 to `yahadesk://` through Launch Services instead of handing it to the
    /// session; the app's registered scheme lands here. The state check in `received` still applies.
    public static func open(_ url: URL) {
        guard url.scheme == PanLogin.redirectURI.scheme else { return }
        current?.received(url, error: nil)
    }

    private func show() {
        let session = ASWebAuthenticationSession(
            url: PanLogin.authorizeURL(state: state),
            callback: .customScheme(PanLogin.redirectURI.scheme!)
        ) { [weak self] url, error in
            Task { @MainActor [weak self] in self?.received(url, error: error) }
        }
        session.presentationContextProvider = self
        self.session = session
        guard session.start() else {
            finish(.failure(DeskProtocolError("无法打开默认浏览器，请重试")))
            return
        }
    }

    private func received(_ url: URL?, error: Error?) {
        if let error {
            let failure = error as NSError
            if failure.domain == ASWebAuthenticationSessionErrorDomain,
               failure.code == ASWebAuthenticationSessionError.Code.canceledLogin.rawValue {
                finish(.failure(CancellationError()))
            } else {
                finish(.failure(DeskProtocolError("默认浏览器未完成网盘登录，请重试")))
            }
            return
        }
        guard let url, case let .code(code) = PanLogin.navigation(url, state: state) else {
            finish(.failure(DeskProtocolError("网盘登录未完成或被拒绝")))
            return
        }
        #if os(macOS)
        NSApp.activate()
        #endif
        finish(.success(code))
    }

    private func finish(_ result: Result<String, Error>) {
        guard let completion else { return }
        self.completion = nil
        session?.cancel()
        session = nil
        if Self.current === self { Self.current = nil }
        completion.resume(with: result)
    }

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        return NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) ?? fallbackAnchor
        #else
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive }?.keyWindow ?? scenes.first?.keyWindow ?? ASPresentationAnchor()
        #endif
    }
}
