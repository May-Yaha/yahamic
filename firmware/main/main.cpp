// Yahamic:Mac mini 的无线麦克风(基于 OpenCharm 的板级与网络工程,见 README)。
// 一个以 24-30 fps 为目标的主循环(kLoopMs = 28):读按键、组屏幕(Live 时画
// 实时频谱律动图,实测 24.3-24.8,以遥测日志为准)、打状态日志;循环睡"剩余时间"
// 而非固定周期,渲染耗时决定实际帧率。频带数据由采集线程约 60 ms 一刷新
// (audio,与 Opus 帧同步),波形的帧间平滑、频谱重心门限/平滑与相位连续的
// 流速/空间周期驱动、逐带"渲染→DMA 传屏"都在 board 侧;音频走采集线程直发
// (60 ms 一帧 Opus,FFT 也在那里),网络握手走 uplink 的 worker 任务。
// 按键:短按 = 硬件静音/取消静音(静音时 codec 关闭,一比特都不出设备);
// 长按 5 秒 = 打开 Wi-Fi 配网热点。Mac 键盘的 Fn 键(按住讲话)与断链自动静音
// 走同一条静音路径(mic::set_muted)。开机默认静音。
#include <atomic>
#include <string>

#include "audio.h"
#include "board.h"
#include "esp_app_desc.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "mic_state.h"
#include "uplink.h"
#include "nvs_flash.h"
#include "power.h"
#include "sdkconfig.h"

namespace {

constexpr const char* kTag = "yahamic";

// 电池读取放独立任务:AXP2101 走 I2C,忙时一个寄存器就能等 50ms,放在主循环
// 里会周期性卡掉好几帧频谱。主循环只读这里的缓存。
std::atomic<int> battery_percent{-1};
std::atomic<bool> battery_usb{false};
std::atomic<bool> battery_charging{false};

void battery_task(void*) {
  for (;;) {
    power::Reading r = power::read();
    battery_percent.store(r.percent);
    battery_usb.store(r.usb);
    battery_charging.store(r.charging);
    vTaskDelay(pdMS_TO_TICKS(1000));
  }
}
constexpr uint32_t kLoopMs = 28;  // 渲染约25ms,给快照/采集让出时间,目标24-30fps(实测24.3-24.8)
constexpr uint32_t kDebounceMs = 20;   // 按键消抖(同 OpenCharm)
constexpr uint32_t kPressMs = 400;     // 短按上限:按住超过这个不算短按
constexpr uint32_t kHoldSetupMs = 5000; // 长按这么久打开配网
constexpr uint32_t kStatusEveryMs = 1000;   // 读电池的间隔
constexpr uint32_t kLogEveryMs = 10000;     // 状态日志的间隔
constexpr int kSpecBars = 32;      // 对数频带数(重心/波形/色柱的输入),与 board 一致
constexpr uint32_t kDashboardFreshMs = 10000;  // type 7 新鲜度窗口:超时回退 Muted
constexpr uint32_t kDashboardTickMs = 1000;    // Dashboard 屏时钟重绘节奏(秒级)

uint32_t now_ms() { return uint32_t(esp_timer_get_time() / 1000); }

void init_nvs() {
  esp_err_t err = nvs_flash_init();
  if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
    ESP_ERROR_CHECK(nvs_flash_erase());
    err = nvs_flash_init();
  }
  ESP_ERROR_CHECK(err);
}

// 屏幕状态 = Wi-Fi 状态 × 链路状态 × 静音状态(空闲时再看 type 7 新鲜度:
// 新鲜 → Dashboard 仪表盘,否则 → Muted)。
board::Screen compose(const uplink::Snapshot& s, const power::Reading& battery,
                      const uplink::Dashboard& dash, uint32_t now) {
  board::Screen screen;
  if (s.setup) {
    screen.state = board::Screen::State::Setup;
    screen.line1 = "#setup";
    screen.line2 = std::string("#hotspot ") + s.setup_ssid;
    screen.line3 = std::string("#password ") + s.setup_pass;
  } else if (s.unpaired) {  // 没有有效配对码:不连 Mac,只能去配网页填码
    screen.state = board::Screen::State::NoWifi;
    screen.line1 = "PAIRING CODE?";
    screen.line2 = "#hold_setup";
  } else if (!s.wifi_up) {
    if (s.joining) {  // 配过网,正在连或重试:不是没配过
      screen.state = board::Screen::State::Joining;
      screen.line1 = "#joining";
    } else {
      screen.state = board::Screen::State::NoWifi;
      screen.line1 = "#nowifi";
      screen.line2 = "#hold_setup";
    }
  } else if (!s.live) {
    screen.state = board::Screen::State::Searching;
    screen.line1 = "#searching";
    screen.line2 = "#run_app";
  } else if (s.muted) {
    // 握手完成且非 Live 的空闲屏:type 7 数据新鲜(10s 内收到过)进 Dashboard。
    // why 回退 Muted:蓝牙断续/守护进程退出后数据停更,若赖在 Dashboard 屏,
    // 时钟与仪表就冻在旧值上误导用户;回退 Muted 保留"从未/不再收到仪表盘
    // 数据"时的旧语义兜底。
    if (dash.valid && uint32_t(now - dash.received_ms) <= kDashboardFreshMs) {
      screen.state = board::Screen::State::Dashboard;
    } else {
      screen.state = board::Screen::State::Muted;
      screen.line1 = "#muted";
      screen.line2 = "#hold_fn";
    }
  } else {
    screen.state = board::Screen::State::Live;
    screen.line1 = "#on_air_s";
  }
  std::string status;
  if (battery.usb || battery.percent >= 0) {
    if (battery.percent >= 0) {
      status += std::to_string(battery.percent) + "%" + (battery.charging ? "+" : "");
    } else {
      status += "USB";
    }
    status += " ";
  }
  status += s.ip[0] ? s.ip : "NO IP";
  if (s.wifi_up) status += " " + std::to_string(s.rssi) + "DB";
  screen.status = status;
  return screen;
}

}  // namespace

extern "C" void app_main() {
  init_nvs();

  static board::Board b;
  board::init(b);
  if (!power::init(b.i2c)) ESP_LOGW(kTag, "no battery readings (on USB that's fine)");
  if (!audio::init(b.i2c)) ESP_LOGE(kTag, "no microphone: the audio didn't start");
#if CONFIG_YAHAMIC_SELFTEST
  audio::self_test();
#endif

  const char* version = esp_app_get_description()->version;
  {
    board::Screen boot;
    boot.state = board::Screen::State::Boot;
    boot.line1 = "#boot";
    boot.line2 = std::string("#firmware ") + version;
    board::draw(boot);
  }
  ESP_LOGI(kTag, "Yahamic %s: free %u KB internal, %u KB PSRAM", version,
           unsigned(heap_caps_get_free_size(MALLOC_CAP_INTERNAL) / 1024),
           unsigned(heap_caps_get_free_size(MALLOC_CAP_SPIRAM) / 1024));

  audio::set_sink([](const uint8_t* opus, size_t size, uint32_t ts_ms, float) {
    uplink::send_audio(opus, size, ts_ms, 0);
  });
  mic::set_muted(true);  // 开机静音:上线后由 Mac 的静音指令决定开不开麦
  audio::start();
  xTaskCreatePinnedToCore(battery_task, "yahamic_batt", 3072, nullptr, 2, nullptr, 0);
  // Mac 键盘 Fn(按住讲话)遥控静音 / 断链自动静音:与板上按键同一条路径,屏幕同步变化。
  // 先注册再 start:worker 一起来就可能回调。
  uplink::on_remote_mute([](bool muted) {
    mic::set_muted(muted);
    ESP_LOGI(kTag, "mac: %s", muted ? "muted (capture off)" : "live");
  });
  uplink::start(version);

  bool key = false;
  bool key_raw = false;
  uint32_t key_changed = 0;
  uint32_t key_down_at = 0;
  bool hold_fired = false;
  uint32_t next_status = 0;
  uint32_t next_log = 0;
  power::Reading battery;
  std::string shown;  // 上次整屏内容的指纹:变了才整屏重画
  uint32_t dash_fed_ms = 0;    // 已喂给 board 的 type 7 接收时间戳(只在新包时重喂)
  uint32_t next_dash_tick = 0; // Dashboard 屏下一次时钟重绘时刻
  float bars[kSpecBars] = {0};

  while (true) {
    uint32_t now = now_ms();

    bool raw = board::key_down();
    if (raw != key_raw) {
      key_raw = raw;
      key_changed = now;
    }
    if (key_raw != key && now - key_changed >= kDebounceMs) {
      key = key_raw;
      if (key) {
        key_down_at = now;
        hold_fired = false;
      } else if (!hold_fired && now - key_down_at < kPressMs) {
        mic::toggle();
        ESP_LOGI(kTag, "key: %s", uplink::muted() ? "muted (capture off)" : "unmuted");
      }
    }
    if (key && !hold_fired && now - key_down_at >= kHoldSetupMs) {
      hold_fired = true;
      ESP_LOGI(kTag, "key held 5 s: opening Wi-Fi setup");
      uplink::open_setup();
    }

    uplink::Snapshot s = uplink::snapshot();
    if (int32_t(now - next_status) >= 0) {
      next_status = now + kStatusEveryMs;
      battery.percent = battery_percent.load();
      battery.usb = battery_usb.load();
      battery.charging = battery_charging.load();
    }
    bool board_dump = uplink::consume_dump_request();
    if (board_dump) board::request_screen_dump();
    // type 7 仪表盘数据:收到新包(接收时间戳变化)才转换并喂给 board,
    // 时钟基准随每包重置(why 见 board::set_dashboard),重复包不重喂。
    uplink::Dashboard dash = uplink::dashboard();
    if (dash.valid && dash.received_ms != dash_fed_ms) {
      dash_fed_ms = dash.received_ms;
      board::DashboardData d;
      d.epoch = dash.epoch;
      d.tz_offset_minutes = dash.tz_offset_minutes;
      d.cpu = dash.cpu;
      d.mem = dash.mem;
      d.mouse_batt = dash.mouse_batt;
      d.kb_batt = dash.kb_batt;
      board::set_dashboard(d);
    }
    board::Screen screen = compose(s, battery, dash, now);
    std::string fingerprint = std::to_string(int(screen.state)) + "|" + screen.line1 + "|" +
                              screen.line2 + "|" + screen.line3 + "|" + screen.status;
    if (fingerprint != shown) {
      shown = fingerprint;
      board::draw(screen);
      if (screen.state == board::Screen::State::Dashboard) next_dash_tick = now + kDashboardTickMs;
    } else if (board_dump) {
      board::draw(screen);  // 内容没变也要重画一次:截图回传在 draw 里
    } else if (screen.state == board::Screen::State::Dashboard && int32_t(now - next_dash_tick) >= 0) {
      next_dash_tick = now + kDashboardTickMs;
      board::draw_dashboard();  // 指纹不变也要按 ~1Hz 重绘:大字时钟秒级走针
    }
    // 只在 Live(按住 Fn 送声)时画频谱律动图;静音屏保持简洁。频带约
    // 60 ms 一刷新,帧间平滑/重心/相位连续动力学在 board 侧抹平台阶。
    if (screen.state == board::Screen::State::Live) {
      if (audio::spectrum(bars, kSpecBars)) board::draw_spectrum(bars, kSpecBars);
    }

    if (int32_t(now - next_log) >= 0) {
      next_log = now + kLogEveryMs;
      static uint32_t last_frames = 0;
      uint32_t frames = board::spectrum_frame_count();
      int32_t avg = 0, mn = 0, mx = 0;
      bool has_cap = audio::capture_stats(avg, mn, mx);
      int32_t rframe = 0, rdma = 0;
      board::render_timing(rframe, rdma);
      ESP_LOGI(kTag, "%s%s| %s | rssi %d | daemon %s | %s%s | level %.2f | 渲染 %.1f fps(帧 %d.%dms,传屏 %d.%dms) | 采集 %d/%d/%d ms",
               s.wifi_up ? "wifi " : "no wifi ", s.setup ? "setup " : "", s.ssid, s.rssi,
               s.daemon[0] ? s.daemon : "-", s.phase, s.muted ? " muted" : "", audio::level(),
               float(frames - last_frames) * 1000.0f / kLogEveryMs,
               rframe / 1000, (rframe % 1000) / 100, rdma / 1000, (rdma % 1000) / 100,
               has_cap ? avg : -1, has_cap ? mn : -1, has_cap ? mx : -1);
      last_frames = frames;
    }
    // 睡"剩余时间"而不是固定周期:波形渲染一帧约 25-33 ms(遥测实测),
    // 若再固定睡 33 ms 就只剩约 15 fps 了。
    uint32_t spent = now_ms() - now;
    vTaskDelay(pdMS_TO_TICKS(spent < kLoopMs ? kLoopMs - spent : 1));
  }
}
