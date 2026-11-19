# 本机控制接口(压测与远程排障)

App 内置本机控制接口:Unix socket `~/Library/Application Support/YahaDesk/control.sock`
(目录 0700、socket 0600,并用 `getpeereid` 校验同一用户),每行一个 JSON 请求、一行
JSON 回复;单行上限 64 KB、最多 4 个并发连接、5 秒读超时。命令处理见
`apps/macos/Sources/YahaDesk/Services/ControlServer.swift` 与 `Model/HomeModel+Control.swift`:

```bash
printf '{"cmd":"status"}\n' | nc -U ~/Library/Application\ Support/YahaDesk/control.sock
```


| 命令 | 作用 |
|---|---|
| `status` | 全量状态(在线/静音/电平/帧率/缓冲/Fn 权限…) |
| `set_mute` | 遥控静音/开麦 |
| `set_ptt` | 切换「按住 Fn 讲话」/常开模式 |
| `devices` / `logs` | 输出设备列表 / 运行日志 |
| `metrics` | 采样 N 秒流指标(不动状态) |
| `stress` | **端到端压测**:自动常开麦克风(+可选 TTS 音源)采样 N 秒,结束恢复原状态,返回帧率/丢帧/缓冲/电平汇总 |
| `dump` / `capture` | 屏幕帧回传 / 诊断录制 |
| `cloud` | 工作台连接与在线状态 |
| `cloud_configure` | 已停用；应用使用预置连接，不通过控制接口接收凭据 |

(2026-11-01 起随包的 MCP 桥 `yahadesk-mcp` 已移除;需要 AI 代理控制时直接连 control.sock 即可。)
