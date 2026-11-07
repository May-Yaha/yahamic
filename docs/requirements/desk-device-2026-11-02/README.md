# 桌面设备接入 yahaops（2026-11-02）

## 目标

用户要求：把 yahamic（ESP32-S3 圆屏 BLE 麦克风 + Mac App）复制进 yahaops，做一个深度定制的新子项目，
让 yahaops 能经自己的接口控制设备：推送 AI 日报，并让 agent 通过 MCP 下发指令。yahamic 仓库原样保留。

## 授权与范围

- 2026-11-02 用户批准计划（`~/.claude/plans/sunny-munching-parrot.md`）：新增子项目 `yahaops-desk/`，
  产品名与 Mac App 对外名统一为「Yaha Desk」，bundle id `com.yaha.desk`。
- 分支 `feat/desk-device`（worktree `yahaops-desk-wt`，基于 `origin/develop`）。提交、推送、刷机逐次征得同意；
  不发布生产。

## 决策与依据

| 决策 | 依据 |
| --- | --- |
| 云端链路走 Mac 中转，设备保持纯 BLE | 0.5.0 刚因配网问题去掉 Wi-Fi；MCP 是无状态 POST，服务端推不出去，只能客户端轮询 |
| Mac 用 OAuth `client_credentials` | OAuth token 的 `aud` 固定为 MCP，portal REST 拒收；机器客户端只能走 MCP 工具 |
| 新 scope `desk.write`（agent）与 `desk.sync`（Mac） | 下发与拉取分权：Mac 凭据泄露也只能拉指令、上报状态，不能下发卡片或静音 |
| 云端只能静音，不能开麦 | 远程开麦是隐私风险；开麦只在本机按键或 Mac 上操作 |
| 设备内置 GB2312 一级字库（28px，4bpp） | 旧字体只有 13 个短语，显示不了任意中文；实测 app 约 2 MB，4 MB 分区余 53% |
| 日报由 Mac 每 10 分钟查 `get_ai_report` | 不新增 worker 推送任务；日报 `overview` 恒为空，摘要取期号、前 3 条要点和 `metrics` |

## 链路

```
agent ─desk_send_card / desk_mute─▶ API（desk_command）◀─desk_pull 15s─ Yaha Desk ─BLE card/control─▶ 设备
                                                       ◀─get_ai_report 10min─┘
```

- BLE 新特征 card（N = 7）：`ttl u16 LE ‖ title ‖ 00 ‖ body`，≤ 512 字节，`ttl = 0` 清除；要求加密 + MITM 认证。
- 屏幕优先级：配对 > 讲话中 > 卡片 > 仪表盘/静音。
- Mac 游标在指令送达设备后才前进；设备离线时卡片留在云端，上线后重发。

## 验收点

1. store 测试：游标、过期、7 天清理、owner 隔离；desk 工具测试：scope 门禁，无开麦工具。
2. `bash deploy/verify-gates.sh` 全过。
3. Mac `swift build -c release` 无告警、`swift test` 通过（含 card 载荷多字节截断）。
4. 固件 `idf.py build` 通过，记录 app 大小与启动内部 RAM 余量。
5. 端到端：`desk_send_card` 后 15 秒内设备出现中文卡片；`desk_mute` 后设备静音；`desk_status` 显示在线；
   新一期日报出现日报卡片；讲话中收到卡片先 Live、松开回到卡片、到期回仪表盘。

## 不做

设备 Wi-Fi、SSE/WebSocket 推送、worker 定时推送、云端开麦、浏览器 OAuth 登录、设备管理页、多设备、
C++/Swift CI、修改 yahamic 仓库、生产发布。

## 进度

| 项 | 状态 |
| --- | --- |
| 子项目落位与改名（UUID 基址、`yahadesk-XXXX`、bundle id、socket 路径、0.1.0） | 完成 |
| 固件 card 特征、卡片屏、GB2312 字库 | 完成，`idf.py build` 通过，app 0x1e6340 字节；真机未验证 |
| Mac card 写入、CloudSync、云端面板、`cloud` 控制命令 | 完成，`swift build`/`swift test` 通过；联调未验证 |
| API scope、`desk_command`/`desk_state`（迁移 78；77 已被开放注册占用）、desk MCP 工具、Web scope 文案、协议契约 | 完成，`dao/store`、`handler/mcpingest`、`logic/oauth` 测试通过；web 门禁通过 |
| Mac 对齐 `desk_pull{ack}` 契约（`card`/`clear_card`/`mute`） | 完成，`swift build -c release` 无告警、`swift test` 8/8 |
| 审查修复：云端静音切到按住讲话（重连不再开麦）、旧固件卡片不堵队列、换客户端重置游标、过期卡片不占上限、上报固件版本 | 完成，desk Go 测试与 `swift test` 通过 |
| `verify-gates.sh` 全量 | 通过（exit 0；本机 python3 为 3.14，以 3.13 置于 PATH 前运行） |
| 端到端 | 未开始（需本地 API 与真机） |
