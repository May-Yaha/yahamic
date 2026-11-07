#pragma once
#include <cctype>
#include <cstdint>
#include <cstring>
#include <string>
#include "display_json.h"

// 网盘设备服务(DMS / IoT Core)的线上格式,移植自 hardware-ai-suite firmware/sdk/core/src/dms.c。
// 纯函数,主机侧 tests/dms_wire_test.cpp 直接编译。
namespace dmswire {
constexpr int64_t kTimeOk = 1700000000;  // broker 校验 ts:SNTP 之前时钟还在 1970 附近
constexpr int64_t kCommandTtl = 60;      // 离线期间排队的指令超过 60 秒不执行
constexpr const char* kBrokerDomain = "iot.gz.baidubce.com";
constexpr size_t kTopicMax = 128;

inline bool only(const std::string& s, const char* set) { return strspn(s.c_str(), set) == s.size(); }
// DMS device_id:18 位数字与小写字母。
inline bool device_id(const std::string& s) {
  return s.size() == 18 && only(s, "0123456789abcdefghijklmnopqrstuvwxyz");
}
inline bool b64url(const std::string& s, size_t lo, size_t hi) {
  return s.size() >= lo && s.size() <= hi &&
         only(s, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_");
}
inline bool core_id(const std::string& s) {
  return !s.empty() && s.size() <= 128 &&
         only(s, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.:-");
}

struct Broker {
  std::string host;
  uint32_t port = 8883;
};
// tls:// 或 mqtts://,后面只有 host[:port],host 在 iot.gz.baidubce.com 之下:broker 由 Mac 转交,
// 不在白名单的 broker 会收走一份能登录的签名口令。
inline bool broker(const std::string& url, Broker& out) {
  const size_t skip = url.rfind("tls://", 0) == 0 ? 6 : url.rfind("mqtts://", 0) == 0 ? 8 : 0;
  if (!skip || url.size() > 200) return false;
  const auto rest = url.substr(skip);
  const auto colon = rest.find(':');
  std::string host = rest.substr(0, colon);
  for (auto& c : host) c = char(tolower(static_cast<unsigned char>(c)));
  if (host.empty() || host.size() > 253 || host.front() == '.' || host.back() == '.' ||
      !only(host, "abcdefghijklmnopqrstuvwxyz0123456789.-")) return false;
  uint32_t port = 8883;
  if (colon != std::string::npos) {
    const auto digits = rest.substr(colon + 1);
    if (digits.empty() || digits.size() > 5 || !only(digits, "0123456789")) return false;
    port = uint32_t(std::stoul(digits));
    if (!port || port > 65535) return false;
  }
  const std::string domain = kBrokerDomain, dotted = std::string(".") + kBrokerDomain;
  if (host != domain && !(host.size() > dotted.size() && host.compare(host.size() - dotted.size(), dotted.size(), dotted) == 0))
    return false;
  out = {host, port};
  return true;
}

struct Credential {
  std::string device_id, core_id, secret, mqtt_url, command_topic;
  int64_t since = 0;  // 绑定时刻;更早的指令属于上一次绑定(如回滚时排队的 unbind),丢弃
};
// command_topic 形如 ah/{device_id}/v1/t/{t}/d/{device_id}/e/0/cmd/down。
inline bool credential(const cJSON* j, Credential& out) {
  using wirejson::text;
  Credential c{text(j, "device_id"), text(j, "core_id"), text(j, "secret"), text(j, "mqtt_url"), text(j, "command_topic")};
  wirejson::integer(j, "since", c.since, 0, 9007199254740991LL);
  Broker b;
  const std::string prefix = "ah/" + c.device_id + "/", suffix = "/cmd/down";
  const auto& t = c.command_topic;
  if (!device_id(c.device_id) || !core_id(c.core_id) || c.secret.empty() || c.secret.size() > 128 ||
      !broker(c.mqtt_url, b) || t.size() >= kTopicMax || t.size() <= prefix.size() + suffix.size() ||
      t.compare(0, prefix.size(), prefix) != 0 || t.compare(t.size() - suffix.size(), suffix.size(), suffix) != 0)
    return false;
  out = c;
  return true;
}
// cmd/up、state/reported、presence 与 cmd/down 同一前缀。
inline std::string topic(const Credential& c, const char* leaf) {
  return c.command_topic.substr(0, c.command_topic.size() - 9) + "/" + leaf;
}
// 用户名 thingidp@{core}|{dev}|{ts}|SHA256,口令是 hex(sha256(下面这串)):纯 SHA-256 不是 HMAC,每次连接重算。
inline std::string username(const Credential& c, int64_t ts) {
  return "thingidp@" + c.core_id + "|" + c.device_id + "|" + std::to_string(ts) + "|SHA256";
}
inline std::string password_input(const Credential& c, int64_t ts) {
  return c.device_id + "&" + std::to_string(ts) + "&SHA256" + c.secret;
}
// 固定域前缀:出厂私钥只签这一种消息,BLE 会话的持有者不能拿它签任意数据。
inline std::string proof_message(const std::string& device_id, const std::string& challenge) {
  return "xpan-dms-iotcore-pop-v1\n" + device_id + "\n" + challenge;
}
inline std::string b64url_encode(const uint8_t* p, size_t n) {
  constexpr char abc[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  std::string out;
  for (size_t i = 0; i < n; i += 3) {
    const uint32_t v = uint32_t(p[i]) << 16 | (i + 1 < n ? uint32_t(p[i + 1]) << 8 : 0) | (i + 2 < n ? p[i + 2] : 0);
    out += abc[v >> 18 & 63];
    out += abc[v >> 12 & 63];
    if (i + 1 < n) out += abc[v >> 6 & 63];
    if (i + 2 < n) out += abc[v & 63];
  }
  return out;
}

// 最近 8 个 message_id:服务端不去重,持久会话重连后会重放。
struct Seen {
  std::string ids[8];
  size_t next = 0;
  bool add(const std::string& id) {
    for (const auto& s : ids) if (s == id) return false;
    ids[next++ % 8] = id;
    return true;
  }
};
enum class Verdict { drop, expired, run };
// {"message_id","action","args","ts"},ts 为秒。
inline Verdict judge(const cJSON* m, int64_t now, int64_t since, Seen& seen) {
  const auto id = wirejson::text(m, "message_id");
  if (id.empty() || id.size() > 64 || wirejson::text(m, "action").empty()) return Verdict::drop;
  int64_t ts = 0;
  const bool stamped = wirejson::integer(m, "ts", ts, 0, 9007199254740991LL);
  if (stamped && ts < since) return Verdict::drop;
  if (!seen.add(id)) return Verdict::drop;
  return now >= kTimeOk && stamped && now - ts > kCommandTtl ? Verdict::expired : Verdict::run;
}
// card 指令 args:{title, body?, ttl_seconds?} 显示一张 agent 卡片,{clear:true} 清除全部 agent 卡片。
// 上限同 BLE 卡片特征:title+body ≤509 字节 UTF-8,ttl 1–65535 秒、默认 4 小时;整条指令 ≤1900 字节(MQTT 包含主题须装进 2048 缓冲)。
constexpr int kCardTtl = 4 * 60 * 60;
constexpr size_t kCardMax = 509;
struct Card {
  bool clear = false;
  std::string title, body;
  int ttl = kCardTtl;
};
inline bool card(const cJSON* m, Card& out) {
  const auto* args = wirejson::field(m, "args");
  if (!cJSON_IsObject(args)) return false;
  Card c;
  if (cJSON_IsTrue(wirejson::field(args, "clear"))) { c.clear = true; out = c; return true; }
  const auto* title = wirejson::field(args, "title");
  const auto* body = wirejson::field(args, "body");
  if (!cJSON_IsString(title) || (body && !cJSON_IsString(body))) return false;
  c.title = title->valuestring;
  if (body) c.body = body->valuestring;
  int64_t ttl = kCardTtl;
  if (wirejson::field(args, "ttl_seconds") && !wirejson::integer(args, "ttl_seconds", ttl, 1, 65535)) return false;
  c.ttl = int(ttl);
  if (c.title.find_first_not_of(" \t\r\n") == std::string::npos || c.title.size() + c.body.size() > kCardMax ||
      !wirejson::utf8(c.title) || !wirejson::utf8(c.body)) return false;
  out = c;
  return true;
}
// cloud 状态里的 dms:订阅确认之前不算 online,否则 Mac 会把收不到指令的设备当绑好了。
inline const char* link_state(bool bound, bool connected, bool subscribed, bool refused) {
  return !bound ? "" : connected && subscribed ? "online" : refused ? "offline" : "connecting";
}
}  // namespace dmswire
