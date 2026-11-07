# Firmware behavior checks

From the repository root:

```sh
c++ -std=c++17 -Wall -Wextra -Werror -I firmware/main firmware/tests/display_test.cpp -o /tmp/yahadesk-display-test
/tmp/yahadesk-display-test
```

This executes the same pure policy used by firmware: workbench navigation (overview row, alert header and notice-bar taps, notice paging, 60 s idle return, new alert keys opening the alert list), the long-press hint labels per alert action, independent notification expiry and pruning, and monotonic counter wrap. It does not emulate flash, Wi-Fi/BLE radio coexistence, TLS/OAuth, the CST9220 touch panel or the actual display.

Build hardware code with ESP-IDF 6.1 (`idf.py build`). The official IDF `esp_http_client/include/esp_http_client.h` documents asynchronous `perform` and response callbacks; `examples/wifi/getting_started/station` and `examples/protocols/sntp` are the network/SNTP references. IDF 6's official `examples/protocols/http_server/restful_server/main/idf_component.yml` declares `espressif/cjson ^1.7.19`.

JSON boundary checks use the official managed cJSON source after `idf.py reconfigure`:

```sh
cc -std=c99 -Wall -Wextra -Werror -c firmware/managed_components/espressif__cjson/cJSON/cJSON.c -o /tmp/yahadesk-cjson.o
c++ -std=c++17 -Wall -Wextra -Werror -I firmware/main -I firmware/managed_components/espressif__cjson/cJSON firmware/tests/display_json_test.cpp /tmp/yahadesk-cjson.o -o /tmp/yahadesk-display-json-test
/tmp/yahadesk-display-json-test
```

`desk_pull_response.sse` comes from the real Go MCP handler. `desk_pull_max_response.sse` comes from Go MCP SDK 1.8's streamable HTTP handler with 20 legal cards, each a 1-byte `T` title and a 508-byte `0x01` body. Its actual response is 135,673 bytes because the SDK returns both structured content and a JSON text content block. A six-byte JSON escape costs another seven bytes in that text block: `20 × 509 × (6 + 7) = 132,340` bytes before duplicated fields, display configuration and SSE framing. HTTP accumulation and JSON/SSE parsing therefore share a 192 KiB limit. Tests replay both actual fixtures and cover acceptance at the limit and rejection above it. `desk_pull` itself is retired (2026-11-06, control moved to DMS); the fixtures stay as real SSE parser evidence. Alert `action`/`token` pairs (workbench batch 2) are kept only for a known action with a non-empty base64url token of at most 256 bytes; an unknown action, missing, spaced, oversized or numeric token drops the pair and keeps the alert.

The configured allocator prefers the board's 8 MiB PSRAM for allocations over 1 KiB, with internal-heap fallback. This limit does not establish the runtime heap watermark or radio/audio performance; those require a device run. The eight-second transfer budget and account-change cancellation remain in effect. Speech cancels ordinary MCP requests and prevents starting a refresh; an already dispatched token refresh finishes receiving and persisting its successor before network work pauses.

Pan DMS wire format (credential/broker allow-list, MQTT username and password input, PoP message, b64url, command replay/expiry, `card` args):

```sh
c++ -std=c++17 -Wall -Wextra -Werror -I firmware/main -I firmware/managed_components/espressif__cjson/cJSON firmware/tests/dms_wire_test.cpp /tmp/yahadesk-cjson.o -o /tmp/yahadesk-dms-wire-test
/tmp/yahadesk-dms-wire-test
```

It reuses the cJSON object built above. The real broker login, TLS and PSA signing on the device are not exercised.

Concurrent RSSI sampling regression:

```sh
python3 firmware/tests/uplink_snapshot_test.py
```

This extracts and compiles the actual `snapshot()` function from `main/uplink.cpp`, including the production cache and mutex. Only hardware/time/connection inputs are stubbed. A condition variable blocks the first HCI sample while a second snapshot starts; both must return `-52` from one HCI call. The unfixed function returns cached `0` to the second caller. A one-second observation window allows that caller to run while sampling is blocked; the executable has a ten-second watchdog. `--source /path/to/old/uplink.cpp` can replay an earlier implementation. Generated source and executable live in a temporary directory that is removed after the check.

OAuth refresh interrupted by speech:

```sh
python3 firmware/tests/cloud_refresh_test.py
```

After `idf.py reconfigure` supplies cJSON, this compiles the actual production `post()`, `token()`, HTTP callbacks and NVS generation guard. Only HTTP/time/flash boundaries are simulated. It verifies that speech before the first transfer blocks dispatch, speech after refresh dispatch still persists the rotated token, following MCP work is blocked, an ordinary MCP request is canceled, and account-change cancellation and the exact eight-second deadline are preserved. It also checks that `desk_monitor` reports malformed and failed calls and clears the error on recovery, and that cloud state still carries `display_revision` for 0.2.0 Mac apps. `--cjson-dir` can select an existing official cJSON source directory; `--source` can replay an older `cloud.cpp`. No radio, flash, credentials or real service are accessed; audio coexistence still needs a device run.

Wi-Fi latency policy for the BLE audio path:

```sh
python3 firmware/tests/wifi_audio_latency_test.py
```

This extracts and compiles the production `cloud::initialize()` against radio
stubs. It verifies that `WIFI_PS_NONE` is no longer forced, so ESP-IDF's default
`WIFI_PS_MIN_MODEM` stays in effect. Wi-Fi and BLE share one radio; on 2026-11-07
in the office, `WIFI_PS_NONE` on a busy AP let only 27 of ~500 BLE audio frames
through in 30 s, against 997/997 with Wi-Fi unassociated. The real boot
acceptance is `wifi:pm start, type: 1` plus a clean stress run with Wi-Fi
associated; this host test does not establish either result.

Muted codec lifecycle regression:

```sh
python3 firmware/tests/audio_mute_lifecycle_test.py
```

This extracts and executes the production `capture_loop()` mute branch against
codec stubs. After the 240 ms fade completes, mute must close the codec without
reading warm-up frames; the final fade frame must keep it open. A deterministic
interleaving also publishes mute immediately after the capture loop snapshots
the old state and verifies that this loop cannot close the codec before the fade.
This restores the pre-2026-11-06 afternoon lifecycle after the 30-second
keep-warm experiment correlated with the text-repeat regression. The host check
does not execute the later PCM scaling/encoding path or prove the Doubao text
result; those still require an authorized flash and a real dictation test.
`--source` can replay an earlier `audio.cpp`.

Internal memory regression checks:

```sh
python3 firmware/tests/memory_layout_test.py
python3 firmware/tests/boot_memory_test.py /path/to/actual-boot.log
python3 firmware/tests/boot_memory_test.py /path/to/actual-audio-run.log --require-capture
```

The layout check reads the actual linked pool address, rather than assuming SDK configuration took effect. Before the fix, the 65,536-byte LVGL builtin pool occupied internal address `0x3fcab9f4`. The device had 92,783 free internal bytes before capture task creation but only a 31,744-byte largest block, so its required 32,768-byte internal stack could not be allocated. Wi-Fi subsequently obtained only four of ten static RX buffers. Both actual failure logs fail the boot check; a successful device run must contain real audio-task and Wi-Fi initialization milestones. `--require-capture` additionally requires positive frame intervals, beyond a BLE connection/subscription.

`main/memory.lf` selects only `lv_mem_core_builtin` with ESP-IDF's `extram_bss` scheme. `SPIRAM_ALLOW_BSS_SEG_EXTERNAL_MEMORY` also moves SDK-designated eligible Wi-Fi/LwIP BSS, as documented in `$IDF_PATH/components/esp_psram/Kconfig.spiram.common`; `SPIRAM_TRY_ALLOCATE_WIFI_LWIP` prefers PSRAM for eligible runtime allocations. Audio keeps its 32 KiB internal stack, display keeps both internal DMA buffers and Wi-Fi keeps ten RX buffers. Wi-Fi IRAM optimization remains enabled.

The RX count and Block Ack window are explicitly pinned to the original product budget, `10/6`, in tracked defaults. The boot check requires at least ten actual static RX buffers; the link check also reads the generated compile header. SDK 6.1's own PSRAM defaults are `16/16`, not `2/2`. The first resource candidate's generated local configuration unexpectedly contained `2/2`; its successful startup cannot establish the `10/6` resource budget. Removing the ignored local configuration and regenerating from tracked defaults reproduces `10/6`.

With `10/6`, the device successfully initialized Wi-Fi with 20,495 free internal bytes and a 12,288-byte largest block. The SDK's default `MBEDTLS_INTERNAL_MEM_ALLOC` forces `heap_caps_calloc(..., MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT)` in `mbedtls/port/esp_mem.c`; `mbedtls/mbedtls/library/ssl_tls.c` allocates the full input buffer, at least 16,384 bytes, during TLS setup. This exceeds that measured largest block. The firmware therefore uses the official `MBEDTLS_EXTERNAL_MEM_ALLOC` strategy (`MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT`) and the compile-header check enforces it. Boot logs record its 16 KiB input/4 KiB output buffer configuration and the 192 KiB HTTP response bound. The existing default malloc policy also prefers PSRAM for the response's large string allocations. A real Wi-Fi connection and TLS/OAuth exchange remain unverified until network provisioning; startup alone does not validate this chain.

Flash/cache constraint: `$IDF_PATH/components/spi_flash/cache_utils.c` pauses task execution on both cores and disables non-IRAM interrupts during cache-disabled flash operations. The display's zero-initialized `spi_bus_config_t` does not request `ESP_INTR_FLAG_IRAM`; `esp_driver_spi/src/gpspi/spi_master.c` uses those flags for interrupt allocation. Consequently LVGL tasks and the display completion callback do not access their PSRAM pool while caches are disabled. NVS writes, active audio/BLE with Wi-Fi, internal heap minima and capture-stack headroom still require the actual device run; the link check alone cannot prove them.

Chinese glyph and layout metrics:

```sh
python3 firmware/tests/font_metrics_test.py
```

This reads the generated fonts' real glyph maps, advances and pair kerning. It checks the workbench's fixed 28 px strings against their real label widths (row title 90 px, row text 270 px, alert row 380 px, alert hint/time column 120 px including the five long-press labels, page width 424 px), the 48 px titles and the 18 px footer status. Cloud-facing display strings are versioned in `cloud_display_strings.txt`, so the public firmware test does not depend on a private cloud-service checkout. Every listed character must exist in `font_zh_sub`; a missing glyph renders blank. The 32 px notice marquee font `font_zh_marquee` must have the same glyph map as `font_zh_sub`. Device screenshots are still needed to confirm actual rendering; metrics alone do not validate the complete display.
