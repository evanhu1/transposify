#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PYTHON="$ROOT/tools/.venv/bin/python"
if [ ! -x "$PYTHON" ]; then
    PYTHON=$(command -v python3)
fi
exec "$PYTHON" "$ROOT/tools/analyze-session.py" "$@"
