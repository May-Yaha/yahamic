# 手机当麦克风

让 iPhone 代替设备采集声音，沿用 Mac 讲话键控制：按住讲话键时手机开始采集并经 BLE 回传 Opus，松开即停，锁屏也能用。

## 可行性结论（2026-11-11）

验证工程与原始数据见 [test/phone-mic-ptt](../../../test/phone-mic-ptt/README.md)。

- PushToTalk 框架在锁屏下可由 BLE 讲话键触发 `requestBeginTransmitting`，两条路线锁屏 10 轮无一被拒，首包约 930–1090 ms。
- 选路线 A：手机模拟 yahadesk 外设，Mac 沿用现有 `Uplink` 写 control，不新增中心角色。
- 首包大头是 `AVAudioEngine.start()`（约 800 ms），实现时在加入频道时先 `prepare()` 预热再复测。

## 实现要点（待做）

- 手机外设实现 yahadesk 协议的音频、静音、info 特征；info 不带 `cloud 1`，Mac 不对它走配网与设备授权。
- 加入频道只能在前台由用户操作；断链或取消订阅时调 `stopTransmitting`。
- Mac 增加「声源：设备 / 手机」选择；DeskProtocol 补手机端编码到 Mac 解码的往返测试。
- 待人工确认：按下/松开的系统提示音与锁屏卡片表现。
