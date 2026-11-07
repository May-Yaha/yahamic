#!/usr/bin/env python3
"""Verify the actual linked LVGL pool uses ESP32-S3 PSRAM, preserving internal RAM."""

from pathlib import Path
import re
import sys


link_map = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / "build/yahadesk.map"
match = re.search(
    r"^\s+\.bss\.work_mem_int\S*\s*\n\s*(0x[0-9a-f]+)\s+(0x[0-9a-f]+)"
    r"[^\n]*liblvgl__lvgl\.a\(lv_mem_core_builtin\.c\.obj\)",
    link_map.read_text(), re.MULTILINE,
)
if not match:
    raise SystemExit("LVGL pool missing from link map; inspect the allocator contract")
address, size = (int(value, 16) for value in match.groups())
print(f"Linked LVGL pool address={address:#x} size={size}")
if not 0x3C000000 <= address < 0x3E000000:
    raise SystemExit("LVGL pool is in internal RAM; audio/Wi-Fi resource regression")
print("Linked LVGL pool uses PSRAM")
header = link_map.parent / "config/sdkconfig.h"
if header.exists():
    config = header.read_text()
    for key, expected in (("ESP_WIFI_STATIC_RX_BUFFER_NUM", 10), ("ESP_WIFI_RX_BA_WIN", 6)):
        value = re.search(r"^#define CONFIG_" + key + r" (\d+)$", config, re.MULTILINE)
        if not value or int(value[1]) != expected:
            raise SystemExit(f"Compiled {key} differs from product budget {expected}")
    print("Compiled Wi-Fi RX budget: static=10 BA=6")
    if "#define CONFIG_MBEDTLS_EXTERNAL_MEM_ALLOC 1" not in config or "#define CONFIG_MBEDTLS_INTERNAL_MEM_ALLOC 1" in config:
        raise SystemExit("TLS must use the official PSRAM allocator; internal largest block is below 16 KiB")
    print("Compiled TLS allocator: PSRAM")
    # The ignored local sdkconfig keeps old "is not set" lines; only a regenerated config picks up the defaults.
    for key in ("CONN_UPDATE", "CHAN_MAP_UPDATE", "PHY_UPDATE"):
        if f"#define CONFIG_BT_CTRL_BLE_LLCP_{key} 1" not in config:
            raise SystemExit(f"BT_CTRL_BLE_LLCP_{key} off: delete sdkconfig and reconfigure (controller asserted on instant passed)")
    print("Compiled BLE LLCP: disconnect on instant passed")
