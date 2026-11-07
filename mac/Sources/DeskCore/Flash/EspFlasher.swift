import CryptoKit
import Darwin
import DeskProtocol
import Foundation

// 一键安装固件:经 USB 串口用 ESP32-S3 ROM 下载协议写 flash(命令格式同 esptool,不带 stub)。
// 只写 bootloader / 分区表 / 程序三段,且只写与设备上内容不同的段;nvs、phy、fac 永不碰。
// ponytail: ROM 不压缩写入,程序区约 4 MB 要一两分钟;嫌慢再换 FLASH_DEFL 压缩写。

public struct FirmwareImage: Sendable {
    public let name: String
    public let offset: UInt32
    public let data: Data
}

/// App 自带的一套固件(make-app.sh 从 firmware/build 拷进 Resources/Firmware)。
public struct FirmwareBundle: Sendable {
    /// 偏移来自 firmware/partitions.csv;上限是下一个分区的起点,整扇区擦除也不越界。
    static let slots: [(name: String, offset: UInt32, limit: UInt32)] = [
        ("bootloader.bin", 0x0, 0x8000),
        ("partition-table.bin", 0x8000, 0x9000),  // 0x9000 起是 nvs:Wi-Fi、蓝牙配对、网盘绑定
        ("yahadesk.bin", 0x10000, 0x410000),      // 0x410000 起是 fac:出厂身份
    ]
    public let images: [FirmwareImage]
    public let version: String

    public init(directory: URL) throws {
        var files: [String: Data] = [:]
        for slot in Self.slots {
            files[slot.name] = try? Data(contentsOf: directory.appendingPathComponent(slot.name))
        }
        try self.init(files: files)
    }

    init(files: [String: Data]) throws {
        images = try Self.slots.map { slot in
            guard let data = files[slot.name], !data.isEmpty else { throw DeskProtocolError("固件包缺 \(slot.name)") }
            let end = UInt64(slot.offset) + (UInt64(data.count) + 0xFFF) / 0x1000 * 0x1000
            guard end <= slot.limit else { throw DeskProtocolError("\(slot.name) 超出分区，已放弃安装") }
            let bytes = [UInt8](data.prefix(16))
            let valid = slot.name == "partition-table.bin"
                ? bytes.starts(with: [0xAA, 0x50])
                : bytes.count == 16 && bytes[0] == 0xE9 && bytes[12] == 9 && bytes[13] == 0  // 9 = ESP32-S3
            guard valid else { throw DeskProtocolError("\(slot.name) 不是 ESP32-S3 固件") }
            return FirmwareImage(name: slot.name, offset: slot.offset, data: data)
        }
        // esp_app_desc_t 紧跟镜像头与首段头(32 字节):magic 0xABCD5432,版本在 +16,32 字节。
        let app = [UInt8](images[2].data.prefix(80))
        guard app.count == 80, Array(app[32..<36]) == [0x32, 0x54, 0xCD, 0xAB] else {
            throw DeskProtocolError("yahadesk.bin 缺少版本信息")
        }
        version = String(decoding: app[48..<80].prefix { $0 != 0 }, as: UTF8.self)
    }
}

/// 串口抽象:真机是 SerialFlashPort,测试用假 ROM。
public protocol FlashPort: AnyObject {
    func write(_ data: Data) throws
    /// 等最多 timeout 秒,返回已到的字节;超时返回空。
    func read(timeout: TimeInterval) throws -> [UInt8]
    func setDTR(_ on: Bool) throws
    func setRTS(_ on: Bool) throws
    /// USB 设备复位时可能掉线重枚举,重新打开同一路径。
    func reopen() throws
}

enum EspRom {
    static let flashBegin: UInt8 = 0x02, flashData: UInt8 = 0x03, sync: UInt8 = 0x08
    static let writeReg: UInt8 = 0x09, readReg: UInt8 = 0x0A, spiSetParams: UInt8 = 0x0B
    static let spiAttach: UInt8 = 0x0D, readFlashSlow: UInt8 = 0x0E, md5: UInt8 = 0x13
    static let blockSize = 0x400

    static func slip(_ d: Data) -> Data {
        var out = Data([0xC0])
        for b in d {
            switch b {
            case 0xC0: out += [0xDB, 0xDC]
            case 0xDB: out += [0xDB, 0xDD]
            default: out.append(b)
            }
        }
        out.append(0xC0)
        return out
    }

    /// 请求:0x00 ‖ op ‖ len u16 ‖ checksum u32 ‖ body,小端。
    static func packet(_ op: UInt8, _ body: Data, checksum: UInt32 = 0) -> Data {
        var d = Data([0, op])
        d += le(UInt16(body.count))
        d += le(checksum)
        return d + body
    }

    static func checksum(_ d: Data) -> UInt32 { UInt32(d.reduce(UInt8(0xEF)) { $0 ^ $1 }) }

    static func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    static func words(_ v: UInt32...) -> Data { v.reduce(into: Data()) { $0 += le($1) } }
}

/// SLIP 帧拆分:首个 0xC0 之前的字节(设备日志)丢弃。
struct SlipReader {
    private var frame: [UInt8]?
    private var escaped = false

    mutating func push(_ b: UInt8) -> [UInt8]? {
        if b == 0xC0 {
            defer { frame = []; escaped = false }
            if let f = frame, !f.isEmpty { return f }
            return nil
        }
        guard frame != nil else { return nil }
        if escaped {
            frame!.append(b == 0xDC ? 0xC0 : b == 0xDD ? 0xDB : b)
            escaped = false
        } else if b == 0xDB {
            escaped = true
        } else {
            frame!.append(b)
        }
        return nil
    }
}

/// 设备上跑的是别的项目的固件(比如同为 ESP32-S3 的 yahamic):需要用户确认后再覆盖。
public struct ForeignFirmwareError: LocalizedError {
    public let project: String
    public var errorDescription: String? { "这台设备上是「\(project)」固件，不是 Yaha Desk" }
}

/// 一次安装:复位进下载模式 → 同步 → 关看门狗 → 逐段比对 MD5,不同才擦写并校验 → 复位运行。
/// 阻塞调用,放后台线程跑。
public final class EspFlasher {
    private let port: FlashPort
    private var reader = SlipReader()
    private var pending: ArraySlice<UInt8> = []  // 切片 removeFirst 是 O(1)

    public init(port: FlashPort) { self.port = port }

    /// progress:0...1,按要写入的字节计。返回与设备不同(已写入)的段名;空表示设备上已是这套固件。
    /// dryRun 只比对不写,设备照样复位一次。allowForeign 为 false 时遇到别的项目固件抛 ForeignFirmwareError。
    @discardableResult
    public func install(_ bundle: FirmwareBundle, dryRun: Bool = false, allowForeign: Bool = false,
                        progress: (Double) -> Void = { _ in }) throws -> [String] {
        defer { try? runApp() }  // 连不上或中途失败也让设备回到原程序(写坏的段下次重装)
        try connect()
        // ROM 固定地址的芯片识别值:ESP32-S3 是 9(esptool CHIP_DETECT_MAGIC_VALUE)。
        guard try command(EspRom.readReg, EspRom.words(0x4000_1000)).value == 9 else {
            throw DeskProtocolError("连接的不是 ESP32-S3 设备")
        }
        try disableWatchdogs()
        try command(EspRom.spiAttach, Data(count: 8))
        try command(EspRom.spiSetParams, EspRom.words(0, 16 << 20, 0x10000, 0x1000, 0x100, 0xFFFF))  // 16 MB flash
        // 程序区 esp_app_desc 的项目名(+80):空板全是 0xFF。ROM 读 flash 总回 64 字节。
        let name = try command(EspRom.readFlashSlow, EspRom.words(0x10050, 32), responseBytes: 64).data.prefix(32)
        if !allowForeign, name.first != 0xFF {
            let project = String(decoding: name.prefix { $0 != 0 }, as: UTF8.self)
            if project != "yahadesk" { throw ForeignFirmwareError(project: project.isEmpty ? "未知" : project) }
        }

        let stale = try bundle.images.filter { try flashMD5($0.offset, $0.data.count) != md5($0.data) }
        let total = Double(stale.reduce(0) { $0 + $1.data.count })
        var done = 0
        for image in stale where !dryRun {
            try write(image) { done += $0; progress(Double(done) / total) }
            guard try flashMD5(image.offset, image.data.count) == md5(image.data) else {
                throw DeskProtocolError("\(image.name) 写入后校验不一致，请重试")
            }
        }
        return stale.map(\.name)
    }

    // MARK: 步骤

    private func connect() throws {
        for attempt in 0..<3 {
            do {
                if attempt > 0 { try port.reopen() }
                try enterDownloadMode()
                for _ in 0..<5 {
                    let body = Data([0x07, 0x07, 0x12, 0x20]) + Data(repeating: 0x55, count: 32)
                    if (try? command(EspRom.sync, body, timeout: 0.1)) != nil { return }  // 多回的 7 遍按 op 过滤
                }
            } catch {}
        }
        throw DeskProtocolError("设备没有进入下载模式：先关掉占用串口的程序（如 idf.py monitor）；仍不行就按住 BOOT 键再按一下 RESET，然后重试")
    }

    /// USB-Serial-JTAG 的复位时序(esptool usb_jtag_bootloader_reset;true = 拉低):DTR 拉 IO0、RTS 复位。
    private func enterDownloadMode() throws {
        try port.setRTS(false); try port.setDTR(false)
        Thread.sleep(forTimeInterval: 0.1)
        try port.setDTR(true); try port.setRTS(false)
        Thread.sleep(forTimeInterval: 0.1)
        try port.setRTS(true); try port.setDTR(false); try port.setRTS(true)
        Thread.sleep(forTimeInterval: 0.1)
        try port.setDTR(false); try port.setRTS(false)
        Thread.sleep(forTimeInterval: 0.1)
    }

    /// 经 USB 下载时 RTC 看门狗没人喂,写 4 MB 途中会把芯片复位(同 esptool disable_watchdogs)。
    private func disableWatchdogs() throws {
        let wdtProtect: UInt32 = 0x6000_80B0, wdtConfig0: UInt32 = 0x6000_8098
        let swdProtect: UInt32 = 0x6000_80B8, swdConf: UInt32 = 0x6000_80B4
        try writeReg(wdtProtect, 0x50D8_3AA1)
        try writeReg(wdtConfig0, 0)
        try writeReg(wdtProtect, 0)
        try writeReg(swdProtect, 0x8F1D_312A)
        try writeReg(swdConf, try readReg(swdConf) | 1 << 31)  // SWD 自动喂狗
        try writeReg(swdProtect, 0)
    }

    private func write(_ image: FirmwareImage, sent: (Int) -> Void) throws {
        let blocks = (image.data.count + EspRom.blockSize - 1) / EspRom.blockSize
        let mb = Double(image.data.count) / 1_048_576
        // ROM 在 FLASH_BEGIN 里按扇区整段擦除:超时按 esptool 的每 MB 40 秒。
        try command(EspRom.flashBegin,
                    EspRom.words(UInt32(image.data.count), UInt32(blocks), UInt32(EspRom.blockSize), image.offset, 0),
                    timeout: max(3, 40 * mb))
        for seq in 0..<blocks {
            var block = image.data.subdata(in: seq * EspRom.blockSize..<min((seq + 1) * EspRom.blockSize, image.data.count))
            let size = block.count
            block += Data(repeating: 0xFF, count: EspRom.blockSize - size)  // 末块补 0xFF,落在已擦除的扇区内
            let body = EspRom.words(UInt32(block.count), UInt32(seq), 0, 0) + block
            for attempt in 1...3 {
                do { try command(EspRom.flashData, body, checksum: EspRom.checksum(block)); break } catch {
                    if attempt == 3 { throw error }
                }
            }
            sent(size)
        }
    }

    /// 清掉「强制下载模式」位,再拉 RTS 复位,设备从新程序启动(esptool hard_reset)。
    private func runApp() throws {
        let option1: UInt32 = 0x6000_812C
        if let v = try? readReg(option1) { try? writeReg(option1, v & ~1) }
        try port.setRTS(true)
        Thread.sleep(forTimeInterval: 0.2)
        try port.setRTS(false)
        Thread.sleep(forTimeInterval: 0.2)
    }

    // MARK: 协议

    private func readReg(_ addr: UInt32) throws -> UInt32 { try command(EspRom.readReg, EspRom.words(addr)).value }

    private func writeReg(_ addr: UInt32, _ value: UInt32) throws {
        try command(EspRom.writeReg, EspRom.words(addr, value, 0xFFFF_FFFF, 0))
    }

    /// ROM 回 32 字节十六进制文本。
    private func flashMD5(_ offset: UInt32, _ size: Int) throws -> String {
        let r = try command(EspRom.md5, EspRom.words(offset, UInt32(size), 0, 0), responseBytes: 32,
                            timeout: max(3, 8 * Double(size) / 1_048_576))
        return String(decoding: r.data, as: UTF8.self).lowercased()
    }

    private func md5(_ d: Data) -> String { Insecure.MD5.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    /// 回应:0x01 ‖ op ‖ len u16 ‖ value u32 ‖ data ‖ 状态(首字节非 0 为失败,次字节是原因)。
    @discardableResult
    private func command(_ op: UInt8, _ body: Data, checksum: UInt32 = 0, responseBytes: Int = 0,
                         timeout: TimeInterval = 3) throws -> (value: UInt32, data: Data) {
        try port.write(EspRom.slip(EspRom.packet(op, body, checksum: checksum)))
        let deadline = Date().addingTimeInterval(timeout)
        while let f = try nextFrame(before: deadline) {
            guard f.count >= 8, f[0] == 1, f[1] == op else { continue }
            let data = Array(f[8...])
            guard data.count >= responseBytes + 2 else { throw DeskProtocolError("设备回应不完整") }
            guard data[responseBytes] == 0 else {
                throw DeskProtocolError(String(format: "设备拒绝了命令 0x%02X(原因 0x%02X)", op, data[responseBytes + 1]))
            }
            let value = UInt32(f[4]) | UInt32(f[5]) << 8 | UInt32(f[6]) << 16 | UInt32(f[7]) << 24
            return (value, Data(data[..<responseBytes]))
        }
        throw DeskProtocolError(String(format: "设备没有回应命令 0x%02X", op))
    }

    private func nextFrame(before deadline: Date) throws -> [UInt8]? {
        while true {
            while !pending.isEmpty {
                if let f = reader.push(pending.removeFirst()) { return f }
            }
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return nil }
            pending = try port.read(timeout: left)[...]
        }
    }
}
