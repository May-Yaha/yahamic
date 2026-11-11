# Mac 百度网盘登录改用默认浏览器并回调 App（2026-11-07）

## 结论

Mac 网盘登录改用 `ASWebAuthenticationSession`：macOS 把授权交给默认浏览器（不支持认证会话时由系统回退 Safari），百度仍回调生产已登记的门户地址，隔离回调页再用 Mac 专用 state 把 fragment 交还当前 App 会话；不再创建内嵌 `WKWebView`。

## 目标与边界

用户反馈：macOS 点击百度登录后没有回到 App，并明确要求拉起过程使用默认浏览器，不使用 App 自建 WebView。

- 只修 Mac 百度网盘隐式授权；iOS、门户百度网盘管理授权、Yaha 工作台 OAuth 均保持原路径。
- 复用已登记的 `https://hub.flyaha.top/api/v1/baidu-pan/callback`，不新增百度后台回调地址或服务。
- 保留 `response_type=token`、随机 state 校验、令牌只存本机钥匙串、不进 query/日志/服务端的契约。
- 不自动部署 API、不重装或发布 Mac App；真实百度账号登录需发布后人工验收。

## 历史与依据

- [桌面网盘与录音需求](../desk-pan-dms-2026-11-05/README.md)确认 Mac 与服务端复用同一百度应用，旧实现用 `WKWebView` 拦截授权页 fragment。
- [百度网盘简化模式官方文档](https://pan.baidu.com/union/doc/使用入门/接入授权/简化模式接入/)要求 `redirect_uri`，并把 token 放在回调 URL fragment；[回调地址文档](https://pan.baidu.com/union/doc/使用入门/接入授权/授权回调地址/)说明回调地址由控制台登记，本地地址不可用。
- [Apple ASWebAuthenticationSession 文档](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession)说明 macOS 使用默认浏览器（不支持时回退 Safari），并将匹配的回调只交给发起会话的 App；[回调 API](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession/callback/customscheme(_:))支持自定义 scheme。
- 生产 nginx 已对现有回调关闭访问日志、缓存与 referrer；本次不改网关配置。

## 实现与验收

| 优先级 | 行动 | 负责人 | 截止时间 | 依赖 | 验收标准 |
| --- | --- | --- | --- | --- | --- |
| P0 | Mac 用系统认证会话打开授权页 | Agent | 本次 | macOS AuthenticationServices | Mac 分支不引用或创建 `WKWebView`；授权 URL 使用已登记 HTTPS 回调 |
| P0 | 回调页桥接 Mac 专用 state | Agent | 本次 | 现有门户回调路由 | 仅 `yahadesk-macos.` state 转到 `com.yaha.desk:/baidu-pan/oauth`；网页管理 state 继续同源 POST |
| P0 | 严格校验 App 回调 | Agent | 本次 | 随机 state | scheme、host、path、state、重复字段和 query 中敏感字段不符均拒绝 |
| P1 | 本地门禁与独立审计 | Agent | 推送前 | Swift/Go 工具链 | 定向测试、`swift test`、完整门禁和 change-audit 通过 |
| P1 | 发布后真实登录验收 | 用户 | 手动发布后 | 百度账号、已安装 Mac App | 默认浏览器授权后回到 App，界面显示“已登录百度网盘” |

## 验证记录

- TDD 红灯：Mac 专用常量和回调缺失时 Swift 编译失败；桥接脚本缺失时 Go 回归失败；独立审查补充的“普通 iOS state 不得接受 Mac 自定义 scheme”在修复前明确返回了错误 token。
- Mac：同步最新 `main` 后执行 `swift build && swift test` 通过，YahaDesk 61 项、DeskProtocol 26 项，共 87 项。
- iOS 兼容：正常签名的 iPhone 模拟器 `xcodebuild test` 通过，20 项、0 失败；禁用签名会使既有 Keychain 用例失败，不作为产品回归结论。
- API：`go test ./server/handler/baidupan ./router -count=1` 通过；行为测试实际执行回调脚本，确认 Mac 不向服务端 POST token、门户授权仍走同源 POST。
- 仓库门禁：审查前后两次执行 `bash deploy/verify-gates.sh` 均退出 0；小程序自动回归 642 项通过、Web 112 个测试文件 / 621 项测试通过、Go 全仓通过。
- 独立审查两轮收敛：首轮发现 iOS 共享解析器信任边界扩大和脚本测试强度不足；补失败回归、最小修复及行为测试后，复核结论为 `Verdict: Ship`。

## 发布与回滚

本次同时影响 API 回调页和 Mac App。推送后由用户在 `YAHA-Mac` 手动执行唯一生产入口 `bash deploy/production-release.sh`，再构建/安装含本提交的 Mac App；只更新一侧不能闭合回调。回滚时 API 与 Mac App 一起回到前一版本，旧钥匙串 token 格式不变，无数据迁移。

## 风险与未验证

- OAuth 属高风险边界：回调 fragment 会先从浏览器历史清除，再交给系统认证会话；服务端不接收 Mac token。
- 默认浏览器若未实现 macOS Web Authentication Session，系统按 Apple 契约回退 Safari；仍不会使用 App 内嵌 WebView。
- 本地自动化不能完成真实百度登录、验证码和授权确认，生产发布前不声称该路径已生效。
