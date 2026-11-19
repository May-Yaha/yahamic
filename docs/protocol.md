# BLE 协议 v3(设备 ⇄ Mac)

本页是设备与 Mac 之间 BLE GATT 协议的规范;改协议时固件(`firmware/main/uplink.cpp`)与
`apps/shared/Sources/DeskProtocol/` 两端一起改,并更新这里。安全模型见 [README](../README.md#安全模型)。

## 为什么是 App 自己连 BLE,而不是系统蓝牙麦克风

ESP32-S3 只有 BLE,没有经典蓝牙,做不了 macOS 认的 HFP/A2DP 麦克风;macOS 也不接受
BLE 音频设备。所以不走系统音频协议:设备把 Opus 帧当普通 GATT 数据 notify 出来,
Yaha Desk 收下解码后写进 BlackHole,系统里看到的麦克风是 BlackHole。

| | BLE 直连(0.5.0 起) | Wi-Fi + UDP(0.4.0 及以前) |
|---|---|---|
| 首次使用 | 系统蓝牙配对:设备显示 6 位数,Mac 弹框输入 | 手机连热点配网 + 两端填配对码 |
| 链路安全 | LE Secure Connections + MITM 认证,系统管理密钥 | 应用层 PBKDF2 + ChaCha20-Poly1305 |
| 带宽 | Opus 32 kbps ≈ 4 KB/s,BLE 余量很大 | 同左 |
| 距离 | 室内约 10 米 | 整个局域网 |

需要跨房间使用时可以用 yahamic 仓库的 0.4.0(提交 `8148c98`,协议 v2)。

## 协议内容

v3 与 v2 不兼容；当前 0.2.0 在 v3 上增加能力行和特征，保留旧音频与10字节dashboard。
配网需要 0.2.0 以上固件，Mac 对缺少能力的设备显示不支持。时序图与模块关系见
[docs/architecture.md](architecture.md);实现在 `firmware/main/uplink.cpp` 与
`apps/shared/Sources/DeskProtocol/Wire.swift`、`apps/macos/Sources/DeskCore/Link/Uplink.swift`。

一个自定义 service,UUID 为 `9052000N-395E-4621-8E8C-82039EE589FC`(N = 1 是 service,
2–10 是特征;基址与 yahamic 不同,两者互不连错)。设备主广播包放 service UUID,扫描响应放名字 `yahadesk-XXXX`;只允许一个连接。
多字节字段都是小端。

| N | 特征 | 属性 | 内容 |
|---|---|---|---|
| 2 | info | read | `fw 0.2.0\nrate 16000\nframe 60\ncodec opus\ncloud 1\ndisplay 1\n`(key value 行) |
| 3 | audio | notify | `seq u16 ‖ frag u8 ‖ Opus 分片`;frag 低 7 位为片序号,bit7 = 末片;每片最多 MTU−6 字节 |
| 4 | status | read + notify | `muted u8`,变化时通知 |
| 5 | control | write | `01 muted` 设静音;`02` 请求屏幕回传 |
| 6 | dashboard | write without response | 原10字节:`epoch u32`+`tz i16`+`cpu/mem/mouse_batt/kb_batt u8`；新能力可追加Mac电量与供电状态，共12字节；未知百分比255，过期指标显示不可用 |
| 7 | card | write | 保留旧`ttl u16 ‖ title ‖ 00 ‖ body`，≤512字节，`ttl=0`清除；通知内容TTL独立于单页停留时长 |
| 8 | provision | write | ≤512字节JSON：`{op:"wifi",ssid,password}`、`{op:"grant",client_id,refresh_token}` 或 `{op:"scan"}`（请求扫描 Wi-Fi，不落盘）；要求加密与MITM |
| 9 | cloud status | read + notify | 无凭据JSON：`wifi_connected,authorized,error,wifi_scan`；`wifi_scan` 是扫描完成次数，旧固件无此键；0.2.0 固件另有 `display_revision` |
| 10 | networks | read | ≤512字节JSON：`{scan,networks:[{ssid,rssi,secure}]}`，按信号强到弱，去掉隐藏、重名、非 UTF-8 与企业认证网络；`scan` 对应 `wifi_scan` |

- 音频:16 kHz 单声道 Opus,32 kbps CBR,60 ms 一帧(240 字节),MTU 247 时一帧两片。
  静音且淡出结束后不发。
- notify 在链路层可靠有序,所以没有保活、重传和重放窗口。帧只会在设备发送队列满时整帧
  丢掉(余下分片不发),Mac 按 seq 跳号计入丢帧,不补静音。设备的 seq 跨连接不归零,
  Mac 每次连上都重置重组状态。
- 连接后设备主动发起加密,并请求 15–30 ms 连接间隔。Mac 订阅 audio 后写一次当前期望的
  静音状态(按住 Fn 模式为静音,常开模式为开麦)。设备开机默认静音,断链自动静音。
- 固件保持 ESP-IDF 默认 `WIFI_PS_MIN_MODEM`,不设 `WIFI_PS_NONE`:Wi-Fi 与 BLE 共用一个射频,
  `PS_NONE` 在繁忙 AP 上占满空口,2026-11-07 公司实测 BLE 音频 30 秒只到 27 帧;默认省电模式
  下 500/500 帧。见 `docs/archive/requirements/desk-wifi-ble-coex-2026-11-07/`。

- 手机当麦克风:iPhone 打开「手机当麦克风」后以 service N = 12(`9052000C-…`)广播,下面只挂 info、
  audio、status、control 四个特征,格式同上;info 为 `fw iPhone <版本>…`,不带 `cloud 1`。Mac 菜单「声源」选
  手机时只扫这个 service;连着设备时也留意配对过的那台 iPhone 是否在广播它,开了就自动切到手机,
  手机停止广播(断链)就切回设备;只认「新打开」(消失或 App 启动后没出现满 1 分钟再出现;启动时已在广播的不算),一直开着时在 Mac 上切回设备,
  重连或刷固件后也不会被抢回手机。写 `01 00` 时手机经 PushToTalk 开始采集(锁屏也可),`01 01` 停止;断链手机自动停。

Yaha Desk 默认以 120 ms 为预缓冲与漂移校正目标;渲染端按缓冲水位做 ±0.5% 内的时钟漂移
微调。链路断开后 Mac 一直挂着连接请求,设备回到范围内由系统自动连上。
