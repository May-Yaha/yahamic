# 桌面设备连上公司 Wi-Fi 后蓝牙音频卡顿

## 目标与授权

用户反馈讲话卡顿、断续、听写重复、背景人声与噪声被识别，要求整体压测，再判断是否需要在 Mac 上加本人声纹过滤和降噪。用户于 2026-11-07 授权改固件并烧录 `yahadesk-XXXX`。

## 根因

ESP32-S3 的 Wi-Fi 与 BLE 共用一个 2.4 GHz 射频，按时分共存。2026-11-06 为排查听写重复加的 `esp_wifi_set_ps(WIFI_PS_NONE)`（[候选修复](../desk-voice-repeat-2026-11-06/README.md)）让 Wi-Fi 一直占着射频。在家里的 AP 上看不出问题，公司 AP（<家庭 Wi-Fi>，信道 11，HT40）繁忙时 BLE 音频拿不到空口。

同一间办公室、BLE RSSI -41 到 -48 dBm 的对照：

| 设备 Wi-Fi | 压测 | 结果 |
| --- | --- | --- |
| 未连上 | 60 s | 997/997 帧，丢帧 0，欠载 0 |
| 已连上，`PS_NONE` | 30 s | 只收到 27 帧（应约 500），设备侧跳号 198，欠载 6 |
| 已连上，`PS_NONE` | 用户讲话 45 s | 只到 1.2 s 音频 |

卡顿、断续和听写重复都由丢帧引起；链路不修，声纹与降噪评估没有意义。

## 改动

- `cloud.cpp` 删掉 `esp_wifi_set_ps(WIFI_PS_NONE)`，回到 ESP-IDF 默认 `WIFI_PS_MIN_MODEM`：AP 替设备缓存下行，空出射频给 BLE。
- `wifi_audio_latency_test.py` 改为断言不再强制 `PS_NONE`；用旧 `cloud.cpp` 回放时失败。
- 不改协议、分区、NVS 与版本号。

## 验证

- 主机测试：新代码通过，旧代码失败（`FAIL: WIFI_PS_NONE is not forced`）。
- `idf.py build`（ESP-IDF 6.1）通过，DIRAM 36.7%。
- 烧录：bootloader、分区表、应用 SHA 校验通过，未擦 NVS；重启后未重新配对即重连 Mac。
- 启动日志：`wifi:connected with <家庭 Wi-Fi> … channel 11, 40D`，`wifi:pm start, type: 1`。
- Wi-Fi 已连上时压测：
  - 30 s：接收/解码/入队 500 帧，跳号 0，欠载 0，溢出 0，缓冲最低 115.6 ms、P50 169.2 ms。
  - 120 s：2000/2000 帧，跳号 0，欠载 0，溢出 0，缓冲最低 97.2 ms、P50 173.0 ms。

## 声纹与降噪判断

120 s 办公室静默采集（没人对设备讲话）：底噪 -62.3 dBFS；13% 的帧高于底噪 15 dB，中位 -41.6 dBFS、基频约 105 Hz，是周围同事说话漏进来的。该段只能说明背景人声的电平，判断本人声纹和是否需要过滤还缺一段本人近场讲话。

下一步：用户对设备正常讲话 30 s，测本人语音电平与背景人声的差值。差值够大（约 20 dB 以上）时，先用电平门限或 LocalVQE 近场复测；差值小再按[声纹档案](../desk-audio-quality-personal-voice-2026-11-07/README.md) P2 做本人声纹过滤。

## 未验证

- 豆包听写是否不再重复：需用户实际使用确认。
- 功耗：默认省电模式比 `PS_NONE` 省电，未实测。
- Wi-Fi 下行延迟：讲话期间固件本就暂停联网，未见影响；未单独测量。

## 回滚

恢复 `esp_wifi_set_ps(WIFI_PS_NONE)` 并重新烧录。
