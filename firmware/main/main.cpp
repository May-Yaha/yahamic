// YahaDesk:Mac mini 的无线麦克风(基于 OpenCharm 的板级与网络工程,见 README)。
// 一个以 24-30 fps 为目标的主循环(kLoopMs = 28):读按键、组屏幕(Live 时画
// 实时频谱律动图,实测 24.3-24.8,以遥测日志为准)、打状态日志;循环睡"剩余时间"
// 而非固定周期,渲染耗时决定实际帧率。频带数据由采集线程约 60 ms 一刷新
// (audio,与 Opus 帧同步),波形的帧间平滑、频谱重心门限/平滑与相位连续的
// 流速/空间周期驱动、逐带"渲染→DMA 传屏"都在 board 侧;音频走采集线程直发
// (60 ms 一帧 Opus,FFT 也在那里),BLE 事件走 NimBLE host 任务。
// 按键:短按 = 硬件静音/取消静音(静音时 codec 关闭,一比特都不出设备)。
// Mac 键盘的 Fn 键(按住讲话)与断链自动静音走同一条静音路径(mic::set_muted)。
// 开机默认静音。链路是 BLE 直连(uplink),首次连接在屏幕上显示 6 位配对码。
#include <algorithm>
#include <atomic>
#include <cstdio>
#include <ctime>
#include <string>

#include "audio.h"
#include "cloud.h"
#include "memory_diagnostics.h"
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

constexpr const char* kTag = "yahadesk";

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
constexpr uint32_t kStatusEveryMs = 1000;   // 读电池的间隔
constexpr uint32_t kLogEveryMs = 10000;     // 状态日志的间隔
constexpr int kSpecBars = 32;      // 对数频带数(重心/波形/色柱的输入),与 board 一致
constexpr uint32_t kDashboardFreshMs = 10000;  // Mac 指标只在设备详情展示，超时显示电脑未连接
constexpr uint32_t kClockTickMs = 1000;        // 工作台首页时钟重绘节奏(秒级)
constexpr uint32_t kMonitorStaleMs = 180000;   // 云端 60 s 一轮,连续三轮没拿到就灰显并提示
constexpr uint32_t kOperationShownMs = 10000;  // 告警页标题显示长按操作结果的时长
constexpr uint32_t kHoldSettleMs = 1600;       // 长按 1.5 s 内告警行变过就丢弃:按下时那一行可能是另一条告警

uint32_t now_ms() { return uint32_t(esp_timer_get_time() / 1000); }

void init_nvs() {
  esp_err_t err = nvs_flash_init();
  if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
    ESP_ERROR_CHECK(nvs_flash_erase());
    err = nvs_flash_init();
  }
  ESP_ERROR_CHECK(err);
}

// 通知页跑马灯速度档:存 NVS,重启沿用;读不到用中档。
uint8_t load_speed() {
  nvs_handle_t h;
  uint8_t v = 1;
  if (nvs_open("desk", NVS_READONLY, &h) == ESP_OK) {
    if (nvs_get_u8(h, "speed", &v) != ESP_OK || v >= display::kSpeeds) v = 1;
    nvs_close(h);
  }
  return v;
}
void save_speed(uint8_t v) {
  nvs_handle_t h;
  if (nvs_open("desk", NVS_READWRITE, &h) != ESP_OK) return;
  if (nvs_set_u8(h, "speed", v) != ESP_OK || nvs_commit(h) != ESP_OK) ESP_LOGW(kTag, "speed not saved");
  nvs_close(h);
}

std::string status_line(const uplink::Snapshot& s, const power::Reading& battery, bool wifi) {
  std::string status;
  if (battery.usb || battery.percent >= 0) {
    if (battery.percent >= 0) {
      status += std::string(battery.charging ? "充电" : "电量") + std::to_string(battery.percent) + "%";
    } else {
      status += "外接电源";
    }
    status += "  ";
  }
  status += wifi ? "联网  " : "离线  ";
  status += s.connected ? "蓝牙" + std::to_string(s.rssi) : "待连接";
  return status;
}

std::string percent(uint8_t value) { return value <= 100 ? std::to_string(value) + "%" : "--"; }

// The device row is local: battery, radios, the Mac's dashboard metrics and firmware version.
board::Screen::Row device_row(const uplink::Snapshot& s, const power::Reading& battery, bool wifi,
                              const uplink::Dashboard& mac, bool mac_fresh,
                              const char* version, std::vector<std::string>& lines) {
  lines.push_back(battery.percent >= 0
      ? std::string(battery.charging ? "电池 充电中 " : "电池 ") + std::to_string(battery.percent) + "%"
      : battery.usb ? "外接电源" : "电池 --");
  lines.push_back(wifi ? "网络 已连接" : "网络 未连接");
  lines.push_back(s.connected ? "蓝牙 " + std::to_string(s.rssi) + " dBm" : "蓝牙 待连接");
  std::string summary = mac_fresh ? "CPU" + percent(mac.cpu) + " 内存" + percent(mac.mem) : "电脑未连接";
  if (mac_fresh) {
    lines.push_back(summary);
    lines.push_back("电脑电量 " + percent(mac.mac_battery) +
                    (mac.mac_power == 3 ? " 充电中" : mac.mac_power == 2 ? " 已接电" : ""));
    lines.push_back("鼠标 " + percent(mac.mouse_batt) + " 键盘 " + percent(mac.kb_batt));
  }
  lines.push_back(std::string("固件 ") + version);
  return {"设备", summary, wifi && s.connected ? "ok" : "warn"};
}

std::string clock_text(int64_t epoch, int tz_minutes) {
  const int64_t local = epoch + int64_t(tz_minutes) * 60;
  char text[8];
  snprintf(text, sizeof text, "%02d:%02d", int(local / 3600 % 24), int(local / 60 % 60));
  return text;
}

bool admin_view(const cloud::View& view) {
  return view.authorized && std::any_of(view.monitor.sections.begin(), view.monitor.sections.end(),
      [](const display::Section& s) { return s.key == "tasks" && s.available; });
}

class IdlePages {
 public:
  board::Screen screen(const uplink::Snapshot& s, const power::Reading& battery, uint32_t now,
                       uint32_t live_since, int tap, int hold, const char* version) {
    metrics();
    sync_time(now);
    // A long press refers to the alert rows as last drawn, so resolve it before the next snapshot lands.
    const bool covered = s.passkey || (s.live && !s.muted);
    if (hold >= 0 && !covered && workbench.page() == display::Page::Alerts && uint32_t(now - rows_ms) > kHoldSettleMs &&
        size_t(hold) < cloud_view.monitor.alerts.size()) {
      const auto& a = cloud_view.monitor.alerts[size_t(hold)];
      if (!a.token.empty() && cloud::operate(a.token, a.action)) workbench.hold(now);
    }
    collect(now);
    local = uplink::card();
    const size_t notices = notice_count(now);
    board::Screen screen;
    screen.status = status_line(s, battery, cloud_view.wifi_connected);
    // Pairing and speech always take precedence over the workbench; their taps are dropped.
    if (s.passkey || (s.live && !s.muted)) workbench.hold(now);
    if (s.passkey) {
      char digits[8];
      snprintf(digits, sizeof digits, "%06u", unsigned(s.passkey % 1000000));
      screen.state = board::Screen::State::Pairing;
      screen.line1 = "#pairing";
      screen.line2 = digits;
      screen.line3 = "在电脑上输入配对码";
      return screen;
    }
    if (s.live && !s.muted) {
      screen.state = board::Screen::State::Live;
      screen.line1 = "#on_air_s";
      const uint32_t secs = (now - live_since) / 1000;
      char timer[8];
      snprintf(timer, sizeof timer, "%02u:%02u", unsigned(secs / 60 % 100), unsigned(secs % 60));
      screen.line2 = timer;
      return screen;
    }
    push_agent(notices, now);
    if (tap == display::kTapSpeedCycle && workbench.page() == display::Page::Notice) {
      speed = (speed + 1) % display::kSpeeds;
      save_speed(speed);
    }
    size_t selected = 0;
    if (tap == display::kTapArticle || tap == display::kTapDaily) {
      const char* kind = tap == display::kTapArticle ? "article" : "daily";
      bool found = false;
      for (size_t i = 0; i < notices; ++i) if (notice(i, now).kind == kind) { selected = i, found = true; break; }
      if (!found) tap = display::kTapNone;
    }
    if (tap != display::kTapNone) workbench.tap(tap, notices, now, selected);
    workbench.tick(now, notices);
    screen.state = board::Screen::State::Workbench;
    screen.page = workbench.page();
    screen.speed = speed;
    screen.marquee_paused = workbench.marquee_paused();
    compose(screen, s, battery, now, notices, version);
    return screen;
  }
  void shown(const board::Screen& screen, uint32_t now) {
    if (screen.state != board::Screen::State::Workbench || screen.page != display::Page::Notice) return;
    const auto n = notice(workbench.index(), now);
    if (n.active(now) && n.kind != "ble") cloud::shown(n.kind, n.key);
  }

 private:
  uint8_t speed = load_speed();
  size_t notice_count(uint32_t now) { return cloud_view.notices.size(now) + (local.active ? 1 : 0); }
  // Cloud notices first, then the Mac's BLE card.
  display::Notice notice(size_t i, uint32_t now) {
    if (i < cloud_view.notices.size(now)) return cloud_view.notices.get(i, now);
    if (local.active) return {"agent", "ble", local.title, local.body, local.expires_ms};
    return {};
  }

  void push_agent(size_t notices, uint32_t now) {
    std::vector<display::Notice> items;
    items.reserve(notices);
    for (size_t i = 0; i < notices; ++i) items.push_back(notice(i, now));
    const size_t selected = pushed_agents.next(items, workbench.page() == display::Page::Home);
    if (selected < notices) workbench.push_notice(selected, notices, now);
  }

  void compose(board::Screen& screen, const uplink::Snapshot& s, const power::Reading& battery,
               uint32_t now, size_t notices, const char* version) {
    static constexpr const char* kSections[5][2] = {
        {"tasks", "任务"}, {"collect", "采集"}, {"processing", "处理"}, {"glm", "GLM"}, {"miniapp", "小程序"}};
    const auto& monitor = cloud_view.monitor;
    const bool have = cloud_view.monitor_ms != 0;
    const bool stale = have && uint32_t(now - cloud_view.monitor_ms) > kMonitorStaleMs;
    const char* reason = !cloud_view.wifi_connected ? "离线" : "等待数据";
    // Without a Zhi.AI account the cloud sections and alerts are someone else's features: home shows no entry row.
    std::vector<display::Section> sections;
    for (const auto& k : kSections) {
      if (!cloud_view.authorized) break;
      auto it = std::find_if(monitor.sections.begin(), monitor.sections.end(),
                             [&](const display::Section& x) { return x.key == k[0]; });
      display::Section section;
      if (it != monitor.sections.end()) section = *it;
      else section.title = k[1], section.summary = have ? "暂不可用" : reason;
      if (stale) section.level.clear();
      sections.push_back(std::move(section));
    }
    display::Section device;
    const auto mac = uplink::dashboard();
    const bool mac_fresh = mac.valid && uint32_t(now - mac.received_ms) <= kDashboardFreshMs;
    const auto row = device_row(s, battery, cloud_view.wifi_connected, mac, mac_fresh, version, device.lines);
    device.title = row.title, device.summary = row.text, device.level = row.level, device.available = true;

    const bool admin = admin_view(cloud_view);
    bool error = false;
    for (const auto& a : monitor.alerts) error |= a.level == "error";
    if (!admin) {
      screen.alert = {};
    } else if (stale) {
      screen.alert = {"数据" + std::to_string(uint32_t(now - cloud_view.monitor_ms) / 60000) + "分钟未更新", "", "warn"};
    } else if (!monitor.alerts.empty()) {
      screen.alert = {"告警 " + std::to_string(monitor.alerts.size()) + " 条", "", error ? "error" : "warn"};
    } else {
      screen.alert = {have ? "全部正常" : reason, "", have ? "ok" : ""};
    }

    switch (screen.page) {
      case display::Page::Home:
        screen.line1 = "麦克风";
        screen.line2 = s.connected ? (s.muted ? "已连接 · 静音" : "已连接") : "等待电脑连接";
        screen.tone = s.connected ? "ok" : "warn";
        break;
      case display::Page::Overview:
        for (const auto& x : sections) screen.rows.push_back({x.title, x.summary, x.available ? x.level : ""});
        break;
      case display::Page::Detail: {
        const auto& x = workbench.index() < sections.size() ? sections[workbench.index()] : device;
        screen.line1 = x.title, screen.line2 = x.summary, screen.tone = x.available ? x.level : "";
        for (const auto& line : x.lines) screen.rows.push_back({line, "", ""});
        screen.trend = x.trend;
        break;
      }
      case display::Page::Alerts: {
        // The operation result replaces the header for a while, then the page reads "告警" again.
        const bool recent = !cloud_view.operation.empty() && uint32_t(now - cloud_view.operation_ms) < kOperationShownMs;
        screen.line1 = recent ? cloud_view.operation : "告警", screen.tone = screen.alert.level;
        for (const auto& a : monitor.alerts) {
          const auto hint = a.token.empty() ? "" : display::hold_label(a.action);
          screen.rows.push_back({a.title, !hint.empty() ? hint : a.at > 0 ? clock_text(a.at, tz_minutes) : "", a.level});
        }
        if (screen.rows.empty()) screen.line2 = screen.alert.title;
        break;
      }
      case display::Page::Notice: {
        const auto n = notice(workbench.index(), now);
        screen.line1 = n.title, screen.line2 = n.body, screen.tone = n.kind;
        screen.line3 = std::to_string(workbench.index() + 1) + "/" + std::to_string(notices);
        break;
      }
    }
  }
  void metrics() {
    // 收到新的 Mac 仪表盘包(接收时间戳变化)才重置时钟基准与时区;重复包不重喂。
    const uplink::Dashboard dash = uplink::dashboard();
    if (dash.valid && dash.received_ms != dash_fed_ms) {
      dash_fed_ms = dash.received_ms;
      tz_minutes = dash.tz_offset_minutes;
      if (dash.epoch) board::set_clock(dash.epoch, tz_minutes);
    }
  }
  void sync_time(uint32_t now) {
    if (int32_t(now - next_clock_sync) >= 0) {
      next_clock_sync = now + 60000;
      const auto epoch = std::time(nullptr);
      if (epoch > 1609459200) board::set_clock(uint32_t(epoch), tz_minutes);
    }
  }
  void collect(uint32_t now) {
    if (int32_t(now - cloud_at) >= 0) {
      cloud_at = now + 250;
      auto next = cloud::snapshot();
      // Rebinding, or losing Zhi.AI (refresh rejected), leaves cloud pages with nothing to show: go home.
      if (next.generation != cloud_view.generation || (cloud_view.authorized && !next.authorized)) {
        workbench.reset();
        pushed_agents.clear();
      }
      if (next.monitor_ms && next.monitor_ms != cloud_view.monitor_ms) {
        workbench.alerts(admin_view(next) ? next.monitor.alerts : std::vector<display::Alert>{}, now);
        const auto& was = cloud_view.monitor.alerts;
        if (!std::equal(was.begin(), was.end(), next.monitor.alerts.begin(), next.monitor.alerts.end(),
                        [](const display::Alert& a, const display::Alert& b) { return a.key == b.key && a.action == b.action; }))
          rows_ms = now;  // tokens are re-signed every poll; only a changed row matters
      }
      cloud_view = std::move(next);
    }
  }
  uint32_t dash_fed_ms = 0;
  display::Workbench workbench;
  display::AgentNoticeQueue pushed_agents;
  cloud::View cloud_view;
  uplink::Card local;
  uint32_t cloud_at = 0;
  uint32_t rows_ms = 0;  // 告警行(key/动作)最近一次变化
  int tz_minutes = 480;
  uint32_t next_clock_sync = 0;
};

// Every visible field, so taps and data changes redraw at once; the home clock ticks separately.
std::string fingerprint(const board::Screen& s) {
  std::string out = std::to_string(int(s.state)) + "|" + std::to_string(int(s.page)) + "|" + s.line1 + "|" +
                    s.line2 + "|" + s.line3 + "|" + s.status + "|" + s.tone + "|" + s.alert.title + s.alert.level;
  for (const auto& r : s.rows) out += "|" + r.title + "\x1f" + r.text + "\x1f" + r.level;
  for (int64_t v : s.trend) out += "|" + std::to_string(v);
  out += "|" + std::to_string(s.speed) + "|" + std::to_string(s.marquee_paused);
  return out;
}

}  // namespace

extern "C" void app_main() {
  diagnostics::heap("app entry");
  diagnostics::watch_failed_allocs();
  init_nvs();

  static board::Board b;
  board::init(b);
  diagnostics::heap("board ready");
  if (!power::init(b.i2c)) ESP_LOGW(kTag, "no battery readings (on USB that's fine)");
  if (!audio::init(b.i2c)) ESP_LOGE(kTag, "no microphone: the audio didn't start");
#if CONFIG_YAHADESK_SELFTEST
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

  audio::set_sink([](const uint8_t* opus, size_t size, uint32_t ts_ms, float) {
    uplink::send_audio(opus, size, ts_ms, 0);
  });
  mic::set_muted(true);  // 开机静音:上线后由 Mac 的静音指令决定开不开麦
  audio::start();
  xTaskCreatePinnedToCore(battery_task, "yahadesk_batt", 3072, nullptr, 2, nullptr, 0);
  // Mac 键盘 Fn(按住讲话)遥控静音 / 断链自动静音:与板上按键同一条路径,屏幕同步变化。
  // 先注册再 start:worker 一起来就可能回调。
  uplink::on_remote_mute([](bool muted) {
    mic::set_muted(muted);
    ESP_LOGI(kTag, "mac: %s", muted ? "muted (no uplink)" : "live");
  });
  uplink::start(version);
  diagnostics::heap("BLE started");
  cloud::start(version);
  diagnostics::heap("cloud task started");
  // 放在 BLE 起来之后:内部 RAM 余量要算上控制器与 host。
  ESP_LOGI(kTag, "YahaDesk %s: free %u KB internal, %u KB PSRAM", version,
           unsigned(heap_caps_get_free_size(MALLOC_CAP_INTERNAL) / 1024),
           unsigned(heap_caps_get_free_size(MALLOC_CAP_SPIRAM) / 1024));

  bool key = false;
  bool key_raw = false;
  uint32_t key_changed = 0;
  uint32_t key_down_at = 0;
  uint32_t next_status = 0;
  uint32_t next_log = 0;
  power::Reading battery;
  std::string shown;  // 上次整屏内容的指纹:变了才整屏重画
  uint32_t next_tick = 0;  // 工作台首页下一次时钟重绘时刻
  float bars[kSpecBars] = {0};
  bool was_live = false;
  uint32_t live_since = 0;  // 本次 Live 的起点(计时用)
  IdlePages idle;

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
      } else if (now - key_down_at < kPressMs) {
        mic::toggle();
        ESP_LOGI(kTag, "key: %s", uplink::muted() ? "muted (no uplink)" : "unmuted");
      }
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
    const bool live_now = s.live && !s.muted && !s.passkey;
    if (live_now && !was_live) live_since = now;
    was_live = live_now;
    board::Screen screen = idle.screen(s, battery, now, live_since, board::take_tap(), board::take_hold(), version);
    const bool ticking = screen.state == board::Screen::State::Workbench && screen.page == display::Page::Home;
    std::string print = fingerprint(screen);
    if (print != shown) {
      shown = std::move(print);
      board::draw(screen);
      next_tick = now + kClockTickMs;
    } else if (board_dump || (ticking && int32_t(now - next_tick) >= 0)) {
      next_tick = now + kClockTickMs;
      board::draw(screen);  // 截图回传在 draw 里;首页时钟内容不在指纹里,按秒重画
    }
    idle.shown(screen, now);
    // 只在 Live(按住 Fn 送声)时画频谱律动图;静音屏保持简洁。频带约
    // 60 ms 一刷新,帧间平滑/重心/相位连续动力学在 board 侧抹平台阶。
    if (screen.state == board::Screen::State::Live) {
      if (audio::spectrum(bars, kSpecBars)) board::draw_spectrum(bars, kSpecBars);
    }

    if (int32_t(now - next_log) >= 0) {
      next_log = now + kLogEveryMs;
      diagnostics::heap("runtime");
      static uint32_t last_frames = 0;
      uint32_t frames = board::spectrum_frame_count();
      int32_t avg = 0, mn = 0, mx = 0;
      bool has_cap = audio::capture_stats(avg, mn, mx);
      int32_t rframe = 0, rdma = 0;
      board::render_timing(rframe, rdma);
      ESP_LOGI(kTag, "ble %s | rssi %d%s | level %.2f | 渲染 %.1f fps(帧 %d.%dms,传屏 %d.%dms) | 采集 %d/%d/%d ms",
               s.phase, s.rssi, s.muted ? " | muted" : "", audio::level(),
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
