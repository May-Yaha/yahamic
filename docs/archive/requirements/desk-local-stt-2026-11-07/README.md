# Yaha Desk 本地语音转文字（2026-11-07）

## 目标与范围

用户在家中 Mac mini 上使用豆包、微信输入法接收 BlackHole 音频时，分别遇到重复提交和
Fn 快捷键拦截。新增一条不依赖输入法的可选路径：Yaha Desk 继续用 Fn 控制设备开麦，
同时复用解码后的 16 kHz 单声道 PCM，在 M3 Mac 本地完成普通话转写；Fn 松开后只把一份
最终文本写入按下 Fn 时的焦点输入框。

本批只改 `yahaops-desk/mac`：不改固件、BLE/Opus 协议、BlackHole 出口和云端，不做实时
中间结果，也不自动回车或发送。BlackHole 继续供会议、录音和其它应用使用。本地转文字默认
关闭，由用户在菜单栏显式打开，避免升级后自动下载模型或向当前应用意外写字。

## 根因与决策

- 受控链路测试中设备音频只出现一个语音段，接收、解码、入队没有重复；重复文字来自输入法
  对同一段音频的提交策略，不应继续改 BlackHole 或 BLE 音频来掩盖。
- Yaha Desk 已有全局 Fn 监听和解码后 PCM 抽头，直接复用即可；不新增录音设备或第二条解码链。
- 微信输入法会响应同一个 Fn。启用本地转文字后，应关闭输入法语音快捷键或改成别的键；
  Fn 的本地转写由 Yaha Desk 完成，但应用不会吞掉发给其它软件的按键事件。

## 模型选型

| 候选 | 本地中文能力 | 体积/性能证据 | 取舍 |
| --- | --- | --- | --- |
| FluidAudio Paraformer-large-zh int8 | 普通话专用，支持中英混合 | 约 207 MB；AISHELL-1 CER 2.12%，约 84× 实时 | **采用**：仓库已钉 FluidAudio 0.17.7，无新增依赖，直接接 16 kHz PCM |
| FluidAudio SenseVoiceSmall int8 | 中文、粤语、英日韩 | 约 225 MB；AISHELL-1 CER 3.09% | 多语言更强，但本批只要普通话且中文基准较弱 |
| WhisperKit / whisper.cpp | 多语言、标准开源生态成熟 | 需要新增运行时与另一套模型管理 | 保留为许可或真实口音效果不满足时的回退，不在 MVP 重复建设 |

模型由 `FluidInference/paraformer-large-zh-coreml` 提供 Core ML 转换，权重继承 FunASR
Paraformer 上游许可；FluidAudio SDK 为开源软件。首次启用从该公开 Hugging Face 仓库下载
int8 所需文件到 `~/Library/Application Support/FluidAudio/Models/`，后续离线运行。Yaha Desk
通过 FluidAudio 的 `ModelRegistry.revisionOverrides` 固定到已核对提交
`5dd557bd06342a3cd07ceccb909d8a45e48b053a`，不跟随可变 `main`；FluidAudio 同时检查必需文件
是否完整。当前未额外维护逐文件 checksum，若未来改为预打包或镜像分发，再补签名/校验清单。

## 行为契约

1. 用户打开“本地转文字”时自动开启“按住讲话”并准备模型；关闭“按住讲话”会同时关闭本地
   转文字并取消在途采集。准备完成前 Fn 仍可正常开麦，但不启动转写。
2. Fn 首次按下时捕获焦点输入对象并开始收集主链路 PCM；重复 key-down 不重置缓冲。
3. Fn 松开只请求结束；等设备状态确认静音后再封口，保留已经在 BLE/解码队列中的话尾。
4. 同一段采集只产生一个转写任务；重复 key-up、重复静音状态和超时兜底不得二次提交。
5. 只提交非空最终文本；模型、焦点或辅助功能写入失败时不提交半成品，不发全局键盘事件，
   不改剪贴板，不自动回车。
6. 诊断录音、声纹录制与本地转写共用既有采集互斥门，任何时刻只有一个 PCM 抽头所有者。
7. 正在转写时不接受下一段本地转写；Fn 的原有开麦/BlackHole 功能仍照常工作。
8. Paraformer 单次输入按上游约 30 秒边界使用；超过该长度可能截断，不在本批拆段拼接。

## 验收标准

- 自动化：覆盖重复 Fn 事件、静音确认后一次封口、断链/超时兜底、空结果不提交、失败不提交。
- 构建：`cd yahaops-desk/mac && swift test`、`swift build -c release` 通过。
- 模型：在 M3 Mac 用固定中文 WAV 运行 Paraformer int8，记录首次下载、转写结果和耗时。
- 手工：TextEdit、Codex 输入框各连续说 10 次“今天下午三点开会，项目进度正常”，每次只出现
  一份最终文本；微信/豆包语音快捷键关闭时仍可工作。不同输入框的真实焦点兼容性未测到的
  必须列为未验证。
- 回归：关闭“本地转文字”后，原有 Fn→BlackHole、诊断采集和声纹录制行为不变。

## 发布与回滚

只需重新构建/安装 Yaha Desk Mac App；不需要固件、schema、云端或生产数据动作。代码通过
验证和审查后推送 `main`，不自动安装或发布。回滚可关闭开关，或回退本需求提交；模型缓存
不参与业务状态，回退代码不要求删除缓存。

## 执行记录

- 2026-11-07：完成历史与调用链核对；CodeGraph 索引健康。确认复用 `Uplink.onAudioTap`、
  `AudioCaptureGate` 与 FluidAudio 0.17.7，不新增依赖。
- 2026-11-07：官方资料与钉定源码核对 Paraformer/SenseVoice API、模型来源、性能和许可边界；
  选择 Paraformer-large-zh int8。YahaLLMWiki 未召回相关页面。
- 2026-11-07：先写回归测试并确认因 `DictationTextTarget`、`LocalDictationCapture`、
  `LocalDictationText` 尚不存在而失败；实现后本地转文字 4 项定向测试通过。随后运行完整
  `swift test`，YahaDesk 58 项、DeskProtocol 26 项，共 84 项通过；`swift build -c release`
  通过。输出仅有仓库既有的 CloudSync 测试非结构化 Task 和 LoopbackReceiver 弱引用告警。
- 2026-11-07：生成固定样本 `/tmp/yahadesk-local-stt.aiff`（Tingting、单声道 22.05 kHz、
  4.010612 秒，SHA-256 `d7371d9786b8e74f632e82e99c2a8355297528ec9cd0cf82c23fcd3ee36e1e23`）。
  FluidAudio CLI 已完成 release 构建，但从 Hugging Face 下载 `config.json` 时出现 TLS 错误，
  直接连接 443 端口也在 10 秒后超时，模型缓存未生成。因此真模型转写、首次下载耗时、
  TextEdit/Codex 各 10 次焦点写入仍为**未验证**，不能据此声明已可安装使用。
- 2026-11-07：`bash deploy/verify-gates.sh` 以 exit 0 完成；其中 worker 304 项、
  小程序 642 项自动化验收（0 失败，38 项既有真机人工待验）、Go 全仓测试、Web 112 个
  测试文件 / 621 项测试均通过。门禁输出的 React SSR、TaskQueue mock 警告为既有路径，
  本次未改 Web；生成的 `docs/acceptance-cases/miniapp/latest-run.json` 时间戳未纳入需求 diff。
- 2026-11-07：第 1 轮独立审查发现完整口述日志、可变模型 revision、全局 Unicode 事件焦点
  竞态、PTT/本地转写状态分离、监听器销毁占住抽头、关闭开关不取消下载共 6 项。已改为仅记
  字符数、固定模型提交、只走 AX 目标写入、强制 PTT 不变量、监听器销毁前统一取消采集、
  结构化模型加载，并新增 3 项回归测试；定向 `LocalDictationTests` 现为 7 项通过。
- 2026-11-07：审查修复后再次运行完整 `swift test`，YahaDesk 61 项、DeskProtocol 26 项，
  共 87 项通过；`swift build -c release` 通过（65.87 秒，仅既有 LoopbackReceiver 告警）。
  第二次 `bash deploy/verify-gates.sh` 以 exit 0 完成；中途按预期提示 CodeGraph 对最新 Swift
  改动待同步，代码冻结后另行完成最终索引同步。
- 2026-11-07：第 2 轮正确性、安全与精简审查未发现新增 P0/P1/P2；精简审查指出需求文档
  对 Fn 事件归属表述过强，现已明确 Yaha Desk 不吞按键事件，需关闭或改掉输入法语音快捷键。
  第 3 轮定向复核确认文档、用户说明和 `FnListener` 透传行为一致，无新增 P0/P1/P2。
  文档修复后第三次 `bash deploy/verify-gates.sh` 以 exit 0 完成，最终 CodeGraph 为完整状态，
  `pendingChanges=0`、`pendingRefs=0`、`worktreeMismatch=null`。合入最新 `origin/main` 后仅需求
  索引发生文本冲突并保留双方条目，桌面代码无冲突；本地转文字 7 项定向测试再次通过。
