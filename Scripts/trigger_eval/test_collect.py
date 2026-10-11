"""CPU-only checks of safety gates, resumability and posterior aggregation."""
import contextlib
import json
import importlib.util
import os
import io
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

try:
    from . import collect
except ImportError:
    import collect


class CollectorTests(unittest.TestCase):
    def test_text_stats_rejects_payload_values_before_persistence(self):
        valid = {"pk_word_count": 2, "pk_char_count": 8, "english_gate_accepted": True,
                 "parakeet_accepted": True, "quality_reason": None, "nl_language": "en",
                 "nl_probability": .99, "nl_english_probability": .99}
        for replacement in (None, {"quality_reason": "synthetic-private-payload"},
                            {"pk_char_count": True}, {"nl_language": "synthetic-private-payload"},
                            {"nl_probability": "synthetic-private-payload"}):
            row = valid.copy()
            if replacement is None:
                row.pop("pk_word_count")
            else:
                row.update(replacement)
            helper = collect.TextStats.__new__(collect.TextStats)
            helper.process = SimpleNamespace(stdin=io.StringIO(), stdout=io.StringIO(json.dumps(row) + "\n"))
            with self.assertRaises(ValueError) as error:
                helper.evaluate("public synthetic text", 8)
            self.assertNotIn("synthetic-private-payload", str(error.exception))

    def test_only_incomplete_last_jsonl_record_can_be_recovered(self):
        with tempfile.TemporaryDirectory() as name:
            path = Path(name) / "stats.jsonl"
            path.write_bytes(b'{"index":0}\n{"index":')
            with contextlib.redirect_stdout(None):
                self.assertEqual(collect.read_rows(path, recover_tail=True), [{"index": 0}])
            self.assertEqual(path.read_bytes(), b'{"index": 0}\n')
            path.write_bytes(b'{"index":0}\ninvalid\n')
            with self.assertRaises(ValueError):
                collect.read_rows(path, recover_tail=True)

    def test_valid_record_without_newline_is_normalized_before_append(self):
        with tempfile.TemporaryDirectory() as name:
            path = Path(name) / "stats.jsonl"
            path.write_bytes(b'{"index":0}')
            collect.read_rows(path, recover_tail=True)
            with path.open("a") as stream:
                stream.write('{"index":1}\n')
            self.assertEqual(len(collect.read_rows(path)), 2)
    def test_waiter_argv_does_not_look_like_an_asr_service(self):
        guard_path = os.environ.get("TRIGGER_EVAL_GUARD_SCRIPT")
        if guard_path is None:
            self.skipTest("Pinned process guard path not provided")
        # Exercise the real pinned guard rather than copying its grammar.
        guard = collect.load_script(guard_path, "trigger_guard_regression")
        row = {"executable": "/synthetic/python3",
               "command": "python3 -B collect.py --service-directory Scripts"}
        self.assertFalse(guard.standalone_asr(row))
        row["command"] = "python3 -B collect.py --service-script Scripts/qwen_asr_service.py"
        self.assertTrue(guard.standalone_asr(row))

    @unittest.skipUnless(importlib.util.find_spec("numpy"), "CPU arrays unavailable")
    def test_nonblank_posterior_excludes_blank_and_duration_logits(self):
        import numpy as np
        fake_mx = SimpleNamespace(float32=np.float32, argmax=np.argmax,
                                 logsumexp=lambda x: np.logaddexp.reduce(x))
        outputs = iter([np.array([[[[0., 0., 2., 100., 100.]]]]),
                        np.array([[[[2., 1., 0., 100., 100.]]]])])
        recorder = collect.JointRecorder(lambda: next(outputs), 2, fake_mx)
        blank = recorder()
        nonblank = recorder()
        self.assertEqual(blank.shape, nonblank.shape)
        self.assertEqual(len(recorder.log_probabilities), 1)
        self.assertAlmostEqual(recorder.statistics(1)["pk_mean_probability"],
                               float(np.exp(2) / (np.exp(2) + np.exp(1) + 1)), places=6)

    @unittest.skipUnless(importlib.util.find_spec("soundfile") and importlib.util.find_spec("numpy"),
                         "CPU audio libraries unavailable")
    def test_identical_unaligned_interpretation_is_not_asserted_english(self):
        import numpy as np
        import soundfile as sf
        with tempfile.TemporaryDirectory() as name:
            path = Path(name) / "synthetic.wav"
            sf.write(path, np.full(16000, .1), 16000, subtype="PCM_16")
            track = {"audio": str(path)}
            rows = [{"start_s": 0., "end_s": 1., "reference_language": "en", "reference_trusted": True}]
            collect.correlate_tracks(track, rows, track, [], sf, np)
            self.assertIsNone(rows[0]["reference_language"])
            self.assertFalse(rows[0]["reference_trusted"])
            self.assertEqual(rows[0]["reference_kind"], "unresolved_waveform_passthrough")

    def test_scheduled_second_route_model_blocks_early_start(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            self.assertFalse(collect.route_finished(root))
            (root / "execution-result.json").write_text('{"status":"9b_completed"}')
            (root / "optional-4b-decision.json").write_text('{"started":true}')
            self.assertFalse(collect.route_finished(root))
            (root / "4b-execution-result.json").write_text('{"status":"4b_completed"}')
            self.assertTrue(collect.route_finished(root))

    def test_explicitly_skipped_second_model_can_finish(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            (root / "execution-result.json").write_text('{"status":"failed"}')
            (root / "optional-4b-decision.json").write_text('{"started":false}')
            self.assertTrue(collect.route_finished(root))

    def test_wrong_resume_window_is_rejected(self):
        track = {"dataset": "public", "track": "english", "split": "dev",
                 "windows": [{"index": 0, "start_s": 0, "end_s": 8}]}
        valid = {**track["windows"][0], "dataset": "public", "track": "english", "split": "dev"}
        collect.verify_prefix([], track)
        collect.verify_prefix([valid], track)
        with self.assertRaises(ValueError):
            collect.verify_prefix([{**valid, "end_s": 7}], track)
        with self.assertRaises(ValueError):
            collect.verify_prefix([valid] * 2, track)
        with self.assertRaises(ValueError):
            collect.verify_prefix([{**valid, "split": "new"}], track)

    def test_posterior_aggregates_and_count_check(self):
        recorder = collect.JointRecorder(None, 3, None)
        recorder.log_probabilities = [0., -0.6931471805599453]
        stats = recorder.statistics(2)
        self.assertAlmostEqual(stats["pk_mean_probability"], .75)
        self.assertAlmostEqual(stats["pk_min_probability"], .5)
        with self.assertRaises(ValueError):
            recorder.statistics(3)

    def test_guard_failure_inside_acquired_session_is_not_retried(self):
        class Rejected(Exception):
            reason = "another_livelingo_run_active"
        entries = []
        @contextlib.contextmanager
        def session():
            entries.append(1)
            yield
        guard = SimpleNamespace(session_lock=session, Rejected=Rejected,
                               preflight_processes=lambda **kw: [])
        args = SimpleNamespace(wait_for_route_directory=None, allow_idle_installed_asr_service=False)
        with contextlib.redirect_stdout(None):
            with self.assertRaises(Rejected):
                with collect.acquire_gpu(guard, args):
                    raise Rejected()
        self.assertEqual(len(entries), 1)

    def test_csv_roundtrip_keeps_failed_row(self):
        with tempfile.TemporaryDirectory() as name:
            path = Path(name) / "stats.csv"
            collect.export_csv(path, [{"index": 0, "probe_error": True},
                                      {"index": 1, "probe_error": False}])
            self.assertEqual(len(path.read_text().splitlines()), 3)
            self.assertFalse(path.with_name(path.name + ".writing").exists())


if __name__ == "__main__":
    unittest.main()
