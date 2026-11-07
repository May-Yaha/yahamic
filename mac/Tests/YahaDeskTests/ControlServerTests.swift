import Darwin
import Foundation
import Testing
@testable import YahaDesk

@Suite(.serialized)
struct ControlServerTests {
    private func fixture() throws -> (ControlServer, URL) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("yd-\(UUID().uuidString.prefix(8))").appendingPathComponent("control.sock")
        let server = try #require(ControlServer(path: path) { request in ["value": request["value"] ?? ""] })
        return (server, path)
    }

    private func connect(_ path: URL, timeoutSeconds: Int = 2) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.path.utf8)
        try #require(bytes.count < MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { let failure = errno; close(fd); throw POSIXError(POSIXErrorCode(rawValue: failure)!) }
        var on: Int32 = 1
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        #expect(setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0)
        #expect(setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0)
        return fd
    }

    private func send(_ text: String, to fd: Int32) throws {
        let data = Data(text.utf8)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.send(fd, bytes.baseAddress! + offset, bytes.count - offset, 0)
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
                offset += count
            }
        }
    }

    private func response(_ fd: Int32) throws -> [String: String] {
        var data = Data(), byte: UInt8 = 0
        while true {
            let count = recv(fd, &byte, 1, 0)
            guard count > 0 else { throw POSIXError(count == 0 ? .ECONNRESET : POSIXErrorCode(rawValue: errno)!) }
            if byte == 10 { break }
            data.append(byte)
        }
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    private func expectClosed(_ fd: Int32) {
        var byte: UInt8 = 0
        let count = recv(fd, &byte, 1, 0)
        let failure = errno
        #expect(count == 0 || (count < 0 && failure == ECONNRESET))
    }

    @Test func delayedAndFragmentedRequestsKeepTheControlConnectionOpen() async throws {
        let (server, path) = try fixture()
        defer { server.stop(); try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let fd = try connect(path)
        defer { close(fd) }
        try await Task.sleep(for: .milliseconds(100))
        try send("{\"value\":", to: fd)
        try await Task.sleep(for: .milliseconds(100))
        try send("\"first\"}\n", to: fd)
        #expect(try response(fd)["value"] == "first")
        try await Task.sleep(for: .milliseconds(100))
        try send("{\"value\":\"second\"}\n", to: fd)
        #expect(try response(fd)["value"] == "second")
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func malformedAndDisconnectedPeersDoNotPreventLaterRequests() async throws {
        let (server, path) = try fixture()
        defer { server.stop(); try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let malformed = try connect(path)
        defer { close(malformed) }
        try send("not-json\n", to: malformed)
        expectClosed(malformed)
        let interrupted = try connect(path)
        try send("{\"value\":", to: interrupted)
        close(interrupted)
        try await Task.sleep(for: .milliseconds(100))
        let valid = try connect(path)
        defer { close(valid) }
        try send("{\"value\":\"valid\"}\n", to: valid)
        #expect(try response(valid)["value"] == "valid")
    }

    @Test func fourClientsAreKeptAndFifthIsRejectedUntilASlotIsReleased() async throws {
        let (server, path) = try fixture()
        defer { server.stop(); try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        var clients = [Int32]()
        defer { clients.forEach { close($0) } }
        for _ in 0..<4 { clients.append(try connect(path)) }
        try await Task.sleep(for: .milliseconds(100))
        let extra = try connect(path)
        defer { close(extra) }
        expectClosed(extra)
        for (index, client) in clients.enumerated() {
            try send("{\"value\":\"\(index)\"}\n", to: client)
            #expect(try response(client)["value"] == String(index))
        }
        close(clients.removeFirst())
        try await Task.sleep(for: .milliseconds(100))
        let replacement = try connect(path)
        clients.append(replacement)
        try send("{\"value\":\"replacement\"}\n", to: replacement)
        #expect(try response(replacement)["value"] == "replacement")
    }

    @Test func idleClientIsClosedByTheExistingFiveSecondReadTimeout() throws {
        let (server, path) = try fixture()
        defer { server.stop(); try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let fd = try connect(path, timeoutSeconds: 8)
        defer { close(fd) }
        let started = Date()
        expectClosed(fd)
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed >= 4.5 && elapsed < 8)
    }
}
