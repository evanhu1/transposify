#!/bin/bash
# Build and install the vocal-removal model for Transposify's "Best" mode.
#
# Most people never need this: the app downloads a prebuilt model from the
# releases page and verifies its checksum. This script is the reproducible
# path — build it yourself instead of trusting a binary — and it's how the
# release artifact is produced.
#
#   ./install-model.sh              build and install
#   ./install-model.sh --force      rebuild even if already installed
#   ./install-model.sh --package    also produce the release zip + SHA-256
#
# Takes about ten minutes the first time, mostly downloading PyTorch and the
# model weights.
set -euo pipefail
cd "$(dirname "$0")"

DEST="$HOME/Library/Application Support/Transposify"
MODEL="$DEST/HTDemucs.mlmodelc"
WORK=".build/model-conversion"
RELEASE=".build/model-release"

PACKAGE=0
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --package) PACKAGE=1 ;;
        --force) FORCE=1 ;;
        *) echo "unknown option: $arg"; exit 2 ;;
    esac
done

package_model() {
    mkdir -p "$RELEASE"
    rm -f "$RELEASE/HTDemucs.mlmodelc.zip"
    ( cd "$DEST" && ditto -c -k --sequesterRsrc --keepParent \
        HTDemucs.mlmodelc "$OLDPWD/$RELEASE/HTDemucs.mlmodelc.zip" )
    echo
    echo "==> release artifact"
    echo "    file:   $RELEASE/HTDemucs.mlmodelc.zip"
    echo "    bytes:  $(stat -f%z "$RELEASE/HTDemucs.mlmodelc.zip")"
    echo "    sha256: $(shasum -a 256 "$RELEASE/HTDemucs.mlmodelc.zip" | cut -d' ' -f1)"
    echo
    echo "    Attach THIS file to the release named by SeparationModel.modelVersion,"
    echo "    and paste the bytes and sha256 into SeparationModel.swift."
    echo "    Note: zip stores timestamps, so re-running this produces a different"
    echo "    sha256 for an identical model. Upload the file you just hashed."
}

if [ -d "$MODEL" ] && [ "$FORCE" -eq 0 ]; then
    echo "==> already installed: $MODEL"
    [ "$PACKAGE" -eq 1 ] && package_model || echo "    re-run with --force to rebuild"
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

[ "$PACKAGE" -eq 1 ] && package_model
exit 0
