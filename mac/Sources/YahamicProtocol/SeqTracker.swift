/// 接收侧序号判定(每个方向一个,会话内所有加密包共用):只收严格递增的序号,
/// 同时承担去重、丢迟到帧(xiaozhi 做法:丢旧不补静)和防重放。
/// 大跳变(>1000)当新基线接受:设备长时间静音后序号可能远超基线,
/// 旧实现在这里只丢不更新基线,导致之后的帧永远被丢(长静音零帧)。
public struct SeqTracker {
    public enum Verdict: Equatable {
        case accept(gap: Int)   // 正常;gap = 中间缺了几个序号(丢包)
        case rebase             // 大跳变,接受并以此为新基线
        case duplicate          // 同号重发
        case late               // 比基线旧:乱序迟到或重放

        public var accepted: Bool {
            switch self {
            case .accept, .rebase: return true
            case .duplicate, .late: return false
            }
        }
    }

    public static let rebaseDistance: Int32 = 1000
    public private(set) var last: UInt32?

    public init() {}

    public mutating func reset() { last = nil }

    public mutating func classify(_ seq: UInt32) -> Verdict {
        guard let last else {
            self.last = seq
            return .accept(gap: 0)
        }
        let dist = Int32(bitPattern: seq &- last)
        if dist == 0 { return .duplicate }
        if dist < 0 { return .late }
        self.last = seq
        return dist > Self.rebaseDistance ? .rebase : .accept(gap: Int(dist - 1))
    }
}
