#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>
#include "cJSON.h"
#include "display.h"

namespace wirejson {
// 20 cards × 509 UTF-8 bytes × (6 structured + 7 text-content escape bytes)
// = 132340 bytes, plus duplicated metadata/SSE framing. 192 KiB bounds both
// the HTTP accumulator and parser, including legal six-byte control/HTML escapes.
constexpr size_t kResponseMax = 192 * 1024;
using Json = std::unique_ptr<cJSON, decltype(&cJSON_Delete)>;
inline Json parse(const std::string& s) {
  const char* end = nullptr;
  Json j(cJSON_ParseWithLengthOpts(s.c_str(), s.size() + 1, &end, true), cJSON_Delete);
  return j;
}
// Go MCP SDK 1.8 streamable.go requires both Accept types; its default response is SSE.
// This is a bounded POST response reader, not a persistent SSE subscription.
inline void response_event(const std::string& data, Json& last) {
  auto j = parse(data);
  const auto* id = cJSON_GetObjectItemCaseSensitive(j.get(), "id");
  if (cJSON_IsNumber(id) && id->valuedouble == 1 &&
      (cJSON_GetObjectItemCaseSensitive(j.get(), "result") || cJSON_GetObjectItemCaseSensitive(j.get(), "error")))
    last = std::move(j);
}
inline void sse_line(std::string line, std::string& data, Json& last) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (line.empty()) { response_event(data, last); data.clear(); }
    else if (line.compare(0, 5, "data:") == 0) {
      if (!data.empty()) data += '\n';
      data += line.substr(line.size() > 5 && line[5] == ' ' ? 6 : 5);
    }
}
inline Json parse_sse(const std::string& body) {
  Json last(nullptr, cJSON_Delete);
  std::string data;
  size_t start = 0;
  while (start <= body.size()) {
    const auto end = body.find('\n', start);
    auto line = body.substr(start, end == std::string::npos ? end : end - start);
    sse_line(line, data, last);
    if (end == std::string::npos) break;
    start = end + 1;
  }
  if (!data.empty()) response_event(data, last);
  return last;
}
inline Json parse_http(const std::string& body, const std::string& content_type) {
  if (body.size() > kResponseMax) return Json(nullptr, cJSON_Delete);
  if (content_type.compare(0, 16, "application/json") == 0) return parse(body);
  if (content_type.compare(0, 17, "text/event-stream") == 0) return parse_sse(body);
  return Json(nullptr, cJSON_Delete);
}
inline Json object() { return Json(cJSON_CreateObject(), cJSON_Delete); }
inline std::string encode(const cJSON* j) {
  char* p = cJSON_PrintUnformatted(j);
  if (!p) return {};
  std::string s(p);
  cJSON_free(p);
  return s;
}
inline const cJSON* field(const cJSON* j, const char* key) { return cJSON_GetObjectItemCaseSensitive(j, key); }
inline std::string text(const cJSON* j, const char* key) {
  const auto* v = field(j, key);
  return cJSON_IsString(v) ? v->valuestring : "";
}
inline bool integer(const cJSON* j, const char* key, int64_t& out, int64_t min, int64_t max) {
  const auto* v = field(j, key);
  if (!cJSON_IsNumber(v) || !std::isfinite(v->valuedouble) || std::floor(v->valuedouble) != v->valuedouble ||
      v->valuedouble < double(min) || v->valuedouble > double(max)) return false;
  out = int64_t(v->valuedouble);
  return true;
}
inline bool valid_wifi(const cJSON* j) {
  const auto ssid = text(j, "ssid"), password = text(j, "password");
  return cJSON_IsString(field(j, "password")) && !ssid.empty() && ssid.size() <= 32 &&
      password.size() <= 63 && (password.empty() || password.size() >= 8);
}
inline bool valid_grant(const cJSON* j) {
  const auto id = text(j, "client_id"), token = text(j, "refresh_token");
  return !id.empty() && id.size() <= 128 && !token.empty() && token.size() <= 256;
}
// SSIDs are raw radio bytes; one invalid UTF-8 name makes the Mac reject the whole list.
inline bool utf8(const std::string& s) {
  for (size_t i = 0; i < s.size(); ++i) {
    const unsigned char c = s[i];
    if (c < 0x80) continue;
    const size_t n = c >= 0xC2 && c <= 0xDF ? 1 : c >= 0xE0 && c <= 0xEF ? 2 : c >= 0xF0 && c <= 0xF4 ? 3 : 0;
    if (!n || i + n >= s.size()) return false;
    const unsigned char d = s[i + 1];
    if ((c == 0xE0 && d < 0xA0) || (c == 0xED && d > 0x9F) || (c == 0xF0 && d < 0x90) || (c == 0xF4 && d > 0x8F))
      return false;
    for (size_t k = 1; k <= n; ++k)
      if ((static_cast<unsigned char>(s[i + k]) & 0xC0) != 0x80) return false;
    i += n;
  }
  return true;
}
// Clip to `max` bytes without splitting a UTF-8 sequence (input already validated).
inline std::string clip(std::string s, size_t max) {
  if (s.size() <= max) return s;
  size_t n = max;
  while (n && (static_cast<unsigned char>(s[n]) & 0xC0) == 0x80) --n;
  s.resize(n);
  return s;
}
inline bool monitor_text(const cJSON* j, const char* key, std::string& out) {
  const auto* v = field(j, key);
  if (!cJSON_IsString(v) || !utf8(v->valuestring)) return false;
  out = clip(v->valuestring, 160);
  return true;
}
inline bool monitor_level(const std::string& level) {
  return level == "ok" || level == "warn" || level == "error";
}
// shortcut: clips to 5 sections × 8 lines × 7 trend points and 20 alerts — the API sends at most that.
inline bool monitor(const cJSON* j, display::Monitor& out) {
  display::Monitor m;
  const auto* sections = field(j, "sections");
  const auto* alerts = field(j, "alerts");
  if (!integer(j, "at", m.at, 0, 9007199254740991LL) || !cJSON_IsArray(sections) || !cJSON_IsArray(alerts))
    return false;
  const cJSON* s = nullptr;
  cJSON_ArrayForEach(s, sections) {
    if (m.sections.size() == 5) break;
    display::Section sec;
    const auto* available = field(s, "available");
    const auto* lines = field(s, "lines");
    const auto* trend = field(s, "trend");
    if (!cJSON_IsBool(available) || !cJSON_IsArray(lines) || (trend && !cJSON_IsArray(trend)) ||
        !monitor_text(s, "key", sec.key) || !monitor_text(s, "title", sec.title) ||
        !monitor_text(s, "summary", sec.summary)) return false;
    sec.available = cJSON_IsTrue(available);
    if (field(s, "level") && !monitor_text(s, "level", sec.level)) return false;
    if (sec.available ? !monitor_level(sec.level) : !(sec.level.empty() || monitor_level(sec.level))) return false;
    const cJSON* item = nullptr;
    cJSON_ArrayForEach(item, lines) {
      if (!cJSON_IsString(item) || !utf8(item->valuestring)) return false;
      if (sec.lines.size() < 8) sec.lines.push_back(clip(item->valuestring, 160));
    }
    cJSON_ArrayForEach(item, trend) {
      const double v = cJSON_IsNumber(item) ? item->valuedouble : -1;  // daily counts; bound keeps bar math in range
      if (!(v >= 0 && v <= 1e9) || std::floor(v) != v) return false;
      sec.trend.push_back(int64_t(v));
    }
    // Trend is oldest to newest; keep the most recent seven days.
    if (sec.trend.size() > 7) sec.trend.erase(sec.trend.begin(), sec.trend.end() - 7);
    m.sections.push_back(std::move(sec));
  }
  const cJSON* a = nullptr;
  cJSON_ArrayForEach(a, alerts) {
    if (m.alerts.size() == 20) break;
    display::Alert alert;
    if (!monitor_text(a, "key", alert.key) || !monitor_text(a, "section", alert.section) ||
        !monitor_text(a, "level", alert.level) || !monitor_text(a, "title", alert.title) ||
        (alert.level != "warn" && alert.level != "error") ||
        !integer(a, "at", alert.at, 0, 9007199254740991LL)) return false;
    // Optional desk.operate pair: a malformed one only hides the long press, the alert still shows.
    const std::string action = text(a, "action"), token = text(a, "token");
    if (!display::hold_label(action).empty() && !token.empty() && token.size() <= 256 &&
        token.find_first_not_of("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.") == std::string::npos)
      alert.action = action, alert.token = token;
    m.alerts.push_back(std::move(alert));
  }
  out = std::move(m);
  return true;
}

struct Network {
  std::string ssid;
  int rssi;
  bool secure;
};
// Input is strongest first. Hidden, invalid and repeated names are dropped; the result fits one 512-byte attribute.
// `scan` matches the cloud status `wifi_scan` counter so the Mac never shows an older list as fresh.
inline std::string network_list(uint32_t scan, const std::vector<Network>& found) {
  auto j = object();
  cJSON_AddNumberToObject(j.get(), "scan", scan);
  auto* list = cJSON_AddArrayToObject(j.get(), "networks");
  std::vector<std::string> seen;
  for (const auto& n : found) {
    if (n.ssid.empty() || n.ssid.size() > 32 || !utf8(n.ssid) ||
        std::find(seen.begin(), seen.end(), n.ssid) != seen.end()) continue;
    auto* item = cJSON_CreateObject();
    cJSON_AddStringToObject(item, "ssid", n.ssid.c_str());
    cJSON_AddNumberToObject(item, "rssi", n.rssi);
    cJSON_AddBoolToObject(item, "secure", n.secure);
    cJSON_AddItemToArray(list, item);
    if (encode(j.get()).size() > 512) { cJSON_DeleteItemFromArray(list, cJSON_GetArraySize(list) - 1); break; }
    seen.push_back(n.ssid);
  }
  return encode(j.get());
}
} // namespace wirejson
