# yahamic/agent — Coding Agent 微内核

主从协调 + 图状态机 + 黑板共享状态三种架构的融合实验:**内核只管图、黑板与预算,一切业务都是插件**。第一个工作负载是 yahamic 项目自身的编码任务。

## 架构:「图是宪法,概率是决策点,黑板是血液,护栏是议会」

```
repo-scan ─┐(两源并发)
wiki-recall┴→ plan(概率决策:任务规划) → route(概率决策:选执行者)
   → execute(Pi GLM/Kimi、Codex) → verify(swift build / idf.py build)
   ↺ 验证失败且 rework<2 → 回到 route(换执行者返工)
   → capture(沉淀到 yahallmwiki) → report
```

- **图是宪法**:`graphs/coding.json` 声明拓扑;加载时静态校验——隐藏环、无 guard 的回边、悬空命名空间、未声明输出全部拒载。概率模型无权改图。
- **概率是决策点**:LLM 只在 plan/route 两个槽位输出结构化 JSON,过严格协议(单一 JSON 围栏,绝不从散文里找标记)才放行;失败降级到确定性默认候选,不自由重试。
- **黑板是血液**:节点间不点对点传参,统一读写 `facts` 命名空间(`repo/wiki/plan/assignments/execution/verify/report`),每次变更原子快照到 `.runs/<id>/blackboard.json`。
- **护栏是议会**:回边必须 `guard`(计数器上限 + `when` 谓词,如"verify.allPassed=false 才触发");`llm-calls` 预算计数;`PROCESS_CANCELLED` 永不当作可重试失败;终态由声明式 `outcome` 谓词判定,不靠节点自觉。

## 快速开始

```sh
cd agent
npm ci --ignore-scripts
node bin/yaha-agent.mjs demo      # 离线全图演示(fixture,零模型调用)
node bin/yaha-agent.mjs doctor    # 本机检查(配置/凭证/命令/wiki)
npm test                          # 31 项自动化测试
```

真实运行(会消耗 Coding Plan 额度并修改工作区):

```sh
node bin/yaha-agent.mjs run --task "修复 mac 端设备重连问题"
node bin/yaha-agent.mjs status --last
```

环境变量放在 `agent/.env`(参照 `.env.example`;`ZHIPU_API_KEY` 与 yahallmwiki 同款 Coding Plan 密钥,执行者凭证可复用 yahaagent 的)。配置见 `agent.example.json`,复制为 `agent.json` 后修改;相对路径相对 yahamic 仓库根解析。当前 `agent.example.json` 已按本机写好默认值(codex 走 `127.0.0.1:7890` 代理、验证命令为 `swift build`)。

## 终态语义

| 状态 | 含义 |
|---|---|
| `completed` | 执行者声明完成且 `outcome` 谓词通过(验证全绿)。仍建议抽查 diff |
| `needs_input` | 规划或执行提出具体问题;补充信息后重新 run |
| `blocked` | 验证未通过且返工预算耗尽 / 路由无候选 / 预算不足 |
| `interrupted` | 被取消;黑板与已完成产物保留在 `.runs/<id>/` |

注意:未配置验证命令时 `verify.allPassed` 为 `null`,按 `outcome` 判为 `blocked`(严格优于假阳性)。

## 插入 Agent 宿主(Codex / Claude Code / ZCode)

本内核的定位是**宿主的工具**:Codex/Claude Code 这类宿主 Agent 是外层的概率性大脑(Supervisor),图工作流是它们手里的确定性执行管道。已注册:

| 宿主 | 注册方式 | 状态 |
|---|---|---|
| Codex CLI | `~/.codex/config.toml` → `[mcp_servers.yahamic-agent]` + 项目根 `AGENTS.md` | ✅ 已注册(额度重置后可用) |
| Claude Code | 项目根 `.mcp.json` + `.claude/skills/coding-task`(软链到 `agent/skills/coding-task/SKILL.md`)+ `CLAUDE.md` | ✅ 已验证真实调用(首次需在 `claude` 里 approve 项目 MCP) |
| ZCode | `~/.zcode/cli/config.json` → `mcp.servers["yahamic-agent"]` | ✅ 已注册(重启会话生效) |

工具(4 个):`yaha_agent_run_task { task, graph?, demo?, waitMs? }`(`waitMs` 同步等待窗口:demo/短任务传 30000 一次拿终态;真实任务默认 0,拿 `runId` 轮询)、`yaha_agent_run_status { runId | latest }`、`yaha_agent_blackboard { runId, ns? }`、`yaha_agent_graphs`。同时只允许一个运行。

手动注册其他宿主(通用 stdio 形态):

```json
{ "mcpServers": { "yahamic-agent": { "command": "node", "args": ["<仓库路径>/agent/mcp-server.mjs"] } } }
```

插件分发形态保留:`agent/.claude-plugin/plugin.json` + `agent/skills/coding-task/SKILL.md`。

2026-11-01 验证:Claude Code 非交互(`claude -p --mcp-config .mcp.json`)真实调用 `run_task(demo, waitMs)` 成功转述终态与报告;Codex 已加载 AGENTS.md 与 MCP 注册(当次因账号额度耗尽未执行,额度 2026-11-04 重置)。注意:`claude -p` 在本机会因全局用户上下文过大报 "Prompt is too long",加 `--settings <空json>` 绕过,交互式会话不受影响。

## 内核与插件

| 层 | 文件 | 职责 |
|---|---|---|
| 内核 | `kernel/graph.mjs` | 图校验(宪法)+ 就绪集调度器(回边/重排队/护栏) |
| 内核 | `kernel/blackboard.mjs` | 共享状态、计数器预算、原子快照 |
| 内核 | `kernel/run.mjs` | 运行生命周期、检查点、终态机 |
| 内核 | `kernel/process.mjs` / `result.mjs` / `config.mjs` | 子进程契约 / 决策协议 / 配置(移植自 yahaagent) |
| 决策 | `plugins/plan.mjs` `router.mjs` `llm-glm.mjs` | 规划、路由、GLM HTTP(智谱 Coding Plan 端点) |
| 执行 | `plugins/coder.mjs` `coder-clis.mjs` `jev.mjs` | Pi/Codex CLI、Jev Choice(移植自 yahaagent) |
| 信息源 | `plugins/source-repo.mjs` `source-wiki.mjs` `wiki-client.mjs` | 仓库扫描、yahallmwiki MCP 召回 |
| 验证/沉淀 | `plugins/verifier.mjs` `sink-capture.mjs` `sink-report.mjs` | 命令验证、知识入队、报告 |
| 测试替身 | `plugins/fixtures.mjs` | 同 id fixture;`demo` 即真实图 + fixture 覆盖 |

已完成的真实冒烟(2026-11-01):GLM 决策点只读调用通过(usage 映射含 reasoning tokens);yahallmwiki MCP 真实检索通过;codex 登录检测通过。真实编码任务端到端尚未跑,首跑建议先在小事上验证。

## 与 yahaagent 的关系

`yahaagent`(兄弟仓库)是单体串行编排器;本目录把它的资产(process/result/plan 校验、codex/pi/jev/wiki 适配器、取消与预算语义)移植进微内核形态,串行循环换成就绪集调度,散落状态并入黑板。yahaagent 本体未改动。
