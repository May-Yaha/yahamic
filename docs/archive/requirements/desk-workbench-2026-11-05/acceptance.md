# 桌面工作台验收

状态只随实际证据更新；自动化通过不代表真机或生产已验证。

| ID | 批次 | 前置与操作 | 可观察预期 | 验证状态 |
| --- | --- | --- | --- | --- |
| DESK-WB-001 | 1 | 管理员设备 token 调 `desk_monitor` | 返回任务、处理、GLM、小程序、设备分区与告警；无日志原文、用户标识、正文 | 自动化通过（`mcpingest.TestDeskMonitorSectionsFollowEachPermission`、`store.TestDeskMonitorReadsTaskProcessingAndGLMFacts`）；生产未核对 |
| DESK-WB-002 | 1 | 非管理员、无小程序菜单授权、其它账号的 token | 无权分区 `available:false`，其余正常；不泄露他人数据 | 自动化通过（同上：管理员/仅小程序/普通读者三账号） |
| DESK-WB-003 | 1 | 仅 `desk.configure` 或动态注册智能体 token | 拿不到 `desk_monitor` | 自动化通过（`desk_test.go` scope 与公开应用矩阵） |
| DESK-WB-004 | 1 | 构造失败运行、待核对运行、失联运行、采集超阈值、GLM 冷却 | 对应告警出现且等级正确；恢复后告警消失 | 自动化通过（`desk.TestTaskSectionsFlagFailedLostAndStalledCollection`、`TestProcessingAndGLMLevels`；纯函数无状态，恢复即无告警） |
| DESK-WB-005 | 1 | 小程序 overview 有/无上期数据 | 今日指标与升降正确；上期不可用时不显示升降 | 自动化通过（`desk.TestMiniappSectionDeltaOnlyWithPreviousDay`） |
| DESK-WB-006 | 1 | 设备点总览某格、返回；新告警到达 | 进入详情/返回总览；新告警自动跳转，讲话时不打断讲话界面 | 导航策略 host 测试通过（`display_test.cpp`）；未验证（真机） |
| DESK-WB-007 | 1 | 旧固件对删除 `display` 后的 API 反复 pull | 命令、ack、TTL 不变，设备保持缓存页面不崩溃 | API 侧自动化通过（`desk_transport_test.go` 旧形状 `display_revision`）；旧固件源码核对：缺 `display` 时跳过、保留缓存配置；未真机 |
| DESK-WB-008 | 1 | 删除轮播后 Mac App 启动、授权设备、配网 | 无轮播配置界面；`desk_prepare_device`、配网与 BLE 音频保留 | `swift build`/`swift test` 见批 1 门禁；启动与授权未真机 |
| DESK-WB-009 | 1 | 触摸、Wi-Fi、BLE 音频同时工作 | 实际采集丢帧/溢出为 0，内部 RAM 水位不低于现版本 | 未验证（真机） |
| DESK-WB-201 | 2 | 管理员/非管理员调 `desk_prepare_device`；已有只登记 `desk.sync` 的设备应用；带 secret、动态注册、他人应用的 `desk.operate` token | 管理员登记 `desk.sync desk.operate` 且旧令牌不失效，非管理员只有 `desk.sync`；非设备专用应用列不出 `desk_operate`；Mac 只按 prepare 返回的 scope 申请、拒绝超出申请的授予 | 自动化通过（`store.TestDeskDevicePreparationGrantsOperateToAdminsWithoutInvalidatingTokens`、`mcpingest.TestDeskPullRequiresOwnOrConfidentialClient`、`desk-scope.test.ts`、Mac `CloudSyncTests`）；Mac 重新授权未真机 |
| DESK-WB-202 | 2 | 失败运行告警；重放、过期、换人、换动作、伪造令牌；无 `desk.operate`；长按 1.5 秒与短按 | 只在授予时附令牌；拒绝全部不入队；首次重试单次入队、重放返回首次结果；取消已结束运行提示状态变化；暂停/恢复生效；审计行可查且无令牌原文；短按不执行，长按后屏幕回显结果 | API 自动化通过（`mcpingest.TestDeskOperateRunsSignedAlertActionsOnce`、`desk.TestOperationTokenBindsOwnerActionTargetAndExpiry`、`desk.TestTaskSectionsAttachDeviceActions`）；固件解析与文案 host 测试通过（`display_json_test.cpp`、`display_test.cpp`、`font_metrics_test.py`）；长按与回显未验证（真机） |
| DESK-WB-012 | 3 | agent 发确认请求，设备同意/拒绝/超时 | agent 读到对应结果；超时为未答复 | 未开工 |
