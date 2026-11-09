#!/usr/bin/env python3
"""Compile the production refresh flow with deterministic HTTP and NVS boundaries."""

import argparse
from pathlib import Path
import subprocess
import tempfile


firmware = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", type=Path, default=firmware / "main/cloud.cpp")
parser.add_argument("--cjson-dir", type=Path, default=firmware / "managed_components/espressif__cjson/cJSON")
args = parser.parse_args()
source = args.source.read_text()
# Keep the real globals, generation guard, NVS serialization, HTTP callbacks,
# post() and token(). Only radio/time/flash APIs below are simulated.
production = source[source.index("// Fixed origin"):source.index("void wifi_event(")]
start = source.index("std::string status() {")
production += source[start:source.index("\n}\n", start) + len("\n}\n")]

harness = r'''
#include "cloud.h"
#include "display_json.h"
#include "uplink.h"
#include <atomic>
#include <cassert>
#include <cstring>
#include <iostream>
#include <map>
#include <mutex>
#include <strings.h>

using esp_err_t = int;
using nvs_handle_t = int;
constexpr int ESP_OK = 0, ESP_FAIL = -1, ESP_ERR_HTTP_EAGAIN = 1;
constexpr int HTTP_EVENT_ON_HEADER = 1, HTTP_EVENT_ON_DATA = 2, HTTP_METHOD_POST = 3;
void* esp_crt_bundle_attach = nullptr;
struct esp_http_client_event_t {
  void* user_data; int event_id; const char* header_key; const char* header_value;
  int data_len; const void* data;
};
struct esp_http_client_config_t {
  const char* url; int method, timeout_ms; bool disable_auto_redirect;
  void* crt_bundle_attach; esp_err_t (*event_handler)(esp_http_client_event_t*);
  void* user_data; bool is_async; int buffer_size_tx;
};
struct Client { esp_http_client_config_t cfg; int step = 0, status = 0; };
using esp_http_client_handle_t = Client*;
enum class Interrupt { none, speech_before_dispatch, speech, speech_during_response, account, timeout };
Interrupt interrupt = Interrupt::none;
uint32_t clock_ms = 0;
int requests = 0, performs = 0, commits = 0;
std::map<std::string, std::string> durable;

int64_t esp_timer_get_time() { return int64_t(clock_ms) * 1000; }
void vTaskDelay(int) {}
#define pdMS_TO_TICKS(x) x
#define ESP_LOGI(...) ((void)0)
int nvs_get_str(int, const char* key, char* out, size_t* size) {
  const auto found = durable.find(key);
  if (found == durable.end()) return ESP_FAIL;
  const auto& value = found->second;
  if (out) { if (*size < value.size() + 1) return ESP_FAIL; std::memcpy(out, value.c_str(), value.size() + 1); }
  *size = value.size() + 1;
  return ESP_OK;
}
int nvs_set_str(int, const char* key, const char* value) { durable[key] = value; return ESP_OK; }
int nvs_commit(int) { ++commits; return ESP_OK; }
esp_http_client_handle_t esp_http_client_init(const esp_http_client_config_t* cfg) { ++requests; return new Client{*cfg}; }
std::string mcp_reply;  // non-empty: the MCP response body for the next request
namespace dms {
void add_status(cJSON*) {}
void add_report(cJSON* j) { cJSON_AddStringToObject(j, "ssid", "lab"); }
}
namespace uplink { bool muted() { return true; } Snapshot snapshot() { return {}; } }
std::string posted;
int esp_http_client_set_header(Client*, const char*, const char*) { return ESP_OK; }
int esp_http_client_set_post_field(Client*, const char*, int);
int esp_http_client_get_status_code(Client* client) { return client->status; }
void esp_http_client_cleanup(Client* client) { delete client; }
esp_err_t esp_http_client_perform(Client* client);

namespace cloud {
''' + production + r'''
}

int esp_http_client_set_post_field(Client*, const char* body, int size) {
  posted.assign(body, size);
  if (interrupt == Interrupt::speech_before_dispatch) cloud::speaking = true;
  return ESP_OK;
}
esp_err_t esp_http_client_perform(Client* client) {
  ++performs;
  if (client->step++ == 0) {
    // The server has accepted the request and consumed the old refresh token.
    if (interrupt == Interrupt::speech) cloud::speaking = true;
    if (interrupt == Interrupt::account) {
      ++cloud::grant_epoch;
      durable["grant"] = R"({"generation":"other","client_id":"other-client","refresh_token":"other-refresh"})";
    }
    if (interrupt == Interrupt::timeout) clock_ms = 8000;
    return ESP_ERR_HTTP_EAGAIN;
  }
  if (interrupt == Interrupt::speech_during_response) cloud::speaking = true;
  client->status = 200;
  esp_http_client_event_t header{client->cfg.user_data, HTTP_EVENT_ON_HEADER, "Content-Type", "application/json", 0, nullptr};
  client->cfg.event_handler(&header);
  const std::string body = !mcp_reply.empty() ? mcp_reply
      : R"({"access_token":"next-access","refresh_token":"next-refresh","expires_in":3600})";
  esp_http_client_event_t data{client->cfg.user_data, HTTP_EVENT_ON_DATA, nullptr, nullptr, int(body.size()), body.data()};
  // ESP-IDF dispatches these notifications without propagating callback errors.
  client->cfg.event_handler(&data);
  return ESP_OK;
}

void reset(Interrupt next) {
  using namespace cloud;
  interrupt = next; clock_ms = 0; requests = 0; performs = 0; commits = 0;
  speaking = false; wifi_up = true; storage_ready = true; grant_epoch = 0;
  generation = "original"; client_id = "device"; refresh_token = "old-refresh";
  access_token.clear(); access_until = 0;
  view.authorized = true; view.error.clear();
  durable["grant"] = R"({"generation":"original","client_id":"device","refresh_token":"old-refresh"})";
}
void require(bool pass, const char* message) {
  if (!pass) { std::cerr << "FAIL: " << message << '\n'; std::exit(1); }
  std::cout << "PASS: " << message << '\n';
}
int main() {
  using namespace cloud;
  reset(Interrupt::speech_before_dispatch);
  require(!token() && performs == 0 && commits == 0 && refresh_token == "old-refresh",
          "speech during request setup blocks refresh before its first dispatch");
  reset(Interrupt::speech);
  const bool refreshed = token();
  auto saved = wirejson::parse(durable["grant"]);
  require(refreshed && refresh_token == "next-refresh" && access_token == "next-access" &&
          wirejson::text(saved.get(), "refresh_token") == "next-refresh" && commits == 1,
          "speech after refresh dispatch retains and persists the rotated token");
  int status = 0;
  require(!post(kMcpURL, "{}", false, status) && requests == 1,
          "speech blocks the following MCP request");

  reset(Interrupt::speech);
  require(!post(kMcpURL, "{}", false, status) && commits == 0,
          "speech cancels an in-flight ordinary MCP request");

  reset(Interrupt::speech_during_response);
  require(token() && wirejson::text(wirejson::parse(durable["grant"]).get(), "refresh_token") == "next-refresh",
          "speech starting inside the response callback still persists refresh");
  reset(Interrupt::speech_during_response);
  require(!post(kMcpURL, "{}", false, status),
          "speech starting inside the response callback discards MCP content");

  reset(Interrupt::account);
  require(!token() && commits == 0 && durable["grant"].find("other-refresh") != std::string::npos,
          "account change still cancels refresh and preserves the new grant");

  reset(Interrupt::timeout);
  require(!token() && commits == 0 && refresh_token == "old-refresh",
          "refresh retains the exact eight-second deadline");

  reset(Interrupt::none);
  speaking = true;
  require(!token() && requests == 0 && commits == 0,
          "refresh never starts while speech is already active");

  // 0.2.0 Mac apps decode display_revision as required and drop cloud state without it.
  // desk_pull is gone (2026-11-06, control moved to DMS): desk_monitor now owns clearing sync errors.
  reset(Interrupt::none);
  access_token = "a"; access_until = 3600000;
  mcp_reply = R"({"jsonrpc":"2.0","id":1,"result":{"structuredContent":{"at":1,"sections":"bad","alerts":[]}}})";
  monitor();
  require(view.error == "invalid_monitor", "a malformed desk_monitor is reported");
  mcp_reply = R"({"jsonrpc":"2.0","id":1,"result":{"isError":true}})";
  monitor();
  require(view.error == "sync_failed", "a failed desk_monitor call is reported");
  mcp_reply = R"({"jsonrpc":"2.0","id":1,"result":{"structuredContent":{"at":1,"sections":[],"alerts":[]}}})";
  firmware = "0.3.0";
  monitor();
  require(view.error.empty(), "a recovered desk_monitor clears the error");
  require(posted.find(R"("arguments":{"firmware":"0.3.0","muted":true,"mac":false,"ssid":"lab"})") != std::string::npos,
          "desk_monitor carries the device report for desk_status");
  mcp_reply.clear();

  require(cloud::status().find("\"display_revision\":0") != std::string::npos,
          "cloud state keeps display_revision for 0.2.0 Mac apps");
  require(cloud::status().find("\"battery\":-1,\"charging\":false,\"usb_power\":false") != std::string::npos,
          "cloud state reports no battery until the battery task has read one");
}
'''

with tempfile.TemporaryDirectory(prefix="yahadesk-cloud-refresh-") as temporary:
    directory = Path(temporary)
    cpp, binary, cjson = directory / "refresh_test.cpp", directory / "refresh_test", directory / "cjson.o"
    cpp.write_text(harness)
    subprocess.run(["cc", "-std=c99", "-c", str(args.cjson_dir / "cJSON.c"), "-o", str(cjson)], check=True, timeout=30)
    subprocess.run(["c++", "-std=c++17", "-Wall", "-Wextra", "-Werror", "-I", str(firmware / "main"),
                    "-I", str(args.cjson_dir), str(cpp), str(cjson), "-o", str(binary)], check=True, timeout=30)
    result = subprocess.run([str(binary)], timeout=10)
    raise SystemExit(result.returncode)
