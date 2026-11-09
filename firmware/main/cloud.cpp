#include "cloud.h"
#include "display_json.h"
#include "dms.h"
#include "memory_diagnostics.h"

#include <atomic>
#include <cmath>
#include <cstring>
#include <strings.h>
#include <ctime>
#include <memory>
#include <mutex>

#include "cJSON.h"
#include "esp_crt_bundle.h"
#include "esp_event.h"
#include "esp_http_client.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_random.h"
#include "esp_netif_sntp.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "nvs.h"
#include "uplink.h"

namespace cloud {
namespace {
// Fixed origin prevents a provisioning payload from redirecting device credentials.
constexpr const char* kTokenURL = "https://hub.flyaha.top/oauth/token";
constexpr const char* kMcpURL = "https://hub.flyaha.top/api/v1/mcp";
using namespace wirejson;
std::mutex lock, storage_lock;
View view;
std::string queued_wifi, queued_grant;
std::string queued_token, queued_action;  // guarded by lock; never logged
uint32_t queued_ms = 0;
std::atomic<bool> speaking{false}, wifi_up{false}, storage_ready{false};
std::atomic<uint32_t> grant_epoch{0};
std::atomic<bool> scan_wanted{false};
std::atomic<bool> wifi_dropped{false};  // a join failed or the AP dropped us; network_cycle schedules the retry
std::atomic<uint16_t> wifi_reason{0};  // last failed join's wifi_err_reason_t; 0 once joined or given new credentials
uint32_t next_connect = 0, backoff = 2000;  // worker task only; network_cycle is the single esp_wifi_connect caller
uint32_t scan_count = 0;  // guarded by lock, with networks
std::string networks = R"({"scan":0,"networks":[]})";
std::string firmware, client_id, refresh_token, access_token, generation;
uint32_t access_until = 0;
nvs_handle_t storage = 0;
bool wifi_started = false;

uint32_t now_ms() { return uint32_t(esp_timer_get_time() / 1000); }
// Codes are fixed strings, never tokens; logging changes leaves a trail for unattended offline periods.
void error(const char* code) {
  bool changed;
  {
    std::lock_guard<std::mutex> g(lock);
    changed = view.error != code;
    view.error = code;
  }
  if (changed) ESP_LOGI("cloud", "error %s", *code ? code : "cleared");
}
bool save(const char* key, const std::string& value) {
  std::lock_guard<std::mutex> g(storage_lock);
  return !value.empty() && storage_ready.load() && nvs_set_str(storage, key, value.c_str()) == ESP_OK && nvs_commit(storage) == ESP_OK;
}
std::string load_locked(const char* key, size_t limit = 2048) {
  size_t n = 0;
  if (!storage_ready.load() || nvs_get_str(storage, key, nullptr, &n) != ESP_OK || !n || n > limit) return {};
  std::string s(n, '\0');
  if (nvs_get_str(storage, key, s.data(), &n) != ESP_OK) return {};
  s.resize(n - 1);
  return s;
}
std::string load(const char* key, size_t limit = 2048) {
  std::lock_guard<std::mutex> g(storage_lock);
  return load_locked(key, limit);
}
bool save_rotated_grant(const std::string& value) {
  std::lock_guard<std::mutex> g(storage_lock);
  auto previous = parse(load_locked("grant", 512));
  if (!previous || text(previous.get(), "generation") != generation) return false;
  return nvs_set_str(storage, "grant", value.c_str()) == ESP_OK && nvs_commit(storage) == ESP_OK;
}
std::string form(const std::string& s) {
  constexpr char hex[] = "0123456789ABCDEF";
  std::string out;
  for (unsigned char c : s) {
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~') out += char(c);
    else { out += '%'; out += hex[c >> 4]; out += hex[c & 15]; }
  }
  return out;
}
struct Response { std::string body, content_type; uint32_t epoch = grant_epoch.load(); bool overflow = false, oauth = false; };
esp_err_t http_event(esp_http_client_event_t* e) {
  auto& r = *static_cast<Response*>(e->user_data);
  if ((!r.oauth && speaking.load()) || r.epoch != grant_epoch.load()) return ESP_FAIL;
  if (e->event_id == HTTP_EVENT_ON_HEADER && e->header_key && e->header_value &&
      strcasecmp(e->header_key, "Content-Type") == 0) r.content_type.assign(e->header_value, strnlen(e->header_value, 128));
  if (e->event_id != HTTP_EVENT_ON_DATA) return ESP_OK;
  if (e->data_len < 0 || r.body.size() + size_t(e->data_len) > kResponseMax) {
    r.overflow = true;
    return ESP_FAIL;
  }
  r.body.append(static_cast<const char*>(e->data), size_t(e->data_len));
  return ESP_OK;
}
esp_err_t transfer(esp_http_client_handle_t client, uint32_t epoch, bool oauth) {
  if (speaking.load()) return ESP_FAIL;
  const uint32_t deadline = now_ms() + 8000;
  esp_err_t rc;
  do {
    if ((!oauth && speaking.load()) || epoch != grant_epoch.load() || int32_t(now_ms() - deadline) >= 0) { rc = ESP_FAIL; break; }
    rc = esp_http_client_perform(client);
    if (rc == ESP_ERR_HTTP_EAGAIN) vTaskDelay(pdMS_TO_TICKS(20));
  } while (rc == ESP_ERR_HTTP_EAGAIN);
  return rc;
}
bool setup_request(esp_http_client_handle_t client, const std::string& body, bool oauth) {
  if (esp_http_client_set_header(client, "Content-Type", oauth ? "application/x-www-form-urlencoded" : "application/json") != ESP_OK ||
      esp_http_client_set_header(client, "Accept", "application/json, text/event-stream") != ESP_OK) return false;
  if (!oauth) {
    const auto auth = "Bearer " + access_token;
    if (esp_http_client_set_header(client, "Authorization", auth.c_str()) != ESP_OK) return false;
  }
  return esp_http_client_set_post_field(client, body.c_str(), int(body.size())) == ESP_OK;
}
Json post(const char* url, const std::string& body, bool oauth, int& status) {
  status = 0;
  if (speaking.load() || !wifi_up.load()) return Json(nullptr, cJSON_Delete);
  Response response;
  // A dispatched refresh consumes the old token: finish receiving and storing its successor before pausing.
  response.oauth = oauth;
  esp_http_client_config_t cfg = {};
  cfg.url = url;
  cfg.method = HTTP_METHOD_POST;
  cfg.timeout_ms = 5000;
  cfg.disable_auto_redirect = true;
  cfg.crt_bundle_attach = esp_crt_bundle_attach;
  cfg.event_handler = http_event;
  cfg.user_data = &response;
  cfg.is_async = true;
  cfg.buffer_size_tx = 2048;
  auto client = esp_http_client_init(&cfg);
  if (!client) return Json(nullptr, cJSON_Delete);
  if (!setup_request(client, body, oauth)) {
    esp_http_client_cleanup(client);
    return Json(nullptr, cJSON_Delete);
  }
  const esp_err_t rc = transfer(client, response.epoch, oauth);
  status = esp_http_client_get_status_code(client);
  esp_http_client_cleanup(client);
  if (rc != ESP_OK || response.overflow || response.epoch != grant_epoch.load()) return Json(nullptr, cJSON_Delete);
  return parse_http(response.body, response.content_type);
}
bool token() {
  if (!access_token.empty() && int32_t(access_until - now_ms()) > 60000) return true;
  if (client_id.empty() || refresh_token.empty()) return false;
  const std::string body = "grant_type=refresh_token&client_id=" + form(client_id) + "&refresh_token=" + form(refresh_token) + "&resource=" + form(kMcpURL);
  int status;
  auto j = post(kTokenURL, body, true, status);
  if (!j || status != 200) {
    if (j && text(j.get(), "error") == "invalid_grant") {
      refresh_token.clear();
      std::lock_guard<std::mutex> g(lock);
      view.authorized = false;
      view.error = "reauthorize";
    } else error("token_unavailable");
    return false;
  }
  const std::string next = text(j.get(), "refresh_token");
  const std::string access = text(j.get(), "access_token");
  int64_t ttl;
  if (access.empty() || next.empty() || !integer(j.get(), "expires_in", ttl, 61, 86400)) { error("invalid_token_response"); return false; }
  auto grant = object();
  cJSON_AddStringToObject(grant.get(), "generation", generation.c_str());
  cJSON_AddStringToObject(grant.get(), "client_id", client_id.c_str());
  cJSON_AddStringToObject(grant.get(), "refresh_token", next.c_str());
  if (!save_rotated_grant(encode(grant.get()))) {
    // The server already rotated the refresh token: never pretend the old token can recover.
    refresh_token.clear();
    std::lock_guard<std::mutex> g(lock);
    view.authorized = false;
    view.error = "reauthorize_storage";
    return false;
  }
  refresh_token = next;
  access_token = access;
  access_until = now_ms() + uint32_t(ttl) * 1000;
  return true;
}
Json call(const char* name, cJSON* args) {
  Json arguments(args, cJSON_Delete);
  if (!token()) return Json(nullptr, cJSON_Delete);
  auto j = object();
  cJSON_AddStringToObject(j.get(), "jsonrpc", "2.0");
  cJSON_AddNumberToObject(j.get(), "id", 1);
  cJSON_AddStringToObject(j.get(), "method", "tools/call");
  auto* params = cJSON_AddObjectToObject(j.get(), "params");
  cJSON_AddStringToObject(params, "name", name);
  cJSON_AddItemToObject(params, "arguments", arguments.release());
  int status;
  auto response = post(kMcpURL, encode(j.get()), false, status);
  if (status == 401) access_token.clear();
  const auto* result = field(response.get(), "result");
  if (!response || status != 200 || !cJSON_IsObject(result) || cJSON_IsTrue(field(result, "isError"))) {
    if (!speaking.load()) error("sync_failed");
    return Json(nullptr, cJSON_Delete);
  }
  const auto* structured = field(result, "structuredContent");
  if (cJSON_IsObject(structured)) return Json(cJSON_Duplicate(structured, true), cJSON_Delete);
  const auto* content = cJSON_GetArrayItem(field(result, "content"), 0);
  return parse(text(content, "text"));
}

// Read-only health overview; kept in memory only, so a reboot shows "loading" until the next poll.
// 同一次调用带上设备状态,iPhone 经 desk_status 读最近一次上报。
void monitor() {
  auto args = object();
  cJSON_AddStringToObject(args.get(), "firmware", firmware.c_str());
  cJSON_AddBoolToObject(args.get(), "muted", uplink::muted());
  cJSON_AddBoolToObject(args.get(), "mac", uplink::snapshot().live);
  dms::add_report(args.get());
  auto out = call("desk_monitor", args.release());
  if (!out) return;
  display::Monitor m;
  if (!wirejson::monitor(out.get(), m)) { error("invalid_monitor"); return; }
  error("");
  std::lock_guard<std::mutex> g(lock);
  view.monitor = std::move(m);
  view.monitor_ms = now_ms();
}

void wifi_event(void*, esp_event_base_t base, int32_t id, void* data) {
  if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) { wifi_up.store(true); wifi_reason.store(0); }
  if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
    const auto reason = static_cast<wifi_event_sta_disconnected_t*>(data)->reason;
    ESP_LOGI("cloud", "wifi down reason %u", unsigned(reason));
    wifi_up.store(false);
    // Our own disconnect (reconfigure, scan) already scheduled the next join; a rare AP-side 8 rejoins
    // once 30 s have passed since the last esp_wifi_connect.
    if (reason != WIFI_REASON_ASSOC_LEAVE) { wifi_dropped.store(true); wifi_reason.store(reason); }
  }
}
bool configure_wifi(const cJSON* j) {
  if (!valid_wifi(j)) return false;
  const auto ssid = text(j, "ssid"), password = text(j, "password");
  wifi_config_t cfg = {};
  memcpy(cfg.sta.ssid, ssid.data(), ssid.size());
  memcpy(cfg.sta.password, password.data(), password.size());
  cfg.sta.threshold.authmode = password.empty() ? WIFI_AUTH_OPEN : WIFI_AUTH_WPA2_PSK;
  if (wifi_started) { esp_wifi_disconnect(); wifi_up.store(false); }
  if (esp_wifi_set_config(WIFI_IF_STA, &cfg) != ESP_OK) return false;
  if (!wifi_started) {
    if (esp_wifi_start() != ESP_OK) return false;
    wifi_started = true;
  }
  next_connect = now_ms();
  backoff = 2000;  // new credentials: don't inherit the wrong password's 30 s wait
  wifi_reason.store(0);
  return true;
}
void apply_grant(const cJSON* j) {
  client_id = text(j, "client_id");
  refresh_token = text(j, "refresh_token");
  generation = text(j, "generation");
  access_token.clear();
  // A new device grant can belong to another account; never display the previous account's data.
  // Persisted state is bound to this generation; stale keys cannot load after a power loss.
  std::lock_guard<std::mutex> g(lock);
  ++view.generation;
  view.monitor = {};
  view.monitor_ms = 0;
  view.notices = {};
  view.authorized = !refresh_token.empty();
  view.error = "";
  queued_token.clear(); queued_action.clear();  // the token belongs to the previous account
  view.operation.clear();
}
void pending() {
  std::string net, grant;
  {
    std::lock_guard<std::mutex> g(lock);
    net.swap(queued_wifi); grant.swap(queued_grant);
  }
  if (!net.empty()) {
    auto j = parse(net);
    if (!configure_wifi(j.get())) error("wifi_configuration_failed");
  }
  if (!grant.empty()) {
    auto j = parse(grant);
    apply_grant(j.get());
  }
}
// Scans run here, never on the BLE task; nothing is persisted.
void scan() {
  if (!scan_wanted.exchange(false)) return;
  std::vector<Network> found;
  // An unconfigured device starts Wi-Fi only for this scan; a station still joining rejects scans.
  const bool configured = wifi_started, joining = configured && !wifi_up.load();
  if (!wifi_started && esp_wifi_start() == ESP_OK) wifi_started = true;
  if (joining) esp_wifi_disconnect();
  wifi_scan_config_t cfg = {};
  if (wifi_started && esp_wifi_scan_start(&cfg, true) == ESP_OK) {
    uint16_t n = 20;
    std::vector<wifi_ap_record_t> aps(n);
    if (esp_wifi_scan_get_ap_records(&n, aps.data()) == ESP_OK) {
      for (uint16_t i = 0; i < n; ++i) {
        const auto mode = aps[i].authmode;
        // Enterprise networks need credentials this device cannot accept.
        if (mode == WIFI_AUTH_WPA2_ENTERPRISE || mode == WIFI_AUTH_WPA3_ENT_192 || mode == WIFI_AUTH_WPA3_ENTERPRISE ||
            mode == WIFI_AUTH_WPA2_WPA3_ENTERPRISE || mode == WIFI_AUTH_WPA_ENTERPRISE) continue;
        found.push_back({reinterpret_cast<const char*>(aps[i].ssid), aps[i].rssi, mode != WIFI_AUTH_OPEN});
      }
    } else {
      esp_wifi_clear_ap_list();
    }
  }
  if (joining) next_connect = now_ms();  // resume the interrupted join on this cycle
  if (!configured && wifi_started && esp_wifi_stop() == ESP_OK) wifi_started = false;
  std::lock_guard<std::mutex> g(lock);
  networks = network_list(++scan_count, found);
}
void load_state() {
  auto net = parse(load("wifi", 512));
  if (net) configure_wifi(net.get());
  auto grant = parse(load("grant", 512));
  if (grant) {
    client_id = text(grant.get(), "client_id"); refresh_token = text(grant.get(), "refresh_token");
    generation = text(grant.get(), "generation");
    std::lock_guard<std::mutex> g(lock);
    view.authorized = !client_id.empty() && !refresh_token.empty();
  }
}
// The queued operation stays set while in flight so a second long press is refused, not stacked.
// Returns true when it ran, so the caller refreshes desk_monitor soon after.
bool operation(uint32_t now, bool online) {
  std::string token, action, message;
  uint32_t at;
  {
    std::lock_guard<std::mutex> g(lock);
    if (queued_token.empty()) return false;
    token = queued_token, action = queued_action, at = queued_ms;
  }
  // Signed: `at` may be stamped by the main task just after this worker read `now`.
  const bool stale = int32_t(now - at) > 30000;  // offline too long: the user has moved on
  if (stale) {
    message = "未送达，请重试";
  } else {
    if (!online) return false;
    auto args = object();
    cJSON_AddStringToObject(args.get(), "token", token.c_str());
    cJSON_AddStringToObject(args.get(), "action", action.c_str());
    auto out = call("desk_operate", args.release());
    message = out ? text(out.get(), "message") : "";
    if (message.empty() || message.size() > 60 || !utf8(message)) message = "操作失败，稍后重试";
  }
  std::lock_guard<std::mutex> g(lock);
  queued_token.clear(); queued_action.clear();
  view.operation = message;
  view.operation_ms = now_ms();
  return !stale;
}
void network_cycle(uint32_t now) {
  static uint32_t next_monitor = 0;
  // Boot-time BLE pairing often starves the first auth (coex); retry in 2 s, doubling to 30 s while the AP stays away.
  if (wifi_up.load()) {
    backoff = 2000;
  } else if (wifi_dropped.exchange(false)) {
    next_connect = now + backoff;
    backoff = backoff < 15000 ? backoff * 2 : 30000;
  }
  if (wifi_started && !wifi_up.load() && int32_t(now - next_connect) >= 0) {
    next_connect = now + 30000;  // fallback if no disconnect event arrives
    esp_wifi_connect();
  }
  const bool online = wifi_up.load() && !refresh_token.empty() && std::time(nullptr) > 1609459200;
  if (!speaking.load() && operation(now, online)) next_monitor = now + 2000;  // show the new task state soon
  if (online) {
    if (!speaking.load() && int32_t(now - next_monitor) >= 0) { next_monitor = now + 60000; monitor(); }
  }
}
bool initialize() {
  diagnostics::heap("cloud initialize");
#if CONFIG_MBEDTLS_EXTERNAL_MEM_ALLOC
  ESP_LOGI("heap", "TLS allocator=PSRAM input=%u output=%u response_max=%u",
           unsigned(CONFIG_MBEDTLS_SSL_IN_CONTENT_LEN), unsigned(CONFIG_MBEDTLS_SSL_OUT_CONTENT_LEN),
           unsigned(kResponseMax));
#endif
  if (nvs_open("deskcloud", NVS_READWRITE, &storage) != ESP_OK) { error("storage_failed"); return false; }
  storage_ready.store(true);
  if (esp_netif_init() != ESP_OK || esp_event_loop_create_default() != ESP_OK) { error("network_init_failed"); return false; }
  if (!esp_netif_create_default_wifi_sta()) { error("network_init_failed"); return false; }
  wifi_init_config_t init = WIFI_INIT_CONFIG_DEFAULT();
  diagnostics::heap("WiFi before init");
  // Keep ESP-IDF's default WIFI_PS_MIN_MODEM: Wi-Fi and BLE share one radio, and modem sleep lets the
  // AP buffer while BLE audio uses the air. WIFI_PS_NONE starved BLE on a busy office AP (2026-11-07:
  // 27 of ~500 frames in 30 s while associated, 997/997 while not).
  if (esp_wifi_init(&init) != ESP_OK || esp_wifi_set_storage(WIFI_STORAGE_RAM) != ESP_OK ||
      esp_wifi_set_mode(WIFI_MODE_STA) != ESP_OK) {
    diagnostics::heap("WiFi init failed");
    error("wifi_init_failed"); return false;
  }
  diagnostics::heap("WiFi init ready");
  if (esp_event_handler_register(WIFI_EVENT, WIFI_EVENT_STA_DISCONNECTED, wifi_event, nullptr) != ESP_OK ||
      esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, wifi_event, nullptr) != ESP_OK) {
    error("network_init_failed"); return false;
  }
  return true;
}
void worker(void*) {
  if (!initialize()) { storage_ready.store(false); vTaskDelete(nullptr); return; }
  load_state();
  esp_sntp_config_t sntp = ESP_NETIF_SNTP_DEFAULT_CONFIG("pool.ntp.org");
  if (esp_netif_sntp_init(&sntp) != ESP_OK) error("clock_init_failed");
  std::string last_status;
  for (;;) {
    const auto state = status();
    if (state != last_status) { uplink::publish_cloud_status(state); last_status = state; }
    dms::cycle(firmware, wifi_up.load(), speaking.load());
    if (!speaking.load()) {
      pending();
      scan();
      network_cycle(now_ms());
    }
    vTaskDelay(pdMS_TO_TICKS(100));
  }
}
}  // namespace

void start(const char* version) {
  firmware = version;
  if (xTaskCreatePinnedToCore(worker, "desk_cloud", 12288, nullptr, 2, nullptr, 0) != pdPASS) error("worker_start_failed");
}
void pause(bool on) { speaking.store(on); }

void identify_grant(cJSON* j) {
  char identity[17];
  snprintf(identity, sizeof identity, "%08x%08x", unsigned(esp_random()), unsigned(esp_random()));
  cJSON_DeleteItemFromObjectCaseSensitive(j, "generation");
  cJSON_AddStringToObject(j, "generation", identity);
}
bool provision(const char* bytes, size_t size) {
  if (!size || size > 512 || memchr(bytes, 0, size)) return false;
  auto j = parse(std::string(bytes, size));
  if (!j) return false;
  const auto op = text(j.get(), "op");
  if (op == "scan") { scan_wanted.store(true); return true; }
  if (op.rfind("dms", 0) == 0) return dms::provision(op, j.get());
  const bool valid = op == "wifi" ? valid_wifi(j.get()) : op == "grant" && valid_grant(j.get());
  if (!valid) return false;
  if (op == "grant") identify_grant(j.get());
  const auto payload = encode(j.get());
  if (!save(op == "wifi" ? "wifi" : "grant", payload)) return false;
  if (op == "grant") grant_epoch.fetch_add(1);
  std::lock_guard<std::mutex> g(lock);
  (op == "wifi" ? queued_wifi : queued_grant) = payload;
  view.error = "";
  return true;
}
std::string status() {
  auto j = object();
  std::lock_guard<std::mutex> g(lock);
  cJSON_AddBoolToObject(j.get(), "wifi_connected", wifi_up.load());
  cJSON_AddBoolToObject(j.get(), "authorized", view.authorized);
  cJSON_AddNumberToObject(j.get(), "wifi_scan", scan_count);
  cJSON_AddNumberToObject(j.get(), "wifi_reason", wifi_reason.load());
  cJSON_AddStringToObject(j.get(), "error", view.error.c_str());
  cJSON_AddNumberToObject(j.get(), "display_revision", 0);  // 0.2.0 Mac apps require it to accept cloud state
  dms::add_status(j.get());
  return encode(j.get());
}
std::string wifi_networks() {
  std::lock_guard<std::mutex> g(lock);
  return networks;
}
bool agent_card(const std::string& key, const std::string& title, const std::string& body, int ttl) {
  std::lock_guard<std::mutex> g(lock);
  return view.notices.put("agent", key, title, body, ttl, now_ms());
}
void clear_agent_cards() {
  std::lock_guard<std::mutex> g(lock);
  view.notices.clear_agent();
}
bool operate(const std::string& token, const std::string& action) {
  std::lock_guard<std::mutex> g(lock);
  if (!queued_token.empty() || token.empty() || action.empty()) return false;
  queued_token = token, queued_action = action, queued_ms = now_ms();
  view.operation = "正在提交";
  view.operation_ms = queued_ms;
  return true;
}
View snapshot() {
  std::lock_guard<std::mutex> g(lock);
  view.wifi_connected = wifi_up.load();
  view.notices.active(now_ms());
  return view;
}
}  // namespace cloud
