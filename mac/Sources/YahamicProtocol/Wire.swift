import Foundation

// 报文编解码:12 字节小端头 + 载荷,详见 README「协议」。
// v2:握手包(hello/welcome/auth)明文;其余类型载荷经 SessionCrypto 封装,头部作 AAD。
public enum Wire {
    public static let version: UInt8 = 2
    public static let headerSize = 12

    public static let hello: UInt8 = 1
    public static let welcome: UInt8 = 2
    public static let audio: UInt8 = 3
    public static let status: UInt8 = 4
    public static let keepalive: UInt8 = 5
    public static let control: UInt8 = 6
    public static let dashboard: UInt8 = 7
    public static let auth: UInt8 = 8

    /// 上线后才收发、载荷必须加密的类型。
    public static func isSealed(_ type: UInt8) -> Bool { (audio...dashboard).contains(type) }

    public struct Packet: Equatable {
        public let type: UInt8
        public let flags: UInt8
        public let seq: UInt32
        public let ts: UInt32
        public let header: Data   // 原始 12 字节头(AEAD 的附加数据)
        public let payload: Data
    }

    public static func parse(_ data: Data) -> Packet? {
        let b = [UInt8](data)
        guard b.count >= headerSize, b[0] == 0x59, b[1] == version else { return nil }
        func u32(_ i: Int) -> UInt32 {
            UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
        }
        return Packet(type: b[2], flags: b[3], seq: u32(4), ts: u32(8),
                      header: Data(b[0..<headerSize]), payload: Data(b[headerSize...]))
    }

    public static func header(type: UInt8, flags: UInt8 = 0, seq: UInt32, ts: UInt32) -> Data {
        var data = Data([0x59, version, type, flags])
        for v in [seq, ts] {
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    public static func build(type: UInt8, flags: UInt8 = 0, seq: UInt32, ts: UInt32,
                             payload: Data = Data()) -> Data {
        header(type: type, flags: flags, seq: seq, ts: ts) + payload
    }
}
