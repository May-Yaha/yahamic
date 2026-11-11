import Foundation
import Testing
@testable import DeskProtocol
@testable import DeskCore

private func packet(_ seq: UInt16, _ frag: UInt8, last: Bool, _ body: [UInt8]) -> Data {
    Data([UInt8(seq & 0xff), UInt8(seq >> 8), frag | (last ? 0x80 : 0)] + body)
}

@Test func uuidsMatchFirmware() {
    #expect(Wire.service == "90520001-395E-4621-8E8C-82039EE589FC")
    #expect(Wire.dashboard == "90520006-395E-4621-8E8C-82039EE589FC")
    #expect(Wire.card == "90520007-395E-4621-8E8C-82039EE589FC")
}

@Test func assemblerJoinsFragments() {
    var a = FrameAssembler()
    #expect(a.push(packet(7, 0, last: false, [1, 2])) == nil)
    #expect(a.push(packet(7, 1, last: true, [3])) == .init(seq: 7, gap: 0, opus: Data([1, 2, 3])))
    #expect(a.push(packet(8, 0, last: true, [4])) == .init(seq: 8, gap: 0, opus: Data([4])))
    #expect(a.invalid == 0)
}

@Test func assemblerDropsBrokenFrameAndCountsGap() {
    var a = FrameAssembler()
    _ = a.push(packet(1, 0, last: true, [1]))
    // seq 2 末片丢了、seq 3 中间片丢了:两帧都不出,seq 4 记缺口 2。
    #expect(a.push(packet(2, 0, last: false, [2])) == nil)
    #expect(a.push(packet(3, 1, last: true, [3])) == nil)
    #expect(a.push(packet(4, 0, last: true, [4])) == .init(seq: 4, gap: 2, opus: Data([4])))
    #expect(a.invalid == 1)
    #expect(a.push(Data([4, 0, 0x80])) == nil)  // 无负载
    #expect(a.invalid == 2)
}

@Test func assemblerHandlesSeqWrapAndReset() {
    var a = FrameAssembler()
    _ = a.push(packet(0xffff, 0, last: true, [1]))
    #expect(a.push(packet(0, 0, last: true, [2]))?.gap == 0)
    a.reset()
    #expect(a.push(packet(500, 0, last: true, [3]))?.gap == 0)  // 重连后不算跳号
}

@Test func writePayloads() {
    #expect(Wire.muteCommand(true) == Data([1, 1]))
    #expect(Wire.muteCommand(false) == Data([1, 0]))
    #expect(Wire.dumpCommand == Data([2]))
    let d = Wire.dashboard(epoch: 0x01020304, tzMinutes: 480, cpu: 12, mem: 34, mouse: 255, keyboard: 90)
    #expect(d.hex == "04030201e0010c22ff5a")
}

@Test func fieldsMatchWholeKeysAtLineStart() {
    let f = Fields.parse(Data("xmuted 0\nmuted 1\nmuted 0\nname yahadesk-ab cd\n".utf8))
    #expect(f["muted"] == "1")
    #expect(f["xmuted"] == "0")
    #expect(f["name"] == "yahadesk-ab cd")
    #expect(Data(hex: "0aFF") == Data([0x0a, 0xff]))
    #expect(Data(hex: "abc") == nil)
    #expect(Data(hex: "zz") == nil)
}

@Test func batteryNamesClassify() {
    #expect(MetricsCollector.classify("Yaha-Mouse") == (true, false))
    #expect(MetricsCollector.classify("Yaha的Magic Mouse").mouse)
    #expect(MetricsCollector.classify("Magic Keyboard with Touch ID") == (false, true))
    #expect(MetricsCollector.classify("Yaha-HHKB").keyboard)
    #expect(MetricsCollector.classify("Apple Internal Keyboard / Trackpad") == (true, false))
    #expect(MetricsCollector.classify("Headset") == (false, false))
}

@Test func cardPayloadLayoutAndTruncation() {
    #expect(Wire.card(ttl: 0, title: "x", body: "y") == Data([0, 0]))
    #expect(Wire.card(ttl: 0x0102, title: "A", body: "日报").hex == "020141" + "00" + "e697a5e68aa5")
    // 正文全是 3 字节汉字:截到 512 字节以内,且不切半个字符。
    let long = Wire.card(ttl: 60, title: "标题", body: String(repeating: "字", count: 400))
    #expect(long.count <= Wire.cardMax)
    #expect((long.count - 2 - 6 - 1) % 3 == 0)
    #expect(String(data: long[9...], encoding: .utf8) != nil)
    // 标题超长:按 4 字节字符截到 508,NUL 分隔符仍在,正文用剩下的 1 字节。
    let t = Wire.card(ttl: 60, title: String(repeating: "😀", count: 200), body: "bc")
    #expect(t.count == Wire.cardMax && t[2 + 508] == 0 && t.last == UInt8(ascii: "b"))
    #expect(Wire.card(ttl: 1, title: "a\0b", body: "").hex == "0100" + "6162" + "00")
}

@Test func phoneFragmentsRoundTripThroughAssembler() {
    #expect(Wire.phoneService == "9052000C-395E-4621-8E8C-82039EE589FC")
    let opus = Data((0..<200).map { UInt8($0 & 0xff) })
    let parts = Wire.fragments(seq: 0xFFFF, opus: opus, chunk: 17)  // 最小 MTU 23 − 6
    #expect(parts.count == 12)
    #expect(parts.dropLast().allSatisfy { $0.count == 20 && $0[2] & 0x80 == 0 })
    var a = FrameAssembler()
    _ = a.push(packet(0xFFFE, 0, last: true, [9]))
    var frame: FrameAssembler.Frame?
    for p in parts { frame = a.push(p) }
    #expect(frame == .init(seq: 0xFFFF, gap: 0, opus: opus))  // seq 回绕不算缺口
    #expect(Wire.fragments(seq: 1, opus: Data(count: 129), chunk: 1).isEmpty)  // 超过 128 片不发
    #expect(Wire.fragments(seq: 1, opus: Data(), chunk: 17).isEmpty)
}
