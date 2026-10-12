#!/usr/bin/env python3
"""Offline acoustic emphasis and speaking-rate prototype; no App integration.

Inputs are explicitly supplied 16 kHz mono audio and JSON/JSONL segments.
Outputs contain scalar features and timing only, never transcript text. See
docs/PROSODY-PROTOTYPE.md for units, score definitions and limitations.
"""
from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass, field
import hashlib
import importlib.metadata
import json
import math
from pathlib import Path
import re
import time
from typing import Any

import numpy as np
from scipy import signal
import soundfile as sf

SR = 16000
FRAME = 1024
HOP = 160
PAUSE_MIN_S = 0.15
MIN_BASELINE = 5
Z_LIMIT = 6.0

# Floors are in feature units, not numerical epsilon. They bound scores when
# the MAD is zero (e.g. a nearly constant tone followed by one outlier).
FEATURE_FLOORS = {
    "duration_s": 0.10,
    "f0_median_hz": 0.5,  # Normalized in semitones, despite the raw column unit.
    "f0_range_st": 0.5,
    "f0_slope_st_s": 0.5,
    "voiced_fraction": 0.05,
    "rms_mean_dbfs": 1.0,
    "rms_peak_dbfs": 1.0,
    "rms_dynamic_db": 1.0,
    "loudness_lufs": 1.0,
    "rate_per_s": 0.25,
    "word_duration_mean_s": 0.05,
    "pause_inside_s": 0.15,
    "pause_inside_max_s": 0.15,
    "pause_before_s": 0.15,
    "pause_fraction": 0.05,
    "spectral_tilt_db_oct": 1.0,
    "alpha_ratio_db": 1.0,
    "spectral_centroid_hz": 100.0,
    "active_fraction": 0.05,
}
FEATURES = tuple(FEATURE_FLOORS)
# Positive deviations only. Range/pitch dominate; level contributes 20%.
# Pauses and slowing can also make a segment acoustically prominent.
EMPHASIS_WEIGHTS = {
    "f0_median_hz": (0.30, 1), "f0_range_st": (0.30, 1),
    "rms_mean_dbfs": (0.10, 1), "loudness_lufs": (0.10, 1),
    "pause_before_s": (0.10, 1), "rate_per_s": (0.10, -1),
}


@dataclass(frozen=True)
class Word:
    start: float
    end: float


@dataclass(frozen=True)
class Segment:
    index: int
    start: float
    end: float
    speaker: str = "unspecified"
    count: int | None = None
    rate_unit: str = "words"
    words: tuple[Word, ...] = ()
    count_source: str = "missing"


@dataclass
class FeatureRow:
    segment: Segment
    values: dict[str, float | None]
    eligible: bool
    quality: str
    pause_source: str
    z: dict[str, float | None] = field(default_factory=dict)
    emphasis: float | None = None
    pace: float | None = None
    score_status: str = "insufficient_baseline"


def _number(value: Any, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError(f"{label} must be a finite number")
    return float(value)


def _time(row: dict, names: tuple[str, ...], label: str) -> float:
    for key in names:
        if key in row:
            return _number(row[key], label)
    raise ValueError(f"missing {label}")


def parse_segments(data: Any) -> list[Segment]:
    """Accept normalized, App segment, or numeric public ASR feature rows.

    Word timestamps are absolute audio seconds, never implicitly offset.
    Missing counts remain missing; a failed ASR's zero is not a slow speaker.
    """
    if isinstance(data, dict):
        data = data.get("segments")
    if not isinstance(data, list) or not data:
        raise ValueError("expected a nonempty segment list")
    result = []
    for ordinal, row in enumerate(data):
        if not isinstance(row, dict):
            raise ValueError("segment must be an object")
        start = _time(row, ("start_s", "start", "startTime"), "segment start")
        end = _time(row, ("end_s", "end", "endTime"), "segment end")
        if not 0 <= start <= end:
            raise ValueError("segment timestamps must be nonnegative and ordered")
        if end - start > 60:
            raise ValueError("segments must be at most 60 seconds; split longer intervals first")
        index = row.get("index", ordinal)
        if type(index) is not int or index < 0:
            raise ValueError("segment index must be a nonnegative integer")
        speaker = row.get("speaker", "unspecified")
        if not isinstance(speaker, str) or not speaker:
            raise ValueError("speaker must be a nonempty string")
        raw_words = row.get("words", [])
        if not isinstance(raw_words, list):
            raise ValueError("words must be a list")
        words = []
        for word in raw_words:
            if not isinstance(word, dict):
                raise ValueError("word must be an object")
            a = _time(word, ("start_s", "start"), "word start")
            b = _time(word, ("end_s", "end"), "word end")
            if not start <= a < b <= end or (words and a < words[-1].end):
                raise ValueError("words must be within the segment and not overlap")
            words.append(Word(a, b))
        count, unit, source = None, "words", "missing"
        if words:
            count, source = len(words), "word_timestamps"
        else:
            for key, label in (("word_count", "words"), ("pk_word_count", "words"),
                               ("char_count", "characters")):
                if key in row:
                    value = row[key]
                    if type(value) is not int or value < 0:
                        raise ValueError("counts must be nonnegative integers")
                    count, unit, source = value, label, "segment_count"
                    break
            if count is None:
                text = row.get("text", row.get("english", ""))
                if not isinstance(text, str):
                    raise ValueError("segment text must be a string")
                # CJK is not whitespace-tokenized; explicitly label the proxy.
                if re.search(r"[\u3400-\u9fff]", text):
                    count = len(re.findall(r"[\u3400-\u9fff]", text))
                    count += len(re.findall(r"[^\W_]+(?:['’\-][^\W_]+)*",
                                            re.sub(r"[\u3400-\u9fff]", " ", text)))
                    unit, source = "characters", "text_count_proxy"
                elif text.strip():
                    count = len(re.findall(r"[^\W_]+(?:['’\-][^\W_]+)*", text))
                    source = "text_count_proxy"
        if row.get("parakeet_error") is True or row.get("parakeet_accepted") is False:
            count, source = None, "asr_rejected"
        result.append(Segment(index, start, end, speaker, count, unit, tuple(words), source))
    result.sort(key=lambda s: (s.start, s.end, s.index))
    if len({s.index for s in result}) != len(result):
        raise ValueError("duplicate segment index")
    if any(b.start < a.end for a, b in zip(result, result[1:])):
        raise ValueError("overlapping segments are unsupported")
    return result


def load_segments(path: Path) -> list[Segment]:
    text = path.read_text(encoding="utf-8")
    if path.suffix.lower() == ".jsonl":
        return parse_segments([json.loads(line) for line in text.splitlines() if line.strip()])
    return parse_segments(json.loads(text))


def frames(samples: np.ndarray, size: int = FRAME, hop: int = HOP) -> np.ndarray:
    if len(samples) < size:
        return np.empty((0, size))
    return np.lib.stride_tricks.sliding_window_view(samples, size)[::hop]


def _db(values: np.ndarray | float) -> np.ndarray:
    return 20.0 * np.log10(np.maximum(values, 1e-6))


def quiet_mask(samples: np.ndarray, threshold_db: float) -> np.ndarray:
    # Nonoverlapping 10 ms bins give pause lengths in actual time, not the
    # duration of an overlapping analysis frame. Include a partial last bin.
    count = math.ceil(len(samples) / HOP)
    if count == 0:
        return np.zeros(0, dtype=bool)
    padded = np.pad(samples * samples, (0, count * HOP - len(samples)))
    lengths = np.full(count, HOP)
    lengths[-1] = len(samples) - (count - 1) * HOP
    rms = np.sqrt(padded.reshape(count, HOP).sum(axis=1) / lengths)
    return _db(rms) < threshold_db


def quiet_runs(mask: np.ndarray, duration: float) -> list[tuple[float, float]]:
    edges = np.diff(np.r_[False, mask, False].astype(np.int8))
    return [(a * HOP / SR, min(b * HOP / SR, duration))
            for a, b in zip(np.flatnonzero(edges == 1), np.flatnonzero(edges == -1))]


def pitch_track(samples: np.ndarray, active: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """YIN estimates gated by lag correlation; YIN alone voices white noise.

    No pYIN model or inference. Correlation is at YIN's estimated period and
    removes DC. The 0.60 threshold is heuristic, not a voiced probability.
    """
    import librosa
    f = frames(samples)
    if not len(f):
        return np.array([]), np.array([])
    f0 = librosa.yin(samples, fmin=65, fmax=500, sr=SR, frame_length=FRAME,
                     hop_length=HOP, center=False)
    centered = f - np.mean(f, axis=1, keepdims=True)
    lags = np.clip(np.rint(SR / f0).astype(int), 1, FRAME - 1)
    columns = np.arange(FRAME)[None, :]
    valid = columns < (FRAME - lags[:, None])
    shifted = np.take_along_axis(centered, np.minimum(columns + lags[:, None], FRAME - 1), axis=1)
    x, y = centered * valid, shifted * valid
    correlation = np.sum(x * y, axis=1) / np.maximum(
        np.sqrt(np.sum(x * x, axis=1) * np.sum(y * y, axis=1)), 1e-20)
    keep = active & (correlation >= 0.60) & np.isfinite(f0) & (f0 > 65) & (f0 < 500)
    times = (np.arange(len(f)) * HOP + FRAME / 2) / SR
    return f0[keep], times[keep]


def spectral_features(f: np.ndarray, active: np.ndarray) -> dict[str, float | None]:
    if not np.any(active):
        return {k: None for k in ("spectral_tilt_db_oct", "alpha_ratio_db", "spectral_centroid_hz")}
    spectrum = np.abs(np.fft.rfft(f[active] * np.hanning(FRAME), axis=1)) ** 2
    power = np.mean(spectrum, axis=0)
    freq = np.fft.rfftfreq(FRAME, 1 / SR)
    band = (freq >= 100) & (freq <= 4000)
    tilt = np.polyfit(np.log2(freq[band] / 100), 10 * np.log10(np.maximum(power[band], 1e-20)), 1)[0]
    low = np.sum(power[(freq >= 50) & (freq < 1000)])
    high = np.sum(power[(freq >= 1000) & (freq <= 5000)])
    return {"spectral_tilt_db_oct": float(tilt),
            "alpha_ratio_db": float(10 * np.log10(max(high, 1e-20) / max(low, 1e-20))),
            "spectral_centroid_hz": float(np.sum(freq * power) / max(np.sum(power), 1e-20))}


def extract_features(samples: np.ndarray, segment: Segment,
                     preceding: np.ndarray | None = None) -> FeatureRow:
    samples = np.asarray(samples, dtype=np.float64)
    if samples.ndim != 1 or not np.all(np.isfinite(samples)):
        raise ValueError("audio must be finite mono samples")
    duration = len(samples) / SR
    if abs(duration - (segment.end - segment.start)) > 1.5 / SR:
        raise ValueError("sample duration does not match segment")
    values = dict.fromkeys(FEATURES)
    values["duration_s"] = duration
    if segment.count is not None and duration > 0:
        values["rate_per_s"] = segment.count / duration
    if segment.words:
        values["word_duration_mean_s"] = float(np.mean([w.end - w.start for w in segment.words]))
    if not len(samples):
        return FeatureRow(segment, values, False, "empty", "unavailable")
    f = frames(samples)
    # RMS amplitude of each frame; very short input gets one actual RMS.
    rms = np.sqrt(np.mean(f * f, axis=1)) if len(f) else np.array([np.sqrt(np.mean(samples * samples))])
    level = _db(rms)
    threshold = max(-50.0, float(np.percentile(level, 95)) - 30.0)
    active = level >= threshold
    values.update(rms_mean_dbfs=float(_db(np.mean(rms))),
                  rms_peak_dbfs=float(_db(np.max(rms))),
                  rms_dynamic_db=float(np.percentile(level, 90) - np.percentile(level, 10)),
                  active_fraction=float(np.mean(active)))
    quiet = quiet_mask(samples, threshold)
    runs = quiet_runs(quiet, duration)
    inside = [(a, b) for a, b in runs if a > 0 and b < duration and b - a >= PAUSE_MIN_S]
    pause_source = "acoustic_threshold"
    if segment.words:
        inside = [(a.end - segment.start, b.start - segment.start)
                  for a, b in zip(segment.words, segment.words[1:]) if b.start - a.end >= PAUSE_MIN_S]
        pause_source = "word_gaps"
    values["pause_inside_s"] = sum(b - a for a, b in inside)
    values["pause_inside_max_s"] = max((b - a for a, b in inside), default=0.0)
    values["pause_fraction"] = float(np.sum([b - a for a, b in runs]) / duration)
    # Measure contiguous quiet time before the first sound in this segment.
    # The context is bounded at five seconds and never equated with a text gap.
    leading = runs[0][1] if runs and runs[0][0] == 0 else 0.0
    before = 0.0
    if preceding is not None and len(preceding):
        preceding = np.asarray(preceding, dtype=np.float64)
        if preceding.ndim != 1 or not np.all(np.isfinite(preceding)):
            raise ValueError("preceding audio must be finite mono samples")
        prior_runs = quiet_runs(quiet_mask(preceding, threshold), len(preceding) / SR)
        if prior_runs and prior_runs[-1][1] == len(preceding) / SR:
            before = prior_runs[-1][1] - prior_runs[-1][0]
    values["pause_before_s"] = leading + before
    silent = float(np.max(rms)) < 10 ** (-50 / 20)
    if duration < 0.4 or not len(f) or silent:
        values["voiced_fraction"] = 0.0
        return FeatureRow(segment, values, False, "silent" if silent else "too_short", pause_source)
    f0, times = pitch_track(samples, active)
    values["voiced_fraction"] = len(f0) / len(f)
    if len(f0):
        semitones = 12 * np.log2(f0)
        values["f0_median_hz"] = float(np.median(f0))
        values["f0_range_st"] = float(np.percentile(semitones, 90) - np.percentile(semitones, 10))
        if len(f0) >= 3 and np.ptp(times) >= 0.1:
            # Winsorize extremes; fit vs actual time, not compressed voiced time.
            clipped = np.clip(semitones, *np.percentile(semitones, [5, 95]))
            values["f0_slope_st_s"] = float(np.polyfit(times, clipped, 1)[0])
    values.update(spectral_features(f, active))
    import pyloudnorm
    loudness = pyloudnorm.Meter(SR).integrated_loudness(samples)
    values["loudness_lufs"] = float(loudness) if math.isfinite(loudness) else None
    eligible = values["voiced_fraction"] >= 0.10 and values["active_fraction"] >= 0.20
    return FeatureRow(segment, values, eligible, "ok" if eligible else "low_voicing", pause_source)


def _normalize_value(name: str, value: float) -> float:
    return 12 * math.log2(value) if name == "f0_median_hz" else value


def normalize(rows: list[FeatureRow]) -> dict:
    """Whole-input, speaker-local median/MAD. No persistent speaker profile.

    Counts in characters and words never share a rate baseline. Unusable
    segments are excluded from *all* baselines and have no aggregate scores.
    """
    baselines = {}
    for speaker in sorted({row.segment.speaker for row in rows}):
        group = [r for r in rows if r.segment.speaker == speaker]
        stats = {}
        for name in FEATURES:
            units = sorted({r.segment.rate_unit for r in group}) if name == "rate_per_s" else [None]
            for unit in units:
                available = [r for r in group if r.eligible and r.values[name] is not None
                             and (unit is None or r.segment.rate_unit == unit)]
                key = name if unit is None else name + ":" + unit
                values = np.array([_normalize_value(name, r.values[name]) for r in available])
                if len(values) < MIN_BASELINE:
                    stats[key] = {"n": len(values), "median": None, "mad": None, "scale": None}
                    continue
                median = float(np.median(values))
                mad = float(np.median(np.abs(values - median)))
                scale = max(1.4826 * mad, FEATURE_FLOORS[name])
                stats[key] = {"n": len(values), "median": median, "mad": mad, "scale": scale}
        baselines[speaker] = stats
        for row in group:
            row.z = dict.fromkeys(FEATURES)
            row.emphasis = row.pace = None
            row.score_status = "excluded" if not row.eligible else "insufficient_baseline"
            if not row.eligible:
                continue
            for name in FEATURES:
                key = name + ":" + row.segment.rate_unit if name == "rate_per_s" else name
                stat = stats[key]
                value = row.values[name]
                if value is not None and stat["scale"] is not None:
                    row.z[name] = float(np.clip((_normalize_value(name, value) - stat["median"]) / stat["scale"],
                                                -Z_LIMIT, Z_LIMIT))
            row.pace = row.z["rate_per_s"]
            components = [(weight, max(0.0, sign * row.z[name]))
                          for name, (weight, sign) in EMPHASIS_WEIGHTS.items() if row.z[name] is not None]
            # Pitch is required. Missing rate/level components are omitted and
            # remaining weights renormalized; the z columns expose coverage.
            if row.z["f0_median_hz"] is not None and row.z["f0_range_st"] is not None:
                row.emphasis = sum(w * z for w, z in components) / sum(w for w, _ in components)
                row.score_status = "ok" if len(components) == len(EMPHASIS_WEIGHTS) else "partial_features"
    return baselines


def csv_record(row: FeatureRow) -> dict:
    s = row.segment
    return {"index": s.index, "start_s": s.start, "end_s": s.end, "speaker": s.speaker,
            "count": s.count, "rate_unit": s.rate_unit, "count_source": s.count_source,
            "pause_source": row.pause_source, "quality": row.quality,
            "eligible": int(row.eligible), "score_status": row.score_status,
            **row.values, **{"z_" + k: v for k, v in row.z.items()},
            "emphasis_score": row.emphasis, "pace_deviation_score": row.pace}


def distribution(values: list[float]) -> dict:
    if not values:
        return {"n": 0, "min": None, "p10": None, "median": None, "p90": None, "max": None}
    q = np.percentile(values, [0, 10, 50, 90, 100])
    return dict(n=len(values), **dict(zip(("min", "p10", "median", "p90", "max"), map(float, q))))


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write_outputs(out: Path, rows: list[FeatureRow], summary: dict) -> None:
    # A new output directory makes reruns reviewable, never overwrites results.
    out.mkdir(parents=True, exist_ok=False)
    records = [csv_record(r) for r in rows]
    with (out / "vectors.csv").open("x", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(records[0]))
        writer.writeheader()
        writer.writerows(records)
    # Numeric-only extremes; names, text and speaker IDs are intentionally absent.
    scored = [r for r in rows if r.emphasis is not None]
    for label, reverse in (("highest", True), ("lowest", False)):
        selected = sorted(scored, key=lambda r: (-r.emphasis if reverse else r.emphasis, r.segment.start))[:10]
        with (out / f"{label}-10.csv").open("x", encoding="utf-8", newline="") as handle:
            writer = csv.writer(handle)
            writer.writerow(["start_s", "end_s", "emphasis_score", "pace_deviation_score"])
            for row in selected:
                writer.writerow([row.segment.start, row.segment.end, row.emphasis, row.pace])
    (out / "summary.json").write_text(json.dumps(summary, indent=2, allow_nan=False) + "\n", encoding="utf-8")


def analyze(audio: Path, segments_path: Path, out: Path) -> dict:
    if out.exists() or out.is_symlink():
        raise FileExistsError("output directory already exists")
    start_wall, start_cpu = time.perf_counter(), time.process_time()
    segments = load_segments(segments_path)
    rows = []
    with sf.SoundFile(audio) as source:
        if source.samplerate != SR or source.channels != 1:
            raise ValueError("input must already be 16 kHz mono; no automatic conversion")
        audio_duration = len(source) / SR
        for s in segments:
            if s.end > audio_duration + 0.5 / SR:
                raise ValueError("segment extends beyond audio")
        for s in segments:
            a, b = round(s.start * SR), round(s.end * SR)
            context_start = max(0, a - 5 * SR)
            source.seek(context_start)
            preceding = source.read(a - context_start, dtype="float64")
            samples = source.read(b - a, dtype="float64")
            rows.append(extract_features(samples, s, preceding))
    baseline = normalize(rows)
    cpu, wall = time.process_time() - start_cpu, time.perf_counter() - start_wall
    analyzed_seconds = sum(r.values["duration_s"] for r in rows)
    versions = {}
    for name in ("numpy", "scipy", "soundfile", "librosa", "pyloudnorm"):
        versions[name] = importlib.metadata.version(name)
    summary = {"schema": 1, "features": list(FEATURES), "libraries": versions,
               "input_audio_sha256": sha256(audio), "input_segments_sha256": sha256(segments_path),
               "audio_duration_s": audio_duration, "analyzed_duration_s": analyzed_seconds,
               "segment_count": len(rows), "eligible_count": sum(r.eligible for r in rows),
               "scored_count": sum(r.emphasis is not None for r in rows),
               "cpu_s": cpu, "wall_s": wall,
               "cpu_s_per_audio_hour": cpu * 3600 / audio_duration if audio_duration else None,
               "cpu_s_per_analyzed_hour": cpu * 3600 / analyzed_seconds if analyzed_seconds else None,
               "timing_scope": "segment parsing, audio reads, feature imports/extraction and normalization; excludes hashes/output/plots",
               "baseline": baseline, "z_clip": Z_LIMIT, "minimum_baseline_segments": MIN_BASELINE,
               "emphasis_distribution": distribution([r.emphasis for r in rows if r.emphasis is not None]),
               "pace_distribution": distribution([r.pace for r in rows if r.pace is not None]),
               "rate_distributions": {unit: distribution([r.values["rate_per_s"] for r in rows
                                            if r.eligible and r.segment.rate_unit == unit and r.values["rate_per_s"] is not None])
                                      for unit in sorted({r.segment.rate_unit for r in rows})},
               "quality_counts": {q: sum(r.quality == q for r in rows) for q in sorted({r.quality for r in rows})},
               "limits": ["heuristic acoustic prominence, no semantic importance ground truth",
                          "speaker labels are supplied, not inferred; unspecified may mix speakers",
                          "whole-input baseline, not causal or cross-lesson",
                          "pause threshold and YIN correlation gate are heuristic",
                          "pre-segment silence context is capped at 5 seconds",
                          "segment-count rate includes pauses; not articulation rate",
                          "no emotion or intent classification"]}
    write_outputs(out, rows, summary)
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--audio", type=Path, required=True)
    parser.add_argument("--segments", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="new directory for numeric-only results")
    args = parser.parse_args()
    try:
        result = analyze(args.audio, args.segments, args.output)
    except (OSError, ValueError) as error:
        # Do not print file paths or decoder exception content from private input.
        parser.exit(2, f"prosody analysis failed ({type(error).__name__}); check input format and new output directory\n")
    print(json.dumps({k: result[k] for k in ("segment_count", "scored_count", "cpu_s", "wall_s", "cpu_s_per_audio_hour")}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
