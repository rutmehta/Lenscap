#!/usr/bin/env bash
# Builds Lenscap in release mode and assembles a minimal dist/Lenscap.app bundle.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Building Lenscap (release)…"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/Lenscap"
APP="dist/Lenscap.app"

echo "==> Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Lenscap"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.rutmehta.lenscap</string>
    <key>CFBundleName</key>
    <string>Lenscap</string>
    <key>CFBundleExecutable</key>
    <string>Lenscap</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> Ad-hoc code signing…"
codesign --force --deep -s - dist/Lenscap.app

echo
echo "Done: ${APP}"
echo
echo "Next steps:"
echo "  1. Move Lenscap.app wherever you like (e.g. /Applications)."
echo "  2. First launch: right-click Lenscap.app > Open (it is ad-hoc signed, not notarized)."
echo "  3. Grant Screen Recording permission when prompted:"
echo "     System Settings > Privacy & Security > Screen Recording."
echo "  4. Look for the Lenscap camera icon in your menu bar."
