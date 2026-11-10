import CryptoKit
import Foundation

/// Baidu Pan file APIs for recording backup: precreate → locateupload → superfile2 → create, and list.
/// Same rules as DmsClient: the token goes in the query (the APIs require it) and is never logged.
struct PanFiles: Sendable {
    static let root = "/apps/拾见/录音"
    static let voiceProfileRoot = root + "/声纹"
    static let blockSize = 4 << 20

    struct Item: Identifiable, Equatable, Sendable {
        let id: UInt64  // fs_id
        let path: String
        let size: Int
        let mtime: Date
    }

    /// One recording: the `HHmmss.opus` audio and, when dictation inserted text for it, the `HHmmss.txt` beside it.
    struct Take: Identifiable, Equatable, Sendable {
        let audio: Item
        var transcript: Item?
        var id: UInt64 { audio.id }
        var path: String { audio.path }
        var size: Int { audio.size }
        var mtime: Date { audio.mtime }
    }

    /// Pairs each audio file with its same-named text, keeping the listing order.
    static func takes(_ items: [Item]) -> [Take] {
        let texts = Dictionary(items.filter { $0.path.hasSuffix(".txt") }.map { (String($0.path.dropLast(4)), $0) }) { a, _ in a }
        return items.filter { $0.path.hasSuffix(".opus") }.map { Take(audio: $0, transcript: texts[String($0.path.dropLast(5))]) }
    }

    /// Takes by local day, newest day and newest take first.
    static func days(_ takes: [Take], calendar: Calendar = .current) -> [(day: Date, items: [Take])] {
        Dictionary(grouping: takes) { calendar.startOfDay(for: $0.mtime) }
            .map { (day: $0.key, items: $0.value.sorted { $0.mtime > $1.mtime }) }
            .sorted { $0.day > $1.day }
    }

    let token: String
    var log: @Sendable (String) -> Void
    var session: URLSession

    init(token: String, log: @escaping @Sendable (String) -> Void = { _ in }, session: URLSession? = nil) {
        self.token = token
        self.log = log
        self.session = session ?? URLSession(configuration: .ephemeral, delegate: PanRedirectDelegate(),
                                             delegateQueue: nil)
    }

    /// Uploads `data` to `path`; a name clash gets renamed (rtype 1), or replaced (rtype 3) when `overwrite`.
    /// Returns the stored path.
    func upload(_ data: Data, to path: String, modified: Date, overwrite: Bool = false) async throws -> String {
        let blocks = stride(from: 0, to: max(data.count, 1), by: Self.blockSize).map {
            data.subdata(in: $0..<min($0 + Self.blockSize, data.count))
        }
        let md5s = blocks.map { Insecure.MD5.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        let list = String(data: try JSONSerialization.data(withJSONObject: md5s), encoding: .utf8)!
        let mtime = String(Int(modified.timeIntervalSince1970))
        let file: [String: String] = ["path": path, "size": String(data.count), "isdir": "0", "block_list": list,
                                      "rtype": overwrite ? "3" : "1", "local_ctime": mtime, "local_mtime": mtime]
        let pre = try await call("precreate", "https://pan.baidu.com/rest/2.0/xpan/file", ["method": "precreate"],
                                 form: file.merging(["autoinit": "1"]) { $1 })
        guard let uploadid = pre["uploadid"] as? String, !uploadid.isEmpty else { throw Self.failure(-1, "precreate") }
        if (pre["return_type"] as? NSNumber)?.intValue != 2 {  // 2: rapid upload, content already on Pan
            let wanted = (pre["block_list"] as? [NSNumber])?.map(\.intValue).filter(blocks.indices.contains) ?? []
            let host = await uploadHost(path, uploadid)
            for i in wanted.isEmpty ? Array(blocks.indices) : wanted {
                let r = try await call("superfile2", host + "/rest/2.0/pcs/superfile2",
                                       ["method": "upload", "type": "tmpfile", "path": path, "uploadid": uploadid,
                                        "partseq": String(i)], part: blocks[i])
                guard r["md5"] as? String == md5s[i] else { throw Self.failure(-1, "superfile2") }
            }
        }
        let made = try await call("create", "https://pan.baidu.com/rest/2.0/xpan/file", ["method": "create"],
                                  form: file.merging(["uploadid": uploadid]) { $1 })
        // Only an fs_id proves Pan stored the file; the caller deletes the local copy on return.
        guard made["fs_id"] is NSNumber else { throw Self.failure(-1, "create") }
        return made["path"] as? String ?? path
    }

    /// Newest first, at most `limit`: date folders by name, then each folder's files by name (both are the recording
    /// time; a clock-rollback `HHmmss.n.opus` sorts just before its `HHmmss.opus`). listall answers errno 20020 (path
    /// outside the app's scope) for this app; `list`, which yahaops-api uses for the same app, works. A missing root
    /// is an empty list; a folder failing after some files were listed returns what was listed.
    func recent(limit: Int = 200) async throws -> [Item] {  // audio + text: about 100 takes
        var files: [[String: Any]] = []
        let days: [[String: Any]]
        // ponytail: newest 30 day folders, one call each; page or cache if older takes must show.
        do { days = try await list(Self.root, limit: 30) } catch let f as DmsClient.Failure where f.errno == -9 { return [] }
        for day in days where files.count < limit && (day["isdir"] as? NSNumber)?.intValue == 1 {
            guard let dir = day["path"] as? String else { continue }
            do {
                files += try await list(dir, limit: limit - files.count).filter { ($0["isdir"] as? NSNumber)?.intValue != 1 }
            } catch where !files.isEmpty { break }
        }
        return files.compactMap { e in
            guard let id = (e["fs_id"] as? NSNumber)?.uint64Value, let path = e["path"] as? String else { return nil }
            let t = (e["local_mtime"] as? NSNumber ?? e["server_mtime"] as? NSNumber)?.doubleValue ?? 0
            return Item(id: id, path: path, size: (e["size"] as? NSNumber)?.intValue ?? 0,
                        mtime: Date(timeIntervalSince1970: t))
        }
    }

    func download(_ item: Item) async throws -> URL {
        let r = try await call("filemetas", "https://pan.baidu.com/rest/2.0/xpan/multimedia",
                               ["method": "filemetas", "fsids": "[\(item.id)]", "dlink": "1"])
        guard let entries = r["list"] as? [[String: Any]], entries.count == 1, let entry = entries.first,
              Self.matchesDownloadMetadata(entry, item: item), let link = entry["dlink"] as? String,
              var components = URLComponents(string: link), let downloadURL = components.url,
              Self.isTrustedDownloadURL(downloadURL),
              !(components.queryItems ?? []).contains(where: { $0.name == "access_token" }) else {
            throw Self.failure(-1, "filemetas")
        }
        components.percentEncodedQuery = [components.percentEncodedQuery, Self.encode(["access_token": token])]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "&")
        var request = URLRequest(url: components.url!, timeoutInterval: 60)
        request.setValue("pan.baidu.com", forHTTPHeaderField: "User-Agent")
        let (temporary, response) = try await session.download(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let finalURL = response.url, Self.isTrustedDownloadURL(finalURL),
              let size = (try? FileManager.default.attributesOfItem(atPath: temporary.path)[.size]) as? NSNumber,
              size.intValue == item.size else {
            throw Self.failure(-1, "download")
        }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".opus")
        try FileManager.default.moveItem(at: temporary, to: target)
        return target
    }

    /// The dictation text of a take; same checked download as the audio, read and deleted at once.
    func text(_ item: Item) async throws -> String {
        let url = try await download(item)
        defer { try? FileManager.default.removeItem(at: url) }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Moves only this app's voice-profile artifacts to Pan's recycle bin.
    func deleteVoiceProfile(paths: [String]) async throws {
        guard !paths.isEmpty, Self.canDeleteVoiceProfile(paths),
              let encoded = try? JSONSerialization.data(withJSONObject: paths),
              let fileList = String(data: encoded, encoding: .utf8) else {
            throw Self.failure(-1, "filemanager-delete")
        }
        let response = try await call(
            "filemanager-delete", "https://pan.baidu.com/rest/2.0/xpan/file",
            ["method": "filemanager", "opera": "delete"],
            form: ["async": "0", "filelist": fileList]
        )
        guard Self.didDeleteVoiceProfile(response, expectedCount: paths.count) else {
            throw Self.failure(-1, "filemanager-delete")
        }
    }

    private func list(_ dir: String, limit: Int) async throws -> [[String: Any]] {
        let r = try await call("list", "https://pan.baidu.com/rest/2.0/xpan/file",
                               ["method": "list", "dir": dir, "order": "name", "desc": "1", "start": "0",
                                "limit": String(limit)])
        return r["list"] as? [[String: Any]] ?? []
    }

    /// The host is asked for every upload and not cached (the docs say so); the default host is the fallback.
    private func uploadHost(_ path: String, _ uploadid: String) async -> String {
        let r = try? await call("locateupload", "https://d.pcs.baidu.com/rest/2.0/pcs/file",
                                ["method": "locateupload", "appid": "250528", "path": path, "uploadid": uploadid,
                                 "upload_version": "2.0"])
        let servers = r?["servers"] as? [[String: Any]] ?? []
        return Self.trustedUploadServer(servers.compactMap { $0["server"] as? String })
    }

    private func call(_ m: String, _ url: String, _ query: [String: String], form: [String: String]? = nil,
                      part: Data? = nil) async throws -> [String: Any] {
        var c = URLComponents(string: url)!
        c.percentEncodedQuery = Self.encode(query.merging(["access_token": token]) { $1 })
        var request = URLRequest(url: c.url!, timeoutInterval: part == nil ? 15 : 60)
        request.httpMethod = form == nil && part == nil ? "GET" : "POST"
        request.setValue("pan.baidu.com", forHTTPHeaderField: "User-Agent")
        if let form {
            request.httpBody = Data(Self.encode(form).utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        if let part {
            let boundary = "yahadesk-" + UUID().uuidString
            var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"blob\"\r\n".utf8)
            body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
            body.append(part)
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            request.httpBody = body
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            log("pan \(m) network error")
            throw DmsClient.Failure(errno: -1, errorDescription: "网络不可用，录音留在本机，稍后自动重传")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            log("pan \(m) HTTP \(status)")
            throw Self.failure(-1, m)
        }
        // xpan answers errno; the pcs hosts answer error_code, and superfile2 only on failure.
        let errno = (r["errno"] as? NSNumber ?? r["error_code"] as? NSNumber)?.intValue ?? 0
        log("pan \(m) HTTP \(status) errno \(errno)")
        guard status == 200, errno == 0 else { throw Self.failure(errno == 0 ? -1 : errno, m) }
        return r
    }

    static func encode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics.intersection(.init(charactersIn: "\u{0}"..."\u{7f}"))
        allowed.insert(charactersIn: "-._~")
        return fields.sorted { $0.key < $1.key }.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
    }

    static func isTrustedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              let host = url.host?.lowercased() else { return false }
        return host.hasSuffix(".pcs.baidu.com") || host.hasSuffix(".baidupcs.com")
    }

    static func matchesDownloadMetadata(_ entry: [String: Any], item: Item) -> Bool {
        item.size > 0 && (entry["fs_id"] as? NSNumber)?.uint64Value == item.id &&
            (entry["path"] as? String) == item.path && (entry["size"] as? NSNumber)?.intValue == item.size &&
            (entry["isdir"] as? NSNumber)?.intValue == 0
    }

    static func trustedUploadServer(_ candidates: [String]) -> String {
        for candidate in candidates {
            guard let url = URL(string: candidate), isTrustedDownloadURL(url),
                  url.path.isEmpty || url.path == "/", url.query == nil else { continue }
            return candidate.hasSuffix("/") ? String(candidate.dropLast()) : candidate
        }
        return "https://d.pcs.baidu.com"
    }

    static func canDeleteVoiceProfile(_ paths: [String]) -> Bool {
        !paths.isEmpty && paths.count <= 10 && paths.allSatisfy { path in
            path.hasPrefix(voiceProfileRoot + "/") &&
                !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == "." || $0 == ".." }
        }
    }

    static func didDeleteVoiceProfile(_ response: [String: Any], expectedCount: Int) -> Bool {
        guard let info = response["info"] as? [[String: Any]], info.count == expectedCount else { return false }
        return info.allSatisfy { ($0["errno"] as? NSNumber)?.intValue == 0 }
    }

    static func failure(_ errno: Int, _ m: String) -> DmsClient.Failure {
        let text = switch errno {
        case -6, 111: "网盘登录已失效，请重新登录网盘"
        case -10: "网盘空间已满"
        default: "网盘文件接口出错（\(m) errno \(errno)）"
        }
        return DmsClient.Failure(errno: errno, errorDescription: text)
    }
}

private final class PanRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              url.fragment == nil else { completionHandler(nil); return }
        completionHandler(url.host?.lowercased() == "pan.baidu.com" || PanFiles.isTrustedDownloadURL(url) ? request : nil)
    }
}
