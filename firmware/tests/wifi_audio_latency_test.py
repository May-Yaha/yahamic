#!/usr/bin/env python3
"""Execute production Wi-Fi initialization against deterministic radio stubs."""

import argparse
from pathlib import Path
import subprocess
import tempfile


firmware = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", type=Path, default=firmware / "main/cloud.cpp")
source = parser.parse_args().source.read_text()

start = source.index("bool initialize() {")
end = source.index("\n}\nvoid worker", start) + len("\n}")
initialize = source[start:end]

harness = r'''
#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

using esp_err_t = int;
using nvs_handle_t = int;
using esp_event_base_t = int;
using esp_event_handler_t = void (*)(void*, esp_event_base_t, int32_t, void*);
constexpr int ESP_OK = 0;
constexpr int NVS_READWRITE = 1, WIFI_STORAGE_RAM = 2, WIFI_MODE_STA = 3;
constexpr int WIFI_PS_NONE = 4, WIFI_EVENT = 5, WIFI_EVENT_STA_DISCONNECTED = 6;
constexpr int IP_EVENT = 7, IP_EVENT_STA_GOT_IP = 8;
struct wifi_init_config_t {};
#define WIFI_INIT_CONFIG_DEFAULT() wifi_init_config_t{}
#define ESP_LOGI(...) ((void)0)

std::vector<std::string> calls;
int nvs_open(const char*, int, nvs_handle_t* out) { *out = 1; return ESP_OK; }
int esp_netif_init() { return ESP_OK; }
int esp_event_loop_create_default() { return ESP_OK; }
void* esp_netif_create_default_wifi_sta() { return reinterpret_cast<void*>(1); }
int esp_wifi_init(const wifi_init_config_t*) { calls.push_back("init"); return ESP_OK; }
int esp_wifi_set_storage(int) { calls.push_back("storage"); return ESP_OK; }
int esp_wifi_set_mode(int) { calls.push_back("mode"); return ESP_OK; }
int esp_wifi_set_ps(int mode) {
  calls.push_back(mode == WIFI_PS_NONE ? "ps:none" : "ps:other");
  return ESP_OK;
}
int esp_event_handler_register(esp_event_base_t, int32_t, esp_event_handler_t, void*) { return ESP_OK; }
namespace diagnostics { void heap(const char*) {} }
void wifi_event(void*, esp_event_base_t, int32_t, void*) {}

namespace cloud {
std::atomic<bool> storage_ready{false};
nvs_handle_t storage = 0;
std::string last_error;
void error(const char* value) { last_error = value; }
''' + initialize + r'''
}

void require(bool pass, const char* message) {
  if (!pass) { std::cerr << "FAIL: " << message << '\n'; std::exit(1); }
  std::cout << "PASS: " << message << '\n';
}
int position(const char* value) {
  for (size_t i = 0; i < calls.size(); ++i) if (calls[i] == value) return int(i);
  return -1;
}
int main() {
  require(cloud::initialize(), "production Wi-Fi initialization succeeds");
  require(position("init") >= 0 && position("ps:none") < 0 && position("ps:other") < 0,
          "no power-save override; the default modem sleep leaves airtime for BLE audio");
}
'''

with tempfile.TemporaryDirectory(prefix="yahadesk-wifi-audio-") as temporary:
    cpp = Path(temporary) / "wifi_audio_test.cpp"
    binary = Path(temporary) / "wifi_audio_test"
    cpp.write_text(harness)
    subprocess.run(
        ["c++", "-std=c++17", "-Wall", "-Wextra", "-Werror", str(cpp), "-o", str(binary)],
        check=True,
        timeout=30,
    )
    result = subprocess.run([str(binary)], timeout=10)
    raise SystemExit(result.returncode)
