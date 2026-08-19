#!/bin/bash
# Build and install the vocal-removal model for Transposify's "Best" mode.
#
# HTDemucs is converted to Core ML once, here, and installed to Application
# Support. It is ~256 MB compiled, which is why it isn't in the repo or the
# .app bundle. Takes about ten minutes the first time, mostly downloading
# PyTorch and the model weights.
set -euo pipefail
cd "$(dirname "$0")"

DEST="$HOME/Library/Application Support/Transposify"
MODEL="$DEST/HTDemucs.mlmodelc"
WORK=".build/model-conversion"

if [ -d "$MODEL" ] && [ "${1:-}" != "--force" ]; then
    echo "==> already installed: $MODEL"
    echo "    re-run with --force to rebuild"
    exit 0
fi

command -v uv >/dev/null || { echo "error: uv is required (brew install uv)"; exit 1; }
command -v xcrun >/dev/null || { echo "error: Xcode command line tools required"; exit 1; }

mkdir -p "$WORK"

if [ ! -d "$WORK/htdemucs-coreml" ]; then
    echo "==> fetching the converter"
    git clone --depth 1 https://github.com/dexxdean/htdemucs-coreml.git \
        "$WORK/htdemucs-coreml"
fi

if [ ! -d "$WORK/venv" ]; then
    echo "==> creating the conversion environment"
    # Pinned: newer torch changes tracing and the conversion fails.
    uv venv --python 3.11 "$WORK/venv"
    VIRTUAL_ENV="$WORK/venv" uv pip install \
        "torch==2.8.0" "torchaudio==2.8.0" "demucs==4.0.1" \
        "coremltools==9.0" "numpy==2.0.2" "einops==0.8.2"
fi

echo "==> converting (7.8 s segments, FP16) — this is the slow part"
( cd "$WORK/htdemucs-coreml" && ../venv/bin/python convert.py --segment 7.8 --fp16 )

PKG="$WORK/htdemucs-coreml/HTDemucs_CoreML_FP16.mlpackage"
[ -d "$PKG" ] || { echo "error: conversion produced no .mlpackage"; exit 1; }

echo "==> compiling"
rm -rf "$WORK/compiled" && mkdir -p "$WORK/compiled"
xcrun coremlcompiler compile "$PKG" "$WORK/compiled"

echo "==> installing"
mkdir -p "$DEST"
rm -rf "$MODEL"
mv "$WORK/compiled/HTDemucs_CoreML_FP16.mlmodelc" "$MODEL"

echo "==> done: $MODEL"
echo "    \"Best\" is now selectable in the Reduce vocals row."
