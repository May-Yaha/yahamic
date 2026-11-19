# 定位收敛:字幕录音默认备份、实验功能分组、README 拆分(2026-11-19)

## 背景

2026-11-18 定下产品定位:核心是语音输入和 AI 字幕,所有录音备份到网盘,App Store 只上架 iOS(见 [ROADMAP.md](../../../ROADMAP.md))。
用户 11-19 确认三件事:AI 字幕的录音默认备份;App Store Connect 上的旧提交可以撤回重提;提交文档并做完阶段 0 剩下的两项。

## 改动

| 项 | 改了什么 | 位置 |
| --- | --- | --- |
| 字幕录音默认备份 | `captionBackup` 没存过值时取 `true`(原来取 `false`);手动关过的保持关。没登录网盘时仍然不录(`RecordingBackup.talking` 里没有令牌就不开文件) | `apps/macos/Sources/YahaDesk/Model/HomeModel.swift` |
| 备份开关的说明 | 开着时写「播放的声音(含会议对方)与原文传到网盘」 | `Views/MenuPanelView.swift` |
| Mac 面板分组 | 「只留本人声音」从「输出」移到新的「实验功能」组;本机没装豆包输入法时,「转文字」不显示「豆包」 | `Views/MenuPanelView.swift` |
| Mac 设置侧栏 | 新增「实验功能」组,放本人声纹、标注、工作台;「语音」留离线模型、AI 润色,「云与数据」留网盘、录音 | `Views/DeviceSetupView.swift` |
| iOS 设备页 | 「发送卡片」从「常用」移到页面最后的「实验功能」组 | `apps/ios/Sources/ContentView.swift` |
| README 拆分 | 协议、压测、控制接口、工作台细节、已验证清单与踩坑移到 `docs/`,README 加「更多文档」表 | `docs/protocol.md`、`performance.md`、`control-interface.md`、`workbench.md`、`verification.md` |

协议规范的位置从 README 改到 `docs/protocol.md`,固件与 Swift 源码注释里的引用、CONTRIBUTING 一并改了(只改注释)。

## 没改

- 没登录网盘时不录音的行为不变。面板上提示登录、显示已备份与待传数量,留在 ROADMAP 阶段 1。
- iOS 首页默认声源、`PrivacyInfo.xcprivacy`、推送权限等上架准备,留在 ROADMAP「iOS 上架」。
- 字幕备份会录下会议里对方的声音。默认开是用户 11-19 的决定,开关与说明都在面板上。

## 验证

- Mac:`swift build`、`swift test`(83 + 30 项)通过;`make-app.sh --install --dmg` 已装机并产出 `YahaDesk-0.5.4.dmg`。
- iOS:`xcodegen generate` 后 `xcodebuild build-for-testing`(App 与测试)编译通过。本机没有可用的模拟器运行时,YahaDuo 未连接,测试没有跑,也没有装到真机。
- 待真机确认:新装(或没动过开关)且已登录网盘时,打开视频字幕后「备份到网盘」是开的,网盘 `录音/视频字幕` 下出现文件;没装豆包输入法的 Mac 上「转文字」只有「关 / 本地」。
