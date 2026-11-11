# 桌面设备接入百度网盘设备服务与录音备份（2026-11-05）

## 目标与授权

用户 2026-11-05 要求把桌面设备的控制流切入百度网盘设备服务（DMS / IoT Core），并把每次开麦期间的语音录音在结束后备份到网盘。同日确认：

- 一步到位切 DMS；首次使用时设备未绑定网盘，先走绑定（register + bind，即新用户注册），过程中配置网络，之后可随时切换网络。
- 网络信息上云**只存网络名**（SSID），密码只在设备 NVS，换网经 BLE。
- 设备固件直连 IoT Core MQTT。录音最初定为固件直传网盘；2026-11-06 用户改为**由 Mac App 上传**（「直接在固件上上传这个网盘文件是不是会造成比较大的性能浪费？如果是的话直接在macapp上上传吧」），网盘令牌不再下发设备。
- 2026-11-06 用户要求 Mac App 显示已备份到网盘的录音列表，并修复按住讲话时卡顿；接受讲话期间网盘指令延后处理。
- 录音窗口：开麦（取消静音）到静音或断开为止；格式 Ogg Opus；路径 `/apps/拾见/录音/YYYY-MM-DD/HHmmss.opus`。
- 网盘开放平台应用 AppID 124380875（AppKey 见 Mac 源码常量，属公开客户端标识）；应用目录 `/apps/拾见`，与服务端备份同一应用。SK 不进代码、配置、文档和日志，隐式授权也不需要它。
- Mac 端网盘登录：百度网盘新入口 `pan.baidu.com/union/oauth/authorize` 的 OAuth 隐式授权（`response_type=token`，不使用 OOB，约 30 天，无 refresh token），直接解析返回的 access token，令牌存 Keychain。
- DMS 参数：`dms_type` 113，`device_type` 202611021737243320（2.16 寸板，替代最初给的 1.75 寸类型）。
- 出厂证书：用户说「应该有通用的根证书」。已找到服务端信任的实验室出厂 CA（`hardware-agent/projects/agent-hardware/.local/lab/ahd/factory.crt`，SKI `F6:51:…:89:4D`，与线上 `IOTCORE_FACTORY_CA_DER` 一致）；私钥只用于本机签发开发板证书，不打印、不复制进仓库、不提交。
- 用户回答「可以下发」含义不明确，不视为烧录授权：**固件与出厂分区烧录须用户逐次明确同意**。

基线 `c997a28b`，worktree `.claude/worktrees/antd-only-web`，分支 `worktree-antd-only-web`。

## 历史与上线检查

- [桌面 Wi-Fi 直连云端](../desk-wifi-cloud-2026-11-03/README.md)：Wi-Fi 与 yahaops 设备授权经加密 BLE `provision` 特征写入，NVS 命名空间 `deskcloud`；本需求沿用同一特征与加密要求，新增 op，不改既有 op。
- [桌面工作台](../desk-workbench-2026-11-05/README.md)：批 1 已推送 `6a170c36`、未烧录；批 2 暂停等待本需求。yahaops 的 `desk_pull`/`desk_monitor`/`desk_feed` 保持不变，DMS 是并行的第二条云端链路，不替代 yahaops 卡片与工作台。**2026-11-06 用户改为**：设备控制只走 DMS，agent 推卡片也走 DMS `card` 指令（只下发文字，固件自行校验显示）；yahaops 删除 `desk_send_card`/`desk_mute`/`desk_status`，`desk_pull` 只为 0.2.0 固件留空壳，业务数据（`desk_monitor`、`desk_feed`、播报）仍走 yahaops。
- 参照实现：`hardware-ai-suite/firmware/sdk/core/src/dms.c`（登录、presence、指令分发）、`hardware-ai-flutter-sdk` iOS `Dms.swift`/`Netdisk.swift`（DMS 客户端、隐式授权、Keychain）、`esp-mosaico` 单分片上传。只移植需要的部分，不引入 SDK 的 ah-ble-sec1 配网通道（与现有 GATT/NimBLE 单连接冲突），DMS 字段走现有加密 BLE 链路。
- 服务端 `yahaops-api/lib/integration/baidupan/` 用同一 AppKey 的授权码令牌备份日报播报。同一账号再做一次隐式授权是否会让服务端令牌失效**未验证**，批 1 真机核对时观察 `desk-tts` 下一次上传。
- 发布方式：本需求只改 `yahaops-desk/`（固件 + Mac App），不改 API、schema、部署；不进 `verify-gates.sh`，本地 `idf.py build`、`swift build`/`swift test` 验证。Mac App 由用户本机构建运行，固件与出厂分区烧录单独授权。
- 旧数据：现有 `nvs` 分区偏移与大小不变，新增分区放在 app 之后；更新分区表后既有 Wi-Fi、yahaops 授权与 BLE 配对保留（烧录时不得 `erase-flash`）。

## 设计

### 出厂身份

- 新增 NVS 分区 `fac`（`0x410000`，`0x6000`），命名空间 `fac`：`id`（出厂设备号，字符串）、`cert`（叶子证书 DER）、`key`（P-256 私钥 32 字节标量）。固件只读，与 `nvs` 分开，清配置不丢身份。
- 出厂设备号 `yd_` + 26 位 `[0-9a-z]` 随机串；它同时是证书 CN、DMS `register.device_addr` 与 `device_sn`。
- 叶子证书：P-256，CN 与 SAN `urn:ah:factory:<出厂设备号>`（同 agent-hardware 出厂证书），EKU ClientAuth，KeyUsage digitalSignature，AKI 取 CA 自带 SKI，由实验室出厂 CA 签发，有效期 10 年。工具 `firmware/tools/factory_identity.py` 生成 CSV 与 `fac.bin`，输出目录权限 0700、私钥文件 0600，默认放仓库外。
- 已知上限：私钥明文存 flash（开发板无 flash 加密）；服务端换 HSM CA 后开发板证书失效（`42117`），届时重签。

### BLE 契约（沿用加密配对链路）

- 新增只读特征 `identity`（`YAHA_UUID(0x0b)`，加密 + 认证读）：出厂证书 DER 原文（≤512 B）；Mac 取证书 CN 作出厂设备号。无 `fac` 分区时读到空值，Mac 提示「设备没有出厂身份」。
- `provision` 特征新增 op（JSON ≤512 B，与 `wifi`/`grant` 同一写入口）：

| op | 字段 | 设备行为 |
| --- | --- | --- |
| `dms_proof` | `device_id`（18 位 `[0-9a-z]`）、`challenge`（b64url 16–128） | 云端任务用出厂私钥对 `SHA-256("xpan-dms-iotcore-pop-v1\n"+device_id+"\n"+challenge)` 签 ES256，`r‖s` 64 字节 b64url 放进状态 `proof`，并记住这个 device_id |
| `dms` | `device_id`、`core_id`、`secret`、`mqtt_url`、`command_topic` | 只接受刚签过的 device_id；校验 broker 白名单、topic 前缀 `ah/{device_id}/` 与后缀 `/cmd/down`；存 NVS `deskcloud/dms` 后连 MQTT |
| `dms_reset` | 无 | 删除 DMS 凭据，断开 MQTT；Wi-Fi 与 yahaops 授权保留 |

- 云端状态特征 `cloud` 的 JSON 新增：`dms`（`""` 未绑定 / `connecting` / `online` / `offline`）、`device_id`、`proof`。字段只增不改，0.3.0 Mac 忽略未知字段。
- 任何日志只记错误码，不记 secret、token、challenge、签名、Wi-Fi 密码。

### IoT Core MQTT（移植 `dms.c`）

- 用户名 `thingidp@{core_id}|{device_id}|{ts}|SHA256`，密码 `hex(sha256("{device_id}&{ts}&SHA256{secret}"))`，每次连接重算；SNTP 对时（≥1700000000）后才登录。broker 只认 `*.iot.gz.baidubce.com`。
- 订阅 `ah/{device_id}/#`；前缀取自 `command_topic` 去掉 `/cmd/down`。每 60 秒发 `presence {"online":true,"fw","boot_id"}`（服务端 TTL 180 秒，无遗嘱）；`dms_reset` 或解绑前发 `{"online":false,"reason"}`。
- 指令 `{message_id, action, args, ts}`：早于开机对时前的丢弃；最近 8 个 message_id 去重；超过 60 秒回 `REJECTED EXPIRED`；回复写 `cmd/up {message_id, result, detail, output, ts}`。动作：`get_status`（回固件版本、静音、Wi-Fi 名；待传录音在 Mac 上，不在设备）、`mute`（只能静音，不能开麦，与 yahaops 一致）、`unbind`（回 OK 后执行 `dms_reset`）。`card`（`args:{title, body?, ttl_seconds?}` 显示 agent 卡片，`{clear:true}` 清除全部 agent 卡片；上限同 BLE 卡片，不合规回 `REJECTED INVALID_ARGS`；离线超过 60 秒的卡片过期不补送；整条指令 ≤1900 字节、不分片，超出静默丢弃；解绑或重新绑定时清掉全部 agent 卡片）。未知动作回 `REJECTED ACTION_NOT_SUPPORTED`（同 SDK `dms.c`）。
- 网络名上云：连上 MQTT 及换网后发 `state/reported {"wifi":{"ssid"},"fw"}`，只含 SSID。
- 讲话时暂停 HTTP 的既有规则不变。MQTT 讲话时**断开**，静音满 10 秒再重连：2026-11-06 真机连着 MQTT 讲话送声掉到 0–5 帧/s（内部堆约 10 KB、DMA 最大块 3 KB），keepalive 与 TLS 记录和 BLE 音频抢射频。讲话期间的指令靠持久会话 + QoS 1 留在服务端，重连后补收。只把下次连接推后到至少 10 秒后，不缩短失败退避；一直连续讲话（静音间隔都不到 10 秒）时 MQTT 一直离线、指令一直延后。开始讲话时若正在 TLS 握手，断开最多卡 10 秒（esp-mqtt 内部锁），这段时间只影响 MQTT 任务。
- esp-mqtt 任务栈与收发缓冲放 PSRAM（`CONFIG_MQTT_TASK_STACK_ON_EXTERNAL_MEMORY`、`CONFIG_MQTT_BUFFERS_ON_EXTERNAL_MEMORY`）：放内部时内部堆最低剩 16 B，yahaops TLS 与 BLE 加密失败。MQTT 回调只碰原子量与队列，不写 NVS/flash。
- CONNACK 拒绝（用户名或口令错，即凭据已被重置）后不再重连，等重新绑定、`dms_reset` 或重启。风险：服务端临时误拒一次也要重启或重绑才恢复；好处是不会拿失效凭据反复连服务端。

### Mac「Yaha Desk」

- 网盘登录：WKWebView 打开 `pan.baidu.com/union/oauth/authorize?response_type=token&client_id=<AppKey>&redirect_uri=&state=<随机>`；当前页面按 AppKey 从服务端读取已配置权限，不再发送旧入口的 `scope`/`display`，也不使用 OOB。只接受该 HTTPS 授权页带 `access_token` 的 fragment，核对 `state` 后存入 Keychain（`ThisDeviceOnly`、首次解锁后可用）；剩余 <60 秒视为失效，旧 `openapi.baidu.com/login_success` 回调不再接受。
- 绑定：读 `identity` → `register`+`bind`（device_addr = device_sn = 出厂设备号，设备名 `Yaha Desk`）→ `iotcorechallenge` → BLE `dms_proof` → 等 `proof` → `iotcoreprovision`（30 秒超时，不重试：每次调用都会重置设备密钥）→ BLE `dms` → 等 `dms=online`（60 秒）。任一步失败：发 `iotcorecommand unbind`（尽力）、`unbind`、BLE `dms_reset`，再报错。
- 解绑：同上回滚路径。`42103` 提示设备已被他人绑定；`42118` 提示稍后再试。

### 录音备份（批 2，Mac 上传）

- 录音窗口：链路在线且取消静音起，到静音或断开后再等 1 秒（收静音后到达的尾帧）为一段；不足 1 秒（误按）不存。期间再次开麦就先结束上一段。
- Mac 拿 BLE 收到的原始 Opus 帧（16 kHz 单声道、60 ms、32 kbps）直接封装 Ogg Opus（RFC 7845，pre-skip 312 = libopus 编码器前瞻），不重新编码；`DeskProtocol/OggOpus.swift`。
- 先写本机 `~/Library/Application Support/YahaDesk/Recordings/YYYY-MM-DD/HHmmss.opus`（本机时区、录音开始时间），网盘 create 返回 HTTP 200、errno 0 且带 fs_id 后才删除；同名本机文件已存在（时钟回拨）时加 `.n` 后缀，不覆盖；失败（断网、令牌失效、空间满）留在本机，下次录音结束、App 启动或登录网盘后按时间顺序补传。未登录网盘时不录。上传返回 -6/111 时清掉网盘令牌，界面提示重新登录。上传期间新结束的录音在同一轮接着传。
- 上传：precreate（4 MB 分块 md5，`rtype=1` 重名自动改名）→ locateupload（每次现取，不缓存）→ superfile2 → create，路径 `/apps/拾见/录音/<同上相对路径>`；precreate 返回 `return_type=2`（秒传）时跳过分块。令牌放 query（接口要求），日志只记接口名与 errno。
- 列表：「设备设置 → 录音备份」用 `xpan/file list`：先列 `/apps/拾见/录音` 下的日期目录（按名倒序），再逐个目录列文件，最多看最近 30 个日期目录、凑满 100 条为止，列出文件名、时间、大小，并显示本机待上传段数。2026-11-06 真机 `multimedia listall` 对本应用回 errno 20020（路径不在允许范围内，开放平台错误码表），服务端同一应用用 `list` 正常，故改用 `list`。某个日期目录读失败时显示已读到的部分；全部失败才报错。
- 已知上限：本机录音不加密、不限总量（只在上传失败时堆积）；列表只取最近 100 条，不分页；录音中途退出 App 的那段丢失（只在结束时写文件）；关闭按键说话（常开麦）时整段连接算一段录音。

## 路线与状态

| 批次 | 内容 | 风险 | 状态 |
| --- | --- | --- | --- |
| 1 | 出厂身份工具与分区表；固件 `identity`、`dms_proof`/`dms`/`dms_reset`、MQTT 在线/指令/SSID 上报；Mac 网盘登录、DMS 客户端、绑定与解绑 | 高：设备凭据、出厂私钥、分区表 | `a4de3dd9` 已推送；2026-11-06 烧录，用户确认绑定可用 |
| 1.1 | 设备控制只走 DMS：固件 `card` 指令；API 删除 `desk_send_card`/`desk_mute`/`desk_status`，`desk_pull` 留空壳，MCP 1.13.0；固件删除 `desk_pull` 轮询与指令游标 | 中：删除对外 MCP 工具，旧 agent 调用失败 | 已推送、未发布、未烧录 |
| 2 | MQTT 移 PSRAM、凭据被拒不重连、讲话时断开 MQTT；Mac 录音 Ogg Opus 封装、网盘上传与已备份列表 | 中：网盘令牌只在 Mac 钥匙串 | 已推送；`6f050a28` 2026-11-06 app-flash，压测通过（见[压测报告](压测报告-2026-11-06.md)） |

批 2 本地证据（2026-11-06）：`idf.py build` 通过（app 0x2bf5f0，分区余 31%）；`tests/dms_wire_test.cpp` 通过；`swift test` 47 项通过（含 Ogg CRC/分页、录音留存与补传回归）；libopus 编码的 3 秒样本经 `OggOpusWriter` 封装后 afconvert 可解码。审查 2 轮，发现均已修复并补回归。

批 2 真机（2026-11-06）：Mac 上传 3 段成功（create HTTP 200 errno 0 带 fs_id），列表 listall 回 20020 已改 `list`。固件 app-flash 后 Wi-Fi 初始化吃掉 57 KB 内部 RAM（86 KB → 19 KB），BLE 连上后内部堆最低 2 KB、DMA 最大块 < 500 B，esp-aes 分配失败、云端 HTTPS `sync_failed`、BLE 加密失败 13。修复：Wi-Fi 静态 TX 缓冲 16→8、RX 热路径不进 IRAM（`sdkconfig.defaults`），频谱缓冲约 14 KB 移到 PSRAM（`audio.cpp`）；`idf.py size` 的 DIRAM 静态占用 139603 → 125267 字节，运行时省多少待烧录实测。

批 2 修复后真机压测（2026-11-06，`6f050a28`，[压测报告](压测报告-2026-11-06.md)）：Wi-Fi 入网后内部空闲最低 44967 字节、开机以来最低水位 39828、DMA 最大块 31744，无分配失败与 TLS 错误；连续讲话 180 秒送声 16 帧/s，零丢帧、零解码失败；12 段录音上传与 `list` 全部 errno 0；每段讲话结束约 10 秒后出现一次 TLS 握手，与 MQTT 静音 10 秒重连一致。

批 2 未验证：讲话期间下发指令在重连后补收（本轮未从网盘侧下发）、服务端 `dms=online` 状态、网盘录音播放与时长、「录音备份」界面列表显示、小时级静置。

批 1 本地证据（2026-11-05）：`idf.py build` 通过（app 0x2bef50，分区余 31%）；`tests/dms_wire_test.cpp` 通过；`swift test` 44 项通过；`tools/factory_identity.py` 生成的开发板证书 `openssl verify` 过实验室出厂 CA，私钥与证书公钥匹配，`fac.bin` 0x6000（放仓库外 `~/.local/share/yahadesk/factory/<id>/`）。

批 1 未验证（需烧录与真机）：

- 真实 broker 登录（用户名/口令格式、CONNACK）、持久会话补收离线指令、`cmd/up` 回复被服务端接受。
- esp-mqtt 任务栈（默认 6144，内部 RAM）与 TLS 缓冲在讲话 + BLE 音频 + Wi-Fi 并存时的内部堆水位；不足时再开 `MQTT_USE_CUSTOM_CONFIG` 把栈与缓冲放 PSRAM。
- 服务端是否认可本工具签发的证书（`42117`）；Mac 网盘登录回调地址；隐式授权是否影响服务端 `desk-tts` 令牌（见上）。
- 云端状态 JSON 带 86 字符 `proof` 时超出单条通知（MTU 247 → 244 字节），Mac 解码失败会补读一次（读可长读到 512 字节）。

每批：失败测试先行 → `idf.py build`、`swift build`/`swift test`、主机侧单测 → change-audit → 推送 `main` → 用户授权后烧录固件与出厂分区 → 真机核对（绑定、MQTT 在线、`get_status`、解绑；批 2 看网盘文件）。

## 验收点

1. 未绑定设备：Mac 登录网盘后点「绑定网盘」，设备 60 秒内 `dms=online`，网盘设备列表出现该设备。
2. `iotcorecommand get_status` 在 `cmd/up` 收到 OK 与 SSID、固件版本；`state/reported` 只含 SSID，不含密码。
3. 绑定中途任一步失败，网盘侧不留绑定，设备不留 DMS 凭据。
4. 解绑后设备删除 DMS 凭据，Wi-Fi 与 yahaops 授权仍在。
5. 换网后 `state/reported` 更新为新 SSID，MQTT 自动重连。
5a. （批 1.1）`iotcorecommand card {title,body}` 后设备屏上出现通知、`cmd/up` 回 OK；`{clear:true}` 清掉 agent 卡片；空标题回 `REJECTED INVALID_ARGS`；160 字中文正文（480 字节，转义后约 1 KB）能显示；网盘解绑或 BLE 重新绑定后 agent 卡片消失（dms.cpp 无主机测试，需真机）。网盘侧下发方不在本仓库，未验证。
5b. （批 1.1）发布 API 后，未升级的 0.2.0 固件调 `desk_pull` 不报 `sync_failed`。
6. （批 2）开麦讲话后静音，网盘 `/apps/拾见/录音/<日期>/` 出现可播放的 `.opus`，时长与讲话一致；断网期间的录音恢复联网后补传。
7. （批 2）「设备设置 → 录音备份」列出网盘里已备份的录音；有未传的显示待上传段数。
8. （批 2）按住讲话持续 30 秒，Mac 指标送声保持约 16 帧/s，不卡顿；静音 10 秒后设备重连 MQTT，讲话期间下发的指令补收并回复。

## 明确不做

- 不改 yahaops API、schema、部署与 `desk_*` MCP 工具；不把 SSID 存 yahaops。
- 不引入 SDK 的 ah-ble-sec1、包装二维码与 PoP 秘密、OTA。
- 不把网盘令牌交给设备或 yahaops 服务端；固件不上传录音、不加录音分区。
- 不自动烧录固件或出厂分区，不做生产 CA 与量产工具。
