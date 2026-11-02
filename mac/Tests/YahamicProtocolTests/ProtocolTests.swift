import CryptoKit
import Foundation
import Testing
@testable import YahamicProtocol

// 测试向量来自 firmware/tools/protocol_vectors.py,固件自检用同一组。
private let dn = Data(0..<16)
private let mn = Data(16..<32)
private let key = SessionCrypto.masterKey(code: "ABCD2345EF")

private func raw(_ k: SymmetricKey) -> String { k.withUnsafeBytes { Data($0).hex } }

@Test func masterKeyMatchesVector() {
    #expect(raw(key) == "b32f3dc50c7781c64ab18cb867e5e2ef1c7baba7dd39b0be26b6e7d7c3e163b8")
}

@Test func proofsMatchVectors() {
    #expect(SessionCrypto.mac(key, "m", dn: dn, mn: mn).hex
            == "cd546160d89ed512d86fffe38651d8ada4613fc242f6162102b1539a20b7f765")
    let proofD = Data(hex: "df5da4ad5311fe3bfd8288832dee79c5767d946abd766cd15443138cc119c56a")!
    #expect(SessionCrypto.verify(key, "d", dn: dn, mn: mn, proof: proofD))
    #expect(!SessionCrypto.verify(key, "m", dn: dn, mn: mn, proof: proofD))
    let wrong = SessionCrypto.masterKey(code: "ABCD2345EG")
    #expect(!SessionCrypto.verify(wrong, "d", dn: dn, mn: mn, proof: proofD))
}

@Test func sessionKeysAndSealMatchVectors() {
    let s = SessionCrypto.Session(macSideWith: key, dn: dn, mn: mn)
    #expect(raw(s.receive) == "e2587735c2e86fb5262cc3c7e4c6b76a8026062024831351631bdf26f341c9f6")
    #expect(raw(s.send) == "c522b3048f624d8ee1b1c7ff411cf8afcbaa2c1fb145fb1078dc5b6b137f3ebe")

    let header = Wire.header(type: Wire.audio, seq: 5, ts: 300)
    #expect(header.hex == "59020300050000002c010000")
    let sealed = Data(hex: "adf6bc7da3c0f86bd0d74ae194acbb5ed7a76925")!
    #expect(s.open(header: header, seq: 5, sealed: sealed) == Data("opus".utf8))

    // 设备侧视角(收发互换)封出同样的密文。
    let device = SessionCrypto.Session(send: s.receive, receive: s.send)
    #expect(device.seal(header: header, seq: 5, plaintext: Data("opus".utf8)) == sealed)

    // 篡改头部 / 换序号 / 改密文都必须验不过。
    let otherHeader = Wire.header(type: Wire.audio, flags: 1, seq: 5, ts: 300)
    #expect(s.open(header: otherHeader, seq: 5, sealed: sealed) == nil)
    #expect(s.open(header: header, seq: 6, sealed: sealed) == nil)
    var flipped = sealed
    flipped[0] ^= 1
    #expect(s.open(header: header, seq: 5, sealed: flipped) == nil)
    #expect(s.open(header: header, seq: 5, sealed: Data(count: 4)) == nil)
}

@Test func wireRoundTripIsLittleEndian() {
    let data = Wire.build(type: Wire.keepalive, flags: 1, seq: 0x0102_0304, ts: 0xA0B0_C0D0,
                          payload: Data("muted 1\n".utf8))
    #expect(data.prefix(12).hex == "59020501" + "04030201" + "d0c0b0a0")
    let p = Wire.parse(data)!
    #expect(p.type == Wire.keepalive && p.flags == 1 && p.seq == 0x0102_0304 && p.ts == 0xA0B0_C0D0)
    #expect(p.payload == Data("muted 1\n".utf8))
    #expect(Wire.parse(Data([0x59, 1, 5, 0] + [UInt8](repeating: 0, count: 8))) == nil)  // v1 拒收
    #expect(Wire.parse(Data([0x59, 2, 5])) == nil)
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

@Test func seqTrackerClassifies() {
    var t = SeqTracker()
    #expect(t.classify(10) == .accept(gap: 0))
    #expect(t.classify(11) == .accept(gap: 0))
    #expect(t.classify(11) == .duplicate)
    #expect(t.classify(9) == .late)
    #expect(t.classify(14) == .accept(gap: 2))
    #expect(t.classify(UInt32.max) == .late)  // 回绕方向的"旧帧"
}

/// 回归:长静音后设备序号远超基线(静音期 status/keepalive 照样消耗序号),
/// 旧实现 dist>1000 只丢不更新基线 → 之后每帧都被丢,永久零帧。
@Test func seqTrackerRebasesAfterLongMute() {
    var t = SeqTracker()
    _ = t.classify(100)
    let afterMute: UInt32 = 100 + 1000 * 17  // 17 分钟每秒一个心跳
    #expect(t.classify(afterMute) == .rebase)
    #expect(t.classify(afterMute + 1) == .accept(gap: 0))
    #expect(t.classify(afterMute + 2).accepted)
}
