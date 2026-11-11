# 页面轮播验收

负责人：Codex；自动化检查点为本轮交付前，真机检查点为用户授权烧录与网页登录后。状态只随实际证据更新。

| ID | 前置与操作 | 可观察预期 | 验证状态 |
| --- | --- | --- | --- |
| DESK-ROT-001 | 新账号首次读取配置 | 按时钟10s、Mac状态15s、通知20s顺序返回默认配置，不写入其他账号 | API `TestDeskDisplaySaveCASNoChangeAndIsolation`、真实HTTP/SSE测试通过 |
| DESK-ROT-002 | Mac在未连接BLE时调序、停用一屏、修改秒数并保存 | 云端按所填配置保存；设备未同步前显示等待应用 | Mac `cloudSaveWorksWithoutBLEAndKeepsNewEditsDuringRequest`通过；真实授权/设备同步待验 |
| DESK-ROT-003 | 两个控制端基于同一版本保存不同配置 | 先保存者成功，过期版本失败，不能覆盖；原样保存不增加版本 | API CAS/并发测试、Mac冲突保留草稿测试通过 |
| DESK-ROT-004 | 配置含重复/未知页面、时间4或301秒、全部停用 | 请求失败且原有效配置保留；5与300秒合法 | Go `TestDeskDisplayValidation`、Swift配置边界、C++行为/JSON边界测试通过 |
| DESK-ROT-005 | 使用其他账号、仅sync或仅configure的token调用工具 | owner隔离；configure不能pull/feed/ack，sync不能写配置 | API工具/scope/owner隔离、OAuth生命周期测试通过 |
| DESK-ROT-006 | 旧桌面数据库结构升级；旧客户端不传display_revision反复pull | 原命令、TTL和ack语义保留；数据库保留历史版本，最新旧客户端不再确认该版本；重复启动幂等 | `TestDeskDisplayUpgradeAndLegacyPullPreserveHistoryWithoutClaimingApplied`、既有desk/TTL/ack测试通过 |
| DESK-ROT-007 | 设备应用一版配置后重复拉取；随后重启与断网 | 同版不重启轮播；有效配置持久恢复；离线继续轮播 | C++同版计时测试通过；NVS重启/断电恢复和实际断网待真机 |
| DESK-ROT-008 | 计时到每屏边界，禁用自动轮播或某页 | 恰好到期切换，禁用页不出现；固定展示首个启用页 | C++轮播边界、停用页与固定模式测试通过；最终固件四次SCR确认状态页到时钟一次实际转场，精确秒数/全周期待验 |
| DESK-ROT-009 | 通知页无内容；文章、日报、agent消息同时有效 | 空通知页跳过；三类内容都能出现，通知TTL与单屏停留秒数独立 | C++空页/多类通知/TTL/clear测试通过；实际内容上屏待真机 |
| DESK-ROT-010 | 讲话或配对打断轮播；松开后恢复 | 配对/讲话优先；恢复轮播，不误开麦；讲话时暂停联网 | C++暂停恢复通过；最终固件5秒实际采集后恢复静音/PTT且基础轮播继续；真实配对/联网中断与无线共存待验 |
| DESK-ROT-011 | Mac断链或指标超过新鲜窗口 | Wi-Fi卡片和时钟仍可展示；Mac指标显示未知而非冻结旧值 | 过期分支源码核对、Swift/IDF构建通过；真实断链与电量读数待验 |
| DESK-ROT-012 | 新旧Mac与固件组合发送10/12字节dashboard | 旧10字节保持原含义；新12字节显示Mac电量与供电，旧固件提示不支持新功能 | Swift载荷边界、固件10/12字节解析源码核对与构建通过；组合真机待验 |
| DESK-ROT-013 | OAuth callback收到错误state、错误path、非loopback来源、取消或超时 | 不接收授权码，不泄露token；设备token不留Mac，控制密钥留钥匙串、client credentials令牌仅留内存；旧PKCE授权仍兼容 | Swift PKCE标准向量、回调与可信拒绝测试通过；真实浏览器与完整钥匙串生命周期待验 |
| DESK-ROT-014 | 未认证BLE写配网/授权，HTTP失败、无效JSON、存储失败 | 未认证写拒绝；错误不覆盖有效配置或误报已应用；不记录凭据且音频不被阻塞 | JSON/SSE边界与真实HTTP测试通过；BLE权限/NVS错误路径源码核对；故障注入和无线性能待真机 |
| DESK-ROT-015 | 已安装连接凭据的Mac启动、令牌到期、缺少权限 | 不要求填写Client ID/密钥；仅申请desk.configure；到期重取，权限不足明确提示；旧PKCE记录保留 | 真实最小scope token及读取HTTP200、Swift回归通过；用户允许钥匙串后正式App configured=true/client_credentials/已连接轮播控制 |
| DESK-ROT-016 | 点击授权设备；重复/并发准备或应用已撤销 | 自动准备本人public desk.sync应用，仍需PKCE同意；不签发grant、不误认其他应用、不绕过20上限、不复活已撤销应用；eval不写 | API真实Handler、并发/迁移/撤销回归通过；生产26d1c2b8已切流，真实浏览器与设备交付待验 |
| DESK-ROT-017 | 查看时钟、Mac状态、通知和离线状态；查看Mac预览 | 系统文案为中文，字体完整、布局不误裁切，预览文案与480方屏一致；通知保留原文及既有省略 | 字体覆盖/宽度与Mac预览通过；最终固件120px抽样确认时钟/状态页布局，通知页和物理屏清晰度待验 |
| DESK-ROT-018 | 从tracked defaults重新构建并烧录；检查实际音频与Wi-Fi启动日志 | LVGL池在PSRAM；32KiB音频栈在内部；保留RX10/BA6预算；真实采集正常且最终恢复静音 | 首次RED后固定RX10/BA6并完成最终bin真机回归；--require-capture通过、59/59/60ms、累计101帧均输出，静音/PTT恢复；真实HTTPS/无线共存待验 |

构建通过只证明可编译，不能替代设备配对、Wi-Fi/ BLE共存、运行内存和真实OAuth验收。

命令、实际输出、审计与发布状态见[验证记录](verification.md)。
