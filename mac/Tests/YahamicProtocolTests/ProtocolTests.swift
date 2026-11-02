import Foundation
import Testing
@testable import YahamicProtocol
@testable import YahamicCore

private func packet(_ seq: UInt16, _ frag: UInt8, last: Bool, _ body: [UInt8]) -> Data {
    Data([UInt8(seq & 0xff), UInt8(seq >> 8), frag | (last ? 0x80 : 0)] + body)
}

@Test func uuidsMatchFirmware() {
    #expect(Wire.service == "6B960001-2D78-4CE2-963A-884ED7A5150C")
    #expect(Wire.dashboard == "6B960006-2D78-4CE2-963A-884ED7A5150C")
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
    let f = Fields.parse(Data("xmuted 0\nmuted 1\nmuted 0\nname yahamic-ab cd\n".utf8))
    #expect(f["muted"] == "1")
    #expect(f["xmuted"] == "0")
    #expect(f["name"] == "yahamic-ab cd")
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
