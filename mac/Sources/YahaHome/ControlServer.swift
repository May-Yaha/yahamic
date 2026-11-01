import Darwin
import Dispatch
import Foundation

// 本机控制接口:127.0.0.1:7718,每行一个 JSON 请求、一行 JSON 回复。
// 给脚本/压测工具用,
// 让 AI 代理能直接驱动这台家庭硬件中枢。只绑回环地址,不出本机。
final class ControlServer {
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "yaha.control.listen")
    private let workers = DispatchQueue(label: "yaha.control.work", attributes: .concurrent)
    private let handler: ([String: Any]) async -> [String: Any]

    init?(port: UInt16, handler: @escaping ([String: Any]) async -> [String: Any]) {
        self.handler = handler
        listenFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else { return nil }
        var reuse: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &reuse,
                   socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(listenFD, 8) == 0 else {
            let code = Int(errno)
            close(listenFD)
            listenFD = -1
            print("控制接口监听失败 errno=\(code)")
            return nil
        }
        let src = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptClients() }
        src.resume()
        acceptSource = src
    }

    deinit {
        acceptSource?.cancel()
        if listenFD >= 0 { close(listenFD) }
    }

    private func acceptClients() {
        while true {
            var remote = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(listenFD, &remote, &len)
            guard client >= 0 else { return }
            let fd = client
            workers.async { [weak self] in self?.serve(fd) }
        }
    }

    // 每个连接:阻塞读、按行取请求、等 async handler 出结果、写回一行。
    private func serve(_ fd: Int32) {
        var buffer = Data()
        var scratch = [UInt8](repeating: 0, count: 65536)
        requestLoop: while true {
            let got = recv(fd, &scratch, scratch.count, 0)
            if got <= 0 { break }
            buffer.append(scratch, count: got)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                guard !lineData.isEmpty else { continue }
                let request = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any]
                    ?? ["cmd": "bad-request"]
                var response: [String: Any] = ["error": "handler-failed"]
                let done = DispatchSemaphore(value: 0)
                let handler = handler
                Task {
                    response = await handler(request)
                    done.signal()
                }
                _ = done.wait(timeout: .distantFuture)
                guard let data = try? JSONSerialization.data(withJSONObject: response),
                      var text = String(data: data, encoding: .utf8) else { continue requestLoop }
                text += "\n"
                text.withCString { pointer in
                    _ = send(fd, pointer, strlen(pointer), 0)
                }
            }
        }
        close(fd)
    }
}
