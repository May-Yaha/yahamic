// swift-tools-version:6.2
// Yaha Desk:yahadesk 桌面设备的 Mac 端(菜单栏 App):无线麦克风,并把 yahaops
// 云端的卡片与指令经 BLE 转给设备。核心能力(设备链路、音频出口、Fn 监听)在 DeskCore 库里,
// 菜单栏 App(YahaDesk)基于它。
// 依赖方向:YahaDesk → DeskCore → DeskProtocol(纯逻辑,可单测), COpus。
import PackageDescription

let package = Package(
    name: "yahadesk",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "YahaDesk", targets: ["YahaDesk"]),
        .library(name: "DeskCore", targets: ["DeskCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: []),
        .package(
            url: "https://github.com/TypeWhisper/mlx-audio-swift.git",
            revision: "1fb13b441c1ad8aae4a23f6a2223e03e5e5b1738"
        ),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.10.1"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.6"),
    ],
    targets: [
        // libopus:没有 pkg-config,头文件自带最小声明(shim.h),静态库见 DeskCore。
        .systemLibrary(name: "COpus", path: "Sources/COpus"),
        .target(name: "DeskProtocol", path: "Sources/DeskProtocol"),
        .target(
            name: "DeskCore",
            dependencies: ["DeskProtocol", "COpus"],
            path: "Sources/DeskCore",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices"),
                // 静态链接 libopus(Homebrew,arm64):发布产物不依赖本机 Homebrew。
                .unsafeFlags(["/opt/homebrew/lib/libopus.a"]),
            ]
        ),
        .executableTarget(
            name: "YahaDesk",
            dependencies: [
                "DeskCore",
                "DeskProtocol",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
            ],
            path: "Sources/YahaDesk",
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("WebKit"),
            ]
        ),
        .testTarget(
            name: "DeskProtocolTests",
            dependencies: ["DeskProtocol", "DeskCore"],
            path: "Tests/DeskProtocolTests"
        ),
        .testTarget(
            name: "YahaDeskTests",
            dependencies: [
                "YahaDesk",
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
            ],
            path: "Tests/YahaDeskTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
