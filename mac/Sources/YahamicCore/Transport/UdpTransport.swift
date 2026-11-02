import Darwin
import Dispatch
import Foundation

// —— 传输层:BSD socket UDP ——
// 不用 NWListener/NWConnection:多次重启 daemon 后,NW 的 UDP 会话在系统层
// 出现粘滞,新实例收不到设备的重连包;BSD socket + DispatchSource 行为可预期,
// Bonjour 另走 dnssd 注册。
final class UdpTransport {
    private let fd: Int32
    private var source: DispatchSourceRead?
    private let queue: DispatchQueue
    private let onPacket: (Data, sockaddr_in) -> Void

    init(port: UInt16, queue: DispatchQueue,
         onPacket: @escaping (Data, sockaddr_in) -> Void) throws {
        self.queue = queue
        self.onPacket = onPacket
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw NSError(domain: "udp", code: Int(errno)) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var any = sockaddr_in()
        any.sin_family = sa_family_t(AF_INET)
        any.sin_port = port.bigEndian
        any.sin_addr = in_addr(s_addr: in_addr_t(0))  // INADDR_ANY
        let bound = withUnsafePointer(to: &any) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = Int(errno)
            close(fd)
            throw NSError(domain: "udp-bind", code: code)
        }
        self.fd = fd
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.drain() }
        // fd 只在 cancel 完成后关:事件回调可能还在跑,deinit 里直接 close 会让它读到被复用的 fd。
        let owned = fd
        src.setCancelHandler { close(owned) }
        src.resume()
        source = src
    }

    /// 一次事件把 socket 读空(非阻塞,EAGAIN 即止),免得突发时每个事件只取一包而积压。
    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 2048)
        while true {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let got = buffer.withUnsafeMutableBytes { raw -> Int in
                withUnsafeMutablePointer(to: &from) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &fromLen)
                    }
                }
            }
            guard got > 0 else { return }
            onPacket(Data(buffer[0..<got]), from)
        }
    }

    func send(_ data: Data, to address: sockaddr_in) {
        data.withUnsafeBytes { raw in
            withUnsafePointer(to: address) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(fd, raw.baseAddress, raw.count, 0, $0,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    deinit {
        source?.cancel()  // fd 由 cancelHandler 关闭
    }
}

func addressKey(_ a: sockaddr_in) -> String {
    let bytes = withUnsafeBytes(of: a.sin_addr.s_addr) { Array($0) }
    return "\(bytes[0]).\(bytes[1]).\(bytes[2]).\(bytes[3]):\(UInt16(bigEndian: a.sin_port))"
}
