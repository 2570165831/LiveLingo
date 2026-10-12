"""Synthetic direction, robustness, timing and offline-output checks."""
from __future__ import annotations

import csv
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import numpy as np
from scipy import signal
import soundfile as sf

sys.path.insert(0, str(Path(__file__).resolve().parent))
import prosody_emphasis as p


def tone(hz=200, amplitude=0.1, duration=2):
    t = np.arange(round(duration * p.SR)) / p.SR
    return amplitude * np.sin(2 * np.pi * hz * t)


def feature(samples, count=8, words=(), start=0, preceding=None):
    s = p.Segment(0, start, start + len(samples) / p.SR, count=count,
                  words=words, count_source="word_timestamps" if words else "segment_count")
    return p.extract_features(samples, s, preceding)


class Features(unittest.TestCase):
    def test_pitch_median_tracks_frequency(self):
        a, b = feature(tone(120)), feature(tone(240))
        self.assertAlmostEqual(a.values["f0_median_hz"], 120, delta=2)
        self.assertAlmostEqual(b.values["f0_median_hz"], 240, delta=3)
        self.assertGreater(a.values["voiced_fraction"], 0.95)

    def test_pitch_range_and_signed_slope(self):
        t = np.arange(3 * p.SR) / p.SR
        up = 0.1 * signal.chirp(t, f0=120, t1=3, f1=260)
        down = 0.1 * signal.chirp(t, f0=260, t1=3, f1=120)
        steady, rising, falling = feature(tone()), feature(up), feature(down)
        self.assertGreater(rising.values["f0_range_st"], steady.values["f0_range_st"] + 5)
        self.assertGreater(rising.values["f0_slope_st_s"], 2)
        self.assertLess(falling.values["f0_slope_st_s"], -2)

    def test_rms_and_lufs_amplitude_direction(self):
        a, b = feature(tone(amplitude=0.05)), feature(tone(amplitude=0.1))
        for name in ["rms_mean_dbfs", "rms_peak_dbfs", "loudness_lufs"]:
            self.assertAlmostEqual(b.values[name] - a.values[name], 20 * math.log10(2), delta=0.02)

    def test_loudness_step_increases_dynamic_and_peak(self):
        steady = feature(tone(amplitude=0.05))
        step = tone(amplitude=0.05)
        step[len(step) // 2:] *= 4
        varied = feature(step)
        self.assertGreater(varied.values["rms_dynamic_db"], steady.values["rms_dynamic_db"] + 10)
        self.assertGreater(varied.values["rms_peak_dbfs"], steady.values["rms_peak_dbfs"] + 10)

    def test_spectral_directions_with_colored_noise(self):
        rng = np.random.default_rng(312)
        white = rng.normal(0, 0.04, 3 * p.SR)
        low = signal.sosfilt(signal.butter(4, 600, fs=p.SR, output="sos"), white)
        flat, tilted = feature(white), feature(low)
        self.assertGreater(flat.values["spectral_tilt_db_oct"], tilted.values["spectral_tilt_db_oct"] + 10)
        self.assertGreater(flat.values["alpha_ratio_db"], tilted.values["alpha_ratio_db"] + 10)
        self.assertGreater(flat.values["spectral_centroid_hz"], tilted.values["spectral_centroid_hz"] + 1500)
        self.assertLess(flat.values["voiced_fraction"], 0.1)
        self.assertFalse(flat.eligible)
        self.assertIsNone(flat.values["f0_median_hz"])

    def test_faster_audio_and_word_durations(self):
        slow_audio = tone(duration=4)
        # Compress the audio in time without running a speech model.
        fast_audio = signal.resample(slow_audio, len(slow_audio) // 2)
        slow_words = tuple(p.Word(i * 0.5, i * 0.5 + 0.3) for i in range(8))
        fast_words = tuple(p.Word(w.start / 2, w.end / 2) for w in slow_words)
        slow, fast = feature(slow_audio, words=slow_words), feature(fast_audio, words=fast_words)
        self.assertEqual(fast.values["duration_s"], slow.values["duration_s"] / 2)
        self.assertEqual(fast.values["rate_per_s"], 2 * slow.values["rate_per_s"])
        self.assertAlmostEqual(fast.values["word_duration_mean_s"], slow.values["word_duration_mean_s"] / 2)
        self.assertEqual(fast.pause_source, "word_gaps")

    def test_acoustic_internal_and_preceding_pause(self):
        y = np.r_[tone(duration=1), np.zeros(p.SR // 2), tone(duration=1)]
        a = feature(y)
        self.assertAlmostEqual(a.values["pause_inside_s"], 0.5, delta=0.01)
        self.assertAlmostEqual(a.values["pause_inside_max_s"], 0.5, delta=0.01)
        self.assertAlmostEqual(a.values["pause_fraction"], 0.2, delta=0.01)
        self.assertLess(a.values["active_fraction"], 0.9)
        self.assertGreater(feature(tone()).values["active_fraction"], a.values["active_fraction"])
        prior = np.r_[tone(duration=1), np.zeros(p.SR // 4)]
        before = feature(np.r_[np.zeros(p.SR // 4), tone(duration=1)], preceding=prior)
        self.assertAlmostEqual(before.values["pause_before_s"], 0.5, delta=0.01)

    def test_absolute_word_gaps_override_acoustic_proxy(self):
        words = (p.Word(10, 10.3), p.Word(10.8, 11.1), p.Word(11.2, 11.6))
        row = feature(tone(), count=3, words=words, start=10)
        self.assertAlmostEqual(row.values["pause_inside_s"], 0.5)
        self.assertAlmostEqual(row.values["pause_inside_max_s"], 0.5)
        self.assertIsNotNone(row.values["word_duration_mean_s"])

    def test_silence_empty_and_extremely_short_are_safe(self):
        for y in [np.zeros(2 * p.SR), np.zeros(1), np.array([]), np.array([0.1]), tone(duration=0.399)]:
            row = feature(y)
            self.assertFalse(row.eligible)
            self.assertIsNone(row.values["f0_median_hz"])
            self.assertIsNone(row.values["loudness_lufs"])
            for value in row.values.values():
                self.assertTrue(value is None or math.isfinite(value))
        silence = feature(np.zeros(p.SR))
        self.assertEqual(silence.values["pause_fraction"], 1)

    def test_400ms_boundary_and_nonfinite_rejection(self):
        row = feature(tone(duration=0.4))
        self.assertTrue(row.eligible)
        self.assertIsNotNone(row.values["loudness_lufs"])
        for bad in [np.array([np.nan]), np.array([np.inf]), np.zeros((100, 2))]:
            with self.assertRaises(ValueError):
                feature(bad)


class Normalization(unittest.TestCase):
    @staticmethod
    def row(index, hz=200, level=-20, rate=3, speaker="A", eligible=True, unit="words"):
        values = {name: 0.0 for name in p.FEATURES}
        values.update(duration_s=2, f0_median_hz=hz, f0_range_st=2,
                      rms_mean_dbfs=level, loudness_lufs=level,
                      rate_per_s=rate, voiced_fraction=0.9, active_fraction=1)
        return p.FeatureRow(p.Segment(index, index * 2, index * 2 + 2, speaker, rate_unit=unit),
                            values, eligible, "ok", "acoustic_threshold")

    def test_mad_outlier_resistance_and_bounded_zero_mad(self):
        rows = [self.row(i, hz=200 + i % 3, rate=3 + 0.1 * (i % 3)) for i in range(21)]
        clean = p.normalize(rows)
        outlier = self.row(21, hz=10000, level=0, rate=10000)
        contaminated = p.normalize(rows + [outlier])
        self.assertAlmostEqual(clean["A"]["rate_per_s:words"]["median"], contaminated["A"]["rate_per_s:words"]["median"])
        self.assertLessEqual(outlier.pace, p.Z_LIMIT)
        self.assertLessEqual(outlier.emphasis, p.Z_LIMIT)
        constant = [self.row(i) for i in range(9)] + [self.row(9, hz=400, rate=6)]
        p.normalize(constant)
        self.assertEqual(constant[0].pace, 0)
        self.assertGreater(constant[-1].pace, 0)
        self.assertGreater(constant[-1].emphasis, 0)

    def test_pitch_relative_semitones_and_independent_speakers(self):
        rows = [self.row(i, hz=100, speaker="A") for i in range(5)]
        rows += [self.row(i + 5, hz=300, speaker="B") for i in range(5)]
        baselines = p.normalize(rows)
        self.assertAlmostEqual(baselines["B"]["f0_median_hz"]["median"] - baselines["A"]["f0_median_hz"]["median"], 12 * math.log2(3))
        self.assertTrue(all(r.emphasis == 0 for r in rows))

    def test_silence_does_not_pollute_baseline(self):
        rows = [self.row(i) for i in range(5)] + [self.row(5, hz=5000, level=0, rate=100, eligible=False)]
        baseline = p.normalize(rows)
        self.assertEqual(baseline["A"]["rate_per_s:words"]["n"], 5)
        self.assertEqual(baseline["A"]["rate_per_s:words"]["median"], 3)
        self.assertIsNone(rows[-1].emphasis)
        self.assertIsNone(rows[-1].pace)

    def test_insufficient_baseline_and_missing_rate(self):
        rows = [self.row(i) for i in range(4)]
        p.normalize(rows)
        self.assertTrue(all(r.emphasis is None and r.pace is None for r in rows))
        rows.append(self.row(4))
        for row in rows:
            row.values["rate_per_s"] = None
        p.normalize(rows)
        self.assertTrue(all(r.emphasis == 0 and r.pace is None for r in rows))
        self.assertTrue(all(r.score_status == "partial_features" for r in rows))

    def test_words_and_characters_use_different_rate_baselines(self):
        rows = [self.row(i, rate=3) for i in range(5)]
        rows += [self.row(i + 5, rate=9, unit="characters") for i in range(5)]
        p.normalize(rows)
        self.assertTrue(all(r.pace == 0 for r in rows))

    def test_pace_sign_and_slowing_emphasis(self):
        rows = [self.row(i) for i in range(7)]
        rows += [self.row(7, rate=4), self.row(8, rate=2)]
        p.normalize(rows)
        self.assertGreater(rows[-2].pace, 0)
        self.assertLess(rows[-1].pace, 0)
        self.assertGreater(rows[-1].emphasis, rows[-2].emphasis)


class InputsAndCLI(unittest.TestCase):
    def test_input_adapters_and_missing_is_not_zero(self):
        rows = p.parse_segments({"segments": [
            {"startTime": 0, "endTime": 2, "english": "don't re-enter 42"},
            {"start_s": 2, "end_s": 4, "pk_word_count": 8, "parakeet_accepted": False},
            {"start": 4, "end": 6, "text": "请记住这点"},
            {"start": 6, "end": 8},
            {"start": 8, "end": 10, "words": [{"start": 8.1, "end": 8.3}, {"start": 9, "end": 9.3}]},
        ]})
        self.assertEqual(rows[0].count, 3)
        self.assertIsNone(rows[1].count)
        self.assertEqual(rows[2].count, 5)
        self.assertEqual(rows[2].rate_unit, "characters")
        self.assertIsNone(rows[3].count)
        self.assertEqual(rows[4].count, 2)
        self.assertEqual(rows[4].count_source, "word_timestamps")

    def test_malformed_inputs_rejected(self):
        for data in [[], [{"start": 0, "end": float("nan")}],
                     [{"start": -1, "end": 2}], [{"start": 2, "end": 1}],
                     [{"start": 0, "end": 2, "word_count": -1}],
                     [{"start": 0, "end": 2, "word_count": True}],
                     [{"start": 0, "end": 2, "words": [{"start": 0, "end": 3}]}],
                     [{"start": 0, "end": 2}, {"start": 1, "end": 3}],
                     [{"start": 0, "end": 1, "index": 1}, {"start": 1, "end": 2, "index": 1}]]:
            with self.assertRaises(ValueError):
                p.parse_segments(data)

    def test_cli_numeric_exports_and_no_overwrite(self):
        # Preserve temporary evidence when the task asks for recoverable deletion.
        root_setting = os.environ.get("PROSODY_TEST_OUTPUT_ROOT")
        root = Path(tempfile.mkdtemp(prefix="prosody-test-", dir=root_setting))
        samples = np.concatenate([tone(hz=150 + i * 5, amplitude=0.05 + i * 0.003) for i in range(12)])
        audio = root / "public-synthetic.wav"
        sf.write(audio, samples, p.SR, subtype="FLOAT")
        inp = root / "segments.json"
        inp.write_text(json.dumps([{"start": i * 2, "end": i * 2 + 2,
                                    "word_count": 3 + i, "text": "TRANSCRIPT_SENTINEL"} for i in range(12)]))
        out = root / "result"
        result = p.analyze(audio, inp, out)
        self.assertEqual(result["scored_count"], 12)
        self.assertGreater(result["cpu_s_per_audio_hour"], 0)
        for file in out.iterdir():
            self.assertNotIn("TRANSCRIPT_SENTINEL", file.read_text())
            self.assertNotIn(str(root), file.read_text())
        with (out / "highest-10.csv").open() as handle:
            top = list(csv.DictReader(handle))
        self.assertEqual(len(top), 10)
        self.assertEqual(set(top[0]), {"start_s", "end_s", "emphasis_score", "pace_deviation_score"})
        self.assertGreaterEqual(float(top[0]["emphasis_score"]), float(top[-1]["emphasis_score"]))
        digest = p.sha256(out / "vectors.csv")
        with self.assertRaises(FileExistsError):
            p.analyze(audio, inp, out)
        self.assertEqual(digest, p.sha256(out / "vectors.csv"))
        # Exercise argument parsing in the actual interpreter without invoking ASR.
        proc = subprocess.run([sys.executable, "-B", str(Path(p.__file__)), "--audio", str(audio),
                               "--segments", str(inp), "--output", str(root / "cli-result")],
                              text=True, capture_output=True, env=os.environ.copy())
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(proc.stdout)["scored_count"], 12)

    def test_wrong_audio_format_and_out_of_bounds_rejected(self):
        root = Path(tempfile.mkdtemp(prefix="prosody-format-", dir=os.environ.get("PROSODY_TEST_OUTPUT_ROOT")))
        inp = root / "segments.json"
        inp.write_text('[{"start":0,"end":2}]')
        for name, rate, audio in [("wrong-rate", 8000, tone()), ("stereo", 16000, np.zeros((16000, 2))),
                                  ("too-short-file", 16000, tone(duration=1))]:
            path = root / (name + ".wav")
            sf.write(path, audio, rate)
            with self.assertRaises(ValueError):
                p.analyze(path, inp, root / name)
            self.assertFalse((root / name).exists())


if __name__ == "__main__":
    unittest.main()
