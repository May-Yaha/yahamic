import Testing
@testable import YahaDesk

@Test func pausedWinsOverConnectionState() {
    var mic = MicDevice()
    mic.state.connected = true
    mic.paused = true
    #expect(mic.statusLine.hasPrefix("已暂时断开"))
    mic.paused = false
    #expect(mic.statusLine.hasPrefix("在线") || mic.statusLine.hasPrefix("送声"))
}

@Test func lostPairingTellsUserToRemoveDeviceInSystemSettings() {
    var mic = MicDevice()
    mic.state.pairingLost = true
    #expect(mic.statusLine.contains("系统蓝牙设置"))
    mic.paused = true
    #expect(mic.statusLine.hasPrefix("已暂时断开"))
}

@Test func batteryShowsOnlyWhileOnlineAndPicksQuarterSymbols() {
    var mic = MicDevice()
    mic.state.cloud.battery = 60
    #expect(mic.battery == nil)
    mic.state.connected = true
    #expect(mic.battery?.text == "60%" && mic.battery?.symbol == "battery.50percent")
    mic.state.cloud.battery = 5
    #expect(mic.battery?.symbol == "battery.0percent" && mic.battery?.low == true)
    mic.state.cloud.charging = true
    #expect(mic.battery?.text == "充电 5%" && mic.battery?.symbol == "battery.100percent.bolt")
    mic.state.cloud.battery = -1
    #expect(mic.battery == nil)
    mic.state.cloud.usbPower = true
    #expect(mic.battery?.text == "外接电源")
}
