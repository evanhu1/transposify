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
# Takes about ten minutes the first time, mostly downloading the pinned Python
# environment and model checkpoint.
set -euo pipefail
cd "$(dirname "$0")"

DEST="$HOME/Library/Application Support/Transposify"
MODEL="$DEST/HTDemucs.mlmodelc"
WORK=".build/model-conversion"
RELEASE=".build/model-release"
CONVERTER="tools/HTDemucsCoreML"
LOCK="$CONVERTER/requirements.lock"
VENV="$WORK/venv"
PYTHON_VERSION="3.11.15"

# Exact HTDemucs model-v1 checkpoint. It is mirrored on our release so a future
# removal of Meta's model CDN cannot make this conversion path unreproducible.
WEIGHTS_NAME="955717e8-8726e21a.th"
WEIGHTS_BYTES="84141911"
WEIGHTS_SHA256="8726e21a993978c7ba086d3872e7608d7d5bfca646ca4aca459ffda844faa8b4"
WEIGHTS_URL="https://github.com/evanhu1/transposify/releases/download/model-v1/$WEIGHTS_NAME"
WEIGHTS_DIR="$WORK/torch/hub/checkpoints"
WEIGHTS="$WEIGHTS_DIR/$WEIGHTS_NAME"

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

sha256() {
    shasum -a 256 "$1" | cut -d' ' -f1
}

prepare_weights() {
    mkdir -p "$WEIGHTS_DIR"
    if [ -f "$WEIGHTS" ] && \
       [ "$(stat -f%z "$WEIGHTS")" = "$WEIGHTS_BYTES" ] && \
       [ "$(sha256 "$WEIGHTS")" = "$WEIGHTS_SHA256" ]; then
        echo "==> model checkpoint already verified"
        return
    fi

    # Never let an incomplete or substituted checkpoint reach Demucs.
    rm -f "$WEIGHTS" "$WEIGHTS.download"
    echo "==> downloading the pinned model checkpoint (84 MB)"
    if ! curl -fL --retry 3 --output "$WEIGHTS.download" "$WEIGHTS_URL"; then
        rm -f "$WEIGHTS.download"
        echo "error: couldn't download the model-v1 checkpoint" >&2
        echo "       The prebuilt model is still available from Transposify's Download button." >&2
        exit 1
    fi
    if [ "$(stat -f%z "$WEIGHTS.download")" != "$WEIGHTS_BYTES" ] || \
       [ "$(sha256 "$WEIGHTS.download")" != "$WEIGHTS_SHA256" ]; then
        rm -f "$WEIGHTS.download"
        echo "error: downloaded checkpoint failed size or SHA-256 verification" >&2
        echo "       Nothing was installed." >&2
        exit 1
    fi
    mv "$WEIGHTS.download" "$WEIGHTS"
}

if [ -d "$MODEL" ] && [ "$FORCE" -eq 0 ]; then
    echo "==> already installed: $MODEL"
    [ "$PACKAGE" -eq 1 ] && package_model || echo "    re-run with --force to rebuild"
    exit 0
fi

command -v uv >/dev/null || { echo "error: uv is required (brew install uv)"; exit 1; }
command -v xcrun >/dev/null || { echo "error: Xcode command line tools required"; exit 1; }
command -v curl >/dev/null || { echo "error: curl is required"; exit 1; }

mkdir -p "$WORK"

if [ ! -d "$VENV" ]; then
    echo "==> creating the conversion environment"
    uv venv --python "$PYTHON_VERSION" "$VENV"
fi
echo "==> syncing the hash-locked conversion environment"
VIRTUAL_ENV="$VENV" uv pip sync --require-hashes "$LOCK"

prepare_weights

echo "==> converting (7.8 s segments, FP16) — this is the slow part"
PKG="$WORK/HTDemucs_CoreML_FP16.mlpackage"
rm -rf "$PKG"
if ! TORCH_HOME="$WORK/torch" "$VENV/bin/python" "$CONVERTER/convert.py" \
    --segment 7.8 --fp16 --output "$PKG"; then
    echo >&2
    echo "error: model conversion failed" >&2
    echo "       Known-good target: Python $PYTHON_VERSION, torch 2.8.0, coremltools 9.0," >&2
    echo "       converter commit d6fe735f2c485f88cce9db123f4bacc3a9d3f02a." >&2
    echo "       The prebuilt model remains available from Transposify's Download button." >&2
    exit 1
fi

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
