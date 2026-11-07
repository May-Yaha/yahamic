# yahamic 仓库的 Agent 指引

本仓库的编码任务(改 firmware/ 或 mac/ 代码、修 bug、加功能)默认走 **yahamic-agent 图工作流**,而不是直接动手改:

- 通过 `yahamic-agent` MCP server 的工具执行:`yaha_agent_run_task { task }`(真实运行,消耗 Coding Plan 额度并修改工作区)→ 轮询 `yaha_agent_run_status` → 终态后读 `yaha_agent_blackboard { ns: "report" }`
- 图工作流 = 召回(yahallmwiki)→ 规划(决策点)→ 路由(决策点)→ 执行(Pi GLM/Kimi、Codex)→ 验证(swift build)→ 返工护栏(rework≤2)→ 沉淀
- `demo: true` 走 fixture 离线演示,零模型调用,可随时用于自检链路
- 终态:`completed`(验证通过,仍建议抽查 diff)/ `needs_input`(把 questions 原样转述给用户,拿到答复后并入新任务重新 run)/ `blocked`(读黑板 `verify` ns 的 diagnostics 定位卡点)/ `interrupted`(不要自动重放)

以下情况不要调图工作流,直接做:纯问答、只读代码/解释、文档措辞级微调。

详细工具语义、异常自修与领域事实(ESP-IDF、代理、串口)见 `agent/skills/coding-task/SKILL.md`;架构与配置见 `agent/README.md`。

## 产品与安全约定

- Mac App 预置服务地址和公开 Client ID；需要密钥的官方控制连接只从安装方已获授权的来源写入本机钥匙串。新机没有该来源时应报告安装配置未完成并停止连接，不猜测、跨账号提取或把密钥写入源码、Git、日志、命令输出、分发资源和固件。浏览器登录、PKCE 同意与设备专用 `desk.sync` 授权不得绕过。
- 固件系统界面和固定文案使用简体中文，并核对字库覆盖、字号与屏幕宽度；动态通知保留来源原文，不擅自翻译或改写。协议字段、日志、标准单位与专有名称继续遵循既有契约。
- 构建、测试或模拟器通过不等于获准安装、烧录、上传商店或发布；这些外部动作仍需用户逐次明确授权。
