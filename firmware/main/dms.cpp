#include "dms.h"
#include "cloud.h"
#include "dms_wire.h"

#include <atomic>
#include <ctime>
#include <deque>
#include <mutex>

#include "esp_crt_bundle.h"
#include "esp_log.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "mic_state.h"
#include "mqtt_client.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "psa/crypto.h"
#include "uplink.h"

namespace dms {
namespace {
constexpr const char* kTag = "dms";
using namespace dmswire;
using wirejson::text;

uint32_t now_ms() { return uint32_t(esp_timer_get_time() / 1000); }
void wipe(void* p, size_t n) {
  for (auto* v = static_cast<volatile uint8_t*>(p); n--;) *v++ = 0;
}
nvs_handle_t storage() {
  static const nvs_handle_t h = [] {
    nvs_handle_t x = 0;
    return nvs_open("deskcloud", NVS_READWRITE, &x) == ESP_OK ? x : 0;
  }();
  return h;
}

// 出厂私钥每次签名现读现清;常驻内存的只有证书。
bool sign(const std::string& message, uint8_t sig[64]) {
  if (identity_cert().empty()) return false;  // 同时完成 fac 分区初始化
  uint8_t key[32];
  size_t n = sizeof key;
  nvs_handle_t h;
  if (nvs_open_from_partition("fac", "fac", NVS_READONLY, &h) != ESP_OK) return false;
  const bool loaded = nvs_get_blob(h, "key", key, &n) == ESP_OK && n == sizeof key;
  nvs_close(h);
  bool ok = false;
  if (loaded && psa_crypto_init() == PSA_SUCCESS) {
    psa_key_attributes_t attr = PSA_KEY_ATTRIBUTES_INIT;
    psa_set_key_type(&attr, PSA_KEY_TYPE_ECC_KEY_PAIR(PSA_ECC_FAMILY_SECP_R1));
    psa_set_key_bits(&attr, 256);
    psa_set_key_usage_flags(&attr, PSA_KEY_USAGE_SIGN_HASH);
    psa_set_key_algorithm(&attr, PSA_ALG_ECDSA(PSA_ALG_SHA_256));
    psa_key_id_t k;
    if (psa_import_key(&attr, key, sizeof key, &k) == PSA_SUCCESS) {
      uint8_t digest[32];
      size_t len = 0;
      ok = psa_hash_compute(PSA_ALG_SHA_256, reinterpret_cast<const uint8_t*>(message.data()), message.size(), digest,
                            sizeof digest, &len) == PSA_SUCCESS &&
           psa_sign_hash(k, PSA_ALG_ECDSA(PSA_ALG_SHA_256), digest, sizeof digest, sig, 64, &len) == PSA_SUCCESS &&
           len == 64;
      psa_destroy_key(k);
    }
  }
  wipe(key, sizeof key);
  return ok;
}
std::string sha256_hex(const std::string& s) {
  uint8_t d[32];
  size_t len = 0;
  if (psa_crypto_init() != PSA_SUCCESS ||
      psa_hash_compute(PSA_ALG_SHA_256, reinterpret_cast<const uint8_t*>(s.data()), s.size(), d, sizeof d, &len) != PSA_SUCCESS)
    return {};
  constexpr char hex[] = "0123456789abcdef";
  std::string out;
  for (uint8_t b : d) { out += hex[b >> 4]; out += hex[b & 15]; }
  return out;
}

// BLE host 任务与云端任务共享,lock 保护。
std::mutex lock;
Credential cred;
bool bound = false;
uint32_t generation = 0;               // 凭据换了或清了就加一,云端任务据此断开旧连接
std::string sign_id, sign_challenge;   // 待签
std::string signed_id, proof;          // 已签,等 Mac 取走后下发 dms
std::deque<std::string> inbox;         // MQTT 任务收进来的 cmd/down

// MQTT 任务写、云端任务读。
std::atomic<bool> connected{false}, subscribed{false}, dead{false}, refused{false}, hello{false}, acked{false};
std::atomic<int> awaited{0};  // msg_id 是随机的:只认正在等的那一条 PUBACK

// 开机读一次 NVS 里的凭据;BLE 写入可能先于云端任务到,两边都先过这里。
void load() {
  static const bool once = [] {
    size_t n = 0;
    if (!storage() || nvs_get_str(storage(), "dms", nullptr, &n) != ESP_OK || !n || n > 1024) return true;
    std::string s(n, '\0');
    if (nvs_get_str(storage(), "dms", s.data(), &n) != ESP_OK) return true;
    s.resize(n - 1);
    auto j = wirejson::parse(s);
    Credential c;
    if (!credential(j.get(), c)) return true;
    std::lock_guard<std::mutex> g(lock);
    cred = c;
    bound = true;
    ++generation;
    return true;
  }();
  (void)once;
}

bool save(const Credential& c) {
  auto j = wirejson::object();
  cJSON_AddStringToObject(j.get(), "device_id", c.device_id.c_str());
  cJSON_AddStringToObject(j.get(), "core_id", c.core_id.c_str());
  cJSON_AddStringToObject(j.get(), "secret", c.secret.c_str());
  cJSON_AddStringToObject(j.get(), "mqtt_url", c.mqtt_url.c_str());
  cJSON_AddStringToObject(j.get(), "command_topic", c.command_topic.c_str());
  cJSON_AddNumberToObject(j.get(), "since", double(c.since));
  const auto s = wirejson::encode(j.get());
  return storage() && nvs_set_str(storage(), "dms", s.c_str()) == ESP_OK && nvs_commit(storage()) == ESP_OK;
}
// dms_reset 与 unbind 共用:先删存储再改内存,掉电也不会留下凭据;断开与 bye 由云端任务做。
bool forget() {
  const esp_err_t rc = storage() ? nvs_erase_key(storage(), "dms") : ESP_FAIL;
  if ((rc != ESP_OK && rc != ESP_ERR_NVS_NOT_FOUND) || nvs_commit(storage()) != ESP_OK) return false;
  {
    std::lock_guard<std::mutex> g(lock);
    bound = false;
    cred = {};
    ++generation;
    sign_id.clear(); sign_challenge.clear(); signed_id.clear(); proof.clear();
    inbox.clear();
    refused.store(false);
  }
  // agent 卡片属于这次网盘绑定。放锁之后再清:cloud::status() 持 cloud 锁再取 dms 锁。
  cloud::clear_agent_cards();
  return true;
}
// 以下只在云端任务里用(MQTT 回调只碰原子量、inbox 与开连接前定下的 down_topic)。
esp_mqtt_client_handle_t client = nullptr;
uint32_t client_generation = 0;
std::string down_topic, up_topic, presence_topic, state_topic, boot_id;
uint32_t next_try = 0, backoff = 2000, next_presence = 0;
int64_t since = 0;
Seen seen;

void on_event(void*, esp_event_base_t, int32_t id, void* data) {
  const auto* e = static_cast<esp_mqtt_event_t*>(data);
  switch (esp_mqtt_event_id_t(id)) {
    case MQTT_EVENT_CONNECTED:
      refused.store(false);
      connected.store(true);
      hello.store(true);
      break;
    case MQTT_EVENT_ERROR:
      // CONNACK 4/5:用户名或口令被拒,多半是凭据已被重置(重新 provision 或网盘侧解绑)。
      if (e->error_handle && e->error_handle->error_type == MQTT_ERROR_TYPE_CONNECTION_REFUSED) {
        const auto rc = e->error_handle->connect_return_code;
        if (rc == MQTT_CONNECTION_REFUSE_BAD_USERNAME || rc == MQTT_CONNECTION_REFUSE_NOT_AUTHORIZED) refused.store(true);
      }
      connected.store(false);
      dead.store(true);
      break;
    case MQTT_EVENT_DISCONNECTED:
      connected.store(false);
      dead.store(true);
      break;
    case MQTT_EVENT_SUBSCRIBED:
      // SUBACK 0x80 也走这里;订阅被拒就当连接失败重连,不报 online(否则指令全丢)。
      if (e->error_handle && e->error_handle->error_type == MQTT_ERROR_TYPE_SUBSCRIBE_FAILED) dead.store(true);
      else subscribed.store(true);
      break;
    case MQTT_EVENT_PUBLISHED:
      if (e->msg_id == awaited.load()) acked.store(true);
      break;
    case MQTT_EVENT_DATA: {
      // 订阅 ah/{dev}/# 会收到自己发的 cmd/up 等回显;只有 cmd/down 是指令。分片的大消息丢掉。
      // 整包(含主题)要装进 cfg.buffer.size 才不分片,载荷实际上限约 1900 字节;509 字节中文转义后约 1.1 KB。
      if (e->current_data_offset != 0 || e->data_len != e->total_data_len || e->data_len > 2048 ||
          std::string(e->topic, size_t(e->topic_len)) != down_topic) break;
      std::lock_guard<std::mutex> g(lock);
      if (client_generation == generation && inbox.size() < 8) inbox.emplace_back(e->data, size_t(e->data_len));
      break;
    }
    default:
      break;
  }
}
void close_client() {
  if (!client) return;
  esp_mqtt_client_destroy(client);  // 先停任务再释放
  client = nullptr;
  connected.store(false);
  subscribed.store(false);
}
// enqueue 不在调用方阻塞网络;QoS 1 等 PUBACK:bye 与 unbind 的回复发出去之后才能断开。
bool publish_acked(const std::string& topic, const std::string& payload) {
  awaited.store(0);
  acked.store(false);
  const int id = esp_mqtt_client_enqueue(client, topic.c_str(), payload.data(), int(payload.size()), 1, 0, true);
  if (id <= 0) return false;
  awaited.store(id);  // 入队只进 outbox,PUBACK 至少隔一个往返,来不及抢在这之前
  for (int i = 0; i < 30 && connected.load(); ++i) {
    if (acked.load()) return true;
    vTaskDelay(pdMS_TO_TICKS(100));
  }
  return false;
}
void publish(const std::string& topic, const cJSON* j) {
  const auto s = wirejson::encode(j);
  esp_mqtt_client_enqueue(client, topic.c_str(), s.data(), int(s.size()), 1, 0, true);
}
void presence(const std::string& firmware, bool online, const char* reason = nullptr) {
  auto j = wirejson::object();
  cJSON_AddBoolToObject(j.get(), "online", online);
  if (online) cJSON_AddStringToObject(j.get(), "fw", firmware.c_str());
  if (reason) cJSON_AddStringToObject(j.get(), "reason", reason);
  cJSON_AddStringToObject(j.get(), "boot_id", boot_id.c_str());
  if (online) publish(presence_topic, j.get());
  else publish_acked(presence_topic, wirejson::encode(j.get()));
}
std::string ssid() {
  wifi_config_t cfg = {};
  if (esp_wifi_get_config(WIFI_IF_STA, &cfg) != ESP_OK) return {};
  return std::string(reinterpret_cast<const char*>(cfg.sta.ssid), strnlen(reinterpret_cast<const char*>(cfg.sta.ssid), 32));
}
// 网络名上云只发 SSID,密码留在设备。连上(含换网后重连)时发一次。
void report_wifi(const std::string& firmware) {
  auto j = wirejson::object();
  auto* wifi = cJSON_AddObjectToObject(j.get(), "wifi");
  cJSON_AddStringToObject(wifi, "ssid", ssid().c_str());
  cJSON_AddStringToObject(j.get(), "fw", firmware.c_str());
  publish(state_topic, j.get());
}
void reply(const std::string& id, const char* result, const char* detail, cJSON* output = nullptr) {
  auto j = wirejson::object();
  cJSON_AddStringToObject(j.get(), "message_id", id.c_str());
  cJSON_AddStringToObject(j.get(), "result", result);
  cJSON_AddStringToObject(j.get(), "detail", detail);
  if (output) cJSON_AddItemToObject(j.get(), "output", output);
  cJSON_AddNumberToObject(j.get(), "ts", double(std::time(nullptr)));
  publish_acked(up_topic, wirejson::encode(j.get()));
}
void dispatch(const std::string& firmware, const std::string& body, uint32_t gen) {
  auto m = wirejson::parse(body);
  const auto verdict = judge(m.get(), std::time(nullptr), since, seen);
  if (verdict == Verdict::drop) return;
  const auto id = text(m.get(), "message_id"), action = text(m.get(), "action");
  ESP_LOGI(kTag, "command %s", action.size() <= 32 ? action.c_str() : "?");
  if (verdict == Verdict::expired) return reply(id, "REJECTED", "EXPIRED");
  if (action == "get_status") {
    auto* out = cJSON_CreateObject();
    cJSON_AddStringToObject(out, "fw", firmware.c_str());
    cJSON_AddBoolToObject(out, "muted", uplink::muted());
    cJSON_AddStringToObject(out, "ssid", ssid().c_str());
    return reply(id, "OK", "", out);
  }
  if (action == "mute") {  // 只能静音:云端不能替用户开麦,与 yahaops 的 mute 一致
    mic::set_muted(true);
    return reply(id, "OK", "");
  }
  if (action == "card") {  // 下发方只给文字,固件自己校验后显示
    Card c;
    if (!card(m.get(), c)) return reply(id, "REJECTED", "INVALID_ARGS");
    if (c.clear) cloud::clear_agent_cards();
    else if (!cloud::agent_card(id, c.title, c.body, c.ttl)) return reply(id, "REJECTED", "INVALID_ARGS");
    bool stale;
    {
      std::lock_guard<std::mutex> g(lock);
      stale = generation != gen;
    }
    if (stale) cloud::clear_agent_cards();  // 显示时 BLE 恰好解绑或重绑:forget() 的清卡可能抢在前面
    return reply(id, "OK", "");
  }
  if (action == "unbind") {
    reply(id, "OK", "");
    if (!forget()) ESP_LOGE(kTag, "unbind: storage failed");
    return;
  }
  reply(id, "REJECTED", "ACTION_NOT_SUPPORTED");
}
bool open_client(const Credential& c, uint32_t gen) {
  Broker b;
  if (!broker(c.mqtt_url, b)) return false;
  const int64_t ts = std::time(nullptr);
  const auto user = username(c, ts), pass = sha256_hex(password_input(c, ts));
  if (pass.empty()) return false;
  down_topic = c.command_topic;
  up_topic = topic(c, "cmd/up");
  presence_topic = topic(c, "presence");
  state_topic = topic(c, "state/reported");
  since = c.since;
  esp_mqtt_client_config_t cfg = {};
  cfg.broker.address.hostname = b.host.c_str();
  cfg.broker.address.port = b.port;
  cfg.broker.address.transport = MQTT_TRANSPORT_OVER_SSL;
  cfg.broker.verification.crt_bundle_attach = esp_crt_bundle_attach;
  cfg.credentials.client_id = c.device_id.c_str();
  cfg.credentials.username = user.c_str();
  cfg.credentials.authentication.password = pass.c_str();  // init 复制所有字符串
  cfg.session.keepalive = 60;
  cfg.session.protocol_ver = MQTT_PROTOCOL_V_3_1_1;
  cfg.session.disable_clean_session = true;  // 持久会话:离线时的 QoS 1 指令重连后补收
  cfg.network.disable_auto_reconnect = true;  // 口令带时间戳,每次重连都要新建客户端重算
  cfg.network.timeout_ms = 10000;
  cfg.buffer.size = 2048;
  {
    std::lock_guard<std::mutex> g(lock);
    client_generation = gen;
  }
  client = esp_mqtt_client_init(&cfg);
  if (!client) return false;
  dead.store(false);
  hello.store(false);
  if (esp_mqtt_client_register_event(client, MQTT_EVENT_ANY, on_event, nullptr) != ESP_OK ||
      esp_mqtt_client_start(client) != ESP_OK) {
    close_client();
    return false;
  }
  return true;
}
}  // namespace

const std::string& identity_cert() {
  static const std::string cert = [] {
    // 只读打开;分区缺失或格式不对就当没有出厂身份,绝不擦除(空白分区 init 会写页头,烧 fac.bin 时覆盖)。
    const esp_err_t rc = nvs_flash_init_partition("fac");
    nvs_handle_t h;
    if (rc != ESP_OK || nvs_open_from_partition("fac", "fac", NVS_READONLY, &h) != ESP_OK) return std::string();
    size_t n = 0;
    std::string der;
    if (nvs_get_blob(h, "cert", nullptr, &n) == ESP_OK && n && n <= 512) {
      der.resize(n);
      if (nvs_get_blob(h, "cert", der.data(), &n) != ESP_OK) der.clear();
    }
    nvs_close(h);
    return der;
  }();
  return cert;
}

bool provision(const std::string& op, const cJSON* j) {
  load();
  if (op == "dms_reset") return forget();
  if (op == "dms_proof") {
    const auto dev = text(j, "device_id"), challenge = text(j, "challenge");
    if (!device_id(dev) || !b64url(challenge, 16, 128) || identity_cert().empty()) return false;
    std::lock_guard<std::mutex> g(lock);
    sign_id = dev;
    sign_challenge = challenge;
    signed_id.clear();
    proof.clear();
    return true;
  }
  if (op != "dms") return false;
  Credential c;
  if (!credential(j, c)) return false;
  {
    // 只收刚签过名的设备号:凭据是用这次签名换来的。
    std::lock_guard<std::mutex> g(lock);
    if (signed_id.empty() || c.device_id != signed_id) return false;
  }
  const int64_t now = std::time(nullptr);
  c.since = now >= kTimeOk ? now : 0;  // 对时前收到的,首次连上时补记
  if (!save(c)) return false;
  {
    std::lock_guard<std::mutex> g(lock);
    cred = c;
    bound = true;
    ++generation;
    signed_id.clear();
    proof.clear();
    refused.store(false);
  }
  cloud::clear_agent_cards();  // 可能换了网盘账号,同 forget()
  return true;
}

void cycle(const std::string& firmware, bool wifi_up, bool speaking) {
  load();
  if (boot_id.empty()) {
    char id[17];
    snprintf(id, sizeof id, "%08lx%08lx", (unsigned long)esp_random(), (unsigned long)esp_random());
    boot_id = id;
  }
  std::string dev, challenge;
  {
    std::lock_guard<std::mutex> g(lock);
    dev.swap(sign_id);
    challenge.swap(sign_challenge);
  }
  if (!dev.empty()) {
    uint8_t sig[64];
    const bool ok = sign(proof_message(dev, challenge), sig);
    if (!ok) ESP_LOGE(kTag, "proof: signing failed");
    std::lock_guard<std::mutex> g(lock);
    if (ok && sign_id.empty()) {  // 签名期间又来了新的 dms_proof 就作废这一份
      signed_id = dev;
      proof = b64url_encode(sig, sizeof sig);
    }
    wipe(sig, sizeof sig);
  }

  Credential c;
  bool have;
  uint32_t gen;
  {
    std::lock_guard<std::mutex> g(lock);
    c = cred;
    have = bound;
    gen = generation;
  }
  const uint32_t now = now_ms();
  if (client && client_generation != gen) {
    if (connected.load()) presence(firmware, false, "reset");  // 解绑或换凭据:服务端没有遗嘱,主动下线
    close_client();
    next_try = now;
    backoff = 2000;
  }
  // 讲话时断开:长连接的 keepalive 与 TLS 记录和 BLE 音频抢同一个射频,2026-11-06 真机送声掉到 0–5 帧/s。
  // 指令留在服务端(持久会话 + QoS 1),静音满 10 秒再重连收取,连按讲话键不会反复握手。
  if (speaking) {
    // 关掉在线连接时 next_try 是很久前的值,直接重设;没连上时只往后推,不缩短失败退避。
    if (client) { close_client(); next_try = now + 10000; }
    else if (int32_t(now + 10000 - next_try) > 0) next_try = now + 10000;
  }
  if (client && dead.load()) {
    close_client();
    next_try = now + backoff;
    backoff = backoff < 30000 ? backoff * 2 : 60000;
    if (refused.load()) ESP_LOGW(kTag, "mqtt refused, waiting for rebind");
    else ESP_LOGW(kTag, "mqtt down, retry in %u s", unsigned((next_try - now) / 1000));
  }
  // 凭据被拒(网盘侧已解绑或换过凭据)就不再重连:每次重试都是一次 TLS 握手,内部 RAM 吃紧。
  // 重新 provision、dms_reset 或重启后再试。
  if (!client && have && !refused.load() && wifi_up && !speaking && std::time(nullptr) >= kTimeOk &&
      int32_t(now - next_try) >= 0) {
    if (!c.since) {
      c.since = std::time(nullptr);
      if (save(c)) {
        std::lock_guard<std::mutex> g(lock);
        if (generation == gen) cred.since = c.since;
      }
    }
    if (!open_client(c, gen)) {
      ESP_LOGE(kTag, "mqtt client failed");
      next_try = now + 60000;
    }
  }
  if (!client || !connected.load()) return;
  if (hello.exchange(false)) {
    const auto all = "ah/" + c.device_id + "/#";
    if (esp_mqtt_client_subscribe_single(client, all.c_str(), 1) < 0) dead.store(true);
    report_wifi(firmware);
    next_presence = now;
  }
  if (subscribed.load()) backoff = 2000;  // 订阅确认才算连好:被拒的订阅照常退避,不每 2 秒重连
  if (int32_t(now - next_presence) >= 0) {
    next_presence = now + 60000;  // 服务端 TTL 180 秒
    presence(firmware, true);
  }
  std::string body;
  {
    std::lock_guard<std::mutex> g(lock);
    if (inbox.empty()) return;
    body.swap(inbox.front());
    inbox.pop_front();
  }
  dispatch(firmware, body, gen);  // gen 在出队前读:之后若有 forget(),它会清空 inbox
}

void add_status(cJSON* j) {
  load();
  std::lock_guard<std::mutex> g(lock);
  const char* state = link_state(bound, connected.load() && client_generation == generation, subscribed.load(), refused.load());
  cJSON_AddStringToObject(j, "dms", state);
  cJSON_AddStringToObject(j, "device_id", bound ? cred.device_id.c_str() : signed_id.c_str());
  cJSON_AddStringToObject(j, "proof", proof.c_str());
}

void add_report(cJSON* j) {
  std::string name = ssid();
  if (wirejson::utf8(name)) cJSON_AddStringToObject(j, "ssid", name.c_str());
  load();
  std::lock_guard<std::mutex> g(lock);
  if (!bound) return;
  cJSON_AddStringToObject(j, "dms", link_state(bound, connected.load() && client_generation == generation, subscribed.load(), refused.load()));
  cJSON_AddStringToObject(j, "pan_device", cred.device_id.c_str());
}
}  // namespace dms
