import AVFoundation
import CoreBluetooth
import DeskProtocol
import DeskShared
import PushToTalk
import UIKit

// 手机当麦克风(需求见 docs/requirements/desk-phone-mic-2026-11-11,可行性见 test/phone-mic-ptt):
// 手机扮成 yahadesk 外设(Wire.phoneService 下 info/audio/status/control,格式同固件),Mac 讲话键写 control,
// 手机经 PushToTalk 开始发送、采集 16 kHz 单声道,每 60 ms 一帧 Opus 32 kbps,按固件同样的分片 notify 回 Mac。
// PushToTalk 让锁屏后讲话键仍能开始采集;加入频道只能在前台由用户点。
@MainActor
final class PhoneMic: NSObject, ObservableObject {
    @Published private(set) var joined = false
    @Published private(set) var macLinked = false   // Mac 已订阅 audio
    @Published private(set) var talking = false
    @Published private(set) var message = ""

    nonisolated private static let channel = UUID(uuidString: "90520F00-395E-4621-8E8C-82039EE589FC")!
    nonisolated private static let descriptor = PTChannelDescriptor(name: "Yaha 麦克风", image: nil)
    private static let maxPending = 40  // 约 1 秒的分片;发不出去时整帧丢,Mac 按 seq 跳号计丢帧

    private var ptt: PTChannelManager?
    private var peripheral: CBPeripheralManager?
    private var audio: CBMutableCharacteristic?
    private var status: CBMutableCharacteristic?
    private var mac: CBCentral?
    private var pending: [Data] = []
    private var seq: UInt16 = 0
    private var wantTalk = false  // Mac 讲话键当前是否按着
    private let engine = AVAudioEngine()
    private var encoder: MicEncoder?

    override init() {
        super.init()
        // 频道跨启动由系统恢复,管理器要在启动时就建好。
        PTChannelManager.channelManager(delegate: self, restorationDelegate: self) { manager, error in
            Task { @MainActor in
                self.ptt = manager
                if let error { self.message = "PushToTalk 不可用:\(error.localizedDescription)" }
                if manager?.activeChannelUUID != nil { self.didJoin() }
            }
        }
    }

    func toggle() {
        guard let ptt else { message = "PushToTalk 未就绪"; return }
        if joined { ptt.leaveChannel(channelUUID: Self.channel); return }
        AVAudioApplication.requestRecordPermission { ok in
            Task { @MainActor in
                guard ok else { self.message = "没有麦克风权限:到 设置 → Yaha Desk 里打开"; return }
                self.configureSession()
                self.ptt?.requestJoinChannel(channelUUID: Self.channel, descriptor: Self.descriptor)
            }
        }
    }

    /// PushToTalk 要求发送前定好 playAndRecord、发送中不改;回放仍走扬声器。
    private func configureSession() {
        do { try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker]) }
        catch { message = "音频会话设置失败:\(error.localizedDescription)" }
    }

    private func didJoin() {
        joined = true
        configureSession()
        // 预热:首包的大头是 engine.start()(约 800 ms)。图里没有节点时 prepare 会抛 ObjC 异常直接闪退,
        // 先取一次 inputNode 把输入节点建出来;拿不到有效输入格式(没权限、没麦克风)就不预热。
        if Self.usable(engine.inputNode.outputFormat(forBus: 0)) { engine.prepare() }
        if peripheral == nil { peripheral = CBPeripheralManager(delegate: self, queue: nil) }
    }

    private func didLeave() {
        joined = false
        talking = false
        stopCapture()
        peripheral?.stopAdvertising()
        peripheral?.removeAllServices()
        peripheral = nil
        mac = nil
        macLinked = false
    }

    /// control 写入:01 muted u8。0 = 按下讲话键。
    /// 快按快放时松开会先于 didBegin 到达,停不掉;记下想要的状态,didBegin 时再对一次。
    private func control(_ data: Data) {
        let b = [UInt8](data)
        guard b.count == 2, b[0] == 0x01, let ptt else { return }
        wantTalk = b[1] == 0
        if wantTalk { ptt.requestBeginTransmitting(channelUUID: Self.channel) }
        else { ptt.stopTransmitting(channelUUID: Self.channel) }
    }

    private func linkLost() {
        mac = nil
        macLinked = false
        pending.removeAll()
        wantTalk = false
        if talking { ptt?.stopTransmitting(channelUUID: Self.channel) }  // 不停会一直发到用户手动结束
    }

    private func setTalking(_ on: Bool) {
        if on, !wantTalk { ptt?.stopTransmitting(channelUUID: Self.channel) }
        talking = on
        if let status, let peripheral { _ = peripheral.updateValue(Data([on ? 0 : 1]), for: status, onSubscribedCentrals: nil) }
    }

    private func startCapture() {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard Self.usable(format) else { message = "拿不到麦克风输入,检查麦克风权限"; return }  // 无效格式 installTap 会闪退
        guard let encoder = MicEncoder(input: format) else { message = "Opus 编码器创建失败"; return }
        self.encoder = encoder
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(encoder, to: self))
        do { try engine.start() } catch { message = "采集启动失败:\(error.localizedDescription)" }
    }

    /// tap 在音频线程上回调。闭包不能在 startCapture 里写:那里写的闭包继承主线程隔离,
    /// 第一帧到达就被 Swift 6 运行时检查判越界直接闪退。
    nonisolated private static func tap(_ encoder: MicEncoder, to mic: PhoneMic) -> AVAudioNodeTapBlock {
        { buffer, _ in
            for frame in encoder.push(buffer) { Task { @MainActor in mic.send(frame) } }
        }
    }

    nonisolated static func usable(_ format: AVAudioFormat) -> Bool { format.sampleRate > 0 && format.channelCount > 0 }

    private func stopCapture() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        encoder = nil
    }

    private func send(_ opus: Data) {
        guard let mac else { return }
        seq &+= 1
        guard pending.count < Self.maxPending else { return }
        pending += Wire.fragments(seq: seq, opus: opus, chunk: mac.maximumUpdateValueLength - 3)
        flush()
    }

    private func flush() {
        guard let peripheral, let audio else { return }
        while let first = pending.first, peripheral.updateValue(first, for: audio, onSubscribedCentrals: nil) {
            pending.removeFirst()
        }
    }
}

extension PhoneMic: @preconcurrency CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        guard p.state == .poweredOn else {
            if p.state == .unauthorized { message = "没有蓝牙权限:到 设置 → Yaha Desk 里打开" }
            return linkLost()
        }
        // 都要求加密:Mac 第一次读 info 时两端弹系统配对框,配对后音频走加密链路。
        let info = CBMutableCharacteristic(type: CBUUID(string: Wire.info), properties: [.read],
                                           value: nil, permissions: [.readEncryptionRequired])
        let audio = CBMutableCharacteristic(type: CBUUID(string: Wire.audio), properties: [.notify, .notifyEncryptionRequired],
                                            value: nil, permissions: [.readEncryptionRequired])
        let status = CBMutableCharacteristic(type: CBUUID(string: Wire.status),
                                             properties: [.read, .notify, .notifyEncryptionRequired],
                                             value: nil, permissions: [.readEncryptionRequired])
        let control = CBMutableCharacteristic(type: CBUUID(string: Wire.control), properties: [.write],
                                              value: nil, permissions: [.writeEncryptionRequired])
        let service = CBMutableService(type: CBUUID(string: Wire.phoneService), primary: true)
        service.characteristics = [info, audio, status, control]
        self.audio = audio
        self.status = status
        p.removeAllServices()
        p.add(service)
        p.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: Wire.phoneService)],
                            CBAdvertisementDataLocalNameKey: "Yaha 手机麦克风"])
    }

    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral, didSubscribeTo c: CBCharacteristic) {
        guard c.uuid == CBUUID(string: Wire.audio) else { return }
        mac = central
        macLinked = true
        pending.removeAll()
    }

    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom c: CBCharacteristic) {
        if c.uuid == CBUUID(string: Wire.audio) { linkLost() }
    }

    func peripheralManagerIsReady(toUpdateSubscribers p: CBPeripheralManager) { flush() }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveRead r: CBATTRequest) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let value: Data
        switch r.characteristic.uuid {
        case CBUUID(string: Wire.info): value = Data("fw iPhone \(version)\nrate 16000\nframe 60\ncodec opus\n".utf8)
        case CBUUID(string: Wire.status): value = Data([talking ? 0 : 1])
        default: return p.respond(to: r, withResult: .attributeNotFound)
        }
        guard r.offset <= value.count else { return p.respond(to: r, withResult: .invalidOffset) }
        r.value = value.subdata(in: r.offset..<value.count)
        p.respond(to: r, withResult: .success)
    }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for r in requests where r.characteristic.uuid == CBUUID(string: Wire.control) {
            if let v = r.value { control(v) }
        }
        if let first = requests.first { p.respond(to: first, withResult: .success) }
    }
}

// PushToTalk 回调的队列不固定,一律切回主线程。
extension PhoneMic: PTChannelManagerDelegate, PTChannelRestorationDelegate {
    nonisolated func channelManager(_ m: PTChannelManager, didJoinChannel uuid: UUID, reason: PTChannelJoinReason) {
        Task { @MainActor in self.didJoin() }
    }

    nonisolated func channelManager(_ m: PTChannelManager, didLeaveChannel uuid: UUID, reason: PTChannelLeaveReason) {
        Task { @MainActor in self.didLeave() }
    }

    nonisolated func channelManager(_ m: PTChannelManager, failedToJoinChannel uuid: UUID, error: Error) {
        let text = Self.describe(error)
        Task { @MainActor in self.message = "加入频道失败:\(text)" }
    }

    /// 常见失败给出处理办法,其余带上错误码方便排查。
    nonisolated static func describe(_ error: Error) -> String {
        let e = error as NSError
        guard e.domain == PTChannelError.errorDomain else { return "\(e.domain) \(e.code) \(e.localizedDescription)" }
        switch PTChannelError.Code(rawValue: e.code) {
        case .channelLimitReached: return "系统同时只允许一个对讲频道,先在其他 App(如“PTT 验证”)里离开频道"
        case .callActive: return "通话中不能加入,挂断后再试"
        case .appNotForeground: return "只能在前台加入,回到 App 里再点"
        default: return "PTChannelError \(e.code) \(e.localizedDescription)"
        }
    }

    nonisolated func channelManager(_ m: PTChannelManager, channelUUID: UUID,
                                    didBeginTransmittingFrom source: PTChannelTransmitRequestSource) {
        Task { @MainActor in self.setTalking(true) }
    }

    nonisolated func channelManager(_ m: PTChannelManager, channelUUID: UUID,
                                    didEndTransmittingFrom source: PTChannelTransmitRequestSource) {
        Task { @MainActor in self.setTalking(false) }
    }

    nonisolated func channelManager(_ m: PTChannelManager, failedToBeginTransmittingInChannel uuid: UUID, error: Error) {
        let text = Self.describe(error)
        Task { @MainActor in self.message = "开始讲话被拒:\(text)" }
    }

    nonisolated func channelManager(_ m: PTChannelManager, didActivate audioSession: AVAudioSession) {
        Task { @MainActor in self.startCapture() }
    }

    nonisolated func channelManager(_ m: PTChannelManager, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor in self.stopCapture() }
    }

    nonisolated func channelManager(_ m: PTChannelManager, receivedEphemeralPushToken pushToken: Data) {}

    nonisolated func incomingPushResult(channelManager: PTChannelManager, channelUUID: UUID,
                                        pushPayload: [String: Any]) -> PTPushResult {
        .leaveChannel  // 没有推送服务端,不该收到
    }

    nonisolated func channelDescriptor(restoredChannelUUID: UUID) -> PTChannelDescriptor { Self.descriptor }
}
