# 第三方组件与致谢

yahamic 的工程结构、板级支持与网络策略站在 OpenCharm 与 xiaozhi-esp32 的肩膀上。

## OpenCharm(MIT)

来源:<https://github.com/opencharm-labs/opencharm>

- `firmware/components/esp-wifi-connect/`(整目录拷贝,含其 `OpenCharm:` 标记的一处
  修复;仅 `assets/` 下两个配网页面替换为 Yahamic 自己的中文页面)
- `firmware/main/board.cpp` 的引脚定义与 CO5300 初始化序列(源自 Waveshare 原理图,
  经 OpenCharm / xiaozhi-esp32 验证)
- `firmware/main/audio.cpp` 的 ES7210/I2S 总线配置(裁剪:去掉 ES8311、AEC、Opus)
- `firmware/main/power.cpp` 的 AXP2101 寄存器操作(裁剪,并显式开启 ALDO1)
- `firmware/main/link.cpp` 的 mDNS 发现与 Wi-Fi 状态机模式(重写为 UDP 协议)
- `firmware/sdkconfig.defaults`、`partitions.csv`、CMake 骨架

## 78/esp-wifi-connect 3.3.1(MIT,Copyright (c) 2024 Terrence)

来源:<https://github.com/78/esp-wifi-connect>(经 OpenCharm 的副本,见上)

## xiaozhi-esp32(MIT)

来源:<https://github.com/78/xiaozhi-esp32>

音频编解码器配置(ES8311/ES7210、增益、I2S)与 Wi-Fi 缓冲调优的参考实现,
通过 OpenCharm 的文档与代码间接引用。

## Waveshare

硬件原理图与板卡资料:<https://www.waveshare.com/ESP32-S3-Touch-AMOLED-2.16>
(固件与 Waveshare、Espressif 无隶属关系)
