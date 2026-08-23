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
# Five things are traded for quality, largest effect first:
#
#   1. Model. The shipping build uses htdemucs_6s, which splits six ways and
#      is the weakest Demucs on vocals. This uses the vocals-fine-tuned member
#      of htdemucs_ft — the best Demucs has for telling a voice from the band.
#      Four stems only, so no guitar or piano tiles.
#   2. Window. 7.8 s, the length the model was trained on, instead of 3 s.
#   3. Precision. FP32 instead of FP16.
#   4. Lookahead. A second of future context instead of 0.12 s.
#   5. Hop. Large, which both suits the slower model and raises the average
#      future context every emitted sample gets.
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
    echo "         cd tools/htdemucs-coreml && HTDEMUCS_MODEL=htdemucs_ft \\" >&2
    echo "           HTDEMUCS_BAG_INDEX=3 ../../.build/model-conversion/venv/bin/python \\" >&2
    echo "           convert.py --segment 7.8 --output /tmp/q.mlpackage" >&2
    echo "         xcrun coremlcompiler compile /tmp/q.mlpackage \"\$(dirname \"$MODEL\")\"" >&2
    exit 1
}

DELAY=$(python3 -c "print(f'{$HOP + $LOOKAHEAD + $CUSHION:.2f}')")
cat <<EOF

==> Quality mode
    model      $(basename "$MODEL")
    window     7.8 s, FP32, 4 stems (no guitar or piano tiles)
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
