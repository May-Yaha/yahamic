# Yaha Desk Mac 上架与 iOS App（2026-11-06）

> **2026-11-10 起已废弃 Mac App Store 渠道**：Mac 只走 GitHub Release（Developer ID + 公证），`APP_STORE` 编译分支与商店签名已删除。下文为历史记录。

## 目标与授权

用户 2026-11-06：「帮我优化一下macosapp的ui和界面，然后做到可以上架的水平，同时需要考虑一下iosapp的发布，ios的app只做录音的展示和设备的配置，比如切换wifi等这些行为，不做录音相关的，录音只适用于macos」。同日确认：

- Mac 发布渠道**两条都做**：Developer ID 签名 + 公证（官网/直接分发），以及 Mac App Store。同一份代码，商店版去掉不合规的能力。
- BLE 冲突：固件只允许一个连接（`BT_NIMBLE_MAX_CONNECTIONS=1`，`MAX_BONDS=3`），**不改固件**。iPhone 配置时由 Mac 让出连接：Mac 加「暂时断开」，iPhone 连不上时提示「请先在 Mac 上断开设备」。
- 产品对外名统一为 **Yaha Desk**；`/apps/拾见/录音` 只是已上线百度网盘应用的兼容目录，不作为 App 名称，也不迁移。
- iOS 录音：**列表 + 播放**（读上述兼容目录），不录音、不送声。
- iOS 配置：切换 Wi-Fi、网盘登录与设备绑定/解绑、设备状态查看、首次配对引导。

授权边界：上传 App Store Connect / TestFlight、提交审核、发布都是对外动作，**每次单独征得用户同意**。证书、公证凭据、Bundle ID 注册、App Store Connect 记录由用户在 Apple 后台完成（见「需要用户做的事」）。固件不改，不涉及烧录。

基线 `797a849e` 合入 main `5d3cfab8`，worktree `.claude/worktrees/antd-only-web`。

## 历史与上线检查

- [网盘设备服务与录音备份](../desk-pan-dms-2026-11-05/README.md)：Mac 网盘隐式授权、DMS 绑定、Ogg Opus 录音与 `list` 列表，iOS 复用同一套流程与 AppKey；令牌存各自钥匙串。
- [桌面 Wi-Fi 直连云端](../desk-wifi-cloud-2026-11-03/README.md)：Wi-Fi 经加密 BLE `provision` 写入；iOS 沿用同一特征与 op，不新增 op。
- [桌面设备](../desk-device-2026-11-02/README.md)：Mac 是菜单栏 App（`LSUIElement`），音频经 BlackHole 虚拟设备给听写输入法；按住讲话用全局 CGEventTap。
- 发布方式：只改 `yahaops-desk/mac/` 与新增 `yahaops-desk/ios/`，不改 API、固件、schema、部署；不进 `verify-gates.sh`，本地 `swift build`/`swift test`、`xcodebuild` 验证。商店与 TestFlight 上传需用户授权。
- 旧数据：Bundle ID `com.yaha.desk` 不变；开发版与 Developer ID 版共用钥匙串条目。商店版在沙盒容器里，读不到旧钥匙串条目、旧日志与旧录音目录，首次启动需重新登录网盘与授权（已知，不迁移）。

## 设计

### Mac 发布阻断项

- **libopus 动态链接 Homebrew**：现在的产物链接 `/opt/homebrew/opt/opus/lib/libopus.0.dylib`，别的机器打不开。改为静态链接 `/opt/homebrew/lib/libopus.a`（arm64），`otool -L` 不得出现 `/opt/homebrew`。产物只支持 Apple 芯片，与 `LSMinimumSystemVersion 26.0` 一致。
- 签名：`make-app.sh` 分三个渠道：
  - `dev`（默认）：Apple Development，便于本机开发，权限授权稳定。
  - `devid`：Developer ID Application + hardened runtime（`--options runtime --timestamp`），不需要额外 entitlements（不录本机麦克风；蓝牙只走 TCC）；有 `notarytool` 钥匙串配置 `yahadesk` 时提交公证并 staple，产出 zip。
  - `appstore`：`-Xswiftc -DAPP_STORE` 构建（独立目录 `.build-appstore`，不污染 dev 产物），嵌入 `PROFILE=` 指定的 Mac App Store 描述文件，Apple Distribution 签名 + 沙盒 `appstore.entitlements`，`productbuild` 用 3rd Party Mac Developer Installer（或 Mac Installer Distribution）证书出 `.pkg`；`BUILD_NUMBER` 每次上传递增；不自动上传。
  - 三个渠道都把 `PrivacyInfo.xcprivacy` 放进 `Contents/Resources`。
- Info.plist：删掉不用的 `NSMicrophoneUsageDescription`（App 不采集本机麦克风）；加 `LSApplicationCategoryType`（效率）、`ITSAppUsesNonExemptEncryption=false`（只用系统 TLS 与标准加密）；版权改 Zhi.AI。

### 商店版（`APP_STORE`）差异

| 能力 | Developer ID 版 | 商店版 |
| --- | --- | --- |
| 按住讲话键 | 会话层 `.defaultTap`，辅助功能 + 输入监听 | 会话层 `.listenOnly`，只要输入监听（沙盒不能申请辅助功能）；回调本来就不改事件 |
| BlackHole | 一键下载官方 pkg 并以管理员身份安装；备选终端命令 | 只给官网链接（审核 2.4.5 不许引导 sudo），安装器代码不编进商店版 |
| 日志、本机录音 | `~/Library/...` | 沙盒容器内同名路径（代码不变，`homeDirectoryForCurrentUser` 指向容器） |
| 控制接口（MCP/压测） | `control.sock` | 不启动：容器路径常超 `sun_path` 104 字节，外部脚本也进不了容器；压测用 dev/devid 版 |
| 听写输入法磁贴 | 检测 `/Library/Input Methods` | 沙盒读不到时磁贴自动不显示 |

沙盒权限：`app-sandbox`、`device.bluetooth`、`network.client`（网盘、IoT、WKWebView）。隐私清单只申报 UserDefaults（`CA92.1`）与文件时间（`C617.1`，录音补传按修改时间排序）。

### Mac UI

- 菜单面板：保留现有分区，设备卡加「暂时断开 / 恢复连接」；离线与暂停各有清楚的说明与下一步。
- 设备设置窗口：从 ScrollView + GroupBox 改为 `Form(.grouped)`，按「设备 / 网络 / 网盘 / 录音备份 / 工作台」分节；空状态用 `ContentUnavailableView`；按钮与状态有无障碍标签。

### 暂时断开（让出连接）

- Mac：`HomeModel.setLinkPaused(true)` 调 `Uplink.stop()`（停扫描、断开、释放 CBCentralManager，不再重连）；`false` 重建链路。状态不持久化，重启 App 自动连接。
- iOS：连不上设备（扫描 15 秒未发现，或连接失败）时提示「请先在 Mac 上点“暂时断开”」。

### 操作结果反馈（用户 2026-11-06 追加）

用户：「点击了推送密码呀，或者是这些相关的一些交互，都不知道成功没有」。只改 Mac，跟着设备上报的云端状态（BLE notify + 写后重读）判断结果，不改固件：

- 配网：发送 → 等 5 秒内旧网络断开 → 等 30 秒内 `wifi_connected` → 「已连上 Wi-Fi」；超时提示检查密码与 2.4 GHz。写入刚返回时 Mac 手里还是写入前的状态，所以只认「断开」这一变化，不看错误码（旧的 `sync_failed`/`reauthorize` 会造成假成功或假失败）。固件不上报断开原因，密码错和找不到网络都只能表现为超时。按住讲话键期间设备不处理配置，可能先报「没有看到设备切换网络」，松开后设备仍会应用。
- 设备授权：交付后等 10 秒内 `authorized`，再提示「正在同步工作台」；交付后断连或点取消不再显示「已取消」（授权已存进设备）。授权进度单独显示在工作台分节（`authorizationMessage`），不再与配网共用一行。
- 固件 `error` 码映射成中文下一步（`DeviceCloudState.errorMessage`），设备分节实时显示，替代原来笼统的「云端异常」。
- 进行中的操作旁显示转圈。
- 要区分「密码错 / 找不到网络」：用户同日授权改固件并烧录。云端状态加 `wifi_reason`（最近一次连接失败的 ESP-IDF `wifi_err_reason_t`，连上或收到新 Wi-Fi 设置时清 0；我方主动断开 `ASSOC_LEAVE` 不记）。Mac 只在看到它清 0 之后再认原因（之前的是旧网络的），30 秒超时时把原因写进提示：15/202/204「密码可能不对」，201「找不到这个网络」，210「加密方式不支持」，211「开放网络请留空密码，否则改用 WPA2」；其它码仍按笼统超时。原因不提前结束等待，也不在设备分节实时显示：蓝牙共存下首次握手常失败、路由器重启时也会报找不到网络，固件会继续重试，实时显示会误导用户重输正确密码。旧固件无该字段按 0 处理。

### iOS App（批 2–3）

- `yahaops-desk/ios/`，xcodegen 生成工程，iOS 26，SwiftUI。
- 共享：`DeskProtocol`（线协议、Ogg、DMS 消息）与 `DeskCore` 里与平台无关的部分（BLE 配置链路、`DmsClient`、`PanFiles`、`FactoryIdentity`）。`Uplink` 的音频部分依赖 CoreAudio HAL，iOS 不编译；拆出只做配置的 BLE 客户端，或按 `os(macOS)` 条件编译，批 2 开工时按改动量二选一。
- 网盘：同一 AppKey 通过 `pan.baidu.com/union/oauth/authorize` 做 `response_type=token` 隐式授权；不使用 OOB，直接从百度网盘 OAuth 回调 fragment 解析 `access_token` 并核对随机 `state`，令牌存 iOS 钥匙串。录音播放：`filemetas dlink=1` → 下载到缓存 → 系统 AVPlayer 播放 Ogg Opus；真机格式兼容仍需人工确认。

## 路线与状态

| 批次 | 内容 | 风险 | 状态 |
| --- | --- | --- | --- |
| 1 | Mac：libopus 静态链接、三渠道打包与权限文件、商店版差异、UI 改版、暂时断开 | 中：签名与沙盒行为只能本机部分验证 | 已推送 main；dev 版已本机重装；商店版/公证待用户证书与描述文件 |
| 2 | iOS 骨架与共享代码、首次配对引导、设备状态、切换 Wi-Fi | 中：BLE 单连接与配对 | 已实现并安装开发版；真机业务流程待人工验收 |
| 3 | iOS 网盘登录、绑定/解绑、录音列表与播放 | 中：网盘下载与 Ogg 播放 | 已实现；新版授权入口已接入，真实登录与播放待人工验收 |

## 验收点

1. `make-app.sh` 产物 `otool -L` 无 `/opt/homebrew`；在没装 Homebrew opus 的机器上能启动并送声。
2. `devid` 产物 `codesign --verify --strict` 通过、`spctl -a -vv` 显示 Developer ID 且已公证（需用户证书）。
3. `appstore` 产物沙盒运行：蓝牙连接、送声到 BlackHole、网盘登录、录音上传、按住讲话（只授权输入监听）均可用。
4. 点「暂时断开」后 Mac 不再重连，iPhone 能连上设备；点「恢复连接」后 Mac 10 秒内重新上线。
5. 设备设置窗口按节显示，未登录、未绑定、无录音时各有说明。
6. （批 2）iPhone 首次配对按 6 位数字完成；能看设备状态并切换 Wi-Fi；Mac 未让出时提示先断开。
7. （批 3）iPhone 登录网盘后能绑定/解绑设备，列出录音并播放。

## 需要用户做的事

- Apple Developer 后台创建 **Developer ID Application** 证书（钥匙串已有 Apple Development、Apple Distribution、3rd Party Mac Developer Installer）。
- 注册 Bundle ID `com.yaha.desk`（macOS）后下载 **Mac App Store 描述文件**，打包时 `PROFILE=<路径> scripts/make-app.sh appstore`。
- 公证凭据：`xcrun notarytool store-credentials yahadesk --apple-id <邮箱> --team-id BB24N2QQD3`（App 专用密码由用户输入，不经 agent）。
- 当前 iOS 开发版使用现有 Apple Development 证书和通配开发描述文件安装，Bundle ID 为 `com.yaha.desk.ios`，没有新增 Apple 后台能力。上 TestFlight / App Store 前仍需注册明确的 macOS 与 iOS Bundle ID，并在 App Store Connect 建两个 App 记录；准备截图、描述、隐私政策 URL。审核需要硬件演示视频（App 依赖 yahadesk 设备）。

## 未验证

- 商店版 `.listenOnly` 会话层 tap 能否收到 Fn（旧注释记录过 HID 层 listenOnly 零事件，会话层未测）。
- 沙盒里改系统默认输入设备（接入听写输入法）是否被允许。
- 商店审核对「需配套硬件 + 虚拟音频驱动」的接受度。
- 非 Xcode 打包的 `.pkg` 能否通过 App Store Connect 校验：Info.plist 已补 `DT*`/`BuildMachineOSBuild` 工具链字段（防 ITMS-90534），上传前先用 Transporter 校验。
- 「暂时断开」后 iPhone 能否立刻连上（`cancelPeripheralConnection` 断开物理链路的时延）。
- Yaha17 上的蓝牙首次配对、Wi-Fi 切换、百度网盘新入口真实登录、设备绑定/解绑和 Ogg Opus 播放，均需用户实际操作验收。

## 本地证据（批 1）

- `swift build`、`swift build -c release -Xswiftc -DAPP_STORE` 通过；`swift test` 49 项通过（含 `pausedWinsOverConnectionState`）。
- release 产物 `otool -L` 无 `/opt/homebrew`，`nm` 有 `_opus_*` 符号（静态链接）。
- 商店版二进制 `strings` 无 `administrator privileges`、`osascript`、`AXIsProcessTrusted`。
- `make-app.sh appstore` 构建、组装成功，缺描述文件时按预期停在签名前。
- 新上下文审查 1 轮：`setLinkPaused` 无暂停中被重连的路径；已修商店版 sudo 命令、公证跳过时产物命名、工具链字段、设置窗口暂停提示、暂停态配色、控制接口 `paused` 字段、商店版控制接口、词汇表命名。

## 本地证据（批 2–3）

- `xcodegen generate` 后，Yaha17 真机 `xcodebuild test` 全量通过；新增授权入口、Wi-Fi 配置载荷、15 秒扫描提示回归。
- 开发包内 `CFBundleDisplayName` 实测为 `Yaha Desk`，使用现有开发证书与通配描述文件覆盖安装并成功启动，Bundle ID `com.yaha.desk.ios`；未注册新 Apple 后台能力。
- 新授权 URL 回归固定为 `https://pan.baidu.com/union/oauth/authorize?response_type=token&client_id=…&redirect_uri=&state=…`；不再发送 `oob`、`scope` 或 `display`，token 只从该 HTTPS 主机与路径的 fragment 解析并校验 `state`，其它主机、HTTP、旧回调及重复参数全部拒绝。
- `swift test` 58 项、iOS 模拟器 9 项通过；iOS 与 Mac 共用的授权解析、网盘文件接口和 DMS 客户端均参与构建。网盘下载只接受百度文件域名、精确文件元数据和下载后的精确字节数，并在退出登录或播放校验失败后清理在途结果与临时文件。
