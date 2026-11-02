import Foundation

// 协议 v3:BLE GATT,规范见 README「协议 v3」,固件侧是 firmware/main/uplink.cpp。
// 这里只有纯逻辑(UUID、audio 分片重组、写入载荷编码),CoreBluetooth 在 YahamicCore。
public enum Wire {
    public static let version: UInt8 = 3

    /// 128 位 UUID 6B96000N-2D78-4CE2-963A-884ED7A5150C(N = 1 service,2–6 特征)。
    private static func uuid(_ n: Int) -> String { String(format: "6B96%04X-2D78-4CE2-963A-884ED7A5150C", n) }
    public static let service = uuid(1)
    public static let info = uuid(2)        // read:Fields 行,fw/rate/frame/codec
    public static let audio = uuid(3)       // notify:seq u16 LE ‖ frag u8 ‖ Opus 分片
    public static let status = uuid(4)      // read + notify:muted u8
    public static let control = uuid(5)     // write:0x01 muted u8 / 0x02 屏幕回传
    public static let dashboard = uuid(6)   // write without response:10 字节

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
