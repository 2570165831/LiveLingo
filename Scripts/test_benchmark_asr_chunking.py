"""Dependency-free checks for the offline ASR comparison's audio boundaries."""
import importlib.util
from contextlib import redirect_stderr, redirect_stdout
import io
import json
from pathlib import Path
from types import SimpleNamespace
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch
import wave

spec = importlib.util.spec_from_file_location(
    'benchmark_asr_chunking', Path(__file__).with_name('benchmark-asr-chunking.py'))
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)


class ChunkingTests(unittest.TestCase):
    def test_complete_coverage_and_clipped_margins(self):
        windows = benchmark.frame_windows(19 * 16000, 16000, 0, 600, 8, .5)
        self.assertEqual(windows, [(0, 128000, 0, 136000),
                                  (128000, 256000, 120000, 264000),
                                  (256000, 304000, 248000, 304000)])

    def test_excerpt_never_reads_outside_selected_range(self):
        self.assertEqual(benchmark.frame_windows(30 * 16000, 16000, 5, 10, 8, .5),
                         [(80000, 208000, 80000, 216000),
                          (208000, 240000, 200000, 240000)])

    def test_subsample_and_empty_ranges_are_rejected(self):
        for start, duration, margin in ((1, 1, .5), (0, .000001, .5), (0, 1, .000001)):
            with self.subTest(start=start, duration=duration, margin=margin):
                with self.assertRaises(ValueError):
                    benchmark.frame_windows(16000, 16000, start, duration, 8, margin)

    def test_invalid_times_are_rejected(self):
        for values in ((-1, 10, 8, .5), (0, 0, 8, .5), (0, 10, .5, .1),
                       (0, 10, 31, .5), (0, 10, 8, 0), (0, 10, 8, 2.1),
                       (0, 10, 1, .6), (float('nan'), 10, 8, .5),
                       (0, float('inf'), 8, .5)):
            with self.subTest(values=values):
                with self.assertRaises(ValueError):
                    benchmark.frame_windows(160000, 16000, *values)

    def test_prefix_does_not_skip_late_token(self):
        prior = [SimpleNamespace(id=1, end=7), SimpleNamespace(id=2, end=9),
                 SimpleNamespace(id=3, end=7.5)]
        merged = [SimpleNamespace(id=1), SimpleNamespace(id=4)]
        checks = benchmark.prefix_checks(prior, merged, 8, .5)
        self.assertEqual(checks[0]['prior_tokens'], 1)
        self.assertTrue(all(check['prefix_preserved'] for check in checks))

    def test_prefix_rewrite_and_shorter_output_are_detected(self):
        prior = [SimpleNamespace(id=1, end=6), SimpleNamespace(id=2, end=7)]
        for merged in ([SimpleNamespace(id=9), SimpleNamespace(id=2)],
                       [SimpleNamespace(id=1)]):
            with self.subTest(merged=merged):
                checks = benchmark.prefix_checks(prior, merged, 8, .5)
                self.assertFalse(checks[0]['prefix_preserved'])

    def test_empty_prefix_is_stable(self):
        self.assertTrue(all(check['prefix_preserved'] for check in
                            benchmark.prefix_checks([], [], 0, .5)))

    @staticmethod
    def audio(channels=1, width=2, rate=16000, frames=100):
        stream = io.BytesIO()
        with wave.open(stream, 'wb') as writer:
            writer.setnchannels(channels)
            writer.setsampwidth(width)
            writer.setframerate(rate)
            writer.writeframes(bytes(channels * width * frames))
        stream.seek(0)
        return stream

    def test_actual_frame_count(self):
        self.assertEqual(benchmark.audio_info(self.audio(frames=123)), (123, 16000))

    def test_invalid_audio_format_and_empty_audio(self):
        for options in ({'channels':2}, {'width':1}, {'rate':48000}, {'frames':0}):
            with self.subTest(options=options):
                with self.assertRaises(ValueError):
                    benchmark.audio_info(self.audio(**options))

    def test_reports_require_content_switch_and_failures_omit_diagnostics(self):
        canary = "PRIVATE_SYNTHETIC_BENCHMARK_CONTENT"
        with tempfile.TemporaryDirectory(prefix="chunking-privacy-") as scratch:
            root = Path(scratch)
            audio = root / (canary + ".wav")
            audio.write_bytes(self.audio(frames=32000).read())
            model = root / "synthetic-model"
            model.mkdir()
            (model / "config.json").write_text("{}")
            class FakeParakeet:
                __module__ = 'mlx_audio.stt.models.parakeet.synthetic'
                def generate(self, *args, **kwargs):
                    token = SimpleNamespace(id=1, text=canary, start=0., end=.1, duration=.1)
                    return SimpleNamespace(text=canary, sentences=[SimpleNamespace(tokens=[token])])
            mx = MagicMock()
            stt = MagicMock()
            stt.load_model.return_value = FakeParakeet()
            alignment = MagicMock()
            alignment.__file__ = str(model / "config.json")
            parakeet = MagicMock()
            parakeet.alignment = alignment
            modules = {'numpy': MagicMock(), 'mlx': MagicMock(core=mx), 'mlx.core': mx,
                       'mlx_audio': MagicMock(), 'mlx_audio.stt': MagicMock(),
                       'mlx_audio.stt.utils': stt, 'mlx_audio.stt.models': MagicMock(),
                       'mlx_audio.stt.models.parakeet': parakeet,
                       'mlx_audio.stt.models.parakeet.alignment': alignment}
            for include_content in (False, True):
                output = root / ("content.json" if include_content else "summary.json")
                arguments = ['benchmark', '--audio', str(audio), '--model', str(model), '--output', str(output)]
                if include_content:
                    arguments.append('--include-content')
                stdout = io.StringIO()
                with patch.dict(sys.modules, modules), patch.object(sys, 'argv', arguments), \
                        patch.object(benchmark.importlib.metadata, 'version', return_value='synthetic'), \
                        redirect_stdout(stdout):
                    self.assertEqual(benchmark.main(), 0)
                report = json.loads(output.read_text())
                self.assertEqual(canary in output.read_text(), include_content)
                self.assertEqual('text' in report, include_content)
                self.assertEqual('raw' in report['chunks'][0]['exact'], include_content)
                self.assertNotIn(canary, stdout.getvalue())
                self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            output = root / "failure.json"
            arguments = ['benchmark', '--audio', str(audio), '--model', str(model), '--output', str(output)]
            stdout, stderr = io.StringIO(), io.StringIO()
            with patch.object(sys, 'argv', arguments), patch.object(benchmark, 'run', side_effect=RuntimeError(canary)), \
                    redirect_stdout(stdout), redirect_stderr(stderr):
                self.assertEqual(benchmark.main(), 1)
            self.assertNotIn(canary, output.read_text() + stdout.getvalue() + stderr.getvalue())
            self.assertEqual(json.loads(output.read_text())['error'], {'code': 'benchmark_failed'})


if __name__ == '__main__':
    unittest.main()
