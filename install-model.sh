#!/bin/bash
# Build and install the vocal-separation model for Transposify's Isolate modes.
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
# Everything it depends on is pinned. The converter is vendored in
# tools/htdemucs-coreml (MIT, see its LICENSE), the Python dependencies are
# hash-locked in tools/model-requirements.txt, and the Demucs weights are
# fetched from this project's own release rather than Meta's CDN. That last
# one matters: without it, conversion stops working the day
# dl.fbaipublicfiles.com goes away, and nothing in this repo could rebuild
# the model.
set -euo pipefail
cd "$(dirname "$0")"

DEST="$HOME/Library/Application Support/Transposify"
MODEL="$DEST/HTDemucs.mlmodelc"
WORK=".build/model-conversion"
RELEASE=".build/model-release"

# Demucs resolves htdemucs to this checkpoint; torch validates the hash prefix
# embedded in the filename.
WEIGHTS_NAME="955717e8-8726e21a.th"
WEIGHTS_SHA="8726e21a993978c7ba086d3872e7608d7d5bfca646ca4aca459ffda844faa8b4"
WEIGHTS_URL="https://github.com/evanhu1/transposify/releases/download/model-v1/$WEIGHTS_NAME"
WEIGHTS_FALLBACK="https://dl.fbaipublicfiles.com/demucs/hybrid_transformer/$WEIGHTS_NAME"

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

explain_failure() {
    cat >&2 <<MSG

==> Conversion failed.

    This path has two dependencies outside this repo: PyPI (for the pinned
    wheels) and the weights download. Everything else is vendored.

    Known-good environment:
      Python 3.11, torch 2.8.0, coremltools 9.0
      (newer torch changes graph tracing and conversion fails)

    You do not need this script to use the app — it downloads a prebuilt,
    checksum-verified model. Open the popover and pick an Isolate mode.

    To debug: rm -rf $WORK and re-run with --force.
MSG
}
trap 'explain_failure' ERR

if [ -d "$MODEL" ] && [ "$FORCE" -eq 0 ]; then
    echo "==> already installed: $MODEL"
    if [ "$PACKAGE" -eq 1 ]; then package_model; else echo "    re-run with --force to rebuild"; fi
    trap - ERR
    exit 0
fi

command -v uv >/dev/null || { echo "error: uv is required (brew install uv)"; exit 1; }
command -v xcrun >/dev/null || { echo "error: Xcode command line tools required"; exit 1; }

mkdir -p "$WORK"

if [ ! -d "$WORK/venv" ]; then
    echo "==> creating the conversion environment (hash-locked)"
    uv venv --python 3.11 "$WORK/venv"
    VIRTUAL_ENV="$WORK/venv" uv pip install --require-hashes \
        -r tools/model-requirements.txt
fi

# Pre-seed the Demucs weights so conversion doesn't depend on Meta's CDN.
CACHE="${TORCH_HOME:-$HOME/.cache/torch}/hub/checkpoints"
mkdir -p "$CACHE"
if [ ! -f "$CACHE/$WEIGHTS_NAME" ]; then
    echo "==> fetching Demucs weights"
    if ! curl -fsSL -o "$CACHE/$WEIGHTS_NAME.tmp" "$WEIGHTS_URL"; then
        echo "    release copy unavailable, falling back to upstream"
        curl -fsSL -o "$CACHE/$WEIGHTS_NAME.tmp" "$WEIGHTS_FALLBACK"
    fi
    got="$(shasum -a 256 "$CACHE/$WEIGHTS_NAME.tmp" | cut -d' ' -f1)"
    if [ "$got" != "$WEIGHTS_SHA" ]; then
        rm -f "$CACHE/$WEIGHTS_NAME.tmp"
        echo "error: weights checksum mismatch (got $got)" >&2
        exit 1
    fi
    mv "$CACHE/$WEIGHTS_NAME.tmp" "$CACHE/$WEIGHTS_NAME"
fi

echo "==> converting (7.8 s segments, FP16) — this is the slow part"
( cd tools/htdemucs-coreml && "$OLDPWD/$WORK/venv/bin/python" convert.py \
    --segment 7.8 --fp16 )

PKG="tools/htdemucs-coreml/HTDemucs_CoreML_FP16.mlpackage"
[ -d "$PKG" ] || { echo "error: conversion produced no .mlpackage"; exit 1; }

echo "==> compiling"
rm -rf "$WORK/compiled" && mkdir -p "$WORK/compiled"
xcrun coremlcompiler compile "$PKG" "$WORK/compiled"

echo "==> installing"
mkdir -p "$DEST"
rm -rf "$MODEL"
mv "$WORK/compiled/HTDemucs_CoreML_FP16.mlmodelc" "$MODEL"
rm -rf "$PKG"

echo "==> done: $MODEL"
echo "    Isolate modes are now selectable in the popover."

if [ "$PACKAGE" -eq 1 ]; then package_model; fi
trap - ERR
exit 0
