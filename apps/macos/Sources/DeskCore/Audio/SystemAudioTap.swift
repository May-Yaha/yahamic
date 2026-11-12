import CoreAudio
import Foundation

// 本机正在播放的声音(视频、会议、音乐)→ 16 kHz Int16 单声道,给视频字幕用。
// Core Audio Process Tap(macOS 14.2+,写法参照开源 insidegui/AudioCap):全局单声道 tap 排除本进程
// (本进程往 BlackHole 写的是用户自己的麦克风声),挂进私有聚合设备,IOProc 回调里取数。
// 首次启动系统会弹「录制系统音频」授权;Info.plist 缺 NSAudioCaptureUsageDescription 时只收到静音。
public final class SystemAudioTap: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var downsampler: Downsampler
    private let queue = DispatchQueue(label: "yahadesk.system-audio-tap")

    public init?(onPCM: @escaping @Sendable (Data) -> Void) {
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: Self.ownProcessObject().map { [$0] } ?? [])
        description.uuid = UUID()
        description.name = "Yaha Desk 视频字幕"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        downsampler = Downsampler(rate: 48_000)
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else { return nil }
        guard let format = Self.tapFormat(tapID), let outputUID = Self.defaultOutputUID() else {
            stop()
            return nil
        }
        downsampler = Downsampler(rate: format.mSampleRate)
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Yaha Desk 视频字幕",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID) == noErr else {
            stop()
            return nil
        }
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { [weak self] _, input, _, _, _ in
            guard let self else { return }
            let pcm = self.downsampler.push(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)))
            if !pcm.isEmpty { onPCM(pcm.withUnsafeBytes { Data($0) }) }
        }
        guard status == noErr, AudioDeviceStart(deviceID, procID) == noErr else {
            stop()
            return nil
        }
    }

    /// 可重复调用;顺序:停设备 → 拆 IOProc → 拆聚合设备 → 拆 tap。
    public func stop() {
        if let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
            self.procID = nil
        }
        if deviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(deviceID)
            deviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { stop() }

    private static func ownProcessObject() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object) == noErr,
              object != kAudioObjectUnknown
        else { return nil }
        return object
    }

    private static func tapFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format) == noErr,
              format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        else { return nil }
        return format
    }

    private static func defaultOutputUID() -> String? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &device) == noErr else { return nil }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr,
              let uid = uid?.takeRetainedValue()
        else { return nil }
        return uid as String
    }
}

/// Float32(任意声道、交错或分声道)→ 16 kHz Int16 单声道,跨回调保留相位。
// ponytail: 盒式平均重采样,够 ASR 用;要拿去回放或音质有问题再换 AVAudioConverter。
public struct Downsampler {
    private let ratio: Double
    private var sum: Float = 0
    private var count = 0
    private var phase = 0.0

    public init(rate: Double) { ratio = max(1, rate / 16_000) }

    public mutating func push(_ buffers: UnsafeMutableAudioBufferListPointer) -> [Int16] {
        var out: [Int16] = []
        if buffers.count == 1, let first = buffers.first, let data = first.mData {
            let channels = max(1, Int(first.mNumberChannels))
            let samples = data.assumingMemoryBound(to: Float.self)
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
            out.reserveCapacity(Int(Double(frames) / ratio) + 1)
            for frame in 0..<frames {
                var mixed: Float = 0
                for c in 0..<channels { mixed += samples[frame * channels + c] }
                feed(mixed / Float(channels), into: &out)
            }
        } else {
            let channels = buffers.compactMap { $0.mData?.assumingMemoryBound(to: Float.self) }
            guard !channels.isEmpty else { return [] }
            let frames = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
            for frame in 0..<frames {
                var mixed: Float = 0
                for channel in channels { mixed += channel[frame] }
                feed(mixed / Float(channels.count), into: &out)
            }
        }
        return out
    }

    /// 测试用:单声道样本直接喂。
    public mutating func push(mono samples: [Float]) -> [Int16] {
        var out: [Int16] = []
        for sample in samples { feed(sample, into: &out) }
        return out
    }

    private mutating func feed(_ sample: Float, into out: inout [Int16]) {
        sum += sample
        count += 1
        phase += 1
        guard phase >= ratio else { return }
        phase -= ratio
        out.append(Int16(max(-1, min(1, sum / Float(count))) * 32_767))
        sum = 0
        count = 0
    }
}
