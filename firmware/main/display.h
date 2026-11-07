#pragma once

#include <algorithm>
#include <cstdint>
#include <string>
#include <vector>

// Pure display policy: no BLE, network, flash or UI dependencies.
namespace display {
// desk_monitor result (yahaops-api domain/desk/monitor.go); sections arrive in fixed order.
struct Section {
  std::string key, title, level, summary;  // level: ok / warn / error, empty when unavailable
  bool available = false;
  std::vector<std::string> lines;
  std::vector<int64_t> trend;
};
struct Alert {
  std::string key, section, level, title;
  int64_t at = 0;
  std::string action, token;  // desk.operate only; the server verifies the signed token, not the device
};
// Row hint for an actionable alert; empty for unknown actions, which the parser already drops.
inline std::string hold_label(const std::string& action) {
  if (action == "retry") return "长按重试";
  if (action == "cancel") return "长按取消";
  if (action == "pause") return "长按暂停";
  if (action == "resume") return "长按恢复";
  if (action == "run") return "长按补跑";
  return "";
}
struct Monitor {
  int64_t at = 0;
  std::vector<Section> sections;
  std::vector<Alert> alerts;
};

// Home exposes microphone, articles and daily reports; only admins see the workbench entry.
// Notice supports previous/next, pause and a cycling speed button.
enum class Page { Home, Overview, Detail, Alerts, Notice };
constexpr int kRows = 5;  // cloud sections; Detail(kRows) is the local device
constexpr int kTapNone = -1, kTapAlerts = 100, kTapHub = 102, kTapDevice = 103;
constexpr int kTapPrev = 104, kTapNext = 105, kTapPause = 106, kTapArticle = 107, kTapDaily = 108;
constexpr int kTapSpeedCycle = 109, kTapEnd = 113, kSpeeds = 3;
constexpr uint32_t kIdleMs = 60000;
// A tap this soon after a page switch was aimed at the previous page (taps queue for about a frame).
constexpr uint32_t kSettleMs = 250;

class Workbench {
 public:
  Page page() const { return page_; }
  size_t index() const { return index_; }
  bool marquee_paused() const { return paused_; }
  // An alert key not in the previous poll opens the list; keys that clear and return count as new.
  void alerts(const std::vector<Alert>& list, uint32_t now) {
    std::vector<std::string> keys;
    bool fresh = false;
    for (const auto& a : list) {
      fresh |= std::find(seen_.begin(), seen_.end(), a.key) == seen_.end();
      keys.push_back(a.key);
    }
    seen_ = std::move(keys);
    if (fresh) open(Page::Alerts, 0, now);
  }
  void push_notice(size_t index, size_t notices, uint32_t now) {
    if (page_ == Page::Home && index < notices) open(Page::Notice, index, now);
  }
  void tap(int target, size_t notices, uint32_t now, size_t selected = 0) {
    if (uint32_t(now - last_) < kSettleMs) return;
    if (page_ == Page::Home) {
      if (target == kTapHub) open(Page::Overview, 0, now);
      else if ((target == kTapArticle || target == kTapDaily) && notices)
        open(Page::Notice, selected < notices ? selected : 0, now);
      else if (target == kTapDevice) open(Page::Detail, kRows, now);
    } else if (page_ == Page::Overview) {
      if (target == kTapAlerts) open(Page::Alerts, 0, now);
      else if (target >= 0 && target < kRows) open(Page::Detail, size_t(target), now);
      else open(Page::Home, 0, now);
    } else if (page_ == Page::Notice && target == kTapPrev) {
      open(Page::Notice, index_ ? index_ - 1 : 0, now);
    } else if (page_ == Page::Notice && target == kTapNext && index_ + 1 < notices) {
      open(Page::Notice, index_ + 1, now);
    } else if (page_ == Page::Notice && target == kTapEnd) {
      open(Page::Home, 0, now);
    } else if (page_ == Page::Notice && target == kTapPause) {
      paused_ = !paused_, last_ = now;
    } else if (page_ == Page::Notice && target == kTapSpeedCycle) {
      last_ = now;
    } else {
      const bool cloud = page_ == Page::Alerts || (page_ == Page::Detail && index_ < size_t(kRows));
      open(cloud ? Page::Overview : Page::Home, 0, now);
    }
  }
  void tick(uint32_t now, size_t notices) {
    if (page_ != Page::Home &&
        (uint32_t(now - last_) >= kIdleMs || (page_ == Page::Notice && index_ >= notices)))
      open(Page::Home, 0, now);
  }
  // Pairing and speech cover the workbench: keep the page and restart its idle minute.
  void hold(uint32_t now) { last_ = now; }
  void reset() { *this = Workbench{}; }
 private:
  void open(Page p, size_t i, uint32_t now) { page_ = p, index_ = i, last_ = now, paused_ = false; }
  Page page_ = Page::Home;
  size_t index_ = 0;
  uint32_t last_ = 0;
  bool paused_ = false;
  std::vector<std::string> seen_;
};

struct Notice {
  std::string kind, key, title, body;
  uint32_t expires = 0;
  bool active(uint32_t now) const { return !title.empty() && int32_t(expires - now) > 0; }
};

// Remembers only agent cards that were actually opened. Active cards that have not been shown stay
// pending regardless of their TTL, so an older long-lived card cannot hide a later short-lived one.
class AgentNoticeQueue {
 public:
  size_t next(const std::vector<Notice>& items, bool can_open) {
    std::vector<std::string> active;
    for (const auto& item : items) if (item.kind == "agent") active.push_back(signature(item));
    for (auto it = shown_.begin(); it != shown_.end();) {
      if (std::find(active.begin(), active.end(), *it) == active.end()) it = shown_.erase(it);
      else ++it;
    }
    if (can_open) {
      for (size_t i = 0; i < items.size(); ++i) {
        if (items[i].kind != "agent") continue;
        const auto value = signature(items[i]);
        if (std::find(shown_.begin(), shown_.end(), value) == shown_.end()) {
          shown_.push_back(value);
          return i;
        }
      }
    }
    return items.size();
  }
  void clear() { shown_.clear(); }
 private:
  static std::string signature(const Notice& item) {
    return item.key + "\x1f" + item.title + "\x1f" + item.body;
  }
  std::vector<std::string> shown_;
};

class Notices {
 public:
  bool put(const std::string& kind, const std::string& key, const std::string& title,
           const std::string& body, int ttl, uint32_t now) {
    if (ttl < 1 || ttl > 65535 || title.empty() || title.size() + body.size() > 509) return false;
    for (auto& n : items_) {
      if ((kind != "agent" && n.kind == kind) || (n.kind == kind && n.key == key)) {
        n = {kind, key, title, body, now + uint32_t(ttl) * 1000};
        return true;
      }
    }
    prune(now);
    // shortcut: 20 pending agent messages + 2 feed cards; retain newest on sustained overflow.
    if (items_.size() == 22) items_.erase(items_.begin());
    items_.push_back({kind, key, title, body, now + uint32_t(ttl) * 1000});
    return true;
  }
  void clear_agent() {
    for (auto it = items_.begin(); it != items_.end();) {
      if (it->kind == "agent") it = items_.erase(it); else ++it;
    }
  }
  bool active(uint32_t now) {
    prune(now);
    for (const auto& n : items_) if (n.active(now)) return true;
    return false;
  }
  size_t size(uint32_t now) {
    prune(now);
    return items_.size();
  }
  Notice get(size_t index, uint32_t now) {
    const size_t count = size(now);
    if (!count) return {};
    return items_[index % count];
  }
 private:
  void prune(uint32_t now) {
    for (auto it = items_.begin(); it != items_.end();) {
      if (!it->active(now)) it = items_.erase(it); else ++it;
    }
  }
  std::vector<Notice> items_;
};
}  // namespace display
