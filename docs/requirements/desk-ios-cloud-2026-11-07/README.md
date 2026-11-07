# 桌面 iPhone 改走云端看状态与远程控制

## 目标

用户 2026-11-07 要求：iPhone「Yaha 桌面」不再靠蓝牙连设备看状态，改经云端读设备是否联网等状态，并能远程控制设备。

## 用户决策（2026-11-07）

- **yahaops 记最近上报**：固件随每分钟的 `desk_monitor` 带上设备状态，API 每人覆盖存一行，iPhone 用新工具 `desk_status` 读。控制仍走网盘设备服务（DMS），yahaops 不新增控制工具。
- **放行私有回调**：新增内置公开 PKCE 应用 `yahadesk-ios`，回调为私有 scheme `com.yaha.desk.ios:/oauth`（RFC 8252 §7.1）。只有这个种子带私有回调，用户自建应用仍只能填 HTTPS 或本地回环。属 OAuth 高风险变更，所有者读证据。
- **这一批一起改固件**：固件改动随本批提交；烧录另行授权。

## 改动

API（`yahaops-api/`）：

- 迁移 91 新表 `desk_report(owner_id PK, firmware, ssid, muted, mac, dms, pan_device, reported_at)`，每人一行覆盖写，删用户时触发器清理。
- `desk_monitor` 接受可选入参 `{firmware, ssid, muted, mac, dms, pan_device}`。`firmware` 为空（旧固件传 `{}`）不记录；任一字段不合规整条丢弃、只记日志，健康总览照常返回；评测模式只校验不写。工具注解从只读改为幂等、非破坏，并进评测影子列表。
- 新 scope `desk.status`（`MCPScopes` 末尾追加）注册只读 `desk_status({})`：返回本人最近一次上报与 `online`（3 分钟内有上报）。
- 迁移 92 一次性种入 `yahadesk-ios`：无 secret、强制 PKCE、只登记 `desk.status`；管理员停用、改名或删除后重启不复活。ID 已被占用时启动失败，不覆盖。
- MCP 服务版本 1.15.0。

Web：同意页把 `desk.status` 显示为「查看 Yaha 桌面状态」；同意后跳转允许 `com.yaha.desk.ios:`，仍要求与授权请求登记的回调同 scheme、同源、同路径。

固件（`firmware/main/`）：`cloud.cpp` 的 `monitor()` 带上 `firmware`、`muted`、`mac`；`dms::add_report` 补 `ssid`，已绑定网盘时补 `dms` 与 `pan_device`。不带 proof 与任何凭据。`PROJECT_VER` 仍为 0.3.0。

Mac 共享代码：`CloudClient` 新增私有 scheme 授权入口（由调用方展示授权页）；`OAuthCallback` 对私有 scheme 要求无 host，回环仍只认 `127.0.0.1`；`DmsClient.command` 支持带参数。

iOS：

- 设备页登录 Zhi.AI 后显示云端状态（在线、上报时间、固件、Wi-Fi、麦克风、Mac、网盘设备服务），下拉刷新。
- 设备已绑定网盘且已登录网盘时，可远程静音、发卡片、清卡片、解绑；只能静音，不能开麦。卡片 title+body ≤509 字节，与固件一致。
- 蓝牙改为按需：只有进入「首次配置（蓝牙）」才扫描连接，离开即断开。
- Zhi.AI 令牌只存钥匙串（`AfterFirstUnlockThisDeviceOnly`），剩不到 60 秒时续期。

## 发布顺序

1. 先发布 API（建表、种客户端、`desk_status`）。旧固件仍传 `{}`，不记录、不受影响。
2. 再烧固件（另行授权）；烧录前 iPhone 显示「设备还没有上报」。
3. iOS 安装新版并登录 Zhi.AI。

回滚：回滚 API 可保留 `desk_report` 表与种子客户端。旧 API 的 `desk_monitor` 入参是空结构，MCP SDK 推断为 `additionalProperties:false`，会拒绝新固件带的字段，设备健康总览随之同步失败；所以必须 API 先上线再烧固件，已烧新固件后若回滚 API，须同时把固件回退到上一版。

## 验证

- Go：`go build ./...`；`go test ./server/... ./dao/... ./domain/...` 通过，含上报往返、非法字段丢弃、3 分钟窗口、按人隔离、覆盖写、种子一次性与 scope 工具表。
- Web：`tsc` 与既有测试通过，含 `consentCallback` 私有回调同源判定。
- 固件：`cloud_refresh_test.py` 新增断言 `desk_monitor` 带上设备状态；`idf.py build` 通过，镜像 3,986,083 字节；`display_test`、`display_json_test`、`dms_wire_test` 通过。
- Mac：`swift test` 76 项通过，含私有 scheme 回调接受与拒绝（带 host、别的路径、别的 scheme、http）。
- iOS：模拟器 `xcodebuild test` 12 项通过，含上报解码、卡片上限与 DMS 状态文案。

- `deploy/verify-gates.sh` 通过（exit 0；小程序回归 642 通过、0 失败）。
- 独立审查（全新上下文）无阻断问题，修复项：非 UTF-8 网络名（如 GBK）解码后超长原会丢弃整条上报，改为只丢网络名，固件也只发合法 UTF-8 网络名，附回归；同意页私有 scheme 的 origin 恒为 `"null"`，补比 host，附回归；iPhone 关掉授权页显示「已取消登录」。
- 已知取舍：动态注册的智能体默认可勾选 `desk.status`（与其它只读 scope 一致，同意页可取消）；会读到 Wi-Fi 名与网盘设备号，但控制仍需本人网盘令牌。

## 未验证

- 真机：新固件上报、iPhone 真机登录 Zhi.AI（ASWebAuthenticationSession 唤回 App）、远程静音、发卡片与解绑。
- 生产：API 未发布前 `desk_status` 不可用。
