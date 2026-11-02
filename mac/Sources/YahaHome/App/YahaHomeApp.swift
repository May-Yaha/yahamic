import AppKit
import SwiftUI

// Yaha 家居:家庭智能硬件的 Mac 端控制中心。菜单栏常驻,无 Dock 图标
// (Info.plist 里 LSUIElement = true);顶栏图标即麦克风状态。
@main
struct YahaHomeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = HomeModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView()
                .environmentObject(model)
        } label: {
            Image(nsImage: menuIcon(model.menuSymbol, red: model.isLive))
        }
        .menuBarExtraStyle(.window)
    }

    /// 顶栏图标默认按模板图渲染(无视颜色);送声时换成非模板的红色图标。
    private func menuIcon(_ name: String, red: Bool) -> NSImage {
        let base = NSImage(systemSymbolName: name, accessibilityDescription: "Yaha 家居") ?? NSImage()
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
