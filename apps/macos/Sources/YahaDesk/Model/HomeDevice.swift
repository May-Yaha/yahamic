import Foundation
import DeskCore

/// yahadesk 无线麦克风(ESP32-S3 板,BLE 直连)。
struct MicDevice {
    var state = Uplink.State()
    var paused = false  // 用户点了「暂时断开」(让连接给 iPhone)

    var kind: String { state.deviceName.isEmpty ? "yahadesk" : state.deviceName }  // 设备编号
    var title: String { "无线麦克风" }
    var isOnline: Bool { state.connected }

    /// 一行状态:暂停 / 离线 / 在线·静音 / 送声 -39 dB
    var statusLine: String {
        if paused { return "已暂时断开,iPhone 现在可以连接设备" }
        if state.pairingLost { return "设备已不认识这台 Mac:到系统蓝牙设置里移除 yahadesk,再点重新连接并按屏幕数字配对" }
        guard state.connected else { return "打开设备,靠近 Mac;首次连接按屏幕上的 6 位数字配对" }
        if state.muted { return "在线 · 静音待命" }
        return String(format: "送声中 · %.0f dB · %d 帧/s", state.levelDb, state.framesPerSecond)
    }

    /// 设备电池:在线且报了电量或外接电源才有(0.4.3 前的固件不报)。图标按 25% 一档;没在充电且 ≤20% 为 low。
    var battery: (text: String, symbol: String, low: Bool)? {
        guard state.connected else { return nil }
        let cloud = state.cloud
        guard cloud.battery >= 0 else { return cloud.usbPower ? ("外接电源", "powerplug", false) : nil }
        let percent = min(cloud.battery, 100)
        if cloud.charging { return ("充电 \(percent)%", "battery.100percent.bolt", false) }
        return ("\(percent)%", "battery.\(min(100, (percent + 12) / 25 * 25))percent", percent <= 20)
    }

    /// 电平 0..1(-60 dB..0 dB)
    var levelFraction: Double {
        guard state.connected, !state.muted else { return 0 }
        return min(1, max(0, (state.levelDb + 60) / 60))
    }
}
