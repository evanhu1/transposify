#!/bin/bash
#
# Run Transposify live with separation quality maximised and latency ignored.
#
#   tools/quality-mode.sh                 max quality, ~2 s behind Spotify
#   tools/quality-mode.sh --lookahead 2   even more future context, ~3 s behind
#   tools/quality-mode.sh --normal        the shipping config, for A/B
#
# This is an experiment, not a mode of the app: nothing here is persisted and
# quitting the app returns you to the installed defaults. Ctrl-C also quits it.
#
# Four things are traded for quality, largest effect first. The model itself
# is deliberately unchanged: same six-stem htdemucs_6s, same stems, same
# tiles — only how it is converted and driven differs from the shipping build.
#
#   1. Window. 7.8 s, the length the model was trained on, instead of 3 s.
#      This is the big one: the shipping window was cut to 3 s purely to make
#      predictions cheap enough for a 0.15 s hop.
#   2. Precision. FP32 instead of FP16.
#   3. Lookahead. A second of future context instead of 0.12 s.
#   4. Hop. Large, which suits the slower model and raises the average
#      future context every emitted sample gets.
#
# TRANSPOSIFY_SUBTRACT=1 is a further lever, off by default here so this is a
# like-for-like comparison: it builds a mix as the input minus the unchecked
# stems rather than the sum of the checked ones, keeping whatever the model
# assigned to no stem at all.
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP="/Applications/Transposify.app/Contents/MacOS/Transposify"
MODEL="${TRANSPOSIFY_QUALITY_MODEL:-$HOME/Library/Application Support/Transposify/HTDemucs-quality.mlmodelc}"
# Measured on an M4 Max: this model predicts in a flat 133 ms whatever the
# GPU has been doing, so the hop only has to clear its slowest step (153 ms
# observed) with room to spare. A 45 s simulation at these settings ran with
# no underruns and settled 1.70 s behind.
LOOKAHEAD=1.0
HOP=0.4
CUSHION=0.3
NORMAL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --lookahead) LOOKAHEAD="$2"; shift 2 ;;
        --hop) HOP="$2"; shift 2 ;;
        --cushion) CUSHION="$2"; shift 2 ;;
        --normal) NORMAL=1; shift ;;
        *) echo "usage: $0 [--lookahead S] [--hop S] [--cushion S] [--normal]" >&2; exit 2 ;;
    esac
done

[ -x "$APP" ] || { echo "error: install the app first (./install.sh)" >&2; exit 1; }

echo "==> Quitting the running copy"
pkill -f "Transposify.app/Contents/MacOS/Transposify" 2>/dev/null || true
sleep 0.7

if [ "$NORMAL" -eq 1 ]; then
    echo "==> Launching with the shipping configuration"
    open /Applications/Transposify.app
    exit 0
fi

[ -d "$MODEL" ] || {
    echo "error: no quality model at $MODEL" >&2
    echo "       build one with:" >&2
    echo "         cd tools/htdemucs-coreml && HTDEMUCS_MODEL=htdemucs_6s \\" >&2
    echo "           ../../.build/model-conversion/venv/bin/python \\" >&2
    echo "           convert.py --segment 7.8 --output /tmp/q.mlpackage" >&2
    echo "         xcrun coremlcompiler compile /tmp/q.mlpackage \"\$(dirname \"$MODEL\")\"" >&2
    exit 1
}

DELAY=$(python3 -c "print(f'{$HOP + $LOOKAHEAD + $CUSHION:.2f}')")
cat <<EOF

==> Quality mode
    model      $(basename "$MODEL")
    window     7.8 s, FP32, six stems as usual
    hop        ${HOP} s
    lookahead  ${LOOKAHEAD} s
    cushion    ${CUSHION} s
    expected   ~${DELAY} s behind Spotify

    Pick Backing in the popover. Quit the app, or Ctrl-C here, to go back.

EOF

TRANSPOSIFY_MODEL="$MODEL" \
TRANSPOSIFY_HOP="$HOP" \
TRANSPOSIFY_LOOKAHEAD="$LOOKAHEAD" \
TRANSPOSIFY_CUSHION="$CUSHION" \
exec "$APP"
