// swift-tools-version:6.2
// macOS 与 iOS 两端共用的 Swift 代码:
//   DeskProtocol:BLE 线格式、配网、Ogg Opus 等纯逻辑(可单测,测试在 ../macos/Tests)。
//   DeskShared:网盘登录/文件、DMS、云端授权、录音回放与 AI 整理等两端都用的服务和视图。
// Android 不复用这里的代码,与固件、Mac 对齐的是 BLE 协议本身(README 协议表)。
import PackageDescription

let package = Package(
    name: "shared",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "DeskProtocol", targets: ["DeskProtocol"]),
        .library(name: "DeskShared", targets: ["DeskShared"]),
    ],
    targets: [
        .target(name: "DeskProtocol", path: "Sources/DeskProtocol"),
        .target(name: "DeskShared", dependencies: ["DeskProtocol"], path: "Sources/DeskShared"),
    ],
    swiftLanguageModes: [.v5]
)
