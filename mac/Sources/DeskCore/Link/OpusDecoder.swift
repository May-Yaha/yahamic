import COpus
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
