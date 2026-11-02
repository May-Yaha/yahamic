#include "uplink.h"

#include <atomic>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>

#include "esp_log.h"
#include "esp_mac.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

extern "C" void ble_store_config_init(void);

// 协议 v3(README「协议 v3」是规范),NimBLE 外设,结构照 ESP-IDF 的 bleprph 示例:
//   info(read)      "fw X\nrate 16000\nframe 60\ncodec opus\n"
//   audio(notify)   seq u16 LE ‖ frag u8(低 7 位片序号,bit7 末片)‖ Opus 分片
//   status(read+notify) muted u8
//   control(write)  0x01 muted u8 设静音;0x02 请求屏幕回传
//   dashboard(write no rsp) 10 字节,布局同 v2 type 7
// 全部特征要求加密 + MITM 认证,未配对的 central 读不到也写不进。notify 在链路层
// 可靠有序,不需要保活与重放窗口;断链即静音,Mac 每次连上后写一次静音指令。
namespace uplink {
namespace {

constexpr const char* kTag = "link";
constexpr size_t kFragHeader = 3;    // seq u16 + frag u8
constexpr uint8_t kLastFrag = 0x80;
constexpr uint32_t kRssiEveryMs = 2000;

// 128 位 UUID 6B96000N-2D78-4CE2-963A-884ED7A5150C,NimBLE 按小端存。
#define YAHA_UUID(n) \
  BLE_UUID128_INIT(0x0c, 0x15, 0xa5, 0xd7, 0x4e, 0x88, 0x3a, 0x96, 0xe2, 0x4c, 0x78, 0x2d, n, 0x00, 0x96, 0x6b)
const ble_uuid128_t kServiceUuid = YAHA_UUID(0x01);
const ble_uuid128_t kInfoUuid = YAHA_UUID(0x02);
const ble_uuid128_t kAudioUuid = YAHA_UUID(0x03);
const ble_uuid128_t kStatusUuid = YAHA_UUID(0x04);
const ble_uuid128_t kControlUuid = YAHA_UUID(0x05);
const ble_uuid128_t kDashboardUuid = YAHA_UUID(0x06);

struct __attribute__((packed)) DashboardPayload {
  uint32_t epoch;
  int16_t tz_minutes;
  uint8_t cpu, mem, mouse_batt, kb_batt;
};
static_assert(sizeof(DashboardPayload) == 10, "wire dashboard");

uint16_t info_handle, audio_handle, status_handle, control_handle, dashboard_handle;
uint8_t own_addr_type = 0;
std::string device_name;
std::string info_text;

// 连接状态只由 NimBLE host 任务写;采集线程与主循环只读这些原子量。
std::atomic<uint16_t> conn{BLE_HS_CONN_HANDLE_NONE};
std::atomic<bool> secure{false};     // 已加密且经 MITM 认证
std::atomic<bool> audio_sub{false};  // Mac 订阅了 audio
std::atomic<bool> status_sub{false};
std::atomic<uint16_t> mtu{BLE_ATT_MTU_DFLT};
std::atomic<uint32_t> passkey{0};    // 配对中显示的数;只上屏,不进日志
std::atomic<bool> muted_{true};
std::atomic<bool> dump_pending{false};
uint16_t audio_seq = 0;  // 只在采集线程里用
MuteCommand remote_mute;  // host 任务里回调(main 注册,须在 start 之前)
std::mutex dash_lock;
Dashboard dash;

uint32_t now_ms() { return uint32_t(esp_timer_get_time() / 1000); }

bool live() { return conn.load() != BLE_HS_CONN_HANDLE_NONE && secure.load() && audio_sub.load(); }

int on_gap(ble_gap_event* event, void*);

void advertise() {
  // 主广播包放 service UUID(Mac 按 UUID 扫描),名字放扫描响应:31 字节放不下两者。
  ble_hs_adv_fields fields = {};
  fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
  fields.uuids128 = &kServiceUuid;
  fields.num_uuids128 = 1;
  fields.uuids128_is_complete = 1;
  int rc = ble_gap_adv_set_fields(&fields);
  if (rc != 0) {
    ESP_LOGE(kTag, "adv fields failed: %d", rc);
    return;
  }
  ble_hs_adv_fields rsp = {};
  rsp.name = reinterpret_cast<const uint8_t*>(device_name.c_str());
  rsp.name_len = uint8_t(device_name.size());
  rsp.name_is_complete = 1;
  rc = ble_gap_adv_rsp_set_fields(&rsp);
  if (rc != 0) {
    ESP_LOGE(kTag, "scan response failed: %d", rc);
    return;
  }
  ble_gap_adv_params params = {};
  params.conn_mode = BLE_GAP_CONN_MODE_UND;
  params.disc_mode = BLE_GAP_DISC_MODE_GEN;
  rc = ble_gap_adv_start(own_addr_type, nullptr, BLE_HS_FOREVER, &params, on_gap, nullptr);
  if (rc != 0 && rc != BLE_HS_EALREADY) ESP_LOGE(kTag, "advertise failed: %d", rc);
}

void link_down() {
  conn.store(BLE_HS_CONN_HANDLE_NONE);
  secure.store(false);
  audio_sub.store(false);
  status_sub.store(false);
  passkey.store(0);
  mtu.store(BLE_ATT_MTU_DFLT);
  {
    std::lock_guard<std::mutex> guard(dash_lock);
    dash = Dashboard{};
  }
  if (remote_mute) remote_mute(true);  // 断链即静音;此处不持任何链路锁
}

void request_fast_interval(uint16_t handle) {
  // 15–30 ms 连接间隔:60 ms 一帧的音频每帧至少两次发送机会。Mac 可以不接受。
  ble_gap_upd_params p = {};
  p.itvl_min = 12;   // × 1.25 ms
  p.itvl_max = 24;
  p.latency = 0;
  p.supervision_timeout = 400;  // × 10 ms
  ble_gap_update_params(handle, &p);
}

int on_gap(ble_gap_event* event, void*) {
  ble_gap_conn_desc desc;
  switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
      if (event->connect.status != 0) {
        advertise();
        return 0;
      }
      conn.store(event->connect.conn_handle);
      ESP_LOGI(kTag, "connected");
      // 主动发起安全流程:已 bond 的 Mac 直接用旧密钥加密,新 Mac 立刻进入配对。
      ble_gap_security_initiate(event->connect.conn_handle);
      request_fast_interval(event->connect.conn_handle);
      return 0;

    case BLE_GAP_EVENT_DISCONNECT:
      ESP_LOGI(kTag, "disconnected (reason 0x%x)", event->disconnect.reason);
      link_down();
      advertise();
      return 0;

    case BLE_GAP_EVENT_ADV_COMPLETE:
      if (conn.load() == BLE_HS_CONN_HANDLE_NONE) advertise();
      return 0;

    case BLE_GAP_EVENT_ENC_CHANGE:
      passkey.store(0);
      if (event->enc_change.status == 0 && ble_gap_conn_find(event->enc_change.conn_handle, &desc) == 0) {
        secure.store(desc.sec_state.encrypted && desc.sec_state.authenticated);
        ESP_LOGI(kTag, "link %s", secure.load() ? "encrypted + authenticated" : "encrypted without MITM: refused");
        if (!secure.load()) ble_gap_terminate(event->enc_change.conn_handle, BLE_ERR_AUTH_FAIL);
      } else {
        // 设备丢了 bond 而 Mac 还留着:Mac 那边要「忘记此设备」后重配。
        ESP_LOGW(kTag, "encryption failed: %d", event->enc_change.status);
      }
      return 0;

    case BLE_GAP_EVENT_SUBSCRIBE:
      if (event->subscribe.attr_handle == audio_handle) {
        audio_sub.store(event->subscribe.cur_notify);
        ESP_LOGI(kTag, "audio %s", event->subscribe.cur_notify ? "subscribed: live" : "unsubscribed");
      } else if (event->subscribe.attr_handle == status_handle) {
        status_sub.store(event->subscribe.cur_notify);
      }
      return 0;

    case BLE_GAP_EVENT_MTU:
      mtu.store(event->mtu.value);
      ESP_LOGI(kTag, "mtu %u", unsigned(event->mtu.value));
      return 0;

    case BLE_GAP_EVENT_REPEAT_PAIRING:
      // Mac 删了配对又来配:扔掉旧 bond,接受新配对(同 bleprph)。
      if (ble_gap_conn_find(event->repeat_pairing.conn_handle, &desc) == 0)
        ble_store_util_delete_peer(&desc.peer_id_addr);
      return BLE_GAP_REPEAT_PAIRING_RETRY;

    case BLE_GAP_EVENT_PASSKEY_ACTION:
      if (event->passkey.params.action == BLE_SM_IOACT_DISP) {
        ble_sm_io io = {};
        io.action = BLE_SM_IOACT_DISP;
        io.passkey = 100000 + esp_random() % 900000;  // 恒为 6 位,0 留作"不在配对"
        passkey.store(io.passkey);
        ESP_LOGI(kTag, "pairing: passkey on screen");
        int rc = ble_sm_inject_io(event->passkey.conn_handle, &io);
        if (rc != 0) ESP_LOGE(kTag, "passkey inject failed: %d", rc);
      }
      return 0;

    default:
      return 0;
  }
}

int on_access(uint16_t, uint16_t attr_handle, ble_gatt_access_ctxt* ctxt, void*) {
  if (ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR) {
    if (attr_handle == info_handle)
      return os_mbuf_append(ctxt->om, info_text.data(), info_text.size()) == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
    if (attr_handle == status_handle) {
      uint8_t m = muted_.load() ? 1 : 0;
      return os_mbuf_append(ctxt->om, &m, 1) == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    return BLE_ATT_ERR_UNLIKELY;
  }
  if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) return BLE_ATT_ERR_UNLIKELY;
  uint8_t buf[sizeof(DashboardPayload)];
  uint16_t len = 0;
  if (OS_MBUF_PKTLEN(ctxt->om) > sizeof buf) return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
  if (ble_hs_mbuf_to_flat(ctxt->om, buf, sizeof buf, &len) != 0) return BLE_ATT_ERR_UNLIKELY;
  if (attr_handle == control_handle) {
    if (len == 2 && buf[0] == 0x01) {
      if (remote_mute) remote_mute(buf[1] != 0);
      return 0;
    }
    if (len == 1 && buf[0] == 0x02) {
      dump_pending.store(true);
      return 0;
    }
    return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
  }
  if (attr_handle == dashboard_handle) {
    if (len != sizeof(DashboardPayload)) return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    DashboardPayload p;
    memcpy(&p, buf, sizeof p);
    std::lock_guard<std::mutex> guard(dash_lock);
    dash.epoch = p.epoch;
    dash.tz_offset_minutes = p.tz_minutes;
    dash.cpu = p.cpu;
    dash.mem = p.mem;
    dash.mouse_batt = p.mouse_batt;
    dash.kb_batt = p.kb_batt;
    dash.received_ms = now_ms();
    dash.valid = true;
    return 0;
  }
  return BLE_ATT_ERR_UNLIKELY;
}

constexpr ble_gatt_chr_flags kSecureRead = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_READ_ENC | BLE_GATT_CHR_F_READ_AUTHEN;
constexpr ble_gatt_chr_flags kSecureNotify =
    BLE_GATT_CHR_F_NOTIFY | BLE_GATT_CHR_F_NOTIFY_INDICATE_ENC | BLE_GATT_CHR_F_NOTIFY_INDICATE_AUTHEN;
constexpr ble_gatt_chr_flags kSecureWrite = BLE_GATT_CHR_F_WRITE_ENC | BLE_GATT_CHR_F_WRITE_AUTHEN;

const ble_gatt_chr_def kChars[] = {
    {.uuid = &kInfoUuid.u, .access_cb = on_access, .flags = kSecureRead, .val_handle = &info_handle},
    {.uuid = &kAudioUuid.u, .access_cb = on_access, .flags = kSecureNotify, .val_handle = &audio_handle},
    {.uuid = &kStatusUuid.u, .access_cb = on_access, .flags = kSecureRead | kSecureNotify, .val_handle = &status_handle},
    {.uuid = &kControlUuid.u, .access_cb = on_access, .flags = BLE_GATT_CHR_F_WRITE | kSecureWrite,
     .val_handle = &control_handle},
    {.uuid = &kDashboardUuid.u, .access_cb = on_access, .flags = BLE_GATT_CHR_F_WRITE_NO_RSP | kSecureWrite,
     .val_handle = &dashboard_handle},
    {},
};
const ble_gatt_svc_def kServices[] = {
    {.type = BLE_GATT_SVC_TYPE_PRIMARY, .uuid = &kServiceUuid.u, .characteristics = kChars},
    {},
};

void on_sync() {
  int rc = ble_hs_util_ensure_addr(0);
  if (rc == 0) rc = ble_hs_id_infer_auto(0, &own_addr_type);
  if (rc != 0) {
    ESP_LOGE(kTag, "no BLE address: %d", rc);
    return;
  }
  ESP_LOGI(kTag, "advertising as %s", device_name.c_str());
  advertise();
}

void on_reset(int reason) { ESP_LOGW(kTag, "host reset: %d", reason); }

void host_task(void*) {
  nimble_port_run();  // 直到 nimble_port_stop()
  nimble_port_freertos_deinit();
}

// notify 不看订阅状态(NimBLE 的 notify_custom 照发),调用方先判断。
bool notify(uint16_t handle, const void* data, size_t len) {
  uint16_t c = conn.load();
  if (c == BLE_HS_CONN_HANDLE_NONE) return false;
  os_mbuf* om = ble_hs_mbuf_from_flat(data, uint16_t(len));
  if (!om) return false;
  return ble_gatts_notify_custom(c, handle, om) == 0;  // 失败时 om 已被释放
}

}  // namespace

void on_remote_mute(MuteCommand command) { remote_mute = std::move(command); }

bool consume_dump_request() { return dump_pending.exchange(false); }

void start(const char* version) {
  uint8_t mac[6] = {0};
  esp_read_mac(mac, ESP_MAC_BT);
  char name[16];
  snprintf(name, sizeof name, "yahamic-%02x%02x", mac[4], mac[5]);
  device_name = name;
  info_text = std::string("fw ") + (version ? version : "0.0.0") + "\nrate 16000\nframe 60\ncodec opus\n";

  esp_err_t err = nimble_port_init();
  if (err != ESP_OK) {
    ESP_LOGE(kTag, "nimble init failed: %d", err);
    return;
  }
  ble_hs_cfg.reset_cb = on_reset;
  ble_hs_cfg.sync_cb = on_sync;
  ble_hs_cfg.store_status_cb = ble_store_util_status_rr;
  ble_hs_cfg.sm_io_cap = BLE_HS_IO_DISPLAY_ONLY;  // 设备显示 6 位数,Mac 输入
  ble_hs_cfg.sm_bonding = 1;
  ble_hs_cfg.sm_mitm = 1;
  ble_hs_cfg.sm_sc = 1;
  ble_hs_cfg.sm_our_key_dist |= BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
  ble_hs_cfg.sm_their_key_dist |= BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;

  ble_svc_gap_init();
  ble_svc_gatt_init();
  int rc = ble_gatts_count_cfg(kServices);
  if (rc == 0) rc = ble_gatts_add_svcs(kServices);
  if (rc != 0) {
    ESP_LOGE(kTag, "gatt services failed: %d", rc);
    return;
  }
  ble_svc_gap_device_name_set(name);
  ble_store_config_init();  // bond 存 NVS(BT_NIMBLE_NVS_PERSIST)
  nimble_port_freertos_init(host_task);
}

void set_muted(bool on) {
  muted_.store(on);
  if (secure.load() && status_sub.load()) {
    uint8_t m = on ? 1 : 0;
    notify(status_handle, &m, 1);
  }
}

bool muted() { return muted_.load(); }

Dashboard dashboard() {
  std::lock_guard<std::mutex> guard(dash_lock);
  return dash;
}

Snapshot snapshot() {
  Snapshot s;
  uint16_t c = conn.load();
  s.connected = c != BLE_HS_CONN_HANDLE_NONE;
  s.live = live();
  s.passkey = passkey.load();
  s.muted = muted_.load();
  // RSSI 要问控制器(走 HCI,带锁):主循环 28 ms 一圈,按 2 秒缓存。
  static int cached_rssi = 0;
  static uint32_t rssi_at = 0;
  if (!s.connected) {
    cached_rssi = 0;
  } else if (now_ms() - rssi_at >= kRssiEveryMs) {
    rssi_at = now_ms();
    int8_t v = 0;
    if (ble_gap_conn_rssi(c, &v) == 0) cached_rssi = v;
  }
  s.rssi = cached_rssi;
  const char* phase = s.live ? "live" : s.passkey ? "pairing" : s.connected ? "connected" : "advertising";
  strlcpy(s.phase, phase, sizeof s.phase);
  return s;
}

void send_audio(const uint8_t* opus, size_t size, uint32_t, float) {
  // 采集线程直发。未 live 直接丢;发送队列满(mbuf 不够)时整帧余下分片丢掉,
  // seq 照常递增,Mac 按跳号计丢帧。
  if (!live() || size == 0) return;
  const uint16_t seq = audio_seq++;
  const size_t chunk = size_t(mtu.load()) - 3 - kFragHeader;  // ATT notify 头 3 字节
  uint8_t packet[BLE_ATT_MTU_MAX];
  for (size_t off = 0, frag = 0; off < size; ++frag) {
    if (frag > 0x7f) return;  // 帧超过 127 片:不会出现(240 B / 最小 17 B)
    const size_t n = size - off < chunk ? size - off : chunk;
    packet[0] = uint8_t(seq);
    packet[1] = uint8_t(seq >> 8);
    packet[2] = uint8_t(frag) | (off + n == size ? kLastFrag : 0);
    memcpy(packet + kFragHeader, opus + off, n);
    if (!notify(audio_handle, packet, kFragHeader + n)) return;
    off += n;
  }
}

}  // namespace uplink
