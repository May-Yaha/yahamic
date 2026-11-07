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
