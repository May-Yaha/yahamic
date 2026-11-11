import Foundation

/// 文本载荷:每行 "key value",key 只按行首整词匹配,同名取第一行。
public enum Fields {
    public static func parse(_ payload: Data) -> [String: String] {
        var out: [String: String] = [:]
        for line in String(decoding: payload, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, out[String(parts[0])] == nil else { continue }
            out[String(parts[0])] = String(parts[1])
        }
        return out
    }

    public static func build(_ pairs: [(String, String)]) -> Data {
        Data(pairs.map { "\($0.0) \($0.1)\n" }.joined().utf8)
    }
}

extension Data {
    public var hex: String { map { String(format: "%02x", $0) }.joined() }

    /// 小写或大写十六进制;长度为奇数或含非法字符返回 nil。
    public init?(hex: String) {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(decoding: chars[i...i + 1], as: UTF8.self), radix: 16)
            else { return nil }
            bytes.append(byte)
        }
        self.init(bytes)
    }
}
