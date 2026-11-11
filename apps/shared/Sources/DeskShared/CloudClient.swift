import Foundation
import DeskProtocol

public struct OAuthGrant: Codable, Sendable {
    public let clientID: String
    public let refreshToken: String
    public let accessToken: String
    public let expiresAt: Date
    public init(clientID: String, refreshToken: String, accessToken: String, expiresAt: Date) {
        self.clientID = clientID; self.refreshToken = refreshToken
        self.accessToken = accessToken; self.expiresAt = expiresAt
    }
}

public struct OAuthAccessToken: Sendable {
    public let accessToken: String
    public let expiresAt: Date
}

/// All credential-bearing requests use same-origin endpoints and refuse redirects.
public final class CloudClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public static let serviceURL = URL(string: "https://hub.flyaha.top")!
    public static let controllerScope = "desk.configure"
    public let issuer: URL
    private let configuration: URLSessionConfiguration
    private lazy var session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    private var resource: URL { issuer.appendingPathComponent("api/v1/mcp") }

    public init(issuer: URL = CloudClient.serviceURL, configuration: URLSessionConfiguration = .ephemeral) {
        self.issuer = issuer; self.configuration = configuration
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    @MainActor
    public func authorize(clientID: String, scope: String, openBrowser: (URL) -> Bool) async throws -> OAuthGrant {
        let state = OAuthPKCE.random()
        let receiver = try LoopbackReceiver(state: state, issuer: issuer)
        defer { receiver.cancel() }
        return try await authorize(clientID: clientID, scope: scope, redirect: receiver.redirectURL, state: state) {
            guard openBrowser($0) else { throw DeskProtocolError("无法打开授权页面") }
            return try await receiver.receive()
        }
    }

    /// App 私有回调（RFC 8252 §7.1）：present 打开授权页并返回回调 URL，如 ASWebAuthenticationSession。
    @MainActor
    public func authorize(clientID: String, scope: String, redirect: URL,
                          present: (URL) async throws -> URL) async throws -> OAuthGrant {
        let state = OAuthPKCE.random()
        return try await authorize(clientID: clientID, scope: scope, redirect: redirect, state: state) {
            try OAuthCallback.code(from: try await present($0), redirect: redirect, state: state, issuer: issuer)
        }
    }

    @MainActor
    private func authorize(clientID: String, scope: String, redirect: URL, state: String,
                           code: (URL) async throws -> String) async throws -> OAuthGrant {
        guard !clientID.isEmpty else { throw DeskProtocolError("授权配置缺失，请重新连接工作台") }
        let endpoints = try await discover()
        try Task.checkCancellation()
        let verifier = OAuthPKCE.random()
        var url = URLComponents(url: endpoints.authorization, resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "response_type", value: "code"),
                         .init(name: "client_id", value: clientID), .init(name: "scope", value: scope),
                         .init(name: "redirect_uri", value: redirect.absoluteString),
                         .init(name: "resource", value: resource.absoluteString), .init(name: "state", value: state),
                         .init(name: "code_challenge", value: OAuthPKCE.challenge(verifier)),
                         .init(name: "code_challenge_method", value: "S256")]
        guard let authURL = url.url else { throw DeskProtocolError("无法打开授权页面") }
        let code = try await code(authURL)
        try Task.checkCancellation()
        return try await grant(endpoint: endpoints.token, clientID: clientID, scope: scope, fields: [
            "grant_type": "authorization_code", "code": code, "code_verifier": verifier,
            "redirect_uri": redirect.absoluteString,
        ])
    }

    public func refresh(_ previous: OAuthGrant, scope: String) async throws -> OAuthGrant {
        let endpoints = try await discover()
        return try await grant(endpoint: endpoints.token, clientID: previous.clientID, scope: scope,
                               fields: ["grant_type": "refresh_token", "refresh_token": previous.refreshToken])
    }

    /// The installed secret is valid only for the fixed official service and the control scope.
    public func controllerToken(clientID: String, clientSecret: String) async throws -> OAuthAccessToken {
        guard issuer == Self.serviceURL else { throw DeskProtocolError("内置连接仅支持官方服务地址") }
        let endpoints = try await discover()
        let object = try await tokenResponse(endpoint: endpoints.token, clientID: clientID, scope: Self.controllerScope,
                                             fields: ["grant_type": "client_credentials", "client_secret": clientSecret])
        guard let access = object["access_token"] as? String, !access.isEmpty,
              (object["token_type"] as? String)?.lowercased() == "bearer",
              let ttl = object["expires_in"] as? Double, ttl.isFinite, ttl > 0,
              let scope = object["scope"] as? String,
              Set(scope.split(separator: " ").map(String.init)) == [Self.controllerScope] else {
            throw DeskProtocolError("内置连接必须仅获得 desk.configure 权限，请检查安装配置")
        }
        return OAuthAccessToken(accessToken: access, expiresAt: Date().addingTimeInterval(ttl))
    }

    public func callTool(_ name: String, arguments: [String: Any], accessToken: String) async throws -> Data {
        var req = URLRequest(url: resource, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments],
        ])
        let object = try await request(req)
        guard object["error"] == nil, let result = object["result"] as? [String: Any], result["isError"] as? Bool != true
        else { throw DeskProtocolError("云端操作失败，请检查授权、配置版本或稍后重试") }
        if let structured = result["structuredContent"] as? [String: Any] {
            return try JSONSerialization.data(withJSONObject: structured)
        }
        guard let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String,
              let data = text.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil
        else { throw DeskProtocolError("云端返回了无效配置") }
        return data
    }

    private func discover() async throws -> (authorization: URL, token: URL) {
        let req = URLRequest(url: issuer.appendingPathComponent(".well-known/oauth-authorization-server"), timeoutInterval: 20)
        let object = try await request(req)
        guard let declaredIssuer = object["issuer"] as? String,
              declaredIssuer.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ==
                issuer.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
              let auth = object["authorization_endpoint"] as? String, let authorization = URL(string: auth),
              let token = object["token_endpoint"] as? String, let endpoint = URL(string: token),
              sameOrigin(authorization), sameOrigin(endpoint)
        else { throw DeskProtocolError("授权服务元数据来源不匹配") }
        return (authorization, endpoint)
    }

    private func sameOrigin(_ url: URL) -> Bool {
        url.scheme == issuer.scheme && url.host == issuer.host && url.port == issuer.port &&
            url.user == nil && url.password == nil && url.fragment == nil
    }

    private func grant(endpoint: URL, clientID: String, scope: String, fields: [String: String]) async throws -> OAuthGrant {
        let object = try await tokenResponse(endpoint: endpoint, clientID: clientID, scope: scope, fields: fields)
        guard let access = object["access_token"] as? String, !access.isEmpty,
              let refresh = object["refresh_token"] as? String, !refresh.isEmpty,
              let ttl = object["expires_in"] as? Double, ttl > 0,
              let grantedScope = object["scope"] as? String,
              // 同意页可取消可选用途：只要求首个用途在、不多出未申请的。
              case let granted = Set(grantedScope.split(separator: " ")), case let asked = scope.split(separator: " "),
              let required = asked.first, granted.contains(required), granted.isSubset(of: asked)
        else { throw DeskProtocolError("授权范围不完整，请只授权所选应用的指定用途") }
        return OAuthGrant(clientID: clientID, refreshToken: refresh, accessToken: access,
                          expiresAt: Date().addingTimeInterval(ttl))
    }

    private func tokenResponse(endpoint: URL, clientID: String, scope: String, fields: [String: String]) async throws -> [String: Any] {
        var form = fields
        form["client_id"] = clientID
        form["resource"] = resource.absoluteString
        form["scope"] = scope
        var req = URLRequest(url: endpoint, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = OAuthPKCE.form(form)
        return try await request(req, requiredScope: scope)
    }

    private func request(_ req: URLRequest, requiredScope: String? = nil) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw DeskProtocolError("云端响应无效") }
        guard (200..<300).contains(http.statusCode), data.count <= 256 * 1024 else {
            if data.count <= 256 * 1024, let requiredScope,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["error"] as? String == "invalid_scope" {
                throw DeskProtocolError("应用未开通 \(requiredScope) 权限，请检查安装配置")
            }
            // Never echo server-controlled bodies; they can contain credential-bearing input.
            throw DeskProtocolError("云端请求失败（HTTP \(http.statusCode)），请重试或重新授权")
        }
        var payload = data
        if http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/event-stream") == true,
           let line = String(decoding: data, as: UTF8.self).split(separator: "\n").last(where: { $0.hasPrefix("data:") }) {
            payload = Data(line.dropFirst(5).utf8)
        }
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw DeskProtocolError("云端响应无效")
        }
        return object
    }
}
