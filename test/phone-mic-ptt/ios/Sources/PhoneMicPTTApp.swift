import AVFoundation
import CoreBluetooth
import PushToTalk
import SwiftUI
import UIKit

// 验证:Mac 讲话键经 BLE 到手机,能否在后台(锁屏)触发 PushToTalk 开始发送并采集。
// A:手机做外设,Mac 写 talk 特征(didReceiveWrite);B:Mac 做外设,notify talk 特征(didUpdateValueFor)。
// 两路同时开着,由 Mac 端 test/phone-mic-ptt/mac-rig.swift 选一路。只回传电平,不传真实音频。
enum SpikeID {
    static func uuid(_ n: Int) -> CBUUID { CBUUID(string: String(format: "9053%04X-395E-4621-8E8C-82039EE589FC", n)) }
    static let serviceA = uuid(0x01), talkA = uuid(0x02), audioA = uuid(0x03)
    static let serviceB = uuid(0x11), talkB = uuid(0x12), audioB = uuid(0x13)
    static let channel = UUID(uuidString: "9053F000-395E-4621-8E8C-82039EE589FC")!
    static let descriptor = PTChannelDescriptor(name: "Yaha 麦克风", image: nil)
}

@main
struct PhoneMicPTTApp: App {
    @StateObject private var spike = Spike()
    var body: some Scene {
        WindowGroup { SpikeView(spike: spike) }
    }
}

struct SpikeView: View {
    @ObservedObject var spike: Spike
    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("频道", value: spike.joined ? "已加入" : "未加入")
                    LabeledContent("A 手机外设", value: spike.linkA)
                    LabeledContent("B 手机中心", value: spike.linkB)
                    Button(spike.joined ? "离开频道" : "加入频道") { spike.toggleChannel() }
                } footer: {
                    Text("先加入频道、等 Mac 脚本显示链路就绪,再锁屏。")
                }
                Section("日志(新的在上)") {
                    ForEach(spike.lines.indices.reversed(), id: \.self) {
                        Text(spike.lines[$0]).font(.caption.monospaced())
                    }
                }
            }
            .navigationTitle("手机麦克风 PTT")
        }
    }
}

final class Spike: NSObject, ObservableObject {
    @Published var joined = false
    @Published var linkA = "未连接"
    @Published var linkB = "扫描中"
    @Published var lines: [String] = []

    private var ptt: PTChannelManager?
    private var peripheralManager: CBPeripheralManager!
    private var central: CBCentralManager!
    private var audioA: CBMutableCharacteristic?
    private var mac: CBPeripheral?
    private var audioB: CBCharacteristic?
    private let engine = AVAudioEngine()
    private var triggeredAt: Date?
    private var firstBuffer = false
    private var seq: UInt16 = 0

    override init() {
        super.init()
        // PTT 要求启动时就定好 playAndRecord,发送过程中不改;权限也在启动时要,不在每次发送时要。
        do { try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default) }
        catch { log("音频会话类别设置失败:\(error.localizedDescription)") }
        AVAudioApplication.requestRecordPermission { [weak self] ok in self?.log("麦克风权限:\(ok ? "已允许" : "被拒")") }
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
        central = CBCentralManager(delegate: self, queue: nil)
        PTChannelManager.channelManager(delegate: self, restorationDelegate: self) { [weak self] manager, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.ptt = manager
                self.joined = manager?.activeChannelUUID != nil
                self.log(error.map { "PTT 初始化失败:\(Self.describe($0))" } ?? "PTT 就绪")
            }
        }
    }

    func toggleChannel() {
        guard let ptt else { return log("PTT 未就绪") }
        if joined { ptt.leaveChannel(channelUUID: SpikeID.channel) }
        else { ptt.requestJoinChannel(channelUUID: SpikeID.channel, descriptor: SpikeID.descriptor) }
    }

    /// A、B 两路的讲话键都走这里:1 = 按下。
    private func talk(_ down: Bool, via path: String) {
        guard let ptt, joined else { return log("\(path) 收到 \(down ? 1 : 0),但未加入频道") }
        log("\(path):讲话键\(down ? "按下" : "松开")")
        if down {
            triggeredAt = Date()
            ptt.requestBeginTransmitting(channelUUID: SpikeID.channel)
        } else {
            ptt.stopTransmitting(channelUUID: SpikeID.channel)
        }
    }

    private func startCapture() {
        let input = engine.inputNode
        firstBuffer = false
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
            let db = 10 * log10(max(sum / Float(buffer.frameLength), 1e-12))
            DispatchQueue.main.async { self?.send(level: db) }
        }
        do { try engine.start() } catch { log("采集启动失败:\(Self.describe(error))") }
    }

    private func stopCapture() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    /// 电平包:seq u16 LE ‖ 后台 u8 ‖ 电平 dB×10 i16 LE。两路都发,Mac 只听自己那一路。
    private func send(level db: Float) {
        if !firstBuffer {
            firstBuffer = true
            log("首个采集缓冲,距收到讲话键 \(elapsed()) ms")
        }
        seq &+= 1
        var packet = Data()
        withUnsafeBytes(of: seq.littleEndian) { packet.append(contentsOf: $0) }
        packet.append(UIApplication.shared.applicationState == .active ? 0 : 1)
        withUnsafeBytes(of: Int16(clamping: Int((db * 10).rounded())).littleEndian) { packet.append(contentsOf: $0) }
        if let audioA { _ = peripheralManager.updateValue(packet, for: audioA, onSubscribedCentrals: nil) }
        if let mac, let audioB { mac.writeValue(packet, for: audioB, type: .withoutResponse) }
    }

    private func elapsed() -> String {
        triggeredAt.map { String(Int(Date().timeIntervalSince($0) * 1000)) } ?? "?"
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func describe(_ error: Error) -> String {
        let e = error as NSError
        return "\(e.domain) \(e.code) \(e.localizedDescription)"
    }

    func log(_ message: String) {
        let at = Date()
        DispatchQueue.main.async {
            let state = UIApplication.shared.applicationState == .active ? "前台" : "后台"
            let line = "\(Self.clock.string(from: at)) [\(state)] \(message)"
            print(line)
            self.lines.append(line)
            if self.lines.count > 300 { self.lines.removeFirst(100) }
        }
    }
}

extension Spike: PTChannelManagerDelegate, PTChannelRestorationDelegate {
    func channelManager(_ m: PTChannelManager, didJoinChannel uuid: UUID, reason: PTChannelJoinReason) {
        DispatchQueue.main.async { self.joined = true }
        log("已加入频道(reason \(reason.rawValue))")
    }

    func channelManager(_ m: PTChannelManager, didLeaveChannel uuid: UUID, reason: PTChannelLeaveReason) {
        DispatchQueue.main.async { self.joined = false }
        log("已离开频道(reason \(reason.rawValue))")
    }

    func channelManager(_ m: PTChannelManager, failedToJoinChannel uuid: UUID, error: Error) {
        log("加入频道失败:\(Self.describe(error))")
    }

    func channelManager(_ m: PTChannelManager, channelUUID: UUID, didBeginTransmittingFrom source: PTChannelTransmitRequestSource) {
        log("开始发送(source \(source.rawValue)),距讲话键 \(elapsed()) ms")
    }

    func channelManager(_ m: PTChannelManager, channelUUID: UUID, didEndTransmittingFrom source: PTChannelTransmitRequestSource) {
        log("结束发送(source \(source.rawValue))")
    }

    func channelManager(_ m: PTChannelManager, failedToBeginTransmittingInChannel uuid: UUID, error: Error) {
        log("❌ 开始发送被拒:\(Self.describe(error))")
    }

    func channelManager(_ m: PTChannelManager, didActivate audioSession: AVAudioSession) {
        log("音频会话激活,距讲话键 \(elapsed()) ms")
        DispatchQueue.main.async { self.startCapture() }
    }

    func channelManager(_ m: PTChannelManager, didDeactivate audioSession: AVAudioSession) {
        DispatchQueue.main.async { self.stopCapture() }
        log("音频会话停用")
    }

    func channelManager(_ m: PTChannelManager, receivedEphemeralPushToken pushToken: Data) {
        log("收到临时推送令牌(demo 不用)")
    }

    func incomingPushResult(channelManager: PTChannelManager, channelUUID: UUID, pushPayload: [String: Any]) -> PTPushResult {
        .leaveChannel  // demo 没有服务端,不该收到推送
    }

    func channelDescriptor(restoredChannelUUID: UUID) -> PTChannelDescriptor { SpikeID.descriptor }
}

// A:手机做外设。
extension Spike: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        guard p.state == .poweredOn else { return log("蓝牙(外设)状态 \(p.state.rawValue)") }
        let talk = CBMutableCharacteristic(type: SpikeID.talkA, properties: [.write], value: nil, permissions: [.writeable])
        let audio = CBMutableCharacteristic(type: SpikeID.audioA, properties: [.notify], value: nil, permissions: [.readable])
        let service = CBMutableService(type: SpikeID.serviceA, primary: true)
        service.characteristics = [talk, audio]
        p.removeAllServices()
        p.add(service)
        audioA = audio
        p.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [SpikeID.serviceA], CBAdvertisementDataLocalNameKey: "YahaPhoneMic"])
    }

    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral, didSubscribeTo c: CBCharacteristic) {
        linkA = "Mac 已订阅"
        log("A:Mac 已订阅")
    }

    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom c: CBCharacteristic) {
        linkA = "未连接"
        log("A:Mac 取消订阅")
    }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for r in requests where r.characteristic.uuid == SpikeID.talkA {
            if let v = r.value?.first { talk(v != 0, via: "A 写入") }
        }
        if let first = requests.first { p.respond(to: first, withResult: .success) }
    }
}

// B:手机做中心,订阅 Mac 的 talk 特征。
extension Spike: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else { return log("蓝牙(中心)状态 \(c.state.rawValue)") }
        c.scanForPeripherals(withServices: [SpikeID.serviceB])
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        guard mac == nil else { return }
        mac = p
        p.delegate = self
        c.stopScan()
        c.connect(p)
        linkB = "连接中"
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([SpikeID.serviceB])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        c.connect(p)
    }

    // 不设超时的 connect 在后台也一直挂着,Mac 回来就连上。
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        audioB = nil
        linkB = "重连中"
        log("B:与 Mac 断开")
        c.connect(p)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == SpikeID.serviceB }) else { return }
        p.discoverCharacteristics([SpikeID.talkB, SpikeID.audioB], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for c in s.characteristics ?? [] {
            if c.uuid == SpikeID.talkB { p.setNotifyValue(true, for: c) }
            if c.uuid == SpikeID.audioB { audioB = c }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard c.uuid == SpikeID.talkB else { return }
        linkB = c.isNotifying ? "已订阅 Mac" : "订阅失败"
        log("B:\(linkB)")
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard c.uuid == SpikeID.talkB, let v = c.value?.first else { return }
        talk(v != 0, via: "B 通知")
    }
}
