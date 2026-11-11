# 手机当麦克风

让 iPhone 代替设备采集声音，沿用 Mac 讲话键控制：按住讲话键时手机开始采集并经 BLE 回传 Opus，松开即停，锁屏也能用。

## 可行性结论（2026-11-11）

验证工程与原始数据见 [test/phone-mic-ptt](../../../test/phone-mic-ptt/README.md)。

- PushToTalk 框架在锁屏下可由 BLE 讲话键触发 `requestBeginTransmitting`，两条路线锁屏 10 轮无一被拒，首包约 930–1090 ms。
- 选路线 A：手机模拟 yahadesk 外设，Mac 沿用现有 `Uplink` 写 control，不新增中心角色。
- 首包大头是 `AVAudioEngine.start()`（约 800 ms），实现时在加入频道时先 `prepare()` 预热再复测。

## 实现（2026-11-11）

- iPhone `apps/ios/Sources/PhoneMic.swift`：首页「手机当麦克风」加入 PushToTalk 频道后，以 `Wire.phoneService`（`9052000C-…`）广播，只挂 info/audio/status/control，均要求加密。info 不带 `cloud 1`，Mac 不对它走配网与设备授权。
- 采集按 PushToTalk 的 `didActivate` 开始，重采样到 16 kHz 单声道，系统 Opus 编码器 60 ms/32 kbps 一帧，按固件同样的分片 notify；发送队列超过约 1 秒整帧丢弃，Mac 按 seq 跳号计丢帧。加入频道时 `engine.prepare()` 预热。
- Mac 取消订阅或断链时手机调 `stopTransmitting`。
- Mac 麦克风模块里「设备 / 手机」分段开关一键切声源，切换即重建链路；两种声源分别记住上次连接的外设。声源不持久化，启动先连设备。
- 自动跟随：第一次在 Mac 上点到“手机”完成配对后，Mac 连着设备时也扫描 `phoneService`，只认那台 iPhone；它开始广播就切到手机，Mac 断链（手机点停止或走远）就切回设备。手机还开着时在 Mac 上切回设备，这次不再自动接管，等手机停了再恢复。
- iPhone 首页顶部「设备 / 手机」分段（和 Mac 同构，选择跨启动保留）：选「手机」即加入频道，整页只剩手机麦克风状态（讲话中绿、Mac 已连接蓝、等待 Mac 灰）、AI 总结与百度网盘，不显示设备状态、远程控制和 Zhi.AI，没有设备的用户也能直接用；选「设备」即离开频道，回到设备云端状态页。系统恢复频道时自动切到「手机」。
- 测试：`Wire.fragments` 与 `FrameAssembler` 往返（含 seq 回绕、最小 MTU、超过 128 片）；iOS 48 kHz 采集缓冲编码出 60 ms 帧。另用本机 libopus 验证过系统编码器产出的包可直接解码。

## 待真机确认

- 锁屏首包时延（预热后目标明显低于验证时的约 950 ms）、连续讲话的丢帧与音质。
- 按下/松开的系统提示音与锁屏卡片表现。
