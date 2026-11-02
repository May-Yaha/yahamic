#include "uplink.h"

#include <ctype.h>
#include <strings.h>

#include <atomic>
#include <cstring>
#include <mutex>

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
#include "protocol.h"
#include "ssid_manager.h"
#include "wifi_manager.h"

// 报文是协议 v2(README「协议」一节是规范,编解码与密码学在 protocol.{h,cpp}):
//   hello(明文,带设备随机数 dn)→ welcome(明文,带 Mac 随机数 mn 与 Mac 的证明)
//   → 设备验证后发 auth(设备的证明)→ Mac 验证通过后的第一个加密包(control)
//   让设备进入 live。live 之后 type 3–7 全部 ChaCha20-Poly1305 加密,明文一律丢弃。
//   拒绝包(welcome ok 0)只在握手中、且 dn 对得上时才认,认了就退避 5 秒。
//   Mac 每个 keepalive 都带最新静音指令 "muted X\ncmd N\n",设备只在 cmd 变化时执行。
//   断链即静音;没有有效配对码(8–63 位)时不连 Mac,屏幕提示去配网页填码。
namespace uplink {
namespace {

constexpr const char* kTag = "link";

constexpr uint32_t kHelloEveryMs = 500;         // 握手期间 hello / auth 的间隔
constexpr uint32_t kDiscoverEveryMs = 3000;     // mDNS 查询间隔
constexpr uint32_t kHandshakeGiveUpMs = 10000;  // 这么久没上线 → 重新发现
constexpr uint32_t kRefusedBackoffMs = 5000;    // 被拒后等这么久再握手
constexpr uint32_t kSilentLiveMs = 5000;        // live 时这么久没包 → 重新握手
constexpr uint32_t kMutedBeatMs = 1000;         // 静音状态心跳
constexpr uint32_t kWifiGiveUpMs = 60000;       // 一直连不上 Wi-Fi → 开配网
constexpr uint32_t kStackReportMs = 30000;      // 开机多久记一次 worker 栈余量
constexpr uint32_t kWorkerStack = 8192;
constexpr int kCmdQueue = 8;
constexpr int kDrainMax = 16;  // 每轮最多处理这么多个包,再回去看定时器

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

enum class Command { WifiUp, WifiDown, OpenSetup, ReloadToken };
struct Posted {
  Command command;
};

// 握手阶段:Hello 等 welcome;Auth 已发证明、等 Mac 的第一个加密包。
enum class Phase { Idle, Discover, Hello, Auth, Live, Backoff };

// —— worker 自己的状态(只有 worker 任务碰)——
Phase phase = Phase::Idle;
std::string daemon_label;      // mDNS 主机名(label,不带 .local)
uint16_t daemon_port = 0;
std::string host_label_cache;  // 记住上次发现的 label,重启后先直接试
uint16_t host_port_cache = 0;
uint32_t hello_at = 0, query_at = 0, last_rx_ms = 0, muted_beat_at = 0, backoff_until = 0;
uint32_t wifi_down_since = 0;
uint32_t handshake_started = 0;
bool mdns_on = false;
sockaddr_in static_addr = {};  // Kconfig 的静态 daemon 地址(逃生舱)
bool has_static = false;       // mDNS 没结果时回到它再试

// 配对:主密钥由配对码派生(配网页「配对码」字段,存 NVS wifi/ota_url),码本身不留在内存。
uint8_t master[proto::kKeySize] = {0};
bool have_key = false;
uint8_t dn[proto::kNonceSize] = {0};  // 本次握手的设备随机数
uint8_t mn[proto::kNonceSize] = {0};  // welcome 带来的 Mac 随机数
bool mismatch_logged = false;
uint32_t rx_seq = 0;      // Mac→设备已接收的最大 seq(控制类包严格递增)
char last_cmd[12] = {0};  // 最近执行过的静音指令代号

std::string device_name;
std::string fw_version;

// —— 共享状态(socket_lock 保护:socket、目标地址、会话密钥、发包 seq)——
// 锁序:main 的静音锁 → socket_lock。持有 socket_lock 时绝不回调 remote_mute。
std::recursive_mutex socket_lock;
int sock = -1;
sockaddr_in daemon_addr = {};
bool have_addr = false;  // mDNS 找到过(或静态配置)的地址
proto::Session session;
uint32_t out_seq = 0;

QueueHandle_t commands = nullptr;
std::mutex info_lock;
bool setup_open = false;
char setup_ssid[33] = {0};
char setup_pass[64] = {0};
char daemon_text[24] = {0};
std::atomic<bool> live_{false};
std::atomic<bool> muted_{false};
std::atomic<bool> unpaired_{false};
std::atomic<Phase> phase_shown{Phase::Idle};  // 给 snapshot 读的阶段副本
std::atomic<bool> dump_pending{false};  // Mac 请求:回传一帧屏幕(排障/看 UI)
MuteCommand remote_mute;  // worker 线程里回调(main 注册,须在 start 之前)
std::mutex dash_lock;
Dashboard dash;  // 最近一次 type 7(供主循环轮询)

uint32_t now_ms() { return uint32_t(esp_timer_get_time() / 1000); }
// 毫秒时钟约 49.7 天回绕一次:截止判断一律按差值的符号。
bool due(uint32_t now, uint32_t at) { return int32_t(now - at) >= 0; }

void set_phase(Phase p) {
  phase = p;
  phase_shown.store(p);
}

// 读配对码并派生主密钥。码不合法(空/超长/含空格)就当没配对。
void load_key() {
  have_key = false;
  memset(master, 0, sizeof master);
  std::string code;
  nvs_handle_t nvs;
  if (nvs_open("wifi", NVS_READONLY, &nvs) == ESP_OK) {
    size_t size = 0;
    if (nvs_get_str(nvs, "ota_url", nullptr, &size) == ESP_OK && size > 1 &&
        size <= proto::kMaxCode + 1) {
      code.resize(size);
      if (nvs_get_str(nvs, "ota_url", code.data(), &size) == ESP_OK) code.resize(size - 1);
      else code.clear();
    }
    nvs_close(nvs);
  }
  if (proto::valid_code(code)) have_key = proto::master_key(code, master);
  if (!code.empty()) memset(code.data(), 0, code.size());
  unpaired_.store(!have_key);
  ESP_LOGI(kTag, "pairing code %s", have_key ? "set" : "missing: fill it in on the Wi-Fi setup page");
}

void send_plain(uint8_t type, const char* payload, size_t len) {
  std::lock_guard<std::recursive_mutex> guard(socket_lock);
  if (sock < 0 || !have_addr || len > proto::kMaxPayload) return;
  uint8_t buf[proto::kMaxPacket];
  proto::Header h = proto::make_header(type, 0, 0, now_ms());
  memcpy(buf, &h, sizeof h);
  memcpy(buf + sizeof h, payload, len);
  lwip_sendto(sock, buf, sizeof h + len, 0, reinterpret_cast<sockaddr*>(&daemon_addr), sizeof daemon_addr);
}

// 加密发送(仅 live):seq 在锁里递增,nonce 由它派生,同一会话密钥下绝不重复。
bool send_sealed(uint8_t type, uint8_t flags, const void* plain, size_t len, uint32_t ts) {
  std::lock_guard<std::recursive_mutex> guard(socket_lock);
  if (!live_.load() || sock < 0 || !have_addr || !session.active() || len > proto::kMaxPayload)
    return false;
  uint8_t buf[proto::kMaxPacket];
  proto::Header h = proto::make_header(type, flags, ++out_seq, ts);
  memcpy(buf, &h, sizeof h);
  size_t n = 0;
  if (!session.seal(h, static_cast<const uint8_t*>(plain), len, buf + sizeof h, &n)) return false;
  return lwip_sendto(sock, buf, sizeof h + n, 0, reinterpret_cast<sockaddr*>(&daemon_addr),
                     sizeof daemon_addr) >= 0;
}

void send_status() {
  const bool on = muted_.load();
  send_sealed(proto::kStatus, on ? 1 : 0, on ? "muted 1\n" : "muted 0\n", 8, now_ms());
}

void send_hello() {
  char dn_hex[2 * proto::kNonceSize + 1];
  proto::to_hex(dn, sizeof dn, dn_hex);
  char payload[192];
  int n = snprintf(payload, sizeof payload,
                   "name %s\nfw %s\nrate 16000\nch 1\nbits 16\nframe 60\ncodec opus\ndn %s\n",
                   device_name.c_str(), fw_version.c_str(), dn_hex);
  if (n > 0 && size_t(n) < sizeof payload) send_plain(proto::kHello, payload, size_t(n));
}

void send_auth() {
  uint8_t proof[32];
  if (!proto::mac(master, "d", dn, mn, proof)) return;
  char payload[6 + 64 + 2] = "proof ";
  proto::to_hex(proof, sizeof proof, payload + 6);
  strcat(payload, "\n");
  send_plain(proto::kAuth, payload, strlen(payload));
}

// 新一轮握手:新随机数,旧会话作废。
void begin_handshake(uint32_t now) {
  {
    std::lock_guard<std::recursive_mutex> guard(socket_lock);
    session.end();
  }
  esp_fill_random(dn, sizeof dn);
  mismatch_logged = false;
  handshake_started = now;
  hello_at = now;
  set_phase(Phase::Hello);
}

void go_live() {
  live_.store(true);
  set_phase(Phase::Live);
  ESP_LOGI(kTag, "live: yahamicd verified, session encrypted");
}

// 断链:会话作废、设备自动静音(重新上线后 Mac 会再下发静音指令)。
void link_down(const char* note) {
  bool was;
  {
    std::lock_guard<std::recursive_mutex> guard(socket_lock);
    was = live_.exchange(false);
    session.end();
  }
  if (!was) return;
  ESP_LOGI(kTag, "link down (%s)", note);
  if (remote_mute) remote_mute(true);
}

void set_target(const sockaddr_in& addr) {
  std::lock_guard<std::recursive_mutex> guard(socket_lock);
  daemon_addr = addr;
  have_addr = true;
}

void handle_sealed(const proto::Header& h, const uint8_t* payload, size_t len, uint32_t now) {
  if (phase != Phase::Auth && phase != Phase::Live) return;
  if (h.type == proto::kAudio || h.type == proto::kStatus) return;  // 设备→Mac 的类型
  // 会话只由 worker 改,这里读不用加锁;tag 不对(伪造/篡改/错码)直接丢。
  uint8_t plain[proto::kMaxPayload + 1];
  size_t n = 0;
  if (!session.open(h, payload, len, plain, &n)) return;
  if (h.seq <= rx_seq) return;  // 重放或迟到:控制类包只认更新的
  rx_seq = h.seq;
  last_rx_ms = now;
  if (phase == Phase::Auth) {  // Mac 验过 auth 后的第一个加密包:会话双向成立
    go_live();
    send_status();
  }
  if (h.type == proto::kDashboard) {
    if (n < sizeof(DashboardPayload)) return;
    DashboardPayload p;
    memcpy(&p, plain, sizeof p);
    std::lock_guard<std::mutex> guard(dash_lock);
    dash.epoch = p.epoch;
    dash.tz_offset_minutes = p.tz_minutes;
    dash.cpu = p.cpu;
    dash.mem = p.mem;
    dash.mouse_batt = p.mouse_batt;
    dash.kb_batt = p.kb_batt;
    dash.received_ms = now;
    dash.valid = true;
    return;
  }
  // keepalive / control:都带最新静音指令;cmd 变了才执行(丢一个 control,下个 keepalive 补上)。
  plain[n] = 0;
  const char* text = reinterpret_cast<const char*>(plain);
  char cmd[sizeof last_cmd], want[4];
  if (proto::field(text, "cmd", cmd, sizeof cmd) && proto::field(text, "muted", want, sizeof want) &&
      strcmp(cmd, last_cmd) != 0) {
    strlcpy(last_cmd, cmd, sizeof last_cmd);
    if (remote_mute) remote_mute(strcmp(want, "1") == 0);
  }
  char dump[4];
  if (h.type == proto::kControl && proto::field(text, "dump", dump, sizeof dump) && strcmp(dump, "1") == 0)
    dump_pending.store(true);
}

void handle_welcome(const uint8_t* payload, size_t len, uint32_t now) {
  if (phase != Phase::Hello && phase != Phase::Auth) return;  // 上线后的明文一律丢弃
  char text[proto::kMaxPayload + 1];
  memcpy(text, payload, len);
  text[len] = 0;
  // 只认回显了本次 dn 的 welcome / 拒绝:嗅探到的旧包、伪造的拒绝都对不上。
  char hex[2 * 32 + 1];
  uint8_t echoed[proto::kNonceSize];
  if (!proto::field(text, "dn", hex, sizeof hex) || !proto::from_hex(hex, echoed, sizeof echoed) ||
      memcmp(echoed, dn, sizeof dn) != 0)
    return;
  char ok[4];
  if (!proto::field(text, "ok", ok, sizeof ok) || strcmp(ok, "1") != 0) {
    char err[64] = {0};
    proto::field(text, "err", err, sizeof err);
    ESP_LOGW(kTag, "yahamicd refused: %s; retrying in 5 s", err[0] ? err : "no reason given");
    {
      std::lock_guard<std::recursive_mutex> guard(socket_lock);
      session.end();
    }
    set_phase(Phase::Backoff);
    backoff_until = now + kRefusedBackoffMs;
    return;
  }
  if (phase != Phase::Hello) return;  // 同一轮里重复的 welcome:已经发过 auth 了
  uint8_t proof[32];
  if (!proto::field(text, "mn", hex, sizeof hex) || !proto::from_hex(hex, mn, sizeof mn) ||
      !proto::field(text, "proof", hex, sizeof hex) || !proto::from_hex(hex, proof, sizeof proof) ||
      !proto::verify(master, "m", dn, mn, proof)) {
    if (!mismatch_logged) {
      mismatch_logged = true;
      ESP_LOGW(kTag, "welcome proof doesn't match: the pairing codes on device and Mac differ?");
    }
    return;
  }
  bool ok_keys;
  {
    std::lock_guard<std::recursive_mutex> guard(socket_lock);
    ok_keys = session.begin(master, dn, mn);
    out_seq = 0;
  }
  if (!ok_keys) {
    ESP_LOGE(kTag, "session keys failed (ChaCha20-Poly1305 enabled in mbedtls?)");
    return;
  }
  rx_seq = 0;
  last_cmd[0] = 0;
  last_rx_ms = now;
  char host[64] = {0};
  proto::field(text, "host", host, sizeof host);
  ESP_LOGI(kTag, "welcomed by %s; sending our proof", host[0] ? host : "yahamicd");
  set_phase(Phase::Auth);
  send_auth();
  hello_at = now + kHelloEveryMs;
}

void handle_datagram(const uint8_t* data, size_t len, const sockaddr_in& from, uint32_t now) {
  proto::Header h;
  if (!proto::parse_header(data, len, h)) return;
  // 只认 yahamicd 的地址:一个来源,防止局域网里别的包搅乱状态(地址只由 worker 改)。
  if (!have_addr || from.sin_addr.s_addr != daemon_addr.sin_addr.s_addr ||
      from.sin_port != daemon_addr.sin_port)
    return;
  const uint8_t* payload = data + sizeof h;
  const size_t payload_len = len - sizeof h;
  if (proto::is_sealed(h.type)) handle_sealed(h, payload, payload_len, now);
  else if (h.type == proto::kWelcome) handle_welcome(payload, payload_len, now);
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
    std::string host;  // 先拷出来:srv 的结果马上就释放
    uint16_t p = 0;
    if (r->hostname && r->port) {
      host = r->hostname;
      p = r->port;
    } else if (r->instance_name) {
      mdns_result_t* srv = nullptr;
      if (mdns_query_srv(r->instance_name, "_yahamic", "_tcp", 800, &srv) == ESP_OK && srv) {
        if (srv->hostname) host = srv->hostname;
        p = srv->port;
        mdns_query_results_free(srv);
      }
    }
    if (host.empty() || !p) continue;
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

bool aim_at(const std::string& label, uint16_t port) {
  esp_ip4_addr_t ip = {};
  if (!resolve(label, ip)) return false;
  daemon_label = label;
  daemon_port = port;
  sockaddr_in addr = {};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(port);
  addr.sin_addr.s_addr = ip.addr;
  set_target(addr);
  char text[24];
  snprintf(text, sizeof text, IPSTR ":%u", IP2STR(&ip), unsigned(port));
  std::lock_guard<std::mutex> guard(info_lock);
  strlcpy(daemon_text, text, sizeof daemon_text);
  return true;
}

void start_discovery() {
  set_phase(Phase::Discover);
  query_at = now_ms();
}

// 握手没成:有静态地址就一直对它握手,否则回到 mDNS 重新发现。
void handshake_failed(uint32_t now) {
  open_socket(true);  // 换源端口再来
  if (has_static) {
    // 不切到纯 mDNS 发现(那条路在不转发组播的网络里会一直空转),mDNS 只顺带刷新一次地址。
    std::string label;
    uint16_t port = 0;
    if (!(discover(label, port) && aim_at(label, port))) set_target(static_addr);
    ESP_LOGI(kTag, "no session; retrying (static %s)", daemon_text);
    begin_handshake(now);
  } else {
    ESP_LOGI(kTag, "no session; looking for yahamicd again");
    host_label_cache.clear();  // 换个思路:重新发现
    start_discovery();
  }
}

void on_command(Command command) {
  switch (command) {
    case Command::WifiUp:
      wifi_down_since = 0;
      link_down("wifi up");
      open_socket();
      if (have_addr) begin_handshake(now_ms());  // 静态地址(或缓存仍在):直接握手
      else start_discovery();
      break;
    case Command::WifiDown:
      wifi_down_since = wifi_down_since ?: now_ms();
      link_down("wifi down");
      set_phase(Phase::Idle);
      break;
    case Command::OpenSetup:
      WifiManager::GetInstance().StartConfigAp();
      break;
    case Command::ReloadToken:  // 配网页可能改了配对码:重新派生,旧会话作废
      load_key();
      link_down("pairing code reloaded");
      if (phase != Phase::Idle) handshake_failed(now_ms());
      break;
  }
}

// 发现 → 握手(找到地址或用缓存/静态地址)。
void step_discover(uint32_t now) {
  if (!due(now, query_at)) return;
  std::string label;
  uint16_t port = 0;
  if (!host_label_cache.empty() && host_port_cache) {
    // 先试上次的地址:守护进程重启/IP 未变时一步到位。
    label = host_label_cache;
    port = host_port_cache;
  } else if (!discover(label, port)) {
    if (has_static) {
      // mDNS 没结果(有的网络不转发组播):回到静态地址再握手,两条路轮着试。
      set_target(static_addr);
      begin_handshake(now);
    } else {
      query_at = now + kDiscoverEveryMs;
    }
    return;
  }
  if (!aim_at(label, port)) {
    // 解析失败(mDNS 缓存掉了):清掉缓存,强制重新发现。
    host_label_cache.clear();
    query_at = now + kDiscoverEveryMs;
    return;
  }
  host_label_cache = daemon_label;
  host_port_cache = daemon_port;
  begin_handshake(now);
}

void worker(void*) {
  const uint32_t started = now_ms();
  bool stack_reported = false;
  for (;;) {
    Posted p;
    // 超时 0:阻塞交给 socket 的 200 ms 读超时,命令与收包都不互相拖延。
    while (xQueueReceive(commands, &p, 0) == pdTRUE) on_command(p.command);
    uint32_t now = now_ms();
    auto& wifi = WifiManager::GetInstance();

    if (!stack_reported && due(now, started + kStackReportMs)) {
      stack_reported = true;
      ESP_LOGI(kTag, "worker stack headroom %u bytes", unsigned(uxTaskGetStackHighWaterMark(nullptr)));
    }

    // 一直连不上 Wi-Fi:一分钟后果断开配网(同 OpenCharm 的策略)。
    if (wifi_down_since != 0 && !wifi.IsConnected() && !wifi.IsConfigMode() &&
        due(now, wifi_down_since + kWifiGiveUpMs)) {
      wifi_down_since = 0;
      ESP_LOGI(kTag, "no Wi-Fi for a minute; opening Wi-Fi setup");
      wifi.StartConfigAp();
      continue;
    }

    if (!wifi.IsConnected() || wifi.IsConfigMode() || !have_key || phase == Phase::Idle) {
      vTaskDelay(pdMS_TO_TICKS(200));
      continue;
    }

    if (phase == Phase::Discover) {
      step_discover(now);
      if (phase == Phase::Discover) vTaskDelay(pdMS_TO_TICKS(200));
      continue;
    }
    if (phase == Phase::Backoff && due(now, backoff_until)) begin_handshake(now);
    if ((phase == Phase::Hello || phase == Phase::Auth) && due(now, hello_at)) {
      // Auth 阶段重发证明:auth 丢了 Mac 还在等;Mac 收到过就忽略重发。
      if (phase == Phase::Hello) send_hello();
      else send_auth();
      hello_at = now + kHelloEveryMs;
    }

    // 收包:第一个等 200 ms(socket 超时),之后把已到的包一次读完。
    uint8_t buf[proto::kMaxPacket + 1];  // 多 1 字节:超长包能被认出来拒收,不被截断
    for (int i = 0; i < kDrainMax; ++i) {
      sockaddr_in from = {};
      socklen_t from_len = sizeof from;
      int got = lwip_recvfrom(sock, buf, sizeof buf, i ? MSG_DONTWAIT : 0,
                              reinterpret_cast<sockaddr*>(&from), &from_len);
      if (got <= 0) break;
      handle_datagram(buf, size_t(got), from, now_ms());
    }
    now = now_ms();

    if (phase == Phase::Live) {
      if (now - last_rx_ms < kSilentLiveMs) {
        if (muted_ && due(now, muted_beat_at)) {  // 静音心跳:让 Mac 知道设备还在
          send_status();
          muted_beat_at = now + kMutedBeatMs;
        }
        continue;
      }
      // Mac 睡着了/守护进程退了:换源端口回到握手(新端口等价于一次全新的接入)。
      link_down("yahamicd went quiet");
      open_socket(true);
      begin_handshake(now);
    } else if ((phase == Phase::Hello || phase == Phase::Auth) &&
               due(now, handshake_started + kHandshakeGiveUpMs)) {
      handshake_failed(now);
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
      break;
    }
    case WifiEvent::ConfigModeExit: {
      {
        std::lock_guard<std::mutex> guard(info_lock);
        setup_open = false;
        setup_ssid[0] = setup_pass[0] = 0;
      }
      Posted reload{Command::ReloadToken};  // 配网页刚改过配对码也立即生效,不用重启
      xQueueSend(commands, &reload, 0);
      if (wifi.IsConnected()) p.command = Command::WifiUp;
      else wifi.StartStation();  // WifiDown:重新起"一分钟没网就开配网"的时钟
      break;
    }
    case WifiEvent::Scanning:
    case WifiEvent::Connecting:
      return;
  }
  xQueueSend(commands, &p, 0);
}

}  // namespace

void on_remote_mute(MuteCommand command) { remote_mute = std::move(command); }

bool consume_dump_request() { return dump_pending.exchange(false); }

void start(const char* version) {
  fw_version = version ? version : "0.0.0";
  psa_crypto_init();  // PSA(PBKDF2/HMAC/ChaCha20-Poly1305)的前提,幂等
  if (!proto::self_test()) ESP_LOGE(kTag, "protocol self-test failed: the Mac won't accept this device");
  uint8_t mac[6] = {0};
  esp_read_mac(mac, ESP_MAC_WIFI_STA);
  char name[16];
  snprintf(name, sizeof name, "yahamic-%02x%02x", mac[4], mac[5]);
  device_name = name;
  load_key();  // PBKDF2 约 1 秒,只在开机和配对码变化时做

#ifdef CONFIG_YAHAMIC_DAEMON_IP
  // 逃生舱:静态 daemon 地址(Kconfig 配置),开机跳过 mDNS 直接握手;
  // mDNS 能发现时顺带刷新地址(见 handshake_failed)。
  if (strlen(CONFIG_YAHAMIC_DAEMON_IP) > 0) {
    esp_ip4_addr_t ip = {};
    ip.addr = inet_addr(CONFIG_YAHAMIC_DAEMON_IP);
    if (ip.addr != 0 && ip.addr != 0xFFFFFFFF) {
      static_addr.sin_family = AF_INET;
      static_addr.sin_port = htons(CONFIG_YAHAMIC_DAEMON_PORT);
      static_addr.sin_addr.s_addr = ip.addr;
      has_static = true;
      set_target(static_addr);  // WifiUp 后直接进入握手(hello 由 worker 发出)
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
  xTaskCreate(worker, "yahamic_link", kWorkerStack, nullptr, 5, nullptr);

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
  send_status();  // 未上线时 send_sealed 直接返回
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
  s.unpaired = unpaired_.load();
  static const char* const names[] = {"idle", "discover", "hello", "auth", "live", "backoff"};
  strlcpy(s.phase, s.unpaired ? "unpaired" : names[int(phase_shown.load())], sizeof s.phase);
  {
    std::lock_guard<std::mutex> guard(info_lock);
    strlcpy(s.daemon, daemon_text, sizeof s.daemon);
  }
  return s;
}

void send_audio(const uint8_t* opus, size_t size, uint32_t ts_ms, float) {
  // ts 字段填设备时戳(xiaozhi 做法:服务端按时戳排序);flags bit0 = 真实静音状态
  // (淡出中的话尾帧带 1)。未上线 send_sealed 直接丢弃,绝不阻塞采集。
  send_sealed(proto::kAudio, muted_.load() ? 1 : 0, opus, size, ts_ms);
}

}  // namespace uplink
