# 桌面设备日报语音播报（2026-11-04）

## 目标

用户要求：设备轮播的第三屏（通知页）把 AI 日报变成语音播报，从设备扬声器出声，播放时同步显示字幕，音量在 Mac 面板调。

## 授权与范围

2026-11-04 用户确认：

1. 出声：设备扬声器（ES8311）。音量：Mac 面板滑块。
2. 合成：~~智谱 GLM-TTS~~ → 2026-11-04 生产首跑（run 98aa9b43）GLM-TTS 被拒（1 次请求、0 token），用户改为生产机本地合成：sherpa-onnx 2.0.1 + MeloTTS 中英模型 `vits-melo-tts-zh_en`（MIT），模型放宿主目录只读挂载，后续发布不重复下载。
3. 播报内容：日报全文；每期只合成一次，设备每期只自动播一次；通知页停留到读完，讲话键立即停播。
4. 存储：合成结果上传到已授权的百度网盘连接，之后从网盘取内容消费；未完成网盘授权时不启用播报。

本需求只覆盖日报。文章卡片与 agent 消息不播报。
固件烧录、生产数据修改不在默认授权内，逐次确认。

## 历史与边界核对

| 历史 / 事实 | 结论 |
| --- | --- |
| 生产 `GLM_BASE_URL` 为 Coding Plan 端点（`docs/requirements/article-risk-audit-2026-10-24/production-inventory.md:94`）；官方 FAQ 写明套餐 Key 与标准 API Key 不通用、自建应用须走标准 API | GLM-TTS 只在标准 API `/api/paas/v4/audio/speech`。用户要求复用同一凭据，**能否调通未验证**；任务上线时在 catalog 中保持暂停，用户在 YAHA-Mac 试调通过后再在 `/worker-center` 恢复 |
| GLM 客户端 `send` 只发 `/chat/completions`，响应限 256 KiB 且必须是 UTF-8（`lib/integration/glm/client.go`） | 新增独立的语音方法，复用同一五并发租约与用量账本，不改对话路径 |
| 当天的日报在每轮 `hot-report` 中重算（`yahaops-worker/yahaops_worker/hot.py` `specs()`） | 「每期只做一次」= 只合成上海时区昨天那一期（不回补更早期），合成成功后不再重做；合成后才补进昨天日报的条目不再播报；合成后有条目被撤下、转私密、风控隐藏或重排出该期，整期播报不再下发（不重合成） |
| 日报内容按查看者可见性渲染，个人私有提交只对 owner 可见（`dao/store/article_access.go`） | 一期只合成一份，脚本只取公开（`private=0`）且通过风险展示的条目，避免把某人私有内容播给别人 |
| 百度网盘连接为简化授权，令牌不能刷新（领域词汇表「访问令牌授权」）；dlink 必须附带 access_token | 网盘令牌只留在服务端；设备经 API 取音频，API 用服务端令牌从网盘下载后转发 |
| 设备 MCP 响应上限 192 KiB、单次请求 8 秒（`firmware/main/display_json.h`、`cloud.cpp`） | 音频不走 MCP，另开 REST 接口，鉴权沿用设备的 `desk.sync` MCP 令牌 |
| 设备 I2S0 为 16 kHz TDM 采集，ES8311 与 ES7210 共用时钟 | 设备只收 16 kHz s16le 单声道 PCM；网盘存 MeloTTS 原始 44.1 kHz WAV，API 转发时线性重采样（无低通，批 3 真机音质不够再加） |
| Matcha zh-en 词表无英文，会丢 AI/OpenAI/GPT；Kokoro 418 MB；Melo 197 MB、M4 上 30.9 s 音频 10.8 s 合成 | 选 Melo（用户偏好语气）；Intel 生产机速度未实测；Melo 不读 `%`、`；`，合成前改写为「百分之」「，」 |
| task-go 镜像即任务镜像，已含 Python 与哈希锁 | `sherpa-onnx` 进 `tasks-requirements.lock`（extra `speech`）；Go `desk-tts` 以子进程调 `python3 -I -m yahaops_worker.speech`，不迁运行池；不再用 GLM 租约与用量账本 |
| 发布脚本为一页自包含入口 | 第 2 步（构建代理内、改服务前）宿主 `$RUNTIME/tts-models/vits-melo-tts-zh_en` 缺失才下载 167 MB 包，sha256 `e58351ed…1514` 校验后整目录换入；失败「服务未改动」 |
| 联网后内部堆约 20 KB（`desk-carousel-2026-11-03/verification.md:157`） | 固件批次必须真机压测，DMA 缓冲预算先算清 |

## 数据形状

- 网盘目录：`<网盘根>/desk-tts/daily/<key>/NN.wav`（每条日报条目一段，单段不超过 1024 字）。
- 门户库 `desk_narration`（迁移 85）：`key`（日报期号）主键，`status`（`running`/`done`）、`manifest_json`、`updated_at`。每段上传后即写回 manifest（running），中断后续跑复用序号与文本未变的段。
- manifest（库内）：`{key, issueNumber, title, sampleRate, durationMs, segments:[{postId, path, fsId, durationMs, text, cues:[{startMs,endMs,text}]}]}`；`desk_feed` 下发的 `narration` 为 `{key, issue_number, title, sample_rate:16000, duration_ms, segments:[{duration_ms, cues:[{start_ms,end_ms,text}]}]}`（不含网盘路径、fsId 与段原文），仅在每段条目此刻仍出现在本人可见的同期日报里、且设备回传的 `narrated` 与最新完成期不同时返回。音频接口只服务最新完成期，同一道日报阅读权限。合成不返回时间戳，字幕按句切分、按字数在段时长内分配，只做到句级同步。

## 迁移路线

| 批次 | 内容 | 风险 | 状态 |
| --- | --- | --- | --- |
| 1 服务端 | ~~GLM 语音方法~~ 本地 MeloTTS；`desk_narration` 表；Go 任务 `desk-tts`（合成→上传网盘→记 manifest，暂停上线）；设备音频接口 `GET /api/v1/mcp/desk/narration?key=&segment=`（16 kHz PCM 段）；`desk_feed` 新增 `narration` 字段与 `narrated` 入参 | 中：网盘写入、任务镜像新依赖与宿主模型 | 已上线；本地合成待发布 |
| 2 Mac | 面板音量滑块，BLE control 新命令写设备音量 | 低 | 未开始 |
| 3 固件 | ES8311 播放、按段流式下载、句级字幕、每期播一次、讲话打断、通知页延长到读完 | 高：内存、无线共存、需烧录授权 | 未开始 |

## 进度

- 2026-11-04：完成对齐与历史核对；worktree `yahaops-desk-tts`，短分支 `feat/desk-tts`，基线 `818b2e34`。
- 2026-11-04：批 1 实现与单测完成：`glm.Speech`、`lib/wav`（解析 + 16 kHz 线性重采样）、`desk_narration` 表、`yahaops-worker/internal/desknarration` 与 jobrunner `desk-tts`（catalog 新队列 `desk-tts`，每小时 :20，暂停）、`GET /api/v1/mcp/desk/narration`、`desk_feed.narration`。GLM-TTS 能否用现有 Coding Plan 凭据调用仍未验证，任务保持暂停；设备侧（批 2、3）尚未开始。
- 2026-11-04：生产首跑 GLM-TTS 失败，诊断阶段日志 `af21a59d` 已推送。改本地 MeloTTS：worktree `yahaops-desk-local-tts`，短分支 `feat/desk-local-tts`，基线 `af21a59d`；删除 `glm.Speech`。镜像构建、linux wheel 加载、Intel 合成耗时本地无法验证，发布后核对。
