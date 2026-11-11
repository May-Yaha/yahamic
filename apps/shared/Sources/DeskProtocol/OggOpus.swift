import Foundation

/// Wraps the device's Opus packets (16 kHz mono) into an Ogg Opus file (RFC 7845) without re-encoding.
/// One packet per page: device packets are ~240 B, so a page never needs more than one lacing run.
public struct OggOpusWriter {
    public static let preSkip = 312  // libopus encoder lookahead, in 48 kHz samples
    private var pages = Data()
    private var granule: UInt64 = 0
    private var sequence: UInt32 = 0
    private var pending: (packet: Data, samples: Int)?
    private let serial: UInt32
    public private(set) var samples48k = 0  // everything appended, the last packet included

    public init(serial: UInt32 = .random(in: 0 ... .max)) {
        self.serial = serial
        var head = Data("OpusHead".utf8)
        head.append(contentsOf: [1, 1])  // version, channels
        head.append(le: UInt16(Self.preSkip))
        head.append(le: UInt32(16000))
        head.append(contentsOf: [0, 0, 0])  // output gain, mapping family
        page(head, flags: 0x02)
        var tags = Data("OpusTags".utf8)
        let vendor = Data("yahadesk".utf8)
        tags.append(le: UInt32(vendor.count))
        tags.append(vendor)
        tags.append(le: UInt32(0))
        page(tags, flags: 0)
    }

    /// `samples` is the packet's decoded length at 16 kHz.
    public mutating func append(_ packet: Data, samples: Int) {
        guard !packet.isEmpty, packet.count < 255 * 255, samples > 0 else { return }
        if let p = pending { audio(p, last: false) }
        pending = (packet, samples)
        samples48k += samples * 3
    }

    /// The finished file; the last audio page carries end-of-stream.
    public func finish() -> Data {
        var w = self
        if let p = w.pending { w.audio(p, last: true) }
        return w.pages
    }

    private mutating func audio(_ p: (packet: Data, samples: Int), last: Bool) {
        granule += UInt64(p.samples * 3)
        page(p.packet, flags: last ? 0x04 : 0)
    }

    private mutating func page(_ packet: Data, flags: UInt8) {
        var h = Data("OggS".utf8)
        h.append(contentsOf: [0, flags])
        h.append(le: granule)
        h.append(le: serial)
        h.append(le: sequence)
        h.append(le: UInt32(0))  // CRC, filled below
        var lacing = [UInt8](repeating: 255, count: packet.count / 255)
        lacing.append(UInt8(packet.count % 255))
        h.append(UInt8(lacing.count))
        h.append(contentsOf: lacing)
        var page = h + packet
        let crc = Self.crc(page)
        page.replaceSubrange(22..<26, with: withUnsafeBytes(of: crc.littleEndian, Array.init))
        pages.append(page)
        sequence += 1
    }

    private static let table: [UInt32] = (0..<256).map { i in
        (0..<8).reduce(UInt32(i) << 24) { r, _ in r & 0x8000_0000 != 0 ? (r << 1) ^ 0x04c1_1db7 : r << 1 }
    }

    static func crc(_ data: Data) -> UInt32 {
        data.reduce(UInt32(0)) { ($0 << 8) ^ table[Int(($0 >> 24) ^ UInt32($1))] }
    }
}

/// Reads back the audio packets of an Ogg Opus file: OpusHead and OpusTags dropped, lacing runs of 255 joined.
/// Nil when the file is not Ogg Opus or a page is cut short.
public enum OggOpusReader {
    public static func packets(_ file: Data) -> [Data]? {
        let file = Data(file)  // zero-based indices
        var packets: [Data] = [], packet = Data(), at = 0
        while at < file.count {
            guard at + 27 <= file.count, file[at..<(at + 4)] == Data("OggS".utf8) else { return nil }
            let segments = Int(file[at + 26])
            guard at + 27 + segments <= file.count else { return nil }
            var body = at + 27 + segments
            for lace in file[(at + 27)..<(at + 27 + segments)] {
                guard body + Int(lace) <= file.count else { return nil }
                packet.append(file[body..<(body + Int(lace))])
                body += Int(lace)
                if lace < 255 { packets.append(packet); packet = Data() }
            }
            at = body
        }
        guard packets.count >= 2, packets[0].starts(with: Data("OpusHead".utf8)) else { return nil }
        return Array(packets.dropFirst(2))
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(le value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
