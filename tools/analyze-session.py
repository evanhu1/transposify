#!/usr/bin/env python3
"""Analyze a Transposify recording without relying on raw-waveform alignment."""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import tempfile
from pathlib import Path

os.environ.setdefault("MPLCONFIGDIR", "/tmp/transposify-matplotlib")

try:
    import matplotlib
    import numpy as np
    from scipy import ndimage, signal
    from scipy.io import wavfile
except ModuleNotFoundError:
    venv_python = Path(__file__).resolve().parent / ".venv" / "bin" / "python"
    if venv_python.exists() and Path(sys.prefix) != venv_python.parent.parent:
        os.execv(str(venv_python), [str(venv_python), *sys.argv])
    raise

matplotlib.use("Agg")
import matplotlib.pyplot as plt


SILENCE_RMS = 10 ** (-60 / 20)


def read_audio(path: Path) -> tuple[int, np.ndarray]:
    rate, audio = wavfile.read(path)
    if audio.ndim == 1:
        audio = audio[:, None]
    if np.issubdtype(audio.dtype, np.integer):
        info = np.iinfo(audio.dtype)
        audio = audio.astype(np.float32) / max(abs(info.min), info.max)
    else:
        audio = audio.astype(np.float32, copy=False)
    return int(rate), audio


def read_events(path: Path) -> list[dict]:
    events = []
    with path.open(encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            if not line.strip():
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError as error:
                raise ValueError(f"{path}:{number}: {error}") from error
    return events


def mel_filterbank(rate: int, fft_size: int, bands: int = 48) -> np.ndarray:
    def mel(hz: np.ndarray | float) -> np.ndarray:
        return 2595 * np.log10(1 + np.asarray(hz) / 700)

    def hz(mels: np.ndarray) -> np.ndarray:
        return 700 * (10 ** (mels / 2595) - 1)

    points = hz(np.linspace(mel(40), mel(rate / 2), bands + 2))
    bins = np.floor((fft_size + 1) * points / rate).astype(int)
    bank = np.zeros((bands, fft_size // 2 + 1), dtype=np.float32)
    for band in range(bands):
        left, center, right = bins[band : band + 3]
        if center > left:
            bank[band, left:center] = np.arange(center - left) / (center - left)
        if right > center:
            bank[band, center:right] = np.arange(right - center, 0, -1) / (right - center)
    return bank


def onset_envelope(audio: np.ndarray, rate: int) -> tuple[np.ndarray, np.ndarray]:
    mono = np.mean(audio, axis=1, dtype=np.float32)
    fft_size = 2048 if rate >= 32_000 else 1024
    hop = max(1, round(rate * 0.005))
    _, times, spectrum = signal.stft(
        mono, fs=rate, window="hann", nperseg=fft_size,
        noverlap=fft_size - hop, boundary=None, padded=False,
    )
    mel_energy = mel_filterbank(rate, fft_size) @ np.abs(spectrum)
    compressed = np.log1p(20 * mel_energy)
    flux = np.maximum(0, np.diff(compressed, axis=1)).sum(axis=0)
    flux = np.concatenate(([0.0], flux)).astype(np.float32)
    if flux.size:
        flux /= np.percentile(flux, 95) + 1e-9
    return times, flux


def delay_curve(input_audio: np.ndarray, output_audio: np.ndarray, rate: int,
                prior_seconds: float | None = None) -> dict:
    input_times, input_onsets = onset_envelope(input_audio, rate)
    output_times, output_onsets = onset_envelope(output_audio, rate)
    hop_seconds = float(np.median(np.diff(input_times)))
    window_bins = max(8, round(4.0 / hop_seconds))
    stride_bins = max(1, round(1.0 / hop_seconds))
    max_lag_bins = round(3.0 / hop_seconds)
    # Bar-periodic music offers the envelope correlator many equally-good
    # wrong alignments; a 4 s window cannot tell a true 0.5 s delay from a
    # bar-aligned 2.5 s one. The worker publishes its counter-based depth
    # alongside the audio, so use it as a prior: the acoustic estimate then
    # only has to find the fine structure (Rubber Band + IO buffers) on top,
    # which is exactly what it is good at.
    min_lag_bins, max_lag_bins_prior = 0, max_lag_bins
    if prior_seconds is not None and np.isfinite(prior_seconds):
        margin_s = 0.150
        min_lag_bins = max(0, int((prior_seconds - margin_s) / hop_seconds))
        max_lag_bins_prior = min(max_lag_bins, int((prior_seconds + margin_s) / hop_seconds))
        if max_lag_bins_prior <= min_lag_bins:
            max_lag_bins_prior = min_lag_bins + 1
    limit = min(len(input_onsets), len(output_onsets))
    points = []

    for start in range(0, max(0, limit - window_bins), stride_bins):
        source = input_onsets[start : start + window_bins].astype(np.float64)
        source -= source.mean()
        source_norm = np.linalg.norm(source)
        if source_norm < 1e-7:
            continue
        correlations = []
        lags = []
        for lag in range(min_lag_bins, max_lag_bins_prior + 1):
            end = start + lag + window_bins
            if end > len(output_onsets):
                break
            target = output_onsets[start + lag : end].astype(np.float64)
            target -= target.mean()
            norm = source_norm * np.linalg.norm(target)
            correlations.append(float(np.dot(source, target) / norm) if norm > 1e-9 else 0.0)
            lags.append(lag)
        if not correlations:
            continue
        values = np.asarray(correlations)
        best = int(np.argmax(values))
        peak = float(values[best])
        guard = max(1, round(0.03 / hop_seconds))
        others = values.copy()
        others[max(0, best - guard) : best + guard + 1] = -1
        prominence = peak - float(np.max(others)) if len(others) > guard * 2 + 1 else peak
        trusted = peak >= 0.12 and prominence >= 0.008
        lag_seconds = lags[best] * hop_seconds
        points.append({
            "t": float(input_times[start] + 2.0 + lag_seconds),
            "delaySeconds": lag_seconds,
            "correlation": peak,
            "prominence": prominence,
            "trusted": trusted,
        })

    trusted = [point for point in points if point["trusted"]]
    delays = np.asarray([point["delaySeconds"] for point in trusted])
    times = np.asarray([point["t"] for point in trusted])
    if len(trusted) >= 2:
        slope = float(np.polyfit(times, delays, 1)[0] * 60_000)
    else:
        slope = math.nan
    return {
        "windows": points,
        "trustedWindows": len(trusted),
        "weakWindows": len(points) - len(trusted),
        "minSeconds": float(np.min(delays)) if len(delays) else math.nan,
        "medianSeconds": float(np.median(delays)) if len(delays) else math.nan,
        "maxSeconds": float(np.max(delays)) if len(delays) else math.nan,
        "driftMsPerMinute": slope,
    }


def interpolated_delay(curve: dict, times: np.ndarray) -> np.ndarray:
    trusted = [point for point in curve["windows"] if point["trusted"]]
    if not trusted:
        fallback = curve["medianSeconds"]
        if not np.isfinite(fallback):
            fallback = 0.0
        return np.full_like(times, fallback, dtype=np.float64)
    x = np.asarray([point["t"] for point in trusted])
    y = np.asarray([point["delaySeconds"] for point in trusted])
    return np.interp(times, x, y, left=y[0], right=y[-1])


def millisecond_rms(audio: np.ndarray, rate: int) -> tuple[np.ndarray, np.ndarray]:
    frame = max(1, round(rate * 0.001))
    count = len(audio) // frame
    trimmed = audio[: count * frame]
    rms = np.sqrt(np.mean(trimmed.reshape(count, frame, -1) ** 2, axis=(1, 2)))
    times = (np.arange(count) * frame + frame / 2) / rate
    return times, rms


def contiguous_runs(mask: np.ndarray) -> list[tuple[int, int]]:
    padded = np.pad(mask.astype(np.int8), (1, 1))
    edges = np.diff(padded)
    return list(zip(np.flatnonzero(edges == 1), np.flatnonzero(edges == -1)))


def hold_windows(events: list[dict], session_seconds: float) -> list[tuple[float, float]]:
    """Intervals where output was intentionally silent (hold/prime).

    The app holds its render callback while paused and while priming; the
    input keeps flowing in a recording, so those windows are silence by
    design. Counting them as dropouts made every scripted pause look like
    a pipeline failure. A `release` closes the window; an unclosed hold
    runs to the end of the session.
    """
    windows: list[tuple[float, float]] = []
    opened = 0.0
    is_open = False
    for event in events:
        if event.get("ev") == "hold":
            if not is_open:
                opened = float(event.get("t", 0.0))
                is_open = True
        elif event.get("ev") == "release" and is_open:
            windows.append((opened, float(event.get("t", opened))))
            is_open = False
    if is_open:
        windows.append((opened, session_seconds))
    return windows


def in_hold(t: float, windows: list[tuple[float, float]], margin: float = 0.030) -> bool:
    return any(start - margin <= t <= end + margin for start, end in windows)


def dropout_analysis(input_audio: np.ndarray, output_audio: np.ndarray, rate: int,
                     curve: dict, events: list[dict], session_seconds: float) -> dict:
    output_times, output_rms = millisecond_rms(output_audio, rate)
    input_times, input_rms = millisecond_rms(input_audio, rate)
    delays = interpolated_delay(curve, output_times)
    aligned_times = output_times - delays
    aligned_indices = np.clip(np.searchsorted(input_times, aligned_times), 0, len(input_rms) - 1)
    aligned_non_silent = (aligned_times >= 0) & (input_rms[aligned_indices] >= SILENCE_RMS)
    candidates = (output_rms < SILENCE_RMS) & aligned_non_silent
    underruns = np.asarray([event["t"] for event in events if event.get("ev") == "underrun"])
    holds = hold_windows(events, session_seconds)
    dropouts = []
    held_out = 0
    for start, end in contiguous_runs(candidates):
        duration_ms = (end - start) * 1000 * (output_times[1] - output_times[0])
        if duration_ms < 2:
            continue
        began = max(0.0, output_times[start] - 0.0005)
        ended = began + duration_ms / 1000
        if any(began < h_end + 0.030 and ended > h_start - 0.030
               for h_start, h_end in holds):
            held_out += 1          # intentional silence while held: not a failure
            continue
        coincident = bool(np.any((underruns >= began - 0.030) & (underruns <= ended + 0.030)))
        dropouts.append({"t": began, "durationMs": duration_ms,
                         "coincidesWithUnderrun": coincident})

    histogram = {"2-5": 0, "5-15": 0, "15-50": 0, "50+": 0}
    for dropout in dropouts:
        duration = dropout["durationMs"]
        bucket = "2-5" if duration < 5 else "5-15" if duration < 15 else "15-50" if duration < 50 else "50+"
        histogram[bucket] += 1
    explained = sum(dropout["coincidesWithUnderrun"] for dropout in dropouts)
    return {
        "items": dropouts,
        "count": len(dropouts),
        "totalMs": sum(item["durationMs"] for item in dropouts),
        "histogram": histogram,
        "coincidentWithUnderrun": explained,
        "unexplained": len(dropouts) - explained,
        "heldOutCount": held_out,
        "holdWindows": [list(w) for w in holds],
    }


def discontinuity_analysis(input_audio: np.ndarray, output_audio: np.ndarray, rate: int,
                           curve: dict, dropouts: dict) -> list[dict]:
    input_mono = np.mean(input_audio, axis=1)
    output_mono = np.mean(output_audio, axis=1)
    input_jump = np.abs(np.diff(input_mono, prepend=input_mono[0]))
    output_jump = np.abs(np.diff(output_mono, prepend=output_mono[0]))
    local_input_max = ndimage.maximum_filter1d(input_jump, size=max(3, round(rate * 0.020)))
    output_times = np.arange(len(output_jump)) / rate
    delays = interpolated_delay(curve, output_times)
    aligned = ((output_times - delays) * rate).astype(np.int64)
    valid = (aligned >= 0) & (aligned < len(local_input_max))
    reference = np.zeros_like(output_jump)
    reference[valid] = local_input_max[aligned[valid]]
    candidates = valid & (output_jump > 0.02) & (output_jump > reference * 1.25 + 1e-4)
    exclusion = np.zeros_like(candidates)
    margin = round(rate * 0.003)
    for dropout in dropouts["items"]:
        start = max(0, round(dropout["t"] * rate) - margin)
        end = min(len(exclusion), round((dropout["t"] + dropout["durationMs"] / 1000) * rate) + margin)
        exclusion[start:end] = True
    # Held windows are transitions by design; their edges are fades.
    for h_start, h_end in dropouts["holdWindows"]:
        start = max(0, round(h_start * rate) - round(rate * 0.030))
        end = min(len(exclusion), round(h_end * rate) + round(rate * 0.030))
        exclusion[start:end] = True
    indices = np.flatnonzero(candidates & ~exclusion)
    if not len(indices):
        return []
    groups = np.split(indices, np.flatnonzero(np.diff(indices) > round(rate * 0.005)) + 1)
    result = []
    for group in groups:
        index = int(group[np.argmax(output_jump[group])])
        result.append({
            "t": index / rate,
            "jump": float(output_jump[index]),
            "alignedInputMaxJump": float(reference[index]),
        })
    return result


def depth_comparison(curve: dict, events: list[dict]) -> dict:
    depth = [event for event in events if event.get("ev") == "depth"]
    if not depth:
        return {"samples": 0, "medianOffsetMs": math.nan, "minOffsetMs": math.nan,
                "maxOffsetMs": math.nan}
    times = np.asarray([event["t"] for event in depth])
    acoustic = interpolated_delay(curve, times)
    logged = np.asarray([event.get("depthSeconds", 0.0) for event in depth])
    offsets = (logged - acoustic) * 1000
    return {
        "samples": len(depth),
        "medianOffsetMs": float(np.median(offsets)),
        "minOffsetMs": float(np.min(offsets)),
        "maxOffsetMs": float(np.max(offsets)),
    }


def event_stats(events: list[dict], rate: int, session_seconds: float) -> dict:
    steps = [event for event in events if event.get("ev") == "step"]
    depths = [event for event in events if event.get("ev") == "depth"]
    governors = [event for event in events if event.get("ev") == "governor"]
    holds = hold_windows(events, session_seconds)
    engagements = 0
    previous = 1.0
    for event in governors:
        ratio = float(event.get("ratio", 1.0))
        if ratio < 1 and previous >= 1:
            engagements += 1
        previous = ratio
    # Ring depth during a hold is meaningless: nothing drains while held,
    # and the pause itself drains it to zero by design. Same for the priming
    # ramp before the first release. Steady-state minimum is the number that
    # says whether mode switches have margin left.
    first_release = next((float(e["t"]) for e in events if e.get("ev") == "release"), 0.0)
    def steady(event: dict) -> bool:
        t = float(event.get("t", -1.0))
        return t >= first_release and not in_hold(t, holds, margin=0.0)
    ring_samples = [event.get(key, 0) for event in steps if steady(event)
                    for key in ("ringBeforeFrames", "ringAfterFrames")]
    ring_samples += [event.get("ringFrames", 0) for event in depths if steady(event)]
    min_ring = min(ring_samples, default=0)
    return {
        "worstStepMs": max((event.get("durationMs", 0.0) for event in steps), default=0.0),
        "minRingFrames": min_ring,
        "minRingMs": min_ring * 1000 / rate,
        "governorEngagements": engagements,
        "underrunEvents": sum(event.get("ev") == "underrun" for event in events),
        "heldSeconds": sum(end - start for start, end in holds),
    }


def plot_timeline(path: Path, report: dict, events: list[dict], rate: int) -> None:
    engage = next((event for event in events if event.get("ev") == "engage"), {})
    target_ms = engage.get("targetDepth", math.nan) * 1000
    cushion_ms = engage.get("cushionSeconds", math.nan) * 1000
    steps = [event for event in events if event.get("ev") == "step"]
    depths = [event for event in events if event.get("ev") == "depth"]
    governors = [event for event in events if event.get("ev") == "governor"]
    underruns = [event for event in events if event.get("ev") == "underrun"]
    holds = [event for event in events if event.get("ev") in ("hold", "release")]

    fig, axes = plt.subplots(5, 1, figsize=(14, 11), sharex=True,
                             gridspec_kw={"height_ratios": [2, 1.3, 1.3, 0.8, 1.2]})
    fig.patch.set_facecolor("white")
    delay = report["delay"]["windows"]
    trusted = [point for point in delay if point["trusted"]]
    weak = [point for point in delay if not point["trusted"]]
    axes[0].plot([point["t"] for point in trusted],
                 [point["delaySeconds"] * 1000 for point in trusted],
                 color="#2463a7", marker="o", ms=3, label="measured delay")
    axes[0].scatter([point["t"] for point in weak],
                    [point["delaySeconds"] * 1000 for point in weak],
                    color="#9bb7d4", marker="x", label="weak window")
    axes[0].plot([event["t"] for event in depths],
                 [event.get("depthSeconds", 0) * 1000 for event in depths],
                 color="#d36b27", alpha=0.85, label="logged depth")
    if np.isfinite(target_ms):
        axes[0].axhline(target_ms, color="#555555", ls="--", label="target")
    axes[0].set_ylabel("Delay (ms)")
    axes[0].legend(loc="best", ncol=3, fontsize=8)

    axes[1].plot([event["t"] for event in steps],
                 [event.get("ringAfterFrames", 0) * 1000 / rate for event in steps],
                 color="#31865b", lw=1)
    if np.isfinite(cushion_ms):
        axes[1].axhline(cushion_ms, color="#555555", ls="--", label="cushion")
        axes[1].legend(loc="best", fontsize=8)
    axes[1].set_ylabel("Ring (ms)")

    if steps:
        axes[2].stem([event["t"] for event in steps],
                     [event.get("durationMs", 0) for event in steps],
                     linefmt="#7a5195", markerfmt=" ", basefmt=" ")
    axes[2].set_ylabel("Step (ms)")

    axes[3].eventplot([[event["t"] for event in underruns],
                       [item["t"] for item in report["dropouts"]["items"]]],
                      lineoffsets=[0.7, 0.3], linelengths=0.35,
                      colors=["#d62728", "#111111"])
    axes[3].set_yticks([0.3, 0.7], ["dropout", "underrun"])

    axes[4].plot([event["t"] for event in governors],
                 [event.get("ratio", 1.0) for event in governors],
                 color="#b04a8b", drawstyle="steps-post", label="governor ratio")
    held_at = None
    for event in holds:
        if event["ev"] == "hold":
            held_at = event["t"]
        elif held_at is not None:
            axes[4].axvspan(held_at, event["t"], color="#c8c8c8", alpha=0.35)
            held_at = None
    if held_at is not None:
        axes[4].axvspan(held_at, report["summary"]["sessionLengthSeconds"],
                        color="#c8c8c8", alpha=0.35)
    axes[4].set_ylabel("Ratio")
    axes[4].set_xlabel("Session time (s)")
    axes[4].set_ylim(0.94, 1.005)
    axes[4].legend(loc="best", fontsize=8)

    for axis in axes:
        axis.grid(True, color="#e6e6e6", lw=0.7)
        axis.set_facecolor("white")
    fig.suptitle("Transposify session timeline")
    fig.tight_layout()
    fig.savefig(path, dpi=150)
    plt.close(fig)


def finite(value: float, digits: int = 1) -> str:
    return f"{value:.{digits}f}" if np.isfinite(value) else "n/a"


def text_report(report: dict) -> str:
    summary = report["summary"]
    delay = report["delay"]
    dropouts = report["dropouts"]
    depth = report["depthComparison"]
    lines = [
        "Transposify session summary",
        "============================",
        f"Session length:       {summary['sessionLengthSeconds']:.2f} s",
        f"Dropouts:             {dropouts['count']} ({dropouts['totalMs']:.1f} ms total)",
        f"Unexplained dropouts: {dropouts['unexplained']}",
        f"Median delay:         {finite(delay['medianSeconds'] * 1000)} ms",
        f"Delay drift:          {finite(delay['driftMsPerMinute'], 2)} ms/min",
        f"Worst step:           {summary['worstStepMs']:.1f} ms",
        f"Minimum output ring:  {summary['minRingFrames']} frames ({summary['minRingMs']:.1f} ms)",
        f"Governor engagements: {summary['governorEngagements']}",
        f"Held (intentional):   {summary.get('heldSeconds', 0):.2f} s excluded from stats",
        "",
        "Dropouts",
        "--------",
        f"Histogram: {dropouts['histogram']}",
        f"Coincident with underrun (+/-30 ms): {dropouts['coincidentWithUnderrun']}",
        f"Not explained by underrun: {dropouts['unexplained']}",
    ]
    for item in dropouts["items"]:
        marker = "underrun" if item["coincidesWithUnderrun"] else "UNEXPLAINED"
        lines.append(f"  {item['t']:8.3f} s  {item['durationMs']:7.1f} ms  {marker}")
    lines += [
        "",
        "Delay",
        "-----",
        f"Min / median / max: {finite(delay['minSeconds'] * 1000)} / "
        f"{finite(delay['medianSeconds'] * 1000)} / {finite(delay['maxSeconds'] * 1000)} ms",
        f"Trusted / weak windows: {delay['trustedWindows']} / {delay['weakWindows']}",
        f"Logged depth - acoustic delay median: {finite(depth['medianOffsetMs'])} ms",
        f"Logged depth (counter truth):        "
        f"{finite((report.get('loggedDepthPriorSeconds') or float('nan')) * 1000)} ms",
        "",
        "Discontinuities",
        "---------------",
        f"Count: {len(report['discontinuities'])}",
    ]
    for item in report["discontinuities"]:
        lines.append(f"  {item['t']:8.3f} s  jump {item['jump']:.5f} "
                     f"(aligned input max {item['alignedInputMaxJump']:.5f})")
    return "\n".join(lines) + "\n"


def json_safe(value):
    if isinstance(value, dict):
        return {key: json_safe(item) for key, item in value.items()}
    if isinstance(value, list):
        return [json_safe(item) for item in value]
    if isinstance(value, float) and not math.isfinite(value):
        return None
    if isinstance(value, np.generic):
        return value.item()
    return value


def analyze(recording: Path, out: Path) -> dict:
    input_rate, input_audio = read_audio(recording / "input.wav")
    output_rate, output_audio = read_audio(recording / "output.wav")
    if input_rate != output_rate:
        raise ValueError(f"sample rates differ: input {input_rate}, output {output_rate}")
    events = read_events(recording / "events.jsonl")
    out.mkdir(parents=True, exist_ok=True)

    session_seconds = len(output_audio) / input_rate
    depths = [float(e["depthSeconds"]) for e in events if e.get("ev") == "depth"]
    prior = float(np.median(depths)) if len(depths) >= 10 else None

    curve = delay_curve(input_audio, output_audio, input_rate, prior_seconds=prior)
    dropouts = dropout_analysis(input_audio, output_audio, input_rate, curve, events,
                                session_seconds)
    stats = event_stats(events, input_rate, session_seconds)
    report = {
        "summary": {
            "sessionLengthSeconds": session_seconds,
            **stats,
        },
        "dropouts": dropouts,
        "discontinuities": discontinuity_analysis(
            input_audio, output_audio, input_rate, curve, dropouts),
        "delay": curve,
        "depthComparison": depth_comparison(curve, events),
        "loggedDepthPriorSeconds": prior,
    }
    (out / "report.json").write_text(
        json.dumps(json_safe(report), indent=2, sort_keys=True) + "\n", encoding="utf-8")
    (out / "report.txt").write_text(text_report(report), encoding="utf-8")
    plot_timeline(out / "timeline.png", report, events, input_rate)
    return report


def selftest() -> None:
    rate = 48_000
    duration = 10.0
    rng = np.random.default_rng(41)
    audio = rng.normal(0, 0.012, (int(rate * duration), 2)).astype(np.float32)
    pulse = signal.windows.hann(round(rate * 0.035)).astype(np.float32)
    for index, when in enumerate(np.arange(0.45, 8.8, 0.37)):
        start = round(when * rate)
        amplitude = 0.25 + 0.5 * ((index * 7) % 11) / 10
        audio[start : start + len(pulse)] += amplitude * pulse[:, None]

    known_delay = 0.350
    delay_frames = round(known_delay * rate)
    output = np.zeros_like(audio)
    output[delay_frames:] = audio[:-delay_frames]
    silences = [(3.0, 0.012), (6.2, 0.045)]
    for when, length in silences:
        output[round(when * rate) : round((when + length) * rate)] = 0

    with tempfile.TemporaryDirectory(prefix="transposify-analyzer-") as temp:
        root = Path(temp)
        wavfile.write(root / "input.wav", rate, audio)
        wavfile.write(root / "output.wav", rate, output)
        events = [
            {"t": 0, "ev": "engage", "sampleRate": rate, "channels": 2,
             "hopSeconds": 0.2, "lookaheadSeconds": 0.1,
             "cushionSeconds": 0.05, "targetDepth": known_delay},
            {"t": 3.0, "ev": "underrun", "shortFrames": round(0.012 * rate),
             "ringFrames": 0},
        ]
        (root / "events.jsonl").write_text(
            "".join(json.dumps(event) + "\n" for event in events), encoding="utf-8")
        report = analyze(root, root / "report")
        measured = report["delay"]["medianSeconds"]
        assert abs(measured - known_delay) <= 0.025, (measured, known_delay)
        durations = sorted(item["durationMs"] for item in report["dropouts"]["items"])
        assert len(durations) == 2, durations
        assert abs(durations[0] - 12) <= 3, durations
        assert abs(durations[1] - 45) <= 3, durations
        assert report["dropouts"]["coincidentWithUnderrun"] == 1
        print(f"analyzer self-test passed: delay={measured * 1000:.1f} ms, "
              f"dropouts={durations[0]:.1f}/{durations[1]:.1f} ms")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("recording_dir", nargs="?", type=Path)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    if args.selftest:
        selftest()
        return
    if args.recording_dir is None:
        parser.error("recording_dir is required unless --selftest is used")
    out = args.out or args.recording_dir / "report"
    analyze(args.recording_dir, out)
    print(out / "report.txt")


if __name__ == "__main__":
    main()
