"""Synthetic routes and protocol-v2 subprocesses only; never import MLX/weights."""
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from . import corpora as c, run_strategies as a


FAKE_PROTOCOL = r'''
import argparse, json, os, pathlib, sys
p = argparse.ArgumentParser()
p.add_argument('--model'); p.add_argument('--state-directory')
args = p.parse_args()
state = pathlib.Path(args.state_directory); state.mkdir(exist_ok=True)
mode = os.environ.get('STRATEGY_SYNTHETIC_MODE', '')
def send(event, **fields):
    print(json.dumps(dict(event=event, **fields)), flush=True)
send('ready', version=1 if mode == 'bad-ready' else 2)
send('memory', activeBytes=0)
for line in sys.stdin:
    row = json.loads(line)
    with (state/'requests.jsonl').open('a') as f:
        f.write(json.dumps(row)+'\n')
    op, identity = row['op'], row['id']
    if op == 'generate':
        if mode == 'timeout': continue
        if mode == 'budget':
            send('error', id=identity, code='output_budget_exhausted', message='PRIVATE diagnostic')
            continue
        send('loading', id=identity)
        send('snapshot', id=identity, wire='')
        send('snapshot', id=identity, wire='synthetic')
        fields = dict(id='wrong' if mode == 'wrong-id' else identity, text='synthetic translation', wire='synthetic translation')
        if mode != 'missing-stats': fields.update(finalTokens=7, thinkingTokens=0)
        if mode == 'bad-stats': fields['finalTokens'] = True
        send('done', **fields)
        print('PRIVATE worker diagnostic', file=sys.stderr, flush=True)
    elif op in ('ack', 'cancel'):
        send(op, id=identity, controlID=row['controlID'], state='released')
    elif op == 'shutdown':
        send(op, id=identity, controlID=row['controlID'], state='ready_to_exit')
        break
'''


class RecordingWorker(a.FakeWorker):
    def __init__(self):
        self.calls = []

    def generate(self, system, text, source, target):
        self.calls.append((system, text, source, target))
        result = super().generate(system, text, source, target)
        result.update(output_tokens=7, final_tokens=7, thinking_tokens=0)
        return result


class SyntheticSampler:
    def __init__(self, **kwargs):
        self.metadata, self.errors, self.stopped = {"source": "synthetic_ioreport"}, [], False

    def start(self):
        self.start_mono = time.monotonic()

    def stop(self):
        self.end_mono, self.stopped = time.monotonic(), True

    def snapshot(self):
        assert self.stopped, "must include the final energy interval"
        duration = self.end_mono - self.start_mono
        return [{"start_mono": self.start_mono, "end_mono": self.end_mono, "is_delta": True,
                 "source": "synthetic_ioreport", "mode": "energy_counters", "energy_unit": "J",
                 "rails_j": {"cpu": duration * 2, "gpu": duration, "ane": 0}}]


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="strategy-synthetic-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name).resolve()
        self.enterContext(patch.dict(os.environ, {c.OUTPUT_ROOT_ENV: str(self.root)}))
        # Exercise the original scoreboard lock/path checker in an authorized
        # synthetic root, without contending with another task's real lock.
        self.enterContext(patch.object(a.scoreboard, "WORK", self.root))
        self.enterContext(patch.object(a.scoreboard, "DEFAULT", self.root / "shared-scoreboard-lock"))
        self.prompts = self.root / "prompts"
        self.export_prompts()
        self.corpus = self.root / "corpus.jsonl"
        self.units = [c.ParallelUnit(f"synthetic:{i}", "synthetic", {
            "zh": f"温度升高 {i}。", "en": f"Temperature rises {i}.", "es": f"La temperatura sube {i}.",
            "fr": f"La température augmente {i}.", "zh-Hant-TW": f"溫度升高 {i}。", "zh-Hant-HK": f"溫度升高 {i}。"},
            {"alignment": "synthetic-line-index", "terms": {"es": ["temperatura"]}}) for i in (1, 2)]
        c.write_jsonl(self.units, self.corpus)
        self.recording = RecordingWorker()

    def export_prompts(self, targets=a.TARGETS):
        self.prompts.mkdir(exist_ok=True)
        entries = []
        for target in targets:
            for profile in ("4b", "9b"):
                # Deliberately retain accents, leading whitespace and trailing
                # newline, so a .strip()/target-rewrite regression fails.
                data = f"  Synthetic {target}/{profile} prompt é\n".encode()
                file = f"{target}-caption-{profile}.utf8"
                (self.prompts / file).write_bytes(data)
                entries.append({"targetLocale": target, "name": f"caption-{profile}", "file": file,
                                "byteCount": len(data), "sha256": a.digest(data)})
        manifest = {"schemaVersion": 1, "encoding": "UTF-8", "addedTrailingNewline": False,
                    "targetsWithPrompts": list(targets), "targetsWithoutPrompts": [], "prompts": entries}
        (self.prompts / "manifest.json").write_text(json.dumps(manifest))

    def args(self, *extra):
        return a.parser().parse_args(["--prompts-dir", str(self.prompts), "--corpus", "jsonl", "--input", str(self.corpus),
                                     "--targets", "es", "--routes", "direct", "via-en", "--sources", "zh",
                                     "--output-dir", str(self.root / "result"), "--dry-run", "--bootstrap-iterations", "12", *extra])

    def run_fake(self, args=None, **kwargs):
        return a.run(args or self.args(), process_provider=lambda: {}, worker_factory=lambda: self.recording, **kwargs)

    def transport(self, *, mode="", timeout=3):
        script = self.root / "fake-worker.py"
        script.write_text(FAKE_PROTOCOL)
        self.enterContext(patch.dict(os.environ, {"STRATEGY_SYNTHETIC_MODE": mode}))
        return a.MLXWorker(sys.executable, script, self.root / "unused-model", self.root / "state", "9b", timeout, 160)

    def real_args_with_fake_protocol(self, *extra):
        script = self.root / "fake-worker.py"
        script.write_text(FAKE_PROTOCOL)
        model = self.root / "models" / a.MODELS["9b"]
        model.mkdir(parents=True)
        for name in ("config.json", "tokenizer.json"):
            (model / name).write_text("{}")
        args = self.args("--python", sys.executable, "--worker", str(script), "--models-root", str(self.root / "models"), *extra)
        args.dry_run = False
        self.enterContext(patch.object(a, "guard_other_workers"))
        return args

    def test_direct_once_and_pivot_twice_on_identical_units(self):
        report = self.run_fake()
        direct, pivot = report["routes"]
        self.assertEqual([direct["summary"]["call_count"], pivot["summary"]["call_count"]], [2, 4])
        self.assertEqual([len(r["calls"]) for r in direct["results"]], [1, 1])
        self.assertEqual([len(r["calls"]) for r in pivot["results"]], [2, 2])
        # All three calls for a unit precede the next unit; pivot consumes the
        # generated English, never the parallel English human reference.
        self.assertEqual([call[3] for call in self.recording.calls], ["es", "en", "es", "es", "en", "es"])
        first, second = pivot["results"][0]["calls"]
        self.assertEqual(second["input"], first["output"])
        self.assertNotEqual(second["input"], self.units[0].texts["en"])
        self.assertEqual(second["source_locale"], "en")
        self.assertEqual(direct["summary"]["chrfpp"], a.m.corpus_chrfpp(
            [r["hypothesis"] for r in direct["results"]], [r["reference"] for r in direct["results"]]))
        self.assertEqual(report["comparisons"][0]["sample_count"], 2)
        self.assertFalse(report["route_switch_gate"]["established"])

    def test_report_keys_null_statistics_and_round_trip(self):
        report = self.run_fake()
        stored = json.loads((self.root / "result/report.json").read_text())
        self.assertEqual(stored, report)
        self.assertIn("DRY RUN", (self.root / "result/summary.md").read_text())
        for route in report["routes"]:
            self.assertIsNone(route["summary"]["input_tokens"])
            self.assertIsNone(route["summary"]["reused_prefix_tokens"])
            for row in route["results"]:
                self.assertEqual(set(("chrfpp", "purity", "terminology")) - row["quality"].keys(), set())
                for call in row["calls"]:
                    self.assertFalse({"input_tokens", "output_tokens", "first_token_seconds", "total_seconds",
                                      "reused_prefix_tokens", "energy", "prompt_sha256"} - call.keys())
                    self.assertIsNone(call["input_tokens"])
                    self.assertIsNone(call["reused_prefix_tokens"])
                    self.assertIsNone(call["exact_first_token_seconds"])
                    self.assertIsNone(call["energy"]["gross_j"])
        self.assertNotIn(str(self.root), json.dumps(report))

    def test_dry_run_never_starts_process_sampler_or_reads_models(self):
        with patch.object(a.subprocess, "Popen", side_effect=AssertionError("unexpected process")), \
                patch.object(a.energy, "PowerSampler", side_effect=AssertionError("unexpected sampler")), \
                patch.object(a, "MLXWorker", side_effect=AssertionError("unexpected MLX worker")):
            report = a.run(self.args("--models-root", "/nonexistent-synthetic-models"), process_provider=lambda: {})
        self.assertTrue(report["dry_run"])
        self.assertFalse(report["energy"]["enabled"])
        self.assertTrue(all(r["summary"]["output_tokens"] is None for r in report["routes"]))

    def test_prompt_bytes_are_preserved_for_both_profiles_and_hops(self):
        for profile in ("4b", "9b"):
            self.recording.calls.clear()
            self.run_fake(self.args("--profile", profile, "--output-dir", str(self.root / profile)))
            for system, _, _, target in self.recording.calls:
                raw = (self.prompts / f"{target}-caption-{profile}.utf8").read_bytes()
                self.assertEqual(system.encode(), raw)

    def test_missing_future_prompts_refused_before_output_or_worker(self):
        self.export_prompts(targets=("zh-Hans",))  # actual step-19 availability
        with self.assertRaisesRegex(ValueError, "missing exported prompt"), patch.object(a, "FakeWorker") as worker:
            a.run(self.args(), process_provider=lambda: {})
        worker.assert_not_called()
        self.assertFalse((self.root / "result").exists())

    def test_export_manifest_mismatch_traversal_duplicate_and_invalid_utf8(self):
        for kind in ("sha", "count", "traversal", "duplicate", "encoding", "not-object", "utf8"):
            with self.subTest(kind=kind):
                self.export_prompts()
                path = self.prompts / "manifest.json"
                manifest = json.loads(path.read_text())
                entry = manifest["prompts"][0]
                if kind == "sha": entry["sha256"] = "0" * 64
                if kind == "count": entry["byteCount"] = True
                if kind == "traversal": entry["file"] = "../prompt.utf8"
                if kind == "duplicate": manifest["prompts"].append(entry)
                if kind == "encoding": manifest["encoding"] = "latin-1"
                if kind == "not-object": manifest = []
                if kind == "utf8":
                    data = b"\xff"
                    (self.prompts / entry["file"]).write_bytes(data)
                    entry.update(byteCount=1, sha256=a.digest(data))
                path.write_text(json.dumps(manifest))
                with self.assertRaises(ValueError):
                    a.PromptBundle(self.prompts)

    def test_shared_scoreboard_lock_blocks_and_is_reusable(self):
        with a.scoreboard.session_lock(a.scoreboard.DEFAULT):
            with self.assertRaises(a.scoreboard.Rejected) as error:
                self.run_fake()
        self.assertEqual(error.exception.reason, "scoreboard_busy")
        self.assertFalse((self.root / "result").exists())
        self.run_fake()
        self.assertTrue((a.scoreboard.DEFAULT / ".lock").is_file())

    def test_other_livelingo_guard_refuses_before_output(self):
        for exe in ("/synthetic/livelingo-cli", "/synthetic/LiveLingo.app/Contents/MacOS/LiveLingo"):
            with self.subTest(exe=exe), self.assertRaises(a.scoreboard.Rejected) as error:
                a.run(self.args(), process_provider=lambda: {41: {"pid": 41, "state": "S", "executable": exe}})
            self.assertEqual(error.exception.reason, "another_livelingo_run_active")
        self.assertFalse((self.root / "result").exists())

    def test_existing_directory_or_file_refused_without_touching_contents(self):
        existing = self.root / "existing"
        existing.mkdir()
        sentinel = existing / "keep.txt"
        sentinel.write_bytes(b"unique evidence")
        for path in (existing, sentinel):
            with self.subTest(path=path), self.assertRaises(FileExistsError):
                self.run_fake(self.args("--output-dir", str(path)))
        self.assertEqual(sentinel.read_bytes(), b"unique evidence")

    def test_output_symlink_outside_root_and_missing_environment_refused(self):
        link = self.root / "link"
        link.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.run_fake(self.args("--output-dir", str(link / "new")))
        with self.assertRaises(ValueError):
            self.run_fake(self.args("--output-dir", str(self.root.parent / "outside")))
        with patch.dict(os.environ, {c.OUTPUT_ROOT_ENV: ""}), self.assertRaisesRegex(ValueError, c.OUTPUT_ROOT_ENV):
            self.run_fake()

    def test_english_passthrough_has_zero_worker_calls_without_english_prompt(self):
        self.export_prompts(targets=("zh-Hans",))
        report = self.run_fake(self.args("--targets", "en", "--routes", "direct", "--sources", "en"))
        self.assertEqual(self.recording.calls, [])
        route = report["routes"][0]
        self.assertEqual(route["summary"]["call_count"], 0)
        self.assertEqual(route["summary"]["chrfpp"], 100)
        self.assertTrue(all(r["passthrough"] and r["hypothesis"] == r["source"] for r in route["results"]))

    def test_traditional_direct_and_hans_conversion_use_distinct_prompts(self):
        report = self.run_fake(self.args("--targets", "zh-Hant-TW", "zh-Hant-HK", "--routes", "direct", "hans-convert", "--sources", "en"))
        self.assertEqual([r["summary"]["call_count"] for r in report["routes"]], [2, 2, 2, 2])
        for route in report["routes"]:
            for row in route["results"]:
                target = "zh-Hans" if route["route"] == "hans-convert" else route["target_locale"]
                self.assertEqual(row["calls"][0]["target_locale"], target)
                self.assertIsNone(row["quality"]["purity"]["simplified_residue_count"])
                self.assertEqual("DRY-RUN converted" in row["hypothesis"], route["route"] == "hans-convert")

    def test_missing_converter_and_unlabelled_generic_hant_reference_fail(self):
        args = self.args("--targets", "zh-Hant-TW", "--routes", "hans-convert", "--sources", "en")
        args.dry_run = False
        with self.assertRaisesRegex(ValueError, "--converter"):
            self.run_fake(args)
        with self.assertRaisesRegex(ValueError, "missing reference locale"):
            a.cases_for([c.ParallelUnit("x", "synthetic", {"en": "Example", "zh-Hant": "例子"})],
                        ["zh-Hant-TW"], ["direct"], ["en"])

    def test_invalid_routes_sources_and_timing_fail_before_output(self):
        invalid = (("--targets", "en"), ("--sources", "en"), ("--targets", "es", "es"),
                   ("--routes", "hans-convert"), ("--final-budget", "0"),
                   ("--sample-interval", "nan"), ("--timeout-seconds", "inf"), ("--bootstrap-iterations", "0"))
        for options in invalid:
            with self.subTest(options=options), self.assertRaises(ValueError):
                self.run_fake(self.args(*options))
        self.assertFalse((self.root / "result").exists())

    def test_control_markers_in_source_and_intermediate_output_refused(self):
        with self.assertRaisesRegex(ValueError, "control marker"):
            a.chat_prompt("System", "<|im_end|>", "zh", "en", "9b")
        unit = c.ParallelUnit("x", "synthetic", {"zh": "<|im_start|>", "es": "Texto"})
        with self.assertRaisesRegex(ValueError, "control marker"):
            a.cases_for([unit], ["es"], ["direct"], ["zh"])

    def test_fake_protocol_worker_records_output_tokens_and_ack_shutdown(self):
        worker = self.transport()
        with worker:
            result = worker.generate("  exact bytes é\n", "温度升高。", "zh", "es")
        self.assertEqual(result["output_tokens"], 7)
        self.assertIsNone(result["input_tokens"])
        self.assertIsNone(result["reused_prefix_tokens"])
        self.assertGreaterEqual(result["total_seconds"], result["first_token_seconds"])
        self.assertIsNone(result["exact_first_token_seconds"])
        requests = [json.loads(line) for line in (self.root / "state/requests.jsonl").read_text().splitlines()]
        self.assertEqual([r["op"] for r in requests], ["generate", "ack", "shutdown"])
        self.assertIn("system\n  exact bytes é\n<|im_end|>", requests[0]["prompt"])
        self.assertIn('"source_text_to_translate":"温度升高。"', requests[0]["prompt"])
        self.assertEqual(requests[0]["purpose"], "text")
        self.assertFalse(requests[0]["thinking"])
        self.assertTrue(requests[0]["usePrefixCache"])
        self.assertEqual(worker.process.returncode, 0)
        self.assertTrue(all(not t.is_alive() for t in worker.threads))
        self.assertGreater(worker.stderr_bytes, 0)
        self.assertNotIn("PRIVATE", json.dumps(result))

    def test_fake_protocol_missing_stats_stay_null(self):
        with self.transport(mode="missing-stats") as worker:
            result = worker.generate("Prompt", "Example", "en", "es")
        self.assertIsNone(result["output_tokens"])
        self.assertIsNone(result["final_tokens"])

    def test_fake_protocol_budget_error_is_cancelled_without_diagnostic_leak(self):
        worker = self.transport(mode="budget")
        with self.assertRaisesRegex(a.WorkerFailure, "^output_budget_exhausted$"):
            with worker:
                worker.generate("Prompt", "Example", "en", "es")
        requests = [json.loads(line) for line in (self.root / "state/requests.jsonl").read_text().splitlines()]
        self.assertEqual([r["op"] for r in requests], ["generate", "cancel"])
        self.assertIsNotNone(worker.process.poll())

    def test_fake_protocol_bad_startup_id_and_stats_rejected_and_child_stopped(self):
        for mode in ("bad-ready", "wrong-id", "bad-stats"):
            with self.subTest(mode=mode):
                worker = self.transport(mode=mode)
                with self.assertRaises(a.WorkerFailure):
                    with worker:
                        worker.generate("Prompt", "Example", "en", "es")
                self.assertIsNotNone(worker.process.poll())

    def test_fake_protocol_timeout_stops_only_the_owned_child(self):
        worker = self.transport(mode="timeout", timeout=.25)
        with self.assertRaisesRegex(a.WorkerFailure, "worker_timeout"):
            with worker:
                worker.generate("Prompt", "Example", "en", "es")
        self.assertIsNotNone(worker.process.poll())

    def test_app_chatml_and_4b_quoted_input_do_not_rewrite_system_prompt(self):
        prompt = "Exact é\n"
        wire = a.chat_prompt(prompt, "温度升高。", "zh", "en", "4b")
        self.assertTrue(wire.startswith("<|im_start|>system\nExact é\n<|im_end|>"))
        self.assertIn("BEGIN QUOTED LECTURE CONTENT ---\n温度升高。", wire)
        self.assertTrue(wire.endswith("<think>\n\n</think>\n\n"))
        self.assertEqual(a.user_input("Example", "en", "es", "4b"), "Example")

    def test_non_dry_orchestration_uses_fake_protocol_only(self):
        report = a.run(self.real_args_with_fake_protocol("--no-energy"), process_provider=lambda: {})
        self.assertFalse(report["dry_run"])
        self.assertEqual([r["summary"]["output_tokens"] for r in report["routes"]], [14, 28])
        self.assertIsNone(report["routes"][0]["summary"]["input_tokens"])
        self.assertFalse(report["energy"]["enabled"])
        calls = [call for route in report["routes"] for row in route["results"] for call in row["calls"]]
        self.assertEqual(sum(call["worker_first_generation"] for call in calls), 1)
        for route in report["routes"]:
            self.assertEqual(route["summary"]["first_token_seconds"]["sample_count"], 2)
            for row in route["results"]:
                last = row["calls"][-1]
                self.assertAlmostEqual(row["first_token_seconds"],
                    last["start_mono"] - row["start_mono"] + last["first_token_seconds"])
                self.assertLessEqual(row["first_token_seconds"], row["total_seconds"])
                self.assertEqual(row["output_tokens"], 7 * len(row["calls"]))

    def test_energy_reuses_final_window_integration_without_comparability_claim(self):
        helper = self.root / "unused-synthetic-helper"
        helper.write_text("synthetic, never executed")
        helper.chmod(0o700)
        args = self.real_args_with_fake_protocol("--energy-helper", str(helper))
        report = a.run(args, process_provider=lambda: {}, sampler_factory=SyntheticSampler)
        self.assertTrue(report["energy"]["enabled"])
        for route in report["routes"]:
            for row in route["results"]:
                self.assertAlmostEqual(row["energy"]["gross_j"], row["total_seconds"] * 3)
                self.assertFalse(row["energy"]["comparable"])
                for call in row["calls"]:
                    self.assertAlmostEqual(call["energy"]["gross_j"], call["total_seconds"] * 3)
            self.assertFalse(route["summary"]["energy_comparable"])

    def test_real_run_requires_local_runtime_and_explicit_helper(self):
        args = self.args()
        args.dry_run = False
        with patch.dict(os.environ, {"LIVELINGO_MLX_PYTHON": "", "LIVELINGO_MLX_MODELS": ""}), \
                self.assertRaisesRegex(ValueError, "LIVELINGO_MLX_PYTHON"):
            a.run(args, process_provider=lambda: {})
        with self.assertRaisesRegex(ValueError, "--energy-helper"):
            a.run(self.real_args_with_fake_protocol(), process_provider=lambda: {})
        self.assertFalse((self.root / "result").exists())

    def test_standalone_worker_census_rejects_busy_and_excludes_owned_or_zombie(self):
        worker = Path("/synthetic/mlx_runtime/worker.py")
        command = f"42 S python {worker} --model local --state-directory local\n"
        with patch.object(a.subprocess, "check_output", return_value=command):
            with self.assertRaises(a.scoreboard.Rejected):
                a.guard_other_workers(worker)
            a.guard_other_workers(worker, owned_pid=42)
        with patch.object(a.subprocess, "check_output", return_value=command.replace("42 S", "42 Z")):
            a.guard_other_workers(worker)

    def test_prompt_mutation_during_run_is_not_published_as_completed(self):
        original = self.recording.generate
        def mutate(*args):
            result = original(*args)
            (self.prompts / "en-caption-9b.utf8").write_text("changed")
            return result
        self.recording.generate = mutate
        with self.assertRaisesRegex(ValueError, "changed during"):
            self.run_fake()
        self.assertTrue((self.root / "result").is_dir())
        self.assertFalse((self.root / "result/report.json").exists())

    def test_converter_adapter_is_explicit_and_never_runs_in_dry_run(self):
        with patch.object(a.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, '{"text":"學習"}', "")) as process:
            self.assertEqual(a.convert("学习", "zh-Hant-TW", Path("/synthetic/converter"), 3, False), "學習")
            self.assertEqual(json.loads(process.call_args.kwargs["input"]), {"targetLocale": "zh-Hant-TW", "text": "学习"})
            process.reset_mock()
            self.assertIn("DRY-RUN converted", a.convert("学习", "zh-Hant-TW", None, 3, True))
            process.assert_not_called()
        with patch.object(a.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "PRIVATE")), \
                self.assertRaisesRegex(a.WorkerFailure, "^converter_nonzero_exit$"):
            a.convert("学习", "zh-Hant-HK", Path("/synthetic/converter"), 3, False)

    def test_loader_reuses_existing_un_and_flores_alignment(self):
        meeting = self.root / "S_PV.synthetic"
        meeting.mkdir()
        data = {"schema_version": 1, "id": "S/PV.synthetic", "turn_count": 1,
                "turns": [{"index": 1, "texts": dict.fromkeys(c.UN_LOCALES, "Synthetic reference"),
                           "text_status": dict.fromkeys(c.UN_LOCALES, "extracted")} ]}
        (meeting / "turns.json").write_text(json.dumps(data))
        args = self.args("--corpus", "un", "--input", str(self.root))
        units, diagnostics = a.load_corpus(args)
        self.assertEqual(units, c.read_un(self.root).units)
        self.assertEqual(diagnostics["excluded"], [])
        files = {}
        for locale in ("en", "fr"):
            file = self.root / f"{locale}.txt"
            file.write_text("Invented one.\nInvented two.\n")
            files[locale] = file
        args.corpus, args.input, args.locale_file = "flores-plus", None, [f"{k}={v}" for k, v in files.items()]
        self.assertEqual(a.load_corpus(args)[0], c.read_flores_plus(files))

    def test_main_dry_run_writes_both_reports_and_prints_relative_receipt(self):
        args = self.args()
        with patch.object(a, "parser") as parser, patch.object(a.scoreboard, "read_processes", return_value={}), \
                redirect_stdout(io.StringIO()) as stdout:
            parser.return_value.parse_args.return_value = args
            self.assertEqual(a.main([]), 0)
        receipt = json.loads(stdout.getvalue())
        self.assertEqual(receipt["output"], "result")
        self.assertEqual([r["calls"] for r in receipt["routes"]], [2, 4])


if __name__ == "__main__":
    unittest.main()
