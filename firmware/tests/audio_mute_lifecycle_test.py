#!/usr/bin/env python3
"""Execute the production muted capture branch against codec stubs."""

import argparse
from pathlib import Path
import subprocess
import tempfile


firmware = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", type=Path, default=firmware / "main/audio.cpp")
source = parser.parse_args().source.read_text()
start = source.index("void capture_loop(void*) {")
end = source.index("    if (!open) {", start)
capture_prefix = source[start:end]
capture_prefix = capture_prefix.replace(
    "int16_t frame[kFrameSamples];", "int16_t frame[kFrameSamples];\n  (void)frame;"
)
capture_prefix = capture_prefix.replace("bool open = false;", "bool open = true;")
capture_prefix = capture_prefix.replace("for (;;) {", "for (int iteration = 0; iteration < 1; ++iteration) {")
capture_prefix += "  }\n}\n"

harness = r'''
#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <iostream>

constexpr int kFrameSamples = 960;
constexpr int ESP_CODEC_DEV_OK = 0;
[[maybe_unused]] constexpr int64_t kWarmUs = 30 * 1000 * 1000;
void* mics = nullptr;
std::atomic<bool> running{true};
class TestMuted {
 public:
  TestMuted& operator=(bool next) { value = next; return *this; }
  bool load() {
    const bool current = value;
    if (publish_mute_after_load) value = true;
    return current;
  }
  operator bool() const { return value; }

  bool value = true;
  bool publish_mute_after_load = false;
};
TestMuted muted_;
std::atomic<int> fade_left{0};
std::atomic<int64_t> muted_at_us{0};
int64_t capture_last_read_us = 123;
int close_count = 0;
int read_count = 0;

int pdMS_TO_TICKS(int value) { return value; }
void vTaskDelay(int) {}
int64_t esp_timer_get_time() { return 1; }
int esp_codec_dev_close(void*) { ++close_count; return 0; }
int esp_codec_dev_read(void*, int16_t*, size_t) { ++read_count; return ESP_CODEC_DEV_OK; }
bool open_mic() { return true; }
''' + capture_prefix + r'''

void require(bool pass, const char* message) {
  if (!pass) { std::cerr << "FAIL: " << message << '\n'; std::exit(1); }
  std::cout << "PASS: " << message << '\n';
}

int main() {
  muted_ = true;
  muted_.publish_mute_after_load = false;
  fade_left = 0;
  close_count = read_count = 0;
  capture_loop(nullptr);
  require(close_count == 1 && read_count == 0,
          "mute closes the codec immediately after the fade instead of keeping it warm");

  fade_left = 1;
  close_count = read_count = 0;
  capture_loop(nullptr);
  require(close_count == 0 && read_count == 0, "the final fade frame keeps the codec open");

  muted_ = false;
  muted_.publish_mute_after_load = true;
  fade_left = 4;
  close_count = read_count = 0;
  capture_loop(nullptr);
  require(close_count == 0,
          "a mute published after the loop snapshot cannot skip the fade by closing the codec");
}
'''

with tempfile.TemporaryDirectory(prefix="yahadesk-audio-mute-") as temporary:
    cpp = Path(temporary) / "audio_mute_test.cpp"
    binary = Path(temporary) / "audio_mute_test"
    cpp.write_text(harness)
    subprocess.run(
        ["c++", "-std=c++17", "-Wall", "-Wextra", "-Werror", str(cpp), "-o", str(binary)],
        check=True,
        timeout=30,
    )
    result = subprocess.run([str(binary)], timeout=10)
    raise SystemExit(result.returncode)
