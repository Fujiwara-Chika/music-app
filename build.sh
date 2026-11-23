#!/bin/bash
# Builds Music.app into ./build
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP_NAME="音乐"
BUNDLE_ID="local.aria.music"

echo "▸ swift build -c $CONFIG (arm64 only)"
swift build -c "$CONFIG"
BIN=".build/$CONFIG/MusicApp"
APP="build/$APP_NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Music"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# SwiftPM resource bundle (album covers, etc.)
for b in .build/"$CONFIG"/*.bundle; do
    [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done

if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
touch "$APP"

echo "✓ $APP  ($BUNDLE_ID)"
