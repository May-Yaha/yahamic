import Foundation
import Testing
@testable import YahaDesk

@Test func panLoginParsesOnlyMatchingCallback() throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func url(_ s: String) -> URL { URL(string: s)! }
    let ok = PanLogin.parse(url("https://pan.baidu.com/union/oauth/authorize#expires_in=3600&access_token=a%2Bb&state=st"),
                            state: "st", now: now)
    #expect(ok == PanToken(token: "a+b", expires: 1_003_600))
    let defaulted = PanLogin.parse(url("https://pan.baidu.com/union/oauth/authorize#access_token=t&state=st"),
                                   state: "st", now: now)
    #expect(defaulted == PanToken(token: "t", expires: 3_592_000))
    let macState = PanLogin.macStatePrefix + "random"
    let bridged = PanLogin.parse(url("com.yaha.desk:/baidu-pan/oauth#expires_in=3600&access_token=mac%2Btoken&state=\(macState)"),
                                 state: macState, now: now)
    #expect(bridged == PanToken(token: "mac+token", expires: 1_003_600))
    #expect(PanLogin.parse(url("com.yaha.desk:/baidu-pan/oauth#access_token=t&state=ios"),
                           state: "ios", now: now) == nil)
    for raw in ["http://pan.baidu.com/union/oauth/authorize#access_token=t&state=st",
                "https://pan.baidu.com/union/oauth/other#access_token=t&state=st",
                "https://pan.baidu.com/union/oauth/authorize#error=access_denied&state=st",
                "https://pan.baidu.com/union/oauth/authorize#access_token=t&state=st&access_token=evil",
                "https://openapi.baidu.com/oauth/2.0/login_success#access_token=t&state=st",
                "https://evil.example/union/oauth/authorize#access_token=t&state=st"] {
        #expect(PanLogin.parse(url(raw), state: "st", now: now) == nil)
    }
    for raw in ["com.yaha.desk://evil/baidu-pan/oauth#access_token=t&state=\(macState)",
                "com.yaha.desk:/other#access_token=t&state=\(macState)",
                "com.evil.desk:/baidu-pan/oauth#access_token=t&state=\(macState)",
                "com.yaha.desk:/baidu-pan/oauth?access_token=query#access_token=t&state=\(macState)"] {
        #expect(PanLogin.parse(url(raw), state: macState, now: now) == nil)
    }
    let authorization = URLComponents(url: PanLogin.authorizeURL(state: "st"), resolvingAgainstBaseURL: false)!
    #expect(authorization.host == "pan.baidu.com")
    #expect(authorization.path == "/union/oauth/authorize")
    let items = authorization.queryItems!
    let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    #expect(query == ["response_type": "token", "client_id": PanLogin.appKey,
                      "redirect_uri": "", "state": "st"])
    let macAuthorization = URLComponents(
        url: PanLogin.authorizeURL(state: macState, redirectURI: PanLogin.macRedirectURI),
        resolvingAgainstBaseURL: false
    )!
    let macQuery = Dictionary(uniqueKeysWithValues: macAuthorization.queryItems!.map { ($0.name, $0.value ?? "") })
    #expect(macQuery["redirect_uri"] == PanLogin.macRedirectURI.absoluteString)
    #expect(macQuery["state"] == macState)
    #expect(PanToken(token: "t", expires: 1_000_061).valid(at: now))
    #expect(!PanToken(token: "t", expires: 1_000_060).valid(at: now))
}

@Test func panLoginCancelsSensitiveFragmentsOutsideTheTrustedCallback() throws {
    func url(_ value: String) -> URL { URL(string: value)! }
    switch PanLogin.navigation(url("https://pan.baidu.com/union/oauth/authorize#access_token=t&state=ok"),
                               state: "ok", now: Date(timeIntervalSince1970: 0)) {
    case let .token(token): #expect(token.token == "t")
    default: Issue.record("trusted direct-token callback should finish login")
    }
    for raw in ["http://pan.baidu.com/union/oauth/authorize#access_token=t&state=ok",
                "https://evil.example/union/oauth/authorize#access_token=t&state=ok",
                "https://evil.example/callback?access_token=t&state=ok",
                "https://pan.baidu.com/union/oauth/authorize?access_token=query#access_token=fragment&state=ok",
                "https://pan.baidu.com/union/oauth/authorize#access_token=a&%61ccess_token=b&state=ok",
                "https://openapi.baidu.com/oauth/2.0/login_success#access_token=t&state=ok",
                "https://pan.baidu.com/union/oauth/other#error=access_denied&state=ok"] {
        if case .reject = PanLogin.navigation(url(raw), state: "ok") {} else {
            Issue.record("sensitive untrusted callback was not rejected: \(raw)")
        }
    }
    if case .allow = PanLogin.navigation(url("https://pan.baidu.com/union/oauth/authorize?client_id=x"), state: "ok") {} else {
        Issue.record("ordinary authorization navigation should continue")
    }
}

@Test func panDownloadOnlyTrustsBaiduFileHostsAndExactMetadata() {
    for raw in ["https://d.pcs.baidu.com/file", "https://c3.pcs.baidu.com/file?x=1",
                "https://d.baidupcs.com/file"] {
        #expect(PanFiles.isTrustedDownloadURL(URL(string: raw)!))
    }
    for raw in ["http://d.pcs.baidu.com/file", "https://pcs.baidu.com/file",
                "https://d.pcs.baidu.com.evil/file", "https://user@d.pcs.baidu.com/file",
                "https://d.pcs.baidu.com:443/file", "https://d.pcs.baidu.com/file#fragment"] {
        #expect(!PanFiles.isTrustedDownloadURL(URL(string: raw)!))
    }
    let item = PanFiles.Item(id: 7, path: "/apps/拾见/录音/2026-11-06/120000.opus", size: 4,
                             mtime: Date(timeIntervalSince1970: 0))
    #expect(PanFiles.matchesDownloadMetadata(["fs_id": NSNumber(value: 7), "path": item.path,
                                              "size": NSNumber(value: 4), "isdir": NSNumber(value: 0)], item: item))
    #expect(!PanFiles.matchesDownloadMetadata(["fs_id": NSNumber(value: 7), "path": item.path,
                                               "size": NSNumber(value: 3), "isdir": NSNumber(value: 0)], item: item))
    #expect(PanFiles.trustedUploadServer(["https://evil.example", "https://c3.pcs.baidu.com/"]) ==
        "https://c3.pcs.baidu.com")
    #expect(PanFiles.trustedUploadServer(["https://d.pcs.baidu.com.evil"]) == "https://d.pcs.baidu.com")
}

@Test func panVoiceProfileDeletionIsConfinedToItsPrivateRoot() {
    #expect(PanFiles.canDeleteVoiceProfile([PanFiles.voiceProfileRoot + "/profile-a/phrase-1.wav"]))
    #expect(!PanFiles.canDeleteVoiceProfile([PanFiles.voiceProfileRoot]))
    #expect(!PanFiles.canDeleteVoiceProfile([PanFiles.root + "/2026-11-06/120000.opus"]))
    #expect(!PanFiles.canDeleteVoiceProfile([PanFiles.voiceProfileRoot + "-other/file.wav"]))
    #expect(PanFiles.didDeleteVoiceProfile(
        ["info": [["errno": NSNumber(value: 0)], ["errno": NSNumber(value: 0)]]], expectedCount: 2))
    #expect(!PanFiles.didDeleteVoiceProfile([:], expectedCount: 1))
    #expect(!PanFiles.didDeleteVoiceProfile(
        ["info": [["errno": NSNumber(value: 0)], ["errno": NSNumber(value: -9)]]], expectedCount: 2))
}

@Test func dmsReplyMapsErrnoToUserText() throws {
    func json(_ errno: Int) -> Data { Data(#"{"errno":\#(errno),"device_id":"abc123def456ghi789"}"#.utf8) }
    #expect(try DmsClient.reply("register", 200, json(0))["device_id"] as? String == "abc123def456ghi789")
    let cases: [(Int, String)] = [
        (42103, "设备已被他人绑定，请先在对方网盘解绑"), (42112, "网盘里找不到这台设备"),
        (42117, "设备出厂证书不被信任"), (42118, "操作太频繁，请稍后再试"),
        (-6, "网盘登录已失效，请重新登录网盘"), (111, "网盘登录已失效，请重新登录网盘"),
        (31023, "网盘设备服务出错（bind errno 31023）"),
    ]
    for (errno, text) in cases {
        #expect(throws: DmsClient.Failure(errno: errno, errorDescription: text)) { try DmsClient.reply("bind", 200, json(errno)) }
    }
    #expect(throws: DmsClient.Failure(errno: -1, errorDescription: "网盘设备服务出错（bind HTTP 502）")) {
        try DmsClient.reply("bind", 502, Data("<html>".utf8))
    }
    var lines: [String] = []
    _ = try? DmsClient.reply("bind", 200, json(42103)) { lines.append($0) }
    #expect(lines == ["dms bind errno 42103"])
}
