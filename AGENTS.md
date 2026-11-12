# yahamic 仓库的 Agent 指引

本仓库的编码任务(改 firmware/ 或 apps/macos/ 代码、修 bug、加功能)默认走 **yahamic-agent 图工作流**,而不是直接动手改:

- 通过 `yahamic-agent` MCP server 的工具执行:`yaha_agent_run_task { task }`(真实运行,消耗 Coding Plan 额度并修改工作区)→ 轮询 `yaha_agent_run_status` → 终态后读 `yaha_agent_blackboard { ns: "report" }`
- 图工作流 = 召回(yahallmwiki)→ 规划(决策点)→ 路由(决策点)→ 执行(Pi GLM/Kimi、Codex)→ 验证(swift build)→ 返工护栏(rework≤2)→ 沉淀
- `demo: true` 走 fixture 离线演示,零模型调用,可随时用于自检链路
- 终态:`completed`(验证通过,仍建议抽查 diff)/ `needs_input`(把 questions 原样转述给用户,拿到答复后并入新任务重新 run)/ `blocked`(读黑板 `verify` ns 的 diagnostics 定位卡点)/ `interrupted`(不要自动重放)

以下情况不要调图工作流,直接做:纯问答、只读代码/解释、文档措辞级微调。

详细工具语义、异常自修与领域事实(ESP-IDF、代理、串口)见 `agent/skills/coding-task/SKILL.md`;架构与配置见 `agent/README.md`。

## 目录与文档归档

- 顶层分两块：`firmware/`（ESP32-S3 固件）与 `apps/<平台>/`（`shared` 为 macOS/iOS 共用 Swift 包，`macos`、`ios`，后续 `android` 同级新增）。`agent/` 是图工作流，`docs/` 是文档。
- 「先证明能不能做」的 demo 与可行性验证放 `test/<主题>/`：自带 README（问题、步骤、结论、踩坑），能独立构建，不依赖也不改 `apps/`、`firmware/`，不进 CI 和发布包，bundle id 与 BLE UUID 与正式产品错开；结论写回对应需求文档，并在 `test/README.md` 登记一行。单元测试跟着各端走，不放 `test/`。
- `docs/requirements/` 只放近两天的需求：目录名日期早于「今天 − 2 天」的整目录 `git mv` 到 `docs/archive/requirements/`，同步更新两边的 README 索引。一次性报告、审计、迁移记录放 `docs/archive/reports/`。`architecture.md`、`cloud-contract.md`、`domain-glossary.md` 是长期文档，不归档，内容随代码更新。
- 每次新增需求文档时顺带检查归档；移动后修正所有相对链接（含 README、AGENTS.md 与其他需求文档里的引用）。

## 产品与安全约定

- Mac App 预置服务地址和公开 Client ID；需要密钥的官方控制连接只从安装方已获授权的来源写入本机钥匙串。新机没有该来源时应报告安装配置未完成并停止连接，不猜测、跨账号提取或把密钥写入源码、Git、日志、命令输出、分发资源和固件。浏览器登录、PKCE 同意与设备专用 `desk.sync` 授权不得绕过。
- 固件系统界面和固定文案使用简体中文，并核对字库覆盖、字号与屏幕宽度；动态通知保留来源原文，不擅自翻译或改写。协议字段、日志、标准单位与专有名称继续遵循既有契约。
- 构建、测试或模拟器通过不等于获准安装、烧录或发布 GitHub Release；这些外部动作仍需用户逐次明确授权。

## 百度网盘登录（快速授权）

- 链路：App 打开授权页拿 code，回调 `yahadesk://oauth` 直达 App；code 换令牌与续期走 hub `POST /api/v1/baidu-pan/desk/token`。百度换取必须带 `client_secret`（不带返回 20025），所以不能改成 App 直连百度，SecretKey 不得进入本开源仓库或安装包。
- App 的 `PanLogin.appKey` 必须与 hub 环境的 AppKey/SecretKey 属同一百度应用（AppID 124461637）。不一致时换取报 20038，登记在该应用下的回调也会报 20030。
- 回调地址由用户在百度控制台登记，未经同意不改 `redirect_uri`；登记清单见 `docs/archive/requirements/desk-pan-quick-oauth-2026-11-09/README.md`。
- 排障先看 errno：Mac 日志 `~/Library/Logs/YahaDesk.log` 的「网盘登录失败」行带 hub 透传的百度 errno。用假 code 请求 hub 返回 10401（而非 10506）说明 hub 自身密钥匹配。hub 由用户在服务器上手动发布，改完服务端先确认线上版本再复测。
