# Yaha Desk WiFi 直连云端（2026-11-03）

## 目标

用户要求：设备连上 WiFi 后，云端直接下发内容（最新采集的一篇文章、AI 日报、agent 卡片与静音），
不再依赖 Mac App 桥接。音频仍走 BLE → Mac → BlackHole。

## 授权与范围

2026-11-03 用户确认：

1. 鉴权用用户手动授权的 OAuth 2.1（授权码 + PKCE）。
2. WiFi 账号密码在 Mac App 面板填写，经加密 BLE 写给设备。
3. 只有设备拉指令，Mac App 不再拉。
4. 推送内容为「最新采集的一篇」与最新日报。

用户选方案 A 并要求「全部落地」：Mac 在浏览器走授权码 + PKCE（loopback 回调）拿 refresh token，
经加密 BLE 写入设备、Mac 不留存；设备自己续期、自己轮询。

分支 `feat/desk-wifi-cloud`（worktree `yahaops-desk-wifi`）。按项目默认授权提交推送 main，推送后经唯一入口
`YAHA-Mac` 上 `bash deploy/production-release.sh` 上线并核对生效（2026-11-03 默认授权）；**固件上传/烧录不在默认授权内**，逐次征得同意。

## 历史与边界核对

| 历史 | 结论 |
| --- | --- |
| 0.5.0 因配网问题去掉 Wi-Fi（yahaops-desk README「BLE 直连」对比表） | 当时 Wi-Fi 承载音频，靠手机热点配网 + 两端配对码。这次 Wi-Fi 只跑低频 HTTPS（15 秒一次 `desk_pull`），音频不动；配网改由已配对的 Mac 经加密 BLE 写入，不重走热点配网 |
| `desk.sync` 只给带 secret 的应用（2026-11-02，`handler.go`） | 原意是不让动态注册的智能体（拿全部 MCP scope）ack 掉排队的静音。放宽到「本人建的、只登记 `desk.sync` 的公开应用」（设备专用），仍挡住智能体（owner=-1）、别人的应用和兼登记其它 scope 的本人公开应用（审查指出这类多半给智能体用）；设备上没法安全存 client secret，只能用公开应用 + PKCE |
| 日报卡片排版在 Mac `CloudSync.dailyCard` | 移到服务端 `desk_feed`，固件只管显示，避免在 C++ 里解析日报 JSON |
| 文章列表无筛选时推荐优先 | 桌面要「最新采集」，新增 `IngestListWindow.Latest` 纯按采集时间倒序；现有调用方不传，行为不变 |
| 旧 Mac 客户端（`client_credentials` + desk_pull） | 批 1 不改它的路径，带 secret 的应用照旧可用；批 2 发布后用户删除旧机密应用 |

## 路线

| 批次 | 内容 | 提交 | 已推送 | 已生效 |
| --- | --- | --- | --- | --- |
| 1 API | `desk.sync` 放宽到本人设备专用公开应用；新 `desk_feed`；文案 Mac→设备；MCP 1.9.0 | 本批 | 待推送 | 待上线核对 |
| 2 固件 + Mac | 固件 WiFi STA + HTTPS + NVS（WiFi、client_id、refresh token）+ 续期 + 15 秒 `desk_pull` / 10 分钟 `desk_feed` + 讲话时暂停联网 + BLE 配网/授权/云端状态特征；Mac 面板 WiFi 字段与「授权设备」，删 CloudSync 拉取循环与 client_credentials | — | — | — |

批 2 依赖批 1 已部署生效。

## 验收点

1. `TestDeskPullRequiresOwnOrConfidentialClient`：智能体（owner=-1）、别人的公开应用、兼登记其它 scope 的本人公开应用不挂 `desk_pull`；本人只登记 `desk.sync` 的公开应用与带 secret 的应用挂。
2. `TestDeskFeedReturnsUnseenCards`：最新一篇按采集时间而非推荐优先；按权限过滤；已显示的 key 不重复；卡片 ≤509 字节且是合法 UTF-8。
3. `bash deploy/verify-gates.sh` 全过。
4. 批 2：`idf.py build`、`swift build`/`swift test` 通过；真机：授权后 Mac 退出，设备 15 秒内收到 `desk_send_card` 卡片、10 分钟内出现日报与文章卡片；讲话中音频不丢帧（对比讲话前后帧率与欠载计数）。

## 已知后果（已告知用户）

- 设备专用应用只能登记 `desk.sync` 一项：PC 表单切到公开应用时默认带 `reports.read`，不删掉就拿不到 `desk_pull`（不报错）。
- 设备没连 WiFi 就收不到卡片。
- 设备离线超过 30 天（refresh token 过期）须重新授权；续期时断电也可能须重新授权。
- refresh token 每次续期轮换，设备约每小时写一次 NVS。

## 不做

SSE/WebSocket 推送、worker 定时推送、云端开麦、设备管理页、多设备、设备上的配网界面、OTA。
