#pragma once
#include <string>
#include "display.h"

namespace cloud {
struct View {
  uint32_t generation = 0;
  display::Monitor monitor;
  uint32_t monitor_ms = 0;  // now_ms() of the last good desk_monitor; 0 before the first
  display::Notices notices;
  bool wifi_connected = false;
  bool authorized = false;
  std::string error;
  std::string operation;      // last desk_operate result for the alert page header
  uint32_t operation_ms = 0;  // now_ms() when `operation` changed
};
void start(const char* firmware);
void pause(bool speaking);
// NimBLE boundary: validate, commit a bounded NVS record, then enqueue network work.
// Successful BLE write response confirms durable delivery; HTTP never runs on the BLE task.
bool provision(const char* json, size_t size);
std::string status();
// Latest scan as `{"scan":n,"networks":[{ssid,rssi,secure}]}`, ≤512 bytes; `{"op":"scan"}` requests a new one.
std::string wifi_networks();
View snapshot();
void shown(const std::string& kind, const std::string& key);
// DMS card 指令(dms.cpp 已用 dmswire::card 校验):key 为 message_id,同 key 覆盖同一张卡。
bool agent_card(const std::string& key, const std::string& title, const std::string& body, int ttl);
void clear_agent_cards();
// Long-pressed alert (desk.operate): queue one token + action for the worker; false while one is in flight.
// The server verifies the signed token, owner and current task state; the device never builds targets.
bool operate(const std::string& token, const std::string& action);
}  // namespace cloud
