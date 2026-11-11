#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release
APP="$PWD/dist/Desktop Snow.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/DesktopSnow "$APP/Contents/MacOS/DesktopSnow"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DesktopSnow</string>
<key>CFBundleIdentifier</key><string>local.desktop-snow.pixel</string>
<key>CFBundleName</key><string>Desktop Snow</string>
<key>CFBundleDisplayName</key><string>Desktop Snow</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Keep the local development identity stable across rebuilds so macOS permissions
# can match the designated requirement rather than a different executable hash.
codesign --force --sign - --requirements '=designated => identifier "local.desktop-snow.pixel"' "$APP"
print "Built: $APP"
