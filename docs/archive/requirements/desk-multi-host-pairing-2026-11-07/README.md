# 桌面设备在家/公司多台 Mac 间来回带

## 目标

用户经常把 yahadesk 在家和公司之间来回带。带回公司后 Mac App 显示离线，面板没有可点的连接按钮，设备用不了。

## 根因

- Mac 日志 2026-11-07 10:59:01：`Peer removed pairing information`；设备串口只在广播。
- 固件沿用 NimBLE 默认 `MAX_BONDS=3`、`MAX_CCCDS=8`。每台 Mac 订阅 audio/status/cloud 加 Service Changed 共 4 个 CCCD，iPhone 订阅 cloud/status；两台 Mac 加 iPhone 超过 8 个，`ble_store_util_status_rr` 调 `ble_gap_unpair_oldest_except` 删掉最早配对的那台 Mac 的 bond。Mac 仍留着密钥，系统层面反复连接失败。
- macOS CoreBluetooth 不能由 App 删除系统配对，只能用户在系统设置里「忽略此设备」。

## 改动

- 固件 `sdkconfig.defaults`：`CONFIG_BT_NIMBLE_MAX_BONDS=8`、`CONFIG_BT_NIMBLE_MAX_CCCDS=32`。不改分区、不改协议、不改版本号。
- Mac：链路状态新增 `pairingLost`（`CBError.peerRemovedPairingInformation`，连接失败与断开回调都识别）；离线时面板显示「重新连接」，配对丢失时另有「打开蓝牙设置」和移除配对的提示；「暂时断开」按钮离线时也保留，便于让出唯一连接给 iPhone。

## 边界

- 不擦除 NVS，旧 bond 在新上限下照常加载（恢复按 1..max 下标遍历）。
- 已经被旧固件删掉配对的 Mac，需要用户手动在系统蓝牙设置里忽略 yahadesk 后重新配对一次。
- NVS 容量按代码估算：满 8 bond + 32 CCCD 约 180 条（约 5.6 KB），0x6000 分区可用约 630 条；未在设备上测满。

## 验证

- `idf.py build`（ESP-IDF 6.1）通过，生成的 `sdkconfig.h` 为 8/32；DIRAM 36.7%，镜像 3,985,767 字节（4 MB 分区）。
- `swift build`、`swift test` 通过：76 个测试，含新增 `lostPairingTellsUserToRemoveDeviceInSystemSettings`。
- 独立上下文审查：根因与容量结论成立；发现「离线隐藏暂时断开」回归与断开回调漏识别，已修复。

## 烧录记录

- 2026-11-07 用户授权烧录。写入设备 `yahadesk-XXXX` 的 bootloader、分区表与应用，SHA 校验通过；未擦除 NVS，未写 `fac`。
- 启动日志：固件 0.3.0、以 `yahadesk-XXXX` 广播、无错误或重启。`wifi down reason 201` 为公司无已存 Wi-Fi，与本次无关。

## 本机安装

- 2026-11-07 11:28 用 `scripts/make-app.sh --install` 本机打包（Apple Development 签名）并替换 `/Applications/YahaDesk.app`，未发布。11:29:12 新版日志识别到 `Peer removed pairing information`，面板进入配对丢失提示。
- 用户在系统设置里忽略 yahadesk 并重新配对后，11:42:43 日志 `yahadesk-XXXX 上线(蓝牙已加密)`，`status` 为 `connected: true`、RSSI -36 dBm、静音待命，溢出/欠载/丢帧为 0。

## 未验证

- 回家后家里 Mac 重新配对一次、之后两地来回带不再掉配对：待真机确认。
