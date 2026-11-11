import Foundation

// 协议 v3:BLE GATT,规范见 README「协议 v3」,固件侧是 firmware/main/uplink.cpp。
// 这里只有纯逻辑(UUID、audio 分片重组、写入载荷编码),CoreBluetooth 在 DeskCore。
public enum Wire {
    public static let version: UInt8 = 3

    /// 128 位 UUID 9052000N-395E-4621-8E8C-82039EE589FC(N = 1 service,2–7 特征)。
    private static func uuid(_ n: Int) -> String { String(format: "9052%04X-395E-4621-8E8C-82039EE589FC", n) }
    public static let service = uuid(1)
    public static let info = uuid(2)        // read:Fields 行,fw/rate/frame/codec
    public static let audio = uuid(3)       // notify:seq u16 LE ‖ frag u8 ‖ Opus 分片
    public static let status = uuid(4)      // read + notify:muted u8
    public static let control = uuid(5)     // write:0x01 muted u8 / 0x02 屏幕回传
    public static let dashboard = uuid(6)   // write without response:10 字节
    public static let card = uuid(7)        // write:ttl u16 LE ‖ title ‖ 0x00 ‖ body,≤ 512 字节
    public static let provision = uuid(8)   // write:Wi-Fi / 设备授权 JSON,≤512 字节
    public static let cloudState = uuid(9)  // read + notify:无凭据的设备云端状态 JSON
    public static let networks = uuid(10)   // read:设备最近一次 Wi-Fi 扫描结果 JSON,≤512 字节
    public static let identity = uuid(11)   // read:出厂证书 DER,≤512 字节;无出厂身份为空

    public static func muteCommand(_ muted: Bool) -> Data { Data([0x01, muted ? 1 : 0]) }
    public static let dumpCommand = Data([0x02])

    /// dashboard:epoch u32(UTC 秒)‖ 时区偏移 i16(分钟)‖ cpu/mem/鼠标/键盘电量 u8(无效 255),小端。
    public static func dashboard(epoch: UInt32, tzMinutes: Int16, cpu: UInt8, mem: UInt8,
                                 mouse: UInt8, keyboard: UInt8) -> Data {
        var d = Data()
        withUnsafeBytes(of: epoch.littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: tzMinutes.littleEndian) { d.append(contentsOf: $0) }
        d.append(contentsOf: [cpu, mem, mouse, keyboard])
        return d
    }

    public static func dashboard(epoch: UInt32, tzMinutes: Int16, cpu: UInt8, mem: UInt8,
                                 mouse: UInt8, keyboard: UInt8, macBattery: UInt8, macPower: UInt8) -> Data {
        var data = dashboard(epoch: epoch, tzMinutes: tzMinutes, cpu: cpu, mem: mem, mouse: mouse, keyboard: keyboard)
        data.append(contentsOf: [macBattery, macPower])
        return data
    }

    /// ATT 属性值上限:card 整包不超过这么多字节(固件 kCardMax)。
    public static let cardMax = 512

    /// card:ttl u16 LE(秒,0 = 清除)‖ title UTF-8 ‖ 0x00 ‖ body UTF-8。
    /// 超长时先截正文、再截标题,都按字符边界截断,不会切出半个 UTF-8 字符;标题里的 NUL 去掉。
    public static func card(ttl: UInt16, title: String, body: String) -> Data {
        var d = Data()
        withUnsafeBytes(of: ttl.littleEndian) { d.append(contentsOf: $0) }
        guard ttl > 0 else { return d }
        let t = prefix(title.replacingOccurrences(of: "\0", with: ""), bytes: cardMax - 3)
        d.append(t)
        d.append(0)
        d.append(prefix(body, bytes: cardMax - d.count))
        return d
    }

    private static func prefix(_ s: String, bytes limit: Int) -> Data {
        var out = Data()
        for ch in s {
            let u = Data(String(ch).utf8)
            if out.count + u.count > limit { break }
            out.append(u)
        }
        return out
    }
}

/// audio notify 的分片重组:按 seq 收片,末片(frag bit7)出整帧。
/// notify 在链路层可靠有序,残帧只来自设备发送队列满时丢掉的余下分片;
/// seq 跳号(含残帧)计为丢帧,不补静音。
public struct FrameAssembler {
    public struct Frame: Equatable {
        public let seq: UInt16
        public let gap: Int     // 与上一完整帧之间缺了几帧
        public let opus: Data
    }

    private var seq: UInt16?
    private var nextFrag: UInt8 = 0
    private var buffer = Data()
    private var lastComplete: UInt16?
    /// 解析失败或分片不连续而扔掉的通知数(诊断用)。
    public private(set) var invalid = 0

    public init() {}

    public mutating func reset() {
        seq = nil
        buffer.removeAll()
        lastComplete = nil
    }

    public mutating func push(_ packet: Data) -> Frame? {
        let b = [UInt8](packet)
        guard b.count > 3 else {
            invalid += 1
            return nil
        }
        let s = UInt16(b[0]) | UInt16(b[1]) << 8
        let frag = b[2] & 0x7f
        if s != seq {
            seq = s
            nextFrag = 0
            buffer.removeAll(keepingCapacity: true)
        }
        guard frag == nextFrag else {  // 中间片丢了:这帧作废,等下一个 seq
            invalid += 1
            nextFrag = 0x80  // 不会再匹配,直到 seq 变化
            return nil
        }
        nextFrag += 1
        buffer.append(contentsOf: b[3...])
        guard b[2] & 0x80 != 0 else { return nil }
        let gap = lastComplete.map { max(0, Int(s &- $0) - 1) } ?? 0
        lastComplete = s
        nextFrag = 0x80
        return Frame(seq: s, gap: gap, opus: buffer)
    }
}
