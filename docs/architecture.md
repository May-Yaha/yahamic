# Yahamic 架构

三部分:ESP32-S3 固件(`firmware/`)、Mac 端 SwiftPM 包(`mac/`)、研发 agent(`agent/`)。
线上协议的规范在 README「协议 v2」一节,本文只讲模块边界与时序。

## Mac(`mac/`,macOS 26,Swift 6.2)

```
YahaHome(菜单栏 App)──┐
                      ├──▶ YahamicCore ──▶ YahamicProtocol
yahamicd(命令行)──────┘          │
                                 └──▶ COpus(系统库 libopus,pkg-config)
```

| 模块 | 职责 | 约束 |
|---|---|---|
| `YahamicProtocol` | `Wire`(12 字节头)、`Fields`(`key value` 行)、`SessionCrypto`(PBKDF2/HMAC/ChaChaPoly)、`SeqTracker`(去重/迟到/重置) | 纯逻辑,无 I/O,不依赖其他模块;全部在 `Tests/YahamicProtocolTests` 单测 |
| `COpus` | libopus 的 modulemap + shim | 只做 C 接口桥接 |
| `YahamicCore/Transport` | `UdpTransport`(BSD socket + dispatch source)、`Bonjour`(dnssd 注册) | fd 在 source 的 cancel handler 里关 |
| `YahamicCore/Link` | `Uplink`(握手与会话状态机)、`OpusDecoder` | `Uplink` 的状态只在它自己的串行 queue 上读写 |
| `YahamicCore/Audio` | `JitterBuffer`、`AudioSink`(渲染到 BlackHole)、`Devices`(设备与采样率监听) | render 回调每次只加一次锁 |
| `YahamicCore/Input` | `FnListener`(CGEventTap) | |
| `YahamicCore/Metrics` | `MetricsCollector`(仪表盘 type 7 的数据源) | |
| `YahaHome/Model` | `HomeModel`(生命周期、设置)、`+Control`(控制命令分发)、`+Diagnostics`(capture/metrics/stress)、`Pairing`(配对码生成与钥匙串) | `@MainActor` |
| `YahaHome/Services` | `ControlServer`(Unix socket 0600)、`BlackHoleSetup` | |
| `YahaHome/Views` | 面板卡片 | 只读 `HomeModel` |

## 固件(`firmware/main/`,ESP-IDF 6.1)

| 文件 | 职责 |
|---|---|
| `protocol.{h,cpp}` | 头部编解码、`field()`、配对码校验、v2 密码学(PSA)、开机自检。不碰 socket/Wi-Fi |
| `uplink.{h,cpp}` | Wi-Fi 事件、mDNS 发现、会话状态机(worker 任务)、发包 |
| `mic_state.{h,cpp}` | 静音唯一入口 `mic::set_muted / toggle`,串起 `audio` 与 `uplink` |
| `audio.{h,cpp}` | ES7210 采集、Opus 编码、静音淡出、频谱 |
| `board*`、`power.*` | 屏幕、按键、AXP2101 电源 |
| `main.cpp` | 组装模块、屏幕状态合成(`compose`) |

锁顺序:`mic` 的 mutex → `uplink` 的 `socket_lock`。持有 `socket_lock` 时不回调
`on_remote_mute`。

固件 worker 的阶段:`idle → discover → hello → auth → live`,被拒进入 `backoff`(5 秒),
握手 10 秒无果或 live 后 5 秒收不到包则重新发现/握手。没有有效配对码时停在 idle,
屏幕显示 `PAIRING CODE?`。

## 协议 v2 时序

```
设备                                         Mac
 │ hello  name/fw/…/dn                       │
 │──────────────────────────────────────────▶│ 生成 mn
 │          welcome ok 1/dn/mn/proof_m       │
 │◀──────────────────────────────────────────│
 │ 验证 proof_m,派生 k_d2m/k_m2d             │
 │ auth  proof_d                             │
 │──────────────────────────────────────────▶│ 验证 proof_d,建会话
 │          control(加密)muted X/cmd N      │
 │◀──────────────────────────────────────────│
 │ 进入 live                                  │
 │ audio/status(k_d2m 加密)                 │
 │══════════════════════════════════════════▶│
 │          keepalive/control/dashboard(k_m2d)│
 │◀══════════════════════════════════════════│
```

测试向量:`firmware/tools/protocol_vectors.py` 生成;Mac `swift test` 与固件
`proto::self_test()` 用同一组。改密码学任一端都要先改这个脚本。

## Agent(`agent/`)

Node 图工作流:`kernel/`(配置、运行时、锁、journal)、`graphs/`、`plugins/`
(router、执行者、verifier)、`mcp-server.mjs`。验证命令在 `agent.json`
(缺省回退 `agent.example.json`),相对路径按仓库根目录解析。
