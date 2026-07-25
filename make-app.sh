#!/bin/bash
# Builds PenBridge.app (arm64, release) from the Swift package.
set -e
cd "$(dirname "$0")"
swift build -c release --arch arm64
APP="PenBridge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/PenBridge "$APP/Contents/MacOS/PenBridge"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>PenBridge</string>
    <key>CFBundleDisplayName</key><string>PenBridge</string>
    <key>CFBundleIdentifier</key><string>local.penbridge</string>
    <key>CFBundleExecutable</key><string>PenBridge</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><true/>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$APP" 2>/dev/null || true
echo "Built $APP"
