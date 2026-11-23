#!/bin/bash
# Plain SwiftPM build: no Xcode project or asset catalog, ad-hoc signing.
set -euo pipefail

# SwiftUI 宏插件只随完整 Xcode 提供；只装 Command Line Tools 时 App target
# 无法编译（Core 与 sysdump 仍可单独构建）。如果系统默认仍是 CLT、但装了
# Xcode，就自动切到 Xcode；CI 已选好的 Xcode 不会被覆盖。
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  SELECTED="$(xcode-select -p 2>/dev/null || true)"
  if [[ "$SELECTED" == "/Library/Developer/CommandLineTools" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  fi
fi
TOOLCHAIN="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"
if [[ "$TOOLCHAIN" == "/Library/Developer/CommandLineTools" ]]; then
  echo "error: GlassMonitor 需要完整 Xcode（SwiftUI 宏不在 Command Line Tools 中）。" >&2
  echo "       安装 Xcode 后无需改脚本；只想看传感器可用 swift build --product sysdump。" >&2
  exit 1
fi

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/GlassMonitor.app"

# 版本号只有一个来源：根目录 VERSION。构建号默认取提交数，CI 可用
# BUILD_NUMBER 覆盖，保证 Info.plist 里的两个字段不需要手工同步。
VERSION="$(tr -d '[:space:]' < VERSION)"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: VERSION 必须是 x.y.z 形式，当前为 '$VERSION'" >&2
  exit 1
fi
BUILD_NUMBER="${BUILD_NUMBER:-}"
if [[ -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
fi
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "error: BUILD_NUMBER 必须是整数，当前为 '$BUILD_NUMBER'" >&2
  exit 1
fi

swift build -c "$CONFIG"
# 产物路径随工具链和架构变化（arm64/x86_64、.build/release 或 .build/out/...），
# 交给 SwiftPM 给出，不能写死。
BIN="$(swift build -c "$CONFIG" --show-bin-path)/GlassMonitor"
[[ -x "$BIN" ]] || { echo "missing $BIN" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GlassMonitor"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>GlassMonitor</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIdentifier</key><string>app.glassmonitor.panel</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>GlassMonitor</string>
	<key>CFBundleDisplayName</key><string>GlassMonitor</string>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleLocalizations</key>
	<array>
		<string>en</string>
		<string>zh-Hans</string>
	</array>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>${VERSION}</string>
	<key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
	<key>LSMinimumSystemVersion</key><string>26.0</string>
	<key>LSUIElement</key><true/>
	<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSSupportsAutomaticTermination</key><false/>
	<key>NSHumanReadableCopyright</key><string>Local build. No telemetry, no network.</string>
</dict>
</plist>
PLIST

# Localized resources use the standard .lproj layout. Bundle.main reads this
# directory directly, so the app needs no SwiftPM resource bundle.
for lproj in Resources/*.lproj; do
  [[ -d "$lproj" ]] || continue
  cp -R "$lproj" "$APP/Contents/Resources/"
done

if [[ -f Resources/AppIcon.png ]]; then
  ICONDIR="$(mktemp -d)"
  ICONSET="$ICONDIR/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  /usr/bin/iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONDIR"
fi

xattr -cr "$APP"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1
echo "built $APP"
