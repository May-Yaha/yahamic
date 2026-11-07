# Yaha Desk 云端契约

本仓只实现开源客户端与固件。云端服务可以独立部署；兼容实现必须遵守下列 scope、工具和数据边界。当前历史需求中的 `yahaops` 名称代表已有云端实现，不表示本仓依赖其源码。

## OAuth 与工具

| Scope | 工具 | 约束 |
| --- | --- | --- |
| `desk.configure` | `desk_prepare_device({})` | 只准备当前用户的设备专用公开应用，返回 `client_id` 与申请 scope；不直接签发授权。 |
| `desk.sync` | `desk_feed({daily?,article?})`、`desk_monitor({...})` | 只挂载给带 secret 的受信应用，或绑定当前用户且登记范围受限的设备专用公开应用。 |
| `desk.operate` | `desk_operate({token,action})` | 只授给符合条件的设备专用应用；操作令牌十分钟、单次有效并绑定用户、动作与目标。 |
| `desk.status` | `desk_status({})` | iOS 只读当前用户最近一次设备上报，不能控制设备。 |

历史 `desk.write` 只为 scope 列表兼容保留，不再注册工具。历史 `desk_pull` 仅兼容 0.2.0 及以前固件，返回空命令；新客户端不得依赖它。

## `desk_feed`

- 返回 `{cards:[{kind,key,ttl_seconds,title,body}]}`。
- `kind` 为 `article` 或 `daily`；调用方以稳定 `key` 去重。
- `title + body` 必须是合法 UTF-8、无 NUL，合计不超过 509 字节；TTL 范围 1–65535 秒。
- 内容必须经过当前用户的实时读取权限过滤，不返回正文之外的内部日志或身份数据。

## `desk_monitor`

可选上报：`firmware`、`ssid`、`muted`、`mac`、`dms`、`pan_device`。响应包含：

- `at`：服务端 Unix 秒；
- `sections`：固定顺序的 `tasks`、`collect`、`processing`、`glm`、`miniapp`；
- `alerts`：稳定 key、分区、级别、标题与时间；有 `desk.operate` 时才可附 `action` 和不透明 `token`。

无权或读取失败的分区必须返回 `available:false`，不能让整个响应失败；响应不得包含日志原文、租约、用户标识、文章正文或操作目标。

## `desk_status`

返回 `{reported,online,reported_at?,firmware?,ssid?,muted,mac,dms?,pan_device?}`。`online` 只表示最近 180 秒内有上报；设备讲话时会暂停联网，因此停报不等于音频链路断开。

## 发布兼容

- 云端新增严格入参后，必须先发布兼容 API，再升级固件或客户端；旧 API 会拒绝未知字段时不可单独回滚。
- 客户端升级不能自动扩大旧授权；新增 scope 需要重新获得用户同意。
- 令牌只存系统钥匙串或设备安全存储，不写日志、不进入固件镜像或 Git。
- App、iOS 与固件保持同一产品版本；云端实现独立版本化。
