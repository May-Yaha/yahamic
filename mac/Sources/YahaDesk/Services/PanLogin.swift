import Foundation
import Security
import WebKit
import DeskProtocol
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Baidu Pan implicit grant (response_type=token, ~30 days, no refresh token). The AppKey is a public client id;
/// the app secret is never needed here and must not appear in this app. Tokens are never logged.
enum PanLogin {
    static let appKey = "yausCBE5H5qb1qTFe40KpkP1x6zxXBrd"

    enum Navigation {
        case allow
        case reject
        case token(PanToken)
    }

    /// Union OAuth returns the implicit token in the authorization page fragment.
    static func isCallback(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "pan.baidu.com" &&
            url.path == "/union/oauth/authorize" && url.fragment != nil
    }

    static func authorizeURL(state: String) -> URL {
        var c = URLComponents(string: "https://pan.baidu.com/union/oauth/authorize")!
        c.queryItems = [.init(name: "response_type", value: "token"), .init(name: "client_id", value: appKey),
                        .init(name: "redirect_uri", value: ""), .init(name: "state", value: state)]
        return c.url!
    }

    /// authorize#access_token=…&expires_in=…&state=… → token; error, other page or wrong state → nil.
    static func parse(_ url: URL, state: String, now: Date = Date()) -> PanToken? {
        guard isCallback(url), let fragment = url.fragment else { return nil }
        var fields: [String: String] = [:]
        for pair in fragment.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = kv[0].removingPercentEncoding, fields[key] == nil else { return nil }
            guard kv.count == 1 || kv[1].removingPercentEncoding != nil else { return nil }
            fields[key] = kv.count > 1 ? kv[1].removingPercentEncoding! : ""
        }
        guard fields["state"] == state, let token = fields["access_token"], !token.isEmpty else { return nil }
        let lifetime = fields["expires_in"].flatMap(TimeInterval.init) ?? 2_592_000
        return PanToken(token: token, expires: now.addingTimeInterval(lifetime).timeIntervalSince1970)
    }

    /// A bearer token or OAuth error must never be rendered by an untrusted page in the login WebView.
    static func navigation(_ url: URL, state: String, now: Date = Date()) -> Navigation {
        if URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: {
            $0.name == "access_token" || $0.name == "error"
        }) == true { return .reject }
        if let token = parse(url, state: state, now: now) { return .token(token) }
        guard let fragment = url.fragment else { return .allow }
        let names = fragment.split(separator: "&").map { pair in
            let raw = pair.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
            return raw.removingPercentEncoding ?? raw
        }
        return names.contains(where: { $0 == "access_token" || $0 == "error" || $0 == "state" }) ? .reject : .allow
    }
}

struct PanToken: Codable, Equatable {
    let token: String
    let expires: TimeInterval  // unix seconds
    func valid(at now: Date = Date()) -> Bool { expires - now.timeIntervalSince1970 > 60 }
}

enum PanKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "yahadesk.netdisk",
         kSecAttrAccount as String: "access_token"]
    }
    static func save(_ token: PanToken) -> Bool {
        guard let data = try? JSONEncoder().encode(token) else { return false }
        _ = delete()
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        return SecItemAdd(query.merging(attrs) { _, new in new } as CFDictionary, nil) == errSecSuccess
    }
    static func load() -> PanToken? {
        var item: CFTypeRef?
        let lookup = query.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { _, new in new }
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(PanToken.self, from: data)
    }
    static func delete() -> Bool {
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// Login page in a WKWebView window. The direct fragment response is intercepted and cancelled here.
/// Non-persistent data store: no Baidu cookies are kept.
#if os(macOS)
@MainActor
final class PanLoginWindow: NSObject, WKNavigationDelegate, NSWindowDelegate {
    private let state = OAuthPKCE.random()
    private var window: NSWindow?
    private var completion: CheckedContinuation<PanToken, Error>?
    private static var current: PanLoginWindow?  // keeps the window alive until it finishes

    static func run() async throws -> PanToken {
        current?.finish(.failure(CancellationError()))
        let login = PanLoginWindow()
        current = login
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { completion in
                login.completion = completion
                login.show()
            }
        } onCancel: {
            Task { @MainActor in login.finish(.failure(CancellationError())) }
        }
    }

    private func show() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 420, height: 640), configuration: configuration)
        web.navigationDelegate = self
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "登录百度网盘"
        window.contentView = web
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        web.load(URLRequest(url: PanLogin.authorizeURL(state: state)))
    }

    private func finish(_ result: Result<PanToken, Error>) {
        guard let completion else { return }
        self.completion = nil
        window?.delegate = nil
        window?.close()
        window = nil
        if Self.current === self { Self.current = nil }
        completion.resume(with: result)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.allow) }
        switch PanLogin.navigation(url, state: state) {
        case .allow:
            decisionHandler(.allow)
        case .reject:
            decisionHandler(.cancel)
            finish(.failure(DeskProtocolError("网盘登录未完成或被拒绝")))
        case let .token(token):
            decisionHandler(.cancel)
            finish(.success(token))
        }
    }

    func windowWillClose(_ notification: Notification) { finish(.failure(CancellationError())) }
}
#elseif os(iOS)
@MainActor
final class PanLoginWindow: NSObject, WKNavigationDelegate, UIAdaptivePresentationControllerDelegate {
    private let state = OAuthPKCE.random()
    private var controller: UIViewController?
    private var completion: CheckedContinuation<PanToken, Error>?
    private static var current: PanLoginWindow?

    static func run() async throws -> PanToken {
        current?.finish(.failure(CancellationError()))
        let login = PanLoginWindow()
        current = login
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { completion in
                login.completion = completion
                login.show()
            }
        } onCancel: {
            Task { @MainActor in login.finish(.failure(CancellationError())) }
        }
    }

    private func show() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
        let controller = UIViewController()
        controller.view = web
        controller.title = "登录百度网盘"
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .formSheet
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: {
            $0.activationState == .foregroundActive
        }), let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else {
            finish(.failure(DeskProtocolError("请回到应用后再登录网盘")))
            return
        }
        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }
        self.controller = navigation
        presenter.present(navigation, animated: true)
        navigation.presentationController?.delegate = self
        web.load(URLRequest(url: PanLogin.authorizeURL(state: state)))
    }

    private func finish(_ result: Result<PanToken, Error>) {
        guard let completion else { return }
        self.completion = nil
        controller?.dismiss(animated: true)
        controller = nil
        if Self.current === self { Self.current = nil }
        completion.resume(with: result)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.allow) }
        switch PanLogin.navigation(url, state: state) {
        case .allow:
            decisionHandler(.allow)
        case .reject:
            decisionHandler(.cancel)
            finish(.failure(DeskProtocolError("网盘登录未完成或被拒绝")))
        case let .token(token):
            decisionHandler(.cancel)
            finish(.success(token))
        }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        finish(.failure(CancellationError()))
    }
}
#endif
