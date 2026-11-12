# 视频字幕与翻译(2026-11-12)

## 问题

看视频、开会时想要实时字幕和翻译:直接采集 Mac 正在播放的声音,自动出字幕,显示在视频下方。

## 选型

| 环节 | 用了什么 | 没用什么、为什么 |
| --- | --- | --- |
| 采集系统声音 | Core Audio Process Tap(macOS 14.2+,写法参照开源 [insidegui/AudioCap](https://github.com/insidegui/AudioCap)):全局单声道 tap 排除本进程,挂私有聚合设备 | ScreenCaptureKit 也能取音频,但要屏幕录制权限且带视频流;BlackHole 回环要用户改系统输出 |
| 识别 | 复用本地听写的 Qwen3-ASR 0.6B 6-bit(`LocalSpeechRecognizer`,模型已缓存约 826 MB,多语种自动识别) | 再引入 Whisper/WhisperKit 要多一份模型;Qwen3 已在本机、离线、中英日韩都能识别 |
| 翻译 | Apple Translation(`TranslationSession(installedSource:target:)`,离线,免 Key);语言对没装离线包时,填了 AI Key 就走 AI 润色同一个接口翻译 | 系统翻译的语言包只能由用户在系统设置里下载,App 内 `installedSource` 不会自动下载 |
| 显示 | 复用讲话浮层的 `OverlayPanel` 与 `CaptionText`(打字动效),贴在前台 App 最大窗口内底部居中 | — |

豆包输入法不能复用:它只在按住自己的语音键时录**系统默认输入**并上屏到输入框,没有开放的识别接口,
也不会持续识别系统输出声音。

## 改动

- `DeskCore/Audio/SystemAudioTap.swift`:tap + 聚合设备 + IOProc,Float32 多声道混单声道,盒式平均降到 16 kHz Int16(`Downsampler`)。
- `HomeModel+LiveCaption.swift`:每 250 ms 取一次新音频;尾段超 6 s 在最安静处切一刀定稿(复用 `LiveTranscript.cut`),
  字幕显示「上一句定稿 + 当前尾段」最后 80 字;连续 2 s 安静就清空并收起字幕。
  原文语言(`NLLanguageRecognizer`,限定中英日韩法德西俄,否则短句常被认成西班牙语、匈牙利语)与目标语言相同不翻;
  同一时刻只跑一个翻译,跑完接着翻最新那句(新字一来就取消旧翻译的话,翻译永远跑不完)。与听写共用 `localSpeech`,
  不占麦克风采集闸门。
- `SubtitleOverlay.swift`:原文一行(大字)+ 译文一行(小字、次要色),非激活、不接鼠标。
- 菜单栏面板新增「视频字幕」组:开关、翻译开关、目标语言(简体中文/英语/日语/韩语)。
- `make-app.sh`:Info.plist 加 `NSAudioCaptureUsageDescription`(缺它 tap 只收到静音)。

## 使用

1. 菜单栏面板 → 视频字幕 → 打开;首次会弹「录制系统音频」授权(系统设置 → 隐私与安全性 → 屏幕与系统录音 → 仅系统录音)。
2. 翻译缺语言包时日志会提示:系统设置 → 通用 → 语言与地区 → 翻译语言,下载对应语言。
3. 设置 → 语音 → 离线模型(`Services/OfflineModels.swift`):
   - Qwen3-ASR 0.6B:看状态与占用,下载(带进度、可取消、断点续下)、在访达中显示、删除。本地转文字或视频字幕开着时不让删;删前先放掉内存里的模型。
   - 字幕翻译语言包:列出可识别的原文语言 → 当前目标语言,显示已安装/可下载/不支持;点「下载」由系统弹框确认下载。删除只能在系统设置里(系统不开放),页面上有跳转按钮。装好后字幕翻译立即改走系统离线翻译(未装的语言对每次重新查)。

4. 有译文时译文是主字幕(大字),原文小字一行对照。送翻译的是按句取的最后两句(`HomeModel.captionWindow`):去掉 um/uh,不从半个词开始,停顿切段时 ASR 补的句号去掉,和下一段接成一句。

## 已知限制

- 字幕延迟约 1–2 s(每轮重转尾段);按住讲话转文字时字幕会晚一拍(两者串行用同一模型)。
- 盒式降采样只够 ASR,不用于回放。
- 浮层跟随前台 App 的最大窗口;画中画、多显示器全屏等情况未专门适配。

## 验证

- `swift build`、`swift test`(新增 `pcmBufferTakeDrainsWhatWasAppended`、`systemAudioDownsamplesToSixteenKilohertz`)通过。
- 离线模型页:`swift build`/`swift test` 通过,已 `make-app.sh --install --dmg` 装机;下载、删除按钮的真机操作待确认。
- 真机:待装机后播放视频确认出字、授权弹框与翻译。
