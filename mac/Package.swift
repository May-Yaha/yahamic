// swift-tools-version:6.4
// Yaha Home:家庭智能硬件的 Mac 端控制中心(菜单栏 App),第一个设备是 yahamic
// 无线麦克风。核心能力(设备链路、音频出口、Fn 监听)在 YahamicCore 库里,
// 菜单栏 App(YahaHome)与命令行工具(yahamicd)都基于它。
import PackageDescription

let package = Package(
    name: "yahamic",
    platforms: [.macOS(.v27)],
    products: [
        .executable(name: "YahaHome", targets: ["YahaHome"]),
        .executable(name: "yahamicd", targets: ["yahamicd"]),
        .library(name: "YahamicCore", targets: ["YahamicCore"]),
    ],
    targets: [
        .target(
            name: "YahamicCore",
            path: "Sources/YahamicCore",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices"),
                .unsafeFlags(["-L/opt/homebrew/lib"]),
                .linkedLibrary("opus"),
            ]
        ),
        .executableTarget(
            name: "YahaHome",
            dependencies: ["YahamicCore"],
            path: "Sources/YahaHome",
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .executableTarget(
            name: "yahamicd",
            dependencies: ["YahamicCore"],
            path: "Sources/yahamicd"
        ),
    ],
    swiftLanguageModes: [.v5]
)
