#!/usr/bin/env python3
"""Check the last real device boot for audio/Wi-Fi resource startup regressions."""

import argparse
from pathlib import Path
import re


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("log", type=Path)
parser.add_argument("--require-capture", action="store_true")
args = parser.parse_args()
log = args.log.read_text(errors="replace")
log = log[log.rfind("ESP-ROM:"):] if "ESP-ROM:" in log else log
failures = []
for signature in ("capture task didn't start", "no microphone", "malloc buffer fail",
                  "Expected to init", "WiFi init failed", "Guru Meditation", "CORRUPT HEAP"):
    if signature in log:
        failures.append(signature)
for milestone in ("audio: ready: ES7210 + Opus", "heap: audio stack ready", "heap: WiFi init ready",
                  "heap: TLS allocator=PSRAM input=16384 output=4096 response_max=196608"):
    if milestone not in log:
        failures.append("missing " + milestone)
rx = re.findall(r"wifi:Init static rx buffer num:\s*(\d+)", log)
if not rx or int(rx[-1]) < 10:
    failures.append("static RX buffer count below product budget 10: " + (rx[-1] if rx else "missing"))
else:
    print("Actual Wi-Fi static RX buffer count=" + rx[-1])
if args.require_capture and not re.search(r"采集 [1-9]\d*/[1-9]\d*/[1-9]\d* ms", log):
    failures.append("missing real capture frame intervals")
for line in log.splitlines():
    if "heap:" in line and ("audio before 32768 stack" in line or "WiFi init ready" in line):
        print(line)
if failures:
    print("Device boot regression FAILED: " + "; ".join(failures))
    raise SystemExit(1)
print("Device boot resource regression passed" + (" with real capture" if args.require_capture else ""))
