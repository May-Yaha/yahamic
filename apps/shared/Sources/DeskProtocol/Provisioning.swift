import Foundation

public struct DeviceCloudState: Codable, Equatable, Sendable {
    public var wifiConnected = false
    public var authorized = false
    /// Completed scan count; 0 before the first scan and on firmware without scanning.
    public var wifiScan = 0
    public var error = ""
    /// Pan DMS link: "" unbound, "connecting", "online", "offline"; absent on firmware before DMS.
    public var dms = ""
    /// DMS device id the device last signed for (or is bound to).
    public var deviceID = ""
    /// b64url ES256 r‖s answering the last `dms_proof`.
    public var proof = ""
    /// ESP-IDF `wifi_err_reason_t` of the last failed join; 0 once joined, after new credentials and on older firmware.
    public var wifiReason = 0
    /// Device battery 0...100; -1 when no battery is fitted or on firmware before 0.4.3.
    public var battery = -1
    public var charging = false
    public var usbPower = false
    public init() {}
    enum CodingKeys: String, CodingKey {
        case authorized, error, dms, proof, battery, charging
        case usbPower = "usb_power"
        case wifiConnected = "wifi_connected", wifiScan = "wifi_scan", deviceID = "device_id", wifiReason = "wifi_reason"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wifiConnected = try c.decode(Bool.self, forKey: .wifiConnected)
        authorized = try c.decode(Bool.self, forKey: .authorized)
        wifiScan = try c.decodeIfPresent(Int.self, forKey: .wifiScan) ?? 0
        error = try c.decode(String.self, forKey: .error)
        dms = try c.decodeIfPresent(String.self, forKey: .dms) ?? ""
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID) ?? ""
        proof = try c.decodeIfPresent(String.self, forKey: .proof) ?? ""
        wifiReason = try c.decodeIfPresent(Int.self, forKey: .wifiReason) ?? 0
        battery = try c.decodeIfPresent(Int.self, forKey: .battery) ?? -1
        charging = try c.decodeIfPresent(Bool.self, forKey: .charging) ?? false
        usbPower = try c.decodeIfPresent(Bool.self, forKey: .usbPower) ?? false
    }

    /// Why the last join failed, for the reasons the user can fix; nil for the rest (they read as a plain timeout).
    public var wifiFailure: String? {
        switch wifiReason {
        case 15, 202, 204: "密码可能不对，请重新输入"
        case 201: "找不到这个网络：请确认名称正确、在附近，且是 2.4 GHz"
        case 210: "这个网络的加密方式设备不支持，请改用 WPA2 个人版"
        // configure_wifi requires WPA2 whenever a password is given, so an open network with a password lands here too.
        case 211: "加密方式不符：开放网络请留空密码，否则请改用 WPA2 个人版"
        default: nil
        }
    }

    /// Firmware `error` code (cloud.cpp) as what the user should do; nil when clear.
    public var errorMessage: String? {
        switch error {
        case "": nil
        case "reauthorize", "reauthorize_storage", "invalid_token_response": "设备授权已失效，请重新授权设备"
        case "token_unavailable": "设备暂时换不到工作台令牌，会自动重试；一直失败请检查网络"
        case "sync_failed": "设备同步工作台失败，会自动重试"
        case "invalid_monitor", "invalid_feed": "工作台返回的内容设备读不懂，请升级固件"
        case "wifi_configuration_failed": "设备没能应用 Wi-Fi 设置，请重新发送"
        case "storage_failed", "network_init_failed", "wifi_init_failed", "clock_init_failed", "worker_start_failed":
            "设备联网模块启动失败，请重启设备"
        default: "设备连接云端异常（\(error)）"
        }
    }
}

/// One network from the device's own scan; firmware drops hidden, enterprise and duplicate names.
public struct WiFiNetwork: Codable, Equatable, Hashable, Sendable {
    public let ssid: String
    public let rssi: Int
    public let secure: Bool
    public init(ssid: String, rssi: Int, secure: Bool) { self.ssid = ssid; self.rssi = rssi; self.secure = secure }
}

public struct WiFiScan: Codable, Equatable, Sendable {
    public let scan: Int
    public let networks: [WiFiNetwork]
    public init(scan: Int, networks: [WiFiNetwork]) { self.scan = scan; self.networks = networks }
}

public enum ProvisioningCommand {
    case wifi(ssid: String, password: String)
    case scanWiFi
    case grant(clientID: String, refreshToken: String)
    /// Device signs the DMS challenge with its factory key; the answer comes back in `DeviceCloudState.proof`.
    case dmsProof(deviceID: String, challenge: String)
    /// IoT Core credential for the device id it just signed for.
    case dms(deviceID: String, coreID: String, secret: String, mqttURL: String, commandTopic: String)
    /// Drops DMS credentials, upload token and pending recordings; Wi-Fi and the yahaops grant stay.
    case dmsReset

    public func encoded() throws -> Data {
        let fields: [String: String]
        switch self {
        case let .wifi(ssid, password):
            guard !ssid.isEmpty, ssid.utf8.count <= 32, password.utf8.count <= 63,
                  !ssid.contains("\0"), !password.contains("\0") else {
                throw DeskProtocolError("Wi-Fi 名称须为 1–32 字节，密码不超过 63 字节")
            }
            fields = ["op": "wifi", "ssid": ssid, "password": password]
        case .scanWiFi:
            fields = ["op": "scan"]
        case let .grant(id, token):
            guard !id.isEmpty, !token.isEmpty, !id.contains("\0"), !token.contains("\0") else {
                throw DeskProtocolError("设备授权信息不完整")
            }
            fields = ["op": "grant", "client_id": id, "refresh_token": token]
        case let .dmsProof(id, challenge):
            guard Self.isDMSDeviceID(id), (16...128).contains(challenge.utf8.count),
                  challenge.allSatisfy({ Self.base64URLChars.contains($0) }) else {
                throw DeskProtocolError("网盘设备号或挑战值格式不对")
            }
            fields = ["op": "dms_proof", "device_id": id, "challenge": challenge]
        case let .dms(id, core, secret, url, topic):
            guard Self.isDMSDeviceID(id), ![core, secret, url, topic].contains(where: { $0.isEmpty || $0.contains("\0") }) else {
                throw DeskProtocolError("网盘设备凭据不完整")
            }
            fields = ["op": "dms", "device_id": id, "core_id": core, "secret": secret, "mqtt_url": url, "command_topic": topic]
        case .dmsReset:
            fields = ["op": "dms_reset"]
        }
        let data = try JSONSerialization.data(withJSONObject: fields)
        guard data.count <= 512 else { throw DeskProtocolError("设备配置超过蓝牙载荷上限") }
        return data
    }

    private static let base64URLChars = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    private static let lowerAlnum = Set("abcdefghijklmnopqrstuvwxyz0123456789")
    /// DMS register returns 18 chars of [0-9a-z].
    public static func isDMSDeviceID(_ id: String) -> Bool { id.count == 18 && id.allSatisfy { lowerAlnum.contains($0) } }
}

public struct DeskProtocolError: LocalizedError, Sendable {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}
