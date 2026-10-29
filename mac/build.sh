#!/bin/bash
# Compiles FileWheel.swift and creates FileWheel.app in the same folder.
# Requirements: macOS 13+ and Xcode Command Line Tools (xcode-select --install)
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install the Command Line Tools with: xcode-select --install"
  exit 1
fi

APP="FileWheel.app"
ARCH="$(uname -m)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Building for ${ARCH} ..."
swiftc -parse-as-library -Osize -swift-version 5 -Xlinker -dead_strip \
  -target "${ARCH}-apple-macos13.0" \
  FileWheel.swift \
  -o "$APP/Contents/MacOS/FileWheel"
strip -x "$APP/Contents/MacOS/FileWheel"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>FileWheel</string>
  <key>CFBundleDisplayName</key><string>FileWheel</string>
  <key>CFBundleIdentifier</key><string>local.filewheel</string>
  <key>CFBundleExecutable</key><string>FileWheel</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
EOF

# Icon: if AppIcon.png (1024x1024 recommended) is next to this script, it is turned into AppIcon.icns
if [ -f AppIcon.png ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for SIZE in 16 32 128 256 512; do
    /usr/bin/sips -z "$SIZE" "$SIZE" AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    /usr/bin/sips -z "$((SIZE * 2))" "$((SIZE * 2))" AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
  done
  /usr/bin/iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  echo "Icon added."
else
  echo "No AppIcon.png found: using the generic icon."
fi

# Ad-hoc signature (required on Apple Silicon)
codesign --force --deep --sign - "$APP"

echo "Done: $(pwd)/$APP"
echo "Launch with: open \"$(pwd)/$APP\"   (it lives in the menu bar, with no window)"
