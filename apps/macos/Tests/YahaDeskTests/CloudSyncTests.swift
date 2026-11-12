import AppKit
import CryptoKit
import DeskCore
import DeskProtocol
import DeskShared
import Foundation
import SwiftUI
import Testing
@testable import YahaDesk

private final class CloudProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Data, TimeInterval))?
    nonisolated(unsafe) static var status: (URLRequest) -> Int = { _ in 200 }
    private var stopped = false
    private let stateLock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.lock.withLock({ Self.handler }) else { return }
        var normalized = request
        if normalized.httpBody == nil, let stream = normalized.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(bytes, count: count)
            }
            normalized.httpBody = data
        }
        let (body, delay) = handler(normalized)
        let status = Self.lock.withLock { Self.status(normalized) }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            guard !self.stateLock.withLock({ self.stopped }) else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { stateLock.withLock { stopped = true } }
}

// Throwaway self-signed P-256 cert, CN yd_0123456789abcdefghijklmnop; its key was discarded.
private let panCertificate = Data(base64Encoded: """
    MIIBhDCCASqgAwIBAgIUaUDCcksq6mH0oWum7KpnBZNLU4YwCgYIKoZIzj0EAwIwKDEmMCQGA1UEAwwdeWRfMDEyMzQ1Njc4OWFiY2RlZmdoaWprbG1ub3AwHhcNMjYxMTA1MTEwOTQzWhcNMjYxMTA2MTEwOTQzWjAoMSYwJAYDVQQDDB15ZF8wMTIzNDU2Nzg5YWJjZGVmZ2hpamtsbW5vcDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABOVhp5Kj8gKGlpZFTHhRawdqYRXjycLgtTrhre+p/VK1yNRl8A7J9AINpW8l+kJlT2nruCFLx52qd1jdaGGFbJKjMjAwMB0GA1UdDgQWBBQAgJiJriWG19OtFC96E0sE6tr8pzAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0gAMEUCIA2jwAjaOIAUeNYBM7+EIBDf3eHFBPGD0eNyldOOr7PZAiEArosN8mJjTHM3Swh4Vv0LoDQYyBVtVefl45+IwujI7dY=
    """)!

@Suite(.serialized)
@MainActor
struct CloudSyncTests {
    @Test func voiceProfileDeleteUsesScopedSynchronousPanOperation() async throws {
        let lock = NSLock()
        nonisolated(unsafe) var captured: URLRequest?
        CloudProtocol.lock.withLock {
            CloudProtocol.handler = { request in
                lock.withLock { captured = request }
                return (Data(#"{"errno":0,"info":[{"errno":0,"path":"ok"}]}"#.utf8), 0)
            }
            CloudProtocol.status = { _ in 200 }
        }
        defer { CloudProtocol.lock.withLock { CloudProtocol.handler = nil } }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudProtocol.self]
        let path = PanFiles.voiceProfileRoot + "/profile-a/phrase-1.wav"

        try await PanFiles(token: "pan-test", session: URLSession(configuration: configuration))
            .deleteVoiceProfile(paths: [path])

        let request = try #require(lock.withLock { captured })
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.first { $0.name == "method" }?.value == "filemanager")
        #expect(query.first { $0.name == "opera" }?.value == "delete")
        #expect(query.first { $0.name == "access_token" }?.value == "pan-test")
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8)!
        let fields = URLComponents(string: "?" + body)!.queryItems!
        #expect(fields.first { $0.name == "async" }?.value == "0")
        let fileList = try #require(fields.first { $0.name == "filelist" }?.value)
        #expect(try JSONSerialization.jsonObject(with: Data(fileList.utf8)) as? [String] == [path])
    }

    private func model(openBrowser: @escaping (URL) -> Bool = { _ in false },
                       load: @escaping () -> OAuthGrant? = { nil }, loadClientSecret: @escaping () -> String? = { nil },
                       save: @escaping (OAuthGrant) -> Bool = { _ in true }, delete: @escaping () -> Bool = { true },
                       status: @escaping (URLRequest) -> Int = { _ in 200 },
                       _ handler: @escaping (URLRequest) -> (Data, TimeInterval)) -> CloudSync {
        CloudProtocol.lock.withLock { CloudProtocol.handler = handler; CloudProtocol.status = status }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudProtocol.self]
        return CloudSync(client: CloudClient(configuration: configuration), load: load, save: save, delete: delete,
                         openBrowser: openBrowser, loadClientSecret: loadClientSecret)
    }
    private func grant(_ account: String = "controller") -> OAuthGrant {
        OAuthGrant(clientID: account, refreshToken: "test-refresh", accessToken: account,
                   expiresAt: Date().addingTimeInterval(3600))
    }
    private let prepared = Data(#"{"jsonrpc":"2.0","id":1,"result":{"structuredContent":{"client_id":"device-client"}}}"#.utf8)
    private func rpc(_ request: URLRequest) -> (name: String, arguments: [String: Any]) {
        let json = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let params = json["params"] as! [String: Any]
        return (params["name"] as! String, params["arguments"] as! [String: Any])
    }
    private func waitUntil(timeout: TimeInterval = 3, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            guard Date() < deadline else { throw DeskProtocolError("等待模拟请求超时") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private func deviceState(_ connection: Uplink.Connection?) -> Uplink.State {
        var state = Uplink.State()
        state.connected = connection != nil; state.connection = connection
        state.supportsCloud = connection != nil
        return state
    }
    private func authorizationResponse(_ request: URLRequest) -> Data {
        if request.url!.path == "/api/v1/mcp" {
            #expect(rpc(request).name == "desk_prepare_device")
            return prepared
        }
        let payload: [String: Any] = request.url!.path.contains("well-known")
            ? ["issuer": "https://hub.flyaha.top", "authorization_endpoint": "https://hub.flyaha.top/auth/oauth2/authorize",
               "token_endpoint": "https://hub.flyaha.top/auth/oauth2/token"]
            : ["access_token": "test-access", "refresh_token": "test-device-refresh", "expires_in": 3600, "scope": "desk.sync"]
        return try! JSONSerialization.data(withJSONObject: payload)
    }
    /// The only controller-token request left: desk_prepare_device. The default browser stub refuses, ending the flow.
    private func prepareDevice(_ cloud: CloudSync) async throws {
        cloud.updateDeviceState(deviceState(Uplink.Connection(peripheralID: UUID())))
        cloud.authorizeDevice()
        try await waitUntil { !cloud.deviceBusy }
    }
    private func completeAuthorization(_ browserURL: URL) async throws {
        let query = URLComponents(url: browserURL, resolvingAgainstBaseURL: false)!.queryItems!
        var callback = URLComponents(string: query.first { $0.name == "redirect_uri" }!.value!)!
        callback.queryItems = [.init(name: "code", value: "test-code"),
                               .init(name: "state", value: query.first { $0.name == "state" }!.value!),
                               .init(name: "iss", value: "https://hub.flyaha.top/")]
        _ = try? await URLSession.shared.data(from: try #require(callback.url))
    }

    @Test(arguments: [30.0, 3600.0])
    func builtInControlRequestsOnlyControlScopeAndRenewsWithoutRefreshToken(ttl: Double) async throws {
        let lock = NSLock()
        nonisolated(unsafe) var forms = [[String: String]]()
        let cloud = model(loadClientSecret: { "test-secret + &" }) { request in
            if request.url!.path.contains("well-known") { return (self.authorizationResponse(request), 0) }
            if request.url!.path.contains("/token") {
                let encoded = String(decoding: request.httpBody!, as: UTF8.self).replacingOccurrences(of: "+", with: " ")
                let pairs = URLComponents(string: "?\(encoded)")!.queryItems!
                lock.withLock { forms.append(Dictionary(uniqueKeysWithValues: pairs.map { ($0.name, $0.value ?? "") })) }
                return (try! JSONSerialization.data(withJSONObject: ["access_token": "test-control", "token_type": "Bearer",
                            "expires_in": ttl, "scope": "desk.configure"]), 0)
            }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-control")
            #expect(!String(decoding: request.httpBody!, as: UTF8.self).contains("test-secret"))
            return (self.prepared, 0)
        }
        defer { cloud.stop() }
        cloud.start()
        #expect(cloud.clientID == "yaha_7PdNbrTFEGxFJMldoLGYTpXO")
        guard cloud.clientID != nil else { return }
        #expect(lock.withLock { forms }.isEmpty)  // No request until the device needs authorization.
        try await prepareDevice(cloud)
        try await prepareDevice(cloud)
        let requests = lock.withLock { forms }
        #expect(requests.count == (ttl < 60 ? 2 : 1))
        #expect(requests.allSatisfy {
            $0["scope"] == "desk.configure" && $0["grant_type"] == "client_credentials" &&
            $0["client_id"] == "yaha_7PdNbrTFEGxFJMldoLGYTpXO" && $0["client_secret"] == "test-secret + &" &&
            $0["resource"] == "https://hub.flyaha.top/api/v1/mcp" && $0["refresh_token"] == nil
        })
    }

    @Test func missingInstallationCredentialsKeepsExistingPKCEAuthorization() async throws {
        let lock = NSLock()
        nonisolated(unsafe) var prepares = 0
        let cloud = model(load: { self.grant("existing-public-client") }) { request in
            if request.url!.path == "/api/v1/mcp" {
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer existing-public-client")
                lock.withLock { prepares += 1 }
            }
            return (self.authorizationResponse(request), 0)
        }
        defer { cloud.stop() }
        cloud.start()
        #expect(cloud.clientID == "existing-public-client" && cloud.authenticationMode == .pkce)
        try await prepareDevice(cloud)
        #expect(lock.withLock { prepares } == 1)
    }

    @Test func builtInConnectionKeepsOldGrantForLaterFallback() async throws {
        var stored: OAuthGrant? = grant("existing-public-client")
        var secret: String? = "test-secret"
        let cloud = model(load: { stored }, loadClientSecret: { secret }, save: { stored = $0; return true },
                          delete: { stored = nil; return true }) { _ in Issue.record("切换凭据不应请求网络"); return (Data(), 0) }
        defer { cloud.stop() }
        cloud.start()
        #expect(cloud.authenticationMode == .clientCredentials)
        cloud.disconnect()
        #expect(stored?.clientID == "existing-public-client")
        secret = nil
        cloud.start()
        #expect(cloud.authenticationMode == .pkce && cloud.clientID == "existing-public-client")
    }

    @Test func legacyPKCEAuthorizationStillRotatesItsRefreshToken() async throws {
        var stored = OAuthGrant(clientID: "existing-public-client", refreshToken: "test-old-refresh", accessToken: "old",
                                expiresAt: Date.distantPast)
        let cloud = model(load: { stored }, save: { stored = $0; return true }) { request in
            if request.url!.path.contains("well-known") { return (self.authorizationResponse(request), 0) }
            if request.url!.path.contains("/token") {
                let body = String(decoding: request.httpBody!, as: UTF8.self)
                #expect(body.contains("grant_type=refresh_token") && body.contains("refresh_token=test-old-refresh"))
                #expect(!body.contains("client_secret="))
                return (Data(#"{"access_token":"test-new","refresh_token":"test-new-refresh","expires_in":3600,"scope":"desk.configure"}"#.utf8), 0)
            }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-new")
            return (self.prepared, 0)
        }
        defer { cloud.stop() }
        cloud.start()
        try await prepareDevice(cloud)
        #expect(stored.refreshToken == "test-new-refresh")
        #expect(cloud.authenticationMode == .pkce)
    }

    @Test(arguments: [false, true])
    func revokedLegacyGrantCanReauthorizeItsSavedClientWithoutInputOrDeletion(cancel: Bool) async throws {
        var stored = OAuthGrant(clientID: "existing-public-client", refreshToken: "revoked", accessToken: "expired",
                                expiresAt: Date.distantPast)
        var browserURL: URL?
        let revoked = { (request: URLRequest) -> Bool in
            request.url!.path.contains("/token") && String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains("grant_type=refresh_token")
        }
        let cloud = model(openBrowser: { browserURL = $0; return true }, load: { stored }, save: { stored = $0; return true },
                          delete: { Issue.record("重新授权不得先删除旧授权"); return false },
                          status: { revoked($0) ? 400 : 200 }) { request in
            if request.url!.path.contains("well-known") { return (self.authorizationResponse(request), 0) }
            if request.url!.path.contains("/token") {
                return revoked(request) ? (Data(#"{"error":"invalid_grant"}"#.utf8), 0)
                    : (Data(#"{"access_token":"test-new","refresh_token":"test-new-refresh","expires_in":3600,"scope":"desk.configure"}"#.utf8), 0)
            }
            return (self.prepared, 0)
        }
        defer { cloud.stop() }
        cloud.start()
        try await prepareDevice(cloud)
        #expect(cloud.authorizationMessage != nil && browserURL == nil)
        #expect(stored.refreshToken == "revoked" && cloud.authenticationMode == .pkce)
        cloud.reauthorizeLegacyController()
        try await waitUntil { browserURL != nil || (cloud.lastError != nil && !cloud.requestBusy) }
        #expect(browserURL != nil)
        guard let browserURL else { return }
        let query = URLComponents(url: browserURL, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.first { $0.name == "client_id" }?.value == "existing-public-client")
        #expect(query.first { $0.name == "scope" }?.value == "desk.configure")
        #expect(stored.refreshToken == "revoked")
        if cancel {
            cloud.cancelAuthorization()
            try await waitUntil { !cloud.authorizationBusy }
            #expect(stored.refreshToken == "revoked")
            #expect(cloud.status == "重新授权已取消")
            return
        }
        try await completeAuthorization(browserURL)
        try await waitUntil { !cloud.authorizationBusy }
        #expect(stored.refreshToken == "test-new-refresh" && cloud.status == "已重新授权工作台")
        #expect(cloud.authenticationMode == .pkce)
    }

    @Test(arguments: [false, true])
    func legacyReauthorizationFailureKeepsUsingSavedGrant(cancel: Bool) async throws {
        let stored = grant("existing-public-client")
        var browserOpened = false
        var holdBrowser = cancel  // Only the reauthorization browser waits; the later device browser refuses.
        let cloud = model(openBrowser: { _ in browserOpened = true; defer { holdBrowser = false }; return holdBrowser }, load: { stored },
                          save: { _ in Issue.record("失败或取消不得覆盖旧授权"); return false },
                          delete: { Issue.record("失败或取消不得删除旧授权"); return false }) { request in
            if request.url!.path == "/api/v1/mcp" {
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer existing-public-client")
            }
            return (self.authorizationResponse(request), 0)
        }
        defer { cloud.stop() }
        cloud.start()
        cloud.reauthorizeLegacyController()
        try await waitUntil { browserOpened }
        if cancel { cloud.cancelAuthorization() }
        try await waitUntil { !cloud.authorizationBusy }
        #expect(cloud.status == (cancel ? "重新授权已取消" : "重新授权未完成"))
        #expect(cloud.clientID == stored.clientID && cloud.authenticationMode == .pkce)
        try await prepareDevice(cloud)
    }

    @Test(arguments: [false, true])
    func legacyReauthorizationCannotResumeAfterStopOrDisconnect(disconnect: Bool) async throws {
        var browserOpened = false
        let lock = NSLock()
        nonisolated(unsafe) var reads = 0
        let cloud = model(openBrowser: { _ in browserOpened = true; return true }, load: { self.grant() }) { request in
            if !request.url!.path.contains("well-known") { lock.withLock { reads += 1 } }
            return (self.authorizationResponse(request), 0)
        }
        defer { cloud.stop() }
        cloud.start()
        cloud.reauthorizeLegacyController()
        try await waitUntil { browserOpened }
        if disconnect { cloud.disconnect() } else { cloud.stop() }
        try await waitUntil { !cloud.authorizationBusy }
        #expect(lock.withLock { reads } == 0)
        if disconnect { #expect(cloud.clientID == nil && cloud.status == "已断开工作台") }
        else { #expect(cloud.status == "重新授权已取消") }
    }

    @Test func missingInstallationCredentialsShowsSetupIssueWithoutRequestingInput() {
        let cloud = model { _ in Issue.record("配置缺失不应请求网络"); return (Data(), 0) }
        cloud.start()
        #expect(cloud.clientID == nil)
        #expect(cloud.status == "安装配置缺失")
        #expect(cloud.lastError?.contains("Client ID") != true)
    }

    @Test(arguments: ["invalid_scope", "wide_response_scope"])
    func builtInControlDoesNotFallBackToBroaderScope(failure: String) async throws {
        let cloud = model(loadClientSecret: { "test-secret" }, status: { request in
            request.url!.path.contains("/token") && failure == "invalid_scope" ? 400 : 200
        }) { request in
            if request.url!.path.contains("well-known") { return (self.authorizationResponse(request), 0) }
            #expect(request.url!.path.contains("/token"))
            let object: [String: Any] = failure == "invalid_scope" ? ["error": "invalid_scope"]
                : ["access_token": "test-wide", "token_type": "Bearer", "expires_in": 3600, "scope": "desk.configure desk.sync"]
            return (try! JSONSerialization.data(withJSONObject: object), 0)
        }
        defer { cloud.stop() }
        cloud.start()
        #expect(cloud.clientID != nil)
        guard cloud.clientID != nil else { return }
        try await prepareDevice(cloud)
        #expect(cloud.authorizationMessage?.contains("desk.configure") == true)
    }

    @Test func installedSecretCannotBeSentToAnotherIssuer() async throws {
        CloudProtocol.lock.withLock { CloudProtocol.handler = { _ in Issue.record("不得向其他服务请求内置凭据"); return (Data(), 0) } }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudProtocol.self]
        let client = CloudClient(issuer: URL(string: "https://other.example")!, configuration: configuration)
        do {
            _ = try await client.controllerToken(clientID: "test-client", clientSecret: "test-secret")
            Issue.record("非官方服务应拒绝内置连接")
        } catch { #expect(error.localizedDescription.contains("官方服务")) }
    }

    /// 服务端只给管理员的设备应用加 desk.operate；其它值（含越界组合）一律只申请 desk.sync。
    /// 默认令牌响应只给 desk.sync，覆盖同意页取消可选的 desk.operate 仍能交付设备。
    @Test(arguments: [(nil, "desk.sync"), ("desk.sync desk.operate", "desk.sync desk.operate"),
                      ("desk.sync desk.configure", "desk.sync"), ("desk.operate", "desk.sync")] as [(String?, String)])
    func deviceAuthorizationUsesServerPreparedPublicApplication(prepared scope: String?, requested: String) async throws {
        var browserURL: URL?
        let lock = NSLock()
        nonisolated(unsafe) var prepareCount = 0
        let cloud = model(openBrowser: { browserURL = $0; return true }) { request in
            if request.url!.path == "/api/v1/mcp" {
                #expect(self.rpc(request).name == "desk_prepare_device")
                lock.withLock { prepareCount += 1 }
                var content: [String: Any] = ["client_id": "owner-device-client"]
                if let scope { content["scope"] = scope }
                return (try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "result": ["structuredContent": content]]), 0)
            }
            return (self.authorizationResponse(request), 0)
        }
        try cloud.connect(grant())
        defer { cloud.stop() }
        let target = Uplink.Connection(peripheralID: UUID())
        cloud.updateDeviceState(deviceState(target))
        var deliveredID: String?
        cloud.grantApplyTimeout = .milliseconds(30); cloud.panPollInterval = .milliseconds(5)
        cloud.sendProvision = { command, connection in
            #expect(connection == target)
            if case .grant(let id, let token) = command { deliveredID = id; #expect(token == "test-device-refresh") }
        }
        cloud.authorizeDevice()
        try await waitUntil { browserURL != nil }
        let query = URLComponents(url: try #require(browserURL), resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.first { $0.name == "client_id" }?.value == "owner-device-client")
        #expect(query.first { $0.name == "scope" }?.value == requested)
        try await completeAuthorization(try #require(browserURL))
        try await waitUntil { !cloud.deviceBusy }
        #expect(lock.withLock { prepareCount } == 1)
        #expect(deliveredID == "owner-device-client")
    }

    @Test(arguments: ["", "controller", "yaha_7PdNbrTFEGxFJMldoLGYTpXO"])
    func deviceAuthorizationRejectsInvalidPreparedApplication(id: String) async throws {
        let cloud = model(openBrowser: { _ in Issue.record("无效设备应用不得打开浏览器"); return false }) { request in
            if request.url!.path == "/api/v1/mcp", self.rpc(request).name == "desk_prepare_device" {
                return (try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1,
                    "result": ["structuredContent": ["client_id": id]]]), 0)
            }
            return (self.authorizationResponse(request), 0)
        }
        try cloud.connect(grant())
        defer { cloud.stop() }
        cloud.updateDeviceState(deviceState(Uplink.Connection(peripheralID: UUID())))
        cloud.sendProvision = { _, _ in Issue.record("不得交付无效设备授权") }
        cloud.authorizeDevice()
        try await waitUntil { !cloud.deviceBusy }
        #expect(cloud.authorizationMessage == "设备授权配置无效，请检查工作台连接")
        #expect(!cloud.requestBusy)
    }

    /// 令牌响应多出未申请用途、或缺了 desk.sync，都不交付设备。
    @Test(arguments: ["desk.sync desk.configure", "desk.operate", "desk.sync desk.operate desk.configure"])
    func deviceAuthorizationRejectsUnexpectedGrantedScope(granted: String) async throws {
        var browserURL: URL?
        let cloud = model(openBrowser: { browserURL = $0; return true }) { request in
            if request.url!.path == "/api/v1/mcp" {
                return (Data(#"{"jsonrpc":"2.0","id":1,"result":{"structuredContent":{"client_id":"owner-device-client","scope":"desk.sync desk.operate"}}}"#.utf8), 0)
            }
            if request.url!.path.contains("/token") {
                return (try! JSONSerialization.data(withJSONObject: ["access_token": "a", "refresh_token": "r", "expires_in": 3600, "scope": granted]), 0)
            }
            return (self.authorizationResponse(request), 0)
        }
        try cloud.connect(grant())
        defer { cloud.stop() }
        cloud.updateDeviceState(deviceState(Uplink.Connection(peripheralID: UUID())))
        cloud.sendProvision = { _, _ in Issue.record("不得交付越界设备授权") }
        cloud.authorizeDevice()
        try await waitUntil { browserURL != nil }
        try await completeAuthorization(try #require(browserURL))
        try await waitUntil { !cloud.deviceBusy }
        #expect(cloud.authorizationMessage?.contains("授权范围") == true)
    }

    @Test func wifiScanWaitsForNewerDeviceListAndClearsOnDisconnect() async throws {
        let cloud = model { _ in (Data(), 0) }
        let target = Uplink.Connection(peripheralID: UUID())
        var state = deviceState(target)
        state.supportsWiFiScan = true
        state.cloud.wifiScan = 4
        state.wifiNetworks = WiFiScan(scan: 4, networks: [.init(ssid: "旧网络", rssi: -50, secure: true)])
        cloud.updateDeviceState(state)
        var sent: [ProvisioningCommand] = []
        cloud.sendProvision = { command, connection in #expect(connection == target); sent.append(command) }
        await cloud.scanWiFi()
        #expect(sent.count == 1 && cloud.wifiScanning)
        if case .scanWiFi = sent.first {} else { Issue.record("应发送扫描指令") }
        cloud.updateDeviceState(state)  // Same scan count: the old list is not the answer.
        #expect(cloud.wifiScanning)
        await cloud.scanWiFi()
        #expect(sent.count == 1)
        state.cloud.wifiScan = 5
        state.wifiNetworks = WiFiScan(scan: 5, networks: [.init(ssid: "家里", rssi: -40, secure: false)])
        cloud.updateDeviceState(state)
        #expect(!cloud.wifiScanning && cloud.wifiNetworks.map(\.ssid) == ["家里"])
        #expect(cloud.deviceMessage == "请选择 Wi-Fi 并输入密码")
        await cloud.scanWiFi()
        cloud.updateDeviceState(deviceState(nil))
        #expect(!cloud.wifiScanning && cloud.wifiNetworks.isEmpty && !cloud.deviceSupportsWiFiScan)
    }

    @Test func wifiScanFailureDoesNotStaySpinning() async throws {
        let cloud = model { _ in (Data(), 0) }
        var state = deviceState(Uplink.Connection(peripheralID: UUID()))
        state.supportsWiFiScan = true
        cloud.updateDeviceState(state)
        cloud.sendProvision = { _, _ in throw DeskProtocolError("设备拒绝了设置，请检查配置后重试") }
        await cloud.scanWiFi()
        #expect(!cloud.wifiScanning && cloud.deviceMessage == "设备拒绝了设置，请检查配置后重试")
        cloud.sendProvision = { _, _ in }
        cloud.wifiScanTimeout = .milliseconds(10)
        await cloud.scanWiFi()  // The device never reports a newer list.
        #expect(cloud.wifiScanning)
        try await waitUntil { !cloud.wifiScanning }
        #expect(cloud.deviceMessage == "扫描没有完成，请重新扫描")
        state.supportsWiFiScan = false
        cloud.updateDeviceState(state)
        cloud.sendProvision = { _, _ in Issue.record("旧固件不得发送扫描指令") }
        await cloud.scanWiFi()
    }

    @Test func deviceAuthorizationIsCancelledWhenConnectionChangesDuringPreparation() async throws {
        let lock = NSLock()
        nonisolated(unsafe) var preparing = false
        let cloud = model(openBrowser: { _ in Issue.record("断连后不得打开授权浏览器"); return false }) { request in
            let prepare = request.url!.path == "/api/v1/mcp" && self.rpc(request).name == "desk_prepare_device"
            if prepare { lock.withLock { preparing = true } }
            return (self.authorizationResponse(request), prepare ? 0.1 : 0)
        }
        try cloud.connect(grant())
        defer { cloud.stop() }
        let first = Uplink.Connection(peripheralID: UUID())
        cloud.updateDeviceState(deviceState(first))
        cloud.sendProvision = { _, _ in Issue.record("断连后不得交付设备授权") }
        cloud.authorizeDevice()
        try await waitUntil { lock.withLock { preparing } }
        cloud.updateDeviceState(deviceState(Uplink.Connection(peripheralID: first.peripheralID)))
        try await waitUntil { !cloud.deviceBusy }
        #expect(cloud.authorizationMessage == "设备授权已取消")
        #expect(!cloud.requestBusy)
    }

    @Test(arguments: [false, true])
    func deviceAuthorizationDoesNotFollowChangedConnection(reconnectSameDevice: Bool) async throws {
        var browserURL: URL?
        let cloud = model(openBrowser: { browserURL = $0; return true }) { request in
            (self.authorizationResponse(request), 0)
        }
        defer { cloud.stop() }
        try cloud.connect(grant())
        let first = Uplink.Connection(peripheralID: UUID())
        let next = Uplink.Connection(peripheralID: reconnectSameDevice ? first.peripheralID : UUID())
        var deliveredTo = [Uplink.Connection]()
        cloud.updateDeviceState(deviceState(first))
        cloud.sendProvision = { _, target in deliveredTo.append(target) }
        cloud.authorizeDevice()
        try await waitUntil { browserURL != nil }
        cloud.updateDeviceState(deviceState(nil))
        cloud.updateDeviceState(deviceState(next))
        try await completeAuthorization(try #require(browserURL))
        try await waitUntil { !cloud.deviceBusy }
        #expect(deliveredTo.isEmpty)
        #expect(cloud.authorizationMessage == "设备授权已取消")
    }

    @Test(arguments: [false, true])
    func deviceAuthorizationRejectsConnectionChangeDuringTokenExchange(reconnectSameDevice: Bool) async throws {
        var browserURL: URL?
        let lock = NSLock()
        nonisolated(unsafe) var exchanging = false
        let cloud = model(openBrowser: { browserURL = $0; return true }) { request in
            let token = request.url!.path.contains("/token")
            if token { lock.withLock { exchanging = true } }
            return (self.authorizationResponse(request), token ? 0.1 : 0)
        }
        defer { cloud.stop() }
        try cloud.connect(grant())
        let first = Uplink.Connection(peripheralID: UUID())
        let next = Uplink.Connection(peripheralID: reconnectSameDevice ? first.peripheralID : UUID())
        var deliveredTo = [Uplink.Connection]()
        cloud.updateDeviceState(deviceState(first))
        cloud.sendProvision = { _, target in deliveredTo.append(target) }
        cloud.authorizeDevice()
        try await waitUntil { browserURL != nil }
        try await completeAuthorization(try #require(browserURL))
        try await waitUntil { lock.withLock { exchanging } }
        // A fresh session is sufficient to invalidate authorization even if no offline snapshot was observed.
        cloud.updateDeviceState(deviceState(next))
        try await waitUntil { !cloud.deviceBusy }
        #expect(deliveredTo.isEmpty)
        #expect(cloud.authorizationMessage == "设备授权已取消")
    }

    @Test func deviceAuthorizationDeliversOnlyToItsUnchangedAuthenticatedConnection() async throws {
        var browserURL: URL?
        let cloud = model(openBrowser: { browserURL = $0; return true }) { (self.authorizationResponse($0), 0) }
        defer { cloud.stop() }
        try cloud.connect(grant())
        let target = Uplink.Connection(peripheralID: UUID())
        var deliveredTo = [Uplink.Connection]()
        cloud.updateDeviceState(deviceState(target))
        cloud.grantApplyTimeout = .milliseconds(100); cloud.panPollInterval = .milliseconds(5)
        cloud.sendProvision = { command, connection in
            if case .grant(let id, let refreshToken) = command {
                #expect(id == "device-client" && refreshToken == "test-device-refresh")
                deliveredTo.append(connection)
                var applied = self.deviceState(target)
                applied.cloud.authorized = true
                cloud.updateDeviceState(applied)
            } else { Issue.record("应交付设备授权") }
        }
        cloud.authorizeDevice()
        try await waitUntil { browserURL != nil }
        var updated = deviceState(target)
        updated.rssi = -60
        cloud.updateDeviceState(updated)
        try await completeAuthorization(try #require(browserURL))
        try await waitUntil { !cloud.deviceBusy }
        #expect(deliveredTo == [target])
        #expect(cloud.authorizationMessage == "设备已授权，连上 Wi-Fi 后开始同步工作台")
    }

    @Test func deviceAuthorizationReportsWhenDeviceDoesNotApplyGrant() async throws {
        var browserURL: URL?
        let cloud = model(openBrowser: { browserURL = $0; return true }) { (self.authorizationResponse($0), 0) }
        defer { cloud.stop() }
        try cloud.connect(grant())
        cloud.updateDeviceState(deviceState(Uplink.Connection(peripheralID: UUID())))
        cloud.grantApplyTimeout = .milliseconds(30); cloud.panPollInterval = .milliseconds(5)
        cloud.sendProvision = { _, _ in }  // written, but authorized never turns true
        cloud.authorizeDevice()
        try await waitUntil { browserURL != nil }
        try await completeAuthorization(try #require(browserURL))
        try await waitUntil { !cloud.deviceBusy }
        #expect(cloud.authorizationMessage == "设备没有启用授权，请重试")
    }

    /// Once the grant is written the device keeps it; a later disconnect must not claim it was cancelled.
    @Test func deviceAuthorizationDisconnectAfterDeliveryIsNotCancellation() async throws {
        var browserURL: URL?
        let cloud = model(openBrowser: { browserURL = $0; return true }) { (self.authorizationResponse($0), 0) }
        defer { cloud.stop() }
        try cloud.connect(grant())
        cloud.updateDeviceState(deviceState(Uplink.Connection(peripheralID: UUID())))
        cloud.grantApplyTimeout = .seconds(2); cloud.panPollInterval = .milliseconds(5)
        cloud.sendProvision = { _, _ in
            Task { @MainActor in
                try await Task.sleep(for: .milliseconds(10))
                cloud.updateDeviceState(self.deviceState(nil))
            }
        }
        cloud.authorizeDevice()
        try await waitUntil { browserURL != nil }
        try await completeAuthorization(try #require(browserURL))
        try await waitUntil { !cloud.deviceBusy }
        #expect(cloud.authorizationMessage?.hasPrefix("授权已交付设备") == true)
    }

    /// Device sequence after a Wi-Fi write: old network drops, then DHCP (or never, on a wrong password).
    /// Like the real Uplink, the write returns first and the device state changes only afterwards.
    @Test(arguments: [true, false])
    func wifiConfigurationFollowsDeviceUntilJoined(joins: Bool) async throws {
        let cloud = model { _ in (Data(), 0) }
        let target = Uplink.Connection(peripheralID: UUID())
        var state = deviceState(target)
        state.cloud.wifiConnected = true  // still on the previous network
        cloud.updateDeviceState(state)
        cloud.wifiApplyTimeout = .milliseconds(200); cloud.wifiJoinTimeout = .milliseconds(80)
        cloud.panPollInterval = .milliseconds(5)
        cloud.sendProvision = { _, _ in
            Task { @MainActor in
                try await Task.sleep(for: .milliseconds(10))
                state.cloud.wifiConnected = false
                cloud.updateDeviceState(state)
                guard joins else { return }
                try await Task.sleep(for: .milliseconds(10))
                state.cloud.wifiConnected = true
                cloud.updateDeviceState(state)
            }
        }
        await cloud.configureWiFi(ssid: "家里", password: "12345678")
        #expect(!cloud.deviceBusy)
        #expect(joins ? cloud.deviceMessage == "已连上 Wi-Fi" : cloud.deviceMessage?.contains("请检查密码") == true)
    }

    /// A stale error and a still-true wifi_connected from the old network must not read as success.
    @Test(arguments: ["sync_failed", "reauthorize", "wifi_configuration_failed"])
    func wifiConfigurationIgnoresPreWriteSnapshot(staleError: String) async throws {
        let cloud = model { _ in (Data(), 0) }
        var state = deviceState(Uplink.Connection(peripheralID: UUID()))
        state.cloud.wifiConnected = true; state.cloud.error = staleError
        cloud.updateDeviceState(state)
        cloud.wifiApplyTimeout = .milliseconds(30); cloud.panPollInterval = .milliseconds(5)
        cloud.sendProvision = { _, _ in }  // device never acts on it
        await cloud.configureWiFi(ssid: "家里", password: "12345678")
        #expect(cloud.deviceMessage == "没有看到设备切换网络，请重新发送")
    }

    /// A failure reason explains the timeout, but only after the device cleared the previous network's reason.
    @Test(arguments: [true, false])
    func wifiConfigurationReportsJoinFailureReason(clears: Bool) async throws {
        let cloud = model { _ in (Data(), 0) }
        var state = deviceState(Uplink.Connection(peripheralID: UUID()))
        state.cloud.wifiReason = 201  // the old network was missing
        cloud.updateDeviceState(state)
        cloud.wifiApplyTimeout = .milliseconds(200); cloud.wifiJoinTimeout = .milliseconds(80)
        cloud.panPollInterval = .milliseconds(5)
        cloud.sendProvision = { _, _ in
            Task { @MainActor in
                try await Task.sleep(for: .milliseconds(10))
                if clears { state.cloud.wifiReason = 0; cloud.updateDeviceState(state) }
                try await Task.sleep(for: .milliseconds(10))
                state.cloud.wifiReason = 15
                cloud.updateDeviceState(state)
            }
        }
        await cloud.configureWiFi(ssid: "家里", password: "12345678")
        #expect(clears ? cloud.deviceMessage?.contains("密码可能不对") == true : cloud.deviceMessage?.contains("请检查密码") == true)
    }

    @Test func switchingAccountCancelsDeviceAuthorizationPreparedWithPreviousAccount() async throws {
        let cloud = model(openBrowser: { _ in Issue.record("切换账号后不得打开旧账号的设备授权"); return false }) { request in
            (self.authorizationResponse(request), request.url!.path == "/api/v1/mcp" ? 0.15 : 0)
        }
        try cloud.connect(grant())
        defer { cloud.disconnect() }
        cloud.updateDeviceState(deviceState(Uplink.Connection(peripheralID: UUID())))
        cloud.sendProvision = { _, _ in Issue.record("切换账号后不得交付设备授权") }
        cloud.authorizeDevice()
        try await waitUntil { cloud.requestBusy }
        try cloud.connect(grant("next-account"))
        try await waitUntil { !cloud.deviceBusy }
        #expect(cloud.clientID == "next-account" && cloud.authorizationMessage == "设备授权已取消")
        #expect(!cloud.requestBusy)
    }

    @Test func rendersDeviceSetupWithoutAppLifecycleOrCredentials() throws {
        // Only native SwiftUI view rendering: no HomeModel.start, BLE, browser or keychain operations.
        _ = NSApplication.shared
        let cloud = model { _ in
            Issue.record("静态渲染不应发起云端请求")
            return (Data(), 0)
        }
        let recordings = RecordingBackup(folder: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        let aiPolish = AIPolish()
        try render(DeviceSetupView(
            cloud: cloud,
            recordings: recordings,
            voiceProfile: VoiceProfile(folder: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)),
            firmware: FirmwareInstaller(),
            aiPolish: aiPolish,
            training: TrainingSet(speech: LocalSpeechRecognizer(), polish: aiPolish, recordings: recordings,
                                  folder: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            models: OfflineModels(),
            deviceFirmware: "0.3.0"
        ), name: "device-setup", width: 620, height: 1_300)
    }

    /// Bind against a mocked Pan DMS. `answers` controls whether the device returns a proof.
    private func bindPan(answers: Bool) async throws -> (cloud: CloudSync, methods: [String], ops: [String], logs: [String]) {
        let dev = "abc123def456ghi789", challenge = "AbCd-_0123456789xyz"
        let lock = NSLock()
        nonisolated(unsafe) var methods = [String](), ops = [String](), logs = [String]()
        let cloud = model { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let method = query.first { $0.name == "method" }!.value!
            #expect(query.first { $0.name == "access_token" }?.value == "pan-test")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "pan.baidu.com")
            lock.withLock { methods.append(method) }
            var reply: [String: Any] = ["errno": 0]
            switch method {
            case "register": reply["device_id"] = dev
            case "iotcorechallenge": reply["challenge"] = challenge
            case "iotcoreprovision":
                let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                #expect(body["challenge"] as? String == challenge && body["sig"] as? String == "device-sig")
                #expect(body["cert"] as? String == OAuthPKCE.base64URL(panCertificate))
                reply.merge(["auth_type": "SIGNATURE", "credential_id": dev, "core_id": "core", "credential": "iot-secret",
                             "mqtt_url": "ssl://mqtt:8883", "command_topic": "t/cmd"]) { _, new in new }
            default: break
            }
            return (try! JSONSerialization.data(withJSONObject: reply), 0)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudProtocol.self]
        cloud.dmsSession = URLSession(configuration: configuration)
        cloud.proofTimeout = .milliseconds(200); cloud.onlineTimeout = .milliseconds(200)
        cloud.panPollInterval = .milliseconds(5)
        cloud.log = { line in lock.withLock { logs.append(line) } }
        cloud.panLogin = { PanToken(token: "pan-test", expires: Date().timeIntervalSince1970 + 3600) }
        cloud.savePanToken = { _ in true }
        cloud.loadPanToken = { PanToken(token: "pan-test", expires: Date().timeIntervalSince1970 + 3600) }
        cloud.readIdentity = { _ in panCertificate }
        nonisolated(unsafe) var state = deviceState(Uplink.Connection(peripheralID: UUID()))
        state.supportsPan = true
        cloud.updateDeviceState(state)
        cloud.sendProvision = { command, _ in
            let op = (try JSONSerialization.jsonObject(with: command.encoded()) as! [String: String])["op"]!
            lock.withLock { ops.append(op) }
            guard answers else { return }
            await MainActor.run {
                if op == "dms_proof" { state.cloud.deviceID = dev; state.cloud.proof = "device-sig" }
                if op == "dms" { state.cloud.dms = "online" }
                cloud.updateDeviceState(state)
            }
        }
        await cloud.loginPan()
        #expect(cloud.panLoggedIn && cloud.canBindPan)
        await cloud.bindPan()
        return lock.withLock { (cloud, methods, ops, logs) }
    }

    @Test func bindPanSignsProvisionsAndWaitsOnline() async throws {
        let (cloud, methods, ops, logs) = try await bindPan(answers: true)
        #expect(methods == ["register", "bind", "iotcorechallenge", "iotcoreprovision"])
        #expect(ops == ["dms_proof", "dms"])
        #expect(cloud.panMessage == "网盘绑定完成，设备已在线" && cloud.panStatus == "在线" && cloud.canUnbindPan)
        #expect(!logs.contains { $0.contains("pan-test") || $0.contains("iot-secret") || $0.contains("device-sig") })
    }

    @Test func bindPanRollsBackWhenDeviceDoesNotSign() async throws {
        let (cloud, methods, ops, _) = try await bindPan(answers: false)
        #expect(methods == ["register", "bind", "iotcorechallenge", "iotcorecommand", "unbind"])
        #expect(ops == ["dms_proof", "dms_reset"])
        #expect(cloud.panMessage == "设备没有返回签名，请重试" && !cloud.panBusy && !cloud.deviceBusy)
    }

    @Test func recordingIsKeptLocallyUntilPanAcceptsIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yd-rec-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let lock = NSLock()
        nonisolated(unsafe) var calls: [String] = []
        nonisolated(unsafe) var mode = "full"  // full, http500, nofsid, expired, ok
        nonisolated(unsafe) var creates = 0
        nonisolated(unsafe) var stored: [String] = []
        CloudProtocol.lock.withLock {
            CloudProtocol.status = { _ in 200 }
            CloudProtocol.handler = { request in
                let q = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                let m = q.first { $0.name == "method" }!.value!
                #expect(q.first { $0.name == "access_token" }?.value == "pan-test")
                #expect(request.value(forHTTPHeaderField: "User-Agent") == "pan.baidu.com")
                lock.withLock { calls.append(m) }
                let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
                var reply: [String: Any] = ["errno": 0]
                switch m {
                case "precreate":
                    switch lock.withLock({ mode }) {
                    case "full": reply["errno"] = -10
                    case "expired": reply["errno"] = 111  // sent with HTTP 401 below
                    default: break
                    }
                    if reply["errno"] as? Int != 0 { break }
                    #expect(body.contains("path=%2Fapps%2F%E6%8B%BE%E8%A7%81%2F%E5%BD%95%E9%9F%B3%2F") && body.contains("rtype=1"))
                    reply.merge(["uploadid": "up1", "return_type": 1, "block_list": [0]]) { $1 }
                case "locateupload": reply = ["error_code": 0, "servers": [["server": "https://c3.pcs.baidu.com"]]]
                case "upload":
                    #expect(request.url!.host == "c3.pcs.baidu.com")
                    let file = request.httpBody!
                    let start = file.range(of: Data("\r\n\r\n".utf8))!.upperBound
                    let end = file.range(of: Data("\r\n--yahadesk-".utf8), options: .backwards)!.lowerBound
                    #expect(file[start..<(start + 4)] == Data("OggS".utf8))
                    reply = ["md5": Insecure.MD5.hash(data: file[start..<end]).map { String(format: "%02x", $0) }.joined()]
                case "create":
                    #expect(body.contains("uploadid=up1"))
                    reply["path"] = "/apps/拾见/录音/x.opus"
                    if lock.withLock({ mode }) != "nofsid" { reply["fs_id"] = 7 }
                    if lock.withLock({ mode == "ok" }) {
                        let path = URLComponents(string: "?" + body)!.queryItems!.first { $0.name == "path" }!.value!
                        lock.withLock { stored.append(path) }
                    }
                    if lock.withLock({ mode == "ok" && creates == 0 }) {  // a take finished while this one uploads
                        let late = folder.appendingPathComponent("2099-01-01/000000.opus")
                        try! FileManager.default.createDirectory(at: late.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try! Data("OggS-late".utf8).write(to: late)
                    }
                    if lock.withLock({ mode == "ok" }) { lock.withLock { creates += 1 } }
                case "list":  // root: date folders newest first; a folder: its takes
                    #expect(q.first { $0.name == "order" }?.value == "name" && q.first { $0.name == "desc" }?.value == "1")
                    let dir = q.first { $0.name == "dir" }!.value!
                    reply["list"] = dir == PanFiles.root
                        ? [["fs_id": 1, "path": PanFiles.root + "/2026-11-06", "isdir": 1],
                           ["fs_id": 2, "path": PanFiles.root + "/2026-11-05", "isdir": 1]]
                        : [["fs_id": dir.hasSuffix("06") ? 9 : 8, "path": dir + "/101500.opus",
                            "size": dir.hasSuffix("06") ? 4096 : 2048, "isdir": 0, "local_mtime": 1_800_000_000]]
                default: Issue.record("unexpected \(m)")
                }
                return (try! JSONSerialization.data(withJSONObject: reply), 0)
            }
        }
        defer { CloudProtocol.lock.withLock { CloudProtocol.status = { _ in 200 } } }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudProtocol.self]
        let backup = RecordingBackup(folder: folder)
        backup.session = URLSession(configuration: configuration)
        backup.token = { PanToken(token: "pan-test", expires: Date().timeIntervalSince1970 + 3600) }
        backup.tail = .milliseconds(10)
        backup.now = { Date(timeIntervalSince1970: 1_800_000_000) }
        nonisolated(unsafe) var logs: [String] = []
        backup.log = { line in lock.withLock { logs.append(line) } }
        var expired = 0
        backup.loginExpired = { expired += 1 }

        func take(_ frames: Int) async throws {
            backup.talking(true)
            for _ in 0..<frames { backup.append(Data(repeating: 0x58, count: 120), samples: 960) }
            backup.talking(false)
            try await Task.sleep(for: .milliseconds(30))  // tail window
        }
        try await take(10)  // 0.6 s: a mis-press, no file
        #expect(backup.pending == 0 && lock.withLock { calls }.isEmpty)
        try await take(20)  // 1.2 s, Pan full: stays on disk
        for _ in 0..<100 where backup.message == nil || backup.items.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(backup.pending == 1 && backup.message == "网盘空间已满")
        let lists = lock.withLock { calls.filter { $0 == "list" }.count }
        try await take(20)  // same second: a second file, not an overwrite
        // finish() uploads and refreshes in the background; wait for its list calls so it can't race the uploads below.
        try await waitUntil { lock.withLock { calls.filter { $0 == "list" }.count } >= lists + 3 }  // root + two days
        #expect(backup.pending == 2)
        let local = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)!.allObjects as! [URL]
        if let one = local.first(where: { $0.lastPathComponent.hasSuffix(".1.opus") }) { try FileManager.default.removeItem(at: one) }
        else { Issue.record("同一秒的第二段应加 .1 后缀") }
        await backup.upload()
        #expect(backup.pending == 1)
        // Neither a non-200 reply nor a create without fs_id proves Pan stored it: the file stays.
        lock.withLock { mode = "http500" }
        CloudProtocol.lock.withLock { CloudProtocol.status = { $0.url!.query!.contains("method=create") ? 500 : 200 } }
        await backup.upload()
        #expect(backup.pending == 1)
        CloudProtocol.lock.withLock { CloudProtocol.status = { _ in 200 } }
        lock.withLock { mode = "nofsid" }
        await backup.upload()
        #expect(backup.pending == 1)
        lock.withLock { mode = "expired" }
        CloudProtocol.lock.withLock { CloudProtocol.status = { _ in 401 } }  // errno still read from a non-200 body
        await backup.upload()
        CloudProtocol.lock.withLock { CloudProtocol.status = { _ in 200 } }
        #expect(backup.pending == 1 && expired == 1)
        lock.withLock { mode = "ok"; calls.removeAll() }
        await backup.upload()
        await backup.refresh()
        #expect(lock.withLock { calls } == ["precreate", "locateupload", "upload", "create",
                                            "precreate", "locateupload", "upload", "create", "list", "list", "list"])
        #expect(backup.pending == 0 && backup.items.map(\.size) == [4096, 2048])
        let newest = try await PanFiles(token: "pan-test", session: backup.session).recent(limit: 1)
        #expect(newest.map(\.id) == [9])  // stops before the older folder
        let first = RecordingBackup.relativePath(Date(timeIntervalSince1970: 1_800_000_000))
        #expect(lock.withLock { stored } == [PanFiles.root + "/" + first, PanFiles.root + "/2099-01-01/000000.opus"])
        #expect(!lock.withLock { logs }.contains { $0.contains("pan-test") })
        #expect(RecordingBackup.relativePath(Date(timeIntervalSince1970: 1_800_000_000), in: TimeZone(identifier: "Asia/Shanghai")!)
                == "2027-01-15/160000.opus")
    }

    private func render<V: View>(_ view: V, name: String, width: CGFloat, height: CGFloat) throws {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/screenshots/\(name).png")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: path)
        #expect(bitmap.pixelsWide >= Int(width) && bitmap.pixelsHigh >= Int(height))
    }
}
