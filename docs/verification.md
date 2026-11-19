# 已验证 / 未验证

**已验证(2026-11-01,协议 v1 / Wi-Fi,ESP-IDF 6.1 + macOS 26 + 真机端到端):**

- 固件与 Mac 构建、刷写和设备重连;ES7210 以 16 kHz/60 ms 采集并经 Opus 发送,
  屏幕、电量、按键硬件静音正常。
- 端到端:配网 → mDNS/静态地址发现 → 握手 → 解码与预缓冲 → BlackHole 2ch;
  180 秒连续语音欠载/溢出/解码错误均为 0,FFmpeg 能从 BlackHole 录到真实音频。
- Mac 控制接口 100 次请求失败 0;Fn 事件、1 秒粒度静音切换、App 重启自动恢复、
  解码后 PCM WAV 录制均通过实测。
- 设备波形真机达到 24.3–24.8 fps,采集间隔保持 59–60 ms。

**未验证 / 已知事项:**

- 协议 v3（BLE）的历史构建记录不能证明本次无线共存性能；真机配对、压测、
  断链重连与长静音回归待复验。上面的「已验证」条目和[压测数据](performance.md)都来自 Wi-Fi 版本。
- 0.3.0 桌面工作台的验证状态见[验收表](archive/requirements/desk-workbench-2026-11-05/acceptance.md)；触摸、内存水位与无线共存待真机复验。0.2.0 轮播（已删除）的测试、构建、兼容与上线状态记录在[验证记录](archive/requirements/desk-carousel-2026-11-03/verification.md)，不沿用历史压测结论。
- 设备只接受一个连接:Mac 不在线时,别的设备连上会占住链路(配不上对就一直停在配对屏),
  断开后恢复广播。

- 讲话键:Apple 键盘/妙控键盘用 Fn;HHKB 等键盘的 Fn 在键盘固件里处理、不上报 macOS,
  在面板「讲话键」里改成左 Command / 左 Option / 左 Control / 右 Option / 右 Command / 右 Control(修饰键只认选中的那一颗;与其他键同按视为快捷键,不送声)。
- 电池续航、超过 1 小时连续送声和实际通话时延仍未测。

**联调中踩过并修掉的坑(供后来者,含系统升级;Wi-Fi 相关几条来自 0.4.0 及以前)**:

- **Fn 键(macOS 26)不再设置 SecondaryFn 修饰位**,只以键码 63 上报——监听要同时
  覆盖 flagsChanged 与 keyDown/keyUp 的键码 63(apps/macos/Sources/DeskCore/FnListener.swift)。
- **CGEventTap 用 `.cghidEventTap + listenOnly` 出现过"创建成功但零事件"** → 改
  `.cgSessionEventTap + defaultTap`(回调须原样返回事件);C 回调不捕获上下文,
  监听器实例必须全局持有(if-let 块内释放 = 野指针 = bus error)。
- **系统升级产生"僵尸辅助功能授权"**(查询 true、事件不放行,设置里也没有条目)
  → `tccutil reset Accessibility com.yaha.desk` 重置后由 App 重新申请;App 内每
  2 秒轮询 `AXIsProcessTrusted()`,缺权限自动弹系统确认框、授权后自动恢复。
- **ad-hoc 签名每次重打包丢授权** → 打包脚本自动检测并用 Xcode 的 Apple
  Development 证书签名。
- **系统升级后 coreaudiod 不重载 HAL 插件**(BlackHole 文件在但设备消失)
  → `sudo killall coreaudiod`。
- **固件 `SO_RCVTIMEO` 必须传 `struct timeval`**——传 `int 200` 会被当成 200 秒,
  worker 假死,表现为 daemon 重启后设备再也连不上。
- **旧 Wi-Fi UDP 音频链路必须 `esp_wifi_set_ps(WIFI_PS_NONE)`**:默认省电按信标缓冲,
  音频周期性卡顿,语音转写端表现为"整句重复"。音频走 BLE 时相反,`PS_NONE` 会挤掉 BLE 空口。
- daemon 的 `handleHello` 若对任何来源刷新"最后活跃时间",重连设备会被自己的
  hello 永远拒之门外:同名设备(名字含 MAC)直接接管。
- 纯命令行进程里 NSEvent 全局监听不触发(要 NSApplication 事件循环)。
- SDK 改名:`CGEvent.getIntegerValue` → `getIntegerValueField`。
