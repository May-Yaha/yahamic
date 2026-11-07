import CoreBluetooth
import DeskProtocol
import Foundation
import Security

@MainActor
final class DeviceStore: NSObject, ObservableObject {
    enum CloudPayload: Equatable {
        case state(DeviceCloudState)
        case reread
        case invalid
    }

    @Published private(set) var connected = false
    @Published private(set) var ready = false  // 已连接且找到配置特征，可以下发指令
    @Published private(set) var deviceName = "正在寻找桌面设备"
    @Published private(set) var firmware = ""
    @Published private(set) var cloud = DeviceCloudState()
    @Published private(set) var networks: [WiFiNetwork] = []
    @Published private(set) var saved = SavedWiFi.load()  // 连上过的网络：名称 → 密码
    @Published private(set) var joined: String?           // 本页这次连上的网络，离开页面或切换失败即清空
    @Published private(set) var busy = false
    @Published var message = ""

    private var central: CBCentralManager?
    private var active = false  // 蓝牙只在切 Wi-Fi、设备管理页打开时使用，离开即断开，Mac 端点“恢复连接”即可连回
    private var peripheral: CBPeripheral?
    private var provision: CBCharacteristic?
    private var identity: CBCharacteristic?
    private var cloudCharacteristic: CBCharacteristic?
    private var cloudRereading = false
    private var writeCompletion: CheckedContinuation<Void, Error>?
    private var reads: [CBUUID: CheckedContinuation<Data, Error>] = [:]
    private var scanTimeout: Task<Void, Never>?

    func start() {
        active = true
        if central == nil { central = CBCentralManager(delegate: self, queue: nil) } else { scan() }
    }

    func stop() {
        active = false
        ready = false
        joined = nil
        scanTimeout?.cancel()
        central?.stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
    }

    func scan() {
        guard active, let central else { return }
        guard central.state == .poweredOn else { message = "请先打开蓝牙"; return }
        guard Self.shouldScan(connected: connected, hasPeripheral: peripheral != nil) else {
            central.stopScan()
            scanTimeout?.cancel()
            return
        }
        scanTimeout?.cancel()
        central.stopScan()
        central.scanForPeripherals(withServices: [CBUUID(string: Wire.service)])
        deviceName = connected ? deviceName : "正在寻找桌面设备"
        scanTimeout = Task {
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled,
                  let prompt = Self.scanTimeoutMessage(connected: connected, discovered: peripheral != nil) else { return }
            self.central?.stopScan()
            message = prompt
        }
    }

    nonisolated static func scanTimeoutMessage(connected: Bool, discovered: Bool) -> String? {
        connected || discovered ? nil : "没有找到设备，请先在 Mac 上点“暂时断开”"
    }

    nonisolated static func shouldScan(connected: Bool, hasPeripheral: Bool) -> Bool {
        !connected && !hasPeripheral
    }

    nonisolated static func isRemoteUnbound(errno: Int) -> Bool { errno == 42112 }

    func reconnect() {
        guard active, let central else { return }
        scanTimeout?.cancel()
        central.stopScan()
        guard let peripheral else { connected = false; scan(); return }
        message = "正在重新连接"
        if peripheral.state == .disconnected {
            self.peripheral = nil
            connected = false
            provision = nil
            ready = false
            identity = nil
            cloudCharacteristic = nil
            cloudRereading = false
            scan()
        } else {
            central.cancelPeripheralConnection(peripheral)
        }
    }

    nonisolated static func decodeCloudPayload(_ data: Data?, rereading: Bool) -> CloudPayload {
        if let data, data.count <= 512, let state = try? JSONDecoder().decode(DeviceCloudState.self, from: data) {
            return .state(state)
        }
        return data != nil && !rereading ? .reread : .invalid
    }

    nonisolated static func wifiSwitchApplied(_ state: DeviceCloudState) -> Bool { !state.wifiConnected }

    func send(_ command: ProvisioningCommand) async throws {
        guard let peripheral, let provision, connected else { throw DeskProtocolError("设备未连接") }
        guard writeCompletion == nil else { throw DeskProtocolError("上一项配置仍在进行") }
        let data = try command.encoded()
        try await withCheckedThrowingContinuation { completion in
            writeCompletion = completion
            peripheral.writeValue(data, for: provision, type: .withResponse)
        }
    }

    func scanWiFi() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            // 基线取列表自带的扫描序号：刚连上时云端状态可能还没读到，用它比较会把旧列表当新结果。
            let before = try await readNetworks().scan
            message = "设备正在扫描附近网络"
            try await send(.scanWiFi)
            try await wait(15, "扫描超时，请靠近设备后重试") { $0.wifiScan > before }
            guard let fresh = Self.freshNetworks(try await readNetworks(), after: before) else {
                throw DeskProtocolError("扫描结果还没更新，请下拉重试")
            }
            networks = fresh
            message = networks.isEmpty ? "没有发现可用网络" : "扫描完成"
        } catch { message = error.localizedDescription }
    }

    nonisolated static func freshNetworks(_ list: WiFiScan, after scan: Int) -> [WiFiNetwork]? {
        list.scan > scan ? list.networks : nil
    }

    /// 返回是否连上；失败时 `cloud.wifiReason` 留着设备给的原因，界面据此判断要不要重新问密码。
    @discardableResult
    func joinWiFi(ssid: String, password: String) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        joined = nil
        do {
            message = "正在发送 Wi-Fi 设置"
            try await send(.wifi(ssid: ssid, password: password))
            message = "设备正在连接 Wi-Fi"
            try await wait(5, "没有看到设备切换网络，请重新发送") { Self.wifiSwitchApplied($0) }
            var cleared = false
            do {
                try await wait(30, "设备尚未连上网络，请检查密码和 2.4 GHz 网络") {
                    if $0.wifiReason == 0 { cleared = true }
                    return $0.wifiConnected
                }
            } catch let timeout as DeskProtocolError {
                guard cleared, let failure = cloud.wifiFailure else { throw timeout }
                throw DeskProtocolError("30 秒内没有连上：\(failure)。设备会继续自动重试")
            }
            message = "已连上 Wi-Fi"
            joined = ssid
            var next = saved
            next[ssid] = password
            if SavedWiFi.save(next) { saved = next }
            return true
        } catch { message = error.localizedDescription; return false }
    }

    /// 设备报的断开原因属于密码错误（与 DeviceCloudState.wifiFailure 同一组代码）。
    nonisolated static func wrongPassword(reason: Int) -> Bool { [15, 202, 204].contains(reason) }

    func forget(_ ssid: String) {
        var next = saved
        next[ssid] = nil
        if SavedWiFi.save(next) { saved = next } else { message = "删除失败，请重试" }
    }

    /// 点一下就能连的密码：开放网络为空串，连上过的取已存密码；需要用户输入时返回 nil。
    nonisolated static func knownPassword(for network: WiFiNetwork, saved: [String: String]) -> String? {
        network.secure ? saved[network.ssid] : ""
    }

    func bindPan(token: String?) async {
        guard let token else { message = CloudStore.panExpired; return }
        guard !busy, peripheral != nil, identity != nil else {
            message = "设备未连接或没有出厂身份"
            return
        }
        busy = true
        defer { busy = false }
        do {
            let client = DmsClient(token: token)
            message = "正在读取设备身份"
            let certificate = try await read(Wire.identity)
            let sn = try FactoryIdentity.deviceID(certificate: certificate)
            message = "正在登记设备"
            let deviceID = try await client.bind(sn: sn, name: "Yaha Desk")
            do {
                message = "设备正在签名"
                let challenge = try await client.challenge(deviceID, sn: sn)
                let oldProof = cloud.proof
                try await send(.dmsProof(deviceID: deviceID, challenge: challenge))
                try await wait(10, "设备没有返回签名") { $0.deviceID == deviceID && !$0.proof.isEmpty && $0.proof != oldProof }
                let credential = try await client.credential(deviceID, sn: sn, challenge: challenge,
                    sig: cloud.proof, cert: OAuthPKCE.base64URL(certificate))
                guard credential.deviceID == deviceID else { throw DeskProtocolError("设备凭据不匹配") }
                try await send(.dms(deviceID: deviceID, coreID: credential.coreID, secret: credential.secret,
                    mqttURL: credential.mqttURL, commandTopic: credential.commandTopic))
                try await wait(60, "设备尚未连上网盘，请检查 Wi-Fi") { $0.dms == "online" }
                message = "网盘绑定完成"
            } catch {
                try? await client.unbind(deviceID)
                try? await send(.dmsReset)
                throw error
            }
        } catch { message = error.localizedDescription }
    }

    func unbindPan(token: String?) async {
        guard let token else { message = CloudStore.panExpired; return }
        guard !busy, cloud.dms != "" else { return }
        busy = true
        defer { busy = false }
        do {
            if !cloud.deviceID.isEmpty {
                do { try await DmsClient(token: token).unbind(cloud.deviceID) }
                catch let failure as DmsClient.Failure where Self.isRemoteUnbound(errno: failure.errno) {}
            }
            try await send(.dmsReset)
            message = "已解绑网盘"
        } catch { message = error.localizedDescription }
    }

    private func read(_ characteristic: CBUUID) async throws -> Data {
        guard let peripheral, connected else { throw DeskProtocolError("设备未连接") }
        guard let found = peripheral.services?.compactMap(\.characteristics).flatMap({ $0 }).first(where: {
            $0.uuid == characteristic
        }) else { throw DeskProtocolError("当前固件不支持这项能力") }
        guard reads[characteristic] == nil else { throw DeskProtocolError("正在读取设备，请稍后") }
        return try await withCheckedThrowingContinuation { completion in
            reads[characteristic] = completion
            peripheral.readValue(for: found)
        }
    }

    private func read(_ uuid: String) async throws -> Data { try await read(CBUUID(string: uuid)) }

    private func readNetworks() async throws -> WiFiScan {
        try JSONDecoder().decode(WiFiScan.self, from: try await read(Wire.networks))
    }

    private func wait(_ seconds: Int, _ timeout: String, until done: (DeviceCloudState) -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(seconds)
        while !done(cloud) {
            guard connected else { throw DeskProtocolError("设备连接已断开") }
            guard ContinuousClock.now < end else { throw DeskProtocolError(timeout) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

@MainActor
extension DeviceStore: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn: scan()
            case .unauthorized:
                scanTimeout?.cancel()
                message = "请在系统设置中允许 Yaha Desk 使用蓝牙"
            case .poweredOff:
                scanTimeout?.cancel()
                message = "请打开蓝牙"
            default:
                scanTimeout?.cancel()
                message = "蓝牙暂不可用"
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi: NSNumber) {
        Task { @MainActor in
            guard active, self.peripheral == nil else { return }
            scanTimeout?.cancel()
            self.peripheral = peripheral
            deviceName = peripheral.name ?? "桌面设备"
            central.stopScan()
            central.connect(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            connected = true
            scanTimeout?.cancel()
            message = "设备已连接"
            peripheral.delegate = self
            peripheral.discoverServices([CBUUID(string: Wire.service)])
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            message = "连接失败，请先在 Mac 上点“暂时断开”"
            self.peripheral = nil
            scan()
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            connected = false
            scanTimeout?.cancel()
            self.peripheral = nil
            provision = nil
            ready = false
            identity = nil
            cloudCharacteristic = nil
            cloudRereading = false
            cloud = DeviceCloudState()  // 设备可能重启过（扫描序号归零），旧状态不能当本次连接的基线
            networks = []
            deviceName = "正在寻找桌面设备"
            writeCompletion?.resume(throwing: DeskProtocolError("设备连接已断开"))
            writeCompletion = nil
            for (_, completion) in reads { completion.resume(throwing: DeskProtocolError("设备连接已断开")) }
            reads.removeAll()
            scan()
        }
    }
}

@MainActor
extension DeviceStore: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if error != nil {
                message = "读取设备服务失败，正在重连"
                central?.cancelPeripheralConnection(peripheral)
                return
            }
            for service in peripheral.services ?? [] {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            if error != nil {
                message = "读取设备能力失败，正在重连"
                central?.cancelPeripheralConnection(peripheral)
                return
            }
            for characteristic in service.characteristics ?? [] {
                switch characteristic.uuid {
                case CBUUID(string: Wire.provision):
                    provision = characteristic
                    ready = true
                case CBUUID(string: Wire.identity): identity = characteristic
                case CBUUID(string: Wire.cloudState):
                    cloudCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                    peripheral.readValue(for: characteristic)
                case CBUUID(string: Wire.info): peripheral.readValue(for: characteristic)
                default: break
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let error { writeCompletion?.resume(throwing: error) }
            else {
                writeCompletion?.resume()
                if characteristic.uuid == CBUUID(string: Wire.provision), let cloudCharacteristic {
                    peripheral.readValue(for: cloudCharacteristic)
                }
            }
            writeCompletion = nil
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            let uuid = characteristic.uuid
            let completion = reads.removeValue(forKey: uuid)
            if let error {
                completion?.resume(throwing: error)
                if completion == nil { message = "读取设备状态失败" }
                if uuid == CBUUID(string: Wire.cloudState) { cloudRereading = false }
                return
            }
            guard let data = characteristic.value else {
                completion?.resume(throwing: DeskProtocolError("设备没有返回读取结果"))
                if completion == nil { message = "设备没有返回读取结果" }
                if uuid == CBUUID(string: Wire.cloudState) { cloudRereading = false }
                return
            }
            completion?.resume(returning: data)
            switch uuid {
            case CBUUID(string: Wire.cloudState):
                switch Self.decodeCloudPayload(data, rereading: cloudRereading) {
                case let .state(state):
                    cloud = state
                    cloudRereading = false
                case .reread:
                    cloudRereading = true
                    peripheral.readValue(for: characteristic)
                case .invalid:
                    cloudRereading = false
                    message = "设备返回了无法识别的状态"
                }
            case CBUUID(string: Wire.info): firmware = Fields.parse(data)["fw"] ?? ""
            default: break
            }
        }
    }
}

/// 连上过的 Wi-Fi 密码只存本机钥匙串（不随 iCloud 同步），换场景时点一下即可切换。
enum SavedWiFi {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.yaha.desk.ios.wifi",
         kSecAttrAccount as String: "networks"]
    }
    /// 原地更新，不先删后加：写失败时旧密码还在。空字典即删除。
    static func save(_ networks: [String: String]) -> Bool {
        if networks.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        guard let data = try? JSONEncoder().encode(networks) else { return false }
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status != errSecItemNotFound { return status == errSecSuccess }
        return SecItemAdd(query.merging(attrs) { _, new in new } as CFDictionary, nil) == errSecSuccess
    }
    static func load() -> [String: String] {
        var item: CFTypeRef?
        let lookup = query.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { _, new in new }
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}
