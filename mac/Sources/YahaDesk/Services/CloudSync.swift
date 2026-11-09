import AppKit
import Combine
import Foundation
import Security
import DeskCore
import DeskProtocol

// Mac holds the desk.configure credential only to prepare device authorization; firmware consumes commands/feed.
@MainActor
final class CloudSync: ObservableObject {
    enum AuthenticationMode { case clientCredentials, pkce }
    static let scope = CloudClient.controllerScope
    nonisolated static let builtInClientID = "yaha_7PdNbrTFEGxFJMldoLGYTpXO"
    @Published private(set) var authenticationMode: AuthenticationMode?
    @Published private(set) var clientID: String?
    @Published private(set) var status = "尚未连接工作台"
    @Published private(set) var lastError: String?
    @Published private(set) var requestBusy = false
    @Published private(set) var authorizationBusy = false
    @Published private(set) var deviceBusy = false
    @Published private(set) var deviceConnection: Uplink.Connection?
    @Published private(set) var deviceSupported = false
    @Published private(set) var deviceCloudState = DeviceCloudState()
    @Published private(set) var deviceMessage: String?  // Wi-Fi 扫描与配网
    @Published private(set) var authorizationMessage: String?
    var grantApplyTimeout: Duration = .seconds(10)
    @Published private(set) var deviceSupportsWiFiScan = false
    @Published private(set) var wifiNetworks: [WiFiNetwork] = []
    /// Scan count at request time; scanning ends when the device reports a newer list.
    @Published private(set) var wifiScanBaseline: Int?
    private var wifiScanRequest = 0
    var wifiScanTimeout: Duration = .seconds(20)
    var sendProvision: (ProvisioningCommand, Uplink.Connection) async throws -> Void = { _, _ in throw DeskProtocolError("设备未连接") }
    var log: (String) -> Void = { _ in }
    // Pan (DMS) binding; the Pan token lives in the Keychain only and is never logged.
    @Published private(set) var panLoggedIn = false
    @Published private(set) var panBusy = false
    @Published private(set) var panMessage: String?
    @Published private(set) var deviceSupportsPan = false
    var readIdentity: (Uplink.Connection) async throws -> Data = { _ in throw DeskProtocolError("设备未连接") }
    var panLogin: @MainActor () async throws -> PanToken = { try await PanLoginWindow.run() }
    var loadPanToken: () -> PanToken? = PanKeychain.load
    var savePanToken: (PanToken) -> Bool = PanKeychain.save
    var deletePanToken: () -> Bool = PanKeychain.delete
    var renewPanToken: @MainActor () async -> Void = { await PanKeychain.renewIfDue() }
    var dmsSession = URLSession(configuration: .ephemeral)
    var panPollInterval: Duration = .milliseconds(200)
    var proofTimeout: Duration = .seconds(40)  // 签名在云端任务下一轮做,前面可能压着 8 秒的拉取与 TLS 连接
    var onlineTimeout: Duration = .seconds(60)

    private let client: CloudClient
    private let loadGrant: () -> OAuthGrant?
    private let saveGrant: (OAuthGrant) -> Bool
    private let deleteGrant: () -> Bool
    private let openBrowser: (URL) -> Bool
    private let loadClientSecret: () -> String?
    private var grant: OAuthGrant?
    private var clientSecret: String?
    private var controlToken: OAuthAccessToken?
    private var authorization: Task<Void, Never>?
    private var generation = 0
    private var deviceAuthorizationTarget: Uplink.Connection?

    init(client: CloudClient = CloudClient(), load: @escaping () -> OAuthGrant? = ControllerKeychain.load,
         save: @escaping (OAuthGrant) -> Bool = ControllerKeychain.save,
         delete: @escaping () -> Bool = ControllerKeychain.delete,
         openBrowser: @escaping (URL) -> Bool = NSWorkspace.shared.open,
         loadClientSecret: @escaping () -> String? = ControlClientKeychain.load) {
        self.client = client; loadGrant = load; saveGrant = save; deleteGrant = delete
        self.openBrowser = openBrowser
        self.loadClientSecret = loadClientSecret
    }

    var deviceConnected: Bool { deviceConnection != nil }

    func start() {
        guard !authorizationBusy else { return }
        panLoggedIn = loadPanToken()?.valid() ?? false
        generation += 1
        stop(); requestBusy = false
        grant = nil; clientSecret = nil; controlToken = nil; clientID = nil; authenticationMode = nil
        lastError = nil
        if let secret = loadClientSecret(), !secret.isEmpty {
            clientSecret = secret; clientID = Self.builtInClientID; authenticationMode = .clientCredentials
        } else if let saved = loadGrant() {
            grant = saved; clientID = saved.clientID; authenticationMode = .pkce
        } else {
            status = "安装配置缺失"
            lastError = "本机尚未安装连接凭据，请完成应用安装配置后重试。"
            return
        }
        status = "已配置工作台连接"
    }
    func stop() { authorization?.cancel() }

    func cancelAuthorization() { authorization?.cancel() }
    func reauthorizeLegacyController() {
        guard authenticationMode == .pkce, let id = grant?.clientID, !authorizationBusy, !requestBusy else { return }
        generation += 1
        let current = generation
        authorizationBusy = true; lastError = nil; status = "请在浏览器重新授权"
        authorization = Task {
            defer { if current == generation { authorizationBusy = false } }
            do {
                let result = try await client.authorize(clientID: id, scope: Self.scope, openBrowser: openBrowser)
                try Task.checkCancellation()
                guard current == generation else { return }
                try connect(result)
                authorizationBusy = false
            } catch {
                if current == generation {
                    status = Task.isCancelled ? "重新授权已取消" : "重新授权未完成"
                    if !Task.isCancelled { lastError = error.localizedDescription }
                }
            }
        }
    }

    // Credentials are committed before any request made with them.
    func connect(_ result: OAuthGrant) throws {
        guard saveGrant(result) else { throw DeskProtocolError("钥匙串保存失败，请重新授权") }
        if deviceAuthorizationTarget != nil { authorization?.cancel() }
        generation += 1
        grant = result; clientSecret = nil; controlToken = nil
        authenticationMode = .pkce; clientID = result.clientID; requestBusy = false
        lastError = nil; status = "已重新授权工作台"
    }
    func disconnect() {
        if authenticationMode == .pkce, !deleteGrant() { lastError = "钥匙串删除失败"; return }
        generation += 1
        stop(); authorization = nil
        grant = nil; clientSecret = nil; controlToken = nil; authenticationMode = nil
        clientID = nil; requestBusy = false; authorizationBusy = false
        lastError = nil; status = "已断开工作台"
    }
    private func accessToken(generation current: Int) async throws -> String {
        guard current == generation else { throw CancellationError() }
        if let clientSecret {
            if let token = controlToken, token.expiresAt.timeIntervalSinceNow > 60 { return token.accessToken }
            let token = try await client.controllerToken(clientID: Self.builtInClientID, clientSecret: clientSecret)
            guard current == generation else { throw CancellationError() }
            controlToken = token
            return token.accessToken
        }
        guard let previous = grant else { throw CancellationError() }
        if previous.expiresAt.timeIntervalSinceNow > 60 { return previous.accessToken }
        let next = try await client.refresh(previous, scope: Self.scope)
        guard current == generation else { throw CancellationError() }
        guard saveGrant(next) else { throw DeskProtocolError("续期凭据保存失败，请重新授权") }
        grant = next
        return next.accessToken
    }

    func updateDeviceState(_ state: Uplink.State) {
        let target = state.connected ? state.connection : nil
        if let authorizedTarget = deviceAuthorizationTarget, target != authorizedTarget || !state.supportsCloud {
            authorization?.cancel()
        }
        deviceConnection = target
        deviceSupported = state.supportsCloud
        deviceCloudState = state.cloud
        deviceSupportsWiFiScan = state.supportsWiFiScan
        deviceSupportsPan = state.supportsPan
        wifiNetworks = state.wifiNetworks?.networks ?? []
        if target == nil { wifiScanBaseline = nil }
        if (state.wifiNetworks?.scan ?? 0) > (wifiScanBaseline ?? .max) {
            wifiScanBaseline = nil
            deviceMessage = wifiNetworks.isEmpty ? "没有扫描到可用的 2.4 GHz 网络，可重新扫描或手动输入" : "请选择 Wi-Fi 并输入密码"
        }
    }

    /// Sends Wi-Fi credentials, then follows the device: it drops the old network first
    /// (a still-true flag is the old network), then reports wifi_connected on DHCP.
    func configureWiFi(ssid: String, password: String) async {
        guard !deviceBusy, let target = deviceConnection, deviceSupported else { return }
        deviceBusy = true
        defer { deviceBusy = false }
        do {
            deviceMessage = "正在发送到设备"
            try await sendProvision(.wifi(ssid: ssid, password: password), target)
            deviceMessage = "设备正在连接 Wi-Fi"
            // The state right after the write is the pre-write snapshot: only a drop proves the device took it.
            // Errors are not checked here, a stale one would end the wait early; they show live in the device section.
            try await waitForDevice(target, wifiApplyTimeout, "没有看到设备切换网络，请重新发送") { !$0.wifiConnected }
            // A reason counts only after the device cleared it for these credentials; before that it is the old network's.
            // The firmware keeps retrying (BLE coexistence can fail one handshake), so a reason only explains a timeout.
            var cleared = false
            let seconds = Int(wifiJoinTimeout.components.seconds)
            do {
                try await waitForDevice(target, wifiJoinTimeout,
                                        "\(seconds) 秒内没有连上：请检查密码，并确认是 2.4 GHz 网络。设备会继续自动重试") {
                    if $0.wifiReason == 0 { cleared = true }
                    return $0.wifiConnected
                }
            } catch let timeout as DeskProtocolError {
                guard cleared, deviceConnection == target, let failure = deviceCloudState.wifiFailure else { throw timeout }
                throw DeskProtocolError("\(seconds) 秒内没有连上：\(failure)。设备会继续自动重试")
            }
            deviceMessage = "已连上 Wi-Fi"
        } catch { deviceMessage = error.localizedDescription }
    }
    var wifiApplyTimeout: Duration = .seconds(5)
    var wifiJoinTimeout: Duration = .seconds(30)
    var wifiScanning: Bool { wifiScanBaseline != nil }
    func scanWiFi() async {
        guard deviceSupportsWiFiScan, !wifiScanning else { return }
        wifiScanBaseline = deviceCloudState.wifiScan
        wifiScanRequest += 1
        let request = wifiScanRequest
        guard await provision(.scanWiFi, done: "设备正在扫描附近 Wi-Fi") else { wifiScanBaseline = nil; return }
        // A lost status notify or a stopped device worker must not spin forever.
        Task { [weak self, timeout = wifiScanTimeout] in
            try? await Task.sleep(for: timeout)
            guard let self, request == self.wifiScanRequest, self.wifiScanning else { return }
            self.wifiScanBaseline = nil; self.deviceMessage = "扫描没有完成，请重新扫描"
        }
    }
    func authorizeDevice() {
        guard !authorizationBusy, !deviceBusy, !requestBusy, clientID != nil,
              let target = deviceConnection, deviceSupported else { return }
        let current = generation
        deviceAuthorizationTarget = target
        authorizationBusy = true; deviceBusy = true; requestBusy = true; authorizationMessage = "正在准备设备授权"
        authorization = Task {
            var delivered = false
            defer {
                deviceBusy = false; authorizationBusy = false; deviceAuthorizationTarget = nil
                if current == generation { requestBusy = false }
            }
            do {
                let token = try await accessToken(generation: current)
                let data = try await client.callTool("desk_prepare_device", arguments: [:], accessToken: token)
                try Task.checkCancellation()
                guard current == generation, deviceConnection == target, deviceSupported else { throw CancellationError() }
                guard let prepared = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = prepared["client_id"] as? String, !id.isEmpty, id.utf8.count <= 128,
                      id != clientID, id != Self.builtInClientID else { throw DeskProtocolError("设备授权配置无效，请检查工作台连接") }
                // 管理员的设备应用另含 desk.operate（长按处理告警）；其它值一律只申请 desk.sync。
                let scope = prepared["scope"] as? String == "desk.sync desk.operate" ? "desk.sync desk.operate" : "desk.sync"
                authorizationMessage = "请在浏览器授权设备"
                let deviceGrant = try await client.authorize(clientID: id, scope: scope, openBrowser: openBrowser)
                try Task.checkCancellation()
                guard current == generation, deviceConnection == target, deviceSupported else { throw CancellationError() }
                try await sendProvision(.grant(clientID: id, refreshToken: deviceGrant.refreshToken), target)
                // Saved in the device: from here a link change or 取消 no longer undoes it.
                delivered = true; deviceAuthorizationTarget = nil
                // Device token is never written to Mac storage.
                authorizationMessage = "设备正在启用授权"
                try await waitForDevice(target, grantApplyTimeout, "设备没有启用授权，请重试") { $0.authorized }
                // Sync results (token refresh, desk_monitor) show live as deviceCloudState.errorMessage.
                authorizationMessage = deviceCloudState.wifiConnected ? "设备已授权，正在同步工作台" : "设备已授权，连上 Wi-Fi 后开始同步工作台"
            } catch {
                let stopped = error is CancellationError || Task.isCancelled || deviceConnection != target
                authorizationMessage = delivered && stopped ? "授权已交付设备，重新连接后可在这里查看是否已授权"
                    : stopped ? "设备授权已取消" : error.localizedDescription
            }
        }
    }
    @discardableResult
    private func provision(_ command: ProvisioningCommand, done: String) async -> Bool {
        guard !deviceBusy, let target = deviceConnection, deviceSupported else { return false }
        deviceBusy = true
        defer { deviceBusy = false }
        do { try await sendProvision(command, target); deviceMessage = done; return true }
        catch { deviceMessage = error.localizedDescription; return false }
    }
    // MARK: 网盘

    var panStatus: String {
        switch deviceCloudState.dms {
        case "": "未绑定"
        case "connecting": "连接中"
        case "online": "在线"
        case "offline": "离线"
        default: "未知"
        }
    }
    var canBindPan: Bool { deviceConnected && deviceSupportsPan && panLoggedIn && deviceCloudState.dms.isEmpty }
    var canUnbindPan: Bool { deviceConnected && deviceSupportsPan && !deviceCloudState.dms.isEmpty }

    func loginPan() async {
        guard !panBusy else { return }
        panBusy = true
        defer { panBusy = false }
        do {
            let token = try await panLogin()
            guard savePanToken(token) else { throw DeskProtocolError("钥匙串保存失败，请重新登录网盘") }
            panLoggedIn = true; panMessage = "已登录百度网盘"
        } catch is CancellationError { panMessage = "网盘登录已取消" }
        catch { panMessage = error.localizedDescription; log("⚠️ 网盘登录失败：\(error.localizedDescription)") }
    }

    /// Renews the Pan token pair before it expires; the login state follows the Keychain afterwards.
    func renewPan() async {
        await renewPanToken()
        panLoggedIn = loadPanToken()?.valid() ?? false
    }

    func logoutPan() {
        guard !panBusy else { return }
        guard deletePanToken() else { panMessage = "钥匙串删除失败"; return }
        panLoggedIn = false; panMessage = "已退出百度网盘"
    }

    /// identity → register + bind → challenge → device proof → iotcoreprovision → device MQTT online.
    /// Any failure after bind unbinds on Pan, and the device drops whatever DMS state it got.
    func bindPan() async {
        guard canBindPan, !panBusy, !deviceBusy, let target = deviceConnection else { return }
        panBusy = true; deviceBusy = true
        defer { panBusy = false; deviceBusy = false }
        do {
            let dms = try dmsClient()
            panMessage = "正在读取设备出厂身份"
            let der = try await readIdentity(target)
            let sn = try FactoryIdentity.deviceID(certificate: der)
            panMessage = "正在网盘登记设备"
            do {
                _ = try await dms.claim(sn: sn, name: "Yaha Desk") { dev in
                    try await self.joinPan(dms, dev: dev, sn: sn, certificate: der, target: target)
                }
            } catch {
                try? await sendProvision(.dmsReset, target)
                throw error
            }
            panMessage = "网盘绑定完成，设备已在线"
        } catch { panFailed(error) }
    }

    private func joinPan(_ dms: DmsClient, dev: String, sn: String, certificate: Data, target: Uplink.Connection) async throws {
        panMessage = "设备正在签名"
        let challenge = try await dms.challenge(dev, sn: sn)
        let before = deviceCloudState.proof
        try await sendProvision(.dmsProof(deviceID: dev, challenge: challenge), target)
        try await waitForDevice(target, proofTimeout, "设备没有返回签名，请重试") {
            $0.deviceID == dev && !$0.proof.isEmpty && $0.proof != before
        }
        panMessage = "正在领取设备凭据"
        let credential = try await dms.credential(dev, sn: sn, challenge: challenge, sig: deviceCloudState.proof,
                                                  cert: OAuthPKCE.base64URL(certificate))
        // The device takes a credential only for the id it just signed.
        guard credential.deviceID == dev else { throw DeskProtocolError("网盘返回的设备凭据与设备不符") }
        try await sendProvision(.dms(deviceID: dev, coreID: credential.coreID, secret: credential.secret,
                                     mqttURL: credential.mqttURL, commandTopic: credential.commandTopic), target)
        panMessage = "等待设备连上网盘"
        try await waitForDevice(target, onlineTimeout, "设备 60 秒内没有连上网盘，请检查设备 Wi-Fi") { $0.dms == "online" }
    }

    func unbindPan() async {
        guard canUnbindPan, !panBusy, !deviceBusy, let target = deviceConnection else { return }
        panBusy = true; deviceBusy = true
        defer { panBusy = false; deviceBusy = false }
        let dev = deviceCloudState.deviceID
        do {
            if !dev.isEmpty {
                do { try await dmsClient().unbind(dev) }
                catch let failure as DmsClient.Failure where failure.errno == 42112 {}  // already gone on Pan
            }
            try await sendProvision(.dmsReset, target)
            panMessage = "已解绑网盘"
        } catch { panFailed(error) }
    }

    private func dmsClient() throws -> DmsClient {
        guard let token = loadPanToken(), token.valid() else {
            panLoggedIn = false
            throw DeskProtocolError("网盘登录已过期，请重新登录网盘")
        }
        let log = self.log
        return DmsClient(token: token.token, log: { line in Task { @MainActor in log(line) } }, session: dmsSession)
    }

    /// Pan rejected the token (-6/111): drop it so the UI asks for a new login.
    func panLoginExpired() {
        _ = deletePanToken(); panLoggedIn = false
    }

    private func panFailed(_ error: Error) {
        if let failure = error as? DmsClient.Failure, [-6, 111].contains(failure.errno) { panLoginExpired() }
        panMessage = error is CancellationError ? "网盘操作已取消" : error.localizedDescription
    }

    private func waitForDevice(_ target: Uplink.Connection, _ timeout: Duration, _ timeoutMessage: String,
                               until done: (DeviceCloudState) -> Bool) async throws {
        let end = ContinuousClock.now + timeout
        while !done(deviceCloudState) {
            guard deviceConnection == target else { throw DeskProtocolError("设备连接已改变，请重新操作") }
            guard ContinuousClock.now < end else { throw DeskProtocolError(timeoutMessage) }
            try await Task.sleep(for: panPollInterval)
        }
    }

    func report() -> [String: Any] {
        var report: [String: Any] = ["configured": clientID != nil, "status": status,
                                   "authenticationMode": authenticationMode == .clientCredentials ? "client_credentials" : authenticationMode == .pkce ? "pkce" : "none"]
        if let clientID { report["clientId"] = clientID }
        return report
    }
}

enum ControlClientKeychain {
    static let service = "com.yaha.desk.control-client"
    static func load() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: CloudSync.builtInClientID,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let secret = String(data: data, encoding: .utf8), !secret.isEmpty else { return nil }
        return secret
    }
}

enum ControllerKeychain {
    private static let service = "com.yaha.desk.controller"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "controller"]
    }
    static func save(_ grant: OAuthGrant) -> Bool {
        guard let data = try? JSONEncoder().encode(grant) else { return false }
        let attrs = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
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
