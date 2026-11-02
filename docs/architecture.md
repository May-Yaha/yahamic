# Yahamic 架构

三部分:ESP32-S3 固件(`firmware/`)、Mac 端 SwiftPM 包(`mac/`)、研发 agent(`agent/`)。
设备与 Mac 走 BLE GATT 直连,协议规范在 README「协议 v3」一节,本文只讲模块边界与时序。

## Mac(`mac/`,macOS 26,Swift 6.2)

```
YahaHome(菜单栏 App)──▶ YahamicCore ──▶ YahamicProtocol
                              │
                              └──▶ COpus(系统库 libopus)
```

| 模块 | 职责 | 约束 |
|---|---|---|
| `YahamicProtocol` | `Wire`(GATT UUID、control/dashboard 载荷)、`FrameAssembler`(audio 分片重组、跳号计数)、`Fields`(`key value` 行) | 纯逻辑,无 I/O,不依赖其他模块;全部在 `Tests/YahamicProtocolTests` 单测 |
| `COpus` | libopus 的 modulemap + shim | 只做 C 接口桥接 |
| `YahamicCore/Link` | `Uplink`(CoreBluetooth central:扫描、连接、订阅、写入)、`OpusDecoder` | `CBCentralManager` 的回调与 `Uplink` 的状态都在它自己的串行 queue 上 |
| `YahamicCore/Audio` | `JitterBuffer`、`AudioSink`(渲染到 BlackHole)、`Devices`(设备与采样率监听) | render 回调每次只加一次锁 |
| `YahamicCore/Input` | `FnListener`(CGEventTap) | |
| `YahamicCore/Metrics` | `MetricsCollector`(dashboard 特征的数据源) | |
| `YahaHome/Model` | `HomeModel`(生命周期、设置)、`+Control`(控制命令分发)、`+Diagnostics`(capture/metrics/stress) | `@MainActor` |
| `YahaHome/Services` | `ControlServer`(Unix socket 0600)、`BlackHoleSetup` | |
| `YahaHome/Views` | 面板卡片 | 只读 `HomeModel` |

`Uplink` 记住上次连上的 peripheral(UserDefaults `yahamic.peripheral`),启动时优先连它;
它 5 秒没连上才换成新发现的设备。断开后立即再挂一个 `connect`,设备回到范围内由系统连上。
音频路径:`FrameAssembler → OpusDecoder → JitterBuffer → AudioSink`。

## 固件(`firmware/main/`,ESP-IDF 6.1)

| 文件 | 职责 |
|---|---|
| `uplink.{h,cpp}` | NimBLE 外设:广播、配对(passkey 上屏)、GATT 读写、audio 分片 notify、RSSI |
| `mic_state.{h,cpp}` | 静音唯一入口 `mic::set_muted / toggle`,串起 `audio` 与 `uplink` |
| `audio.{h,cpp}` | ES7210 采集、Opus 编码(CBR)、静音淡出、频谱 |
| `board*`、`power.*` | 屏幕、按键、AXP2101 电源 |
| `main.cpp` | 组装模块、屏幕状态合成(`compose`) |

线程:NimBLE host 任务写连接状态(原子量);采集线程调 `send_audio` 直接 notify;
主循环拉 `snapshot()` / `dashboard()`。锁顺序:`mic` 的 mutex → `uplink` 的 `dash_lock`。
`on_remote_mute` 在 host 任务里回调,回调时不持 `uplink` 的任何锁。

链路阶段(`Snapshot.phase`):`advertising → connected → pairing(passkey 非 0)→ live`
(已加密认证且订阅了 audio)。断开即静音、清仪表盘、重新广播。

## 协议 v3 时序

```
设备                                         Mac
 │ 广播 service UUID + 名字                   │
 │◀──────────────────────────────────────────│ connect
 │ security_initiate;请求 15–30 ms 间隔       │
 │   新 Mac:屏幕显示 6 位数 ⇄ 系统框输入      │
 │   已 bond:直接用旧密钥加密                │
 │◀──────────────────────────────────────────│ 读 info,订阅 status / audio
 │ live                                      │
 │◀──────────────────────────────────────────│ control 01 muted(当前期望的静音)
 │ audio notify(seq ‖ frag ‖ Opus 分片)       │
 │══════════════════════════════════════════▶│ 重组 → 解码 → 抖动缓冲
 │ status notify(muted)                     │
 │══════════════════════════════════════════▶│
 │◀══════════════════════════════════════════│ control(Fn)/ dashboard(3 s)
```

测试:Mac `swift test` 覆盖分片重组、跳号、seq 回绕与写入载荷编码;UUID 常量要与
`uplink.cpp` 的 `YAHA_UUID` 一致(测试里有一条固定值断言)。

## Agent(`agent/`)

Node 图工作流:`kernel/`(配置、运行时、锁、journal)、`graphs/`、`plugins/`
(router、执行者、verifier)、`mcp-server.mjs`。验证命令在 `agent.json`
(缺省回退 `agent.example.json`),相对路径按仓库根目录解析。
