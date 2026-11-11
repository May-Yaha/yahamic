import COpus
import DeskProtocol
import Foundation

/// libopus 解码器(16 kHz 单声道,与固件编码器匹配),随对象销毁释放。
final class OpusFrameDecoder {
    static let maxSamples = 960  // 60 ms @ 16 kHz

    private let state: OpaquePointer

    init?(sampleRate: Int32 = 16000, channels: Int32 = 1) {
        var error: Int32 = 0
        guard let created = opus_decoder_create(sampleRate, channels, &error), error == 0 else {
            return nil
        }
        state = created
    }

    /// 解码一帧到 pcm(容量至少 maxSamples);返回样本数,<=0 表示失败。
    func decode(_ payload: Data, into pcm: inout [Int16]) -> Int {
        let capacity = Int32(min(pcm.count, Self.maxSamples))
        return Int(payload.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            return pcm.withUnsafeMutableBufferPointer {
                opus_decode(state, base.assumingMemoryBound(to: UInt8.self), Int32(raw.count),
                            $0.baseAddress, capacity, 0)
            }
        })
    }

    deinit { opus_decoder_destroy(state) }
}

public enum OggOpusDecoder {
    /// A backed-up `.opus` take decoded to 16 kHz mono Int16 PCM, the encoder lookahead (pre-skip) dropped.
    public static func pcm(_ ogg: Data) -> Data? {
        guard let packets = OggOpusReader.packets(ogg), let decoder = OpusFrameDecoder() else { return nil }
        var out = Data(), frame = [Int16](repeating: 0, count: OpusFrameDecoder.maxSamples)
        for packet in packets {
            let n = decoder.decode(packet, into: &frame)
            guard n > 0 else { return nil }
            frame.prefix(n).withUnsafeBytes { out.append(contentsOf: $0) }
        }
        return Data(out.dropFirst(OggOpusWriter.preSkip / 3 * 2))
    }
}
