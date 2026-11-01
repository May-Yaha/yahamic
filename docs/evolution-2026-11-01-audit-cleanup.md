# 代码审计与清理决策记录(2026-11-01)

> 目的:对开发演进过程中产生的冗余/过时代码做一轮只读审计 + 确定项清理;拿不准的留待用户确认;
> 把"必须保留"的东西(逃生舱、在途功能)沉淀为 agent 领域事实与 yahallmwiki 知识,防止未来被当死代码误删。
> 本仓库**不是 git 仓库**,动手前已做源码快照:`/tmp/yahamic-pre-cleanup-20261101.tar.gz`(14.4MB,含固件/Mac/agent 源码与 .runs)。

## 1. 演进时间线(据 agent/.runs 黑板与 README)

| 阶段 | 时间 | 内容 |
|---|---|---|
| OpenCharm 底座 | 早期 | 板级驱动/Wi-Fi 配网/mDNS 继承自 OpenCharm;音频链路按纯麦克风重设计 |
| 20ms PCM 时代 | — | 早期采集帧长 20ms(残留注释已在此前任务清完,本轮 grep 复核无残留) |
| 60ms Opus 链路 | — | kFrameSamples=960;两端联调:静态 IP 逃生舱、SO_RCVTIMEO 坑、WIFI_PS_NONE |
| demo/宿主验证 | 10-31~11-01 | 7 次 fixture 运行(已清理,可 `npm run demo` 重现) |
| 首跑失败 | 11-01 09:53 | run `f2dc101b` blocked(plan 阶段无产出)——失败本身是演进证据 |
| Mac 音频稳定性 | 11-01 09:57/10:09 | 预缓冲门控、欠载计数口径、FnListener 键码63、onAudioTap 转 PCM、重连重置会话 |
| 固件波形优化 | 11-01 10:36 | LUT+相位递推替代逐列 std::sin,单遍柔光;13.3→24.8fps |
| Fn 崩溃修复 | 11-01 11:27 | CGEventTap passRetained 生命周期,passUnretained 仅用于事件返回值 |
| 频谱重心驱动 | 11-01 11:57 | 重心→流速/空间周期;interrupted 后由后续任务续做 |
| Dashboard(在途) | 11-01 12:58 | run `619723b7`:固件 type7 接收✓、MetricsCollector✓;4 子任务决策协议失败,Mac 发送端与状态接线缺 |

## 2. 审计方法

三路并行只读审计(firmware/main、mac/Sources、agent/+根目录),逐项要求给出引用证据与编译分支依据;
交叉核对 sdkconfig 实际值、Kconfig、CMakeLists、Package.swift、MCP 工具面、README 协议表与 `.runs` 黑板。
**本仓库无 git 历史,演进推断以 .runs 黑板 + 代码内注释为据。**

## 3. 决策记录

### 3.1 已直接执行(不涉及 firmware/mac 产品代码)

| 动作 | 依据 |
|---|---|
| 删 `agent/.runs/` 7 个 demo/宿主验证目录(56K) | 纯 fixture 产出,`npm run demo` 可重现;7 次真实运行全保留 |
| `docs-screen-muted.png` → `docs/screen-muted.png` | 全仓零引用;留作历史 UI 参考,不再占仓库根 |
| `agent/kernel/config.mjs` 删 `AGENT_DIR` re-export | 仅内部使用,无外部 import;`npm test` 31/31 通过 |
| `agent/agent.example.json` 同步实测调优值(thinking=low/32768) | 与 agent.json 对齐,新装机不再走保守默认 |
| `docs/baseline-code-audit.md` 头部加行号失效标注 | board.cpp 758→1094 行,锚点漂移但语义仍成立 |

### 3.2 图工作流执行(firmware/mac 确定项,run `20261101133535-2a098f43`)

任务书逐项给出文件与符号锚点,边界里明令不动在途功能与待确认项;验证 = idf.py build + swift build 双绿。
清单:① `dma_us` 死变量 ② `audio::muted()` 零调用 ③ `i2s_std.h` 冗余 include ④ `"muted 1\n"` 传长 9→8
⑤ battery 毫伏链(power.cpp/power.h/main.cpp)⑥ `self_test` 包进 `#if CONFIG_YAHAMIC_SELFTEST` ⑦ fps 口径与
board.cpp:986 失实注释修正 ⑧ Mac `pushSilence` 删除 ⑨ Package.swift 补 `yahamic-mcp` product ⑩ MetricsCollector
注释标注未接线 ⑪ HomeModel 未知命令提示补 dump。
执行结果见第 5 节。

### 3.3 保留待用户确认(未删,原因如下)

| 项 | 位置 | 未删原因 |
|---|---|---|
| `draw_waves()` canvas 版 | board.cpp ~958 | 作者注明"保留作对照";与现行渲染重复一套平滑/插值,删它可消解整组重复 |
| `draw_level`+`compose_bar`+`Screen::level` | board.cpp ~343/~673, board.h | board.h 自述"保留 API";与"电平由波形振幅表现"现行设计冲突 |
| `set_brightness()` | board.cpp ~1088 | 零调用孤儿接口,可能是将来自动亮度预留 |
| `text_zh.h` 未用短语×3 | generated + gen_text.swift | on_air 大字版(14.6KB)疑似 Live 主标题预留;删需重新生成 |
| `Uplink.State.bonjourName` | Uplink.swift ~162 | 只写不读,但位于最近才稳定的重连关键文件,谨慎起见留待确认 |
| FnListener 调试日志 | HomeModel ~255 | macOS27 Fn 排查期产物,已限 12 个事件,噪声极小 |
| 版本号 0.2.1 vs 0.3.0 | make-app.sh vs yahamic-mcp | mtime 显示 make-app.sh 最后编辑仍保持 0.2.1,方向需用户拍板 |
| `flash-backup-20261031.bin` | 仓库根 | 16MB 刷机备份属用户数据(.gitignore 已覆盖);建议移出仓库,未擅动 |

### 3.4 审计排除的疑点(复查过是干净的,防止未来重复审计)

- `draw_bars` 是 menuconfig 可选风格(`CONFIG_YAHAMIC_SPECTRUM_BARS`),非死代码
- Kconfig.projbuild 无孤儿选项;协议 type 1-6 两端实现与 README 一致
- "20ms/50Hz" 时代注释已无残留;JitterBuffer 是预缓冲门控的存储本体(仅 pushSilence 死)
- yahamicd 与 YahaHome 核心管线零重复(yahamicd 是有意保留的命令行调试版)
- agent 14 个插件全部在用,31 项测试与 README 一致;graphs/coding.json 无不可达节点
- Mac "120ms 预缓冲"等数字声明与代码全部吻合;CLAUDE.md 是有意的去重指针

### 3.5 逃生舱清单(动前必读,已同步 agent SKILL.md)

| 逃生舱 | 状态 |
|---|---|
| 静态 IP 直连(`CONFIG_YAHAMIC_DAEMON_IP` 回落) | **激活中**(sdkconfig 已配本机局域网静态地址(私有配置,不入库)) |
| dump 屏幕回传(远程看设备 UI) | 活,Mac 端可触发 |
| 台架自检(`CONFIG_YAHAMIC_SELFTEST`) | 开关保留,未启用 |

## 4. 经验沉淀

- `agent/skills/coding-task/SKILL.md`:新增「逃生舱与敏感区(动前必读)」+ 决策点 JSON 批量失败的自愈对策
- yahallmwiki:proposal 提交(见 `../../yahallmwiki/wiki/proposals/`,L2 yahamic 项目页);图工作流每次 run 的 digest 自动进 inbox 队列

## 5. 执行结果(图工作流,run `20261101133535-2a098f43`)

双构建全绿:① `source ~/esp/esp-idf/export.sh && cd firmware && idf.py build` 退出码 0,日志 0 warning/0 error(另以 `CONFIG_YAHAMIC_SELFTEST=y` 临时复验编译 0 告警后还原 sdkconfig);② `cd mac && swift build` 退出码 0,唯一 ld warning 为 homebrew opus dylib(26.0)vs 部署目标(macOS-13.0)的环境性告警,与本轮改动无关非新增;③ `swift build --product yahamic-mcp` 退出码 0。对账基准 = 动手前快照 `/tmp/yahamic-pre-cleanup-20261101.tar.gz`,源码 diff 恰为下列 12 个文件(固件 8 + Mac 4),无清单外文件。

### 5.1 逐项对账(11 项清理)

| # | 文件 | 改前行为 | 改动内容(删除符号) |
|---|---|---|---|
| ① | firmware/main/board.cpp | render_waves_direct 局部变量 `dma_us`(声明约:911、累加约:943 `dma_us += t1-t0>0?t1-t0:0`)与 draw_us 恒等且只写不读 | 删局部 `dma_us` 声明与累加行;遥测 `render_dma_us_v = int32_t(draw_us)` 不变(注:全局 render_dma_us_v 与 render_timing 出参 dma_us 为另一套在用遥测,未动) |
| ② | firmware/main/audio.h、audio.cpp | `audio::muted()` 声明(:23)/定义(:298 `bool muted() { return muted_.load(); }`)全仓零调用 | 删声明与定义;内部 `muted_` 原子成员原样保留(注释同步改为「set_muted 写,capture_loop 读」,不再引用已删符号);注:`uplink::muted()` 为另一在用符号,未动 |
| ③ | firmware/main/audio.cpp | `#include "driver/i2s_std.h"`(原:8)冗余,文件只用 TDM 接口 | 删该 include,`driver/i2s_tdm.h` 保留 |
| ④ | firmware/main/uplink.cpp | 三处(:321/:521/:658)发 `"muted 1\n"` 长度误传 9(含尾 NUL),与 Mac 端 Data(utf8) 恰 8 字节不一致 | 三处统一:前两处 `sizeof("muted 1\n") - 1`,第三处(带 muted 0 分支)常数 8;字面量与协议语义不变 |
| ⑤ | firmware/main/power.cpp、power.h、main.cpp | 毫伏链只写不读:power.cpp `kBatteryHigh`(0x34) 常量+两寄存器合成毫伏块、power.h `Reading::millivolts` 字段、main.cpp `battery_mv` 原子及其转存/遥测赋值 | 整链删除(符号:`kBatteryHigh`、`millivolts`、`battery_mv`);percent/usb/charging 字段、计算与遥测全保留 |
| ⑥ | firmware/main/audio.h、audio.cpp(main.cpp 调用点快照中原已带同一宏门) | `self_test()` 声明/定义无条件编译,仅调用点有 `#if CONFIG_YAHAMIC_SELFTEST` 门 | 声明与定义包进 `#if CONFIG_YAHAMIC_SELFTEST ... #endif`,三处同一宏;开关双向编译均绿(默认 not set / 临时 =y),sdkconfig 已还原 |
| ⑦ | firmware/main/board.cpp、board.h、main.cpp、audio.cpp | board.cpp ~:986 注释「两者经 Kconfig 二选一」与事实不符(draw_waves 无调用方);fps 口径 main.cpp 写 26-30、其余文件写 24-30 | 注释改为「本函数当前无任何调用方(保留作 canvas 版对照…)」;fps 全部统一「目标 24-30,实测 24.3-24.8」(main.cpp:2/:3/:46、board.h:76、board.cpp:682、audio.cpp:228);`grep -rn "26-30" firmware/main` 零命中;仅注释零代码 |
| ⑧ | mac/Sources/YahamicCore/JitterBuffer.swift | `public func pushSilence(_ n: Int)`(原:46-54)零调用,且与「从不插静音」设计矛盾 | 整方法删除;push/pop/count/clear/stats/noteUnderrun 零 diff |
| ⑨ | mac/Package.swift | products 缺 yahamic-mcp,依赖 SwiftPM 隐式行为 | 补 `.executable(name: "yahamic-mcp", targets: ["yahamic-mcp"])`;`swift build --product yahamic-mcp` 验证通过 |
| ⑩ | mac/Sources/YahamicCore/MetricsCollector.swift | 头注释未标注在途未接线状态 | 头注释补一句「(尚未接线:Uplink.sendDashboard 已就绪但暂无调用方,等待 dashboard 任务收尾)」;逻辑零改动(verify 阶段修正了原拟措辞「Uplink 无 type 7 发送端」——与 Uplink.swift:316 事实不符) |
| ⑪ | mac/Sources/YahaHome/HomeModel.swift | 未知命令提示列了 capture 漏 dump | 提示补 dump:「…logs/dump/capture/metrics/stress」,其余文案不变 |

### 5.2 边界清单零改动核对(对快照 diff 逐项确认)

- **Dashboard/type 7/MetricsCollector 逻辑**:固件 board.cpp/main.cpp/uplink.cpp 的 diff 中零 dashboard/type 7 行;`Uplink.swift` 与快照逐字节一致(cmp IDENTICAL,含 `State.bonjourName` 与 `sendDashboard`);MetricsCollector 除头注释一句外零行变化;HomeModel 中曾被越界混入的 type 7 接线(dashboardTimer/metricsCollector/3s Timer 调 sendDashboard)已在 verify 阶段回退,最终 diff 仅剩⑪的 dump 提示一行。
- **draw_waves/draw_level/compose_bar/set_brightness/text_zh 短语**:board.cpp diff 对这四个符号零命中(仅⑦的注释改写,不含符号名);generated/text_zh.h 无 diff。
- **FnListener.swift、ControlServer、yahamic-mcp 工具面**:三文件均无 diff。
- **协议语义**:type 1-7 头结构/语义零改动;"muted 1\n" 字面量不变,仅长度对齐 Mac 端 8 字节(修 bug 非改语义)。
- **60ms Opus 链路**:audio.cpp 采集/FFT/滑窗/编码路径零改动(kFrameSamples=960 不变)。

### 5.3 verify 阶段的三处回正(越界/失实)

1. **HomeModel.swift 回退 type 7 接线**:改动任务 mac-package-and-comments 执行时越界混入了 dashboard 发送接线(不在 11 项清单,边界明令不动);已回退,接线留待 dashboard 收尾任务。
2. **audio.cpp:40 注释**:原注释「叫 muted_ 才不与 audio::muted() 打架」引用已删符号,改为如实描述读写方。
3. **MetricsCollector.swift 头注释措辞**:按⑩说明修正(原拟句与 Uplink.swift 事实不符)。

### 5.4 残留说明

- T1 验收「`grep -rn "muted()"` 零命中」字面不可满足:`uplink::muted()`(uplink.h:40/uplink.cpp:662,main.cpp:186 在用)是另一合法符号;按其括号语义(audio::muted 声明/定义删净)已满足。
- sdkconfig 在⑥验收过程中被临时改写后还原(现 `# CONFIG_YAHAMIC_SELFTEST is not set`,与动手前一致);快照 tar 未含 sdkconfig,故以内容状态为准。
- 固件 build/、managed_components、dependencies.lock 为构建产物,不属源码 diff。

### 5.5 人工复核(会话主控,与执行者报告独立)

- 以 `/tmp/yahamic-pre-cleanup-20261101.tar.gz` 独立 diff 全量核对:固件 8 文件 + Mac 4 文件,
  与 5.1 表逐项吻合;边界项(Dashboard/type 7、draw_waves、draw_level、set_brightness、
  text_zh、Uplink.swift、FnListener、ControlServer、协议、60ms 链路)确认零改动。
- 悬空引用 grep(battery_mv/millivolts/dma_us/pushSilence/audio::muted)零命中
  (`render_dma_us_v`/`render_timing` 的 dma_us 出参是另一套在用遥测,不属清理项)。
- 附注:`mac-pushsilence` 执行者顺带重建并重签了 YahaHome.app(可再生产物,未 --install);
  固件双配置构建由执行者完成(默认 + SELFTEST=y 临时复验后还原 sdkconfig),主控未重复跑
  idf.py build——当时已有并行 run `20261101141002-7ecf99cd`(Dashboard 收尾)在工作区活动,
  避免构建目录冲突。

### 5.6 事故记录:跨会话并发竞态吃掉 Dashboard 接线(已修复)

- 时间线:并行会话 21:48 用 yahamicd 版接线真机验收 Dashboard → 21:52 前后给
  `HomeModel.startUplink` 补 3s Timer(HomeModel 版)→ 恰落在本 run 执行窗口内;
  本 run 的 mac 执行者把该接线视为"越界混入",verify 阶段按任务边界回退(按任务书
  规则本身没错)→ 结果 App 版 type 7 发送接线从源码消失,已装 App 二进制仍正常,
  下次重建即回归(Muted 屏)。
- 根因:两个会话共用一个无 git 的工作区,各自快照基准不同;"快照 diff 对账/回退
  越界"在多写者场景不安全。**多会话并发跑图工作流需要互斥约定**(如 .runs 加工作
  区锁,或会话间先对表)。
- 修复:照 `yahamicd/main.swift` 的同一 idiom 恢复 HomeModel 接线
  (Timer 只建一次 + 闭包读 self.uplink 属性 + sendDashboard 内部串行队列投递),
  `swift build` 通过(3.94s)。
- 教训已并入 agent SKILL.md 与本节:执行者的"越界回退"必须先查该改动是否来自
  并行会话,不能只对任务清单。

## 6. 第二轮清理(用户拍板,run `20261101142957-60810770`,22:29 提交)

| # | 项 | 结果 |
|---|---|---|
| 1 | `draw_waves` canvas 版删除 | ✓ board.cpp 1094→1022 行(:951-1021 连注释 72 行);wave_dynamics/LUT 等活代码零误伤 |
| 2 | text_zh.h 未用短语×3 | ✓ gen_text.swift 删 on_air(56px 大字)/release_fn/battery(on_air_s 保留),重新生成 155KB/13 条 |
| 3 | `bonjourName` 双字段链 | ✓ Uplink.swift 4 处删净(public/private 字段+两处赋值;注册日志保留) |
| 4 | Fn 调试日志 | ✓ HomeModel 诊断块 + FnListener 钩子本体(:109)及两处发射行,判定分支零动 |
| 5 | 版本号 0.3.0 双端对齐 | ✓* make-app.sh 0.2.1→0.3.0 由执行者完成;但其 glm 协议失败前**反向越界**把 mcp serverInfo 改成 0.1.0(向固件旧值对齐)——主控修正回 0.3.0,并按"双端对齐"语义把固件 CMakeLists `PROJECT_VER` 0.1.0→0.3.0(执行者原注释由此变为真命题) |

验证:swift build 1.16s 绿;idf.py build 完整产出 yahamic.bin(含清理+Siri 流光渲染器+版本号)。
另修 board.h:74-77 过时注释(三条正弦→Siri 流光,删 render_waves_direct 引用;流光 run 按边界未动 board.h,留下失实描述)。

## 7. 运行时缺口:三 run 并发写同一工作区(22:25-22:48)

22:25/22:28/22:29 三分钟内三个 run 并发执行(用户会话的 Siri 流光×2 + 本会话清理第二轮)。
"同时只能有一个运行"的限制是 **per-MCP-server-process**,多宿主会话各自拉起进程即绕过;
本轮实测三者交叉写 board.cpp 未损坏(编辑时序上恰好错开),但 HomeModel 接线事故(5.6 节)
证明这种运气不可依赖。**建议**:① 多会话并行时对表分工;② kernel 层加跨进程工作区锁
(.runs 锁文件);③ 重复提交的 run(`20261101142856-20b3d4b5`,与已完成的流光同需求)
卡在 plan 阶段未动,留置观察,若苏醒会重写 board.cpp——需人工决定弃留。

## 8. 第三轮清理:移除 yahamic-mcp(run `20261101145452-75bfe580`,用户拍板"用不上")

- 删 `mac/Sources/yahamic-mcp/`(stdio MCP 桥 167 行)、Package.swift 的 product+target、
  make-app.sh 的构建行与拷贝行、ControlServer 头注释的 MCP 引用(接口本体保留)。
- 主控直接处理:`~/.zcode/cli/config.json` 移除 `yaha-home` 注册(保留 `yahamic-agent`);
  README「MCP 接入」章节改写为「本机控制接口」(7718 行式 JSON 直连,命令表保留,
  注明 MCP 桥已移除);SKILL.md 版本号条目从三处改两处(CMakeLists PROJECT_VER + make-app.sh VERSION)。
- **保留**:ControlServer + HomeModel 命令处理(dump/stress/capture 仍可脚本直连)。
- 验证:swift build 1.37s 绿、bash -n make-app.sh 语法 OK、diff 恰为 4 处预期 + README。
- 注:已安装的 /Applications/YahaHome.app 里旧 yahamic-mcp 二进制仍在,下次 make-app.sh
  重打包自然消失;ZCode 里 yaha-home 工具(this session 已加载的)下次会话起不再出现。
