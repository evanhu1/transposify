# Transposify

A macOS menu-bar app that lets you **transpose and mix Spotify songs in
realtime**.

https://github.com/user-attachments/assets/f7157fe1-7879-4905-acac-966362948482

<p align="center">
  <img src="docs/popover-mix.png" alt="The Transposify popover" width="300">
</p>

## Install

Downloading the app (option 1) is quicker but it's unsigned so you'll need to tell MacOS it's safe. Building from source (option 2) skips this.

### Option 1: download the app

1. Download `Transposify-<version>.dmg` from the
   [latest release](https://github.com/evanhu1/transposify/releases/latest).
2. Open the `.dmg` and drag **Transposify** onto the **Applications** folder
   beside it.
3. Open Transposify from Applications. macOS will refuse the first time:
   *"Transposify" Not Opened — Apple could not verify…* Click **Done**.
4. Open **System Settings ▸ Privacy & Security**, scroll to the bottom of the
   page, and click **Open Anyway** next to the Transposify message. Confirm
   with your password or Touch ID.

   This happens because the app is not signed with an Apple Developer ID,
   so macOS cannot check it. It is a one-time decision; after it the app
   opens like any other.
5. Look for the `𝄞` in your menu bar. macOS asks for permissions on first
   launch. **System Audio Recording** is what Core Audio uses to capture
   Spotify's audio (older versions of macOS ask for **Microphone** instead —
   it never touches your real microphone). **Automation** (controlling
   Spotify) is for reading the current track and pausing Spotify for a few
   seconds while the model loads. Allow them.
6. To remove vocals or isolate stems, click **Download** in the popover. It
   fetches the separation model (118 MB) once and verifies it.

**Updating:** download the new `.dmg` and drag the app over the old one. Your
settings, per-song transposes and the model stay where they are.

### Option 2: build from source

```sh
git clone https://github.com/evanhu1/transposify.git
cd transposify
./install.sh
```

That builds the app, ad-hoc-signs it, installs it to `/Applications`, and
launches it. macOS does not quarantine apps built on the Mac they run on, so
step 4 above does not apply. The permission prompts in step 5 do.

**Updating:** from the same clone used for the original install:

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
./uninstall.sh                  # app, model, settings, caches, permissions
./uninstall.sh --keep-settings  # same, but keep your per-song transposes
```

The app lives in more places than `/Applications`: the model in Application
Support, preferences, caches, a launch-at-login entry, and two privacy
permissions. The script removes all of them.

## Stem separation

**Mix** splits the track into six stems (vocals, drums, bass, guitar, piano, and
everything else) and plays back only the ones you keep. Drop the vocal to sing
lead, or keep vocal and drums to learn a part. It runs live, on your Mac.

It needs a one-time model download. Open the popover and click **Download Mix
model**, above the mix controls. The model lands in
`~/Library/Application Support/Transposify/` and is checked against a SHA-256
built into the app, so a corrupted or substituted file is refused. Until it is
there, every mix except **All** stays greyed out.

To build it yourself instead:

```sh
./install-model.sh
```

That converts Meta's HTDemucs to Core ML locally, in about ten minutes. The
converter is vendored, the Python environment is version- and hash-locked, and
the checkpoint is mirrored in this project's own `model-v1` release and verified
before conversion, so it still works the day Meta's CDN goes away. Provenance
and third-party notices:
[`tools/htdemucs-coreml/`](tools/htdemucs-coreml/README.md).

## How it works

Spotify never exposes its decoded audio. It is DRM-protected, so no injected
code (Spicetify etc.) can reach the stream for DSP. The only way to pitch-shift
it is to capture Spotify's audio _output_ and process it before your speakers:

```
Spotify ─► Core Audio process tap (muted when tapped) ─► ring buffer
                                                              │
                              ┌───────────────────────────────┘
                              ▼
              HTDemucs via Core ML, sliding 3 s window ─► ring buffer
                              │
  popup sets semitones ─► Rubber Band R3 ◄── source node
                                  │
                                  └─► default output device
```

- **Capture**: a Core Audio _process tap_ (`AudioHardwareCreateProcessTap`,
  macOS 14.4+) grabs Spotify's audio alone, with no virtual device and no
  extension. It is created _muted when tapped_, so Spotify's own output is
  silenced and you hear only the processed copy.
- **Transpose**: the
  [Rubber Band Library](https://breakfastquay.com/rubberband/) **R3 ("finer")
  engine** in real-time mode, run inside the audio render callback. Its latency
  is higher than Apple's built-in unit, which does not matter when you sing
  _along to_ the output. Verified accurate to <0.1%.
- **Untouched playback**: the pipeline engages only while Spotify plays and
  there is something to do (`pitch ≠ 0`, or a mix that drops a stem). With
  nothing to do it runs on until the next track change, then stands down and
  leaves Spotify bit-perfect at zero latency.
- **Pausing freezes it**: pause holds the pipeline rather than tearing it down,
  so resume continues from the exact sample. Teardown would discard the audio
  still in flight, which Spotify never replays.
- **Now playing**: Spotify's `PlaybackStateChanged` distributed notification
  (instant, no polling). Per-song settings key off the same track ID.

## How the live separation works

Live separation is a sliding-window problem. HTDemucs sees **3 seconds at a
time** and takes about **45 ms** per window on an M4 Max.

```
     ──  3 s window the model actually sees  ──
┌───────────────────────────────────────────────┐
│        past context        │ keep │ lookahead │
└───────────────────────────────────────────────┘
                             └ hop ─┘           └─ newest audio captured
```

**Hop** is how often the model runs, and the block size the audio comes out in.
GPU duty is `inference ÷ hop`: every second is about 10% duty, every
quarter-second about 40%. A smaller hop means fresher output at the cost of
power, and only while separating, since **All** copies the window through
untouched.

**Lookahead** is how much captured audio sits _after_ the part being kept.
Future context helps: a held vowel and a cymbal decay are far easier to tell
apart once you have heard what follows. The benefit has a sharp knee.

| lookahead               | 0 s  | 0.25 s | 0.5 s | 1.0 s | 2.0 s |
| ----------------------- | ---- | ------ | ----- | ----- | ----- |
| quality (dB vs offline) | 19.3 | 20.5   | 22.0  | 23.2  | 24.2  |

Beyond half a second it buys almost nothing, and below a quarter-second the
curve is shallow: a 60 s run at 0.12 s scored within 0.5 dB of 0.25 s at the
tenth percentile, and 0.06 s within 0.6 dB. The default is 0.12 s — 130 ms
of delay for half a dB.

**Window** is the model's. HTDemucs was trained on 7.8 s segments, and that
is what the first releases used; every hop then cost a full 7.8 s prediction
to emit a quarter-second, and the GPU never got the idle time it needs to run
at full clock (see below). Converted at 3 s the prediction costs a quarter as
much. On a 60 s test against the 7.8 s window:

| window              | 2 s  | 3 s  | 4 s  | 7.8 s |
| ------------------- | ---- | ---- | ---- | ----- |
| quality (dB, median) | 20.9 | 22.1 | 22.3 | 23.1  |
| prediction, M4 Max  | 33 ms | 45 ms | 70 ms | 113 ms |

Two runs of the *same* 7.8 s model differ from each other at ~23 dB, so 3 s
and 4 s are within the measurement's own floor; 2 s is audibly rougher.

**Delay** is the three added together, `hop + lookahead + cushion`, plus the
pitch shifter and two IO buffers (~60 ms). Inference is not in the sum: it
sets how small the hop and cushion can be, not the delay itself.

### Hop is chosen automatically

A hop at 40% duty on an M4 Max would demand nearly 300% on an M1, where the
worker falls permanently behind and the audio breaks up. One hard-coded value
cannot serve both.

So the model is timed as it loads (playback is paused for the load, so the
measurement is free), the fastest reading is kept, and the hop is scaled to
roughly **40% GPU duty**, clamped to 0.15–2.0 s:

| Mac                   | inference | hop     | delay   |
| --------------------- | --------- | ------- | ------- |
| M4 Max                | ~45 ms    | 0.15 s  | ~0.45 s |
| mid-range (estimated) | ~115 ms   | ~0.29 s | ~0.65 s |
| M1 (estimated)        | ~270 ms   | ~0.67 s | ~1.1 s  |

A prediction is not a fixed cost. On Apple GPUs it depends on how much idle
time preceded it — with the 7.8 s window, 113 ms after a quarter-second of
idle and 245 ms back-to-back — so a hop that leaves the GPU no gap makes
every prediction slower, and the worker falls behind. That is why the hop
cannot simply be set to the prediction time, and why the shorter window
(less work per prediction, more idle per hop) was worth more than any other
change. `TRANSPOSIFY_PREDICT_BENCH=song.wav .build/release/Transposify`
measures the curve on any Mac.

The output **cushion** — how much finished audio sits in front of the
speaker — is sized from the slowest step seen on this machine, capped at
350 ms. Underruns, pauses and late steps used to deepen the pipeline for
good; a **governor** now plays up to 3% fast (Rubber Band's time ratio,
pitch untouched) until the depth is back at its target, so nothing is lost
and nothing accumulates.

### Every mix carries the same delay, including All

Separated audio exists only once the input has passed it by
`lookahead + inference`, so playing it in time requires a delayed output. A
zero-delay **All** cutting over to a delayed stream would have to gap, repeat,
or bend the tempo.

So **All** runs the same window and hop machinery and copies the input instead
of predicting it: same delay, no GPU. Switching is then only a flag. The worker
already holds the history and lookahead the new mix needs, so the next block
comes out changed and the existing crossfade joins it to the previous one. No
gap, no repeat, no drift.

Every control the user can click still takes a moment to reach the ears: the
change enters at the front of the pipeline and has to travel its whole delay.
So the popover dims the controls and says "Loading…" from the click until
the audio matches them — about a second and a half for a mix change, longer for
a cold load. The dim is the same one the Off button uses, and it means the same
thing: what you see is not what is playing yet.

A cold model load is the one wait that audio cannot cover. The pipeline plays
the mix through until the model is resident, so the vocal you asked to remove
would keep playing for those seconds. Transposify pauses Spotify instead and
plays again the moment the model is ready, so the first note you hear is the
mix you asked for. Press play yourself during the load and it lets you.
Without Automation permission it cannot pause, and the audio plays through as
before.

## Diagnostics & tests

```sh
swift probe.swift                              # OSStatus of each Core Audio tap call
TRANSPOSIFY_SELFTEST=1 .build/debug/Transposify  # headless engagement state-machine test
TRANSPOSIFY_RBTEST=1   .build/debug/Transposify  # Rubber Band pitch-accuracy check (440Hz +7st)
```

Record an engaged session and analyze its samples, delay, worker timing, ring
depth and underruns:

```sh
TRANSPOSIFY_RECORD=/tmp/transposify-session \
TRANSPOSIFY_RECORD_AUTOSTOP=60 .build/debug/Transposify
tools/analyze-session.sh /tmp/transposify-session
```

Run the same pipeline from a file under a paced 512-frame audio clock:

```sh
TRANSPOSIFY_SIMULATE=tools/test-audio/song.wav:/tmp/transposify-sim \
TRANSPOSIFY_SIM_SECONDS=30 \
TRANSPOSIFY_SIM_SCRIPT="5:pause,7:play,12:vocals,20:all,25:backing,30:+3,40:track" \
.build/debug/Transposify
```

`TRANSPOSIFY_HOP`, `TRANSPOSIFY_LOOKAHEAD`, and `TRANSPOSIFY_CUSHION` override
their corresponding seconds only when set. `TRANSPOSIFY_GOVERNOR=0` disables
the depth governor. `TRANSPOSIFY_SIM_SPEED=2` runs the clock twice as fast with
proportionally tighter worker deadlines, so it is useful for stress but less
faithful to live playback. `tools/bench.sh <in.wav> [--secs N]` runs the standard
configuration sweep.

To build without installing: `./make-app.sh && open Transposify.app`.
To build the release DMG: `./make-dmg.sh` (see the script for signing and
notarizing with a Developer ID).

## License

This project is **GPLv2-or-later** (see [`LICENSE`](LICENSE)). It must be: it
statically links the
[Rubber Band Library](https://breakfastquay.com/rubberband/) by Particular
Programs Ltd, which is GPLv2+. The Rubber Band source is vendored under
[`Sources/CRubberBand`](Sources/CRubberBand) (single-file build, using Apple's
vDSP FFT). If you want to ship a closed-source build, obtain a commercial Rubber
Band licence from Breakfast Quay.
