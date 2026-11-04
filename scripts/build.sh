#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$(pwd)/build/Windows QoL.app"
mkdir -p "$APP/Contents/MacOS"
EXT="$APP/Contents/PlugIns/Open Terminal Here.appex"
mkdir -p "$EXT/Contents/MacOS"
swiftc -swift-version 5 -O -parse-as-library -module-name WindowsQoLFinder Sources/FinderExtension.swift -o "$EXT/Contents/MacOS/WindowsQoLFinder" -framework Cocoa -framework FinderSync -Xlinker -e -Xlinker _NSExtensionMain
cat > "$EXT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Open Terminal Here</string>
<key>CFBundleDisplayName</key><string>Open Terminal Here</string>
<key>CFBundleIdentifier</key><string>local.dan.windowsqol.finder</string>
<key>CFBundleExecutable</key><string>WindowsQoLFinder</string>
<key>CFBundlePackageType</key><string>XPC!</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>NSExtension</key><dict>
<key>NSExtensionPointIdentifier</key><string>com.apple.FinderSync</string>
<key>NSExtensionPrincipalClass</key><string>WindowsQoLFinderExtension</string>
</dict></dict></plist>
PLIST
codesign --force --sign - --entitlements Sources/FinderExtension.entitlements -r '=designated => identifier "local.dan.windowsqol.finder"' "$EXT"
swiftc -swift-version 5 -O Sources/WindowsQoL.swift -o "$APP/Contents/MacOS/WindowsQoL" -framework AppKit -framework ApplicationServices
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Windows QoL</string>
<key>CFBundleIdentifier</key><string>local.dan.windowsqol</string>
<key>CFBundleExecutable</key><string>WindowsQoL</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Windows QoL controls System Events to change Dock auto-hide without restarting the Dock.</string>
</dict></plist>
PLIST
# Keep the designated requirement stable between local ad-hoc builds. This is
# not a developer identity and does not provide publisher authentication.
codesign --force --sign - -r '=designated => identifier "local.dan.windowsqol"' "$APP"
