import Foundation

/// Baidu Pan device service (DMS), ported from hardware-ai-flutter-sdk Dms.swift. The user's Pan token goes in the
/// query; logs carry the method and errno only, never token, secret, challenge, signature or certificate.
struct DmsClient: Sendable {
    static let base = "https://pan.baidu.com/rest/2.0/xpan/device"
    static let deviceType = "202611021737243320"  // 2.16" board, dms_type 113

    struct Credential: CustomStringConvertible, Sendable {
        let deviceID, coreID, secret, mqttURL, commandTopic: String
        var description: String { "DmsClient.Credential(device=\(deviceID), core=\(coreID))" }
    }

    struct Failure: LocalizedError, Equatable {
        let errno: Int
        let errorDescription: String?
    }

    let token: String
    var log: @Sendable (String) -> Void = { _ in }
    var session = URLSession(configuration: .ephemeral)

    /// register + bind; returns the DMS device id (device_addr = device_sn = factory device id).
    func bind(sn: String, name: String) async throws -> String {
        let r = try await call("POST", "register", ["device_type": Self.deviceType, "device_addr": sn])
        guard let dev = r["device_id"] as? String, !dev.isEmpty else { throw Self.failure(-1, "register") }
        _ = try await call("POST", "bind", ["device_id": dev, "device_name": name, "device_sn": sn])
        return dev
    }

    func challenge(_ dev: String, sn: String) async throws -> String {
        let r = try await call("GET", "iotcorechallenge", ["device_id": dev, "device_sn": sn])
        guard let challenge = r["challenge"] as? String, !challenge.isEmpty else { throw Self.failure(-1, "iotcorechallenge") }
        return challenge
    }

    /// Never retried: every iotcoreprovision call resets the device secret.
    func credential(_ dev: String, sn: String, challenge: String, sig: String, cert: String) async throws -> Credential {
        let r = try await call("POST", "iotcoreprovision", ["device_id": dev, "device_sn": sn],
                               json: ["device_type": UInt64(Self.deviceType)!, "challenge": challenge, "sig": sig, "cert": cert],
                               timeout: 30)
        func field(_ key: String) throws -> String {
            guard let v = r[key] as? String, !v.isEmpty else { throw Self.failure(-1, "iotcoreprovision") }
            return v
        }
        guard r["auth_type"] as? String == "SIGNATURE" else { throw Self.failure(-1, "iotcoreprovision") }
        return Credential(deviceID: try field("credential_id"), coreID: try field("core_id"), secret: try field("credential"),
                          mqttURL: try field("mqtt_url"), commandTopic: try field("command_topic"))
    }

    func command(_ dev: String, _ action: String, args: [String: Any] = [:]) async throws {
        _ = try await call("POST", "iotcorecommand", [:], json: ["device_id": dev, "action": action, "args": args, "qos": 1,
                                                                 "message_id": "msg_" + UUID().uuidString.lowercased()])
    }

    /// Tells the device to drop its credential (best effort), then removes the binding.
    func unbind(_ dev: String) async throws {
        try? await command(dev, "unbind")
        _ = try await call("GET", "unbind", ["device_id": dev])
    }

    /// bind, then `join`; any failure in `join` unbinds before rethrowing.
    func claim(sn: String, name: String, then join: (String) async throws -> Void) async throws -> String {
        let dev = try await bind(sn: sn, name: name)
        do { try await join(dev) } catch {
            // Rollback runs even when the caller was cancelled.
            do { try await Task { try await unbind(dev) }.value } catch { log("dms rollback unbind failed") }
            throw error
        }
        return dev
    }

    private func call(_ method: String, _ m: String, _ query: [String: String], json: [String: Any]? = nil,
                      timeout: TimeInterval = 15) async throws -> [String: Any] {
        var c = URLComponents(string: Self.base)!
        c.queryItems = [URLQueryItem(name: "method", value: m), URLQueryItem(name: "access_token", value: token)]
            + query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: c.url!, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("pan.baidu.com", forHTTPHeaderField: "User-Agent")
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            log("dms \(m) network error")
            throw DmsClient.Failure(errno: -1, errorDescription: "网络不可用，请检查网络后重试")
        }
        return try Self.reply(m, (response as? HTTPURLResponse)?.statusCode ?? 0, data, log: log)
    }

    static func reply(_ m: String, _ status: Int, _ data: Data, log: (String) -> Void = { _ in }) throws -> [String: Any] {
        guard let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            log("dms \(m) HTTP \(status)")
            throw Failure(errno: -1, errorDescription: "网盘设备服务出错（\(m) HTTP \(status)）")
        }
        let errno = (r["errno"] as? NSNumber)?.intValue ?? -1
        log("dms \(m) errno \(errno)")
        guard errno == 0 else { throw failure(errno, m) }
        return r
    }

    static func failure(_ errno: Int, _ m: String) -> Failure {
        let text = switch errno {
        case -6, 111: "网盘登录已失效，请重新登录网盘"
        case 42103: "设备已被他人绑定，请先在对方网盘解绑"
        case 42112: "网盘里找不到这台设备"
        case 42117: "设备出厂证书不被信任"
        case 42118: "操作太频繁，请稍后再试"
        default: "网盘设备服务出错（\(m) errno \(errno)）"
        }
        return Failure(errno: errno, errorDescription: text)
    }
}
