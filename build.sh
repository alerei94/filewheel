#!/bin/bash
# Compila ConvertiMac.swift e crea Converti.app nella stessa cartella.
# Requisiti: macOS 13+ e Xcode Command Line Tools (xcode-select --install)
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc non trovato. Installa i Command Line Tools con: xcode-select --install"
  exit 1
fi

APP="Converti.app"
ARCH="$(uname -m)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compilazione per ${ARCH} ..."
swiftc -parse-as-library -Osize -swift-version 5 -Xlinker -dead_strip \
  -target "${ARCH}-apple-macos13.0" \
  ConvertiMac.swift \
  -o "$APP/Contents/MacOS/Converti"
strip -x "$APP/Contents/MacOS/Converti"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Converti</string>
  <key>CFBundleDisplayName</key><string>Converti</string>
  <key>CFBundleIdentifier</key><string>it.local.converti</string>
  <key>CFBundleExecutable</key><string>Converti</string>
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

# Icona: se accanto allo script c'è AppIcon.png (consigliato 1024x1024) la trasforma in AppIcon.icns
if [ -f AppIcon.png ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for SIZE in 16 32 128 256 512; do
    /usr/bin/sips -z "$SIZE" "$SIZE" AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    /usr/bin/sips -z "$((SIZE * 2))" "$((SIZE * 2))" AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
  done
  /usr/bin/iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  echo "Icona inserita."
else
  echo "Nessun AppIcon.png trovato: uso l'icona generica."
fi

# Firma ad-hoc (necessaria su Apple Silicon)
codesign --force --deep --sign - "$APP"

echo "Fatto: $(pwd)/$APP"
echo "Avvio con: open \"$(pwd)/$APP\"   (vive nella barra dei menu, senza finestra)"