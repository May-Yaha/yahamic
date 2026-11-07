import Darwin
import DeskProtocol
import Foundation

/// 设备自带的 USB-Serial-JTAG 串口(/dev/cu.usbmodem*):原始模式,DTR/RTS 经 ioctl 控制。
public final class SerialFlashPort: FlashPort {
    public let path: String
    private var fd: Int32 = -1

    /// 当前插着的设备串口;Espressif 的 USB 串口在 macOS 上都叫 cu.usbmodem*。
    public static func candidates() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names.filter { $0.hasPrefix("cu.usbmodem") }.sorted().map { "/dev/" + $0 }
    }

    public init(path: String) throws {
        self.path = path
        try open()
    }

    deinit { if fd >= 0 { Darwin.close(fd) } }

    private func open() throws {
        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw DeskProtocolError("打不开 \(path):\(String(cString: strerror(errno)))") }
        // 独占(同 pyserial exclusive):擦完程序区后别的串口工具插进来抢走 ROM 回应,设备就没有可启动的程序了。
        guard ioctl(fd, TIOCEXCL) == 0 else {
            Darwin.close(fd); fd = -1
            throw DeskProtocolError("\(path) 正被别的程序占用：先关掉串口监视器再安装")
        }
        var t = termios()
        tcgetattr(fd, &t)
        cfmakeraw(&t)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        t.c_cflag &= ~tcflag_t(HUPCL)  // 关闭时不拉复位线
        cfsetspeed(&t, speed_t(B115200))  // USB 串口不看波特率,ROM 默认值
        tcsetattr(fd, TCSANOW, &t)
        tcflush(fd, TCIOFLUSH)
    }

    public func reopen() throws {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        for _ in 0..<20 {  // 复位后最多等 2 秒重枚举
            if (try? open()) != nil { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        try open()
    }

    public func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 { offset += n; continue }
                guard n < 0, errno == EAGAIN else { throw DeskProtocolError("串口写入失败:\(String(cString: strerror(errno)))") }
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&p, 1, 1000)
            }
        }
    }

    public func read(timeout: TimeInterval) throws -> [UInt8] {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&p, 1, Int32(max(1, timeout * 1000)))
        guard ready > 0 else { return [] }
        if p.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { throw DeskProtocolError("设备串口断开") }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = Darwin.read(fd, &buf, buf.count)
        if n < 0 && errno != EAGAIN { throw DeskProtocolError("串口读取失败:\(String(cString: strerror(errno)))") }
        return n > 0 ? Array(buf[..<n]) : []
    }

    /// on = 拉低(置位 modem 线),与 esptool 的 PIN_LOW 同义。
    public func setDTR(_ on: Bool) throws { try modem(TIOCM_DTR, on) }
    public func setRTS(_ on: Bool) throws { try modem(TIOCM_RTS, on) }

    private func modem(_ bit: Int32, _ on: Bool) throws {
        var bits = bit
        guard ioctl(fd, on ? UInt(TIOCMBIS) : UInt(TIOCMBIC), &bits) == 0 else {
            throw DeskProtocolError("控制串口失败:\(String(cString: strerror(errno)))")
        }
    }
}
