# 桌面商店上架、图标与一键安装固件（2026-11-07）

> **2026-11-10 起已废弃 Mac App Store 渠道**：Mac 只走 GitHub Release（Developer ID + 公证），`APP_STORE` 编译分支与商店签名已删除。下文为历史记录。

## 目标与授权

用户要求「全部都进行上线」：Mac 与 iOS 上 App Store、固件可分发给别人用、出 logo。用户选定图标方案 C（四环），
并要求固件「集成到 macOS App，引导用户直接一键安装」。设备身份（别人的板子能被网盘设备服务远程控制）用户指向
百度 IoT Core 文档，方案待用户决定。

不做 / 须单独授权：真机写 flash、App Store Connect 上传与送审、固件公开发布、生产数据改动；
不碰 nvs 与 fac，不复制、打印、提交实验室出厂 CA 私钥。

## 本批完成

| 项 | 实现 | 验证 |
| --- | --- | --- |
| 图标 C | `mac/scripts/make-icon.swift`（`ios` 参数出无 alpha 满幅图），`ios/Assets.xcassets` | iOS xcodebuild test 12/12 |
| 固件刷写核心 | `mac/Sources/DeskCore/Flash/`：`EspFlasher`（ROM 协议，同 esptool，不带 stub）、`SerialFlashPort`（独占打开） | `EspFlasherTests` 4 条：只写变化段、nvs/fac 不动、他项目固件须确认、连不上也复位回原程序 |
| App 入口 | 「设备设置 → 固件」：版本对比、安装按钮、进度、他项目固件确认框；`FirmwareInstaller` 后台线程跑 | 设置页静态渲染测试；全量 `swift test` 80/80 |
| 打包 | `make-app.sh` 官网/dev 版把三段固件拷进 `Resources/Firmware`，固件 `esp_app_desc.version` 须等于 App 版本 | dev 包产物含三文件 |
| 真机只读 | dry run：bootloader、分区表一致，只有程序段不同；设备复位后回原程序 0.3.0 在线 | 未写 flash |

商店版：Xcode 构建系统只认 `com.apple.security.device.usb`，没有串口沙盒权限，`#if !APP_STORE` 去掉固件区，
商店包也不带固件；商店用户的固件升级走官网版或后续 OTA。

## 真机恢复出厂与全流程（用户 11-07 授权）

| 步骤 | 结果 |
| --- | --- |
| 备份 | 0x0–0x410000 整段读出存本机 `~/esp/backup/yahadesk-XXXX-2026-11-07/`（权限 600），fac 不读不存 |
| 解绑网盘 | App「设备设置 → 解绑」，状态变「未绑定 / 已解绑网盘」 |
| 恢复出厂 | `esptool erase_region 0x0 0x410000`（5.5 s）；读回 0x0–0x20000 全 0xFF，fac 仍有 715 字节身份数据 |
| 一键安装 | 空板上 App 按钮安装 0.3.0：三段全写，3.98 MB 共 50 s，设备重启后在广播 |
| 蓝牙重配对 | 先报「Peer removed pairing information」；用户在系统设置忽略设备后重配，「上线(蓝牙已加密)」 |
| 重新安装 | 已是同版本时写入为空，界面「无需安装」 |
| Wi-Fi | 连上 <家庭 Wi-Fi>，取得 192.168.x.x |
| 网盘绑定 | register/bind/iotcorechallenge/iotcoreprovision 均 errno 0，状态「在线」 |
| 录音备份 | 绑定后讲话自动上传 `/apps/拾见/录音/2026-11-07/*.opus` |
| 设备授权 | 状态「已授权」；但提示仍显示「设备没有启用授权，请重试」（等待超时后设备才报已授权，提示未刷新） |

固件分发：用户 11-07 确认固件随 macOS 官网安装包一起发版，不另放后端、Web 或单独 OTA 服务。

版本统一：用户 11-07 要求所有端同版。固件 `PROJECT_VER`、Mac `make-app.sh VERSION`、iOS `CFBundleShortVersionString`
与 `CFBundleVersion` 均为 0.3.0；`make-app.sh` 打包前校验固件与 iOS 版本，不一致即退出。

iOS 闪退：真机点「登录 Zhi.AI」即 SIGABRT（`-[__NSCFNumber length]`，CFNetwork `initializeUserAgentString`）。
根因是 `CFBundleVersion` 写成数字 1，首个 HTTPS 请求拼 User-Agent 时崩溃；改为字符串，回归测试 `testBundleVersionsAreStrings`。

测试注意：用 pyserial 打开设备 USB 串口读日志会让设备复位（USB-Serial-JTAG 打开即拉复位线），
授权与绑定期间不要开串口监视。

## iOS 改版：以功能为导向、快速切 Wi-Fi（用户 11-07 要求）

- 版式：只用系统控件与 Dynamic Type 文字样式（HIG 8 pt 网格、SF Symbols），不自定义字号间距，跟随系统字号缩放。
- 首页：状态卡（在线/静音/Wi-Fi/Mac/上报时间）→ 常用（切换 Wi-Fi、静音、发送卡片）→ 设备与账号（设备管理、Zhi.AI、百度网盘）。
  远程控制不可用时按钮变灰，底部说明原因（未登录 / 未绑定网盘 / 网盘未登录）。
- 切换 Wi-Fi：进页即连蓝牙并扫描，下拉重扫；点网络即切，连上过的网络密码存本机钥匙串（`ThisDeviceOnly`，不同步 iCloud），
  下次点一下就连，左滑「忽略」删除；不在附近的已保存网络单独列出。不改固件（固件仍只存一个网络）。
- 蓝牙被 Mac 占用：页面提示在 Mac 上点「暂时断开」，不做挤占（需改固件）。
- 设备管理：蓝牙绑定/解绑网盘、远程解绑、清除卡片；解绑均二次确认。发卡片改为弹出表单并实时显示字节数。
- 录音：按天分组，新的在前。
- 验证：模拟器 `xcodebuild test` 15/15；真机 Debug 包已装到 iPhone，待用户实测切网与远程控制。

## 上架前审查修复（2026-11-07）

- 网盘令牌过期（`RecordingStore.token` 为 nil）时静音、卡片、绑定/解绑都提示重新登录，不拿空令牌调接口；卡片发送失败表单不关。
- 扫描以 networks 特征自带的 `scan` 序号为基线（固件初值 0），只接受更新的列表。
- 切 Wi-Fi：点当前网络给提示；切换开始即清空 `joined`，失败后回落到云端上报；已存密码连失败且原因是 15/202/204 时改问密码。
- 离开页面 `stop()` 同时清 `ready`；去掉未使用的静音特征订阅；钥匙串原地 `SecItemUpdate`，写失败不丢旧密码。
- `make-app.sh` 版本校验整串匹配固件 `PROJECT_VER` 与 iOS `project.yml`。
- iOS bundle id 改为 `com.yaha.desk`，与 Mac 共用一条 App Store 记录（通用购买）。
- 验证：iOS 模拟器 20/20，Mac `swift test` 80/80。

## App Store Connect（用户 11-07 授权，iOS + macOS）

App「Yaha Desk」（Apple ID 6831925487，SKU yaha-desk，通用购买 com.yaha.desk，简体中文）、副标题、分类效率/工具、
年龄分级 4+、免费、隐私问卷、隐私政策与技术支持页（`yahaops-web/public/desk/`）均已填。

| 项 | 状态 |
| --- | --- |
| 销售范围 | 中国大陆、香港、澳门、台湾、新加坡（用户 11-07 选择加港澳台新） |
| ICP 备案号 | 未填。提交时 Apple 不强制；用户此前「毛孩子成长史」大陆在售且未填。若因备案被拒，去掉中国大陆重提 |
| iOS 0.3.0 | 11-07 已提交，正在等待审核；1 张截屏（模拟器已登录首页，1206×2622） |
| macOS 0.3.0 | 11-07 已提交，正在等待审核；1 张截屏（离屏渲染菜单面板合成 2880×1800，终端无屏幕录制权限故不实拍） |
| 审核登录 | 未提供演示账号；网盘登录在模拟器内取消，用户 11-07 决定跳过 |

审核风险：审核员没有实体设备也没有登录账号，可能按 2.1 要求演示。被拒后由用户在 ASC 自行填写演示账号（不写进仓库）或附设备演示视频。
截屏只各 1 张，补宣传图须等下个版本，或先从审核中撤回再改。

## 未验证 / 下一步

- 设备推送卡片/日报、经网盘设备服务远程静音、iPhone 云端状态（iOS Debug 包已签名构建，待 iPhone 解锁连接后安装）。
- 授权超时后的过期提示未修。
- 审查已知小问题未修：FLASH_DATA 超时重试若旧回应迟到会错位一块，写后 MD5 校验会拦下并报失败，重装即可。
- 设备身份方案（待用户选）：a 请网盘设备服务接受 IoT Core 预配身份或代签证书；b 自建逐台签证书服务，CA 私钥只在服务端/HSM；
  c 在 App 里内置预配 TaskSecret（共享密钥，违背逐台身份，不推荐）。
- Apple 侧：等两端审核结果；过审后按「App 发布时供应」自动上架。
