# Transposify

A macOS menu-bar app that lets you **transpose and mix Spotify songs in
realtime**.

https://github.com/user-attachments/assets/f7157fe1-7879-4905-acac-966362948482

<p align="center">
  <img src="docs/popover-mix.png" alt="The Transposify popover" width="300">
</p>

## Install

```sh
git clone https://github.com/evanhu1/transposify.git
cd transposify
./install.sh
```

That builds the app, ad-hoc-signs it, installs it to `/Applications`, and
launches it. On first launch macOS asks for **Microphone** access — that's the
permission Core Audio uses to capture Spotify's audio; it never touches your
real microphone. Click **Allow**, then look for the `𝄞` in your menu bar.

### Updating

From the same clone used for the original install:

```sh
cd /path/to/transposify
git switch main
git pull --ff-only
./install.sh
```

**Requirements:** macOS 14.4 or later, the Spotify desktop app, and Apple's
command-line tools (`xcode-select --install` if `swift` isn't found).

**Uninstall:**

```sh
rm -rf /Applications/Transposify.app && tccutil reset Microphone com.evanhu.transposify
```

## Stem separation

**Mix** splits the track into six stems — vocals, drums, bass, guitar, piano and
everything else — and plays back only the ones you keep. Drop the vocal to sing
lead, or keep vocal and drums to learn a part. It runs on your Mac, live.

It needs a one-time model download. Open the popover and click **Download** next
to "Isolating needs a 118 MB model". The model installs to
`~/Library/Application Support/Transposify/` and is checked against a SHA-256
built into the app, so a corrupted or substituted file is refused rather than
installed. Until it is there, every mix except **All** stays greyed out.

If you would rather build it than trust a binary:

```sh
./install-model.sh
```

That converts Meta's HTDemucs to Core ML locally, in about ten minutes. The
converter is vendored, the Python environment is version- and hash-locked, and
the checkpoint is mirrored in this project's own `model-v1` release and verified
before conversion — so the path still works the day Meta's CDN does not.
Provenance and third-party notices are in
[`tools/htdemucs-coreml/`](tools/htdemucs-coreml/ATTRIBUTION.md).

Separating a moment of audio means seeing slightly past it, so every mix but
**All** plays a fraction of a second behind Spotify. That is affordable here:
you sing _along to_ the output rather than monitoring yourself through it. Pause,
resume, and changing the mix are all seamless — see
[How the live separation works](#how-the-live-separation-works).

## How it works

Spotify's desktop client never exposes its decoded audio — it's DRM-protected,
so no injected code (Spicetify etc.) can touch the stream for DSP. The only way
to pitch-shift it is to capture Spotify's audio _output_ and process it before
your speakers:

```
Spotify ─► Core Audio process tap (muted-when-tapped) ─► ring buffer
                                                              │
                              ┌───────────────────────────────┘
                              ▼
             [Best]  HTDemucs via Core ML, sliding 7.8 s window ─► ring buffer
             [Fast]  mid/side centre cancellation (in the render callback)
                              │
  popup sets semitones ─► Rubber Band R3 ◄── source node
                                  │
                                  └─► default output device
```

- **Capture**: a Core Audio _process tap_ (`AudioHardwareCreateProcessTap`,
  macOS 14.4+) grabs only Spotify's audio — no virtual device, no extension. The
  tap is created _muted-when-tapped_, so Spotify's untouched output is silenced
  and you hear only the processed copy.
- **Transpose**: the
  [Rubber Band Library](https://breakfastquay.com/rubberband/) **R3 ("finer")
  engine** in real-time mode — a state-of-the-art music pitch shifter, run
  directly in the audio render callback. Latency is higher than Apple's built-in
  unit, but that's irrelevant here (you sing _along to_ the output, so there's
  no monitoring loop). Verified accurate to <0.1%.
- **Pristine passthrough at 0**: the pipeline engages **only** while Spotify is
  playing _and_ there's something to do (`pitch ≠ 0` or karaoke on). At 0 with
  karaoke off the tap is fully torn down, so Spotify plays untouched —
  bit-perfect, zero added latency. It also disengages when you pause.
- **Now playing / per-song memory**: read from Spotify's `PlaybackStateChanged`
  distributed notification (instant, no polling), keyed by track ID.

## How the live separation works

Isolating a track in real time is a sliding-window problem. HTDemucs looks at
**7.8 seconds at a time** and takes about **110 ms** to do it on an M4 Max.

```
     ── 7.8 s window the model actually sees ──
┌───────────────────────────────────────────────┐
│        past context        │ keep │ lookahead │
└───────────────────────────────────────────────┘
                             └ hop ─┘           └─ newest audio captured
```

**Hop** is how often the model runs, and how big a block the audio comes out in.
GPU duty is simply `inference ÷ hop`: run it every second and the GPU is busy
11% of the time; every quarter-second and it's 44%. A smaller hop means fresher
output at the cost of power — and only while actually separating, since `Off`
copies the window through without touching the model.

**Lookahead** is how much already-captured audio sits _after_ the part being
kept. Future context genuinely helps — whether a sound is a held vowel or a
cymbal decay is much clearer once you have heard what follows. It has a sharp
knee:

| lookahead               | 0 s  | 0.25 s | 0.5 s | 1.0 s | 2.0 s |
| ----------------------- | ---- | ------ | ----- | ----- | ----- |
| quality (dB vs offline) | 19.3 | 20.5   | 22.0  | 23.2  | 24.2  |

A quarter-second captures most of the benefit; beyond half a second it buys
almost nothing.

**Delay** is those three added together — `hop + lookahead + inference`. You
wait for the future context to exist, wait to compute it, then wait for your
block to fill.

### Hop is chosen for your Mac, not for mine

GPU duty is `inference / hop`, so a hop that sits at 44% duty on an M4 Max would
demand well over 100% on an M1 — the worker would fall permanently behind and
the audio would break up. A single hard-coded value cannot serve both machines.

So the model is timed once, right after it loads (which also absorbs Core ML's
first-run specialisation, keeping that cost out of the audio path). The
measurement is persisted, and the hop is scaled to hit roughly **40% GPU duty**,
clamped to 0.15–2.0 s. Faster Macs get lower latency; slower Macs get audio that
keeps up. Roughly:

| Mac       | inference | hop     | delay  |
| --------- | --------- | ------- | ------ |
| M4 Max    | ~175 ms   | ~0.44 s | ~0.7 s |
| mid-range | ~300 ms   | ~0.75 s | ~1.1 s |
| M1        | ~700 ms   | ~1.75 s | ~2.7 s |

### Every mode carries the same delay, including Off

Separated audio for a moment only exists once the input has passed it by
`lookahead + inference`. Playing it at its natural time therefore _requires_ the
output to be delayed. A zero-delay `Off` cutting over to a delayed stream would
have to insert a gap, repeat a couple of seconds, or bend the tempo.

So `Off` runs the same window and hop machinery and just copies the input
instead of predicting it — same delay, no GPU. Because every mode is delayed
identically, switching is only a flag: the worker already holds the history and
the lookahead the new mode needs, so the next block comes out separated and the
existing crossfade joins it to the previous one. No gap, no repeat, no drift.
Any preparation — even a cold model load — happens underneath audio that keeps
playing.

### Why the delay is small now

The quality figures above are measured against _whole-file offline Demucs_: how
close streaming gets to what the model would do seeing the entire song at once.
They are not the separation quality itself. Offline Demucs is only about **9
dB** against true isolated stems — that is the model's own error, and it is what
you actually hear as faint bleed. Streaming sits ~22 dB below the offline
result, i.e. roughly 13 dB below the model's own error, so it contributes
essentially nothing.

Which means hop and lookahead control **latency and power, not quality**.
Sweeping them from 2.1 s of delay down to 0.5 s moved the number from 23.2 dB to
22.5 dB and wobbled rather than trended — noise, not signal. The original 2 s
delay was buying nothing.

If you want better separation, none of these knobs will do it; you are at the
model's ceiling, and the next model up (Mel-Band RoFormer, ~2 dB better) is
roughly 12x too slow to stream.

## Diagnostics & tests

```sh
swift probe.swift                              # OSStatus of each Core Audio tap call
TRANSPOSIFY_SELFTEST=1 .build/debug/Transposify  # headless engagement state-machine test
TRANSPOSIFY_RBTEST=1   .build/debug/Transposify  # Rubber Band pitch-accuracy check (440Hz +7st)
```

To build without installing: `./make-app.sh && open Transposify.app`.

## License

This project is **GPLv2-or-later** (see [`LICENSE`](LICENSE)). It must be — it
statically links the
[Rubber Band Library](https://breakfastquay.com/rubberband/) by Particular
Programs Ltd, which is GPLv2+. The Rubber Band source is vendored under
[`Sources/CRubberBand`](Sources/CRubberBand) (single-file build, using Apple's
vDSP FFT). If you want to ship a closed-source build, obtain a commercial Rubber
Band licence from Breakfast Quay.
