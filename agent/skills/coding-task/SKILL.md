---
name: coding-task
description: 用 yahamic-agent 微内核执行 yahamic 仓库的编码任务（改固件/Mac 端代码、修 bug、加功能）。当用户要求修改 yahamic 项目代码、修复麦克风/daemon/固件问题、或要求走"图工作流/微内核"跑编码任务时触发。
---

# yahamic 编码任务（图工作流）

## 意图触发

- 用户要求修改 yahamic 仓库（firmware/ 或 mac/）的代码、修 bug、加功能
- 用户提到"用 agent 微内核 / 图工作流跑一下这个任务"
- 用户要求带验证与知识沉淀的自动化编码

## 执行步骤

1. **MCP 工具是第一入口**（宿主已注册 `yahamic-agent` server）：
   - 自检/演示：`yaha_agent_run_task { "task": "链路自检", "demo": true, "waitMs": 30000 }` —— fixture 离线跑全图,一次调用直接返回终态
   - 真实任务：`yaha_agent_run_task { "task": "<任务描述>" }` → 拿 `runId`（真实执行可能数分钟，不要传大 waitMs 阻塞）
   - 轮询 `yaha_agent_run_status { "runId": ... }`（或 `{ "latest": true }`）直到终态
   - 终态后读 `yaha_agent_blackboard { "runId": ..., "ns": "report" }` 拿可读汇总；
     需要细节按需读 `plan` / `assignments` / `execution` / `verify` 命名空间
2. **没有 MCP 时退化为 CLI**（在 yahamic 仓库根执行）：
   ```bash
   cd agent && npm ci --ignore-scripts   # 首次
   node bin/yaha-agent.mjs run --task "<任务描述>"
   node bin/yaha-agent.mjs status --last
   ```
3. **终态语义**：
   - `completed`：执行者声明完成且验证命令通过。仍建议抽查 diff。
   - `needs_input`：返回里有 `questions`，逐条向用户转述，得到答复后带补充信息重新 run。
   - `blocked`：读 `verify` 命名空间的 diagnostics 与 `reason`，向用户报告卡点。
   - `interrupted`：被取消，现场保留在 `.runs/<runId>/`，不要自动重放。

## 领域事实（写给决策与排障）

- Mac 端有 `YahaDeskTests` 与 `DeskProtocolTests`：至少执行 `swift test` 和 `swift build -c release`；本地听写改动另跑 `swift test --filter LocalDictationTests`。
- iOS 工程由 `ios/project.yml` 生成；验证使用 XcodeGen + `xcodebuild`，不能把 Mac 测试通过当成 iOS 已验证。
- 固件验证 = `idf.py build` 与 `firmware/tests/README.md` 列出的 host tests，需先加载 ESP-IDF 6.1 环境。刷机、量产分区和设备数据动作仍需单独授权。
- 产品版本以 `firmware/CMakeLists.txt`、`mac/scripts/make-app.sh` 和 `ios/project.yml` 三端一致为准（当前 0.3.0）。
- 当前音频主链路为 ESP32-S3 BLE GATT Opus → `DeskCore` → BlackHole；云端内容走 Wi-Fi，不能恢复已删除的 Wi-Fi 音频 daemon。
- 本地听写复用同一 Fn、PCM capture 与最终文字写入链路；Qwen3-ASR 模型权重是本机缓存，不进入 Git。
- Codex 子进程走本机代理 `http://127.0.0.1:7890`（配置于 `agent/agent.json`）
- 图拓扑：repo-scan + wiki-recall → plan(决策) → route(决策) → execute → verify →(失败且护栏允许)↩ route → capture + report
- 返工护栏：`rework` 计数器上限 2；LLM 决策预算 `llmCalls` 上限 40

## 敏感边界（清理/重构前必读）

- `mic_state` 是静音唯一状态入口；按键、Mac 遥控和断链都必须汇合到这里，不能旁路开麦。
- BLE 配对、音频分片、Ogg/Opus 录音、DMS 出厂身份与 Wi-Fi 配置都已有回归测试；清理前先查 `docs/requirements/` 与 `firmware/tests/README.md`。
- `fac` 出厂身份、NVS 中的网络/配对/授权信息和百度网盘令牌不可随普通固件更新擦除；一键安装固件只写版本不同的程序相关分区。
- `desk_prepare_device` 只准备 OAuth 应用，不等于授权；token 只进入系统钥匙串或设备安全存储。
- 旧 Wi-Fi 版本的审计记录保留在 `docs/`，仅用于历史追溯，不能覆盖当前 BLE 架构事实。

## 异常自愈

- 报依赖缺失 / `Cannot find module`：`cd agent && npm ci --ignore-scripts`
- LLM `LLM_AUTH_ERROR`/401：检查 `agent/.env` 的 `ZHIPU_API_KEY`（与 yahallmwiki 同款 Coding Plan 密钥）
- `CODEX_SUBSCRIPTION_REQUIRED`：`codex login`（ChatGPT 订阅登录）
- 验证失败：读黑板 `verify` ns 的 diagnostics（编译错误在尾部 4KB），把关键错误并入下一次 `--task` 重新 run，或人工修复
- wiki 相关报错（`WIKI_*`）：知识沉淀是尽力而为，不影响编码结果；可用 `node bin/yaha-agent.mjs doctor` 检查 `../yahallmwiki/dist/mcp.js`
- **执行者（kimi/GLM）多子任务"决策点未返回结构化 JSON"成批失败**（run 20261101125833 出现 4 个、run 20261101133535 固件 5 个全挂而 Mac 任务同 run 通过）：是决策协议拒收，不是代码问题。对策：把大任务拆小、任务书少留自由发挥空间（逐项给文件与符号锚点）、或重跑让 router 换执行者；同一 run 里已完成的子任务成果保留，重跑只补失败项。
- **DECISION_NOT_JSON ≠ 没改文件**：执行者常在协议失败前已把改动做完（run 20261101133535 固件 5 个"失败"子任务的 diff 全部落地且质量合格）。终态后必须以动手前快照做全量 diff 对账，不能只信 status 字段。
- **verify 盲区**：verify 只跑 agent.json 里配置的命令（当前仅 `swift build`）；固件子任务失败时 Mac 侧构建照样绿，outcome 会把整 run 判成 `completed`。看终态后要读 execution ns 确认每个子任务状态，别把 completed 当全绿。
- **"同时一个运行"是 per-process 限制**：每个宿主会话各自的 mcp-server.mjs 进程独立计数，多会话并发 run 会同时写同一工作区（2026-11-01 实测三 run 并发）。多会话并行前先对表分工；run 终态后一律快照 diff 对账。
- **版本号统一看三端**：固件 `PROJECT_VER`、make-app.sh `VERSION`、iOS `CFBundleShortVersionString` / `MARKETING_VERSION` 必须同值（现 0.3.0）；执行者不能单向拿旧端覆盖新端。
