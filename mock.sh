#!/bin/bash
# Render the popover design gallery and open it.
#
# The point of this script is the loop time: a debug build of one changed file
# takes under a second, and rendering the variants takes about a fifth of one.
# Edit Sources/Transposify/DesignGallery.swift, run this, look. There is no
# need to sign, install, relaunch, or click the menu bar to judge a layout —
# the variants are real AppKit views, so what you see here is what ships.
#
#   ./mock.sh            render and open
#   ./mock.sh --watch    re-render on every save
set -euo pipefail
cd "$(dirname "$0")"

OUT=".build/gallery.png"

render() {
    swift build -c debug 2>&1 | grep -E "error:" && return 1
    TRANSPOSIFY_GALLERY="$OUT" .build/debug/Transposify
}

if [ "${1:-}" = "--watch" ]; then
    command -v fswatch >/dev/null || {
        echo "error: --watch needs fswatch (brew install fswatch)" >&2; exit 1; }
    render || true
    open "$OUT"
    echo "==> watching Sources/Transposify — ctrl-C to stop"
    fswatch -o Sources/Transposify | while read -r _; do
        printf '\n==> change detected\n'
        render || true
    done
else
    render
    open "$OUT"
fi
