#!/usr/bin/env python3
"""Deterministic, musically-realistic test track for pipeline benchmarks.

The old song.wav was a looped tone+noise bed. Two problems: its exact 1 s
periodicity gave the session analyzer's correlator multiple equally-good
delay peaks (2.53 / 1.53 / 0.53 s), and it has no vocal register, so the
"Vocals" preset produced near-silence that read as an 8 s dropout.

This synthesizes four separable layers a cappella-to-full-mix test wants:

    drums   - kick/snare/hats on a jittered grid (transients for the analyzer)
    bass    - sawtooth line through a i-VI-III-VII progression
    chords  - detuned saw pad with slow movement
    vocal   - formant-synthesised lead with vibrato and phrasing

Every event time carries humanized jitter, so nothing repeats exactly and
cross-correlation locks unambiguously onto onsets. Output: 48 kHz stereo
float32 WAV.

    tools/.venv/bin/python tools/make-test-audio.py [seconds] [out.wav]
"""

import sys
import wave
import numpy as np

RATE = 48_000
rng = np.random.default_rng(20240822)

# ---------------------------------------------------------------- helpers


def env(n, attack, decay, rate=RATE):
    """Exponential decay envelope with a short attack."""
    a = max(1, int(attack * rate))
    d = n - a
    e = np.ones(n)
    if a > 1:
        e[:a] = np.linspace(0, 1, a)
    if d > 0:
        e[a:] *= np.exp(-np.arange(d) / (rate * decay))
    return e


def place(buf, start_s, sig, gain=1.0):
    i = int(start_s * RATE)
    if i < 0 or i >= len(buf):   # jitter can push the very first event negative
        return
    j = min(len(buf), i + len(sig))
    buf[i:j] += sig[: j - i] * gain


def saw(freq, dur, detune_cents=(0,), phase_jitter=True):
    t = np.arange(int(dur * RATE)) / RATE
    out = np.zeros_like(t)
    for cents in detune_cents:
        f = freq * 2 ** (cents / 1200)
        ph = rng.uniform(0, 2 * np.pi) if phase_jitter else 0.0
        out += 2 * ((f * t + ph / (2 * np.pi)) % 1.0) - 1
    return out / max(1, len(detune_cents))


def lowpass(x, alpha):
    y = np.empty_like(x)
    acc = 0.0
    for i, v in enumerate(x):
        acc += alpha * (v - acc)
        y[i] = acc
    return y


def highpass(x, alpha):
    return x - lowpass(x, alpha)


def resonator(x, freq, q, rate=RATE):
    """Two-pole resonator; used to give the voice formants."""
    w = 2 * np.pi * freq / rate
    r = np.exp(-w / (2 * q))
    # y[n] = x[n] + 2 r cos(w) y[n-1] - r^2 y[n-2]
    a = np.array([1.0, -2 * r * np.cos(w), -(r * r)])
    y = np.zeros_like(x)
    for i in range(2, len(x)):
        y[i] = x[i] + a[1] * y[i - 1] + a[2] * y[i - 2]
    return y / (np.abs(y).max() + 1e-9)


# ---------------------------------------------------------------- layers


def drums(total):
    out = np.zeros(int(total * RATE))
    beat = 0.5  # 120 bpm
    t = 0.0
    while t < total:
        # kick on 1 & 3 (+ ghost), snare on 2 & 4, hats every eighth.
        pos = t + rng.uniform(-0.006, 0.006)
        n = int(0.28 * RATE)
        f = np.linspace(110, 45, n)
        kick = np.sin(np.cumsum(2 * np.pi * f / RATE)) * env(n, 0.001, 0.07)
        place(out, pos, kick, 0.9)

        if int(round(t / beat)) % 4 in (1, 3):          # snare
            pos = t + rng.uniform(-0.005, 0.005)
            n = int(0.18 * RATE)
            burst = rng.uniform(-1, 1, n) * env(n, 0.0008, 0.05)
            place(out, pos, highpass(burst, 0.25), 0.35)

        for h in (0.0, 0.25):                            # hats off the eighth
            pos = t + h * beat + rng.uniform(-0.002, 0.002)
            n = int(0.05 * RATE)
            tick = rng.uniform(-1, 1, n) * env(n, 0.0003, 0.012)
            place(out, pos, highpass(tick, 0.55), 0.16 if h else 0.10)

        if rng.random() < 0.12:                          # occasional ghost kick
            place(out, t + 0.75 * beat,
                  kick * 0.3, 0.28)
        t += beat
    return out


CHORDS = [57, 53, 48, 52]      # A3 F3 C3 E3 -> Am F C E over i VI III V
BASS_ROOT = CHORDS


def bass(total):
    out = np.zeros(int(total * RATE))
    bar = 2.0
    t = 0.0
    while t < total:
        root = BASS_ROOT[int(t / bar) % len(BASS_ROOT)] - 24   # A1 etc.
        for k, off in enumerate((0.0, 0.75, 1.25)):
            midi = root + (0 if k != 2 else 7)
            f = 440 * 2 ** ((midi - 69) / 12)
            dur = 0.6
            n = int(dur * RATE)
            sig = saw(f, dur, detune_cents=(-6, 5)) * env(n, 0.004, 0.30)
            place(out, t + off * bar + rng.uniform(-0.004, 0.004),
                  lowpass(sig, 0.18), 0.42)
        t += bar
    return out


def chords(total):
    out = np.zeros(int(total * RATE))
    bar = 2.0
    t = 0.0
    while t < total:
        root = CHORDS[int(t / bar) % len(CHORDS)]
        quality = (0, 4, 7) if root in (53, 60) else (0, 3, 7)
        n = int(bar * 0.95 * RATE)
        sig = np.zeros(n)
        for ivl in quality:
            f = 440 * 2 ** ((root + ivl - 69) / 12)
            sig += saw(f, bar * 0.95, detune_cents=(-9, -3, 4, 10))
        place(out, t, lowpass(sig, 0.10)
              * env(n, 0.05, 1.2), 0.11)
        t += bar
    return out


VOCAL_MELODY = [76, 76, 74, 72, 72, 74, 76, 79,
                77, 76, 74, 72, 71, 69, 71, 72]


def vocal(total):
    """Formant-synthesised lead: glottal pulse train through 3 formants."""
    out = np.zeros(int(total * RATE))
    eighth = 0.25
    t = 0.0
    idx = 0
    while t < total:
        midi = VOCAL_MELODY[idx % len(VOCAL_MELODY)]
        f0 = 220 * 2 ** ((midi - 69) / 12)
        sing_for = eighth * rng.choice([2, 2, 2, 4])
        n = int(sing_for * RATE)
        tt = np.arange(n) / RATE
        vib = 1 + 0.011 * np.sin(2 * np.pi * 5.2 * tt + rng.uniform(0, 6))
        freq_track = f0 * vib
        phase = np.cumsum(freq_track) / RATE
        pulse = (phase % 1.0 < 0.4).astype(float)           # glottal-ish
        breath = rng.uniform(-1, 1, n) * 0.02
        src = lowpass(pulse + breath, 0.5)
        note = np.zeros(n)
        # Three formants give the tone a sung-vowel character; alternate two
        # vowels so the timbre moves between notes like a real phrase.
        formants = ((700, 90), (1220, 100), (2650, 140)) if idx % 2 \
            else ((620, 80), (1080, 90), (2450, 130))
        for fq, q in formants:
            note += resonator(src, fq, q)
        # Phrase shape: swell in, taper out.
        note *= env(n, 0.08, sing_for * 0.45) * rng.uniform(0.7, 1.0)
        place(out, t, note, 0.30)
        idx += 1
        t += sing_for + rng.choice([0.0, 0.25])             # breathe between
    return out


def survey_markers(total):
    """Soft, short pings at golden-ratio-spaced times.

    The session analyzer aligns input to output by mel-envelope correlation.
    A bar-grid signal offers it many equally-good wrong peaks; these markers
    are deliberately off any musical grid and uniquely spaced, so the true
    delay is the only alignment that lines all of them up at once.
    """
    out = np.zeros(int(total * RATE))
    t = 1.6180339
    while t < total - 0.5:
        n = int(0.006 * RATE)
        tt = np.arange(n) / RATE
        ping = np.sin(2 * np.pi * 6200 * tt) * env(n, 0.0005, 0.0018)
        place(out, t, ping, 0.05)
        place(out, t, ping, 0.04)   # both channels via mono mix later
        t += 0.6180339 * max(0.9, 1 + 0.4 * np.sin(t))
    return out


# ---------------------------------------------------------------- main


def main():
    seconds = float(sys.argv[1]) if len(sys.argv) > 1 else 60.0
    path = sys.argv[2] if len(sys.argv) > 2 else "tools/test-audio/song.wav"

    layers = {
        "drums": drums(seconds),
        "bass": bass(seconds),
        "chords": chords(seconds),
        "vocal": vocal(seconds),
        "markers": survey_markers(seconds),
    }
    mix = sum(layers.values())
    peak = np.abs(mix).max()
    mix = mix / peak * 0.85
    # Gentle fade in/out so edges are clean for correlation windows.
    fade = int(0.05 * RATE)
    mix[:fade] *= np.linspace(0, 1, fade)
    mix[-fade:] *= np.linspace(1, 0, fade)

    stereo = np.stack([mix, mix], axis=1)
    pcm = stereo.astype(np.float32)
    # scipy writes a proper WAVE_FORMAT_IEEE_FLOAT header; python's wave
    # module would label the same bytes PCM int32, which every reader then
    # scales wrong.
    from scipy.io import wavfile
    wavfile.write(path, RATE, pcm)
    print(f"wrote {path}: {seconds}s @ {RATE} Hz float32 stereo")


if __name__ == "__main__":
    main()
