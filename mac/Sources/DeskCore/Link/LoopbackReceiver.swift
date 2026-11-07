import Darwin
import Dispatch
import Foundation
import DeskProtocol

/// Native OAuth callback, bound only to 127.0.0.1 on an OS-assigned port (RFC 8252 §7.3).
public final class LoopbackReceiver: @unchecked Sendable {
    public let redirectURL: URL
    private let fd: Int32
    private let queue = DispatchQueue(label: "yahadesk.oauth.callback")
    private let source: DispatchSourceRead
    private let expectedState: String
    private let issuer: URL?
    private var continuation: CheckedContinuation<String, Error>?
    private var completed: Result<String, Error>?

    public init(state: String, issuer: URL? = nil) throws {
        expectedState = state
        self.issuer = issuer
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw DeskProtocolError("无法监听本机授权回调") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &size) }
        }
        guard bound == 0, named == 0, listen(socketFD, 4) == 0,
              fcntl(socketFD, F_SETFL, O_NONBLOCK) == 0 else {
            close(socketFD)
            throw DeskProtocolError("无法监听本机授权回调")
        }
        fd = socketFD
        redirectURL = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/callback")!
        source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        source.setCancelHandler { close(socketFD) }
        source.setEventHandler { [weak self] in self?.acceptCallback() }
        source.resume()
    }

    public func receive(timeout: TimeInterval = 180) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiting in
                queue.async {
                    if let completed = self.completed { waiting.resume(with: completed) }
                    else { self.continuation = waiting }
                    self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                        self?.finish(.failure(DeskProtocolError("浏览器授权超时，请重试")))
                    }
                }
            }
        } onCancel: { cancel() }
    }

    public func cancel() { queue.async { self.finish(.failure(CancellationError())) } }
    deinit { source.cancel() }

    private func finish(_ result: Result<String, Error>) {
        guard completed == nil else { return }
        completed = result
        continuation?.resume(with: result)
        continuation = nil
        source.cancel()
    }

    private func acceptCallback() {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        guard fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK) == 0 else { return }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        var noSignal: Int32 = 1
        guard setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else { return }
        var header = Data()
        var scratch = [UInt8](repeating: 0, count: 2048)
        while header.count < 8192 {
            let count = recv(client, &scratch, min(scratch.count, 8192 - header.count), 0)
            guard count > 0 else { return }
            header.append(scratch, count: count)
            if header.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        let request = String(decoding: header, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        let fields = request.split(separator: " ")
        guard fields.count == 3, fields[0] == "GET", fields[1].hasPrefix("/callback?"),
              let url = URL(string: "http://127.0.0.1:\(redirectURL.port!)\(fields[1])") else {
            reply(client, code: 400)
            return
        }
        do {
            let code = try OAuthCallback.code(from: url, redirect: redirectURL, state: expectedState, issuer: issuer)
            reply(client, code: 200)
            finish(.success(code))
        } catch OAuthCallbackError.denied {
            reply(client, code: 200, message: "Authorization denied. Return to Yaha Desk.")
            finish(.failure(OAuthCallbackError.denied))
        } catch {
            reply(client, code: 400)  // Invalid callbacks cannot cancel a legitimate pending authorization.
        }
    }

    private func reply(_ client: Int32, code: Int, message: String? = nil) {
        let body = message ?? (code == 200 ? "Authorization received. You can close this page." : "Invalid authorization callback. Return to Yaha Desk.")
        let data = Data("HTTP/1.1 \(code) \(code == 200 ? "OK" : "Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = send(client, bytes.baseAddress! + offset, bytes.count - offset, 0)
                guard count > 0 else { return }
                offset += count
            }
        }
    }
}
