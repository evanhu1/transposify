#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$#" -lt 1 ]; then
    echo "usage: tools/bench.sh in.wav [--secs N]" >&2
    exit 2
fi
INPUT=$1
shift
SECS=60
if [ "${1:-}" = "--secs" ] && [ -n "${2:-}" ]; then
    SECS=$2
fi

BINARY="$ROOT/.build/release/Transposify"
if [ ! -x "$BINARY" ]; then
    BINARY="$ROOT/.build/debug/Transposify"
fi
if [ ! -x "$BINARY" ]; then
    echo "build Transposify first" >&2
    exit 1
fi

STAMP=$(date +%Y%m%d-%H%M%S)
OUTROOT="$ROOT/tools/bench-results/$STAMP"
mkdir -p "$OUTROOT"
SCRIPT="${BENCH_SCRIPT:-5:pause,7:play,12:vocals,20:all,25:backing,30:+3,40:track}"

printf '%-20s %9s %12s %12s %12s %12s %12s\n' \
    config dropouts unexplained delay_ms drift_ms_min worst_ms min_ring

for config in defaults hop-0.20 hop-0.16 look-0.12 look-0.12-hop-0.16; do
    run_dir="$OUTROOT/$config"
    mkdir -p "$run_dir"
    common="TRANSPOSIFY_SIMULATE=$INPUT:$run_dir"
    if [ "$config" = defaults ]; then
        if ! env -u TRANSPOSIFY_HOP -u TRANSPOSIFY_LOOKAHEAD \
            "$common" TRANSPOSIFY_SIM_SECONDS="$SECS" TRANSPOSIFY_SIM_SCRIPT="$SCRIPT" \
            "$BINARY" >"$run_dir/simulator.txt" 2>&1; then
            echo "matrix stopped early: $config crashed" >&2
            exit 1
        fi
    elif [ "$config" = hop-0.20 ]; then
        if ! env -u TRANSPOSIFY_LOOKAHEAD "$common" TRANSPOSIFY_HOP=0.20 \
            TRANSPOSIFY_SIM_SECONDS="$SECS" TRANSPOSIFY_SIM_SCRIPT="$SCRIPT" \
            "$BINARY" >"$run_dir/simulator.txt" 2>&1; then
            echo "matrix stopped early: $config crashed" >&2
            exit 1
        fi
    elif [ "$config" = hop-0.16 ]; then
        if ! env -u TRANSPOSIFY_LOOKAHEAD "$common" TRANSPOSIFY_HOP=0.16 \
            TRANSPOSIFY_SIM_SECONDS="$SECS" TRANSPOSIFY_SIM_SCRIPT="$SCRIPT" \
            "$BINARY" >"$run_dir/simulator.txt" 2>&1; then
            echo "matrix stopped early: $config crashed" >&2
            exit 1
        fi
    elif [ "$config" = look-0.12 ]; then
        if ! env -u TRANSPOSIFY_HOP "$common" TRANSPOSIFY_LOOKAHEAD=0.12 \
            TRANSPOSIFY_SIM_SECONDS="$SECS" TRANSPOSIFY_SIM_SCRIPT="$SCRIPT" \
            "$BINARY" >"$run_dir/simulator.txt" 2>&1; then
            echo "matrix stopped early: $config crashed" >&2
            exit 1
        fi
    else
        if ! env "$common" TRANSPOSIFY_LOOKAHEAD=0.12 TRANSPOSIFY_HOP=0.16 \
            TRANSPOSIFY_SIM_SECONDS="$SECS" TRANSPOSIFY_SIM_SCRIPT="$SCRIPT" \
            "$BINARY" >"$run_dir/simulator.txt" 2>&1; then
            echo "matrix stopped early: $config crashed" >&2
            exit 1
        fi
    fi
    "$ROOT/tools/analyze-session.sh" "$run_dir" --out "$run_dir/report" >/dev/null
    "$ROOT/tools/.venv/bin/python" - "$config" "$run_dir/report/report.json" <<'PY'
import json
import sys

name, path = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    report = json.load(handle)
summary = report["summary"]
dropouts = report["dropouts"]
delay = report["delay"]
median = delay["medianSeconds"]
drift = delay["driftMsPerMinute"]
print(f"{name:<20} {dropouts['count']:>9} {dropouts['unexplained']:>12} "
      f"{median * 1000 if median is not None else float('nan'):>12.1f} "
      f"{drift if drift is not None else float('nan'):>12.2f} "
      f"{summary['worstStepMs']:>12.1f} {summary['minRingFrames']:>12}")
PY
done

echo "Reports: $OUTROOT"
