# 桌面录音只留本人声音：自训目标说话人提取模型（2026-11-07）

## 目标与决定

用户要求网盘录音「只保留本人的声音，其他的都不要」，模型集成在 macOS App 内。调研后没有可商用、16 kHz、
能直接进 Core ML 的现成模型，用户 11-07 决定**后续自己训练模型**；本文是训练与接入的交接文档，本批不写代码。

- 要解决：别人说话（含与本人重叠的部分）、环境噪声、静音段。
- 只做离线：录音结束后、上传网盘前处理；BlackHole 实时输出和听写不经过模型。
- 不改固件，不改网盘里已有的录音。

## 为什么要自训（11-07 调研）

| 候选 | 不能直接用的原因 |
| --- | --- |
| [LocalVQE](https://github.com/FluidInference/FluidAudio/blob/v0.17.7/Documentation/Enhancement/LocalVQE.md)（已装） | 只降噪/去混响，不区分说话人；Beta；11-07 远场 TTS 样本上语音段 27→6，过度抑制 |
| 声纹门控（WeSpeaker，已装） | 只能按段保留/丢弃，重叠语音里分不出本人 |
| [WeSep](https://github.com/wenet-e2e/WeSep) | 代码 Apache-2.0，v0.1 未发布预训练模型，README 写明暂不支持生产部署；**适合作训练框架** |
| [USEF-TSE ONNX](https://huggingface.co/bitsydarel/usef-tse-onnx) | 权重 CC BY-NC 4.0，禁止商用，上架版不能用 |
| [TD-SpeakerBeam Core ML 移植](https://github.com/rumiverse/ios-tse-models) | 8 kHz（电话音质）；Core ML 后 SI-SDR 16.20→14.85 dB；上游 [BUT 仓库](https://github.com/BUTSpeechFIT/speakerbeam) 未发权重，来源与许可查不清 |
| [OpenSpeakerBeam-SS](https://github.com/helloooideeeeea/OpenSpeakerBeam-SS) | 代码 MIT，但作者自评效果一般（约 5.9 dB SI-SNR），无 Core ML |

## 输入与输出约束（从现有代码得出）

| 项 | 现状 | 来源 |
| --- | --- | --- |
| 麦克风 | ES7210 四路只用通道 0，单声道；模拟增益 37.5 dB（芯片上限） | `firmware/main/audio.cpp` `kMicGainDb`、`channel_mask` |
| 采样 | 16 kHz、16 bit，60 ms 一帧（960 样本） | `audio.cpp` `kRate`、`kFrameSamples` |
| 编码 | Opus 32 kbps，Mac 原样封装 Ogg 上传 | `audio.cpp` `enc_cfg.bitrate`；`RecordingBackup.swift` |
| 本人参考 | 声纹档案：五段 2–6 秒 16 kHz WAV + WeSpeaker 256 维 embedding，存本机 | `VoiceProfile.swift`；[声纹档案需求](../desk-audio-quality-personal-voice-2026-11-07/README.md) |
| 输出 | 16 kHz 单声道，只含本人语音，再编 Opus 上传 | — |

模型输入应是 **Opus 32 kbps 解码后的 16 kHz 单声道**：训练数据要过同一编码，否则训练/实际分布不一致。

## 训练建议

- **框架**：WeSep（Apache-2.0），说话人编码器复用 WeSpeaker，与 App 里已有的 256 维 embedding 对齐，
  可直接用声纹档案当本人参考，不必再录一份。
- **结构**：选轻量、可导出 Core ML 的掩码类（如 TD-SpeakerBeam / Conv-TasNet 量级，约 7M 参数）；
  离线处理不要求流式，但按 1 秒左右分块推理，长录音内存可控。
- **数据许可（上架必看）**：只用允许商用的语料。LibriSpeech 为 CC BY 4.0 可用；**WHAM! 噪声为 CC BY-NC，
  不能用于商用模型**，噪声改用 CC0/CC BY 来源或自己录的办公/家里噪声。每份数据记许可和出处。
- **贴近真实**：训练混合里加入本设备录的本人语音、身边同事说话、风扇/空调/键盘噪声，统一过 37.5 dB 增益量级的电平与 Opus 32 kbps。
- **原始数据**：本人语音属于生物特征数据，训练用的原始录音不进 Git、不上传第三方训练平台，除非用户另行决定。

## 验收指标（接入前须达到）

先用 5–10 段真实网盘录音（含他人说话、重叠、噪声）建评测集，每段人工标注本人说话的时间段。

| 指标 | 含义 | 建议门槛（用户最终确认） |
| --- | --- | --- |
| 本人误删率 | 本人说话时长中被删/压掉的比例 | ≤ 2% |
| 他人残留率 | 他人单独说话时长中被保留的比例 | ≤ 5% |
| 重叠段 SI-SDRi | 本人与他人重叠时的提取质量 | ≥ 10 dB |
| 听写可用 | 处理后音频的听写字错率不高于原始音频 | 不劣化 |
| 速度 | M 系列 Mac 上 1 小时录音的处理时间 | ≤ 1 分钟 |

## 接入 Mac App 的位置（训练完成后）

1. 模型导出 Core ML（`.mlpackage`），随 App 资源打包或首用下载；在 `THIRD_PARTY_NOTICES.md` 记权重与数据许可。
2. 接在 `RecordingBackup.finish()` 之后、`upload()` 之前：Ogg Opus 解码 → 模型 → 重新编码 → 上传。
3. 没有声纹档案时不处理，原样上传并在界面提示先录声纹。
4. 原始录音在本机保留期限待定（建议 7 天，便于误删时找回）；网盘只放处理后的版本。
5. 回滚：去掉这一步即恢复原样上传，不影响固件和协议。

## 待用户决定

- 原始录音本机保留多久，或不保留。
- 验收门槛的具体数值。
- 训练数据的来源与是否允许带上同事的声音（需对方同意）。
