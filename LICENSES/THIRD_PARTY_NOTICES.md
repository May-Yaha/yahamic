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

## 硬件:乐鑫 ESP32-S3 芯片 + 微雪开发板

- 芯片:乐鑫(Espressif)ESP32-S3R8,固件只面向乐鑫芯片构建。
- 开发板:微雪(Waveshare)ESP32-S3-Touch-AMOLED-2.16,板载 CO5300 AMOLED、CST9220 触摸、
  ES7210 麦克风阵列 ADC 与 AXP2101 电源管理。原理图与板卡资料:
  <https://www.waveshare.com/ESP32-S3-Touch-AMOLED-2.16>
- 本项目与乐鑫、微雪无隶属关系;「ESP32」「ESP-IDF」是乐鑫的商标。

## ESP-IDF 与乐鑫组件

固件基于 ESP-IDF 6.1(Apache-2.0,<https://github.com/espressif/esp-idf>),并经 ESP Component
Registry 拉取以下组件(`firmware/main/idf_component.yml`,源码不入库,构建时下载到
`firmware/managed_components/`,各组件许可证随源码一起下载):

| 组件 | 版本 | 许可证 |
|---|---|---|
| espressif/esp_audio_codec | 2.5.0 | **乐鑫修改版 MIT**(见下) |
| espressif/esp_codec_dev | 1.6.2 | Apache-2.0 |
| espressif/esp_lcd_co5300 | 2.2.0 | Apache-2.0 |
| espressif/esp_lcd_touch / esp_lcd_touch_cst9220 | 1.2.1 / 0.1.1 | Apache-2.0 |
| espressif/esp_lvgl_port | 2.6.3 | Apache-2.0 |
| espressif/mqtt | 1.1.0 | Apache-2.0 |
| espressif/cmake_utilities | 0.5.3 | Apache-2.0 |
| espressif/cjson(cJSON) | 1.7.19 | MIT |

**esp_audio_codec(Opus 编码)用的是 Espressif Modified MIT License:只允许与乐鑫芯片一起使用,
禁止为非乐鑫产品再分发。** 本项目固件只跑在 ESP32-S3 上,Mac App 内带的固件二进制
(`Resources/Firmware/`)同样只用于烧录乐鑫芯片。若要把固件移植到其他厂商的芯片,须换掉该组件。

## LVGL(MIT)

来源:<https://github.com/lvgl/lvgl>,版本 9.2.2,Copyright (c) 2021 LVGL Kft。设备屏幕 UI 框架。

## Noto Sans CJK SC(SIL OFL 1.1)

`firmware/main/generated/fonts/*.c` 由 Noto Sans CJK SC Medium 经 lv_font_conv 子集化生成。
Copyright 2014-2021 Adobe,保留字体名「Source」;许可证全文见 `firmware/tools/fonts/OFL.txt`。

## BlackHole(GPL-3.0)

Mac App 的「一键安装」从 Existential Audio 官方发布地址下载并校验 BlackHole 2ch 安装包,
不随 App 打包:<https://github.com/ExistentialAudio/BlackHole>。

## FluidAudio / LocalVQE(Apache-2.0)

来源:<https://github.com/FluidInference/FluidAudio>

Mac App 使用 FluidAudio 0.17.7 提取本地声纹向量，并在离线诊断中调用
LocalVQE 做降噪/混响抑制 A/B 对比。完整
Apache-2.0 许可证随 App 打包为 `FluidAudio-LICENSE.txt`。

## TypeWhisper(GPLv3)

来源:<https://github.com/TypeWhisper/typewhisper-mac>，参考版本 `v1.8.2`。

本地语音输入的 Qwen3 选型、固定依赖版本、推理参数与后续设置页信息架构参考
TypeWhisper。Yaha Desk 不嵌入 TypeWhisper App、插件宿主或第二套热键监听器。

## MLX Audio Swift / MLX Swift(MIT)

- MLX Audio Swift:<https://github.com/TypeWhisper/mlx-audio-swift>，固定提交
  `1fb13b441c1ad8aae4a23f6a2223e03e5e5b1738`。
- MLX Swift:<https://github.com/ml-explore/mlx-swift>，固定版本 `0.31.6`。

Mac App 使用这些组件在 Apple Silicon 上运行 Qwen3-ASR。各依赖的完整许可证会从
Swift Package checkout 自动复制到 App 的 `Resources/Licenses/`。

## Swift Hugging Face / Swift Transformers(Apache-2.0)

模型下载与 tokenizer 由 Hugging Face 的 Swift 包提供；完整许可证随 App 打包到
`Resources/Licenses/`。

## Qwen3-ASR 0.6B 6-bit(模型许可)

模型来源:<https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-6bit>，下载固定到提交
`468b9b6d692d3397d5d17b84a1166876a00c9bfa`。模型按需下载，不随 App 安装包分发；
使用、复制或再分发时须保留上游模型卡、归属与许可证信息。
