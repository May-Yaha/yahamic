#!/bin/bash
# 把 Yaha Home 打包成 .app:构建 → 图标 → Info.plist → 签名(ad-hoc)。
#   scripts/make-app.sh            → build/Yaha Home.app
#   scripts/make-app.sh --install  → 另外复制到 /Applications 并启动
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="YahaHome"          # 路径用 ASCII,显示名用中文
DISPLAY_NAME="Yaha 家居"
BUNDLE_ID="com.yaha.home"
VERSION="0.4.0"  # 与固件对齐(firmware/CMakeLists.txt PROJECT_VER),Mac 侧勿单独升版
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "▸ 构建 release 二进制"
swift build -c release --product YahaHome 2>&1 | grep -E "error|warning: unre" || true
BIN=".build/release/YahaHome"
[ -x "$BIN" ] || { echo "构建失败"; exit 1; }

echo "▸ 图标"
mkdir -p "$BUILD_DIR"
if [ ! -f "$BUILD_DIR/AppIcon.icns" ]; then
  swift scripts/make-icon.swift "$BUILD_DIR/AppIcon-1024.png" >/dev/null
  ICONSET="$BUILD_DIR/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$BUILD_DIR/AppIcon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s*2))
    sips -z $d $d "$BUILD_DIR/AppIcon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$BUILD_DIR/AppIcon.icns"
  rm -rf "$ICONSET"
fi

echo "▸ 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/YahaHome"
cp "$BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>YahaHome</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT · yahamic</string>
  <key>NSMicrophoneUsageDescription</key><string>yahamic 需要访问麦克风以采集音频,用于无线麦克风功能。</string>
</dict>
</plist>
PLIST

# 签名:优先用 Xcode 的 Apple Development 证书——身份稳定,辅助功能等授权在重新
# 打包后仍然有效;没有证书才退回 ad-hoc(每次重打包都得重新授权)。
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')
if [ -n "$IDENTITY" ]; then
  echo "▸ 签名:$IDENTITY"
  codesign --force --deep --sign "$IDENTITY" "$APP" 2>&1 | grep -v "replacing existing signature" || true
else
  echo "▸ 签名(ad-hoc,无开发者证书:重新打包后需重新授权辅助功能)"
  codesign --force --deep --sign - "$APP" 2>&1 | grep -v "replacing existing signature" || true
fi

if [ "${1:-}" = "--install" ]; then
  echo "▸ 安装到 /Applications 并启动"
  pkill -x YahaHome 2>/dev/null || true
  sleep 1
  rm -rf "/Applications/$APP_NAME.app" "/Applications/Yaha Home.app"
  cp -R "$APP" "/Applications/$APP_NAME.app"
  open "/Applications/$APP_NAME.app"
  echo "✓ 「${DISPLAY_NAME}」已启动:看顶栏的麦克风图标。日志:~/Library/Logs/YahaHome.log"
else
  echo "✓ 产物:$APP(加 --install 安装到 /Applications)"
fi
