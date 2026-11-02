---
name: coding-task
description: 用 yahamic-agent 微内核执行 yahamic 仓库的编码任务（改固件/Mac 端代码、修 bug、加功能）。当用户要求修改 yahamic 项目代码、修复麦克风/daemon/固件问题、或要求走"图工作流/微内核"跑编码任务时触发。
version: 0.5.0
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
   - 中止当前运行：`yaha_agent_cancel {}`（宿主断开 stdio 时也会自动中止）
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

- mac 端验证 = `swift build` + `swift test`（均在 mac/ 下跑）；固件验证 = `idf.py build`，需先 `source ~/esp/esp-idf/export.sh`
- Mac 端最低系统 macOS 26（Package.swift `.macOS(.v26)`）
- 设备串口 `/dev/cu.usbmodem31301`(以 `ls /dev/cu.usbmodem*` 为准)；刷机前工具会自动备份 flash
- Codex 子进程走本机代理 `http://127.0.0.1:7890`（配置于 `agent/agent.json`）
- 图拓扑：repo-scan + wiki-recall → plan(决策) → route(决策) → execute → verify →(验证失败或有子任务执行失败，且护栏允许)↩ route → capture + report
- 返工护栏：`rework` 计数器上限 2；LLM 决策预算 `llm-calls` 上限 40；Codex 执行次数记在 `codex-calls` 计数器（受 `limits.maxCodexExecutions` 约束）
- `completed` = 验证全过 **且** 每个计划任务最新一次执行为 completed（`execution.allCompleted`）；`execution.history` 跨返工轮次只追加
- 跨进程运行锁 `.runs/.lock`（内容为 pid）：CLI `run` 与 MCP run 都要先拿锁；持锁进程已死则视为过期自动替换

## 逃生舱与敏感区（清理/重构任务动前必读，2026-11-01 审计确认）

- **dump 屏幕回传是活的**：control 特征写 `0x02` → `consume_dump_request` → `board::dump_rows`，Mac 端 `Uplink.sendDump()`（HomeModel `dump` 命令）可触发，是远程"看"设备 UI 的排障通道。不许删。
- **台架自检**：`audio::self_test()`，Kconfig `CONFIG_YAHAMIC_SELFTEST` 开关（当前未启用）。是"不连 Mac 也能验麦克风链路"的逃生舱，可包进同一 `#if` 省空间，不可直接删除。
- **Dashboard 空闲仪表盘已接线（勿当死代码清理）**：固件端 dashboard 特征接收 + `compose_dashboard` 绘制；Mac 端 `Uplink.sendDashboard`（YahamicCore/Link/Uplink.swift）由 `YahaHome/Model/HomeModel.swift`（菜单栏 App 定时器）调用，采集器为 `YahamicCore/Metrics/MetricsCollector.swift`。
- **待用户确认的死代码（作者注明"保留"，清理需用户点头）**：`draw_waves()`（canvas 版对照）、`draw_level`+`compose_bar`+`Screen::level`（响度条旧路径）、`set_brightness()`、`text_zh.h` 未用短语（on_air 大字/release_fn/battery）、FnListener 调试日志。
- 完整审计结论与决策记录：`docs/evolution-2026-11-01-audit-cleanup.md`。

## 异常自愈

- 报依赖缺失 / `Cannot find module`：`cd agent && npm ci --ignore-scripts`
- LLM `LLM_AUTH_ERROR`/401：检查 `agent/.env` 的 `ZHIPU_API_KEY`（与 yahallmwiki 同款 Coding Plan 密钥）
- `CODEX_SUBSCRIPTION_REQUIRED`：`codex login`（ChatGPT 订阅登录）
- 验证失败：读黑板 `verify` ns 的 diagnostics（编译错误在尾部 4KB），把关键错误并入下一次 `--task` 重新 run，或人工修复
- wiki 相关报错（`WIKI_*`）：知识沉淀是尽力而为，不影响编码结果；可用 `node bin/yaha-agent.mjs doctor` 检查 `../yahallmwiki/dist/mcp.js`
- **执行者（kimi/GLM）多子任务"决策点未返回结构化 JSON"成批失败**（run 20261101125833 出现 4 个、run 20261101133535 固件 5 个全挂而 Mac 任务同 run 通过）：是决策协议拒收，不是代码问题。对策：把大任务拆小、任务书少留自由发挥空间（逐项给文件与符号锚点）、或重跑让 router 换执行者；同一 run 里已完成的子任务成果保留，重跑只补失败项。
- **DECISION_NOT_JSON ≠ 没改文件**：执行者常在协议失败前已把改动做完（run 20261101133535 固件 5 个"失败"子任务的 diff 全部落地且质量合格）。终态后必须以动手前快照做全量 diff 对账，不能只信 status 字段。
- **verify 盲区**：verify 只跑 agent.json 里配置的命令（当前 `swift build` + `swift test`，不含固件构建）；固件子任务改坏了但执行者报 completed 时 Mac 侧照样绿。执行失败的子任务现在会让 outcome 判 `blocked`，但"执行者自称完成"仍要抽查 diff。
- **同时一个运行**：`.runs/.lock` 跨进程生效，多会话并发 run 会拿到 `RUN_LOCKED`；等前一个终态或 `yaha_agent_cancel` 后再起。run 终态后一律快照 diff 对账。
- **版本号统一看 CMakeLists**：固件 `PROJECT_VER`（firmware/CMakeLists.txt）与 make-app.sh `VERSION` 两处须同值（现 0.5.0）；执行者可能把别的端往本端旧值对齐，方向要盯住。（yahamic-mcp MCP 桥已于 2026-11-01 移除，不再有 serverInfo 第三处。）
