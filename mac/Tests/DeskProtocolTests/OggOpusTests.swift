import Foundation
import Testing
@testable import DeskProtocol

@Test func oggCrcMatchesReferenceVector() {
    // CRC-32/POSIX "123456789" = 0x765E7680 before its final xor; Ogg has no xor.
    #expect(OggOpusWriter.crc(Data("123456789".utf8)) == 0x89A1_897F)
}

@Test func oggOpusPagesCarryHeadersGranuleAndEOS() {
    var w = OggOpusWriter(serial: 7)
    for _ in 0..<3 { w.append(Data(repeating: 0x58, count: 240), samples: 960) }
    w.append(Data(repeating: 1, count: 255), samples: 960)  // exact multiple of 255 needs a trailing 0 lace
    let file = w.finish()
    #expect(w.samples48k == 4 * 2880)

    var pages: [(flags: UInt8, granule: UInt64, seq: UInt32, body: Data)] = []
    var at = file.startIndex
    while at < file.endIndex {
        let h = file[at...]
        #expect(h.prefix(4) == Data("OggS".utf8))
        func int<T: FixedWidthInteger>(_ o: Int, _: T.Type) -> T {
            file[(at + o)..<(at + o + MemoryLayout<T>.size)].reversed().reduce(T(0)) { $0 << 8 | T($1) }
        }
        let segments = Int(file[at + 26])
        let lacing = file[(at + 27)..<(at + 27 + segments)]
        let size = lacing.reduce(0) { $0 + Int($1) }
        let end = at + 27 + segments + size
        var zeroed = Data(file[at..<end])
        zeroed.replaceSubrange(22..<26, with: [0, 0, 0, 0])
        #expect(OggOpusWriter.crc(zeroed) == int(22, UInt32.self))
        #expect(int(14, UInt32.self) == 7)
        pages.append((file[at + 5], int(6, UInt64.self), int(18, UInt32.self), Data(file[(end - size)..<end])))
        at = end
    }
    #expect(pages.count == 6)
    #expect(pages.map(\.seq) == [0, 1, 2, 3, 4, 5])
    #expect(pages.map(\.flags) == [0x02, 0, 0, 0, 0, 0x04])
    #expect(pages.map(\.granule) == [0, 0, 2880, 5760, 8640, 11520])
    #expect(pages[0].body.prefix(8) == Data("OpusHead".utf8))
    #expect(pages[1].body.prefix(8) == Data("OpusTags".utf8))
    #expect(pages[5].body.count == 255)
}
