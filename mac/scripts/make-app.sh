#!/bin/bash
# 把 Yaha Desk 打包成 .app:构建 → 图标 → Info.plist → 签名。三条渠道同一份代码:
#   scripts/make-app.sh [--install]           dev:Apple Development 签名,本机自用(默认)
#   scripts/make-app.sh devid [--install]     官网分发:Developer ID + hardened runtime + 公证
#   scripts/make-app.sh appstore              Mac App Store:-DAPP_STORE 沙盒版 + pkg,不上传
# 公证需先由用户自己存好凭据(密码不经 agent):
#   xcrun notarytool store-credentials yahadesk --apple-id <邮箱> --team-id BB24N2QQD3
# 商店版需先下载 Mac App Store 描述文件,路径经 PROFILE=... 传入。
set -euo pipefail
cd "$(dirname "$0")/.."

CHANNEL="dev"
INSTALL=""
for arg in "$@"; do
  case "$arg" in
    dev|devid|appstore) CHANNEL="$arg" ;;
    --install) INSTALL=1 ;;
    *) echo "未知参数:$arg"; exit 2 ;;
  esac
done
[ "$CHANNEL" = "appstore" ] && [ -n "$INSTALL" ] && { echo "商店版走 TestFlight 安装,不支持 --install"; exit 2; }

APP_NAME="YahaDesk"          # 路径用 ASCII,显示名用中文
DISPLAY_NAME="Yaha Desk"
BUNDLE_ID="com.yaha.desk"
VERSION="0.4.1"  # 三端同版:Mac/iOS/设备端一致,Mac 侧勿单独升版
BUILD_NUMBER="${BUILD_NUMBER:-$VERSION}"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

# 三端同版:固件 PROJECT_VER、iOS project.yml 的版本键都必须等于 VERSION(整串匹配,0.3.0 不放过 0.3.01)。
grep -qF "set(PROJECT_VER \"$VERSION\")" ../firmware/CMakeLists.txt || { echo "固件 PROJECT_VER 与 App $VERSION 不一致"; exit 1; }
grep -qF "CFBundleShortVersionString: \"$VERSION\"" ../ios/project.yml || { echo "iOS 版本与 App $VERSION 不一致"; exit 1; }
grep -qF "MARKETING_VERSION: \"$VERSION\"" ../ios/project.yml || { echo "iOS DeskProtocol 版本与 App $VERSION 不一致"; exit 1; }

identity() {  # 钥匙串里第一个匹配前缀的签名身份
  security find-identity -v ${2:-} 2>/dev/null | grep -o "\"$1[^\"]*\"" | head -1 | tr -d '"' || true
}

echo "▸ 构建 release 二进制($CHANNEL)"
if [ "$CHANNEL" = "appstore" ]; then
  SCRATCH=".build-appstore"
  swift build -c release --product YahaDesk --scratch-path "$SCRATCH" -Xswiftc -DAPP_STORE
else
  SCRATCH=".build"
  swift build -c release --product YahaDesk
fi
# 新版 SwiftPM(swiftbuild 后端)产物在 out/Products 下,.build/release 可能只是符号链接
BIN=""
for cand in "$SCRATCH/release/YahaDesk" "$SCRATCH/out/Products/Release/YahaDesk"; do
  [ -x "$cand" ] && { BIN="$cand"; break; }
done
[ -n "$BIN" ] || { echo "构建失败:找不到 YahaDesk 二进制"; exit 1; }
PRODUCTS="$(dirname "$BIN")"
CHECKOUTS="$SCRATCH/checkouts"

echo "▸ 图标"
mkdir -p "$BUILD_DIR"
if [ ! -f "$BUILD_DIR/AppIcon.icns" ] || [ scripts/make-icon.swift -nt "$BUILD_DIR/AppIcon.icns" ]; then
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
cp "$BIN" "$APP/Contents/MacOS/YahaDesk"
cp "$BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp scripts/PrivacyInfo.xcprivacy "$APP/Contents/Resources/PrivacyInfo.xcprivacy"

echo "▸ SwiftPM 资源 bundle(含 MLX metallib)"
# MLX 运行时从主 bundle 资源目录里找 mlx-swift_Cmlx.bundle/default.metallib,
# 缺了启动即抛 "Failed to load the default metallib",必须随包携带。
for bundle in "$PRODUCTS"/*.bundle; do
  [ -d "$bundle" ] || continue
  cp -R "$bundle" "$APP/Contents/Resources/"
done
MLX_BUNDLE="$APP/Contents/Resources/mlx-swift_Cmlx.bundle"
[ -f "$MLX_BUNDLE/Contents/Resources/default.metallib" ] || { echo "缺 MLX 资源:default.metallib($PRODUCTS 下没有 mlx-swift_Cmlx.bundle?)"; exit 1; }
[ -d "$APP/Contents/Resources/FluidAudio_FluidAudio.bundle" ] || { echo "缺 FluidAudio 资源包"; exit 1; }

echo "▸ 许可证"
LICENSES_DIR="$APP/Contents/Resources/Licenses"
mkdir -p "$LICENSES_DIR"
cp ../LICENSE "$LICENSES_DIR/YahaDesk-GPL-3.0.txt"
# 必须带上的第三方/GPL 许可证:缺了直接失败,别默默漏掉
for pkg in mlx-audio-swift mlx-swift swift-huggingface FluidAudio; do
  src=""
  for cand in "$CHECKOUTS/$pkg"/LICENSE "$CHECKOUTS/$pkg"/LICENSE.* "$CHECKOUTS/$pkg"/LICENCE "$CHECKOUTS/$pkg"/COPYING; do
    [ -f "$cand" ] && { src="$cand"; break; }
  done
  [ -n "$src" ] || { echo "缺 $pkg 许可证文件:$CHECKOUTS/$pkg 下找不到 LICENSE"; exit 1; }
  cp "$src" "$LICENSES_DIR/$pkg-$(basename "$src")"
done
# 其余依赖的许可证也一并收进包里
for checkout in "$CHECKOUTS"/*; do
  [ -d "$checkout" ] || continue
  package=$(basename "$checkout")
  case " mlx-audio-swift mlx-swift swift-huggingface FluidAudio " in *" $package "*) continue ;; esac
  for license in "$checkout"/LICENSE "$checkout"/LICENSE.*; do
    [ -f "$license" ] || continue
    cp "$license" "$LICENSES_DIR/${package}-$(basename "$license")"
  done
done
cp ../LICENSES/THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"

if [ "$CHANNEL" != "appstore" ]; then  # 一键安装固件;商店版沙盒没有串口权限,不带
  FW=../firmware/build
  for f in bootloader/bootloader.bin partition_table/partition-table.bin yahadesk.bin; do
    [ -s "$FW/$f" ] || { echo "缺固件 $FW/$f:先在 firmware/ 里 idf.py build"; exit 1; }
  done
  FW_VER=$(dd if="$FW/yahadesk.bin" bs=1 skip=48 count=32 2>/dev/null | tr -d '\0')  # esp_app_desc.version
  [ "$FW_VER" = "$VERSION" ] || { echo "固件版本 $FW_VER 与 App $VERSION 不一致:重新 idf.py build"; exit 1; }
  mkdir -p "$APP/Contents/Resources/Firmware"
  cp "$FW/bootloader/bootloader.bin" "$FW/partition_table/partition-table.bin" "$FW/yahadesk.bin" \
    "$APP/Contents/Resources/Firmware/"
fi

printf 'APPL????' > "$APP/Contents/PkgInfo"
IFS=. read -r XC_MA XC_MI XC_PA <<< "$(xcodebuild -version | awk 'NR==1{print $2}')"
XC_BUILD=$(xcodebuild -version | awk 'NR==2{print $3}')
SDK_VER=$(xcrun --sdk macosx --show-sdk-version)
SDK_BUILD=$(xcrun --sdk macosx --show-sdk-build-version)
OS_BUILD=$(sw_vers -buildVersion)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>YahaDesk</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>$BUNDLE_ID.baidu-pan</string>
    <key>CFBundleURLSchemes</key><array><string>yahadesk</string></array>
  </dict></array>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>ITSAppUsesNonExemptEncryption</key><false/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Zhi.AI</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Yaha Desk 通过蓝牙连接 yahadesk 麦克风,接收音频并同步静音状态。</string>
  <key>DTXcode</key><string>${XC_MA}${XC_MI:-0}${XC_PA:-0}</string>
  <key>DTXcodeBuild</key><string>$XC_BUILD</string>
  <key>DTSDKName</key><string>macosx$SDK_VER</string>
  <key>DTSDKBuild</key><string>$SDK_BUILD</string>
  <key>DTPlatformName</key><string>macosx</string>
  <key>DTPlatformVersion</key><string>$SDK_VER</string>
  <key>DTPlatformBuild</key><string>$SDK_BUILD</string>
  <key>DTCompiler</key><string>com.apple.compilers.llvm.clang.1_0</string>
  <key>BuildMachineOSBuild</key><string>$OS_BUILD</string>
</dict>
</plist>
PLIST

case "$CHANNEL" in
  dev)
    # 优先 Apple Development 证书:身份稳定,辅助功能等授权重新打包后仍有效;没有才 ad-hoc。
    IDENTITY=$(identity "Apple Development: " "-p codesigning")
    echo "▸ 签名:${IDENTITY:-ad-hoc(重新打包后需重新授权辅助功能)}"
    codesign --force --sign "${IDENTITY:--}" "$APP"
    ;;
  devid)
    IDENTITY=$(identity "Developer ID Application: " "-p codesigning")
    [ -n "$IDENTITY" ] || { echo "缺 Developer ID Application 证书:在 Xcode → Settings → Accounts 里创建"; exit 1; }
    echo "▸ 签名(hardened runtime):$IDENTITY"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
    ;;
  appstore)
    IDENTITY=$(identity "Apple Distribution: " "-p codesigning")
    [ -n "$IDENTITY" ] || { echo "缺 Apple Distribution 证书"; exit 1; }
    [ -f "${PROFILE:-}" ] || { echo "缺描述文件:PROFILE=<Mac App Store .provisionprofile 路径> $0 appstore"; exit 1; }
    cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
    echo "▸ 签名(沙盒):$IDENTITY"
    codesign --force --timestamp --entitlements scripts/appstore.entitlements --sign "$IDENTITY" "$APP"
    ;;
esac
codesign --verify --strict "$APP"

if [ "$CHANNEL" = "devid" ]; then
  ZIP="$BUILD_DIR/$APP_NAME-$VERSION.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  if xcrun notarytool history --keychain-profile yahadesk >/dev/null 2>&1; then
    echo "▸ 公证(几分钟)"
    xcrun notarytool submit "$ZIP" --keychain-profile yahadesk --wait
    xcrun stapler staple "$APP"
    ditto -c -k --keepParent "$APP" "$ZIP"  # 重打包带上公证票据
  else
    echo "⚠️ 未找到公证凭据 yahadesk(或查询失败),跳过公证:别的 Mac 会被 Gatekeeper 拦下"
    mv "$ZIP" "${ZIP%.zip}-unnotarized.zip"
    ZIP="${ZIP%.zip}-unnotarized.zip"
  fi
  echo "✓ 官网分发包:$ZIP"
fi

if [ "$CHANNEL" = "appstore" ]; then
  INSTALLER=$(identity "3rd Party Mac Developer Installer: ")
  [ -n "$INSTALLER" ] || INSTALLER=$(identity "Mac Installer Distribution: ")
  [ -n "$INSTALLER" ] || { echo "缺 Mac Installer Distribution 证书"; exit 1; }
  PKG="$BUILD_DIR/$APP_NAME-$VERSION-$BUILD_NUMBER.pkg"
  productbuild --component "$APP" /Applications --sign "$INSTALLER" "$PKG"
  echo "✓ 商店包:$PKG(上传:Transporter 或 xcrun altool,需单独授权)"
  exit 0
fi

if [ -n "$INSTALL" ]; then
  echo "▸ 安装到 /Applications 并启动"
  pkill -x YahaDesk 2>/dev/null || true
  sleep 1
  rm -rf "/Applications/$APP_NAME.app"  # 只动自己:yahamic 的 Yaha Home 是另一个 App
  cp -R "$APP" "/Applications/$APP_NAME.app"
  open "/Applications/$APP_NAME.app"
  echo "✓ 「${DISPLAY_NAME}」已启动:看顶栏的桌面设备图标。日志:~/Library/Logs/YahaDesk.log"
else
  echo "✓ 产物:$APP(加 --install 安装到 /Applications)"
fi
