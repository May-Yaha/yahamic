#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>

#include "driver/i2c_master.h"

// 麦克风采集(xiaozhi-esp32 的做法):ES7210 采集 16 kHz 单声道,**Opus 编码**
// (32 kbps、60 ms 帧),带宽从裸 PCM 256 kbps 降到 32 kbps。频谱(FFT)在编码前
// 对原始 PCM 做。静音是真静音:关掉 codec,一比特不出设备。
namespace audio {

// sink 收到的是编码后的 Opus 数据(约 50-200 字节)+ 设备时戳(ms)。
using Sink = std::function<void(const uint8_t* opus, size_t size, uint32_t ts_ms, float level)>;

// codec 在 I2C 上初始化;sink 在采集线程里被调用(opus 指向内部缓冲,返回即失效)。
bool init(i2c_master_bus_handle_t bus);
void set_sink(Sink sink);

void start();          // 开始采集(静音状态下只是待命)
void set_muted(bool);  // 硬件静音开关(下降沿触发约 240ms 线性淡出再关 codec)
float level();         // 最近一帧的响度 0..1(遥测日志用;屏幕电平由波形振幅表现)

// 实时频谱(给屏幕的律动图):32 柱,对数频带 50 Hz..8 kHz,0..1。
// 采集线程里对 1024 样本滑窗做 FFT,每个 60 ms 音频帧更新一次;静音时清零。
bool spectrum(float* bars, int count);

// 采集帧间隔遥测(理想 60 ms 一帧,即 Opus 帧长):压测用,读完即清零。
bool capture_stats(int32_t& avg_ms, int32_t& min_ms, int32_t& max_ms);

// 自检(CONFIG_YAHAMIC_SELFTEST):采 1 秒,打印 RMS 与削波比例。
#if CONFIG_YAHAMIC_SELFTEST
void self_test();
#endif

}  // namespace audio
