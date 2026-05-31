#!/bin/bash
# Build Transposify and assemble a runnable, ad-hoc-signed .app bundle.
# A real .app bundle (not a bare binary) is required so macOS can attach the
# Info.plist usage strings and prompt for audio-capture permission.
set -euo pipefail
cd "$(dirname "$0")"

APP="Transposify.app"
CONFIG="${1:-release}"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/Transposify"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Transposify"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> ad-hoc codesign"
codesign --force --sign - \
    --entitlements Resources/Transposify.entitlements \
    "$APP"

echo "==> done: $(pwd)/$APP"
echo "    Run it with:  open $APP"
