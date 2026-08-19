# Transposify

A macOS menu-bar app that lets you **sing along to any Spotify song in your
range** — shift the key up or down by semitones in real time, pitch without
tempo change. It stays out of the way: a small `𝄞 +2` / `𝄞 −3` / `𝄞 0` in the
menu bar, and a popup when you click it. Settings are remembered per song.

<p align="center">
  <img src="docs/popover.png" alt="Transposify popover" width="320">
</p>

## Install

You build it on your own Mac with one script. Because it's compiled locally,
macOS doesn't quarantine it — **no Apple Developer account, no notarization, no
"unidentified developer" warning.**

```sh
git clone https://github.com/evanhu1/transposify.git
cd transposify
./install.sh
```

That builds the app, ad-hoc-signs it, installs it to `/Applications`, and
launches it. On first launch macOS asks for **Microphone** access — that's the
permission Core Audio uses to capture Spotify's audio; it never touches your
real microphone. Click **Allow**, then look for the `𝄞` in your menu bar.

**Requirements:** macOS 14.4 or later, the Spotify desktop app, and Apple's
command-line tools (`xcode-select --install` if `swift` isn't found).

**Uninstall:**
```sh
rm -rf /Applications/Transposify.app && tccutil reset Microphone com.evanhu.transposify
```

## Vocal removal

`Fast` needs nothing extra. `Best` needs a one-time model download: open the
popover and click **Download** next to "Best needs a 142 MB model". It lands in
`~/Library/Application Support/Transposify/` and is checked against a SHA-256
built into the app, so a corrupted or substituted download is refused rather
than installed. Until it's there, `Best` stays greyed out.

If you'd rather build the model yourself than trust a binary:

```sh
./install-model.sh
```

That converts Meta's HTDemucs to Core ML locally and installs it to the same
place. It takes about ten minutes, mostly spent downloading PyTorch and the
model weights.

**Why the delay.** Separating a moment of audio well needs to see slightly past
it, so `Best` buffers about a second of lookahead and emits a second at a time —
roughly two seconds behind Spotify. That is affordable here because you sing
*along to* the output rather than monitoring yourself through it, but it does
mean pausing and skipping lag by the same amount. `Fast` has no such delay.

Measured on an M4 Max: one 7.8 s window takes ~130 ms on the GPU, so the model
runs at about 15x realtime and uses a fraction of the machine. The model is held
in memory (on the order of a gigabyte) only while `Best` is selected.

## Using it

Click the menu-bar item to open the popup:

- **Now playing** — current track + artist.
- **Transpose** — `−` / value / `+`, or the slider (±12 semitones). *Reset*
  (↺) appears when shifted.
- **Reduce vocals** — `Off` / `Fast` / `Best`.
  *Fast* is centre-channel cancellation: instant, but it ducks the bass and
  drums along with the vocal. *Best* runs neural source separation (HTDemucs)
  and genuinely removes the vocal, at the cost of about two seconds of delay
  between Spotify and what you hear. See [Vocal removal](#vocal-removal).
- **Remember key for this song** — on by default; your setting auto-applies when
  that track plays again. New songs start at the original key.
- **Launch at login** — register as a login item via `SMAppService`.

The menu-bar item (treble clef + signed value) always reflects the current
offset, at fixed width so it never shifts. The app auto-adjusts when you switch
output devices (e.g. plug in headphones) and engages only while Spotify is
playing.

## How it works

Spotify's desktop client never exposes its decoded audio — it's DRM-protected,
so no injected code (Spicetify etc.) can touch the stream for DSP. The only way
to pitch-shift it is to capture Spotify's audio *output* and process it before
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

- **Capture**: a Core Audio *process tap* (`AudioHardwareCreateProcessTap`,
  macOS 14.4+) grabs only Spotify's audio — no virtual device, no extension. The
  tap is created *muted-when-tapped*, so Spotify's untouched output is silenced
  and you hear only the processed copy.
- **Transpose**: the [Rubber Band Library](https://breakfastquay.com/rubberband/)
  **R3 ("finer") engine** in real-time mode — a state-of-the-art music pitch
  shifter, run directly in the audio render callback. Latency is higher than
  Apple's built-in unit, but that's irrelevant here (you sing *along to* the
  output, so there's no monitoring loop). Verified accurate to <0.1%.
- **Pristine passthrough at 0**: the pipeline engages **only** while Spotify is
  playing *and* there's something to do (`pitch ≠ 0` or karaoke on). At 0 with
  karaoke off the tap is fully torn down, so Spotify plays untouched —
  bit-perfect, zero added latency. It also disengages when you pause.
- **Now playing / per-song memory**: read from Spotify's `PlaybackStateChanged`
  distributed notification (instant, no polling), keyed by track ID.

## Diagnostics & tests

```sh
swift probe.swift                              # OSStatus of each Core Audio tap call
TRANSPOSIFY_SELFTEST=1 .build/debug/Transposify  # headless engagement state-machine test
TRANSPOSIFY_RBTEST=1   .build/debug/Transposify  # Rubber Band pitch-accuracy check (440Hz +7st)
```

To build without installing: `./make-app.sh && open Transposify.app`.

## License

This project is **GPLv2-or-later** (see [`LICENSE`](LICENSE)). It must be — it
statically links the [Rubber Band Library](https://breakfastquay.com/rubberband/)
by Particular Programs Ltd, which is GPLv2+. The Rubber Band source is vendored
under [`Sources/CRubberBand`](Sources/CRubberBand) (single-file build, using
Apple's vDSP FFT). If you want to ship a closed-source build, obtain a
commercial Rubber Band licence from Breakfast Quay.
