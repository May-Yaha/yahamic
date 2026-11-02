# yahamic — Mac mini 的无线麦克风

一块约 ¥250 的 [Waveshare ESP32-S3-Touch-AMOLED-2.16](https://www.waveshare.com/ESP32-S3-Touch-AMOLED-2.16)
开发板,刷上本仓库的固件,就变成 Mac mini 的**无线麦克风**:开机自动连上家里
Wi-Fi、自动找到你的 Mac,Mac 上多出一个叫 "BlackHole 2ch" 的麦克风输入,任何
应用(备忘录听写、Zoom、FaceTime、QuickTime……)都能选它。板上按键是**硬件
静音**——按下后采集直接关闭,一比特音频都不会离开设备。

工程基于开源项目 [OpenCharm](https://github.com/opencharm-labs/opencharm)(给 AI
代理做"身体"的开源硬件项目,同样使用这块板子):板级驱动、Wi-Fi 配网、mDNS
发现、构建配置均继承自它;音频链路按"纯麦克风"重新设计。感谢 OpenCharm 与
xiaozhi-esp32(见 [LICENSES/THIRD_PARTY_NOTICES.md](LICENSES/THIRD_PARTY_NOTICES.md))。

```
┌─────────────────────────┐    Wi-Fi / 局域网     ┌──────────────────────────┐
│  设备(ESP32-S3 板)      │  UDP, 16 kHz Opus    │  Mac                     │
│                         │ ───────────────────▶ │                          │
│  ES7210 麦克风           │   60 ms 帧 + 握手     │  yahamicd / Yaha Home    │
│  按键:短按静音           │   + 静音/保活         │   │ 解码、预缓冲、重采样    │
│  长按 5s:配网           │ ◀─────────────────── │   ▼                      │
│  屏幕:ON AIR / MUTED …  │   welcome / keepalive │  BlackHole(虚拟麦克风)   │
└─────────────────────────┘                       │   ▲                      │
   发现:设备用 mDNS 找 `_yahamic._tcp`            │  任何应用选它当麦克风输入  │
                                                   └──────────────────────────┘
```

## 为什么是 Wi-Fi,不是蓝牙

你的需求是"无线局域网**或者**蓝牙"。这个项目选 Wi-Fi,原因是硬性的:

| | Wi-Fi(本方案) | 蓝牙 |
|---|---|---|
| ESP32-S3 蓝牙能力 | Wi-Fi 完整 | **只有 BLE,没有经典蓝牙** |
| macOS 侧 | 任何虚拟麦克风方案都可用 | 麦克风需要 HFP/A2DP(经典蓝牙协议),S3 不支持;macOS 也不接受 BLE 音频设备 |
| 带宽/音质 | 16 kHz PCM 采集,Opus 32 kbps 传输,局域网压力很小 | HFP 地麦仅 8/16 kHz,还受限于不可用的协议栈 |
| 延迟 | 局域网一跳,60 ms 帧 + 120 ms 预缓冲 | (不可行) |
| 配对 | mDNS 自动发现,必填配对码(双向鉴权 + 加密) | — |

如果你手上是**原版 ESP32(带经典蓝牙)**,理论上可以做 HFP 耳麦,但 ESP-IDF
没有可用的 HFP Audio Gateway 实现,macOS 一侧也不接受 ESP32 发起的 HFP 连接,
所以没有走通的现实路径。Wi-Fi 是唯一稳妥方案。

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
│   │   ├── main.cpp          # 30 Hz 主循环:按键(静音/配网)、屏幕、状态日志
│   │   ├── audio.{h,cpp}     # ES7210 采集,16 kHz 单声道,60 ms Opus 帧
│   │   ├── uplink.{h,cpp}    # Wi-Fi + mDNS 发现 + 会话状态机(握手/音频/状态/保活)
│   │   ├── protocol.{h,cpp}  # 协议 v2 纯逻辑:报文头、key value 行、PSA 密码学、开机自检
│   │   ├── mic_state.{h,cpp} # 静音唯一入口(按键 / Mac 遥控 / 断链)
│   │   ├── board*.{h,cpp}    # CO5300 屏幕、LVGL 渲染、按键、I2C
│   │   ├── power.{h,cpp}     # AXP2101 电量读数 + 打开麦克风供电
│   │   └── generated/fonts/  # 屏幕中文字体子集(tools/make_fonts.sh 生成)
│   ├── tools/protocol_vectors.py  # 协议 v2 测试向量(Mac 单测与固件自检共用)
│   ├── components/esp-wifi-connect/   # 配网组件(78/xiaozhi 的 MIT 组件,页面换成了中文)
│   ├── sdkconfig.defaults / partitions.csv / CMakeLists.txt
│   └── main/Kconfig.projbuild          # CONFIG_YAHAMIC_SELFTEST(台架自检)
├── mac/                      # Yaha Home + yahamicd(Swift 6.2+,macOS 26)
│   ├── Sources/COpus/        # libopus 的系统库模块
│   ├── Sources/YahamicProtocol/  # 纯逻辑:报文、key value 行、序号跟踪、会话密码学(可单测)
│   ├── Sources/YahamicCore/  # Transport(UDP/Bonjour)、Link(会话/Opus)、Audio、Input(Fn)、Metrics
│   ├── Sources/YahaHome/     # 菜单栏 App:App / Model / Services(控制接口、BlackHole 安装)/ Views
│   ├── Sources/yahamicd/     # 命令行版本
│   ├── Tests/YahamicProtocolTests/
│   └── com.yaha.yahamicd.plist  # 开机常驻示例
├── agent/                    # 研发 agent(Node)
├── docs/architecture.md      # 模块图、依赖方向、协议 v2 时序
└── LICENSES/THIRD_PARTY_NOTICES.md
```

## 快速开始

### 1. Mac 端:Yaha Home 菜单栏 App(先做这步,设备开机才能找到它)

需要 macOS 26 与 Xcode 26(Swift 6.2+),以及 libopus(`brew install opus`)。

```bash
# 打包并安装 Yaha Home(菜单栏 App,无 Dock 图标)
cd mac && ./scripts/make-app.sh --install
```

虚拟麦克风用 BlackHole 2ch(把它想成"一根环回音频线")。没装时面板会出现
「安装 BlackHole」卡片:**一键安装**直接下载官方 pkg(校验 sha256)并弹管理员授权,
不需要 Homebrew;也可以复制终端命令自己装(有 Homebrew 时是
`brew install blackhole-2ch`)。装完若 CoreAudio 里看不到:`sudo killall coreaudiod`。

顶栏出现麦克风图标即运行中:**划线线框 = 设备离线,实心划线 = 在线静音,实心 = 送声**。
点开是控制面板:设备卡片(状态、电平、开麦/静音)、「按住 Fn 讲话」开关、输出设备
选择、**配对码**(首次启动自动生成并存入钥匙串,可复制、可重新生成)、**开机自启**、日志。首次使用系统会弹「辅助功能」授权(监听 Fn 要用),
到 系统设置 → 隐私与安全性 → 辅助功能 勾选 Yaha Home 即可。日志在
`~/Library/Logs/YahaHome.log`。

> 它是你家庭智能硬件的 Mac 端控制中心:`mac/Sources/YahaHome/HomeDevice.swift` 定义了
> 设备抽象,接新硬件 = 新增一个遵守 `HomeDevice` 的模型 + 一张卡片视图。核心能力
> (设备链路、音频出口、Fn 监听)在 `YahamicCore` 库里;`yahamicd` 仍保留为命令行版
> (`swift build -c release --product yahamicd`,`--help` 看参数),调试时更顺手。

### 2. 固件构建与刷写

需要 [ESP-IDF 6.1](https://docs.espressif.com/projects/esp-idf/zh_CN/latest/esp32s3/get-started/index.html):

```bash
cd firmware
idf.py set-target esp32s3     # 首次
idf.py build
idf.py flash monitor          # 板子接 USB-C;Ctrl+] 退出日志
```

台架自检(不连 Mac,采 1 秒打印响度,确认麦克风链路):
`idf.py menuconfig` → Yahamic → 开启 `开机自检`,重新刷写。

### 3. 设备配网(只用一次)

1. 上电后约一分钟(或长按按键 5 秒),板子开出热点 `Yahamic-XXXX`,
   屏幕显示热点名和密码,日志里也有。
   热点密码默认每次随机;想固定一个,用 `idf.py menuconfig` → Yahamic 设
   `CONFIG_YAHAMIC_AP_PASSWORD`(至少 8 位)后重刷——这是本机私有配置,留在
   `firmware/sdkconfig`(不入库)里即可,不要写进 `sdkconfig.defaults`。
2. 手机连上该热点,自动弹出配网页(或浏览器打开 `192.168.4.1`)。
3. 选家里 Wi-Fi、输密码;在「配对码」里填 Mac 面板上显示的配对码(**必填**,8–63 位可见
   字符;命令行版 `yahamicd` 用 `--token` 指定同一个码)。没有配对码设备不会连 Mac,
   屏幕显示 `PAIRING CODE?`。之后在配网页改码,退出配网即生效,无需重启。
4. 提交后热点关闭,设备入网。

### 4. 用起来

- 设备屏幕变绿 `ON AIR` = 正在送声。打开 系统设置 → 声音 → 输入,选
  **BlackHole 2ch**;或在 Zoom/QuickTime 等应用里选它。
- **短按按键**:硬件静音(屏幕红 `MUTED`,采集关闭),再按恢复。
- **长按 5 秒**:重新开配网热点。
- 屏幕底部常显:电量、IP、Wi-Fi 信号。

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

设备不跑字库:屏幕上的中文短语(讲话中 / 已静音 / 寻找 Mac 中 / 配网模式 / 热点 /
密码……)由 `firmware/tools/gen_text.swift` 用 **Noto Sans CJK SC**(SIL OFL 1.1)在 Mac 上
预渲染成 8 位 alpha 位图,生成 `main/generated/text_zh.h`(约 180 KB,进 flash),固件贴图
时按 alpha 与状态色相乘。要加/改文案,在脚本的 `phrases` 表里改一行再重新生成:

```bash
cd firmware && swift tools/gen_text.swift tools/fonts/NotoSansCJKsc-Medium.otf main/generated/text_zh.h
```

字体文件不进仓库(16 MB),首次从
<https://github.com/notofonts/noto-cjk/raw/main/Sans/OTF/SimplifiedChinese/NotoSansCJKsc-Medium.otf>
下载到 `firmware/tools/fonts/`。动态文本(热点名、密码、IP、电量)仍用内置 ASCII 点阵。

## 协议 v2(设备 ⇄ Mac,UDP)

v2 与 v1 不兼容:Mac(0.4.0)与固件(0.4.0)要一起升级,设备刷新后在配网页填配对码。
时序图与模块关系见 [docs/architecture.md](docs/architecture.md);编解码在
`mac/Sources/YahamicProtocol` 与 `firmware/main/protocol.{h,cpp}`,两端共用
`firmware/tools/protocol_vectors.py` 生成的测试向量(Mac `swift test`、固件开机自检)。

所有报文:小端,12 字节头 `magic 'Y' | version 2 | type | flags | seq u32 | ts u32`,
其后为载荷。flags bit0 = 静音。明文载荷上限 512 字节,超长包直接拒收。

| type | 方向 | 加密 | 载荷 | 说明 |
|---|---|---|---|---|
| 1 hello | 设备→Mac | 否 | `name/fw/rate/ch/bits/frame/codec/dn`(dn = 16 字节随机数 hex) | 每 500 ms 重发直到收到 welcome |
| 2 welcome | Mac→设备 | 否 | `ok 1`、`host`、`dn`、`mn`、`proof`;拒绝时 `ok 0`、`err`、`dn` | 设备只认握手中且 dn 对得上的 welcome/拒绝 |
| 8 auth | 设备→Mac | 否 | `proof` | 设备的证明;Mac 验证通过才建会话 |
| 3 audio | 设备→Mac | 是 | 16 kHz 单声道 Opus,60 ms 一帧 | 静音且淡出结束后不发 |
| 4 status | 设备→Mac | 是 | `muted 1/0` | 静音时兼作 1 Hz 心跳 |
| 5 keepalive | Mac→设备 | 是 | `muted X`、`cmd N`(最新静音指令) | 0.5 s 一个;设备 5 秒收不到就重新握手 |
| 6 control | Mac→设备 | 是 | `muted X`、`cmd N`,或 `dump 1` | 遥控静音、请求屏幕回传 |
| 7 dashboard | Mac→设备 | 是 | 10 字节:`epoch u32` + `tz i16`(分钟)+ `cpu/mem/mouse_batt/kb_batt u8` | 无效字段 255;数据不新鲜时设备回退静音屏 |

密码学(HMAC 均为 HMAC-SHA256,`‖` 为拼接):

```
K      = PBKDF2-HMAC-SHA256(配对码, "yahamic-v2", 4096 轮, 32 字节)
proof  = HMAC(K, "m" ‖ dn ‖ mn)   welcome 里 Mac 的证明
         HMAC(K, "d" ‖ dn ‖ mn)   auth 里设备的证明(都用常量时间比较)
k_d2m  = HMAC(K, "d2m" ‖ dn ‖ mn) 设备→Mac 方向密钥
k_m2d  = HMAC(K, "m2d" ‖ dn ‖ mn) Mac→设备 方向密钥
加密包 = 头 ‖ ChaCha20-Poly1305(方向密钥, nonce = 0^8 ‖ seq_LE, aad = 12 字节头) ‖ 16 字节 tag
```

- 握手:hello(dn)→ welcome(mn + Mac 证明)→ 设备验证后发 auth → Mac 验证后立即发
  一个加密 control(当前静音指令),设备收到这个包才进入 live。
- 每个会话两个方向的 seq 都从 1 重新计数;接收方先验 tag 再处理。设备侧控制类包要求
  seq 严格递增,Mac 侧用序号跟踪去重、丢迟到包、识别重置。
- 上线后的明文包一律丢弃;伪造的拒绝包对不上 dn,打不断链路。被拒后设备退避 5 秒。
- 静音同步:Mac 的每个 keepalive 都带最新静音指令,设备只在 `cmd` 变化时执行,丢一个
  control 也会被下一个 keepalive 纠正。设备开机默认静音,断链自动静音。

Yaha Home 默认以 120 ms 为预缓冲与漂移校正目标,命令行可用 `--jitter-ms` 调整;
渲染端按缓冲水位做 ±0.5% 内的时钟漂移微调。链路断开(Mac 合盖、守护进程重启)
后设备自动重新握手,Mac 恢复即自动接上,无需重新配网。

## 安全模型

配对码必填,两端必须一致(Mac 面板生成并存钥匙串;设备存在 NVS,日志里不打印)。

- **防冒充 Mac 窃听**:设备只在验证 Mac 的证明后才发 auth、才送声;证明含设备本次的
  随机数 dn,重放旧 welcome 无效。
- **防注入音频**:Mac 只在验证设备的证明后建会话,之后只接受能用会话密钥验签的包。
- **防窃听与篡改**:音频、静音、仪表盘全部 ChaCha20-Poly1305 加密,头部作为附加数据
  参与认证。
- **离线猜码**:证明里含双方随机数,嗅探到的握手只能拿去离线爆破,PBKDF2 4096 轮加上
  最少 8 位配对码抬高成本。App 生成的 10 位码(去掉易混字符的字母数字)约 50 比特。
- 本机控制接口只对当前用户开放(见上文)。

## 已验证 / 未验证

**已验证(2026-11-01,协议 v1,ESP-IDF 6.1 + macOS 26 + 真机端到端):**

- 固件与 Mac 构建、刷写和设备重连;ES7210 以 16 kHz/60 ms 采集并经 Opus 发送,
  屏幕、电量、按键硬件静音正常。
- 端到端:配网 → mDNS/静态地址发现 → 握手 → 解码与预缓冲 → BlackHole 2ch;
  180 秒连续语音欠载/溢出/解码错误均为 0,FFmpeg 能从 BlackHole 录到真实音频。
- Mac 控制接口 100 次请求失败 0;Fn 事件、1 秒粒度静音切换、App 重启自动恢复、
  解码后 PCM WAV 录制均通过实测。
- 设备波形真机达到 24.3–24.8 fps,采集间隔保持 59–60 ms。
- daemon 的 Bonjour 注册用 dnssd,传输层用 BSD socket,避免进程反复重启时的
  系统服务粘滞;同设备重连会重置序号、抖动缓冲与渲染会话。

**未验证 / 已知事项:**

- 协议 v2(0.4.0):Mac `swift test` 与固件开机自检共用测试向量通过,固件已刷机启动;
  真机配对、压测、长静音回归待配网后复验。

- 豆包输入法内的文字级听写重复:已验证 Fn 到 BlackHole 的链路,仍需在豆包中
  做人工听写复验,不能仅凭音频指标宣称完全解决。
- Fn 键:Apple 键盘/妙控键盘可用;部分第三方键盘的 Fn 不上报给 macOS(用设备
  按键代替)。某些路由器不转发 mDNS 时可使用静态 daemon 地址。
- launchd(LaunchAgent)环境下 daemon 表现异常时,先用终端方式运行。
- 电池续航、超过 1 小时连续送声和实际通话时延仍未测。

**联调中踩过并修掉的坑(供后来者,含系统升级)**:

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
- **设备短按按键**:同样的静音开关;**长按 5 秒**:重新配网
- 屏幕底部:电量 IP 信号;配网屏:热点名与密码(密码可在固件里固定,见上文)

## 故障排查

| 症状 | 处置 |
|---|---|
| 屏幕一直 `SEARCHING` | Mac 上 yahamicd 起了吗?`--verbose` 看日志;两端在同一网段/同一 VLAN?路由器开了 AP 隔离(mDNS 被拦)就关掉它 |
| App 日志「配对码不匹配」/ 设备日志 `welcome proof doesn't match` | 长按 5 秒进配网页,填 Mac 面板上的配对码后退出配网 |
| 屏幕 `PAIRING CODE?` | 设备没有有效配对码:长按 5 秒进配网页填码 |
| 应用里没有 BlackHole 2ch | 面板「安装 BlackHole」一键安装,或 `brew install blackhole-2ch`;仍看不到就 `sudo killall coreaudiod`;`yahamicd --list-devices` 确认设备名,必要时 `--device` 指定 |
| 声音卡顿 | `--jitter-ms 100` 加大缓冲;离路由器近些;`--verbose` 看 溢/欠 计数 |
| 设备连不上 Wi-Fi | 确认是 2.4 GHz 网络;长按 5 秒重开配网 |
| 想换 Wi-Fi | 长按 5 秒,配网页里「忘记」旧网络 |

## 产品演进:从无线麦克风到个人智能中枢

- **当前可用**:ESP32 无线麦克风、Fn 对讲、硬件静音、Yaha Home 菜单栏控制、
  BlackHole 系统输入、自动重连、PCM 诊断与可重复压力测试。
- **下一阶段(Mac 中枢)**:以 `HomeDevice` 统一接入更多设备,补齐设备分组、
  连接质量展示、事件通知、场景开关和本地自动化;控制接口保持仅监听回环地址。
- **再往后(智能能力)**:在稳定音频入口上增加本地语音指令、设备联动与个人任务
  自动化;按需增加 24 kHz 音质档、其它麦克风板子和 BLE 控制通道。
- **安全基础**:跨网段或不可信网络使用前,增加 ChaCha20 预共享密钥或 WireGuard;
  智能中枢的设备权限、日志与语音数据默认留在本机。

## 许可证

本仓库代码:MIT(见 [LICENSE](LICENSE))。第三方组件见
[LICENSES/THIRD_PARTY_NOTICES.md](LICENSES/THIRD_PARTY_NOTICES.md)。
本项目与 OpenCharm、Waveshare、Espressif、Apple 无隶属关系。
