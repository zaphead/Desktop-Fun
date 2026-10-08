#!/bin/zsh
# Builds DeskDuck.app (release) into ./build
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/DeskDuck.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DeskDuck "$APP/Contents/MacOS/DeskDuck"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Desk Duck</string>
  <key>CFBundleDisplayName</key><string>Desk Duck</string>
  <key>CFBundleIdentifier</key><string>cloud.sharpstack.deskduck</string>
  <key>CFBundleExecutable</key><string>DeskDuck</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Desk Duck reads where your desktop icons are so it can hop on them, and nudges them around when it goes surfing.</string>
</dict>
</plist>
PLIST
# Sign with a stable identity when one exists so macOS remembers the Finder permission across rebuilds.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP"
