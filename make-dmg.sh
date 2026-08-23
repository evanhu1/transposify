#!/bin/bash
#
# Transposify — build a distributable .dmg.
#
#   ./make-dmg.sh                       ad-hoc signed (first launch needs "Open Anyway")
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" ./make-dmg.sh
#   SIGN_IDENTITY=... NOTARY_PROFILE=transposify ./make-dmg.sh   also notarize + staple
#
# The app downloads its own model on first use, so the bundle alone is a
# complete install. What the DMG cannot carry is trust: a copy that arrives
# by download is quarantined, and Gatekeeper only waves it through if it is
# signed with a Developer ID and notarized. Without those, macOS 15 shows
# "Apple could not verify…" and the user has to allow it once in
# System Settings ▸ Privacy & Security. The README explains that step.
#
# NOTARY_PROFILE names credentials stored once with
#   xcrun notarytool store-credentials transposify --apple-id ... --team-id ...
#
set -euo pipefail
cd "$(dirname "$0")"

APP="Transposify.app"
VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
OUT="dist"
DMG="$OUT/Transposify-$VERSION.dmg"
STAGE="$OUT/stage"

echo "==> building"
./make-app.sh >/dev/null

if [ -n "${SIGN_IDENTITY:-}" ]; then
    echo "==> signing with $SIGN_IDENTITY (hardened runtime)"
    codesign --force --deep --timestamp --options runtime \
        --sign "$SIGN_IDENTITY" \
        --entitlements Resources/Transposify.entitlements "$APP"
else
    echo "==> ad-hoc signature (set SIGN_IDENTITY for a Developer ID build)"
fi
codesign --verify --strict "$APP"

echo "==> assembling $DMG"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Transposify $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG"
rm -rf "$STAGE"

if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        echo "==> notarizing (this waits for Apple; a few minutes)"
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
        echo "==> Gatekeeper check"
        spctl --assess --type open --context context:primary-signature -v "$DMG"
    else
        echo "==> not notarized (set NOTARY_PROFILE); downloads will still be blocked"
    fi
fi

echo
echo "✓ $DMG  ($(du -h "$DMG" | cut -f1))"
echo "  sha256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
