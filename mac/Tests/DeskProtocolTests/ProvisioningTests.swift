import Foundation
import Testing
import DeskCore
@testable import DeskProtocol

@Test func provisioningRejectsOversizeAndKeepsUTF8AndOldDashboard() throws {
    let wifi = try ProvisioningCommand.wifi(ssid: "逸尘网络", password: "secret+password").encoded()
    let object = try #require(JSONSerialization.jsonObject(with: wifi) as? [String: String])
    #expect(object["ssid"] == "逸尘网络" && object["op"] == "wifi")
    #expect(throws: (any Error).self) {
        try ProvisioningCommand.wifi(ssid: String(repeating: "字", count: 11), password: "").encoded()
    }
    #expect(throws: (any Error).self) {
        try ProvisioningCommand.grant(clientID: "device", refreshToken: String(repeating: "x", count: 510)).encoded()
    }
    let legacy = Wire.dashboard(epoch: 1, tzMinutes: 480, cpu: 10, mem: 20, mouse: 30, keyboard: 40)
    let extended = Wire.dashboard(epoch: 1, tzMinutes: 480, cpu: 10, mem: 20, mouse: 30, keyboard: 40,
                                  macBattery: 75, macPower: 3)
    #expect(legacy.count == 10 && extended.count == 12)
    #expect(extended.prefix(10) == legacy && extended.suffix(2) == Data([75, 3]))
}

@Test func wifiScanCommandAndOlderFirmwareStateDecode() throws {
    let scan = try #require(JSONSerialization.jsonObject(with: ProvisioningCommand.scanWiFi.encoded()) as? [String: String])
    #expect(scan == ["op": "scan"])
    let old = Data(#"{"wifi_connected":true,"authorized":false,"display_revision":3,"error":""}"#.utf8)
    let state = try JSONDecoder().decode(DeviceCloudState.self, from: old)
    #expect(state.wifiConnected && state.wifiScan == 0)
    // Firmware without the carousel stops sending display_revision.
    let current = Data(#"{"wifi_connected":false,"authorized":true,"error":"","wifi_scan":2}"#.utf8)
    let next = try JSONDecoder().decode(DeviceCloudState.self, from: current)
    #expect(next.authorized && next.wifiScan == 2)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(DeviceCloudState.self, from: Data(#"{"authorized":false}"#.utf8)) }
    // Same shape as firmware network_list().
    let list = Data(#"{"scan":2,"networks":[{"ssid":"家里","rssi":-41,"secure":true},{"ssid":"Cafe","rssi":-80,"secure":false}]}"#.utf8)
    let decoded = try JSONDecoder().decode(WiFiScan.self, from: list)
    #expect(decoded.scan == 2 && decoded.networks == [.init(ssid: "家里", rssi: -41, secure: true),
                                                     .init(ssid: "Cafe", rssi: -80, secure: false)])
}

@Test func dmsCommandsEncodeAndRejectBadInput() throws {
    let dev = "abc123def456ghi789"
    let challenge = "AbCd-_0123456789xyz"
    func fields(_ c: ProvisioningCommand) throws -> [String: String] {
        try #require(JSONSerialization.jsonObject(with: c.encoded()) as? [String: String])
    }
    #expect(try fields(.dmsProof(deviceID: dev, challenge: challenge)) == ["op": "dms_proof", "device_id": dev, "challenge": challenge])
    #expect(try fields(.dms(deviceID: dev, coreID: "core", secret: "s", mqttURL: "ssl://m:8883", commandTopic: "t/cmd"))
            == ["op": "dms", "device_id": dev, "core_id": "core", "secret": "s", "mqtt_url": "ssl://m:8883", "command_topic": "t/cmd"])
    #expect(try fields(.dmsReset) == ["op": "dms_reset"])
    let bad: [ProvisioningCommand] = [
        .dmsProof(deviceID: "ABC123DEF456GHI789", challenge: challenge),     // upper case
        .dmsProof(deviceID: "abc123def456ghi78", challenge: challenge),      // 17 chars
        .dmsProof(deviceID: dev, challenge: "short-0123456"),                // < 16
        .dmsProof(deviceID: dev, challenge: String(repeating: "a", count: 129)),
        .dmsProof(deviceID: dev, challenge: "AbCd+/0123456789xyz="),        // std base64
        .dms(deviceID: dev, coreID: "", secret: "s", mqttURL: "u", commandTopic: "t"),
        .dms(deviceID: dev, coreID: "c", secret: "s", mqttURL: "u", commandTopic: String(repeating: "t", count: 500)),
    ]
    for command in bad { #expect(throws: (any Error).self) { try command.encoded() } }
}

@Test func dmsStateFieldsDecodeAndDefaultOnOldFirmware() throws {
    let old = try JSONDecoder().decode(DeviceCloudState.self, from: Data(#"{"wifi_connected":true,"authorized":true,"error":""}"#.utf8))
    #expect(old.dms == "" && old.deviceID == "" && old.proof == "")
    let next = try JSONDecoder().decode(DeviceCloudState.self, from: Data(
        #"{"wifi_connected":true,"authorized":true,"error":"","dms":"online","device_id":"abc123def456ghi789","proof":"sig_-"}"#.utf8))
    #expect(next.dms == "online" && next.deviceID == "abc123def456ghi789" && next.proof == "sig_-")
    #expect(Wire.identity.uppercased().hasPrefix("9052000B-"))
}

@Test func batteryFieldsDecodeAndDefaultOnOldFirmware() throws {
    let old = try JSONDecoder().decode(DeviceCloudState.self, from: Data(#"{"wifi_connected":true,"authorized":true,"error":""}"#.utf8))
    #expect(old.battery == -1 && !old.charging && !old.usbPower)
    let next = try JSONDecoder().decode(DeviceCloudState.self, from: Data(
        #"{"wifi_connected":true,"authorized":true,"error":"","battery":42,"charging":true,"usb_power":true}"#.utf8))
    #expect(next.battery == 42 && next.charging && next.usbPower)
}

// Throwaway self-signed P-256 cert, CN yd_0123456789abcdefghijklmnop; its key was discarded.
private let testCertificate = Data(base64Encoded: """
    MIIBhDCCASqgAwIBAgIUaUDCcksq6mH0oWum7KpnBZNLU4YwCgYIKoZIzj0EAwIwKDEmMCQGA1UEAwwdeWRfMDEyMzQ1Njc4OWFiY2RlZmdoaWprbG1ub3AwHhcNMjYxMTA1MTEwOTQzWhcNMjYxMTA2MTEwOTQzWjAoMSYwJAYDVQQDDB15ZF8wMTIzNDU2Nzg5YWJjZGVmZ2hpamtsbW5vcDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABOVhp5Kj8gKGlpZFTHhRawdqYRXjycLgtTrhre+p/VK1yNRl8A7J9AINpW8l+kJlT2nruCFLx52qd1jdaGGFbJKjMjAwMB0GA1UdDgQWBBQAgJiJriWG19OtFC96E0sE6tr8pzAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0gAMEUCIA2jwAjaOIAUeNYBM7+EIBDf3eHFBPGD0eNyldOOr7PZAiEArosN8mJjTHM3Swh4Vv0LoDQYyBVtVefl45+IwujI7dY=
    """)!

@Test func factoryIdentityReadsCommonName() throws {
    #expect(try FactoryIdentity.deviceID(certificate: testCertificate) == "yd_0123456789abcdefghijklmnop")
    do { _ = try FactoryIdentity.deviceID(certificate: Data()); Issue.record("empty must fail") }
    catch { #expect(error.localizedDescription == "设备没有出厂身份") }
    do { _ = try FactoryIdentity.deviceID(certificate: Data([0x30, 0x03, 0x01, 0x02, 0x03])); Issue.record("garbage must fail") }
    catch { #expect(error.localizedDescription == "设备出厂证书无效") }
}

@Test func oauthCallbackChecksStateEndpointAndDuplicateParameters() throws {
    let redirect = URL(string: "http://127.0.0.1:19432/callback")!
    #expect(try OAuthCallback.code(from: URL(string: "http://127.0.0.1:19432/callback?code=abc&state=expected")!,
                                  redirect: redirect, state: "expected") == "abc")
    for raw in ["http://127.0.0.1:19432/callback?code=abc&state=bad",
                "http://127.0.0.1:19433/callback?code=abc&state=expected",
                "http://127.0.0.1:19432/other?code=abc&state=expected",
                "http://127.0.0.1:19432/callback?code=abc&state=expected&code=evil",
                "http://127.0.0.1:19432/callback?error=access_denied&state=expected"] {
        #expect(throws: (any Error).self) { try OAuthCallback.code(from: URL(string: raw)!, redirect: redirect, state: "expected") }
    }
    let app = URL(string: "com.yaha.desk.ios:/oauth")!
    #expect(try OAuthCallback.code(from: URL(string: "com.yaha.desk.ios:/oauth?code=abc&state=expected&iss=https%3A%2F%2Fhub.flyaha.top%2F")!,
                                  redirect: app, state: "expected", issuer: URL(string: "https://hub.flyaha.top")!) == "abc")
    for raw in ["com.yaha.desk.ios://evil/oauth?code=abc&state=expected", "com.yaha.desk.ios:/other?code=abc&state=expected",
                "com.evil.app:/oauth?code=abc&state=expected", "http://evil/oauth?code=abc&state=expected"] {
        #expect(throws: (any Error).self) { try OAuthCallback.code(from: URL(string: raw)!, redirect: app, state: "expected") }
    }
}

@Test func pkceUsesRFC7636S256VectorAndFormEscapesPlus() throws {
    #expect(OAuthPKCE.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    let form = String(decoding: OAuthPKCE.form(["code": "a+b/c=", "scope": "desk.configure"]), as: UTF8.self)
    #expect(form.contains("a%2Bb%2Fc%3D"))
    #expect(!form.contains("+"))
    #expect(OAuthPKCE.random().count >= 43)
}

@Test func loopbackIgnoresBadStateButFinishesTrustedDenialImmediately() async throws {
    let issuer = URL(string: "https://hub.flyaha.top")!
    let receiver = try LoopbackReceiver(state: "expected-state", issuer: issuer)
    defer { receiver.cancel() }
    let waiting = Task { try await receiver.receive(timeout: 1) }
    var callback = URLComponents(url: receiver.redirectURL, resolvingAgainstBaseURL: false)!
    callback.queryItems = [.init(name: "state", value: "bad-state"), .init(name: "error", value: "access_denied"),
                           .init(name: "iss", value: issuer.absoluteString + "/")]
    let (_, invalid) = try await URLSession.shared.data(from: callback.url!)
    #expect((invalid as? HTTPURLResponse)?.statusCode == 400)
    callback.queryItems?[0].value = "expected-state"
    let start = Date()
    _ = try await URLSession.shared.data(from: callback.url!)
    do {
        _ = try await waiting.value
        Issue.record("拒绝授权应立即结束并报告拒绝")
    } catch {
        #expect(error.localizedDescription.contains("拒绝"))
        #expect(Date().timeIntervalSince(start) < 0.8)
    }
}

@Test func cloudErrorCodesReadAsNextSteps() {
    var state = DeviceCloudState()
    #expect(state.errorMessage == nil)
    state.error = "reauthorize"
    #expect(state.errorMessage == "设备授权已失效，请重新授权设备")
    state.error = "future_code"
    #expect(state.errorMessage?.contains("future_code") == true)
}

@Test func wifiReasonDecodesOptionalAndReadsAsCause() throws {
    let old = try JSONDecoder().decode(DeviceCloudState.self, from: Data(#"{"wifi_connected":false,"authorized":false,"error":""}"#.utf8))
    #expect(old.wifiReason == 0 && old.wifiFailure == nil)
    var state = try JSONDecoder().decode(DeviceCloudState.self,
                                         from: Data(#"{"wifi_connected":false,"authorized":false,"error":"","wifi_reason":15}"#.utf8))
    #expect(state.wifiFailure?.contains("密码") == true)
    state.wifiReason = 201
    #expect(state.wifiFailure?.contains("找不到") == true)
    state.wifiReason = 211  // a password given for an open network
    #expect(state.wifiFailure?.contains("留空密码") == true)
    state.wifiReason = 200  // beacon timeout: nothing the user can fix
    #expect(state.wifiFailure == nil)
}
