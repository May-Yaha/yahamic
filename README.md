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
| 配对 | mDNS 自动发现,可选配对码 | — |

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
│   │   ├── uplink.{h,cpp}    # Wi-Fi + mDNS 发现 + UDP 协议(握手/音频/状态/保活)
│   │   ├── board.{h,cpp}     # CO5300 屏幕、LUT 波形渲染、按键、I2C
│   │   └── generated/text_zh.h  # 屏幕中文短语的预渲染位图(tools/gen_text.swift 生成)
│   │   └── power.{h,cpp}     # AXP2101 电量读数 + 打开麦克风供电
│   ├── components/esp-wifi-connect/   # 配网组件(78/xiaozhi 的 MIT 组件,页面换成了中文)
│   ├── sdkconfig.defaults / partitions.csv / CMakeLists.txt
│   └── main/Kconfig.projbuild          # CONFIG_YAHAMIC_SELFTEST(台架自检)
├── mac/                      # Yaha Home + yahamicd(Swift、系统框架、Opus)
│   ├── Sources/YahamicCore/  # UDP/Bonjour、Opus 解码、预缓冲、音频出口、Fn 监听
│   ├── Sources/YahaHome/     # 菜单栏 UI、HomeDevice 抽象、控制接口与压力测试
│   ├── Sources/yahamicd/     # 命令行版本
│   └── com.yaha.yahamicd.plist  # 开机常驻示例
└── LICENSES/THIRD_PARTY_NOTICES.md
```

## 快速开始

### 1. Mac 端:Yaha Home 菜单栏 App(先做这步,设备开机才能找到它)

```bash
# 虚拟麦克风:BlackHole(把它想成"一根环回音频线")
brew install blackhole-2ch          # 装完若 CoreAudio 里看不到:sudo killall coreaudiod

# 打包并安装 Yaha Home(菜单栏 App,无 Dock 图标)
cd mac && ./scripts/make-app.sh --install
```

顶栏出现麦克风图标即运行中:**划线线框 = 设备离线,实心划线 = 在线静音,实心 = 送声**。
点开是控制面板:设备卡片(状态、电平、开麦/静音)、「按住 Fn 讲话」开关、输出设备
选择、配对码、**开机自启**、日志。首次使用系统会弹「辅助功能」授权(监听 Fn 要用),
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
3. 选家里 Wi-Fi、输密码;(可选)在「配对码」里填与 `--token` 一致的配对码。
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

App 内置本机控制接口(127.0.0.1:7718,行式 JSON),脚本可直连,命令处理见
`mac/Sources/YahaHome/ControlServer.swift` 与 HomeModel:

| 命令 | 作用 |
|---|---|
| `status` | 全量状态(在线/静音/电平/帧率/缓冲/Fn 权限…) |
| `set_mute` | 遥控静音/开麦 |
| `set_ptt` | 切换「按住 Fn 讲话」/常开模式 |
| `devices` / `logs` | 输出设备列表 / 运行日志 |
| `metrics` | 采样 N 秒流指标(不动状态) |
| `stress` | **端到端压测**:自动常开麦克风(+可选 TTS 音源)采样 N 秒,结束恢复原状态,返回帧率/丢帧/缓冲/电平汇总 |
| `dump` / `capture` | 屏幕帧回传 / 诊断录制 |

(2026-11-01 起随包的 MCP 桥 `yahamic-mcp` 已移除;需要 AI 代理控制时直接连 7718 即可。)

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

## 协议(设备 ⇄ Mac,UDP)

所有报文:小端,12 字节头 `magic 'Y' | version 1 | type | flags | seq u32 | ts u32`,
其后为载荷。flag bit0 = 静音。

| type | 方向 | 载荷 | 说明 |
|---|---|---|---|
| 1 hello | 设备→Mac | `key value` 行:`name/fw/rate/ch/bits/frame/codec`,配对码启用时另有 `nonce/proof` | 每 500 ms 重发直到收到 welcome |
| 2 welcome | Mac→设备 | `ok 1/0`、`host`、配对码启用时 `proof` | 拒绝时给 `err 原因` |
| 3 audio | 设备→Mac | 16 kHz 单声道 Opus,60 ms 一帧 | 静音时不发送;Mac 解码为 PCM |
| 4 status | 设备→Mac | `muted 1/0` | 静音时兼作 1 Hz 心跳 |
| 5 keepalive | Mac→设备 | 空 | 1 Hz;设备 5 秒收不到就重新握手 |
| 6 control | Mac→设备 | `muted 0/1` 或 `dump 1` | 遥控静音、请求屏幕回传 |
| 7 dashboard | Mac→设备 | 10 字节小端(整帧 22 字节):`epoch u32`(UTC 秒)+ `tz_offset i16`(分钟)+ `cpu u8` + `mem u8` + `mouse_batt u8` + `kb_batt u8` | 空闲屏仪表盘数据;百分比字段无效统一 255,数据过时不新鲜设备回退静音屏 |

Yaha Home 默认以 120 ms 为预缓冲与漂移校正目标,命令行可用 `--jitter-ms` 调整;
渲染端按缓冲水位做 ±0.5% 内的时钟漂移微调。链路断开(Mac 合盖、守护进程重启)
后设备自动重新握手,Mac 恢复即自动接上,无需重新配网。

## 安全模型

不设配对码(默认)时,同一局域网内的任何设备都可以:冒充 yahamicd 接收你的
麦克风音频,或向你的麦克风通道注入音频。家用网尚可接受,**建议设置配对码**:

- 设备配网页「配对码」与 Mac 端 `--token` 填同一个码;
- 设备在 hello 里带一次性 `nonce` 和 `proof = SHA256(配对码+nonce)` 前 8 字节,
  Mac 验证后才接收音频(防止**注入**);
- Mac 的 welcome 里带 `SHA256(配对码+nonce+"welcome")` 前 8 字节,设备验证后才
  送声(防止**收流窃听**)——nonce 一次性且方向绑定,截获报文推不出配对码。

音频只走局域网明文 UDP(与多数商用无线麦克风同类);如需跨网段/加密,见路线图。

## 已验证 / 未验证

**已验证(2026-11-01,ESP-IDF 6.1 + macOS 27 + 真机端到端):**

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

- 豆包输入法内的文字级听写重复:已验证 Fn 到 BlackHole 的链路,仍需在豆包中
  做人工听写复验,不能仅凭音频指标宣称完全解决。
- Fn 键:Apple 键盘/妙控键盘可用;部分第三方键盘的 Fn 不上报给 macOS(用设备
  按键代替)。某些路由器不转发 mDNS 时可使用静态 daemon 地址。
- launchd(LaunchAgent)环境下 daemon 表现异常时,先用终端方式运行。
- 电池续航、超过 1 小时连续送声和实际通话时延仍未测。

**联调中踩过并修掉的坑(供后来者,含 macOS 26→27 升级)**:

- **Fn 键(macOS 27)不再设置 SecondaryFn 修饰位**,只以键码 63 上报——监听要同时
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
| hello 被拒:配对码不匹配 | 设备配网页里清掉配对码重存,或两端改成同一个 |
| 应用里没有 BlackHole 2ch | `brew install blackhole-2ch` 后重启;`yahamicd --list-devices` 确认设备名,必要时 `--device` 指定 |
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
