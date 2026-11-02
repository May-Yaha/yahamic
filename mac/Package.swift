// swift-tools-version:6.2
// Yaha Home:家庭智能硬件的 Mac 端控制中心(菜单栏 App),第一个设备是 yahamic
// 无线麦克风。核心能力(设备链路、音频出口、Fn 监听)在 YahamicCore 库里,
// 菜单栏 App(YahaHome)与命令行工具(yahamicd)都基于它。
// 依赖方向:YahaHome / yahamicd → YahamicCore → YahamicProtocol(纯逻辑,可单测), COpus。
import PackageDescription

let package = Package(
    name: "yahamic",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "YahaHome", targets: ["YahaHome"]),
        .executable(name: "yahamicd", targets: ["yahamicd"]),
        .library(name: "YahamicCore", targets: ["YahamicCore"]),
    ],
    targets: [
        // libopus:没有 pkg-config,头文件自带最小声明(shim.h),库路径见 YahamicCore。
        .systemLibrary(name: "COpus", path: "Sources/COpus"),
        .target(name: "YahamicProtocol", path: "Sources/YahamicProtocol"),
        .target(
            name: "YahamicCore",
            dependencies: ["YahamicProtocol", "COpus"],
            path: "Sources/YahamicCore",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices"),
                .unsafeFlags(["-L/opt/homebrew/lib"]),
            ]
        ),
        .executableTarget(
            name: "YahaHome",
            dependencies: ["YahamicCore", "YahamicProtocol"],
            path: "Sources/YahaHome",
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .executableTarget(
            name: "yahamicd",
            dependencies: ["YahamicCore", "YahamicProtocol"],
            path: "Sources/yahamicd"
        ),
        .testTarget(
            name: "YahamicProtocolTests",
            dependencies: ["YahamicProtocol"],
            path: "Tests/YahamicProtocolTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
