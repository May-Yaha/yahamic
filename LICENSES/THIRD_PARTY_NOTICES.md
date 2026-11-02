# 第三方组件与致谢

yahamic 的工程结构与板级支持站在 OpenCharm 与 xiaozhi-esp32 的肩膀上。

## OpenCharm(MIT)

来源:<https://github.com/opencharm-labs/opencharm>

- `firmware/main/board.cpp` 的引脚定义与 CO5300 初始化序列(源自 Waveshare 原理图,
  经 OpenCharm / xiaozhi-esp32 验证)
- `firmware/main/audio.cpp` 的 ES7210/I2S 总线配置(裁剪:去掉 ES8311、AEC、Opus)
- `firmware/main/power.cpp` 的 AXP2101 寄存器操作(裁剪,并显式开启 ALDO1)
- `firmware/sdkconfig.defaults`、`partitions.csv`、CMake 骨架

## ESP-IDF NimBLE 示例 bleprph(Apache-2.0)

`firmware/main/uplink.cpp` 的 NimBLE 外设结构(GAP 事件处理、bond 与 repeat pairing、
host 任务)参照 ESP-IDF `examples/bluetooth/nimble/bleprph`,代码为重写。

## xiaozhi-esp32(MIT)

来源:<https://github.com/78/xiaozhi-esp32>

音频编解码器配置(ES8311/ES7210、增益、I2S)的参考实现,
通过 OpenCharm 的文档与代码间接引用。

## Waveshare

硬件原理图与板卡资料:<https://www.waveshare.com/ESP32-S3-Touch-AMOLED-2.16>
(固件与 Waveshare、Espressif 无隶属关系)
