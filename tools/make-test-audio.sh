#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT="$ROOT/tools/test-audio/song.wav"
PYTHON="$ROOT/tools/.venv/bin/python"
mkdir -p "$(dirname -- "$OUT")"

source_file=${1:-}
if [ -z "$source_file" ]; then
    candidates=$(mktemp)
    trap 'rm -f "$candidates"' EXIT
    for loop_root in "/Library/Audio/Apple Loops" "$HOME/Library/Audio/Apple Loops"; do
        if [ -d "$loop_root" ]; then
            find "$loop_root" -type f \( -iname '*.caf' -o -iname '*.aif' -o -iname '*.aiff' \) >> "$candidates"
        fi
    done
    source_file=$(awk 'BEGIN{IGNORECASE=1} /vocal|vox|voice/{print; exit}' "$candidates")
    if [ -z "$source_file" ]; then
        source_file=$(sed -n '1p' "$candidates")
    fi
fi

if [ -n "$source_file" ] && [ -f "$source_file" ]; then
    echo "Using Apple Loop: $source_file"
    if command -v ffmpeg >/dev/null 2>&1; then
        ffmpeg -loglevel error -y -stream_loop -1 -i "$source_file" -t 60 \
            -ar 48000 -ac 2 -c:a pcm_f32le "$OUT"
    elif command -v sox >/dev/null 2>&1; then
        sox "$source_file" -b 32 -e floating-point -r 48000 -c 2 "$OUT" repeat 999 trim 0 60
    elif command -v afconvert >/dev/null 2>&1 && [ -x "$PYTHON" ]; then
        converted=$(mktemp -t transposify-loop).wav
        trap 'rm -f "$candidates" "$converted"' EXIT
        afconvert "$source_file" "$converted" -f WAVE -d LEF32@48000 -c 2
        "$PYTHON" - "$converted" "$OUT" <<'PY'
import sys
import numpy as np
from scipy.io import wavfile

rate, audio = wavfile.read(sys.argv[1])
if audio.ndim == 1:
    audio = np.repeat(audio[:, None], 2, axis=1)
audio = audio[:, :2].astype(np.float32)
needed = rate * 60
audio = np.tile(audio, (int(np.ceil(needed / len(audio))), 1))[:needed]
wavfile.write(sys.argv[2], rate, audio)
PY
    else
        source_file=
    fi
fi

if [ -z "$source_file" ]; then
    echo "No usable Apple Loop or converter found; synthesising drums, bass, and a vocal-band sweep."
    if [ ! -x "$PYTHON" ]; then
        echo "tools/.venv is required to synthesise test audio" >&2
        exit 1
    fi
    "$PYTHON" - "$OUT" <<'PY'
import sys
import numpy as np
from scipy.io import wavfile

rate = 48_000
seconds = 60
t = np.arange(rate * seconds, dtype=np.float64) / rate
rng = np.random.default_rng(2026)

# Drum-like decays at two alternating accents per second.
drums = np.zeros_like(t)
for beat in np.arange(0, seconds, 0.5):
    start = int(beat * rate)
    length = min(int(0.12 * rate), len(t) - start)
    local = np.arange(length) / rate
    noise = rng.normal(0, 1, length)
    drums[start:start + length] += 0.24 * noise * np.exp(-local * 35)

# A moving bass fundamental with harmonics.
bass_frequency = 82.4 * 2 ** (np.floor(t / 4) % 4 / 12)
bass_phase = 2 * np.pi * np.cumsum(bass_frequency) / rate
bass = 0.16 * np.sin(bass_phase) + 0.05 * np.sin(2 * bass_phase)

# A voiced carrier whose formant emphasis sweeps through the vocal band.
fundamental = 175 + 35 * np.sin(2 * np.pi * 0.09 * t)
phase = 2 * np.pi * np.cumsum(fundamental) / rate
vocal = np.zeros_like(t)
formant = 650 + 850 * (0.5 + 0.5 * np.sin(2 * np.pi * 0.035 * t))
for harmonic in range(1, 18):
    frequency = harmonic * fundamental
    weight = np.exp(-0.5 * ((frequency - formant) / 180) ** 2) / np.sqrt(harmonic)
    vocal += weight * np.sin(harmonic * phase)
vocal *= 0.20 / (np.max(np.abs(vocal)) + 1e-9)

left = drums + bass + vocal
right = 0.92 * drums + 0.98 * bass + np.roll(vocal, 19)
audio = np.stack((left, right), axis=1).astype(np.float32)
peak = np.max(np.abs(audio))
if peak > 0.92:
    audio *= 0.92 / peak
wavfile.write(sys.argv[1], rate, audio)
PY
fi

echo "Wrote $OUT (60 s, 48 kHz stereo float WAV)"
