import AVFoundation
import Foundation

/// 采集缓冲 → 16 kHz 单声道 Int16 → 每 960 样本一帧 Opus(与固件同参数,Mac 端 libopus 直接解)。
/// iPhone 当麦克风与 Mac 视频字幕录音共用。只在一个线程上用。
public final class MicEncoder: @unchecked Sendable {
    public static let frameSamples = 960
    private let pcm16k = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private let opusFormat: AVAudioFormat
    private let resampler: AVAudioConverter
    private let opus: AVAudioConverter
    private var samples: [Int16] = []

    public init?(input: AVAudioFormat) {
        var asbd = AudioStreamBasicDescription(mSampleRate: 16000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                               mBytesPerPacket: 0, mFramesPerPacket: UInt32(Self.frameSamples),
                                               mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        guard let opusFormat = AVAudioFormat(streamDescription: &asbd),
              let resampler = AVAudioConverter(from: input, to: pcm16k),
              let opus = AVAudioConverter(from: pcm16k, to: opusFormat) else { return nil }
        opus.bitRate = 32000
        self.opusFormat = opusFormat
        self.resampler = resampler
        self.opus = opus
    }

    public func push(_ buffer: AVAudioPCMBuffer) -> [Data] {
        let ratio = 16000 / buffer.format.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: pcm16k, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32)
        else { return [] }
        var fed = false
        _ = resampler.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if let data = out.int16ChannelData { samples += UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)) }
        return frames()
    }

    /// 已是 16 kHz 单声道 Int16 的 PCM(Mac 系统声音经 Downsampler 后)。
    public func push(pcm16k: Data) -> [Data] {
        pcm16k.withUnsafeBytes { samples += $0.bindMemory(to: Int16.self) }
        return frames()
    }

    private func frames() -> [Data] {
        var frames: [Data] = []
        while samples.count >= Self.frameSamples {
            if let frame = encode(samples.prefix(Self.frameSamples)) { frames.append(frame) }
            samples.removeFirst(Self.frameSamples)
        }
        return frames
    }

    public func encode(_ frame: ArraySlice<Int16>) -> Data? {
        guard let input = AVAudioPCMBuffer(pcmFormat: pcm16k, frameCapacity: AVAudioFrameCount(frame.count)) else { return nil }
        input.frameLength = AVAudioFrameCount(frame.count)
        frame.withUnsafeBufferPointer { input.int16ChannelData![0].update(from: $0.baseAddress!, count: frame.count) }
        let out = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: 1, maximumPacketSize: max(opus.maximumOutputPacketSize, 512))
        var fed = false
        let result = opus.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard result != .error, out.packetCount == 1, out.byteLength > 0 else { return nil }
        return Data(bytes: out.data, count: Int(out.byteLength))
    }
}
