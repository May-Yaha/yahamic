#!/usr/bin/env python3
"""Compile the production snapshot function against a blocked HCI sampling stub."""

import argparse
from pathlib import Path
import subprocess
import tempfile


firmware = Path(__file__).resolve().parents[1]
args = argparse.ArgumentParser(description=__doc__)
args.add_argument("--source", type=Path, default=firmware / "main/uplink.cpp")
source = args.parse_args().source.read_text()
start = source.index("Snapshot snapshot() {")
end = source.index("\n}\n", start) + len("\n}")
snapshot = source[start:end]  # Compile the original function without rewriting its cache/locks.

harness = r'''
#include "uplink.h"
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <future>
#include <iostream>
#include <mutex>

namespace uplink {
constexpr uint16_t BLE_HS_CONN_HANDLE_NONE = 0xffff;
constexpr uint32_t kRssiEveryMs = 2000;
std::atomic<uint16_t> conn{1};
std::atomic<uint32_t> passkey{0};
std::atomic<bool> muted_{true};
std::mutex gate;
std::condition_variable changed;
bool hci_started = false, second_started = false, release_hci = false;
int hci_calls = 0;
thread_local bool second_caller = false;
uint32_t now_ms() { return 2000; }
bool live() {
  if (second_caller) {
    std::lock_guard<std::mutex> guard(gate);
    second_started = true;
    changed.notify_all();
  }
  return false;
}
int ble_gap_conn_rssi(uint16_t, int8_t* out) {
  std::unique_lock<std::mutex> guard(gate);
  ++hci_calls;
  hci_started = true;
  changed.notify_all();
  changed.wait(guard, [] { return release_hci; });
  *out = -52;
  return 0;
}
size_t strlcpy(char* dst, const char* src, size_t size) {
  return size_t(std::snprintf(dst, size, "%s", src));
}
''' + snapshot + r'''
}
int main() {
  using namespace uplink;
  auto first = std::async(std::launch::async, snapshot);
  {
    std::unique_lock<std::mutex> guard(gate);
    changed.wait(guard, [] { return hci_started; });
  }
  auto second = std::async(std::launch::async, [] {
    second_caller = true;
    return snapshot();
  });
  {
    std::unique_lock<std::mutex> guard(gate);
    changed.wait(guard, [] { return second_started; });
  }
  // HCI stays blocked while the second caller can expose the old cached zero.
  // With the production mutex, the second caller waits for the same sample.
  second.wait_for(std::chrono::seconds(1));
  {
    std::lock_guard<std::mutex> guard(gate);
    release_hci = true;
  }
  changed.notify_all();
  const auto a = first.get(), b = second.get();
  std::cout << "snapshot RSSI: first=" << a.rssi << " second=" << b.rssi
            << " HCI calls=" << hci_calls << '\n';
  return a.rssi == -52 && b.rssi == -52 && hci_calls == 1 ? 0 : 1;
}
'''

with tempfile.TemporaryDirectory(prefix="yahadesk-snapshot-") as temporary:
    directory = Path(temporary)
    cpp, binary = directory / "snapshot_test.cpp", directory / "snapshot_test"
    cpp.write_text(harness)
    subprocess.run(
        ["c++", "-std=c++17", "-Wall", "-Wextra", "-Werror", "-pthread",
         "-I", str(firmware / "main"), str(cpp), "-o", str(binary)],
        check=True, timeout=30,
    )
    result = subprocess.run([str(binary)], timeout=10)
    raise SystemExit(result.returncode)
