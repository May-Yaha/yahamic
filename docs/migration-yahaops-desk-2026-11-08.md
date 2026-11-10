# yahaops-desk 迁回 yahamic（2026-11-08）

## 结论

`yahamic` 重新成为 Yaha Desk 的开源源码与项目记录唯一事实源；闭源 `yahaops` 只保留云端业务
实现，不再承载桌面设备源码。

## 来源与基线

- 目标仓库初始基线：`yahamic` `4f23296555fd22118f9c247d3745362a6139d2b6`；提交前已合并远端
  `main` `6622c69eb96278ff255486faed74817df9044407`，保留其 agent 运行时改进。
- 来源仓库基线：`yahaops` `0815a5582e747ae305f9e6fadba976d2da1689b6`。
- 来源工作分支：`codex/desk-unified-dictation-2026-11-07`；快照额外包含尚未合入来源仓库
  `main` 的 GPLv3 与 Qwen3 本地听写改造。
- 用户授权：产品源码可直接覆盖旧 `yahamic` 实现；相关需求、验收和验证记录一并迁移并开源。

## 覆盖与保留边界

直接覆盖：

- `firmware/`：当前 ESP32-S3 BLE 音频、屏幕、DMS 与云端状态实现。
- `mac/`：当前 Yaha Desk 菜单栏 App、DeskCore、DeskProtocol、测试与打包脚本。
- `ios/`：iOS 控制端源码、工程定义与测试。
- 根 `README.md`、`LICENSE`、`LICENSES/`，以及桌面设备架构文档。
- `docs/requirements/desk-*`：22 组需求、验收、验证和审计记录。

保留：

- `yahamic/.git` 及其原始 Wi-Fi 版本历史。
- `agent/`、`AGENTS.md`、`CLAUDE.md`、`.mcp.json`、`.claude/`、`.zcode/`。
- 迁移前的 `docs/baseline-code-audit.md`、`docs/evolution-2026-11-01-audit-cleanup.md` 与
  `docs/stress-report-2026-11-01.md`，作为旧 Wi-Fi 架构历史证据。

不迁移：

- `yahaops-api/`、`yahaops-worker/`、`yahaops-web/`、部署配置、生产数据或凭据。
- 本机构建缓存、固件备份、`sdkconfig`、模型权重和百度网盘中的用户语音数据。
- App Store 上传、Developer ID 发布、固件刷写和生产数据操作。

## 公开性检查

迁移前对产品源码与 `desk-*` 记录扫描了私钥、常见 API key、OAuth secret、访问令牌和密码模式；
未发现真实凭据。命中项为协议字段、测试占位 token 和测试 Wi-Fi 密码。后续仍以 Git staged diff
和仓库门禁复核，任何真实凭据不得进入提交历史。

## 验证状态

| 项目 | 状态 | 证据或阻塞 |
| --- | --- | --- |
| 快照覆盖 | 已完成 | 产品目录与 22 组记录已进入迁移分支 |
| 远端并发变更 | 已合并 | 保留 `6622c69` 的 agent 运行时与 47 项回归；11 月 2 日的旧命名产品实现由 11 月 8 日迁移快照覆盖 |
| Mac 定向测试 | 已通过 | `swift test --filter LocalDictationTests`：8 项通过，真实模型用例默认按环境变量跳过 |
| Qwen 真实推理 | 已通过 | 使用本机既有 TypeWhisper 固定快照与临时 16 kHz PCM；`qwenRecognizesAReal16kPCMFixture` 5.858 秒通过；未下载或提交权重 |
| Mac 全量测试 / release build | 已通过 | 全量 88 项测试通过；`swift build -c release` 通过；既有 warning 另列、不冒充零 warning |
| Mac 打包资源 | 已通过 | `.app` 中实测 `mlx-swift_Cmlx.bundle/default.metallib` 可完成 MLX GPU smoke；脚本保留 dev、Developer ID、App Store 三渠道及非商店固件装配 |
| iOS 测试 / 构建 | 测试可编译 | XcodeGen 成功；`xcodebuild ... build-for-testing` 成功；本机无可启动的 iOS Simulator runtime，未运行测试 |
| ESP-IDF 构建 | 已通过 | 删除迁移遗留的旧 ignored `sdkconfig` 后，以 `sdkconfig.defaults` 全量重建通过；host tests 全部通过 |
| 固件容量 | 风险保留 | `yahadesk.bin` 为 `0x3cd2a0`，4 MiB app 分区仅余 `0x32d60`（5%）；未刷写真机 |
| 闭源主工作区 WIP | 已补迁 | 清理前发现 codec 保温回滚与静音生命周期测试；迁入后 host tests 全过，`yahadesk.bin` 为 `0x3cd240`，未刷写真机 |
| 晚于来源分支的提交 | 已补迁 | 补迁 `faeb3992` 的 Mac 百度网盘默认浏览器回调、测试与需求记录；服务端回调实现继续留在 `yahaops-api` |
| 闭源仓库清理 | 待目标推送后 | 目标未验证、未推送前不删除来源 |

## 自动工作流取舍

按本仓约定执行了 `yahamic-agent` 图工作流（run `20261107162642-af51f5a7`）。其中依赖核对、单链路审计和
metallib 测试三项因执行器没有返回结构化 JSON 被标记失败；资源装配、三条 Swift 验证和范围守卫产出了可复核
证据。工作流曾把“本轮不执行发布”误解为“删除 Developer ID、App Store 与固件打包能力”，该变更已纠正：
不执行发布不等于删除发布通道。

## 本地听写资源约定

- 模型仓库固定为 `mlx-community/Qwen3-ASR-0.6B-6bit`，快照固定为
  `468b9b6d692d3397d5d17b84a1166876a00c9bfa`。
- `mlx-audio-swift` 固定 TypeWhisper revision
  `1fb13b441c1ad8aae4a23f6a2223e03e5e5b1738`，`mlx-swift` 固定 `0.31.6`，
  `swift-huggingface` 固定 `0.10.1`。
- 测试用例通过 `YAHA_QWEN_MODEL_DIR` 与 `YAHA_QWEN_PCM` 显式启用；测试进程把工作目录临时切到
  SwiftPM 测试包内的 metallib 目录，生产 App 则从 `Contents/Resources/mlx-swift_Cmlx.bundle` 加载。
- 模型权重、语音样本、声纹与百度网盘数据均为用户数据，不属于迁移提交。
