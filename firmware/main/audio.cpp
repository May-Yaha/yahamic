#include "audio.h"

#include <atomic>
#include <cmath>
#include <cstring>
#include <mutex>

#include "driver/i2s_tdm.h"
#include "esp_codec_dev.h"
#include "esp_codec_dev_defaults.h"
#include "esp_log.h"
#include "esp_opus_enc.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

namespace audio {
namespace {

constexpr const char* kTag = "audio";

// 引脚与总线配置同 OpenCharm(Waveshare 原理图):ES7210 挂在 I2S0 的 TDM RX 上。
constexpr gpio_num_t kMclk = GPIO_NUM_42;
constexpr gpio_num_t kBclk = GPIO_NUM_9;
constexpr gpio_num_t kWs = GPIO_NUM_45;
constexpr gpio_num_t kDin = GPIO_NUM_10;

constexpr int kRate = 16000;       // 采集、传输全程 16 kHz
constexpr int kFrameSamples = 960; // 60 ms 一帧(同 xiaozhi),Opus 帧长
constexpr float kMicGainDb = 30.0f; // 与 xiaozhi-esp32 在此板上相同
constexpr int kFftN = 1024;         // 频谱窗:1024 样本(64 ms),512 个 bin,≥帧长
constexpr int kBars = 32;           // 屏幕频谱柱数(粗条,播放器量级)

esp_codec_dev_handle_t mics = nullptr;
void* opus_encoder = nullptr;      // Opus 编码器(xiaozhi 同款)
uint8_t opus_out[512];             // 编码输出缓冲(32kbps 60ms 最大 ~400B)
TaskHandle_t task = nullptr;
Sink sink;                        // 只在采集线程里调用
std::atomic<bool> running{false};
std::atomic<bool> muted_{false};  // 硬件静音状态:set_muted 写,capture_loop 读
// 静音淡出:话尾骤停是阶跃咔哒,听写分段器遇咔哒会把上一句整段重发一遍
// (Mac 端 AudioSink nextSample 注释实证过该机制,即用户看到的"听写文字出现
// 两遍"),渐弱收尾远比硬切友好。帧长 60ms,3 帧衰减台阶(共 240ms,整数帧
// 里最接近设计目标 ≈140ms 的取值),末帧增益恰为 0 = 干净的数字零再关 codec。
constexpr int kMuteFadeFrames = 3;
std::atomic<int> fade_left{0};  // 剩余淡出帧计数:set_muted(true) 下降沿置 kMuteFadeFrames+1
std::atomic<float> last_level{0};

// 频谱(采集线程写,主循环读):滑窗 + Hann 窗 + 手写基-2 FFT,不引 esp-dsp。
std::mutex bars_lock;
float bars[kBars] = {0};
int16_t window[kFftN] = {0};

// 与 OpenCharm 的 create_bus 相同的总线,只是不开 TX(ES8311/扬声器整体不碰)。
void create_bus(i2s_chan_handle_t& rx) {
  i2s_chan_config_t chan = {};
  chan.id = I2S_NUM_0;
  chan.role = I2S_ROLE_MASTER;
  chan.dma_desc_num = 6;
  chan.dma_frame_num = 240;
  ESP_ERROR_CHECK(i2s_new_channel(&chan, nullptr, &rx));

  i2s_tdm_config_t tdm = {};
  tdm.clk_cfg.sample_rate_hz = kRate;
  tdm.clk_cfg.clk_src = I2S_CLK_SRC_DEFAULT;
  tdm.clk_cfg.mclk_multiple = I2S_MCLK_MULTIPLE_256;
  tdm.clk_cfg.bclk_div = 8;
  tdm.slot_cfg = I2S_TDM_PHILIPS_SLOT_DEFAULT_CONFIG(
      I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_STEREO,
      i2s_tdm_slot_mask_t(I2S_TDM_SLOT0 | I2S_TDM_SLOT1 | I2S_TDM_SLOT2 | I2S_TDM_SLOT3));
  tdm.gpio_cfg.mclk = kMclk;
  tdm.gpio_cfg.bclk = kBclk;
  tdm.gpio_cfg.ws = kWs;
  tdm.gpio_cfg.dout = I2S_GPIO_UNUSED;
  tdm.gpio_cfg.din = kDin;
  ESP_ERROR_CHECK(i2s_channel_init_tdm_mode(rx, &tdm));
  ESP_ERROR_CHECK(i2s_channel_enable(rx));
}

bool create_codec(i2c_master_bus_handle_t bus) {
  i2s_chan_handle_t rx = nullptr;
  create_bus(rx);
  audio_codec_i2s_cfg_t i2s = {};
  i2s.port = I2S_NUM_0;
  i2s.rx_handle = rx;
  const audio_codec_data_if_t* data = audio_codec_new_i2s_data(&i2s);

  audio_codec_i2c_cfg_t i2c = {};
  i2c.port = I2C_NUM_0;
  i2c.addr = ES7210_CODEC_DEFAULT_ADDR;
  i2c.bus_handle = bus;
  const audio_codec_ctrl_if_t* ctrl = audio_codec_new_i2c_ctrl(&i2c);
  es7210_codec_cfg_t es7210 = {};
  es7210.ctrl_if = ctrl;
  es7210.mic_selected = ES7210_SEL_MIC1 | ES7210_SEL_MIC2 | ES7210_SEL_MIC3 | ES7210_SEL_MIC4;
  esp_codec_dev_cfg_t dev = {};
  dev.dev_type = ESP_CODEC_DEV_TYPE_IN;
  dev.codec_if = es7210_codec_new(&es7210);
  dev.data_if = data;
  mics = esp_codec_dev_new(&dev);
  return mics != nullptr;
}

// 遥测:采集帧间隔(理想 60ms,即 Opus 帧长)。看 max/p95 与理想值的偏离 = 收音链路抖动。
std::atomic<int32_t> cap_min_ms{999};
std::atomic<int32_t> cap_max_ms{0};
std::atomic<int32_t> cap_sum_ms{0};
std::atomic<int32_t> cap_count{0};
int64_t capture_last_read_us = 0;  // 采集遥测的上一帧时刻(静音重开后重置)

bool open_mic() {
  // 四槽 TDM,只取第 0 槽(板上主麦克风):读多少、得多少,交错的只有这一路。
  esp_codec_dev_sample_info_t fs = {};
  fs.bits_per_sample = 16;
  fs.channel = 4;
  fs.channel_mask = ESP_CODEC_DEV_MAKE_CHANNEL_MASK(0);
  fs.sample_rate = kRate;
  if (esp_codec_dev_open(mics, &fs) != ESP_CODEC_DEV_OK) return false;
  esp_codec_dev_set_in_channel_gain(mics, ESP_CODEC_DEV_MAKE_CHANNEL_MASK(0), kMicGainDb);
  return true;
}

float rms(const int16_t* pcm, int n) {
  double sum = 0;
  for (int i = 0; i < n; ++i) sum += double(pcm[i]) * pcm[i];
  return n > 0 ? float(std::sqrt(sum / n)) : 0;
}

// —— 频谱(采集线程)——
// 就地基-2 FFT(迭代、位反转、每级旋转因子递推;显示用途,精度足够)。
void fft(float* re, float* im, int n) {
  for (int i = 1, j = 0; i < n; ++i) {
    int bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) {
      float t = re[i]; re[i] = re[j]; re[j] = t;
      t = im[i]; im[i] = im[j]; im[j] = t;
    }
  }
  for (int len = 2; len <= n; len <<= 1) {
    float ang = -2.0f * float(M_PI) / float(len);
    float wr = std::cos(ang), wi = std::sin(ang);
    for (int i = 0; i < n; i += len) {
      float cr = 1, ci = 0;
      for (int k = 0; k < len / 2; ++k) {
        float xr = re[i + k + len / 2] * cr - im[i + k + len / 2] * ci;
        float xi = re[i + k + len / 2] * ci + im[i + k + len / 2] * cr;
        re[i + k + len / 2] = re[i + k] - xr;
        im[i + k + len / 2] = im[i + k] - xi;
        re[i + k] += xr;
        im[i + k] += xi;
        float ncr = cr * wr - ci * wi;
        ci = cr * wi + ci * wr;
        cr = ncr;
      }
    }
  }
}

// 1024 样本滑窗(kFftN,64 ms,≥ 一帧)→ Hann → FFT → 512 bin 的能量,按
// 对数频带聚成 32 柱(kBars)。频带从 50 Hz 到 8 kHz(160 倍),每柱取频带内
// 最大值,显示更有颗粒感。跟着每个 60 ms 音频帧更新(≈ 16.7 Hz),渲染侧
// (board)再在帧间对频带与重心做平滑。
void update_spectrum() {
  static float re[kFftN], im[kFftN], hann[kFftN];
  static bool hann_ready = false;
  if (!hann_ready) {
    for (int i = 0; i < kFftN; ++i) hann[i] = 0.5f * (1 - std::cos(2 * float(M_PI) * i / (kFftN - 1)));
    hann_ready = true;
  }
  for (int i = 0; i < kFftN; ++i) {
    re[i] = float(window[i]) * hann[i];
    im[i] = 0;
  }
  fft(re, im, kFftN);
  float power[kFftN / 2];
  for (int i = 1; i < kFftN / 2; ++i) power[i] = re[i] * re[i] + im[i] * im[i];
  const float hz_per_bin = float(kRate) / float(kFftN);
  const float lo = 50.0f, hi = 8000.0f;
  float next[kBars];
  for (int b = 0; b < kBars; ++b) {
    float f0 = lo * std::pow(hi / lo, float(b) / kBars);
    float f1 = lo * std::pow(hi / lo, float(b + 1) / kBars);
    int i0 = std::max(1, int(f0 / hz_per_bin));
    int i1 = std::max(i0 + 1, int(f1 / hz_per_bin) + 1);
    float peak = 0;
    for (int i = i0; i < i1 && i < kFftN / 2; ++i) peak = std::max(peak, power[i]);
    // 能量 → dB → 归一化:-72..-12 dB 映射到 0..1。
    float db = 10.0f * std::log10(peak / float(1 << 26) + 1e-12f);
    float v = (db + 72.0f) / 60.0f;
    next[b] = std::fmin(1.0f, std::fmax(0.0f, v));
  }
  std::lock_guard<std::mutex> guard(bars_lock);
  memcpy(bars, next, sizeof bars);
}

// 采集线程:未静音时持续读 60 ms 帧并交给 sink;静音先走淡出帧再关 codec。
void capture_loop(void*) {
  int16_t frame[kFrameSamples];
  bool open = false;
  for (;;) {
    if (!running) {
      vTaskDelay(pdMS_TO_TICKS(50));
      continue;
    }
    // 淡出窗口:静音但还有淡出帧时保持开麦,把话尾渐弱送完(缩放见 read 后)。
    const bool fading = muted_.load() && open && fade_left.load() > 0;
    if (muted_ && open && !fading) {
      esp_codec_dev_close(mics);
      open = false;
      capture_last_read_us = 0;  // 遥测别把静音期的跨度算进采集间隔
    }
    if ((muted_ && !fading) || (!open && !open_mic())) {
      if (!muted_) vTaskDelay(pdMS_TO_TICKS(50));  // 打不开别空转
      else vTaskDelay(pdMS_TO_TICKS(20));
      continue;
    }
    open = true;
    // (遥测基准 last_read_us 在命名空间层,静音关码时会清零)
    if (esp_codec_dev_read(mics, frame, sizeof frame) == ESP_CODEC_DEV_OK) {
      int64_t now = esp_timer_get_time();
      uint32_t ts_ms = uint32_t(now / 1000);
      if (capture_last_read_us) {
        int32_t ms = int32_t((now - capture_last_read_us) / 1000);
        if (ms < cap_min_ms.load()) cap_min_ms.store(ms);
        if (ms > cap_max_ms.load()) cap_max_ms.store(ms);
        cap_sum_ms.fetch_add(ms);
        cap_count.fetch_add(1);
      }
      capture_last_read_us = now;
      // 静音淡出(why 见 fade_left 定义处):每帧按 left/kMuteFadeFrames 线性衰减,
      // left 从 kMuteFadeFrames 走到 0(首帧满幅、末帧数字零),缩放后的样本照常
      // 走电平/频谱/Opus 上行,让 Mac 端收到完整渐弱的尾巴;末帧发完下一圈关 codec。
      if (muted_.load()) {
        int left = fade_left.fetch_sub(1) - 1;
        if (left < 0) { left = 0; fade_left.store(0); }
        const int32_t gain = int32_t(left) * 32768 / kMuteFadeFrames;
        for (int i = 0; i < kFrameSamples; ++i)
          frame[i] = int16_t((int32_t(frame[i]) * gain + 16384) >> 15);
      }
      // 语音响度大约落在 0.3..0.8(刻度同 OpenCharm 的脸部动画)。
      float level = std::fmin(1.0f, rms(frame, kFrameSamples) / 4000.0f);
      last_level.store(level);
      // 滑窗前移一帧再追加,频谱跟着音频帧更新(60 ms 一帧 ≈ 16.7 Hz);
      // 屏幕波形的 24-30 fps 目标(实测 24.3-24.8)由主循环渲染节奏决定,与采集帧率解耦,
      // 帧间平滑/重心/相位连续动力学在 board 侧,60 ms 台阶在那里被抹平。
      memmove(window, window + kFrameSamples, (kFftN - kFrameSamples) * sizeof(int16_t));
      memcpy(window + kFftN - kFrameSamples, frame, kFrameSamples * sizeof(int16_t));
      update_spectrum();
      // Opus 编码后交 sink(带宽 256kbps→32kbps,时戳让 Mac 端正确排序)。
      if (opus_encoder && sink) {
        esp_audio_enc_in_frame_t enc_in = {};
        enc_in.buffer = reinterpret_cast<uint8_t*>(frame);
        enc_in.len = kFrameSamples * sizeof(int16_t);
        esp_audio_enc_out_frame_t enc_out = {};
        enc_out.buffer = opus_out;
        enc_out.len = sizeof opus_out;
        if (esp_opus_enc_process(opus_encoder, &enc_in, &enc_out) == ESP_AUDIO_ERR_OK &&
            enc_out.encoded_bytes > 0) {
          sink(opus_out, enc_out.encoded_bytes, ts_ms, level);
        }
      }
    } else {
      vTaskDelay(pdMS_TO_TICKS(5));  // 读失败绝不自旋
    }
  }
}

}  // namespace

bool init(i2c_master_bus_handle_t bus) {
  if (!create_codec(bus)) {
    ESP_LOGE(kTag, "ES7210 not found");
    return false;
  }
  // Opus 编码器(32 kbps、60 ms、VOIP 模式、复杂度 0 = 最低 CPU,xiaozhi 做法)。
  esp_opus_enc_config_t enc_cfg = ESP_OPUS_ENC_CONFIG_DEFAULT();
  enc_cfg.sample_rate = kRate;
  enc_cfg.channel = 1;
  enc_cfg.bitrate = 32000;
  enc_cfg.frame_duration = ESP_OPUS_ENC_FRAME_DURATION_60_MS;
  enc_cfg.application_mode = ESP_OPUS_ENC_APPLICATION_VOIP;
  enc_cfg.complexity = 0;
  if (esp_opus_enc_open(&enc_cfg, sizeof enc_cfg, &opus_encoder) != ESP_AUDIO_ERR_OK) {
    ESP_LOGE(kTag, "Opus encoder open failed");
    opus_encoder = nullptr;
    return false;
  }
  // 32 KB 内部栈:去掉 AEC 后内部 RAM 充裕;PSRAM 栈在 Core 1 上引发过
  // LoadProhibited(缓存一致性问题),内部栈无此忧。采集固定在 Core 1,与
  // 跑主循环/渲染的 Core 0 核隔离,互不抢时间片。
  if (xTaskCreatePinnedToCore(capture_loop, "yahamic_mic", 32768, nullptr, 6, &task, 1) != pdPASS) {
    ESP_LOGE(kTag, "capture task didn't start");
    return false;
  }
  ESP_LOGI(kTag, "ready: ES7210 + Opus 32kbps, 16 kHz mono, 60 ms frames");
  return true;
}

void set_sink(Sink s) { sink = std::move(s); }

void start() { running.store(true); }

void set_muted(bool on) {
  // exchange 取下降沿才启动淡出:重复静音不重置 fade_left,避免淡出中途增益
  // 被抬回满幅(听感凸包);开麦立即清零,不残留半截淡出窗口。
  const bool was = muted_.exchange(on);
  if (on) {
    if (!was) fade_left.store(kMuteFadeFrames + 1);  // +1 = 首个淡出帧仍满幅
    // 静音即无信号:清窗、清柱,屏幕上的频谱自然落零。
    memset(window, 0, sizeof window);
    std::lock_guard<std::mutex> guard(bars_lock);
    memset(bars, 0, sizeof bars);
  } else {
    fade_left.store(0);
  }
}

float level() { return last_level.load(); }

bool capture_stats(int32_t& avg_ms, int32_t& min_ms, int32_t& max_ms) {
  int32_t n = cap_count.load();
  if (!n) return false;
  avg_ms = cap_sum_ms.load() / n;
  min_ms = cap_min_ms.load();
  max_ms = cap_max_ms.load();
  cap_min_ms.store(999);
  cap_max_ms.store(0);
  cap_sum_ms.store(0);
  cap_count.store(0);
  return true;
}

bool spectrum(float* out, int count) {
  if (!out || count <= 0) return false;
  int n = count < kBars ? count : kBars;
  std::lock_guard<std::mutex> guard(bars_lock);
  memcpy(out, bars, size_t(n) * sizeof(float));
  return true;
}

#if CONFIG_YAHAMIC_SELFTEST
void self_test() {
  if (!mics) {
    ESP_LOGE(kTag, "self-test skipped: no codec");
    return;
  }
  if (!open_mic()) {
    ESP_LOGE(kTag, "self-test: mic didn't open");
    return;
  }
  double sum = 0;
  int frames = 0, clipped = 0;
  int16_t frame[kFrameSamples];
  for (int i = 0; i < kRate / kFrameSamples; ++i) {  // 1 秒
    if (esp_codec_dev_read(mics, frame, sizeof frame) != ESP_CODEC_DEV_OK) break;
    float r = rms(frame, kFrameSamples);
    sum += double(r) * r;
    ++frames;
    for (int s = 0; s < kFrameSamples; ++s)
      if (frame[s] >= 32700 || frame[s] <= -32700) {
        ++clipped;
        break;
      }
  }
  esp_codec_dev_close(mics);  // 采集线程用时会自己重新打开
  if (frames > 0)
    ESP_LOGI(kTag, "self-test: %d frames, RMS %.0f (%s), %d clipped", frames,
             std::sqrt(sum / frames), frames < 50 ? "too few frames" : "ok", clipped);
}
#endif  // CONFIG_YAHAMIC_SELFTEST

}  // namespace audio
