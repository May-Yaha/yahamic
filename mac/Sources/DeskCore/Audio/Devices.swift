import CoreAudio
import Foundation

// CoreAudio 输出设备枚举:找到虚拟麦克风(BlackHole 或 --device 指定的设备)。

public struct OutputDevice: Identifiable, Hashable {
    public let id: AudioDeviceID
    public let name: String
    public let sampleRate: Double
    public let outputStreams: Int  // 输出流数量:>0 = 可写(虚拟麦克风的「输出」侧)
}

private func deviceName(_ id: AudioDeviceID) -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    let name = UnsafeMutablePointer<CFString>.allocate(capacity: 1)
    name.initialize(to: "" as CFString)
    defer {
        name.deinitialize(count: 1)
        name.deallocate()
    }
    var size = UInt32(MemoryLayout<CFString>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, name) == noErr else {
        return "#\(id)"
    }
    return name.pointee as String
}

private func outputStreamCount(_ id: AudioDeviceID,
                               scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> Int {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
        return 0
    }
    var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &streams) == noErr else {
        return 0
    }
    return streams.count
}

private func nominalRate(_ id: AudioDeviceID) -> Double {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var rate: Double = 0
    var size = UInt32(MemoryLayout<Double>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr else {
        return 48000
    }
    return rate > 0 ? rate : 48000
}

private func allDeviceIDs() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
        size > 0
    else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
    else { return [] }
    return ids
}

public func outputDevices() -> [OutputDevice] {
    allDeviceIDs()
        .map { id in
            OutputDevice(id: id, name: deviceName(id), sampleRate: nominalRate(id),
                         outputStreams: outputStreamCount(id))
        }
        .filter { $0.outputStreams > 0 }  // 只列有输出流的设备
}

public func findOutputDevice(named needle: String) -> OutputDevice? {
    let devices = outputDevices()
    // 先精确,再子串,大小写不敏感。
    if let exact = devices.first(where: { $0.name.caseInsensitiveCompare(needle) == .orderedSame }) {
        return exact
    }
    return devices.first { $0.name.range(of: needle, options: .caseInsensitive) != nil }
}

// 系统默认输入设备:听写类输入法(微信输入法只认它)从这里取麦克风。
private func defaultInputAddress() -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
}

public func defaultInputName() -> String? {
    var address = defaultInputAddress()
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
        id != 0
    else { return nil }
    return deviceName(id)
}

/// 按名字(精确,大小写不敏感)把有输入流的设备设为系统默认输入。
@discardableResult
public func setDefaultInput(named name: String) -> Bool {
    guard var id = allDeviceIDs().first(where: {
        outputStreamCount($0, scope: kAudioDevicePropertyScopeInput) > 0
            && deviceName($0).caseInsensitiveCompare(name) == .orderedSame
    }) else { return false }
    var address = defaultInputAddress()
    return AudioObjectSetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
        UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr
}

/// 虚拟麦克风的音量只会衰减我们写进去的声音:它被拉低后(实测 BlackHole 被调到 19% ≈ -52 dB,
/// 谁调的未查明,系统「输入音量」滑块即可改它),听写引擎只听到底噪、不出字。
/// 把输入/输出两侧的主音量拉回 1.0,返回调整前偏低的那个值(没动返回 nil)。
@discardableResult
public func restoreFullVolume(of id: AudioDeviceID) -> Float32? {
    var lowered: Float32?
    for scope in [kAudioDevicePropertyScopeInput, kAudioDevicePropertyScopeOutput] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var volume: Float32 = 1
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(id, &address),
              AudioObjectGetPropertyData(id, &address, 0, nil, &size, &volume) == noErr,
              volume < 0.999
        else { continue }
        var full: Float32 = 1
        if AudioObjectSetPropertyData(id, &address, 0, nil, size, &full) == noErr {
            lowered = min(lowered ?? volume, volume)
        }
    }
    return lowered
}

/// 监听设备列表与(当前出口设备的)采样率变化,回调在主队列。
/// 设备被拔掉/驱动重装、用户在「音频 MIDI 设置」里改采样率时,调用方据此重建 AudioSink。
public final class AudioHardwareWatcher {
    private var devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private var rateAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private let block: AudioObjectPropertyListenerBlock
    private var rateDevice: AudioDeviceID?

    public init(onChange: @escaping () -> Void) {
        block = { _, _ in onChange() }
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &devicesAddress, .main, block)
    }

    /// 改为监听这台设备的采样率(nil = 不监听)。
    public func watchRate(of device: AudioDeviceID?) {
        guard device != rateDevice else { return }
        if let old = rateDevice {
            AudioObjectRemovePropertyListenerBlock(old, &rateAddress, .main, block)
        }
        rateDevice = device
        if let device {
            AudioObjectAddPropertyListenerBlock(device, &rateAddress, .main, block)
        }
    }

    deinit {
        watchRate(of: nil)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &devicesAddress, .main, block)
    }
}
