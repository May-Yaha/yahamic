#!/usr/bin/env python3
"""Dependency-free WAV quality metrics for Yaha Desk stress artifacts."""

from __future__ import annotations

import argparse
import array
import json
import math
import sys
import wave
from pathlib import Path


def dbfs(value: float) -> float:
    return 20 * math.log10(max(value / 32_768, 1e-9))


def percentile(values: list[float], fraction: float) -> float:
    if not values:
        return -180.0
    ordered = sorted(values)
    position = fraction * (len(ordered) - 1)
    lower = int(math.floor(position))
    upper = int(math.ceil(position))
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def analyze(path: Path) -> dict[str, int | float | str]:
    with wave.open(str(path), "rb") as source:
        channels = source.getnchannels()
        sample_rate = source.getframerate()
        sample_width = source.getsampwidth()
        frames = source.getnframes()
        if sample_width != 2 or channels < 1:
            raise ValueError(f"only PCM S16 WAV is supported: {path}")
        window_size = max(sample_rate // 50, 1)  # 20 ms
        windows: list[float] = []
        peak = 0.0
        energy = 0.0
        clipped = 0
        mono_frames = 0
        while payload := source.readframes(window_size):
            samples = array.array("h", payload)
            if sys.byteorder != "little":
                samples.byteswap()
            window_energy = 0.0
            window_frames = len(samples) // channels
            for index in range(0, window_frames * channels, channels):
                sample = sum(samples[index:index + channels]) / channels
                magnitude = abs(sample)
                peak = max(peak, magnitude)
                clipped += magnitude >= 32_767
                window_energy += sample * sample
            energy += window_energy
            mono_frames += window_frames
            if window_frames == window_size:
                windows.append(dbfs(math.sqrt(window_energy / window_frames)))
    rms = math.sqrt(energy / max(mono_frames, 1))
    active = [level > -55 for level in windows]
    bursts = sum(flag and (index == 0 or not active[index - 1]) for index, flag in enumerate(active))

    return {
        "path": str(path),
        "sampleRate": sample_rate,
        "channels": channels,
        "frames": frames,
        "durationSeconds": frames / sample_rate,
        "peakDbfs": dbfs(peak),
        "rmsDbfs": dbfs(rms),
        "clippedSamples": clipped,
        "clippedRatio": clipped / max(mono_frames, 1),
        "windowP05Dbfs": percentile(windows, 0.05),
        "windowP50Dbfs": percentile(windows, 0.5),
        "windowP95Dbfs": percentile(windows, 0.95),
        "silenceRatio": sum(not flag for flag in active) / max(len(active), 1),
        "bursts": bursts,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--decoded", type=Path, required=True)
    parser.add_argument("--blackhole", type=Path, required=True)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--enhanced", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    report = {
        "decoded": analyze(args.decoded),
        "blackhole": analyze(args.blackhole),
    }
    if args.source:
        report["source"] = analyze(args.source)
    if args.enhanced:
        report["enhanced"] = analyze(args.enhanced)
    report["comparison"] = {
        "blackholeMinusDecodedDurationSeconds": (
            report["blackhole"]["durationSeconds"] - report["decoded"]["durationSeconds"]
        ),
        "blackholeMinusDecodedRmsDb": report["blackhole"]["rmsDbfs"] - report["decoded"]["rmsDbfs"],
    }
    if args.enhanced:
        report["comparison"]["enhancedMinusDecodedRmsDb"] = (
            report["enhanced"]["rmsDbfs"] - report["decoded"]["rmsDbfs"]
        )
        report["comparison"]["enhancedMinusDecodedSilenceRatio"] = (
            report["enhanced"]["silenceRatio"] - report["decoded"]["silenceRatio"]
        )
    rendered = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.write_text(rendered, encoding="utf-8")
    print(rendered, end="")


if __name__ == "__main__":
    main()
