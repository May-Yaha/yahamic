// 手机当麦克风 PushToTalk 验证的 Mac 端(手机端见同目录 ios/):模拟讲话键,
// 每 8 秒按住 3 秒,打印从按下到收到手机首个电平包的时延,以及松开后还收到多少包。
// 用法:./run-mac-rig.sh a|b(编译并包成 .app 再启动,见脚本注释)
//   a:手机做外设,这里连上去写 talk 特征;b:这里做外设,notify talk 特征给手机。
// 首次运行会弹终端的蓝牙权限。与 Yaha Desk 用不同的服务 UUID,可以同时开着。
import CoreBluetooth
import Foundation

let mode = CommandLine.arguments.dropFirst().first ?? ""
guard mode == "a" || mode == "b" else {
    print("用法:ptt-spike a|b")
    exit(2)
}

func uuid(_ n: Int) -> CBUUID { CBUUID(string: String(format: "9053%04X-395E-4621-8E8C-82039EE589FC", n)) }
let serviceA = uuid(0x01), talkA = uuid(0x02), audioA = uuid(0x03)
let serviceB = uuid(0x11), talkB = uuid(0x12), audioB = uuid(0x13)

func log(_ s: String) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    print("\(f.string(from: Date())) \(s)")
    fflush(stdout)
}

final class Rig: NSObject {
    var send: ((Bool) -> Void)?
    var ready = false {
        didSet { if ready != oldValue { log(ready ? "链路就绪:每 8 秒按住 3 秒。现在可以锁屏手机。" : "链路断开,等重连") } }
    }
    private var talking = false
    private var pressedAt = Date.distantPast, releasedAt = Date.distantPast
    private var packets = 0, tail = 0, lastTailMs = 0
    private var gotFirst = false

    private var phone: CBPeripheral?
    private var talkChar: CBCharacteristic?
    private var talkMutable: CBMutableCharacteristic?

    func cycle() {
        guard ready, let send else { return }
        if tail > 0 { log("  上轮松开后又收到 \(tail) 包,最后一包 +\(lastTailMs) ms") }
        talking = true; gotFirst = false; packets = 0; tail = 0
        pressedAt = Date()
        send(true)
        log("▶ 按下")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
            talking = false
            releasedAt = Date()
            self.send?(false)
            log("■ 松开,按住期间收到 \(packets) 包" + (gotFirst ? "" : "(没收到音频:看手机日志是否「开始发送被拒」)"))
        }
    }

    func audio(_ d: Data) {
        guard d.count >= 5 else { return }
        guard talking else {
            tail += 1
            lastTailMs = Int(Date().timeIntervalSince(releasedAt) * 1000)
            return
        }
        packets += 1
        guard !gotFirst else { return }
        gotFirst = true
        let db = Double(Int16(bitPattern: UInt16(d[3]) | UInt16(d[4]) << 8)) / 10
        log("  首包 +\(Int(Date().timeIntervalSince(pressedAt) * 1000)) ms,手机\(d[2] == 1 ? "后台" : "前台"),\(db) dB")
    }
}

// a:Mac 做中心。
extension Rig: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else { return log("蓝牙状态 \(c.state.rawValue)") }
        c.scanForPeripherals(withServices: [serviceA])
        log("扫描手机(手机 App 先放前台)")
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        guard phone == nil else { return }
        phone = p
        p.delegate = self
        c.stopScan()
        c.connect(p)
        log("发现 \(p.name ?? "手机"),连接中")
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) { p.discoverServices([serviceA]) }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { c.connect(p) }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        ready = false
        c.connect(p)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == serviceA }) else { return }
        p.discoverCharacteristics([talkA, audioA], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for c in s.characteristics ?? [] {
            if c.uuid == talkA { talkChar = c }
            if c.uuid == audioA { p.setNotifyValue(true, for: c) }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard c.uuid == audioA, c.isNotifying, let talk = talkChar else { return }
        send = { [weak p] down in p?.writeValue(Data([down ? 1 : 0]), for: talk, type: .withResponse) }
        ready = true
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        if let error { log("写 talk 失败:\(error.localizedDescription)") }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        if c.uuid == audioA, let v = c.value { audio(v) }
    }
}

// b:Mac 做外设。
extension Rig: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ pm: CBPeripheralManager) {
        guard pm.state == .poweredOn else { return log("蓝牙状态 \(pm.state.rawValue)") }
        let talk = CBMutableCharacteristic(type: talkB, properties: [.notify], value: nil, permissions: [.readable])
        let audio = CBMutableCharacteristic(type: audioB, properties: [.writeWithoutResponse], value: nil, permissions: [.writeable])
        let service = CBMutableService(type: serviceB, primary: true)
        service.characteristics = [talk, audio]
        pm.add(service)
        talkMutable = talk
        pm.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceB], CBAdvertisementDataLocalNameKey: "YahaMacTalk"])
        log("广播中,等手机订阅(手机 App 先放前台)")
    }

    func peripheralManager(_ pm: CBPeripheralManager, central: CBCentral, didSubscribeTo c: CBCharacteristic) {
        guard let talk = talkMutable else { return }
        send = { [weak pm] down in
            if pm?.updateValue(Data([down ? 1 : 0]), for: talk, onSubscribedCentrals: nil) == false { log("notify 队列满,本次讲话键丢了") }
        }
        ready = true
    }

    func peripheralManager(_ pm: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom c: CBCharacteristic) {
        ready = false
    }

    func peripheralManager(_ pm: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for r in requests where r.characteristic.uuid == audioB { if let v = r.value { audio(v) } }
    }
}

let rig = Rig()
let central = mode == "a" ? CBCentralManager(delegate: rig, queue: .main) : nil
let peripheralManager = mode == "b" ? CBPeripheralManager(delegate: rig, queue: .main) : nil
_ = (central, peripheralManager)
Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { _ in rig.cycle() }
RunLoop.main.run()
