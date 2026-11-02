# yahamic — Mac mini 的无线麦克风

一块约 ¥250 的 [Waveshare ESP32-S3-Touch-AMOLED-2.16](https://www.waveshare.com/ESP32-S3-Touch-AMOLED-2.16)
开发板,刷上本仓库的固件,就变成 Mac mini 的**无线麦克风**:开机就用蓝牙(BLE)广播,
Mac 上的 Yaha 家居 App 自动连上,Mac 上多出一个叫 "BlackHole 2ch" 的麦克风输入,任何
应用(备忘录听写、Zoom、FaceTime、QuickTime……)都能选它。不用配网,首次连接按设备
屏幕上的 6 位数字在 Mac 上配对一次即可。板上按键是**硬件静音**:按下后采集直接关闭,
一比特音频都不会离开设备。

工程基于开源项目 [OpenCharm](https://github.com/opencharm-labs/opencharm)(给 AI
代理做"身体"的开源硬件项目,同样使用这块板子):板级驱动与构建配置继承自它;
音频链路按"纯麦克风"重新设计。感谢 OpenCharm 与
xiaozhi-esp32(见 [LICENSES/THIRD_PARTY_NOTICES.md](LICENSES/THIRD_PARTY_NOTICES.md))。

```
┌─────────────────────────┐   BLE GATT(加密)     ┌──────────────────────────┐
│  设备(ESP32-S3 板)      │  16 kHz Opus notify  │  Mac                     │
│                         │ ───────────────────▶ │                          │
│  ES7210 麦克风           │   60 ms 帧,按 MTU 分片 │  Yaha 家居(菜单栏 App)  │
│  按键:短按静音           │   + 静音状态          │   │ 解码、预缓冲、重采样    │
│  屏幕:配对数字 / 讲话中 │ ◀─────────────────── │   ▼                      │
│                         │   静音指令 / 仪表盘    │  BlackHole(虚拟麦克风)   │
└─────────────────────────┘                       │   ▲                      │
   发现:设备广播 yahamic service UUID              │  任何应用选它当麦克风输入  │
                                                   └──────────────────────────┘
```

## 为什么是 App 自己连 BLE,而不是系统蓝牙麦克风

ESP32-S3 只有 BLE,没有经典蓝牙,做不了 macOS 认的 HFP/A2DP 麦克风;macOS 也不接受
BLE 音频设备。所以不走系统音频协议:设备把 Opus 帧当普通 GATT 数据 notify 出来,
Yaha 家居收下解码后写进 BlackHole,系统里看到的麦克风是 BlackHole。

| | BLE 直连(0.5.0 起) | Wi-Fi + UDP(0.4.0 及以前) |
|---|---|---|
| 首次使用 | 系统蓝牙配对:设备显示 6 位数,Mac 弹框输入 | 手机连热点配网 + 两端填配对码 |
| 链路安全 | LE Secure Connections + MITM 认证,系统管理密钥 | 应用层 PBKDF2 + ChaCha20-Poly1305 |
| 带宽 | Opus 32 kbps ≈ 4 KB/s,BLE 余量很大 | 同左 |
| 距离 | 室内约 10 米 | 整个局域网 |

需要跨房间使用时可以回到 0.4.0(提交 `dda76aa`,协议 v2)。

## 硬件清单

| 物品 | 说明 | 参考价 |
|---|---|---|
| Waveshare ESP32-S3-Touch-AMOLED-2.16 | 与 OpenCharm 相同的参考板:ESP32-S3R8(8 MB PSRAM / 16 MB flash)、ES7210 双麦克风、ES8311 扬声器、2.16″ 圆屏、按键 | 约 ¥230 |
| USB-C 数据线 | 供电 + 刷机(板上的 USB 口就是 ESP32-S3 自带的 USB-Serial/JTAG,日志也从这里出) | — |
| (可选)3.7 V 锂电池 | 板载 MX1.25 电池接口 + AXP2101 电源管理,屏幕会显示电量 | — |

不需要扬声器、不需要外壳也能用(不过 OpenCharm 的 [3D 打印外壳](https://github.com/opencharm-labs/opencharm)
可以直接复用)。

## 目录结构

```
yahamic/
├── firmware/                 # ESP32-S3 固件(ESP-IDF 6.1)
│   ├── main/
│   │   ├── main.cpp          # 30 Hz 主循环:按键(静音)、屏幕、状态日志
│   │   ├── audio.{h,cpp}     # ES7210 采集,16 kHz 单声道,60 ms Opus 帧(CBR)
│   │   ├── uplink.{h,cpp}    # BLE GATT 外设(NimBLE):广播、配对、audio 分片 notify、静音/仪表盘
│   │   ├── mic_state.{h,cpp} # 静音唯一入口(按键 / Mac 遥控 / 断链)
│   │   ├── board*.{h,cpp}    # CO5300 屏幕、LVGL 渲染、按键、I2C
│   │   ├── power.{h,cpp}     # AXP2101 电量读数 + 打开麦克风供电
│   │   └── generated/fonts/  # 屏幕中文字体子集(tools/make_fonts.sh 生成)
│   ├── sdkconfig.defaults / partitions.csv / CMakeLists.txt
│   └── main/Kconfig.projbuild          # CONFIG_YAHAMIC_SELFTEST(台架自检)
├── mac/                      # Yaha 家居菜单栏 App(Swift 6.2+,macOS 26)
│   ├── Sources/COpus/        # libopus 的系统库模块
│   ├── Sources/YahamicProtocol/  # 纯逻辑:GATT UUID、audio 分片重组、写入载荷、key value 行(可单测)
│   ├── Sources/YahamicCore/  # Link(CoreBluetooth 链路/Opus)、Audio、Input(Fn)、Metrics
│   ├── Sources/YahaHome/     # 菜单栏 App:App / Model / Services(控制接口、BlackHole 安装)/ Views
│   └── Tests/YahamicProtocolTests/
├── agent/                    # 研发 agent(Node)
├── docs/architecture.md      # 模块图、依赖方向、协议 v3 时序
└── LICENSES/THIRD_PARTY_NOTICES.md
```

## 快速开始

### 1. Mac 端:Yaha 家居菜单栏 App

需要 macOS 26 与 Xcode 26(Swift 6.2+),以及 libopus(`brew install opus`)。

```bash
# 打包并安装 Yaha 家居(菜单栏 App,无 Dock 图标)
cd mac && ./scripts/make-app.sh --install
```

首次启动系统会问是否允许 Yaha 家居使用蓝牙,选允许(之后在 系统设置 → 隐私与安全性
→ 蓝牙 里管理)。

虚拟麦克风用 BlackHole 2ch(把它想成"一根环回音频线")。没装时面板会出现
「安装 BlackHole」卡片:**一键安装**直接下载官方 pkg(校验 sha256)并弹管理员授权,
不需要 Homebrew;也可以复制终端命令自己装(有 Homebrew 时是
`brew install blackhole-2ch`)。装完若 CoreAudio 里看不到:`sudo killall coreaudiod`。

顶栏出现麦克风图标即运行中:**划线线框 = 设备离线,实心划线 = 在线静音,实心 = 送声**。
点开是控制面板:设备卡片(状态、电平、蓝牙信号、开麦/静音)、「按住 Fn 讲话」开关、
输出设备选择、**开机自启**、日志。首次使用系统会弹「辅助功能」授权(监听 Fn 要用),
到 系统设置 → 隐私与安全性 → 辅助功能 勾选 Yaha 家居即可。日志在
`~/Library/Logs/YahaHome.log`。

> 它是你家庭智能硬件的 Mac 端控制中心:`mac/Sources/YahaHome/Model/HomeDevice.swift` 定义了
> 设备抽象,接新硬件 = 新增一个遵守 `HomeDevice` 的模型 + 一张卡片视图。核心能力
> (设备链路、音频出口、Fn 监听)在 `YahamicCore` 库里。

### 2. 固件构建与刷写

需要 [ESP-IDF 6.1](https://docs.espressif.com/projects/esp-idf/zh_CN/latest/esp32s3/get-started/index.html):

```bash
cd firmware
idf.py set-target esp32s3     # 首次
idf.py build
idf.py flash monitor          # 板子接 USB-C;Ctrl+] 退出日志
```

从 0.4.0 升级时先删掉旧的 `firmware/sdkconfig`(Wi-Fi 配置不再需要),让新的
`sdkconfig.defaults` 生效。

台架自检(不连 Mac,采 1 秒打印响度,确认麦克风链路):
`idf.py menuconfig` → Yahamic → 开启 `开机自检`,重新刷写。

### 3. 蓝牙配对(只用一次)

1. 设备上电即广播 `yahamic-XXXX`(XXXX 为蓝牙 MAC 后两字节),Yaha 家居发现后自动连接。
2. 首次连接时设备屏幕变橙,显示 6 位数字和 `PAIR ON MAC`;Mac 弹出系统配对框,输入这 6 位数。
3. 配对完成后屏幕转为静音待命。配对信息两端都会记住(设备存 NVS),以后开机自动重连。

换 Mac 或设备重刷过 NVS 后连不上:在 系统设置 → 蓝牙 里对 yahamic「忽略此设备」,再重连一次走配对。

### 4. 用起来

- 设备屏幕变绿 `ON AIR` = 正在送声。打开 系统设置 → 声音 → 输入,选
  **BlackHole 2ch**;或在 Zoom/QuickTime 等应用里选它。
- **短按按键**:硬件静音(屏幕红 `MUTED`,采集关闭),再按恢复。
- 屏幕底部常显:电量和蓝牙信号(`BLE -55DB`);未连接时显示 `ADV`(广播中)。
- 走出蓝牙范围或 Mac 关蓝牙时设备自动静音,回来后自动重连。

## 压测结论与性能账本(2026-11-01)

双端修复后 600 秒全链路压测(扬声器持续播放语音、麦克风常开,60 ms Opus):

- **收音链路**:平均 16、最低 14 帧/s;10384 个音频包全部解码入队,欠载仅 4 次、
  丢帧/溢出/解码错误均为 0;缓冲平均 112.2 ms。Mac 开播与断供恢复使用 120 ms
  预缓冲,松 Fn 后保留并自然播完话尾,静音空转不再累计虚假欠载。
- **BlackHole 系统出口**:FFmpeg 实录到 48 kHz PCM,峰值 -27.6 dB;原始流录制
  也已修正为解码后的 16 kHz PCM,5 秒样本数与 WAV 时长一致。
- **波形渲染**:25.6–26.2 fps(优化前 13.3–13.7),单帧约 25 ms(此前约 50 ms),
  传屏约 17.2 ms;采集间隔保持 59–60 ms。频谱重心会驱动波形流速与空间周期,
  非录音状态则显示麦克风图标、连接/静音状态和操作提示。

渲染性能的关键措施(全部实测验证):

1. 主循环睡**剩余时间**,波形直接画进内部 DMA 缓冲,主任务钉 CPU1;
2. 快照里的慢查询按 TTL 缓存,电池读取放独立低优先级任务;
3. 正弦与包络使用查找表,相位按真实时间连续累进,热路径不再逐列计算三角函数;
4. 柔光与亮芯合并为单遍距离梯度绘制;DMA 单缓冲继续按需清底,避免残影。

固件状态日志每 10 秒打印:`渲染 N fps(帧 X ms,传屏 Y ms) | 采集 avg/min/max ms`,
以后性能回退一眼可见。豆包输入法的文字级听写重复仍需在该应用内复验,不能用
网络指标替代这一结论。

## 压力测试报告

完整压测报告(音频链路/渲染/采集/听写问题定位/UI 验收)见
[docs/stress-report-2026-11-01.md](docs/stress-report-2026-11-01.md),全部数据经
控制接口自动采集。控制接口另有 `dump` 命令:设备经串口回传一帧降采样屏幕,
可远程"看"设备 UI(固件日志输出 SCR 行,`firmware/tools` 侧可重建 PNG)。

## 本机控制接口(压测与远程排障)

App 内置本机控制接口:Unix socket `~/Library/Application Support/YahaHome/control.sock`
(目录 0700、socket 0600,并用 `getpeereid` 校验同一用户),每行一个 JSON 请求、一行
JSON 回复;单行上限 64 KB、最多 4 个并发连接、5 秒读超时。命令处理见
`mac/Sources/YahaHome/Services/ControlServer.swift` 与 `Model/HomeModel+Control.swift`:

```bash
printf '{"cmd":"status"}\n' | nc -U ~/Library/Application\ Support/YahaHome/control.sock
```


| 命令 | 作用 |
|---|---|
| `status` | 全量状态(在线/静音/电平/帧率/缓冲/Fn 权限…) |
| `set_mute` | 遥控静音/开麦 |
| `set_ptt` | 切换「按住 Fn 讲话」/常开模式 |
| `devices` / `logs` | 输出设备列表 / 运行日志 |
| `metrics` | 采样 N 秒流指标(不动状态) |
| `stress` | **端到端压测**:自动常开麦克风(+可选 TTS 音源)采样 N 秒,结束恢复原状态,返回帧率/丢帧/缓冲/电平汇总 |
| `dump` / `capture` | 屏幕帧回传 / 诊断录制 |

(2026-11-01 起随包的 MCP 桥 `yahamic-mcp` 已移除;需要 AI 代理控制时直接连 control.sock 即可。)

## 设备屏幕的中文

设备不跑字库:屏幕上的中文短语(讲话中 / 已静音 / 寻找 Mac 中……)用 **Noto Sans CJK SC**
(SIL OFL 1.1)子集化成 LVGL 字体,由 `firmware/tools/make_fonts.sh` 生成到
`main/generated/fonts/`(生成的 .c 已提交,日常构建不需要字体文件)。要加/改文案,
按脚本头部的说明改短语表再重新生成。动态文本(配对数字、电量、信号)用内置 ASCII 点阵。

## 协议 v3(设备 ⇄ Mac,BLE GATT)

v3 与 v2 不兼容:Mac(0.5.0)与固件(0.5.0)要一起升级。时序图与模块关系见
[docs/architecture.md](docs/architecture.md);实现在 `firmware/main/uplink.cpp` 与
`mac/Sources/YahamicProtocol/Wire.swift`、`mac/Sources/YahamicCore/Link/Uplink.swift`。

一个自定义 service,UUID 为 `6B96000N-2D78-4CE2-963A-884ED7A5150C`(N = 1 是 service,
2–6 是特征)。设备主广播包放 service UUID,扫描响应放名字 `yahamic-XXXX`;只允许一个连接。
多字节字段都是小端。

| N | 特征 | 属性 | 内容 |
|---|---|---|---|
| 2 | info | read | `fw 0.5.0\nrate 16000\nframe 60\ncodec opus\n`(key value 行) |
| 3 | audio | notify | `seq u16 ‖ frag u8 ‖ Opus 分片`;frag 低 7 位为片序号,bit7 = 末片;每片最多 MTU−6 字节 |
| 4 | status | read + notify | `muted u8`,变化时通知 |
| 5 | control | write | `01 muted` 设静音;`02` 请求屏幕回传 |
| 6 | dashboard | write without response | 10 字节:`epoch u32`(UTC 秒)+ `tz i16`(分钟)+ `cpu/mem/mouse_batt/kb_batt u8`;无效字段 255,数据不新鲜时设备回退静音屏 |

- 音频:16 kHz 单声道 Opus,32 kbps CBR,60 ms 一帧(240 字节),MTU 247 时一帧两片。
  静音且淡出结束后不发。
- notify 在链路层可靠有序,所以没有保活、重传和重放窗口。帧只会在设备发送队列满时整帧
  丢掉(余下分片不发),Mac 按 seq 跳号计入丢帧,不补静音。设备的 seq 跨连接不归零,
  Mac 每次连上都重置重组状态。
- 连接后设备主动发起加密,并请求 15–30 ms 连接间隔。Mac 订阅 audio 后写一次当前期望的
  静音状态(按住 Fn 模式为静音,常开模式为开麦)。设备开机默认静音,断链自动静音。

Yaha 家居默认以 120 ms 为预缓冲与漂移校正目标;渲染端按缓冲水位做 ±0.5% 内的时钟漂移
微调。链路断开后 Mac 一直挂着连接请求,设备回到范围内由系统自动连上。

## 安全模型

链路安全全部交给蓝牙控制器:LE Secure Connections(ECDH P-256)+ MITM 认证 + bonding。

- **全部特征要求加密且已认证**(`READ/WRITE/NOTIFY_*_ENC | *_AUTHEN`)。未配对的 central
  (例如别人的手机)能看到广播,但读不到 info/status、订阅不了 audio、写不进静音和仪表盘。
- **配对用 passkey entry**:设备 IO 能力为 DisplayOnly,每次配对随机生成 6 位数只显示在
  屏幕上(不进日志),Mac 输入后完成认证,防止中间人;
  要配对就得看得到设备屏幕。关掉了 legacy pairing。
- 如果加密完成但没有 MITM 认证(对端用 Just Works),设备立即断开。
- bond 密钥设备存 NVS、Mac 存系统钥匙串;Mac 删掉配对后再连,设备删旧 bond 重新配对。
- 本机控制接口只对当前用户开放(见上文)。

## 已验证 / 未验证

**已验证(2026-11-01,协议 v1 / Wi-Fi,ESP-IDF 6.1 + macOS 26 + 真机端到端):**

- 固件与 Mac 构建、刷写和设备重连;ES7210 以 16 kHz/60 ms 采集并经 Opus 发送,
  屏幕、电量、按键硬件静音正常。
- 端到端:配网 → mDNS/静态地址发现 → 握手 → 解码与预缓冲 → BlackHole 2ch;
  180 秒连续语音欠载/溢出/解码错误均为 0,FFmpeg 能从 BlackHole 录到真实音频。
- Mac 控制接口 100 次请求失败 0;Fn 事件、1 秒粒度静音切换、App 重启自动恢复、
  解码后 PCM WAV 录制均通过实测。
- 设备波形真机达到 24.3–24.8 fps,采集间隔保持 59–60 ms。

**未验证 / 已知事项:**

- 协议 v3(0.5.0,BLE):Mac `swift build`/`swift test` 与固件构建通过;真机配对、压测、
  断链重连与长静音回归待复验。上面的「已验证」条目和前文压测数据都来自 Wi-Fi 版本。
- 设备只接受一个连接:Mac 不在线时,别的设备连上会占住链路(配不上对就一直停在配对屏),
  断开后恢复广播。

- 豆包输入法内的文字级听写重复:已验证 Fn 到 BlackHole 的链路,仍需在豆包中
  做人工听写复验,不能仅凭音频指标宣称完全解决。
- 讲话键:Apple 键盘/妙控键盘用 Fn;HHKB 等键盘的 Fn 在键盘固件里处理、不上报 macOS,
  在面板「讲话键」里改成右 Option / 右 Command / 右 Control(只认右侧那颗)。

**配合豆包 / 微信输入法听写**:面板「听写输入法」点「接入豆包」或「接入微信」,会把系统默认
输入切到 BlackHole 2ch(微信输入法只认系统默认输入),并打开该输入法的设置。设置里要手动
确认两项(输入法没有可写的配置接口):麦克风选「BlackHole 2ch」或「跟随系统」;语音快捷键
设成「长按」与 Yaha 家居相同的讲话键(HHKB 用空格右侧的 ◇,即右 Command)。按住时 Yaha 开麦、输入法开始听,
松开两边同时停。面板上有「还原系统输入」按钮;切走默认输入会让其他 App 的麦克风也变成 Yaha。
- 电池续航、超过 1 小时连续送声和实际通话时延仍未测。

**联调中踩过并修掉的坑(供后来者,含系统升级;Wi-Fi 相关几条来自 0.4.0 及以前)**:

- **Fn 键(macOS 26)不再设置 SecondaryFn 修饰位**,只以键码 63 上报——监听要同时
  覆盖 flagsChanged 与 keyDown/keyUp 的键码 63(mac/Sources/YahamicCore/FnListener.swift)。
- **CGEventTap 用 `.cghidEventTap + listenOnly` 出现过"创建成功但零事件"** → 改
  `.cgSessionEventTap + defaultTap`(回调须原样返回事件);C 回调不捕获上下文,
  监听器实例必须全局持有(if-let 块内释放 = 野指针 = bus error)。
- **系统升级产生"僵尸辅助功能授权"**(查询 true、事件不放行,设置里也没有条目)
  → `tccutil reset Accessibility com.yaha.home` 重置后由 App 重新申请;App 内每
  2 秒轮询 `AXIsProcessTrusted()`,缺权限自动弹系统确认框、授权后自动恢复。
- **ad-hoc 签名每次重打包丢授权** → 打包脚本自动检测并用 Xcode 的 Apple
  Development 证书签名。
- **系统升级后 coreaudiod 不重载 HAL 插件**(BlackHole 文件在但设备消失)
  → `sudo killall coreaudiod`。
- **固件 `SO_RCVTIMEO` 必须传 `struct timeval`**——传 `int 200` 会被当成 200 秒,
  worker 假死,表现为 daemon 重启后设备再也连不上。
- **ESP32 流式音频必须 `esp_wifi_set_ps(WIFI_PS_NONE)`**:默认省电按信标缓冲,
  音频周期性卡顿,语音转写端表现为"整句重复"。
- daemon 的 `handleHello` 若对任何来源刷新"最后活跃时间",重连设备会被自己的
  hello 永远拒之门外:同名设备(名字含 MAC)直接接管。
- 纯命令行进程里 NSEvent 全局监听不触发(要 NSApplication 事件循环)。
- SDK 改名:`CGEvent.getIntegerValue` → `getIntegerValueField`。

## 使用速查

- **按住 Fn**:讲话(设备屏幕绿「讲话中」+ 流动的正弦声波);松开:静音(红色麦克风图标)
- 讲话动效可选:`idf.py menuconfig` → Yahamic → 「讲话时的屏幕动效」,正弦声波(默认)
  或频谱柱;声波随音量起伏,并由频谱重心驱动流速与周期,带柔光描边
- **空闲/离线**:显示麦克风图标与连接状态;录音时才切换为实时波形
- **设备短按按键**:同样的静音开关
- 屏幕底部:电量与蓝牙信号;配对屏:6 位配对数字

## 故障排查

| 症状 | 处置 |
|---|---|
| 屏幕一直 `寻找 Mac 中`,底部 `ADV` | Yaha 家居在运行吗?系统设置 → 隐私与安全性 → 蓝牙 里允许了吗?Mac 蓝牙开着吗?靠近一些 |
| App 日志「蓝牙权限」警告 | 系统设置 → 隐私与安全性 → 蓝牙,打开 Yaha 家居 |
| 一直不出配对框 / 日志「读取失败」「订阅失败」 | 设备重刷过或 Mac 换过:系统设置 → 蓝牙 里忽略 yahamic,再等它重连配对 |
| 屏幕停在橙色配对数字 | Mac 上的系统配对框被关掉了:断电重启设备再配一次 |
| 应用里没有 BlackHole 2ch | 面板「安装 BlackHole」一键安装,或 `brew install blackhole-2ch`;仍看不到就 `sudo killall coreaudiod` |
| 声音卡顿 | 靠近 Mac、避开金属遮挡;控制接口 `status` 看 `rssi` 与 `droppedFrames`,`stress 60` 复现 |

## 产品演进:从无线麦克风到个人智能中枢

- **当前可用**:ESP32 无线麦克风、Fn 对讲、硬件静音、Yaha 家居菜单栏控制、
  BlackHole 系统输入、蓝牙自动重连、PCM 诊断与可重复压力测试。
- **下一阶段(Mac 中枢)**:以 `HomeDevice` 统一接入更多设备,补齐设备分组、
  连接质量展示、事件通知、场景开关和本地自动化;控制接口保持仅本用户可连。
- **再往后(智能能力)**:在稳定音频入口上增加本地语音指令、设备联动与个人任务
  自动化;按需增加 24 kHz 音质档(BLE 2M PHY 余量足够)和其它麦克风板子。
- **安全基础**:智能中枢的设备权限、日志与语音数据默认留在本机。

## 许可证

本仓库代码:MIT(见 [LICENSE](LICENSE))。第三方组件见
[LICENSES/THIRD_PARTY_NOTICES.md](LICENSES/THIRD_PARTY_NOTICES.md)。
本项目与 OpenCharm、Waveshare、Espressif、Apple 无隶属关系。
