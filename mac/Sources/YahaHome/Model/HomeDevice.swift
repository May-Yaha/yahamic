import Foundation
import YahamicCore

// 家庭硬件的统一抽象:菜单栏面板按设备分区渲染。以后接入新硬件(灯、传感器、
// 开关……)只需新增一个遵守 HomeDevice 的模型 + 一个卡片视图,HomeModel 里挂上。
protocol HomeDevice: Identifiable {
    var id: String { get }
    var kind: String { get }     // 设备类别,如「无线麦克风」
    var title: String { get }    // 显示名
    var isOnline: Bool { get }
}

/// 第一个设备:yahamic 无线麦克风(ESP32-S3 板,Wi-Fi 直连)。
struct MicDevice: HomeDevice {
    var state = Uplink.State()

    var id: String { "yahamic" }
    var kind: String { state.deviceName.isEmpty ? "yahamic" : state.deviceName }  // 设备编号
    var title: String { "无线麦克风" }
    var isOnline: Bool { state.connected }

    /// 一行状态:离线 / 在线·静音 / 送声 -39 dB
    var statusLine: String {
        guard state.connected else { return "等待设备上线…" }
        if state.muted { return "在线 · 静音待命" }
        return String(format: "送声中 · %.0f dB · %d 帧/s", state.levelDb, state.framesPerSecond)
    }

    /// 电平 0..1(-60 dB..0 dB)
    var levelFraction: Double {
        guard state.connected, !state.muted else { return 0 }
        return min(1, max(0, (state.levelDb + 60) / 60))
    }
}
