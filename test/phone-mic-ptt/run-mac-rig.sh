#!/bin/bash
# 编译 mac-rig.swift 并包成 .app 再启动:macOS 只认 .app 里的 NSBluetoothAlwaysUsageDescription,
# 裸命令行程序一用 CoreBluetooth 就被 TCC 以 SIGABRT 杀掉(-sectcreate 嵌 Info.plist 也不行)。
#   ./run-mac-rig.sh a|b      输出写到 /tmp/ptt-spike-<路线>.log
set -euo pipefail
cd "$(dirname "$0")"
ROUTE="${1:-}"
[[ "$ROUTE" == a || "$ROUTE" == b ]] || { echo "用法:$0 a|b"; exit 2; }

APP=/tmp/PTTSpike.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
swiftc -O mac-rig.swift -o "$APP/Contents/MacOS/ptt-spike"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.yaha.desk.pttspike.mac</string>
<key>CFBundleExecutable</key><string>ptt-spike</string>
<key>LSUIElement</key><true/>
<key>NSBluetoothAlwaysUsageDescription</key><string>模拟讲话键,验证手机 PushToTalk 后台触发。</string>
</dict></plist>
EOF
codesign -s - --force "$APP"
LOG="/tmp/ptt-spike-$ROUTE.log"
: > "$LOG"
open -n "$APP" --stdout "$LOG" --stderr "$LOG" --args "$ROUTE"
echo "已启动,日志:tail -f $LOG;结束:pkill -f PTTSpike.app"
