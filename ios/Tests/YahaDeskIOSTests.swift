import DeskProtocol
import XCTest
@testable import YahaDeskIOS

final class YahaDeskIOSTests: XCTestCase {
    /// 版本号是数字时,真机首个 HTTPS 请求在 CFNetwork 拼 User-Agent 时崩溃。
    func testBundleVersionsAreStrings() {
        for key in ["CFBundleVersion", "CFBundleShortVersionString"] {
            XCTAssertTrue(Bundle.main.object(forInfoDictionaryKey: key) is String, key)
        }
    }

    func testPanLoginStopsAtTheCallbackWithMatchingState() {
        let callback = "yahadesk://oauth"
        XCTAssertEqual(PanLogin.navigation(URL(string: callback + "?code=c&state=ok")!, state: "ok"), .code("c"))
        XCTAssertEqual(PanLogin.navigation(URL(string: callback + "?code=c&state=wrong")!, state: "ok"), .reject)
        XCTAssertEqual(PanLogin.navigation(URL(string: "https://pan.baidu.com/union/oauth/authorize?x=1")!, state: "ok"), .allow)
        let authorization = URLComponents(url: PanLogin.authorizeURL(state: "ok"), resolvingAgainstBaseURL: false)!
        XCTAssertEqual(authorization.queryItems?.first { $0.name == "redirect_uri" }?.value, callback)
        XCTAssertNil(authorization.queryItems?.first { $0.name == "show_dir" })
    }

    func testWiFiCommandUsesExistingFirmwarePayload() throws {
        let data = try ProvisioningCommand.wifi(ssid: "home", password: "password").encoded()
        let object = try JSONSerialization.jsonObject(with: data) as? [String: String]
        XCTAssertEqual(object, ["op": "wifi", "ssid": "home", "password": "password"])
        XCTAssertThrowsError(try ProvisioningCommand.wifi(ssid: "", password: "").encoded())
    }

    func testMissingDevicePromptOnlyAppearsWithoutConnectionOrCandidate() {
        XCTAssertEqual(
            DeviceStore.scanTimeoutMessage(connected: false, discovered: false),
            "没有找到设备，请先在 Mac 上点“暂时断开”"
        )
        XCTAssertNil(DeviceStore.scanTimeoutMessage(connected: true, discovered: false))
        XCTAssertNil(DeviceStore.scanTimeoutMessage(connected: false, discovered: true))
    }

    func testTruncatedCloudNotificationRequestsOneLongRead() throws {
        let truncated = Data(#"{"wifi_connected":false,"authorized":false,"error":"","proof":"abc""#.utf8)
        XCTAssertEqual(DeviceStore.decodeCloudPayload(truncated, rereading: false), .reread)
        XCTAssertEqual(DeviceStore.decodeCloudPayload(truncated, rereading: true), .invalid)
        let complete = Data(#"{"wifi_connected":false,"authorized":false,"error":"","proof":"abc"}"#.utf8)
        guard case let .state(state) = DeviceStore.decodeCloudPayload(complete, rereading: false) else {
            return XCTFail("complete cloud state should decode")
        }
        XCTAssertEqual(state.proof, "abc")
    }

    func testExistingWiFiMustDropBeforeTheNewJoinCanComplete() {
        XCTAssertFalse(DeviceStore.wifiSwitchApplied(DeviceCloudState(wifiConnected: true)))
        XCTAssertTrue(DeviceStore.wifiSwitchApplied(DeviceCloudState(wifiConnected: false)))
    }

    func testLogoutInvalidatesAnInFlightRecordingDownload() {
        XCTAssertTrue(RecordingStore.acceptsResult(request: 4, current: 4, loggedIn: true))
        XCTAssertFalse(RecordingStore.acceptsResult(request: 4, current: 5, loggedIn: true))
        XCTAssertFalse(RecordingStore.acceptsResult(request: 4, current: 4, loggedIn: false))
    }

    func testReconnectOnlyScansWithoutAnExistingPeripheral() {
        XCTAssertTrue(DeviceStore.shouldScan(connected: false, hasPeripheral: false))
        XCTAssertFalse(DeviceStore.shouldScan(connected: true, hasPeripheral: true))
        XCTAssertFalse(DeviceStore.shouldScan(connected: false, hasPeripheral: true))
    }

    func testRemoteAlreadyUnboundStillAllowsLocalReset() {
        XCTAssertTrue(DeviceStore.isRemoteUnbound(errno: 42112))
        XCTAssertFalse(DeviceStore.isRemoteUnbound(errno: 42103))
    }

    func testDeskStatusDecodesCloudReportAndUnreportedDevice() throws {
        let json = #"{"reported":true,"online":true,"reported_at":1800000000,"firmware":"0.3.0","ssid":"公司","muted":true,"mac":false,"dms":"online","pan_device":"abc123def456ghi789"}"#
        let status = try JSONDecoder().decode(DeskStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.panDevice, "abc123def456ghi789")
        XCTAssertEqual(status.reportedAt, 1_800_000_000)
        let empty = try JSONDecoder().decode(DeskStatus.self, from: Data(#"{"reported":false,"online":false,"muted":false,"mac":false}"#.utf8))
        XCTAssertFalse(empty.reported)
        XCTAssertNil(empty.panDevice)
    }

    func testCardMatchesFirmwareLimit() {
        XCTAssertTrue(CloudStore.cardFits(title: "开会", body: String(repeating: "a", count: 503)))
        XCTAssertFalse(CloudStore.cardFits(title: "开会", body: String(repeating: "a", count: 504)))
        XCTAssertFalse(CloudStore.cardFits(title: " \n", body: "正文"))
    }

    func testDmsLabel() {
        XCTAssertEqual(ContentView.dmsLabel(nil), "未绑定")
        XCTAssertEqual(ContentView.dmsLabel("online"), "在线")
        XCTAssertEqual(ContentView.dmsLabel("offline"), "未在线")
    }

    /// 同名 .txt 挂到录音上，没有文字的录音照样列出，顺序跟列表一致。
    func testTakesPairAudioWithText() {
        let item = { (id: UInt64, path: String) in PanFiles.Item(id: id, path: path, size: 1, mtime: Date()) }
        let takes = PanFiles.takes([item(1, "/d/101500.txt"), item(2, "/d/101500.opus"), item(3, "/d/093000.opus"),
                                    item(4, "/d/093000.1.opus")])
        XCTAssertEqual(takes.map(\.id), [2, 3, 4])
        XCTAssertEqual(takes.map { $0.transcript?.id }, [1, nil, nil])
        XCTAssertEqual(TakePlayer.clock(67.9), "1:07")
        XCTAssertEqual(TakePlayer.clock(.nan), "0:00")
    }

    /// 连上过的网络点一下即连；开放网络不问密码；没存过的加密网络必须让用户输入。
    func testSavedWiFiJoinsWithoutTyping() {
        let saved = ["公司": "secret123"]
        XCTAssertEqual(DeviceStore.knownPassword(for: WiFiNetwork(ssid: "公司", rssi: -50, secure: true), saved: saved), "secret123")
        XCTAssertEqual(DeviceStore.knownPassword(for: WiFiNetwork(ssid: "咖啡馆", rssi: -60, secure: false), saved: saved), "")
        XCTAssertNil(DeviceStore.knownPassword(for: WiFiNetwork(ssid: "家", rssi: -40, secure: true), saved: saved))
        XCTAssertEqual(WiFiView.strength(-95), 0.2)
        XCTAssertEqual(WiFiView.strength(-40), 1)
    }

    /// 扫描结果只认序号比发指令前大的列表，旧列表不当新结果。
    func testScanKeepsOnlyFreshList() {
        let list = WiFiScan(scan: 3, networks: [WiFiNetwork(ssid: "公司", rssi: -50, secure: true)])
        XCTAssertEqual(DeviceStore.freshNetworks(list, after: 2), list.networks)
        XCTAssertNil(DeviceStore.freshNetworks(list, after: 3))
    }

    /// 本页刚切的网络优先；切换失败清空 joined 后回落到云端上报，设备没联网时不打勾。
    func testCurrentNetworkFollowsDevice() {
        XCTAssertEqual(WiFiView.current(connected: true, joined: "家", reported: "公司"), "家")
        XCTAssertEqual(WiFiView.current(connected: true, joined: nil, reported: "公司"), "公司")
        XCTAssertNil(WiFiView.current(connected: false, joined: "家", reported: "公司"))
    }

    /// 只有密码类断开原因才改问密码，信号弱等原因不打扰用户。
    func testWrongPasswordReasons() {
        for reason in [15, 202, 204] { XCTAssertTrue(DeviceStore.wrongPassword(reason: reason), "\(reason)") }
        for reason in [0, 201, 8] { XCTAssertFalse(DeviceStore.wrongPassword(reason: reason), "\(reason)") }
    }

    /// 网盘令牌过期（token 为 nil）时不调接口，提示重新登录，卡片表单不关。
    @MainActor
    func testExpiredPanTokenDoesNotSendCard() async {
        let store = CloudStore()
        let sent = await store.sendCard(title: "标题", body: "", panToken: nil)
        XCTAssertFalse(sent)
        XCTAssertEqual(store.message, CloudStore.panExpired)
    }

    /// 钥匙串原地更新：第二次保存覆盖第一次，清空即删除。
    func testSavedWiFiUpdatesInPlace() {
        let original = SavedWiFi.load()
        defer { _ = SavedWiFi.save(original) }
        XCTAssertTrue(SavedWiFi.save(["公司": "one12345"]))
        XCTAssertTrue(SavedWiFi.save(["公司": "two12345", "家": ""]))
        XCTAssertEqual(SavedWiFi.load(), ["公司": "two12345", "家": ""])
        XCTAssertTrue(SavedWiFi.save([:]))
        XCTAssertEqual(SavedWiFi.load(), [:])
    }

    func testRecordingsGroupByLocalDayNewestFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let item = { (id: UInt64, at: TimeInterval) in PanFiles.Take(audio: PanFiles.Item(id: id, path: "/\(id).opus", size: 1, mtime: Date(timeIntervalSince1970: at))) }
        // 1_800_000_000 = 2027-01-15 16:00 +08:00；+9 小时跨到次日 01:00。
        let groups = PanFiles.days([item(1, 1_800_000_000), item(2, 1_800_032_400), item(3, 1_800_003_600)], calendar: calendar)
        XCTAssertEqual(groups.map { $0.items.map(\.id) }, [[2], [3, 1]])
    }
}

private extension DeviceCloudState {
    init(wifiConnected: Bool) {
        self.init()
        self.wifiConnected = wifiConnected
    }
}
