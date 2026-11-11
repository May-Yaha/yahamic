# 手机当麦克风:PushToTalk 后台触发验证

只回答一个问题:手机锁屏后,Mac 讲话键经 BLE 能否触发 `requestBeginTransmitting` 并开始采集;同时量出从按下到收到首包的时延。
只回传电平(每个采集缓冲一包),不传真实音频,不碰 Yaha Desk 与固件。服务 UUID 用 `9053xxxx`,与设备的 `9052xxxx` 不冲突。

| 路线 | 手机角色 | 讲话键到手机的形式 |
| --- | --- | --- |
| A | 外设 | Mac 写 `talk` 特征(`didReceiveWrite`) |
| B | 中心 | Mac notify `talk` 特征(`didUpdateValueFor`,与苹果文档举的配件按键例子一致) |

## 结论(2026-11-11,YahaDuo iPhone19,4,iOS 26,锁屏)

两条路线锁屏都能稳定触发,后台方案成立;正式实现选 **A**(手机模拟 yahadesk 外设,Mac 沿用现有 Uplink 写 control)。

| 路线 | 前台首包 ms | 锁屏首包 ms | 锁屏被拒 | 每 3 秒包数 |
| --- | --- | --- | --- | --- |
| A | 未单独测(B 跑完手机已锁屏) | 941–963(有效 4/4) | 0 次 | 22–23 |
| B | 938–1139 | 932–1088(6/6) | 0 次 | 21–23 |

A 的第一轮无效:切换路线时 B 的 Mac 端在按住期间被杀,手机一直在发,这一轮收到 64 个残留包,首包 +83 ms 不计。

手机侧分段(两路相近):讲话键到「开始发送」8–21 ms,到「音频会话激活」100–180 ms,到首个采集缓冲约 900 ms。
大头在 `didActivate` 之后的 `AVAudioEngine.start()`(约 800 ms),正式实现在加入频道时先 `engine.prepare()` 预热,再复测。
系统提示音与锁屏卡片待人工确认。

## 踩过的坑

- **Mac 端必须是 .app。** 裸命令行程序用 CoreBluetooth 会被 TCC 以 SIGABRT(退出码 134)杀掉,崩溃报告提示缺
  `NSBluetoothAlwaysUsageDescription`;用 `-sectcreate` 把 Info.plist 嵌进二进制也不行。`run-mac-rig.sh` 负责包成 .app 再 `open`。
- **没加入频道,讲话键无效。** 手机日志出现「收到 1,但未加入频道」时,先在前台点「加入频道」;加入只能在前台由用户操作。
- **断链要主动停止发送。** 按住期间杀掉 Mac 端,手机会一直发送(这次多收到 64 个包)。正式实现在断开或取消订阅时调 `stopTransmitting`。
- **一次只跑一条路线。** 切路线前先 `pkill -f PTTSpike.app`,否则上一条路线的残留会污染首轮数据。

## 准备(需账号持有人操作)

1. 开发者账号接受最新协议;Xcode 里给 `com.yaha.desk.pttspike` 开 Push to Talk、Push Notifications 能力(首次真机构建时 Xcode 可代为注册)。
2. `cd test/phone-mic-ptt/ios && xcodegen generate && open PhoneMicPTT.xcodeproj`,选真机运行。

## 步骤

每条路线单独跑(`./run-mac-rig.sh a`,结束后 `pkill -f PTTSpike.app`,再 `./run-mac-rig.sh b`),日志在 `/tmp/ptt-spike-<路线>.log`:

1. 手机 App 前台点「加入频道」,允许麦克风与蓝牙;等 Mac 打印「链路就绪」。
2. 前台先看两轮:Mac 应打印「首包 +N ms,手机前台」。
3. 锁屏,再看至少三轮:是否仍出现「首包 …手机后台」。
4. 结束后解锁手机看日志:后台时有没有「开始发送被拒」,以及「音频会话激活」「首个采集缓冲」各距讲话键多少毫秒。同时留意按下/松开时有没有系统提示音。

判读:锁屏能稳定出首包的路线才可用;都被拒则后台方案不成立,回到「前台 + 禁止自动锁屏」。
