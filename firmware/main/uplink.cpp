#include "uplink.h"

#include <ctype.h>
#include <strings.h>

#include <atomic>
#include <cstring>
#include <mutex>

#include <psa/crypto.h>  // IDF 6.1 的 mbedtls 4.x:哈希走 PSA API

#include "esp_log.h"
#include "esp_mac.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "lwip/inet.h"
#include "lwip/ip4_addr.h"
#include "lwip/sockets.h"
#include "mdns.h"
#include "nvs.h"
#include "ssid_manager.h"
#include "wifi_manager.h"

// 报文(README「协议」一节是规范):UDP,小端,12 字节头 + 载荷。
//   头:magic 'Y'、version 1、type、flags(bit0=静音)、seq、ts(设备毫秒)
//   type 1 hello     设备→Mac  名字/固件/音频参数/(nonce+proof,配对码启用时)
//        2 welcome   Mac→设备  ok 1/0、主机名、(proof)
//        3 audio     设备→Mac  Opus 编码(16 kHz 单声道,60 ms 一帧,变长载荷)
//        4 status    设备→Mac  muted 1/0(静音时兼作心跳)
//        5 keepalive Mac→设备  空,1 Hz;5 秒收不到 → 重新握手
//        6 control   Mac→设备  muted 0/1(Fn push-to-talk 的遥控静音)
//        7 dashboard Mac→设备  10 字节小端:epoch u32 + tz i16(分钟) + cpu u8 +
//                              mem u8 + 鼠标电量 u8 + 键盘电量 u8,无效统一 255
// 配对码双向验证:proof = SHA256(配对码+nonce) 前 8 字节十六进制(方向不同,
// welcome 的 proof 再拼 "welcome"),这样既能防别人冒充 Mac 收流,也能防向
// Mac 注入假音频;不设配对码则互相直接放行。
namespace uplink {
namespace {

constexpr const char* kTag = "link";

constexpr uint8_t kHello = 1;
constexpr uint8_t kWelcome = 2;
constexpr uint8_t kAudio = 3;
constexpr uint8_t kStatus = 4;
constexpr uint8_t kKeepalive = 5;
constexpr uint8_t kControl = 6;
constexpr uint8_t kDashboard = 7;

constexpr uint32_t kHelloEveryMs = 500;      // 握手期间 hello 的间隔
constexpr uint32_t kDiscoverEveryMs = 3000;  // mDNS 查询间隔
constexpr uint32_t kHandshakeGiveUpMs = 10000;  // 这么久没 welcome → 重新发现
constexpr uint32_t kSilentLiveMs = 5000;     // live 时这么久没包 → 重新握手
constexpr uint32_t kMutedBeatMs = 1000;      // 静音状态心跳
constexpr uint32_t kWifiGiveUpMs = 60000;    // 一直连不上 Wi-Fi → 开配网
constexpr int kCmdQueue = 8;

struct __attribute__((packed)) Header {
  uint8_t magic;
  uint8_t version;
  uint8_t type;
  uint8_t flags;
  uint32_t seq;
  uint32_t ts;
};
static_assert(sizeof(Header) == 12, "wire header");

// type 7 载荷:设备端只做一次 epoch+tz 加法,时区用分钟才能覆盖 30/45 分钟偏移。
struct __attribute__((packed)) DashboardPayload {
  uint32_t epoch;       // Unix epoch 秒(UTC)
  int16_t tz_minutes;   // 时区偏移(分钟)
  uint8_t cpu;          // 0-100,255=无效
  uint8_t mem;          // 0-100,255=无效
  uint8_t mouse_batt;   // 0-100,255=无效
  uint8_t kb_batt;      // 0-100,255=无效
};
static_assert(sizeof(DashboardPayload) == 10, "wire dashboard");

enum class Command { WifiUp, WifiDown, OpenSetup };
struct Posted {
  Command command;
};

// —— worker 自己的状态(只有 worker 任务碰)——
int sock = -1;
sockaddr_in daemon_addr = {};
bool have_addr = false;        // mDNS 找到过(或缓存过)的地址
std::string daemon_label;      // mDNS 主机名(label,不带 .local)
uint16_t daemon_port = 0;
std::string host_label_cache;  // 记住上次发现的 label,重启后先直接试
uint16_t host_port_cache = 0;
uint32_t seq = 0;
uint32_t hello_at = 0, query_at = 0, last_rx_ms = 0, muted_beat_at = 0;
uint32_t wifi_down_since = 0;
uint32_t handshake_started = 0;
bool mdns_on = false;
bool discovering = false;   // 正在做 mDNS 查询
bool handshaking = false;   // 正在等 welcome
sockaddr_in static_addr = {};  // Kconfig 的静态 daemon 地址(逃生舱)
bool has_static = false;       // mDNS 没结果时回到它再试

// 配对码(配网页「配对码」字段,存 NVS wifi/ota_url)与 hello 的 nonce 记录。
std::string token;
char nonce_log[4][17] = {{0}};  // 最近发过的 nonce,校验 welcome 用(容忍乱序)
int nonce_next = 0;

std::string device_name;
std::string fw_version;

// —— 共享状态 ——
QueueHandle_t commands = nullptr;
std::recursive_mutex socket_lock;  // 发包与关socket 互斥
std::mutex info_lock;
bool setup_open = false;
char setup_ssid[33] = {0};
char setup_pass[16] = {0};
char daemon_text[24] = {0};
std::atomic<bool> live_{false};
std::atomic<bool> muted_{false};
std::atomic<bool> dump_pending{false};  // Mac 请求:回传一帧屏幕(排障/看 UI)
MuteCommand remote_mute;  // worker 线程里回调(main 注册)
std::mutex dash_lock;
Dashboard dash;  // 最近一次 type 7(供主循环轮询)

uint32_t now_ms() { return uint32_t(esp_timer_get_time() / 1000); }

std::string read_token() {
  nvs_handle_t nvs;
  if (nvs_open("wifi", NVS_READONLY, &nvs) != ESP_OK) return "";
  char value[64] = {0};
  size_t size = sizeof value;
  std::string out = nvs_get_str(nvs, "ota_url", value, &size) == ESP_OK ? value : "";
  nvs_close(nvs);
  // 配网页借道组件的 ota_url 存储:只当配对码用,长度也按配对码限制。
  if (out.size() >= size_t(sizeof value)) out.clear();
  return out;
}

void hex8(const uint8_t digest[32], char out[17]) {
  static const char* digits = "0123456789abcdef";
  for (int i = 0; i < 8; ++i) {
    out[i * 2] = digits[digest[i] >> 4];
    out[i * 2 + 1] = digits[digest[i] & 0xF];
  }
  out[16] = 0;
}

// proof = SHA256(token + nonce [+ suffix]) 的前 8 字节十六进制。
// IDF 6.1 带 mbedtls 4.x(SHA256 走 PSA Crypto API),与 Mac 端 CryptoKit 的
// SHA256 输出完全一致。
std::string proof_of(const std::string& nonce_hex, const char* suffix) {
  std::string in = token + nonce_hex + (suffix ? suffix : "");
  uint8_t digest[32];
  size_t digest_len = 0;
  if (psa_hash_compute(PSA_ALG_SHA_256, reinterpret_cast<const uint8_t*>(in.data()),
                       in.size(), digest, sizeof digest, &digest_len) != PSA_SUCCESS ||
      digest_len < 8)
    return "";
  char out[17];
  hex8(digest, out);
  return out;
}

bool send_packet(uint8_t type, uint8_t flags, const void* payload, size_t len) {
  if (sock < 0 || !have_addr) return false;
  uint8_t buf[1500];
  if (sizeof(Header) + len > sizeof buf) return false;
  auto* h = reinterpret_cast<Header*>(buf);
  h->magic = 'Y';
  h->version = 1;
  h->type = type;
  h->flags = flags;
  h->seq = ++seq;
  h->ts = now_ms();
  if (len) memcpy(buf + sizeof(Header), payload, len);
  std::lock_guard<std::recursive_mutex> guard(socket_lock);
  return lwip_sendto(sock, buf, sizeof(Header) + len, 0,
                     reinterpret_cast<sockaddr*>(&daemon_addr), sizeof daemon_addr) >= 0;
}

void new_nonce(char out[17]) {
  uint8_t raw[8];
  esp_fill_random(raw, sizeof raw);
  static const char* digits = "0123456789abcdef";
  for (int i = 0; i < 8; ++i) {
    out[i * 2] = digits[raw[i] >> 4];
    out[i * 2 + 1] = digits[raw[i] & 0xF];
  }
  out[16] = 0;
}

void send_hello() {
  char nonce[17] = {0};
  char payload[256];
  int n;
  if (!token.empty()) {
    new_nonce(nonce);
    strlcpy(nonce_log[nonce_next], nonce, sizeof nonce_log[0]);
    nonce_next = (nonce_next + 1) % 4;
    n = snprintf(payload, sizeof payload,
                 "name %s\nfw %s\nrate 16000\nch 1\nbits 16\nframe 60\ncodec opus\nnonce %s\nproof %s\n",
                 device_name.c_str(), fw_version.c_str(), nonce, proof_of(nonce, "").c_str());
  } else {
    n = snprintf(payload, sizeof payload, "name %s\nfw %s\nrate 16000\nch 1\nbits 16\nframe 60\ncodec opus\n",
                 device_name.c_str(), fw_version.c_str());
  }
  send_packet(kHello, 0, payload, size_t(n));
}

// "key value" 行里取值(值不含空格,所以够用)。
bool field(const char* text, const char* key, char* out, size_t out_size) {
  size_t klen = strlen(key);
  const char* at = text;
  while ((at = strstr(at, key)) != nullptr) {
    if (at[klen] == ' ') {
      const char* from = at + klen + 1;
      const char* to = strchr(from, '\n');
      if (!to) to = from + strlen(from);
      size_t len = size_t(to - from);
      if (len >= out_size) len = out_size - 1;
      memcpy(out, from, len);
      out[len] = 0;
      return true;
    }
    at += klen;
  }
  return false;
}

void set_live(bool on, const char* note) {
  bool was = live_.exchange(on);
  if (was != on) ESP_LOGI(kTag, "%s (%s)", on ? "live: yahamicd answered" : "link down", note);
}

void handle_datagram(const uint8_t* data, size_t len, const sockaddr_in& from) {
  if (len < sizeof(Header)) return;
  auto* h = reinterpret_cast<const Header*>(data);
  if (h->magic != 'Y' || h->version != 1) return;
  // 只认 yahamicd 的包:一个来源,防止局域网里别的包搅乱状态。
  if (!have_addr || from.sin_addr.s_addr != daemon_addr.sin_addr.s_addr ||
      from.sin_port != daemon_addr.sin_port)
    return;
  const char* payload = reinterpret_cast<const char*>(data + sizeof(Header));
  size_t payload_len = len - sizeof(Header);
  char text[192];
  size_t copy = payload_len < sizeof text - 1 ? payload_len : sizeof text - 1;
  memcpy(text, payload, copy);
  text[copy] = 0;

  if (h->type == kKeepalive) {
    last_rx_ms = now_ms();
    return;
  }
  if (h->type == kDashboard) {  // Mac 下发的仪表盘数据(二进制载荷,不走文本行)
    last_rx_ms = now_ms();
    if (payload_len < sizeof(DashboardPayload)) return;
    auto* p = reinterpret_cast<const DashboardPayload*>(data + sizeof(Header));
    std::lock_guard<std::mutex> guard(dash_lock);
    dash.epoch = p->epoch;
    dash.tz_offset_minutes = p->tz_minutes;
    dash.cpu = p->cpu;
    dash.mem = p->mem;
    dash.mouse_batt = p->mouse_batt;
    dash.kb_batt = p->kb_batt;
    dash.received_ms = last_rx_ms;
    dash.valid = true;
    return;
  }
  if (h->type == kControl) {  // Mac 遥控:静音 / 屏幕截图回传(排障)
    last_rx_ms = now_ms();
    char want[4] = {0};
    if (field(text, "muted", want, sizeof want)) {
      bool on = strcmp(want, "1") == 0;
      if (remote_mute) remote_mute(on);
    }
    char dump[4] = {0};
    if (field(text, "dump", dump, sizeof dump) && strcmp(dump, "1") == 0)
      dump_pending.store(true);
    return;
  }
  if (h->type != kWelcome) return;
  char ok[4] = {0};
  if (!field(text, "ok", ok, sizeof ok) || strcmp(ok, "1") != 0) {
    char err[64] = {0};
    field(text, "err", err, sizeof err);
    ESP_LOGW(kTag, "yahamicd refused: %s", err[0] ? err : "no reason given");
    last_rx_ms = now_ms();  // 是它,只是拒绝(多半是配对码不一致):别再轰炸
    set_live(false, "refused");
    return;
  }
  if (!token.empty()) {
    char proof[24] = {0};
    if (!field(text, "proof", proof, sizeof proof)) {
      ESP_LOGW(kTag, "welcome without proof; ignoring");
      return;
    }
    bool good = false;
    for (auto& saved : nonce_log) {
      if (!saved[0]) continue;
      if (proof_of(saved, "welcome") == proof) {
        good = true;
        break;
      }
    }
    if (!good) {
      ESP_LOGW(kTag, "welcome proof doesn't match the pairing code; ignoring");
      return;
    }
  }
  last_rx_ms = now_ms();
  handshaking = false;  // 握手完成,别再发 hello 了
  char host[64] = {0};
  field(text, "host", host, sizeof host);
  ESP_LOGI(kTag, "welcomed by %s", host[0] ? host : "yahamicd");
  set_live(true, "welcome");
  if (muted_) {  // 握手后立刻同步静音状态
    send_packet(kStatus, 1, "muted 1\n", sizeof("muted 1\n") - 1);
    muted_beat_at = now_ms();
  }
}

bool mdns_ready() {
  if (!mdns_on) mdns_on = mdns_init() == ESP_OK;
  return mdns_on;
}

// 同 OpenCharm 的 discover():问 _yahamic._tcp,拿到主机名(label)与端口。
bool discover(std::string& label, uint16_t& port) {
  if (!mdns_ready()) return false;
  mdns_result_t* results = nullptr;
  if (mdns_query_ptr("_yahamic", "_tcp", 1500, 4, &results) != ESP_OK || !results) return false;
  bool found = false;
  for (mdns_result_t* r = results; r && !found; r = r->next) {
    const char* name = nullptr;
    uint16_t p = 0;
    if (r->hostname && r->port) {
      name = r->hostname;
      p = r->port;
    } else if (r->instance_name) {
      mdns_result_t* srv = nullptr;
      if (mdns_query_srv(r->instance_name, "_yahamic", "_tcp", 800, &srv) == ESP_OK && srv) {
        name = srv->hostname;
        p = srv->port;
        mdns_query_results_free(srv);
      }
    }
    if (!name || !p) continue;
    std::string host = name;
    const std::string suffix = ".local";
    if (host.size() > suffix.size() &&
        strcasecmp(host.c_str() + host.size() - suffix.size(), suffix.c_str()) == 0)
      host = host.substr(0, host.size() - suffix.size());
    if (host.empty() || host.size() > 63) continue;
    bool plain = true;
    for (char c : host)
      if (!(isalnum((unsigned char)c) || c == '-')) {
        plain = false;
        break;
      }
    if (!plain) continue;
    label = host;
    port = p;
    found = true;
  }
  mdns_query_results_free(results);
  return found;
}

bool resolve(const std::string& label, esp_ip4_addr_t& ip) {
  if (!mdns_ready()) return false;
  // lwIP 自己不解析 .local,得问 mDNS 组件(同 OpenCharm 的 connect_url)。
  return mdns_query_a(label.c_str(), 2000, &ip) == ESP_OK && ip.addr != 0;
}

void open_socket(bool fresh = false) {
  std::lock_guard<std::recursive_mutex> guard(socket_lock);
  if (sock >= 0 && !fresh) return;
  if (sock >= 0) lwip_close(sock);  // 换源端口重开:绕开 Mac 端对旧会话的任何粘滞
  sock = lwip_socket(AF_INET, SOCK_DGRAM, 0);
  if (sock < 0) return;
  // recvfrom 的超时必须是 struct timeval(lwip 也按它读):初版传了 int,
  // 被当成 tv_sec=200 → recvfrom 阻塞 200 秒,worker 假死、重连全部失灵。
  struct timeval tv = {};
  tv.tv_sec = 0;
  tv.tv_usec = 200 * 1000;
  lwip_setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
  sockaddr_in any = {};
  any.sin_family = AF_INET;
  any.sin_addr.s_addr = htonl(INADDR_ANY);
  any.sin_port = 0;
  lwip_bind(sock, reinterpret_cast<sockaddr*>(&any), sizeof any);
}

void aim_at(const std::string& label, uint16_t port) {
  esp_ip4_addr_t ip = {};
  if (!resolve(label, ip)) return;
  daemon_label = label;
  daemon_port = port;
  daemon_addr = {};
  daemon_addr.sin_family = AF_INET;
  daemon_addr.sin_port = htons(port);
  daemon_addr.sin_addr.s_addr = ip.addr;
  have_addr = true;
  char text[24];
  snprintf(text, sizeof text, IPSTR ":%u", IP2STR(&ip), unsigned(port));
  std::lock_guard<std::mutex> guard(info_lock);
  strlcpy(daemon_text, text, sizeof daemon_text);
}

void worker(void*) {
  for (;;) {
    Posted p;
    if (xQueueReceive(commands, &p, pdMS_TO_TICKS(200)) == pdTRUE) {
      switch (p.command) {
        case Command::WifiUp:
          wifi_down_since = 0;
          set_live(false, "wifi up");
          open_socket();
          if (have_addr) {  // 静态地址(或刚连上时缓存仍在):直接握手
            handshaking = true;
            handshake_started = now_ms();
            hello_at = 0;
          } else {
            discovering = true;
            query_at = 0;
            handshaking = false;
          }
          break;
        case Command::WifiDown:
          wifi_down_since = wifi_down_since ?: now_ms();
          set_live(false, "wifi down");
          handshaking = false;
          break;
        case Command::OpenSetup:
          WifiManager::GetInstance().StartConfigAp();
          break;
      }
    }
    uint32_t now = now_ms();
    auto& wifi = WifiManager::GetInstance();

    // 一直连不上 Wi-Fi:一分钟后果断开配网(同 OpenCharm 的策略)。
    if (wifi_down_since != 0 && !wifi.IsConnected() && !wifi.IsConfigMode() &&
        now - wifi_down_since >= kWifiGiveUpMs) {
      wifi_down_since = 0;
      ESP_LOGI(kTag, "no Wi-Fi for a minute; opening Wi-Fi setup");
      wifi.StartConfigAp();
      continue;
    }

    if (!wifi.IsConnected() || wifi.IsConfigMode()) continue;

    // 在局域网里找 yahamicd;找到(或用缓存的地址)后握手。
    if (discovering && now >= query_at) {
      std::string label;
      uint16_t port = 0;
      if (!host_label_cache.empty() && host_port_cache) {
        // 先试上次的地址:守护进程重启/IP 未变时一步到位。
        label = host_label_cache;
        port = host_port_cache;
      } else if (discover(label, port)) {
        host_label_cache = label;
        host_port_cache = port;
      } else if (has_static) {
        // mDNS 没结果(有的网络不转发组播):回到静态地址再握手,两条路轮着试。
        daemon_addr = static_addr;
        have_addr = true;
        discovering = false;
        handshaking = true;
        handshake_started = now;
        hello_at = 0;
        continue;
      } else {
        query_at = now + kDiscoverEveryMs;
        continue;
      }
      aim_at(label, port);
      if (!have_addr) {
        // 解析失败(mDNS 缓存掉了):清掉缓存,强制重新发现。
        host_label_cache.clear();
        query_at = now + kDiscoverEveryMs;
        continue;
      }
      host_label_cache = daemon_label;
      host_port_cache = daemon_port;
      discovering = false;
      handshaking = true;
      handshake_started = now;
      hello_at = 0;
    }
    if (discovering) continue;

    if (handshaking && now >= hello_at) {
      send_hello();
      hello_at = now + kHelloEveryMs;
    }

    // 收包(超时 200 ms 由 socket 决定)。
    uint8_t buf[1500];
    sockaddr_in from = {};
    socklen_t from_len = sizeof from;
    int got = lwip_recvfrom(sock, buf, sizeof buf, 0, reinterpret_cast<sockaddr*>(&from), &from_len);
    if (got > 0) handle_datagram(buf, size_t(got), from);
    now = now_ms();

    if (live_) {
      if (now - last_rx_ms >= kSilentLiveMs) {
        // Mac 睡着了/守护进程退了:换源端口回到握手(daemon 重启后旧会话
        // 可能被各种中间环节粘住,新端口等价于一次全新的接入)。
        set_live(false, "yahamicd went quiet");
        open_socket(true);
        handshaking = true;
        handshake_started = now;
        hello_at = 0;
      } else if (muted_ && now >= muted_beat_at) {
        // 静音心跳:让 Mac 知道设备还在。
        send_packet(kStatus, 1, "muted 1\n", sizeof("muted 1\n") - 1);
        muted_beat_at = now + kMutedBeatMs;
      }
    } else if (handshaking && now - handshake_started >= kHandshakeGiveUpMs) {
      open_socket(true);  // 换源端口再来
      handshake_started = now;
      hello_at = 0;
      if (has_static) {
        // 有静态地址:永远保持握手(不切到纯 mDNS 发现——那条路在不转发
        // 组播的网络里会一直空转),mDNS 只用来顺带刷新一次地址。
        std::string label;
        uint16_t port = 0;
        if (discover(label, port)) aim_at(label, port);
        if (!have_addr || daemon_addr.sin_addr.s_addr == 0) {
          daemon_addr = static_addr;
          have_addr = true;
        }
        ESP_LOGI(kTag, "no welcome; retrying (static %s)", daemon_text);
      } else {
        ESP_LOGI(kTag, "no welcome; looking for yahamicd again");
        handshaking = false;
        discovering = true;
        query_at = 0;
        host_label_cache.clear();  // 换个思路:重新发现
      }
    }
  }
}

void on_wifi(WifiEvent event, const std::string&) {
  auto& wifi = WifiManager::GetInstance();
  Posted p{Command::WifiDown};
  switch (event) {
    case WifiEvent::Connected:
      p.command = Command::WifiUp;
      break;
    case WifiEvent::Disconnected:
      break;
    case WifiEvent::ConfigModeEnter: {
      // 热点密码每次随机:进热点时就把名字和密码抄给屏幕。
      std::lock_guard<std::mutex> guard(info_lock);
      setup_open = true;
      strlcpy(setup_ssid, wifi.GetApSsid().c_str(), sizeof setup_ssid);
      strlcpy(setup_pass, wifi.GetApPassword().c_str(), sizeof setup_pass);
      p.command = Command::WifiDown;
      break;
    }
    case WifiEvent::ConfigModeExit:
      {
        std::lock_guard<std::mutex> guard(info_lock);
        setup_open = false;
        setup_ssid[0] = setup_pass[0] = 0;
      }
      if (!wifi.IsConnected()) wifi.StartStation();
      p.command = Command::WifiDown;  // 重新起"一分钟没网就开配网"的时钟
      break;
    case WifiEvent::Scanning:
    case WifiEvent::Connecting:
      return;
  }
  xQueueSend(commands, &p, 0);
}

}  // namespace

void on_remote_mute(MuteCommand command) { remote_mute = std::move(command); }

bool consume_dump_request() { return dump_pending.exchange(false); }

void start(const char* fw_version) {
  fw_version = fw_version ? fw_version : "0.0.0";
  psa_crypto_init();  // PSA 哈希(psa_hash_compute)的前提,幂等
  uint8_t mac[6] = {0};
  esp_read_mac(mac, ESP_MAC_WIFI_STA);
  char name[16];
  snprintf(name, sizeof name, "yahamic-%02x%02x", mac[4], mac[5]);
  device_name = name;
  token = read_token();
  if (!token.empty()) ESP_LOGI(kTag, "pairing code set (%zu chars)", token.size());

#ifdef CONFIG_YAHAMIC_DAEMON_IP
  // 逃生舱:静态 daemon 地址(Kconfig 配置),开机跳过 mDNS 直接握手;
  // 握手失败 10 秒仍会自动回落到 mDNS 自动发现(worker 的常规路径)。
  if (strlen(CONFIG_YAHAMIC_DAEMON_IP) > 0) {
    esp_ip4_addr_t ip = {};
    ip.addr = inet_addr(CONFIG_YAHAMIC_DAEMON_IP);
    if (ip.addr != 0 && ip.addr != 0xFFFFFFFF) {
      daemon_addr.sin_family = AF_INET;
      daemon_addr.sin_port = htons(CONFIG_YAHAMIC_DAEMON_PORT);
      daemon_addr.sin_addr.s_addr = ip.addr;
      have_addr = true;
      static_addr = daemon_addr;
      has_static = true;
      handshaking = true;  // WifiUp 后直接进入握手(hello 由 worker 发出)
      hello_at = 0;
      char text[32];
      snprintf(text, sizeof text, IPSTR ":%u(static)", IP2STR(&ip),
               unsigned(CONFIG_YAHAMIC_DAEMON_PORT));
      std::lock_guard<std::mutex> guard(info_lock);
      strlcpy(daemon_text, text, sizeof daemon_text);
      ESP_LOGI(kTag, "static daemon %s", text);
    }
  }
#endif

  commands = xQueueCreate(kCmdQueue, sizeof(Posted));
  xTaskCreate(worker, "yahamic_link", 6144, nullptr, 5, nullptr);

  auto& wifi = WifiManager::GetInstance();
  // 语音流不能容忍 Wi-Fi 省电的按信标缓冲(MIN_MODEM 会造成周期性卡顿,
  // 语音转写端表现为"重复"):全程关闭省电(语音设备的标配做法)。
  esp_wifi_set_ps(WIFI_PS_NONE);
  WifiManagerConfig config;
  config.ssid_prefix = "Yahamic";
  config.language = "zh-CN";       // 配网页是中文的
  config.show_ota_config = true;   // 页面借此显示「配对码」字段
  config.station_hostname = "yahamic";
  wifi.Initialize(config);
  wifi.SetEventCallback(on_wifi);
  if (SsidManager::GetInstance().GetSsidList().empty()) {
    wifi.StartConfigAp();
  } else {
    Posted p{Command::WifiDown};  // 起"一分钟"时钟,直到事件说连上了
    xQueueSend(commands, &p, 0);
    wifi.StartStation();
  }
}

void open_setup() {
  if (commands) {
    Posted p{Command::OpenSetup};
    xQueueSend(commands, &p, 0);
  }
}

void set_muted(bool on) {
  muted_.store(on);
  if (live_ && sock >= 0) send_packet(kStatus, on ? 1 : 0, on ? "muted 1\n" : "muted 0\n", 8);
  if (on) muted_beat_at = now_ms();
}

bool muted() { return muted_.load(); }

Dashboard dashboard() {
  std::lock_guard<std::mutex> guard(dash_lock);
  return dash;
}

Snapshot snapshot() {
  Snapshot s;
  auto& wifi = WifiManager::GetInstance();
  s.setup = wifi.IsConfigMode();
  if (s.setup) {
    std::lock_guard<std::mutex> guard(info_lock);
    strlcpy(s.setup_ssid, setup_ssid, sizeof s.setup_ssid);
    strlcpy(s.setup_pass, setup_pass, sizeof s.setup_pass);
  }
  s.wifi_up = wifi.IsConnected();
  // 存过网络但没连上 = 正在加入。SsidManager 要读 NVS(带锁、慢),主循环
  // 每 33ms 拉一次快照会拖垮频谱帧率:结果缓存 5 秒足够。
  static bool cached_joining = false;
  static uint32_t joining_at = 0;
  if (!s.wifi_up && now_ms() - joining_at >= 5000) {
    joining_at = now_ms();
    cached_joining = !SsidManager::GetInstance().GetSsidList().empty();
  }
  s.joining = !s.wifi_up && cached_joining;
  // SSID/IP/RSSI 的查询走 Wi-Fi 驱动(带锁,单次可达几十毫秒),主循环 33ms 一
  // 圈不能每次都问:按 2 秒 TTL 缓存。
  static char cached_ssid[33] = {0};
  static char cached_ip[16] = {0};
  static int cached_rssi = 0;
  static uint32_t net_at = 0;
  if (s.wifi_up && now_ms() - net_at >= 2000) {
    net_at = now_ms();
    strlcpy(cached_ssid, wifi.GetSsid().c_str(), sizeof cached_ssid);
    strlcpy(cached_ip, wifi.GetIpAddress().c_str(), sizeof cached_ip);
    cached_rssi = wifi.GetRssi();
  }
  if (s.wifi_up) {
    strlcpy(s.ssid, cached_ssid, sizeof s.ssid);
    strlcpy(s.ip, cached_ip, sizeof s.ip);
    s.rssi = cached_rssi;
  }
  s.live = live_.load();
  s.muted = muted_.load();
  strlcpy(s.phase, s.live ? "live" : discovering ? "discover" : handshaking ? "handshake" : "idle",
          sizeof s.phase);
  {
    std::lock_guard<std::mutex> guard(info_lock);
    strlcpy(s.daemon, daemon_text, sizeof s.daemon);
  }
  return s;
}

void send_audio(const uint8_t* opus, size_t size, uint32_t ts_ms, float) {
  if (!live_.load()) return;
  // ts 字段填设备时戳(xiaozhi 做法:服务端按时戳排序)。
  std::lock_guard<std::recursive_mutex> guard(socket_lock);
  if (sock < 0 || !have_addr) return;
  Header h = {};
  h.magic = 'Y'; h.version = 1; h.type = kAudio; h.flags = 0;
  h.seq = ++seq;
  h.ts = ts_ms;
  uint8_t buf[600];
  size_t total = sizeof(Header) + size;
  if (total > sizeof buf) return;
  memcpy(buf, &h, sizeof(Header));
  memcpy(buf + sizeof(Header), opus, size);
  lwip_sendto(sock, buf, total, 0,
              reinterpret_cast<sockaddr*>(&daemon_addr), sizeof daemon_addr);
}

}  // namespace uplink
