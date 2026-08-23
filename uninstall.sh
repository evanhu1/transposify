#!/bin/bash
#
# Transposify — remove everything the app put on this Mac.
#
#   ./uninstall.sh                  remove the app, the model, settings, caches
#   ./uninstall.sh --keep-settings  keep per-song transposes and preferences
#
# The app lives in more places than /Applications: the separation model in
# Application Support, preferences (including the saved transpose for every
# song), download and artwork caches, a launch-at-login registration, and two
# privacy permissions. Deleting only the bundle leaves all of that behind, and
# a later ./install-model.sh then reports the model as already installed.
#
set -uo pipefail
cd "$(dirname "$0")"

BUNDLE_ID="com.evanhu.transposify"
KEEP_SETTINGS=0
for arg in "$@"; do
    case "$arg" in
        --keep-settings) KEEP_SETTINGS=1 ;;
        *) echo "usage: $0 [--keep-settings]" >&2; exit 2 ;;
    esac
done

# A bundle that still exists can unregister its own login item; one that has
# already been deleted cannot, and macOS keeps a dead entry in Login Items.
unregister_login_item() {
    local app="$1"
    if [ -x "$app/Contents/MacOS/Transposify" ]; then
        TRANSPOSIFY_UNREGISTER_LOGIN=1 "$app/Contents/MacOS/Transposify" >/dev/null 2>&1 || true
    fi
}

echo "==> Quitting Transposify"
pkill -f "Transposify.app/Contents/MacOS/Transposify" 2>/dev/null || true
pkill -f "Transposer.app/Contents/MacOS/Transposer" 2>/dev/null || true
sleep 0.5

echo "==> Removing the app"
for app in /Applications/Transposify.app "$HOME/Applications/Transposify.app" \
           /Applications/Transposer.app "$HOME/Applications/Transposer.app"; do
    [ -d "$app" ] || continue
    unregister_login_item "$app"
    rm -rf "$app"
    echo "    removed $app"
done

echo "==> Removing the separation model"
rm -rf "$HOME/Library/Application Support/Transposify" \
       "$HOME/Library/Application Support/Transposer"

echo "==> Removing caches"
rm -rf "$HOME/Library/Caches/$BUNDLE_ID" "$HOME/Library/Caches/Transposify" \
       "$HOME/Library/Caches/com.evanhu.transposer" "$HOME/Library/Caches/Transposer" \
       "$HOME/Library/HTTPStorages/$BUNDLE_ID" "$HOME/Library/HTTPStorages/Transposify" \
       "$HOME/Library/HTTPStorages/com.evanhu.transposer" \
       "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"

if [ "$KEEP_SETTINGS" -eq 0 ]; then
    echo "==> Removing settings (per-song transposes included)"
    # The app's own domain, the one the headless tools use, and the old name.
    for domain in "$BUNDLE_ID" Transposify com.evanhu.transposer Transposer; do
        defaults delete "$domain" >/dev/null 2>&1 || true
        rm -f "$HOME/Library/Preferences/$domain.plist"
    done
else
    echo "==> Keeping settings (--keep-settings)"
fi

echo "==> Resetting privacy permissions"
tccutil reset AudioCapture "$BUNDLE_ID" >/dev/null 2>&1 || true
tccutil reset Microphone "$BUNDLE_ID" >/dev/null 2>&1 || true
tccutil reset AppleEvents "$BUNDLE_ID" >/dev/null 2>&1 || true

# The login-item table is macOS's and only the app can edit its own row, and
# reading it (sfltool dumpbtm) needs an administrator password, so this does
# not check. If the app ever launched at login, one look is enough.
cat <<EOF

    If System Settings ▸ General ▸ Login Items & Extensions still shows a
    "Transposify" row, remove it there with the "−" button. macOS keys that
    table by code signature, so a row can outlive the copy that made it.
EOF

echo
echo "✓ Transposify is uninstalled."
