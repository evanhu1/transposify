#!/usr/bin/env python3
"""Score a Transposify streaming separation against an offline reference.

The reference is any higher-quality render of the same song — e.g.
htdemucs_6s run full-window with 25% overlap:

    /tmp/demucs-venv/bin/python - <<'PY'
    ... apply_model(model, x, overlap=0.25, split=True) ...
    instrumental = sum(stems) - vocals   ->  instrumental_44k.wav
    PY

Alignment works by chunk-origin matching: several 8 s chunks of the
streaming output are located in the reference by FFT cross-correlation
(unbounded search — no lag-range guessing), and their offsets must agree;
the score is then SI-SNR over the whole song at that constant offset.

Verified on an M4 Max: Blue Hoodie, shipping config vs htdemucs_6s
full-window — SI-SNR 21.6 dB, gain 0.998, all chunk offsets identical.

    tools/.venv/bin/python tools/quality-check.py \
        /tmp/streaming-instrumental.wav /tmp/demucs-ref/instrumental_44k.wav
"""

import sys
import numpy as np
from scipy import signal
from scipy.io import wavfile


def load_mono(path: str) -> tuple[int, np.ndarray]:
    rate, audio = wavfile.read(path)
    audio = audio.astype(np.float32)
    if np.issubdtype(audio.dtype, np.integer):
        info = np.iinfo(audio.dtype)
        audio = audio / max(abs(info.min), info.max)
    if audio.ndim == 1:
        audio = audio[:, None]
    mono = audio.mean(axis=1)
    return int(rate), mono - mono.mean()


def resample_to(mono: np.ndarray, src: int, dst: int) -> np.ndarray:
    from math import gcd
    if src == dst:
        return mono.astype(np.float64)
    g = gcd(src, dst)
    return signal.resample_poly(mono, dst // g, src // g).astype(np.float64)


def chunk_offsets(stream: np.ndarray, ref: np.ndarray, sr: int,
                  chunk_s: float = 8.0) -> list[float]:
    """Where each streaming chunk sits inside the reference, in seconds."""
    seg = int(chunk_s * sr)
    offsets = []
    for frac in (0.10, 0.25, 0.40, 0.55, 0.70, 0.85):
        start = int((len(stream) - seg) * frac)
        if start < 0 or start + seg > len(ref):
            continue
        w = stream[start:start + seg].astype(np.float64)
        w -= w.mean()
        wn = np.linalg.norm(w) + 1e-30
        corr = signal.correlate(ref, w, mode="valid", method="fft")
        j = int(np.argmax(corr))
        rr = ref[j:j + seg].copy()
        rr -= rr.mean()
        corr_value = float(np.dot(rr, w) / (np.linalg.norm(rr) * wn))
        offsets.append(j / sr - start / sr)
        print(f"  chunk @ stream {start/sr:7.2f}s -> ref {j/sr:8.3f}s  "
              f"corr {corr_value:+.4f}")
    return offsets


def si_snr(stream: np.ndarray, ref: np.ndarray, sr: int,
           offset_samples: int, edge_s: float = 1.0) -> float:
    """Scale-invariant SNR pairing stream[i] with ref[i + offset_samples].

    The chunk match gave the offset directly (negative: reference content
    sits earlier). Edges are trimmed because the streaming run's first and
    last second carry model warm-in/warm-out.
    """
    edge = int(edge_s * sr)
    n = min(len(ref) - offset_samples, len(stream)) - 2 * edge
    if n <= edge:
        return float("nan")
    s = stream[edge:edge + n].astype(np.float64)
    t = ref[offset_samples + edge:offset_samples + edge + n].astype(np.float64)
    s -= s.mean()
    t -= t.mean()
    alpha = float(np.dot(s, t) / (np.dot(t, t) + 1e-30))
    resid = s - alpha * t
    snr = 10 * np.log10((alpha ** 2 * np.dot(t, t) + 1e-30)
                        / (np.dot(resid, resid) + 1e-30))
    print(f"  gain alpha {alpha:.4f}")
    return float(snr)


def band_report(stream: np.ndarray, ref: np.ndarray, sr: int,
                offset_samples: int) -> list[tuple[str, float]]:
    edge = sr
    n = min(len(ref) - offset_samples, len(stream)) - 2 * edge
    f, _, S = signal.stft(
        stream[edge:edge + n].astype(np.float32), fs=sr, nperseg=4096)
    _, _, R = signal.stft(
        ref[offset_samples + edge:offset_samples + edge + n].astype(np.float32),
        fs=sr, nperseg=4096)
    edges = sorted({20, 60, 150, 400, 1000, 2500, 6000, 12000, int(sr / 2)})
    out = []
    for lo, hi in zip(edges, edges[1:]):
        band = (f >= lo) & (f < hi)
        ps = (np.abs(S[band]) ** 2).mean()
        pr = (np.abs(R[band]) ** 2).mean()
        out.append((f"{lo:.0f}-{hi:.0f} Hz",
                    float(10 * np.log10(ps / pr + 1e-12))))
    return out


def main() -> None:
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    sr_stream, stream = load_mono(sys.argv[1])
    sr_ref, ref = load_mono(sys.argv[2])
    if sr_stream != sr_ref:
        ref = resample_to(ref, sr_ref, sr_stream)

    print("alignment:")
    offsets = chunk_offsets(stream, ref, sr_stream)
    if len(offsets) < 3:
        print("FAIL: fewer than 3 chunks matched")
        sys.exit(1)
    spread_ms = (max(offsets) - min(offsets)) * 1000
    median_offset = int(round(float(np.median(offsets)) * sr_stream))
    print(f"  offset spread: {spread_ms:.1f} ms "
          f"({'consistent' if spread_ms < 25 else 'INCONSISTENT'})")

    score = si_snr(stream, ref, sr_stream, median_offset)
    print(f"SI-SNR vs offline reference: {score:.2f} dB")
    print("spectral balance (streaming/reference dB, 0 = match):")
    for name, delta in band_report(stream, ref, sr_stream, median_offset):
        bar = "#" * max(0, min(40, int(abs(delta) * 4)))
        sign = "+" if delta >= 0 else "-"
        print(f"  {name:>12}  {delta:+7.2f} dB  {sign}{bar}")


if __name__ == "__main__":
    main()
