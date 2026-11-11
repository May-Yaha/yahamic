# 桌面工作台固件（2026-11-05）

## 目标与已确认范围

用户 2026-11-05 认为现有三页轮播（像素时钟、Mac 状态、通知）没有实际用途、也不能操作，要求把桌面设备改成 yahaops 的**快速处理工作台**：平时一屏看清系统是否正常，出问题直接在设备上处理；并追加纳入**小程序数据**。

同日确认：场景表与三批路线照推荐执行；风控放行等改业务数据的决定设备只读、仍在 PC 处理；轮播与其配置整体删除，通知并入「待我处理」。确认方式默认**长按屏幕 1.5 秒**，静音键保持硬件静音单一语义不复用（静音是隐私开关，叠加长按会让误触变成误开/误关）。

基线 `a2daf9eb`，worktree `../yahaops-desk-workbench`，短分支 `feat/desk-workbench`。

## 场景

| # | 场景 | 屏幕 | 设备操作 | 复用能力 | 批次 |
|---|---|---|---|---|---|
| 1 | 健康总览 | 任务/采集/处理/GLM/小程序/设备各一格，红黄绿 + 更新时间 | 点格进详情 | `TaskQueueStore.Stats` 等 | 1 |
| 7 | GLM 额度 | 今日用量、在途、冷却剩余 | 只看 | `glm_usage` | 1 |
| 10 | 发布后核对 | 当前 API release、健康、最近 run 程序 digest | 只看 | 现有 run 记录 | 1 |
| 11 | 小程序数据 | 今日 UV/PV、有效阅读、读完、笔记，较上期升降；近 7 日迷你趋势 | 只看 | `miniapp.Logic.Report`（overview） | 1 |
| 2 | 任务失败 | 任务名、失败次数、错误分类、一行摘要 | 重试 | 入队 `RetryOf` | 2 |
| 3 | 失联运行 | 租约过期仍 running | 取消 | `TaskQueue.Cancel` | 2 |
| 4 | 止血 | 连续失败的任务 | 暂停/恢复 | `TaskQueue.SetPaused` | 2 |
| 5 | 采集断流 | 最近成功距今超阈值 | 立即跑一次 | 入队 | 2 |
| 6 | 文章处理积压/失败 | 各阶段积压、失败条目 | 失败项重新入队 | articleprocessing 入队 | 2 |
| 8 | 待我处理 | 风控隔离待审、待审核用户、新用户反馈、最新文章/日报/agent 消息 | 只看摘要 | article_risk、waitlist、user_feedback、desk_feed | 3 |
| 9 | Agent 确认请求 | agent 发来的问题与两个选项 | 同意/拒绝，结果回传 agent | DMS `card` 指令扩展（2026-11-06 起 agent 卡片走网盘） | 3 |

总览常驻；出现新告警自动跳到告警页，可选扬声器提示一声；讲话与配对仍优先于工作台界面。

## 契约与权限

- **批 1 只读工具 `desk_monitor({})`**，挂在设备现有 `desk.sync` 授权下，不要求设备重新授权；返回各分区聚合与告警列表。每个分区按本人现有权限单独判定：任务/处理/GLM 复用 `taskQueueAccess`（活跃管理员 + 任务菜单），小程序复用 `get_miniapp_analytics` 的菜单授权；无权的分区返回 `available:false`，不整体失败。只返回计数、状态、时间和错误分类，**不返回日志原文、用户标识、正文**；错误摘要截断并视为不可信数据。
- **批 2 写操作**：新 scope `desk.operate`，仅活跃管理员可授予，与 `desk.sync` 分开授权和撤销；设备专用应用的公开应用限制（现仅允许只登记 `desk.sync`）同步放宽为 `desk.sync`/`desk.operate` 子集，并补回归。每条告警由服务端附短时操作令牌（绑定 owner、告警对象与允许动作，单次有效），设备只能提交「令牌 + 动作」，不能构造任务 key 或参数；带幂等键、写审计记录，屏幕回显结果。
- **永不在设备上做**：发布、删除数据、风控放行、用户审核、开麦。
- **轮播删除**：删除 `desk_get_display`/`desk_set_display`、`desk_pull` 的 `display` 输入输出、Mac 排序/秒数界面和固件轮播；`desk_display` 表保留不读、不 DROP（持久卷历史数据不清理）。`desk.configure` 仍保留给 Mac 的 `desk_prepare_device`。旧固件拿不到 `display` 时须保持最后缓存配置不崩溃，批 1 验证。

## 路线与状态

| 批次 | 内容 | 依赖 | 风险 | 状态 |
|---|---|---|---|---|
| 1 | API `desk_monitor`（含小程序分区）；固件触摸驱动、总览/详情/告警页；删除轮播（API/Mac/固件） | 无 | 中：读取管理员聚合、触摸驱动与内存 | 已推送 `6a170c36`、未发布；固件未烧录 |
| 2 | `desk.operate`、操作令牌、长按确认、场景 2–5（6 跳过） | 批 1 生效；网盘 MCP 对接完成 | 高：设备写权限与 OAuth，开工前再报评估 | 已实现；2026-11-06 用户选择「实现并立即推 main」，不等批 1 生效，与批 1 一起发布；未发布、固件未烧录 |
| 3 | 场景 8、9；agent 双向确认 | 批 2 生效 | 中：新消息模型 | 未开工 |

每批：失败测试先行 → 门禁 → change-audit → 推送 `main` → 用户手动发布 → 用户授权后烧录 → 只读与真机核对，生效后再合下一批。

## 批 1 实现记录（2026-11-05）

- **API**：`desk_monitor` 挂在 `desk.sync` 下（与 `desk_pull` 同条件），领域纯函数 `domain/desk/monitor.go` 判定等级与告警；只读查询在 `dao/store/desk_monitor.go`，可选流水线表缺失按无数据处理；MCP 1.12.0。轮播工具与 `desk_pull.display` 删除，旧固件上报的 `display_revision` 忽略，`desk_display` 表保留。
- **固件 0.3.0**：触摸为 CST9220（I2C 0x5A、INT GPIO11、RST GPIO40，`espressif/esp_lcd_touch_cst9220`），经 esp_lvgl_port 输入；初始化失败只记日志，界面照常显示。总览六行（五个云端分区 + 本地设备行）、详情、告警、通知四页；新告警 key 自动跳告警页；60 秒空闲回总览；总览 3 分钟未更新清等级。BLE info 保留 `display 1` 兼容 0.2.0 Mac 配网。
- **Mac 0.3.0**：删除轮播预览、排序与秒数界面；配网与设备授权保留。
- **字库**：所有固定文案与 API 下发字符串由 `font_metrics_test.py` 校验 `font_zh_sub` 字形与实际标签宽度；总览设备行摘要改为 `CPU100% 内存100%`，行标题列 90 px、告警时间列 80 px。
- **未验证（需真机）**：触摸方向（`board.cpp` 的 `swap_xy`/`mirror_*` 为校准点）、触摸与 Wi-Fi/BLE 音频共存时的丢帧和内部 RAM 水位、实际渲染截图。固件未烧录。

## 批 2 实现记录（2026-11-06）

- **范围**：场景 2–5（失败重试、失联取消、连续失败暂停/恢复、断流补跑）。场景 6（文章失败项批量重新入队）跳过：一次改多条业务数据，不适合单次长按，仍在 PC 处理。用户 2026-11-06 确认设备控制只走网盘后，本批的任务操作仍属 yahaops 业务数据，经 MCP 保留。
- **授权**：新 scope `desk.operate`。`desk_prepare_device` 对活跃管理员登记 `desk.sync desk.operate`，已有只登记 `desk.sync` 的设备应用就地追加，只推进 `revision`、不改 `updated_at`，既有令牌不失效；从不收回。MCP 网关只把 `desk.operate` 留给 `desk_prepare_device` 绑定的那一个本人设备专用公开应用（手工建的同 scope 公开应用、带 secret 的应用、动态注册、他人应用都剥掉，防止智能体绕过长按确认）；同一失败运行无论换几张令牌只入队一次重试。Mac 按 prepare 返回的 `scope` 申请授权，**须重新授权设备**才拿到 `desk.operate`；授予结果须包含 `desk.sync` 且是申请的子集。
- **令牌**：`desk_monitor` 只在 token 带 `desk.operate` 时给告警附 `action` + `token`，HMAC（由会话密钥派生）绑定 owner、动作、对象与 10 分钟过期；目标对象不下发。`desk_operate({token,action})` 每次重新校验活跃管理员，`desk_operation` 表（schema v89）按令牌哈希单次认领并记录结果，重放返回首次结果；入队带 `desk:` 幂等键。审计行不存令牌原文；运行记录 `actor_id` 为本人。预期内的拒绝返回一行文案（固件把工具错误当同步失败）。MCP 1.14.0。
- **固件**：告警行长按 1.5 秒（`lv_indev_set_long_press_time`）提交，按下时整行高亮；点击改用 `LV_EVENT_SHORT_CLICKED`，长按松手不再触发返回。云端任务单槽排队，30 秒未送达提示「未送达，请重试」；讲话时不提交。结果替换告警页标题 10 秒。解析时未知动作、空令牌、超 256 字节或含非 base64url 字符的令牌丢弃动作、保留告警。
- **未验证（需真机）**：长按时长与误触、按下高亮、结果回显。固件未烧录。

## 已知缺口

- ~~触摸控制器型号未记录~~：已按 Waveshare ESP32-S3-Touch-AMOLED-2.16 资料确定为 CST9220（0x5A、INT GPIO11、RST GPIO40），真机 I2C 应答待烧录后核对。
- `../yahaops-desk-ble-fix` 有约 60 行未提交的固件改动（`cloud.cpp`/`main.cpp`/`uplink.cpp`/`sdkconfig.defaults`，2026-11-04），`../yahaops-desk-dictation` 有 4 行未提交改动（`audio.cpp`/`board.cpp`）。本需求会改同一批文件，不纳入也不覆盖；需用户确认这两处是否仍要合入、以及当前设备烧的是否为 main 版本。
- 健康阈值（采集断流多久算红、积压多少算黄）首版取常量写在 API 领域纯函数里，用 `shortcut:` 注释标明，有误报再调。

验收见[验收表](acceptance.md)。
