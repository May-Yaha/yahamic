# Yaha Desk 一体化本地语音输入（2026-11-08）

## 目标、授权与不做项

用户确认把 Yaha Desk 与 TypeWhisper 的本地语音输入能力做成一个 Mac App：一个讲话键同时控制
设备开麦、录音、Qwen 转写和文字写入，不再让 Yaha Desk 与输入法或 TypeWhisper 两个进程争抢
Fn。用户接受 Yaha Desk 的 Mac、iOS 与固件统一改为 GPLv3 并公开源码，并希望沿用
TypeWhisper 的设置页、模型管理和状态反馈交互。

当前 App Store 审核中的 `0.3.0` 不修改、不撤回。本需求从后续 `0.4.0` 开始；不上传或发布
Mac/iOS App，不烧录或发布固件，不读取百度网盘训练数据，不改变 BLE/Opus、BlackHole、云端、
网盘和设备协议。

## 历史、基线与根因

- [既有本地语音转文字](../desk-local-stt-2026-11-07/README.md)已经实现单一 Fn 监听、解码后
  16 kHz PCM 抽头、静音确认后一次封口、焦点锁定和单次文字写入；这些契约继续保留。
- 用户实测认为 Paraformer 准确率不足；问题不在已经验证无整句重播的 BLE/BlackHole 音频链路。
- TypeWhisper `v1.8.2`（提交 `28163e7810b3d0a22d1e6b07560240d2024cb7b8`）使用
  Qwen3-ASR 的 MLX Swift 运行时，提供模型下载、选择、加载和本地转写；源码为 GPLv3。
- 当前 M3 Mac 已下载 `mlx-community/Qwen3-ASR-0.6B-6bit`，实际约 827 MiB，满足用户“模型
  1 GB 以内”的约束。固定模型已用临时 16 kHz PCM 完成真实 MLX 推理，但真实用户语音的
  Paraformer/Qwen A/B 尚未完成，不能用 TypeWhisper 页面显示“已加载”代替验收。

## 架构决策

不整仓复制 TypeWhisper。现有 Yaha Desk 已经拥有唯一设备链路和完整 Fn 会话，重复引入
TypeWhisper 的录音器、热键、插件宿主、历史和订阅系统会产生两套状态机。第一阶段只复用经过官方
源码核对的 Qwen3 MLX 依赖、模型参数和必要的防循环策略；页面与交互按 TypeWhisper 的信息架构
逐页迁移到 Yaha Desk，但保持 Yaha 的业务语义和现有设备能力。

唯一主链：

`FnListener → Uplink.onAudioTap → LocalDictationCapture → Qwen3 0.6B 6-bit → DictationTextTarget`

- `FnListener` 是唯一讲话键写入者；启用本地语音输入时不再要求微信/豆包或独立 TypeWhisper
  监听同一按键。
- `Uplink`、`AudioCaptureGate`、静音确认和焦点目标保持现状；Qwen 只替换
  `LocalSpeechRecognizer` 的 Paraformer 后端。
- BlackHole 继续并行服务会议、录音与其它应用，但不参与本地转写决策。
- 模型文件属于可重新下载缓存，不进入 Git、网盘或业务数据；自训练模型导入后续单独交付。

## 分批路线

| 批次 | 内容 | 状态 | 验收 |
| --- | --- | --- | --- |
| P0 | Yaha Desk 许可证切为 GPLv3；Paraformer 替换为 Qwen3 0.6B 6-bit；保留单 Fn/单写入者 | 候选实现完成 | 定向测试、`swift test`、release build 已通过；真实用户短句 A/B 待验 |
| P1 | TypeWhisper 风格的设置侧栏、听写页、快捷键页和 Qwen 模型页；显式下载/导入/加载/卸载 | 待 P0 | 页面状态与模型真实状态一致；错误可重试，不自动下载 |
| P2 | 词典、历史、修正数据和自训练模型导入；处理百度网盘语音/文本数据 | 待单独数据授权 | 原音频、原转写、人工修正文和模型版本可追溯；训练/验证/测试集隔离 |
| P3 | `0.4.0` Developer ID 与 App Store 双渠道 | 待前批真人验收 | 两渠道构建、权限、许可证、模型下载和文本插入分别验收 |

## P0 行为与兼容契约

1. Fn 按下/松开、断链、静音超时和重复事件仍只形成一个 `Utterance`，不改已有测试语义。
2. 识别器固定到 `mlx-community/Qwen3-ASR-0.6B-6bit`；依赖版本与 TypeWhisper 1.8.2 的
   Qwen 插件保持一致，不跟随浮动分支。
3. 单次输入仍以短听写为主；空音频、过短音频、模型未加载、循环输出和加载失败都不写入输入框。
4. 第一次模型下载失败可重试；关闭本地语音输入会取消准备和在途转写，不删除缓存。
5. 关闭本地语音输入后，原有 Fn→BlackHole、诊断采集和声纹录制完全不变。
6. iOS、固件、旧 Mac 设置和旧 App Store `0.3.0` 数据格式不迁移；许可证变化不改变运行协议。

## 许可证与来源

- Yaha Desk 自有源码统一为 GNU GPL v3；MIT/Apache-2.0 等第三方代码继续保留原许可证和
  notice，并作为 GPLv3 兼容组件分发。
- TypeWhisper 来源：<https://github.com/TypeWhisper/typewhisper-mac>，`v1.8.2`，GPLv3。
- MLX Audio 来源：<https://github.com/TypeWhisper/mlx-audio-swift>，提交
  `1fb13b441c1ad8aae4a23f6a2223e03e5e5b1738`；版本与 TypeWhisper `v1.8.2` 一致。
- Qwen3-ASR 模型来源：`mlx-community/Qwen3-ASR-0.6B-6bit`；模型许可证和归属随分发清单保留。
- Apple 商店版继续使用同一源码的小范围条件编译；正式提交前单独核对 GPL 文案、自定义 EULA、
  沙盒 PostEvent 和内置插件/模型下载政策。此处记录工程边界，不替代法律意见。

## 验证与发布边界

- 开发：先写会因 Paraformer 后端仍存在而失败的测试，再替换实现；运行桌面定向测试、完整
  `swift test`、`swift build -c release` 和相关打包静态检查。
- 真人：同一环境各说至少 10 次“今天下午三点开会，项目进度正常”，记录 Paraformer 与 Qwen
  原始输出、耗时和是否重复；没有该证据只写“候选实现完成”。
- 发布：代码验证、change-audit 和推送 `main` 后仍不自动安装或发布；App Store、Developer ID
  分发和固件动作继续逐次授权。

## 执行记录

- 2026-11-08：用户确认全量 GPLv3 与开源方向，并选择 TypeWhisper 的页面/交互作为 Mac 端参考。
- 2026-11-08：从最新 `origin/main` 建立独立 worktree；CodeGraph 初始化 1,623 个文件、
  26,562 个节点、67,854 条边，状态 `complete`，`pendingRefs=0`，无 worktree mismatch。
- 2026-11-08：核对现有调用链后确认无需再建第二个热键或录音器；P0 只替换既有
  `LocalSpeechRecognizer`，调用方、焦点写入、BlackHole 和音频尾部契约不变。
- 2026-11-08：Yaha Desk 产品源码、22 组需求与验证记录迁回公开 `yahamic` 仓库；闭源仓库只保留
  客户端仍依赖的 Desk 云端 API，不再作为桌面产品源码事实源。
- 2026-11-08：固定 Qwen 模型快照完成一次真实 MLX 推理；完整 Swift 测试 88 项通过，release
  build 与 dev App 资源装配通过。该证据验证运行链，不替代真实用户语音的 Paraformer/Qwen A/B。
- 2026-11-08：iOS `build-for-testing` 与 ESP-IDF 6.1 干净构建通过；本机缺少可启动的 iOS
  Simulator runtime，固件未刷写真机，均保留为未验证边界。本轮不上传或发布任何 App/固件。
