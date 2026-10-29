#!/bin/bash
# Builds Pagewright.app with the Xcode Command Line Tools (full Xcode is not needed).
#   bash build.sh                  build
#   bash build.sh && open Pagewright.app
# Requirements: macOS 13+ and the Command Line Tools:  xcode-select --install
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install the Command Line Tools with: xcode-select --install"
  exit 1
fi

SRC_DIR="$(pwd)"
OUT="${1:-$SRC_DIR}"                 # optional: build into another folder (the Update button does this)
mkdir -p "$OUT"
APP="$OUT/Pagewright.app"
ARCH="$(uname -m)"
BUILT_AT="$(date +%s)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Building for ${ARCH} ..."
swiftc -parse-as-library -Osize -swift-version 5 -Xlinker -dead_strip \
  -target "${ARCH}-apple-macos13.0" \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/Pagewright"
strip -x "$APP/Contents/MacOS/Pagewright"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Pagewright</string>
  <key>CFBundleDisplayName</key><string>Pagewright</string>
  <key>CFBundleIdentifier</key><string>local.pagewright</string>
  <key>CFBundleExecutable</key><string>Pagewright</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>PagewrightSourceDir</key><string>$SRC_DIR</string>
  <key>PagewrightBuiltAt</key><string>$BUILT_AT</string>
</dict>
</plist>
PLIST

# Icon: Resources/icon.png (1024x1024) becomes AppIcon.icns
if [ -f Resources/icon.png ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for SIZE in 16 32 128 256 512; do
    /usr/bin/sips -z "$SIZE" "$SIZE" Resources/icon.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    /usr/bin/sips -z "$((SIZE * 2))" "$((SIZE * 2))" Resources/icon.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
  done
  /usr/bin/iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  echo "Icon added."
fi

# Ad-hoc signature (required on Apple Silicon)
codesign --force --deep --sign - "$APP"

echo "Done: $APP"
echo "Check it first with:  \"$APP/Contents/MacOS/Pagewright\" --self-test"
echo "Then open it with:    open \"$APP\""
