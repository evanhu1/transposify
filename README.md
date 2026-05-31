# Spotify Transposer

A macOS menu-bar app that lets you **sing along to any Spotify song in your
range** — shift the key up or down by semitones in real time, pitch without
tempo change. It stays out of the way: a small `𝄞 +2` / `𝄞 −3` / `𝄞 0` in the
menu bar, and a popup when you click it. Settings are remembered per song.

<!-- Add a screenshot here: docs/popover.png -->

## Install

You build it on your own Mac with one script. Because it's compiled locally,
macOS doesn't quarantine it — **no Apple Developer account, no notarization, no
"unidentified developer" warning.**

```sh
git clone https://github.com/YOUR_USERNAME/spotify-transposer.git
cd spotify-transposer
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
rm -rf /Applications/Transposer.app && tccutil reset Microphone com.evanhu.transposer
```

## Using it

Click the menu-bar item to open the popup:

- **Now playing** — current track + artist.
- **Transpose** — `−` / value / `+`, or the slider (±12 semitones). *Reset*
  (↺) appears when shifted.
- **Reduce vocals (karaoke)** — experimental center-channel cancellation to duck
  the original lead vocal; works best on stereo tracks.
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
  popup sets semitones ─► [vocal reduce] ─► Rubber Band R3 ◄── source node
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

## Caveats

- Rubber Band R3 handles the full ±12 range well; very large shifts still thin
  out musically (physics, not the algorithm). Engaging adds startup latency (the
  music begins a fraction of a second after you hit a non-zero key).
- Karaoke vocal-reduce is approximate — it can't fully remove vocals and thins
  centered bass; it's a starting-point prototype.
- Capture and output run on independent clocks; the ring buffer self-heals tiny
  drift, so very long sessions may have rare sub-millisecond glitches.

## Diagnostics & tests

```sh
swift probe.swift                              # OSStatus of each Core Audio tap call
TRANSPOSER_SELFTEST=1 .build/debug/Transposer  # headless engagement state-machine test
TRANSPOSER_RBTEST=1   .build/debug/Transposer  # Rubber Band pitch-accuracy check (440Hz +7st)
```

To build without installing: `./make-app.sh && open Transposer.app`.

## License

This project is **GPLv2-or-later** (see [`LICENSE`](LICENSE)). It must be — it
statically links the [Rubber Band Library](https://breakfastquay.com/rubberband/)
by Particular Programs Ltd, which is GPLv2+. The Rubber Band source is vendored
under [`Sources/CRubberBand`](Sources/CRubberBand) (single-file build, using
Apple's vDSP FFT). If you want to ship a closed-source build, obtain a
commercial Rubber Band licence from Breakfast Quay.
