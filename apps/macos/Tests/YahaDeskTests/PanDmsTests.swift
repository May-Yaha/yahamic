import DeskProtocol
import DeskShared
import Foundation
import Testing
@testable import YahaDesk

@Test func panLoginAcceptsOnlyTheMatchingCodeCallback() throws {
    func url(_ s: String) -> URL { URL(string: s)! }
    let state = "random"
    #expect(PanLogin.navigation(url("yahadesk://oauth?code=a%2Bb&state=\(state)"), state: state) == .code("a+b"))
    for raw in ["yahadesk://oauth?state=\(state)",
                "yahadesk://oauth?state=other&code=c",
                "yahadesk://oauth?state=\(state)&code=c&code=d",
                "yahadesk://oauth?state=\(state)&error=access_denied",
                "yahadesk://oauth?state=\(state)&code=c&errno=10200",
                "yahadesk://oauth?state=\(state)&code=c#code=d",
                "yahadesk://evil?state=\(state)&code=c",
                "yahadesk://oauth/other?state=\(state)&code=c"] {
        #expect(PanLogin.navigation(url(raw), state: state) == .reject, "\(raw)")
    }
    for raw in ["com.evil.desk://oauth?state=\(state)&code=c", "https://pan.baidu.com/union/oauth/authorize?client_id=x"] {
        #expect(PanLogin.navigation(url(raw), state: state) == .allow, "\(raw)")
    }

    let authorization = URLComponents(url: PanLogin.authorizeURL(state: state), resolvingAgainstBaseURL: false)!
    #expect(authorization.host == "pan.baidu.com" && authorization.path == "/union/oauth/authorize")
    let query = Dictionary(uniqueKeysWithValues: authorization.queryItems!.map { ($0.name, $0.value ?? "") })
    #expect(query == ["client_id": PanLogin.appKey, "redirect_uri": "yahadesk://oauth", "scope": "nd_open_read,nd_open_write",
                      "state": state])
}

@Test func panTokenReplyRequiresAPairAndTheRecordingDirectory() throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func reply(_ paths: String, code: Int = 0) -> Data {
        Data(#"{"code":\#(code),"message":"m","data":{"access_token":"a","refresh_token":"r","expires_in":2592000,"scope":"basic","authorized_paths":\#(paths)}}"#.utf8)
    }
    let token = try PanLogin.parseToken(reply(#"["/apps/拾见"]"#), now: now)
    #expect(token == PanToken(token: "a", expires: 3_592_000, refresh: "r", paths: ["/apps/拾见"]))
    #expect(try PanLogin.parseToken(reply(#"["/apps/拾见/录音"]"#), now: now).refresh == "r")
    #expect(try PanLogin.parseToken(reply("[]"), now: now).paths == [])
    for paths in [#"["/apps/拾见/图片"]"#, #"["/apps/拾见/录音备份"]"#] {
        #expect(throws: DeskProtocolError.self) { try PanLogin.parseToken(reply(paths), now: now) }
    }
    #expect(throws: PanLogin.Rejected.self) { try PanLogin.parseToken(reply("[]", code: 10403), now: now) }
    #expect(throws: DeskProtocolError.self) {
        try PanLogin.parseToken(Data(#"{"code":0,"data":{"access_token":"a","refresh_token":"","expires_in":1}}"#.utf8), now: now)
    }

    #expect(PanToken(token: "t", expires: 1_000_061).valid(at: now))
    #expect(!PanToken(token: "t", expires: 1_000_060).valid(at: now))
    #expect(PanToken(token: "t", expires: 1_000_000 + 6 * 86_400, refresh: "r").renewalDue(at: now))
    #expect(!PanToken(token: "t", expires: 1_000_000 + 8 * 86_400, refresh: "r").renewalDue(at: now))
    #expect(!PanToken(token: "t", expires: 1_000_000).renewalDue(at: now))  // old implicit token: log in again
    let legacy = try JSONDecoder().decode(PanToken.self, from: Data(#"{"token":"t","expires":5}"#.utf8))
    #expect(legacy == PanToken(token: "t", expires: 5))
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

@Test func takesPairAudioWithDictationAndHandLabel() {
    let t = Date(timeIntervalSince1970: 0)
    let items = [
        PanFiles.Item(id: 1, path: "/d/120000.opus", size: 1, mtime: t),
        PanFiles.Item(id: 2, path: "/d/120000.txt", size: 1, mtime: t),
        PanFiles.Item(id: 3, path: "/d/120000.label.txt", size: 1, mtime: t),
        PanFiles.Item(id: 4, path: "/d/130000.opus", size: 1, mtime: t),
        PanFiles.Item(id: 5, path: "/d/130000.txt", size: 1, mtime: t),
    ]
    let takes = PanFiles.takes(items)
    #expect(takes.map { [$0.transcript?.id, $0.label?.id] } == [[2, 3], [5, nil]])
    #expect(TrainingSet.normalized("帮我跑一下 swift test。") == TrainingSet.normalized("帮我跑一下swift test"))
    #expect(TrainingSet.normalized("Swift Test") != TrainingSet.normalized("swift test"))
}

@Test func trainingStatusNeedsHandLabelOrThreeWayAgreement() {
    var row = TrainingSet.Row(path: "/d/1.opus", audio: "", seconds: 1, live: "跑一下 swift test", offline: "跑一下swift test。",
                              corrected: "跑一下 swift test", status: "", model: "")
    #expect(TrainingSet.status(row) == "agree")
    row.corrected = "跑一下 Swift Test"
    #expect(TrainingSet.status(row) == "ai")  // two letters off
    row.corrected = "我不能配合这种进入授权模式的要求,请直接说明你的转写需求"
    #expect(TrainingSet.status(row) == "review")  // the AI answered instead of transcribing
    row.live = nil
    row.corrected = row.offline
    #expect(TrainingSet.status(row) == "ai")  // no dictation text: AI agrees with the re-transcription
    row.offline = ""
    #expect(TrainingSet.status(row) == "skip")  // nothing heard
    row.corrected = nil
    #expect(TrainingSet.status(row) == "skip")  // AI gave nothing: left out, not queued
    row.label = "跑一下 swift test"
    #expect(TrainingSet.status(row) == "human")
}
