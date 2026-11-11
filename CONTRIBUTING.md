# 参与贡献

欢迎提 issue 和 PR。文档与注释以中文为主,英文 issue 也可以。

第一次参与可以先看带 `good first issue` 或 `help wanted` 标签的 issue,方向参考 README 的「欢迎参与」。

## 环境

- Mac App:macOS 26、Xcode 26(Swift 6.2+)、`brew install opus`。
- 固件:ESP-IDF 6.1,硬件为 Waveshare ESP32-S3-Touch-AMOLED-2.16(乐鑫 ESP32-S3R8)。
- iOS:Xcode 26 + `xcodegen`。

## 提交前

```bash
cd apps/macos && swift build && swift test               # Mac(含 apps/shared)
cd apps/ios && xcodegen generate && xcodebuild test -scheme YahaDeskIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'                       # iOS
cd firmware && idf.py build                             # 固件(需 ESP-IDF)
```

固件纯逻辑测试见 [firmware/tests/README.md](firmware/tests/README.md)。改了版本号时,
`apps/macos/scripts/make-app.sh` 的 `VERSION`、`firmware/CMakeLists.txt` 的 `PROJECT_VER`、
`apps/ios/project.yml` 三处要一致。

## 约定

- 跟随周围代码的命名、注释密度与写法;一个 PR 做一件事。
- 提交信息用 `feat:` / `fix:` / `docs:` 等前缀。
- 不提交任何密钥、令牌、设备出厂证书或个人设备信息(MAC、串口、Wi-Fi 名)。
- 涉及 BLE 协议(`firmware/main/uplink.cpp` 与 `apps/shared/Sources/DeskProtocol/`)的改动两端一起改,并更新 README 的协议表。
- 云端相关功能依赖官方服务 `hub.flyaha.top`(见 README「云端依赖说明」),外部贡献者无法端到端验证,PR 里说明验证到哪一步即可。

贡献的代码按 GPL-3.0 授权。
