"""Synthetic routes and protocol-v2 subprocesses only; never import MLX/weights."""
from contextlib import redirect_stdout
import ast
from collections import OrderedDict
import copy
import io
import json
import os
from pathlib import Path
import re
import stat
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
generations = 0
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
        generations += 1
        if mode == 'timeout': continue
        if mode in ('crash-once', 'timeout-once') and generations == 4 and not (state/'fault-used').exists():
            (state/'fault-used').write_text('synthetic fault')
            if mode == 'crash-once': os._exit(2)
            continue
        if mode == 'budget' or mode == 'budget-once' and generations == 15:
            send('error', id=identity, code='output_budget_exhausted', message='PRIVATE diagnostic')
            continue
        send('loading', id=identity)
        send('snapshot', id=identity, wire='')
        send('snapshot', id=identity, wire='synthetic')
        fields = dict(id='wrong' if mode == 'wrong-id' else identity, text='synthetic translation', wire='synthetic translation')
        if mode != 'missing-stats': fields.update(finalTokens=7, thinkingTokens=0)
        if mode == 'prefix-stats': fields.update(inputTokens=1000, reusedPrefixTokens=768)
        if mode == 'bad-prefix-stats': fields.update(inputTokens=1000, reusedPrefixTokens=True)
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


class PrefixCacheWorker(RecordingWorker):
    """Replay real PromptPrefixCache LRU policy without importing MLX."""

    def __init__(self):
        super().__init__()
        source = Path(a.__file__).resolve().parents[1] / "mlx_runtime/engine.py"
        tree = ast.parse(source.read_text())
        node = next(n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == "PromptPrefixCache")
        namespace = {"OrderedDict": OrderedDict, "copy": copy, "PREFILL_STEP": 256}
        exec(compile(ast.Module(body=[node], type_ignores=[]), str(source), "exec"), namespace)
        self.cache = namespace["PromptPrefixCache"](max_tokens=768, max_entries=2)

    def generate(self, system, text, source, target):
        tokens = list(a.chat_prompt(system, text, source, target, "9b").encode())
        _, reused = self.cache.fetch(tokens)
        count = min(768, (len(tokens) - 1) // 256 * 256)
        snapshot = type("Snapshot", (), {"nbytes": 1})()
        self.cache.remember(tokens[:count], [snapshot])
        result = super().generate(system, text, source, target)
        result.update(input_tokens=len(tokens), reused_prefix_tokens=reused)
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
        self.enterContext(patch.object(a.scoreboard, "default_machine_lock_directory", return_value=a.scoreboard.DEFAULT))
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
        model.mkdir(parents=True, exist_ok=True)
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
        # Two unmeasured warm-ups precede the rotated unit order. Pivot consumes
        # generated English, never the parallel English human reference.
        self.assertEqual([call[3] for call in self.recording.calls], ["es", "en", "es", "en", "es", "en", "es", "es"])
        self.assertEqual([r["route_position"] for r in direct["results"]], [0, 1])
        self.assertEqual([r["route_position"] for r in pivot["results"]], [1, 0])
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

    @staticmethod
    def acl(path):
        result = subprocess.run(["/bin/ls", "-lde", str(path)], check=True,
                                capture_output=True, text=True)
        return result.stdout.splitlines()[1:]

    @unittest.skipUnless(sys.platform == "darwin", "macOS inherited ACL")
    def test_dry_run_clears_inherited_acl_on_output_and_body_reports(self):
        subprocess.run(["/bin/chmod", "+a", "everyone allow read,write,file_inherit,directory_inherit",
                        str(self.root)], check=True, capture_output=True)
        canary = self.root / "acl-canary"
        canary.write_text("synthetic")
        self.assertTrue(any("everyone inherited allow" in row for row in self.acl(canary)))
        out = self.root / "nested" / "result"
        self.run_fake(self.args("--output-dir", str(out)))
        for path in (out.parent, out):
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o700)
            self.assertEqual(self.acl(path), [])
        for name in ("report.json", "summary.md"):
            self.assertEqual(stat.S_IMODE((out / name).stat().st_mode), 0o600)
            self.assertEqual(self.acl(out / name), [])

    @unittest.skipUnless(sys.platform == "darwin", "macOS inherited ACL")
    def test_worker_state_root_is_private_before_synthetic_spawn(self):
        parent = self.root / "state-parent"
        parent.mkdir(mode=0o700)
        subprocess.run(["/bin/chmod", "+a", "everyone allow read,write,file_inherit,directory_inherit",
                        str(parent)], check=True, capture_output=True)
        state = parent / "worker-state"
        script = self.root / "fake-worker.py"
        script.write_text(FAKE_PROTOCOL)
        transport = a.MLXWorker(sys.executable, script, self.root / "unused-model", state, "9b", 3, 160)
        original = subprocess.Popen
        inspected = []

        def spawn(*args, **kwargs):
            if args[0] == transport.command:
                self.assertTrue(state.is_dir())
                self.assertEqual(stat.S_IMODE(state.stat().st_mode), 0o700)
                self.assertEqual(self.acl(state), [])
                inspected.append(True)
            return original(*args, **kwargs)

        with patch.object(a.subprocess, "Popen", side_effect=spawn):
            with transport:
                pass
        self.assertEqual(inspected, [True])

    @unittest.skipUnless(sys.platform == "darwin", "macOS existing ACL")
    def test_existing_unsafe_or_readonly_state_is_refused_before_spawn(self):
        for index, (mode, acl) in enumerate(((0o755, False), (0o700, True), (0o500, False), (0o700, "deny-allow"))):
            with self.subTest(mode=mode, acl=acl):
                state = self.root / f"existing-state-{index}"
                state.mkdir(mode=mode)
                if acl == "deny-allow":
                    subprocess.run(["/bin/chmod", "+a", "everyone deny delete", str(state)],
                                   check=True, capture_output=True)
                    self.addCleanup(subprocess.run, ["/bin/chmod", "-a", "everyone deny delete", str(state)],
                                    check=True, capture_output=True)
                if acl:
                    subprocess.run(["/bin/chmod", "+a", "everyone allow read,write", str(state)],
                                   check=True, capture_output=True)
                before = state.stat().st_mode, self.acl(state)
                transport = a.MLXWorker(sys.executable, self.root / "unused-worker", self.root / "unused-model",
                                        state, "9b", 3, 160)
                with patch.object(a.subprocess, "Popen", side_effect=AssertionError("spawned before state validation")) as spawn, \
                        self.assertRaises((OSError, ValueError, RuntimeError)):
                    transport.__enter__()
                spawn.assert_not_called()
                self.assertEqual((state.stat().st_mode, self.acl(state)), before)

    def test_existing_readonly_output_is_refused_without_permission_upgrade(self):
        out = self.root / "readonly-output"
        out.mkdir(mode=0o500)
        before = out.stat().st_mode
        with self.assertRaises(FileExistsError):
            self.run_fake(self.args("--output-dir", str(out)))
        self.assertEqual(out.stat().st_mode, before)

    def test_parser_errors_use_fixed_prog_and_omit_private_arguments(self):
        sentinel = "SYNTHETIC_PRIVATE_ARGUMENT"
        with patch.object(sys, "argv", ["synthetic-program-" + sentinel]), \
                patch.object(a.sys, "stderr", new_callable=io.StringIO) as error, self.assertRaises(SystemExit):
            a.parser().parse_args(["--final-budget", sentinel])
        self.assertNotIn(sentinel, error.getvalue())
        self.assertIn("target-eval-run-strategies", error.getvalue())

    def test_main_error_does_not_print_private_exception_text(self):
        sentinel = "SYNTHETIC_PRIVATE_INPUT"
        with patch.object(a, "run", side_effect=OSError(sentinel)), \
                patch.object(a.sys, "stderr", new_callable=io.StringIO) as error, self.assertRaises(SystemExit):
            a.main(["--prompts-dir", str(self.prompts), "--targets", "es", "--routes", "direct",
                    "--output-dir", str(self.root / "result"), "--dry-run"])
        self.assertNotIn(sentinel, error.getvalue())
        self.assertIn("target-eval-run-strategies", error.getvalue())

    def test_output_identity_drift_is_refused_before_acl_or_mode_changes(self):
        for index, drift in enumerate(("replacement", "owner", "device")):
            with self.subTest(drift=drift):
                out = self.root / f"claimed-{index}"
                replacement = self.root / f"replacement-{index}"
                replacement.mkdir(mode=0o755)
                before = replacement.stat().st_mode, replacement.stat().st_ino
                original_open, original_fstat = os.open, os.fstat
                opened_fd = []

                def open_output(name, flags, *args, **kwargs):
                    if name == out.name and flags & os.O_DIRECTORY:
                        if drift == "replacement":
                            out.rename(self.root / f"superseded-claimed-{index}")
                            replacement.rename(out)
                        descriptor = original_open(name, flags, *args, **kwargs)
                        opened_fd.append(descriptor)
                        return descriptor
                    return original_open(name, flags, *args, **kwargs)

                def fstat_output(descriptor):
                    state = original_fstat(descriptor)
                    if descriptor in opened_fd and drift in ("owner", "device"):
                        values = list(state)
                        values[4 if drift == "owner" else 2] += 1
                        return os.stat_result(values)
                    return state

                with patch.object(a.os, "open", side_effect=open_output), \
                        patch.object(a.os, "fstat", side_effect=fstat_output), \
                        patch.object(a, "privatize_new", wraps=a.privatize_new) as privatize, \
                        self.assertRaises((OSError, ValueError, a.scoreboard.Rejected)):
                    self.run_fake(self.args("--output-dir", str(out)))
                privatize.assert_not_called()
                if drift == "replacement":
                    self.assertEqual((out.stat().st_mode, out.stat().st_ino), before)

    @unittest.skipUnless(sys.platform == "darwin", "macOS deny ACL")
    def test_existing_private_worker_state_deny_acl_is_preserved(self):
        state = self.root / "state"
        state.mkdir(mode=0o700)
        subprocess.run(["/bin/chmod", "+a", "everyone deny delete", str(state)],
                       check=True, capture_output=True)
        self.addCleanup(subprocess.run, ["/bin/chmod", "-a", "everyone deny delete", str(state)],
                        check=True, capture_output=True)
        before = state.stat().st_mode, self.acl(state)
        with self.transport():
            pass
        self.assertEqual((state.stat().st_mode, self.acl(state)), before)

    def test_cli_entrypoints_direct_scripts_and_alias_preserve_private_parser(self):
        scripts = Path(a.__file__).resolve().parents[1]
        environment = {"PYTHONPATH": str(scripts), "PYTHONDONTWRITEBYTECODE": "1",
                       "TMPDIR": os.environ.get("TMPDIR", "/tmp")}
        sentinel = "SYNTHETIC_PRIVATE_ARGUMENT"
        prefixes = ([sys.executable, "-B", str(scripts / "target_eval/run_strategies.py")],
                    [sys.executable, "-B", "-m", "Scripts.target_eval.run_strategies"],
                    [sys.executable, "-B", "-m", "target_eval.run_strategies"])
        for prefix in prefixes:
            with self.subTest(entry=prefix[-1]):
                help_result = subprocess.run([*prefix, "--help"], cwd=scripts.parent, env=environment,
                                             capture_output=True, text=True, timeout=10)
                self.assertEqual(help_result.returncode, 0)
                self.assertIn("target-eval-run-strategies", help_result.stdout)
                result = subprocess.run([*prefix, "--unknown-" + sentinel], cwd=scripts.parent, env=environment,
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 2)
                self.assertNotIn(sentinel, result.stdout + result.stderr)
                self.assertNotIn(str(scripts), result.stdout + result.stderr)
                self.assertIn("invalid_arguments", result.stderr)

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
        self.assertIsNone(route["summary"]["chrfpp"])
        self.assertEqual(route["summary"]["passthrough_count"], 2)
        self.assertEqual([r["quality"]["chrfpp"] for r in route["results"]], [100, 100])
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
        self.assertEqual(sum(call["worker_first_generation"] for call in calls), 0)
        self.assertEqual(sum(call["worker_first_generation"] for call in report["warmups"]), 1)
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

    def expand_units(self, count):
        self.units = [c.ParallelUnit(f"synthetic:{i}", "synthetic", self.units[0].texts,
                                     self.units[0].metadata) for i in range(count)]
        self.corpus = self.root / f"corpus-{count}.jsonl"
        c.write_jsonl(self.units, self.corpus)

    def long_prefix_prompts(self):
        manifest_path = self.prompts / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        for entry in manifest["prompts"]:
            data = (entry["targetLocale"] + " System " + "x" * 1100).encode()
            (self.prompts / entry["file"]).write_bytes(data)
            entry.update(byteCount=len(data), sha256=a.digest(data))
        manifest_path.write_text(json.dumps(manifest))

    def test_target_blocks_keep_real_two_entry_lru_warm_for_every_measured_direct(self):
        self.expand_units(6)
        self.long_prefix_prompts()
        scenarios = ((["es", "fr"], ["direct", "via-en"], "zh"),
                     (["zh-Hant-TW", "zh-Hant-HK"], ["direct", "hans-convert"], "en"),
                     (["en", "es", "fr"], ["direct"], "zh"))
        for index, (targets, routes, source) in enumerate(scenarios):
            with self.subTest(targets=targets):
                self.recording = PrefixCacheWorker()
                args = self.args("--targets", *targets, "--routes", *routes, "--sources", source,
                                 "--output-dir", str(self.root / f"lru-{index}"))
                report = self.run_fake(args)
                calls = [call for route in report["routes"] for row in route["results"] for call in row["calls"]]
                self.assertTrue(calls)
                self.assertEqual({call["reused_prefix_tokens"] for call in calls}, {768})
                self.assertTrue(all(not call["worker_first_generation"] for call in calls))
                expected_warmups = sum(len(set(hop for name in routes for hop in a.Route(t, name).hops)) for t in targets)
                self.assertEqual(len(report["warmups"]), expected_warmups)
                self.assertTrue(all(not warm["measured"] for warm in report["warmups"]))
                self.assertTrue(all(route["summary"]["reused_prefix_tokens"] > 0 for route in report["routes"]))
        # Reproduce the reviewed old order: each direct is evicted by en+other target.
        cold = PrefixCacheWorker()
        reused = []
        for _ in range(6):
            for target in ("es", "fr"):
                system = a.PromptBundle(self.prompts).caption(target, "9b")
                reused.append(cold.generate(system, "text", "zh", target)["reused_prefix_tokens"])
                cold.generate(a.PromptBundle(self.prompts).caption("en", "9b"), "text", "zh", "en")
                cold.generate(system, "text", "en", target)
        self.assertEqual(reused, [0] * 12)

    def test_first_load_and_energy_are_only_in_unmeasured_warmups_in_both_route_orders(self):
        self.expand_units(5)
        for index, routes in enumerate((["direct", "via-en"], ["via-en", "direct"])):
            with self.subTest(routes=routes):
                clock = [100.0]
                class ColdWorker(RecordingWorker):
                    def generate(worker, system, text, source, target):
                        start = clock[0]
                        clock[0] += 1.0 if not worker.calls else .01
                        worker.calls.append((system, text, source, target))
                        return {"output": "synthetic translation", **a.stats(start, clock[0], clock[0], 7, 0)}
                self.recording = ColdWorker()
                helper = self.root / "synthetic-helper"
                helper.touch(); helper.chmod(0o700)
                args = self.real_args_with_fake_protocol("--routes", *routes, "--energy-helper", str(helper),
                                                        "--output-dir", str(self.root / f"cold-{index}"))
                with patch.object(a.time, "monotonic", side_effect=lambda: clock[0]):
                    report = self.run_fake(args, sampler_factory=SyntheticSampler)
                by_name = {route["route"]: route for route in report["routes"]}
                self.assertAlmostEqual(by_name["direct"]["summary"]["mean_seconds"], .01)
                self.assertAlmostEqual(by_name["via-en"]["summary"]["mean_seconds"], .02)
                self.assertAlmostEqual(by_name["direct"]["summary"]["p95_seconds"], .01)
                self.assertAlmostEqual(by_name["direct"]["summary"]["gross_j"], .15)
                self.assertAlmostEqual(by_name["via-en"]["summary"]["gross_j"], .30)
                self.assertAlmostEqual(report["warmups"][0]["total_seconds"], 1.0)
                self.assertAlmostEqual(report["warmups"][0]["energy"]["gross_j"], 3.0)
                self.assertEqual([r["route_position"] for r in by_name[routes[0]]["results"]], [0, 1, 0, 1, 0])

    def test_warmup_failure_invalidates_target_and_never_measures_cold_call(self):
        self.expand_units(6)
        self.long_prefix_prompts()
        for code in ("worker_generation_failed", "output_budget_exhausted"):
            with self.subTest(code=code):
                clock = [100.0]
                attempts = []

                class ColdAfterErrorWorker(PrefixCacheWorker):
                    def generate(worker, system, text, source, target):
                        start = clock[0]
                        attempts.append((text, target))
                        if len(attempts) == 1:
                            clock[0] += .01
                            raise a.WorkerFailure(code, measurement=a.stats(start, clock[0]))
                        result = super().generate(system, text, source, target)
                        clock[0] += 1.0 if len(attempts) == 2 else .01
                        result.update(start_mono=start, end_mono=clock[0], total_seconds=clock[0] - start)
                        return result

                self.recording = ColdAfterErrorWorker()
                args = self.args("--targets", "es", "fr", "--routes", "direct",
                                 "--output-dir", str(self.root / code))
                with patch.object(a.time, "monotonic", side_effect=lambda: clock[0]):
                    report = self.run_fake(args)
                invalid, valid = report["routes"]
                self.assertEqual([text for text, target in attempts if target == "es"], ["1"])
                self.assertEqual(invalid["summary"]["call_count"], 0)
                self.assertEqual(invalid["summary"]["failure_count"], 6)
                self.assertIsNone(invalid["summary"]["p95_seconds"])
                self.assertIsNone(invalid["summary"]["chrfpp"])
                self.assertTrue(all(not row["comparison_eligible"] for row in invalid["results"]))
                self.assertEqual(report["invalid_target_blocks"][0]["target_locale"], "es")
                self.assertEqual(report["invalid_target_blocks"][0]["failure"]["code"], code)
                self.assertAlmostEqual(valid["summary"]["mean_seconds"], .01)
                self.assertEqual({call["reused_prefix_tokens"] for row in valid["results"]
                                  for call in row["calls"]}, {768})
                self.assertAlmostEqual(report["warmups"][1]["total_seconds"], 1.0)
                self.assertEqual(report["status"], "completed_with_failures")
                summary = (self.root / code / "summary.md").read_text()
                self.assertIn("Invalid target block: es", summary)
                self.assertIn(code, summary)
                self.assertEqual(json.loads((self.root / code / "report.json").read_text()), report)

    def test_failed_rewarm_invalidates_previously_measured_target_rows(self):
        self.expand_units(6)
        workers = []

        class BrokenThenColdWorker(RecordingWorker):
            def generate(worker, system, text, source, target):
                if len(workers) == 2:
                    raise a.WorkerFailure("worker_generation_failed")
                if len(worker.calls) == 3:
                    raise a.WorkerFailure("worker_exited")
                return super().generate(system, text, source, target)

        def factory():
            worker = BrokenThenColdWorker()
            workers.append(worker)
            return worker

        report = a.run(self.args(), process_provider=lambda: {}, worker_factory=factory)
        self.assertEqual(report["worker_sessions"]["count"], 2)
        self.assertEqual(report["comparisons"][0]["sample_count"], 0)
        self.assertEqual(report["comparisons"][0]["excluded_count"], 6)
        for route in report["routes"]:
            self.assertTrue(all(not row["comparison_eligible"] for row in route["results"]))
            self.assertIsNone(route["summary"]["mean_seconds"])
            self.assertIsNone(route["summary"]["chrfpp"])
        self.assertEqual(len(report["invalid_target_blocks"]), 1)
        self.assertEqual(report["routes"][0]["results"][0]["status"], "succeeded")
        self.assertFalse(workers[1].calls)

    def test_model_route_first_positions_balance_without_counting_passthrough(self):
        for count in (5, 6):
            self.expand_units(count)
            # Match the review's default en/zh source selection for a Hant target.
            units = [c.ParallelUnit(unit.id, unit.corpus,
                     {locale: unit.texts[locale] for locale in ("zh", "en", "zh-Hant-TW")}, unit.metadata)
                     for unit in self.units]
            self.corpus = self.root / f"rotation-corpus-{count}.jsonl"
            c.write_jsonl(units, self.corpus)
            for index, routes in enumerate((["direct", "hans-convert"], ["hans-convert", "direct"])):
                with self.subTest(count=count, routes=routes):
                    self.recording = RecordingWorker()
                    args = self.args("--targets", "zh-Hant-TW", "--routes", *routes,
                                     "--output-dir", str(self.root / f"rotation-{count}-{index}"))
                    args.sources = None
                    report = self.run_fake(args)
                    first_counts = [sum(row["route_position"] == 0 and row["comparison_eligible"]
                                        for row in route["results"]) for route in report["routes"]]
                    self.assertEqual(first_counts, [(count + 1) // 2, count // 2])
                    self.assertEqual(report["comparisons"][0]["sample_count"], count)
                    for route in report["routes"]:
                        self.assertEqual(route["summary"]["call_count"], count)
                        self.assertTrue(all(not row["calls"] and not row["comparison_eligible"]
                                            for row in route["results"] if row["source_locale"] == "zh"))

    def test_nonuniform_energy_sampling_splits_warmups_targets_and_restarts(self):
        self.expand_units(5)
        helper = self.root / "synthetic-helper"
        helper.touch()
        helper.chmod(0o700)
        for scenario, targets, restart in (("review", ["es"], False),
                                           ("targets", ["es", "fr"], False),
                                           ("restart", ["es"], True)):
            with self.subTest(scenario=scenario):
                clock, joules = [100.0], [0.0]
                workers, samplers = [], []
                fault_used = [False]

                class NonuniformWorker(RecordingWorker):
                    def generate(worker, system, text, source, target):
                        start = clock[0]
                        first = not worker.calls
                        clock[0] += 1.0 if first else .01
                        joules[0] += 100.0 if first else .01
                        if restart and len(worker.calls) == 3 and not fault_used[0]:
                            fault_used[0] = True
                            raise a.WorkerFailure("worker_exited", measurement=a.stats(start, clock[0]))
                        worker.calls.append((system, text, source, target))
                        return {"output": "synthetic translation",
                                **a.stats(start, clock[0], clock[0], 777 if text == "1" else 7, 0)}

                class BoundarySampler(SyntheticSampler):
                    def __init__(sampler, **kwargs):
                        super().__init__(**kwargs)
                        sampler.started = False
                        samplers.append(sampler)

                    def start(sampler):
                        assert not sampler.started, "a stopped sampler must be replaced"
                        sampler.started = True
                        sampler.start_j = joules[0]
                        super().start()

                    def stop(sampler):
                        assert sampler.started and not sampler.stopped
                        sampler.end_j = joules[0]
                        super().stop()

                    def snapshot(sampler):
                        assert sampler.stopped, "flush counters before taking the final snapshot"
                        if sampler.start_mono == sampler.end_mono:
                            return []
                        return [{"start_mono": sampler.start_mono, "end_mono": sampler.end_mono,
                                 "is_delta": True, "source": "synthetic_ioreport", "mode": "energy_counters",
                                 "energy_unit": "J", "rails_j": {"cpu": sampler.end_j - sampler.start_j,
                                                                   "gpu": 0.0, "ane": 0.0}}]

                def factory():
                    worker = NonuniformWorker()
                    workers.append(worker)
                    return worker

                args = self.real_args_with_fake_protocol("--targets", *targets, "--sample-interval", "2",
                        "--energy-helper", str(helper), "--output-dir", str(self.root / f"energy-{scenario}"))
                with patch.object(a.time, "monotonic", side_effect=lambda: clock[0]):
                    report = a.run(args, process_provider=lambda: {}, worker_factory=factory,
                                   sampler_factory=BoundarySampler)
                for route in report["routes"]:
                    self.assertAlmostEqual(route["summary"]["gross_j"], route["summary"]["call_count"] * .01)
                    for row in route["results"]:
                        self.assertAlmostEqual(row["energy"]["gross_j"], len(row["calls"]) * .01)
                        for call in row["calls"]:
                            self.assertAlmostEqual(call["energy"]["gross_j"], .01)
                if scenario == "review":
                    self.assertAlmostEqual(joules[0], 100.16)
                    self.assertAlmostEqual(report["routes"][0]["summary"]["gross_j"], .05)
                    self.assertAlmostEqual(report["routes"][1]["summary"]["gross_j"], .10)
                expected_segments = 2 if scenario == "review" else 4
                self.assertEqual(len(samplers), expected_segments)
                self.assertTrue(all(sampler.stopped for sampler in samplers))
                self.assertEqual([segment["phase"] for segment in report["energy"]["segments"]],
                                 ["warmup", "measurement"] * (expected_segments // 2))
                samples = report["energy"]["samples"]
                self.assertAlmostEqual(sum(sample["rails_j"]["cpu"] for sample in samples), joules[0])
                measured_samples = [sample for sample in samples if sample["sampling_phase"] == "measurement"]
                for warmup in report["warmups"]:
                    self.assertTrue(all(sample["end_mono"] <= warmup["start_mono"] or
                                        sample["start_mono"] >= warmup["end_mono"] for sample in measured_samples))

    def test_pass_through_table_matches_swift_output_language_profiles(self):
        sources = Path(a.__file__).resolve().parents[2] / "LiveLingo/Sources"
        swift = (sources / "OutputLanguage.swift").read_text()
        enum_cases = dict(re.findall(r'case (\w+) = "([^"]+)"', swift))
        table = swift.split("private static let profiles:", 1)[1].split("\n    ]", 1)[0]
        matches = re.findall(r'\.(\w+): \.init\(.*?passThroughSources: (\[[^\]]*\]|LatinOutputDefaults\.\w+)', table, re.DOTALL)
        actual = {}
        for name, codes in matches:
            if codes.startswith("LatinOutputDefaults."):
                constant = codes.split(".")[1]
                value = re.search(rf'static let {constant}: Set<String> = (\[[^\]]*\])', swift)
                self.assertIsNotNone(value)
                codes = value[1]
            actual[enum_cases[name]] = frozenset(re.findall(r'"([^"]+)"', codes))
        self.assertEqual(len(matches), len(enum_cases))
        self.assertEqual(actual, a.PASS_THROUGH_SOURCES)

    def test_chinese_to_hans_or_hant_passthrough_has_zero_calls_and_no_comparison(self):
        self.export_prompts(targets=())
        for index, target in enumerate(("zh-Hans", "zh-Hant-TW", "zh-Hant-HK")):
            routes = ["direct"] if target == "zh-Hans" else ["direct", "hans-convert"]
            with self.subTest(target=target):
                self.recording.calls.clear()
                report = self.run_fake(self.args("--targets", target, "--routes", *routes, "--sources", "zh",
                                                 "--output-dir", str(self.root / f"pass-{index}")))
                self.assertEqual(self.recording.calls, [])
                self.assertEqual(report["warmups"], [])
                for route in report["routes"]:
                    self.assertEqual(route["summary"]["call_count"], 0)
                    self.assertEqual(route["summary"]["passthrough_count"], 2)
                    self.assertEqual(route["summary"]["translation_success_count"], 0)
                    self.assertTrue(all(row["passthrough"] and not row["comparison_eligible"] for row in route["results"]))
                for comparison in report["comparisons"]:
                    self.assertEqual(comparison["status"], "no_common_successes")
                    self.assertEqual(comparison["sample_count"], 0)

    def test_default_chinese_hant_source_is_passthrough_and_excluded_from_pairing(self):
        args = self.args("--targets", "zh-Hant-TW", "--routes", "direct", "hans-convert")
        args.sources = None
        report = self.run_fake(args)
        for route in report["routes"]:
            zh = [row for row in route["results"] if row["source_locale"] == "zh"]
            self.assertEqual(len(zh), 2)
            self.assertTrue(all(not row["calls"] and row["passthrough"] for row in zh))
        paired_ids = report["comparisons"][0]["example_ids"]
        self.assertEqual(len(paired_ids), 6)
        self.assertTrue(all(json.loads(identity)[1] != "zh" for identity in paired_ids))

    def test_real_chinese_passthrough_requires_normalizer_before_worker_and_uses_zero_calls(self):
        args = self.args("--targets", "zh-Hans", "--routes", "direct", "--sources", "zh")
        args.dry_run = False
        with self.assertRaisesRegex(ValueError, "--converter"):
            self.run_fake(args)
        executable = self.root / "synthetic-normalizer"
        executable.touch(); executable.chmod(0o700)
        args.converter = executable
        with patch.object(a, "convert", return_value="温度升高。") as normalizer, patch.object(a, "guard_other_workers"):
            report = self.run_fake(args)
        self.assertEqual(normalizer.call_count, 2)
        self.assertTrue(all(call.args[1] == "zh-Hans" for call in normalizer.call_args_list))
        self.assertEqual(self.recording.calls, [])
        self.assertEqual(report["routes"][0]["summary"]["call_count"], 0)

    def test_fake_protocol_optional_prefix_stats_and_invalid_counts(self):
        with self.transport(mode="prefix-stats") as worker:
            result = worker.generate("Prompt", "Example", "en", "es")
        self.assertEqual(result["input_tokens"], 1000)
        self.assertEqual(result["reused_prefix_tokens"], 768)
        worker = self.transport(mode="bad-prefix-stats")
        with self.assertRaisesRegex(a.WorkerFailure, "invalid_worker_token_count"):
            with worker:
                worker.generate("Prompt", "Example", "en", "es")

    def test_budget_failure_on_call_fifteen_keeps_rows_and_same_worker(self):
        self.expand_units(10)
        self.enterContext(patch.dict(os.environ, {"STRATEGY_SYNTHETIC_MODE": "budget-once"}))
        report = a.run(self.real_args_with_fake_protocol("--no-energy"), process_provider=lambda: {})
        direct, pivot = report["routes"]
        self.assertEqual(report["status"], "completed_with_failures")
        self.assertEqual(report["worker_sessions"]["count"], 1)
        self.assertEqual([r["summary"]["failure_count"] for r in report["routes"]], [1, 0])
        failed = next(row for row in direct["results"] if row["status"] == "failed")
        self.assertEqual(failed["failure"], {"code": "output_budget_exhausted", "stream_fault": False})
        self.assertEqual(failed["calls"][0]["status"], "failed")
        self.assertGreater(failed["calls"][0]["total_seconds"], 0)
        self.assertIsNone(failed["quality"])
        self.assertEqual(len(direct["results"]), 10)
        self.assertEqual(len(pivot["results"]), 10)
        self.assertEqual(report["comparisons"][0]["sample_count"], 9)
        self.assertNotIn(failed["id"], report["comparisons"][0]["example_ids"])
        self.assertEqual(direct["results"][-1]["status"], "succeeded")
        self.assertNotIn("PRIVATE", json.dumps(report))
        self.assertEqual(json.loads((self.root / "result/report.json").read_text()), report)
        self.assertIn("Failed", (self.root / "result/summary.md").read_text())

    def test_stream_crash_or_timeout_restarts_then_rewarms_and_continues(self):
        for mode in ("crash-once", "timeout-once"):
            with self.subTest(mode=mode), patch.dict(os.environ, {"STRATEGY_SYNTHETIC_MODE": mode}):
                args = self.real_args_with_fake_protocol("--no-energy", "--timeout-seconds", ".25",
                                                        "--output-dir", str(self.root / mode))
                report = a.run(args, process_provider=lambda: {})
                self.assertEqual(report["worker_sessions"]["count"], 2)
                self.assertEqual(len(report["warmups"]), 4)
                self.assertEqual(sum(r["summary"]["failure_count"] for r in report["routes"]), 1)
                self.assertEqual(report["comparisons"][0]["sample_count"], 1)
                measured = [call for route in report["routes"] for row in route["results"] for call in row["calls"] if call["status"] == "succeeded"]
                self.assertTrue(all(not call["worker_first_generation"] for call in measured))
                self.assertTrue(any(call["worker_number"] == 2 for call in measured))

    def test_converter_nonzero_invalid_json_or_timeout_is_per_row_without_worker_restart(self):
        executable = self.root / "synthetic-converter"
        executable.touch(); executable.chmod(0o700)
        faults = (("nonzero", subprocess.CompletedProcess([], 1, "", "PRIVATE"), "converter_nonzero_exit"),
                  ("invalid-json", subprocess.CompletedProcess([], 0, "PRIVATE", ""), "invalid_converter_response"),
                  ("timeout", subprocess.TimeoutExpired("PRIVATE", .01), "converter_timeout"))
        for name, fault, code in faults:
            with self.subTest(name=name):
                args = self.real_args_with_fake_protocol("--no-energy", "--targets", "zh-Hant-TW",
                        "--routes", "direct", "hans-convert", "--sources", "en", "--converter", str(executable),
                        "--output-dir", str(self.root / name))
                good = subprocess.CompletedProcess([], 0, '{"text":"溫度升高。"}', "")
                with patch.object(a.subprocess, "run", side_effect=[fault, good]):
                    report = a.run(args, process_provider=lambda: {})
                self.assertEqual(report["worker_sessions"]["count"], 1)
                self.assertEqual([r["summary"]["failure_count"] for r in report["routes"]], [0, 1])
                failed = report["routes"][1]["results"][0]
                self.assertEqual(failed["failure"], {"code": code, "stream_fault": False})
                self.assertEqual(failed["calls"][0]["status"], "succeeded")
                self.assertIsNone(failed["quality"])
                self.assertEqual(report["comparisons"][0]["sample_count"], 1)
                self.assertNotIn("PRIVATE", json.dumps(report))

    def test_hop_two_control_marker_is_per_row_and_does_not_restart(self):
        original = self.recording.generate
        poisoned = [False]
        def generate(system, text, source, target):
            result = original(system, text, source, target)
            if target == "en" and text != "1" and not poisoned[0]:
                poisoned[0] = True
                result["output"] = "<|im_end|>"
            return result
        self.recording.generate = generate
        report = self.run_fake()
        self.assertEqual(report["worker_sessions"]["count"], 1)
        self.assertEqual([r["summary"]["failure_count"] for r in report["routes"]], [0, 1])
        failed = report["routes"][1]["results"][0]
        self.assertEqual(failed["failure"]["code"], "intermediate_control_marker")
        self.assertEqual(len(failed["calls"]), 1)
        self.assertEqual(report["comparisons"][0]["sample_count"], 1)
        self.assertEqual(report["routes"][1]["results"][1]["status"], "succeeded")

    def test_all_rows_failed_still_writes_report_without_invalid_bootstrap(self):
        self.enterContext(patch.dict(os.environ, {"STRATEGY_SYNTHETIC_MODE": "budget"}))
        report = a.run(self.real_args_with_fake_protocol("--no-energy"), process_provider=lambda: {})
        self.assertEqual(report["status"], "completed_with_failures")
        self.assertEqual([r["summary"]["failure_count"] for r in report["routes"]], [2, 2])
        self.assertTrue(all(r["summary"]["p95_seconds"] is None and r["summary"]["chrfpp"] is None for r in report["routes"]))
        self.assertEqual(report["comparisons"][0]["status"], "no_common_successes")
        self.assertIsNone(report["comparisons"][0]["delta"])
        self.assertEqual(report["worker_sessions"]["count"], 1)

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
