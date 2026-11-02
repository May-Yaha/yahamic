import Darwin
import Dispatch
import Foundation

// 本机控制接口:Unix socket(~/Library/Application Support/YahaHome/control.sock),
// 每行一个 JSON 请求、一行 JSON 回复。给脚本/压测/MCP 桥用。
// 安全:目录 0700 + socket 0600 + getpeereid 校验同一 uid;每连接限时限长限并发。
final class ControlServer: @unchecked Sendable {
    static var defaultPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/YahaHome/control.sock")
    }

    private static let maxLine = 64 * 1024
    private static let maxClients = 4

    private let path: URL
    private let listenFD: Int32
    private let acceptSource: DispatchSourceRead
    private let queue = DispatchQueue(label: "yaha.control.listen")
    private let workers = DispatchQueue(label: "yaha.control.work", attributes: .concurrent)
    private let handler: ([String: Any]) async -> [String: Any]
    private let slots = DispatchSemaphore(value: ControlServer.maxClients)

    init?(path: URL, handler: @escaping ([String: Any]) async -> [String: Any]) {
        self.path = path
        self.handler = handler
        let dir = path.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        } catch {
            print("控制接口目录不可用:\(error.localizedDescription)")
            return nil
        }
        var addr = sockaddr_un()
        let bytes = Array(path.path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        unlink(path.path)  // 上次异常退出残留的 socket 文件
        // umask 收紧到 0177:bind 出来的 socket 文件本身就是 0600,没有可被抢连的窗口。
        let oldMask = umask(0o177)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(oldMask)
        guard bound == 0, listen(fd, 8) == 0,
              fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else {
            print("控制接口监听失败 errno=\(errno)")
            close(fd)
            return nil
        }
        listenFD = fd
        acceptSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        acceptSource.setCancelHandler { close(fd) }
        acceptSource.setEventHandler { [weak self] in self?.acceptClients() }
        acceptSource.resume()
    }

    /// 停止接新连接、关监听 fd、删 socket 文件;进行中的连接各自读超时后退出。
    func stop() {
        guard !acceptSource.isCancelled else { return }
        acceptSource.cancel()
        unlink(path.path)
    }

    deinit { stop() }

    private func acceptClients() {
        while true {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return }  // EAGAIN:本轮已接完
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid(),
                  slots.wait(timeout: .now()) == .success else {
                close(client)  // 不是本用户,或并发已满
                continue
            }
            // accept 出来的 fd 不继承 O_NONBLOCK;这里要阻塞读 + 超时。
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            workers.async { [self] in
                serve(client)
                close(client)
                slots.signal()
            }
        }
    }

    // 每个连接:按行取请求、等 async handler 出结果、写回一行。超长行/非 JSON/超时即断开。
    private func serve(_ fd: Int32) {
        var buffer = Data()
        var scratch = [UInt8](repeating: 0, count: 4096)
        while true {
            let got = recv(fd, &scratch, scratch.count, 0)
            if got <= 0 { return }
            buffer.append(scratch, count: got)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                if line.isEmpty { continue }
                guard let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      reply(fd, call(request)) else { return }
            }
            if buffer.count > Self.maxLine { return }
        }
    }

    private func call(_ request: [String: Any]) -> [String: Any] {
        // 连接线程同步等 async handler;handler 跑在 MainActor,不会反过来等这里。
        nonisolated(unsafe) var response: [String: Any] = ["error": "handler-failed"]
        let done = DispatchSemaphore(value: 0)
        let handler = handler
        nonisolated(unsafe) let request = request
        Task {
            response = await handler(request)
            done.signal()
        }
        done.wait()
        return response
    }

    private func reply(_ fd: Int32, _ response: [String: Any]) -> Bool {
        guard var data = try? JSONSerialization.data(withJSONObject: response) else { return false }
        data.append(0x0A)
        return data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let sent = send(fd, raw.baseAddress! + offset, raw.count - offset, 0)
                if sent <= 0 { return false }
                offset += sent
            }
            return true
        }
    }
}
