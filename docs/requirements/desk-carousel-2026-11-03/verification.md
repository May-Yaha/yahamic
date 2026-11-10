# 验证与上线记录

负责人：Codex。检查点：本轮交付前完成本地验证与审计；服务端生效须取得生产入口执行与运行态证据；真机验收须在用户授权烧录、本人完成网页登录后进行。

截至2026-11-04：产品提交 `26d1c2b8` 已核对生产切流，正式Mac免填连接已生效；最终固件实际采集、恢复静音和基础页面转场已验证。设备配网、独立浏览器授权、HTTPS/通知同步与配置持久恢复仍待验。下文保留各阶段证据，最新状态见末尾。

## 工作区与历史边界

- 基线：`53794c66`；隔离 worktree：`<workspace>/yahaops-desk-carousel`，分支：`codex/desk-carousel-2026-11-03`。
- 原工作区的 `docs/acceptance-cases/miniapp/latest-run.json` 与 `yahaops-api/jobrunner` 不属于本需求，未修改。门禁在隔离 worktree 生成的验收报告已恢复，不提交无关回归产物。
- 历史来源：[Wi-Fi 直连需求](../desk-wifi-cloud-2026-11-03/README.md)、既有 `desk_pull`/`desk_feed`、专用公开应用 `desk.sync` 限制、BLE UUID 2–7、10 字节 dashboard 与音频/静音路径。
- 新配置使用 SQLite 迁移 80；保留旧表数据与指令/TTL/ack 语义。应用版本与最新客户端是否报告版本分开保存，旧客户端降级后不以历史版本误报“已应用”。

## 仓库门禁

在隔离 worktree 运行 `bash deploy/verify-gates.sh`，使用 Node、pnpm 10.33.0、Go 1.27.1、Python 3.13；退出码 **0**。完整日志：`/tmp/yahaops-desk-carousel-gates-20261103-1308.log`。

实际输出摘要：

```text
Ran 350 tests in 56.886s
Regression: 659 passed, 0 failed; manual pending: 19
ok  yahaops/api/dao/store                      230.211s
ok  yahaops/api/server/handler/mcpingest        15.142s
ok  yahaops/api/server/logic/oauth             34.485s
ok  yahaops/worker/internal/baidupanbackup      93.417s
Test Files  102 passed (102)
     Tests  564 passed (564)
```

该脚本的 Go/API 与 worker 全量构建、vet、测试、小程序类型检查和微信构建均通过；19 个既有人工小程序 case 仍待人工，不能视为真机通过。桌面固件和 Swift 按项目约定使用各自构建入口。

审查修复并合入 `a7783f76` 后再次完整运行同一命令，**exit 0**，日志 `/tmp/yahaops-desk-carousel-gates-final.log`，持久副本见 `evidence/verify-gates-final.log.gz`。实际最终输出：

```text
Ran 350 tests in 53.646s
Regression: 683 passed, 0 failed; manual pending: 20
ok  yahaops/api/dao/store                      (cached)
ok  yahaops/api/server/handler/mcpingest        8.450s
ok  yahaops/api/server/logic/oauth             (cached)
Test Files  102 passed (102)
     Tests  564 passed (564)
```

新增的24条小程序回归和1个人工case来自合入的扫码注册需求；本需求不修改小程序。Go 使用其正常缓存，新增真实HTTP回归已实际执行；不以缓存输出冒充重新执行。最终20个人工case仍待验。当前工作流仅 `workflow_dispatch`，不把其他提交的CI记录记成本需求通过。

## 真实 MCP 传输回归

`go test ./server/handler/mcpingest -run TestDeskPullHTTPTransportAcceptAndSSE -count=1 -v` → **exit 0**，`ok 3.285s`。测试通过真实 `Handler(sc)`、本人专用公开 `desk.sync` 应用发起请求：

- 只接受 `application/json` → HTTP 400。
- 同时接受 `application/json, text/event-stream` → HTTP 200，`Content-Type: text/event-stream`；事件同时带 `result.content[0].text` 与 `structuredContent`。
- 实际响应保存为固件测试夹具 `yahaops-desk/firmware/tests/desk_pull_response.sse`。旧 JSON-only 解析器回放失败（exit 134），修复后的生产解析器回放通过；不修改全局 API 传输模式。

## Mac 与固件

Mac 在 `yahaops-desk/mac` 执行：

```text
swift test --disable-xctest
23 tests / 1 suite passed (1.853 seconds)
bash scripts/make-app.sh
Build complete! (6.56s)
codesign --verify --deep --strict build/YahaDesk.app
exit 0
```

三条命令组成的最终命令链退出码 **0**，产物 `build/YahaDesk.app`，版本 **0.2.0**，使用本机 Apple Development 签名。普通 `swift test` 存在宿主 XCTest 加载器架构冲突；本仓库使用 Swift Testing，本次通过的实际入口为 `--disable-xctest`，不能把普通入口写成通过。

- 行为覆盖：BLE 未连接也能保存；保存或显式重载途中新编辑保留；冲突保留草稿；首次慢读取不覆盖期间编辑；切账号后拒绝旧响应；设备授权等待及 token 交换期间换设备或同设备重连不能交付凭据；正常授权仍可完成；配置/回调/PKCE/10–12 字节载荷边界。
- OAuth 拒绝回调先复现 RED，再改为合法 state/issuer 的拒绝立即结束；错误 state 仍不能终止合法授权等待。
- 使用实际 SwiftUI 视图生成并人工检查完整控制页、编辑器和三模板截图；截图位于 `mac/.build/screenshots/`，没有运行正式 App 生命周期、蓝牙连接或真实钥匙串读写。预览使用明确标注的示例数据。

固件使用 ESP-IDF **v6.1**，最终 `idf.py build` → **exit 0**，日志 `/tmp/yahadesk-idf-build.log`：

```text
yahadesk.bin binary size 0x2a0b00 bytes
4MB app partition: 34% free
Project build complete.
```

这是合入最新 `main`（`349feee4` 方屏通知卡、`a7783f76` 扫码注册修复）后重建的产物；通知卡的424px卡面、24px内边距、正文重算高度/五行省略和卡面外状态行仍保留。应用二进制 SHA-256：`bf0adf26e4b83ec1c0c6cd82b9e1640e97eef8c9a1723d446b34a1ba973d9195`。

`firmware/tests/README.md` 所列两组 host 编译/执行命令均退出 **0**：

```text
display behavior tests passed
display JSON boundary tests passed
```

第三组 `python3 yahaops-desk/firmware/tests/uplink_snapshot_test.py` → **exit 0**，`snapshot RSSI: first=-52 second=-52 HCI calls=1`。该测试原样编译生产函数，仅替代硬件与时间输入；旧函数实际为 `second=0`、exit 1，不用重写缓存逻辑的镜像测试替代生产代码。

覆盖配置边界、精确到期、停用页/空通知、固定通知模板内三类卡片仍轮换、讲话暂停恢复、同版不重置、通知 TTL/clear、32 位计时回绕、SSE 实际响应/CRLF/多 data 行/无关事件/非法 JSON/超限。实际最坏合法批次夹具为 135673 字节；接收与解析共用 **192 KiB** 上限，保留 8 秒超时。20×509 字节卡片经 MCP 两份输出与最坏转义约 13 倍，另留固定字段余量；板载 8MB PSRAM 且大块 malloc 走 PSRAM。NVS、TLS、无线、音频及实际堆水位仍待真机验证。

## CodeGraph 与独立审计

实现冻结后在本 worktree 执行 `python3 agent/skills/codegraph/scripts/refresh.py` → **exit 0**。审查前健康记录 `/tmp/yahaops-desk-carousel-codegraph-review.json`：引擎 **1.6.2**，1515 files / 24647 nodes / 62558 edges；`index.state=complete`、`pendingRefs=0`、`reindexRecommended=false`、`pendingChanges` 全零、`worktreeMismatch=null`，路径为本 worktree。

关系检查将 `DeskStore.SaveDisplay` 追溯到 `setDeskDisplay` 与四组行为测试；跨 Swift/BLE/MCP 的字符串协议继续由源码核对，不以静态图遗漏证明无调用方。

第 1 轮由全新上下文的 API、Mac、固件三位审查者独立核查。API 无确定发现；其余发现 **4 项 P1、1 项 P2**，均由实际回放或确定调用链复现后修复，第 2 轮复核全部通过：

| 级别 | 问题与触发证据 | 修复与回归 |
| --- | --- | --- |
| P1 | 显式重载等待时改为60秒，响应返回变10秒且无待保存标记 | 所有替换都比较请求开始的草稿；Swift回归先RED后GREEN |
| P1 | A设备开始OAuth、断连后B或A新连接收到旧授权凭据 | 外设ID+连接代次贯穿状态、授权、写入和ACK；断连取消；真实本地回调/假OAuth与BLE回归先RED后GREEN |
| P1 | 合法20卡最坏转义响应135673B，原32KiB解析拒绝整批 | 共用192KiB上限；真实SDK夹具RED/GREEN与超限测试 |
| P1 | 固定通知模板时第一条卡占满4h，日报和后来的agent消息直接过期 | 固定模板内仍按停留时间推进内容turn；三类内容、暂停和独立TTL回归RED/GREEN |
| P2 | 主循环与新增云端任务同时读写RSSI静态缓存 | 缓存及HCI采样互斥，核对cache mutex→HCI锁单向次序；`uplink_snapshot_test.py`原样提取生产函数，旧版第二调用返回0（exit1），新版两次均-52且仅一次采样（exit0） |

第2轮以 `a7783f76` 为基线、代码 HEAD `2e55f8e3` 为对象：API确认最新注册链不改变owner/scope/schema边界；Mac审查者独立运行 `swift test --disable-xctest --filter CloudSyncTests` → 9 tests / 1 suite passed、exit0；固件审查者独立运行三组host检查，并回放4小时固定通知页，出现 `agent article daily`。三位均判定 **Pass**，无必须修复项，无必须精简项；未把真机待验项改成通过。

修复与合并后再次刷新 CodeGraph → **exit 0**，1517 files / 24703 nodes / 62893 edges，所有健康条件仍满足；证据见 `evidence/codegraph-final.json`。最终提交仅补充验证文档与证据，不再变更上述已审计的产品代码。

## 高风险边界与发布依赖

- OAuth：新增独立 `desk.configure`；不放宽设备 `desk.sync` 专用应用限制；Mac 控制凭据留钥匙串，设备 refresh token 仅经加密 BLE 交付设备，网络拒绝跨源重定向。
- 持久化：配置保存采用版本比较；非法配置与过期修改不能覆盖有效配置；固件先提交 NVS 再确认配网/授权，配置持久化成功后才上报应用版本。
- 发布顺序：API → Mac → 用户授权后的固件。新固件收到旧 API 的 `-32602` 时仅移除新参数重试，缺少 `display` 时继续旧指令路径；旧 Mac/固件继续使用既有音频与 10 字节 dashboard。
- 回滚：服务端代码按现有生产入口回退版本，新增表/列可保留，旧服务端忽略；Mac/固件可退回既有版本，保留 NVS，不擦除配对数据。回退设备会失去新轮播能力，控制端不能继续声称新配置已应用。
- 无生产数据回填/清理，无小程序平台操作，无固件烧录/上传/发布，无真实网页登录或正常 App 安装/启动。

## 实现依据

- [MCP Go SDK v1.8.0 Streamable HTTP](https://github.com/modelcontextprotocol/go-sdk/blob/v1.8.0/mcp/streamable.go)：本机实际依赖源码及真实处理器验证 Accept/SSE 行为。
- [RFC 7636](https://www.rfc-editor.org/rfc/rfc7636#appendix-B)：PKCE S256 使用标准测试向量；[RFC 8252](https://www.rfc-editor.org/rfc/rfc8252#section-7.3) 对应本地回调/随机端口。
- ESP-IDF v6.1 已安装官方 SDK 的 `esp_http_client.h`、Wi-Fi station、SNTP、RESTful server/cJSON 示例；采用官方 `espressif/cjson`，没有自写 JSON 解析器或引入新常驻服务。
- 新通知卡沿用主分支的[方屏需求与 LVGL 证据](../desk-notification-card-2026-11-03/README.md)；Mac 示例预览按该方屏事实更新，不能当作设备实拍。

## 初次交付时的未验证与运行状态（历史检查点）

- 真实 OAuth 登录、设备授权、Wi-Fi 配网、断网恢复、BLE MITM、音频与无线共存、运行内存水位、实际屏幕和电量读数：需要用户参与与真实设备，尚未验证。
- `YAHA-Mac` 与 `YAHA-Mac.local` 名称解析失败，Agent未执行生产唯一入口。用户提供的发布输出表明线上为 `349feee40cf3bdfc332444697e5b979118dd9c82`（方屏通知卡），并非本需求版本；公网OAuth元数据实际仍无 `desk.configure`。本需求推送后需再次按唯一入口发布并核对，不以旧发布记录替代本次生效证据。

## 后续真机与免填连接检查点（覆盖上述初次交付状态）

- 用户已自行执行唯一入口，发布到 `ae45b0730f8037892dd2d5e5fcb4977929b7f95a`。使用带缓存穿透参数的 OAuth 元数据核对 HTTP 200、`desk.configure`，响应头 `x-yahaops-release: yahaops-api-slot-20261103210246-ae45b073`。不带参数的历史缓存不能作为服务未部署的证据。
- 用户另为现有应用勾选轮播控制权限后，真实 `client_credentials` 请求仅申请 `desk.configure` → HTTP 200，响应权限恰为该单项；随后 `desk_get_display` → HTTP 200、JSON-RPC 成功。此步骤只读，不保存轮播配置、不签发设备授权。真实密钥用 Security API 安装至本机钥匙串，ACL 信任稳定签名的正式 App；不写源码、Git 或分发包，令牌未持久化。
- Mac 0.2.0 已通过 `bash scripts/make-app.sh --install` 安装至 `/Applications/YahaDesk.app`，签名核对通过，显示器菜单图标已替换，原配对自动恢复到 `yahadesk-XXXX`。这只是图标版本安装；免填连接和中文预览完成后仍须重装与运行验证。
- 烧录目标再次核对为 `/dev/cu.usbmodemXXXX`、基础 MAC `xx:xx:xx:xx:xx:xx`（BT 尾号 `XXXX`），另一块 USB 设备未操作。完整 16MiB Flash 已备份在本机私有目录 `~/Library/Application Support/YahaDesk/firmware-backups/20261103-carousel-0.2.0-pt5vcdkt/flash-before.bin`，目录 0700、文件 0600；SHA-256 `74b2faae547482b77141da8709ee43e0d248214658c6d78dbc7d26faf505f4f8`。备份包含私密配置，不提交。
- 实际分区表与构建产物逐字节一致，只写入 `0x10000` 应用分区，保留 NVS、配对、bootloader 与分区表。第一次烧录 `bf0adf26…` 经 esptool hash 核对，但启动出现 `capture task didn't start` 与 Wi-Fi RX 4/10 分配失败，因此未通过真机验收。
- 诊断固件 SHA-256 `eee5515d3a0e66cb5c55e488f986b9814ad601a71690b6c5be93ffb922d7967e`。阶段日志 `/tmp/yahaops-desk-carousel-memory-diagnostic.log` 显示显示器初始化后内部 free=105063、largest=31744；音频栈申请前 free=92783、largest=31744，无法满足 32768 字节内部栈。UI 对象创建期间系统堆不变，LVGL 使用固定 64KiB 内部池；不能把像素对象数量当成系统堆碎片根因，也不能把音频栈迁往 PSRAM 掩盖问题。
- `python3 yahaops-desk/firmware/tests/boot_memory_test.py /tmp/yahaops-desk-carousel-memory-diagnostic.log` 为真实失败回归；修复后须通过音频与 Wi-Fi 启动里程碑，并用 `--require-capture` 验证真实采集间隔。BLE 订阅显示 live 不足以证明采集成功。

### 追加实现的确定性验证与规则演练

- `bash deploy/verify-gates.sh` 最终完整重跑 `/tmp/yahaops-desk-onboarding-gates-retry.log` → exit 0：worker 350 tests、MP 683 自动回归（20 人工待验）、Web 102 files / 564 tests、Go vet/test/build。此前一次完整运行有未改动的 worker 用例 `test_manual_budget_permission_is_not_inherited_by_retry_or_human_rerun` 返回 running 而非 succeeded；原日志保留，聚焦重跑 0.478s 通过，未修改 worker 或断言。失败根因未确认，不把并行构建负载推测当成事实。
- 随后整合最新 `origin/main` 至 `846f9044`（他项小程序上传证据与历史读完记录修复）；只在本 worktree 保留本需求改动，词汇表/协议补充三方应用成功。`bash deploy/verify-gates.sh miniapp go` → exit 0，日志 `/tmp/yahaops-desk-onboarding-after-main-gates.log`：MP **684 passed, 0 failed; manual pending: 21**；Go store 190.213s、MCP handler 18.542s，全组 vet/test/build 通过。新增人工项来自上游需求，不等于本需求真机通过。
- API `go test ./dao/store ./server/handler/mcpingest ./server/logic/oauth -count=1` → exit 0，store 169.473s、MCP handler 9.281s、OAuth 17.472s；三包 vet、全 API build 和相关 Web 7 项回归通过。新增迁移81只建专用绑定表/约束与用户删除清绑定 trigger；v80 旧应用快照、八并发同 ID、19→20 配额、满额事务回退、撤销/删除/修改不复活、eval 不写及 configure-only 真实 HTTP 工具测试通过，不写 grant/code/token。
- Mac 最终 `swift test --disable-xctest && swift build -c release --product YahaDesk` → exit 0，**39 tests / 2 suites passed (5.655s)**、release 8.38s。控制令牌显式无 refresh 模式、最小 scope、续期、旧 PKCE 恢复/重新授权/取消、prepare 等待换连接、权限错误和无效设备 ID 均有回归。旧 PKCE 被撤销后不能重授权的恢复缺口、保存续期时权限提示被覆盖，已先复现再修。
- 真机诊断过程中发现本机控制请求提前断开，真实临时 ControlServer 延迟 100ms 发送 → Broken pipe 32（RED 0.110s）；Darwin 原生探针确认 accepted flags 6 继承 O_NONBLOCK 4，同 UID 501，无 payload 时 recv 返回 EAGAIN 35。修复只清 accepted fd 非阻塞标志，失败关闭并释放槽。四组回归验证延迟/分包/同连接多请求、坏 JSON/断开后恢复、4 连接上限与替换、5 秒超时（实际 5.006s）。跨 UID 拒绝未实测，原校验保留。
- agent 新规则完成两轮独立场景演练：首轮发现新机凭据来源未定义、全中文可能误导改写来源正文；已明确安装方只用本次已授权来源，新机缺来源报告安装未完成并暂停连接；中文针对系统界面/固定文案，动态通知保留来源原文。第二轮两项歧义均消除，本机既有授权不重复索取，缺权限/无 BLE 不被混为同一阻断。

### 最终固件产物与安装检查点

- LVGL builtin 65536B 池通过官方 object 粒度 `extram_bss` 映射到 `0x3c2900ac`；内部 `.bss` 减少 80544B（含 SDK 可外置 Wi-Fi/LwIP 状态），显示 DMA 与 32768B 音频栈保留内部。初次外置池版本实际生成配置漂移成 RX2/BA2，因此不能作为原预算通过；已在 tracked defaults 固定 RX10/BA6，删除 ignored sdkconfig 后从 defaults 完整重建，链接回归同时校验实际编译头。
- RX10 版本 `6d4ec23c…` 真机日志 `/tmp/yahaops-desk-carousel-rx10-verified-boot.log`：音频栈 ready、Wi-Fi 实际 RX10、初始化内部 free 20495 / largest 12288、运行最低 19612，BLE 加密重连正常。RX2 版本曾实际采集 59/59/60ms，音频栈余 4336B、Mac 254 帧全解码/入队/输出，无解码错误和丢帧；此证据不能替代最终 RX10 中文版本采集验证。
- 官方 `mbedtls/port/esp_mem.c:16–19` 显示原配置所有 TLS calloc 强制内部；`ssl_tls.c:1182/1202` 的输入缓冲至少 16384B，大于上述连续块。最终使用 `MBEDTLS_EXTERNAL_MEM_ALLOC` 官方 PSRAM 分配，不缩 TLS record 缓冲，192KiB 响应保留标准大块 malloc 策略。构建头验证外部分配启用且内部模式关闭，启动回归增加实际 allocator/input/RX 检查；真实 TLS 握手仍须配网后验证。
- 中文固定文案、中文星期日期、供电/四环/状态/徽标已同步 Mac；新增 18px 字体行高 21，实际字形与 kerning 测量最长 28px 状态 324px、日期 302px（可用 424px），48px 配对标题 192px。补全已有字库缺的“脑”等字，不以字符数量或 Mac 预览证明实际字体覆盖。
- 最终 IDF 从 defaults 全量 reconfigure/build → exit 0；四组 host（display、JSON/SSE、真实 snapshot、memory layout）及字形宽度检查 exit 0。最终 bin `0x2a4650`（2770512B，4MiB 分区余34%），SHA-256 **adb959f2f7273d4524815a773eb836b6c65050c4d17b365ce71f9970fe9d47f5**。该版本已只写目标设备应用分区，esptool hash verified，日志 `/tmp/yahaops-desk-onboarding-final-flash.log`。
- 新版 Mac 已再次执行 `bash scripts/make-app.sh --install` → exit 0，稳定 Apple Development 签名与严格 verify 通过。App 首次读取安装的钥匙串项目触发 macOS SecurityAgent，已请求用户本人完成系统许可；此时自动连接、最终真机音频与设备授权尚未通过，不自动处理系统密码/确认。

### 最终追加审计结论

API、固件独立审查通过；Mac 首轮确认 1 项 P2：旧 PKCE 重新授权失败/取消后原轮询被取消且不再恢复。新增真实 15 秒周期的失败/取消回归，两分支各等待 17 秒超时（RED，34.043s/exit1）；修复在同一代次、未停止时延迟15秒恢复，保留旧授权、草稿与远端配置。`stop` 清轮询句柄，`disconnect` 更换代次，跨周期回归证明不会因授权收尾复活。

最终 `swift test --disable-xctest && swift build -c release --product YahaDesk` → **exit 0，41 tests / 2 suites passed (64.380s)，release 6.46s**。Mac 第2轮只读复核 **Pass**；三领域无剩余确定问题、无必须精简项。不因本地通过把真实 Keychain、PKCE 浏览器与 BLE 授权交付写成已验证。

修复后再次打包安装 → exit0（`/tmp/yahaops-desk-onboarding-install-final.log`），已安装二进制与本轮签名包逐字节一致，严格签名校验通过。最终设备启动回归通过：RX10、TLS PSRAM、音频与Wi-Fi任务 ready；内部最低余量 **21032B**、最大连续块 **13312B**。最终固件日志全程静音，实际采集及中文屏幕回传仍待系统钥匙串许可解除后核对，Wi-Fi/HTTPS/配置NVS/无线共存仍待用户配网及独立设备授权。

最终源码冻结后 CodeGraph → exit0，记录 `/tmp/yahaops-desk-onboarding-codegraph-recheck.json`：当前 worktree、引擎1.6.2、1528 files / 24865 nodes / 63522 edges，complete、pendingRefs/changes全0、无 mismatch。完整门禁后已整合 `846f9044` 并完成受影响复验；最后一次 fetch 确认远端仍为该版本。

高风险 OAuth/迁移81、密钥不入仓库/固件、专用设备授权、Flash 私有备份与只写应用分区证据均已留存。新增 API 准备工具已由用户通过生产唯一入口发布；本环境无法连接 `YAHA-Mac`，但已用公网元数据只读核对 release。无需再次索取已给的 Client ID 或密钥，未预调用生产准备工具创建应用。

### 2026-11-04 生效核对

- 用户完成 macOS 钥匙串系统许可后，正式 `/Applications/YahaDesk.app` 的本机控制接口返回 `configured=true`、`authenticationMode=client_credentials`、`status=已连接轮播控制`、`desiredRevision=0`；同次只读状态显示版本 `0.2.0`、设备 `yahadesk-XXXX` 已加密蓝牙连接、静音与 PTT 保持开启。原始脱敏结果见 `evidence/onboarding-runtime-20261104.json`，未保存 token 或 secret。
- OAuth 元数据请求 HTTP 200，响应头 `x-yahaops-release: yahaops-api-slot-20261104092157-26d1c2b8`、`x-cache: MISS`，`desk.configure` 位于支持范围；这证明新增服务版本已切流。Mac 已能读取内置密钥并建立控制模式，未要求用户填写 Client ID/密钥。
- 设备仍显示 `online=false`（设备云端同步状态）；本轮尚未执行 Wi-Fi 配网、浏览器设备授权或 BLE 下发 refresh token。已请用户在Mac设置中完成配网及浏览器确认，不在聊天索取Wi-Fi密码；不能把蓝牙在线误报为云端同步已生效。

### 最终固件实际采集与屏幕回传

USB重新枚举为 `/dev/cu.usbmodemXXXX` 后，先通过 esptool `read-mac` 确认仍为基础MAC `xx:xx:xx:xx:xx:xx`，没有操作另一块设备或重新烧录。当前bin SHA-256仍为 `adb959f2…`，内嵌ELF完整摘要 `e08e5e27890c289f9671f8cd920819d22b2c4fdc31b829ab12ce22ea1bd1dde0` 与本地ELF一致，启动日志前缀吻合。

`python3 yahaops-desk/firmware/tests/boot_memory_test.py /tmp/yahaops-desk-runtime-20261104/boot.log --require-capture` → **exit0**：实际RX10、TLS PSRAM和音频任务ready；实际采集 **59/59/60ms**，音频栈最低余量 **6836B**。本次内部最低余量 **21140B**、后段最大连续块 **13312B**，未见启动失败、panic或堆损坏签名。

正式App的5秒ambient指标窗口新增接收/解码/入队 **94帧**、输出 **92帧**；窗口后排空，累计接收、解码、入队、输出均 **101帧**，丢帧、解码错误、跳号、溢出和欠载均0。结束后 `muted=true`、`ptt=true`、`streamActive=false`、缓冲0。没有调用PCM录制入口，未保存音频文件。

四次SCR均为完整120行×120像素，前三帧Mac状态页、末帧像素时钟，确认基础布局及一次本地自动转场。120×120是480px屏幕每隔4行/列的抽样，不能证明原始字形清晰度或物理屏观感；没有覆盖通知页、完整轮播周期或精确停留时间。安全统计与日志分别见 `evidence/onboarding-final-runtime-20261104.json`、`evidence/onboarding-final-runtime-20261104.log.gz`，两页抽样见 `evidence/onboarding-device-samples-20261104.png`。固件审查者独立复核上述证据 **Pass**。

上述是本地短时采集与转场证据，不能扩写为长期稳定性或真实Wi-Fi/BLE共存通过；云端配置revision仍0、设备online仍false。下一检查点由Codex在用户完成配网和设备浏览器授权后核对HTTPS/OAuth、配置落盘/重启恢复、通知轮播及联网音频水位，依赖仍是该设备联网与本人浏览器确认，风险为无线/持久化链路尚未实测。
