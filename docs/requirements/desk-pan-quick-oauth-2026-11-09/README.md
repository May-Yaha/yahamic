# Yaha Desk 百度网盘快速授权（2026-11-09）

## 目标与决策

用户要求把 Mac/iOS 的百度网盘登录从简化授权（`response_type=token`，30 天到期后须重新登录）改为
[快速授权](https://pan.baidu.com/union/doc/使用入门/接入授权/快速授权/)，并选择：

- 完整快速授权：App 只拿一次性 code，`hub.flyaha.top` 用服务端 SecretKey 换取 access/refresh token，
  令牌对只存本机钥匙串；剩 7 天内经 hub 续期。SecretKey 不进 App、Git、日志与分发资源。
- 授权目录：固定 `/apps/拾见/录音`，授权页不让用户选择。

## 链路

### 百度控制台回调地址（用户登记，固定不改）

| 地址 | 用途 |
| --- | --- |
| `yahadesk://oauth` | Yaha Desk Mac/iOS 快速授权（App 与 hub 换取 code 时使用；0.3.0 起验证可用） |
| `https://hub.flyaha.top/api/v1/baidu-pan/callback` | hub 门户网页授权 |
| `com.yaha.desk:/baidu-pan/oauth` | 已登记但百度返回 20030「redirect_uri 与应用配置不匹配」，不使用 |
| `http://localhost:8902/baidu/oauth` | 本地调试，当前代码不使用 |

改动 App 或 hub 的 `redirect_uri` 前必须先征得用户同意，并同步修改百度控制台与本表。

1. 授权页：`/union/oauth/authorize?client_id&redirect_uri=yahadesk://oauth&scope=nd_open_read,nd_open_write&state`。
   用户要求不传 `show_dir`，授权页不出现目录选择；App 固定只读写 `/apps/拾见/录音`。
   回调地址由用户在百度控制台登记；换取 code 时 hub 固定传同一地址。
2. 回调：百度直接跳到 `yahadesk://oauth?code&state`，不经过任何网页。
   - Mac：`ASWebAuthenticationSession` 按 `yahadesk` scheme 截获；App 也在 Info.plist 注册该 scheme，
     浏览器经系统打开时由 `application(_:open:)` 交回同一登录会话，state 校验不变。
   - iOS：WKWebView 在跳往回调地址前取消导航。
3. 换取/续期：`POST /api/v1/baidu-pan/desk/token`，body 为 `{"code"}` 或 `{"refresh_token"}`；
   返回百度 `data` 原样字段。10403 表示 code/refresh_token 已失效，只能重新登录。
4. App 校验 `authorized_paths` 为空或覆盖 `/apps/拾见/录音`；不覆盖即报错，不保存。
5. 续期：Mac 启动后每 6 小时、iOS 启动/回前台/刷新列表时检查；单飞执行，成功后立即覆盖钥匙串。
   旧简化授权令牌照常可用到期，之后提示重新登录。

## 已知风险

- 换取 code 仍需服务端 SecretKey；hub 的 AppKey/SecretKey 必须与 App 的 AppKey 属同一百度应用，否则百度返回 20038。
- DMS（`xpan/device`）是否接受目录级令牌未经实测；真机登录后绑定/静音须验收。
- 百度授权页没有指定目录的参数：不传 `show_dir` 时提交的 `paths` 为空，授权范围由百度控制台的应用配置决定。
  若百度返回的 `authorized_paths` 不含 `/apps/拾见/录音`，App 拒绝保存并提示检查控制台。

## 验证

- hub 服务端（闭源）：换取/续期接口与桥接页单测通过。
- Mac：`swift test` 88 项通过。iOS：Release 真机构建与 `build-for-testing` 通过。
- 版本随本需求升至 `0.4.1`（Mac/iOS/固件同版）。
- 真实登录、续期与 DMS 验收待服务端发布后执行。
