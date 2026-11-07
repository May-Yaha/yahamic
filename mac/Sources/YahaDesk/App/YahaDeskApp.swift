import AppKit
import SwiftUI

// Yaha Desk:家庭智能硬件的 Mac 端控制中心。菜单栏常驻,无 Dock 图标
// (Info.plist 里 LSUIElement = true);顶栏以桌面设备图标进入控制中心。
@main
struct YahaDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = HomeModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView()
                .environmentObject(model)
        } label: {
            Image(nsImage: menuIcon("display", red: model.isLive))
        }
        .menuBarExtraStyle(.window)
        Window("设备设置", id: "device-setup") {
            DeviceSetupView(cloud: model.cloud, recordings: model.recordings, voiceProfile: model.voiceProfile,
                            firmware: model.firmware, deviceFirmware: model.mic.state.firmware)
        }
        .defaultSize(width: 620, height: 480)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
    }

    /// 顶栏图标默认按模板图渲染(无视颜色);送声时换成非模板的红色图标。
    private func menuIcon(_ name: String, red: Bool) -> NSImage {
        let base = NSImage(systemSymbolName: name, accessibilityDescription: "Yaha Desk 设备控制中心") ?? NSImage()
        guard red, let colored = base.withSymbolConfiguration(.init(paletteColors: [.systemRed])) else {
            base.isTemplate = true
            return base
        }
        colored.isTemplate = false
        return colored
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // 菜单栏工具,不进 Dock/切换器
        HomeModel.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        HomeModel.shared.shutdown()
    }
}
