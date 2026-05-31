#!/bin/bash
#
# Transposify — one-step build & install.
#
# Builds the app from source on your Mac and installs it to /Applications.
# Because it's compiled locally, macOS doesn't quarantine it, so no Apple
# Developer account or notarization is needed — an ad-hoc signature is enough
# and there's no "unidentified developer" warning.
#
set -euo pipefail
cd "$(dirname "$0")"

APP="Transposify.app"
BUNDLE_ID="com.evanhu.transposify"

echo "==> Checking prerequisites"
osver="$(sw_vers -productVersion)"
major="${osver%%.*}"; rest="${osver#*.}"; minor="${rest%%.*}"
if [ "$major" -lt 14 ] || { [ "$major" -eq 14 ] && [ "${minor:-0}" -lt 4 ]; }; then
    echo "Error: requires macOS 14.4 or later (for Core Audio process taps). You have $osver." >&2
    exit 1
fi
if ! command -v swift >/dev/null 2>&1; then
    echo "Error: the Swift toolchain wasn't found. Install Apple's command-line tools:" >&2
    echo "    xcode-select --install" >&2
    exit 1
fi
if [ ! -d "/Applications/Spotify.app" ]; then
    echo "Note: Spotify isn't in /Applications — install the Spotify desktop app to use this."
fi

echo "==> Building and signing (first build takes a minute)"
./make-app.sh

# Stop any running copy so the fresh build takes over.
pkill -f "$APP/Contents/MacOS/Transposify" 2>/dev/null || true
# Clean up the previous "Transposer" name, if a prior version was installed.
pkill -f "Transposer.app/Contents/MacOS/Transposer" 2>/dev/null || true
rm -rf "/Applications/Transposer.app" "$HOME/Applications/Transposer.app" 2>/dev/null || true
sleep 0.5

if [ -w /Applications ]; then
    DEST="/Applications"
else
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
    echo "==> /Applications isn't writable; installing to $DEST instead"
fi

echo "==> Installing to $DEST"
rm -rf "${DEST:?}/$APP"
cp -R "$APP" "$DEST/"

echo "==> Launching"
open "$DEST/$APP"

cat <<EOF

✓ Installed to $DEST/$APP

On first launch macOS asks for Microphone access — that's the permission Core
Audio uses to capture Spotify's audio; it never touches your real mic. Click
Allow, then look for the 𝄞 in your menu bar.

Uninstall:  rm -rf "$DEST/$APP" && tccutil reset Microphone $BUNDLE_ID
EOF
