#!/bin/bash
# Command Line Tools only: no Xcode.app, no asset catalog, ad-hoc signing.
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/GlassMonitor.app"

swift build -c "$CONFIG"
BIN=".build/x86_64-apple-macosx/$CONFIG/GlassMonitor"
[[ -x "$BIN" ]] || { echo "missing $BIN" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GlassMonitor"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>GlassMonitor</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIdentifier</key><string>app.glassmonitor.panel</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>玻璃监控</string>
	<key>CFBundleDisplayName</key><string>玻璃监控</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.1.1</string>
	<key>CFBundleVersion</key><string>3</string>
	<key>LSMinimumSystemVersion</key><string>26.0</string>
	<key>LSUIElement</key><true/>
	<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSSupportsAutomaticTermination</key><false/>
	<key>NSHumanReadableCopyright</key><string>Local build. No telemetry, no network.</string>
</dict>
</plist>
PLIST

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
