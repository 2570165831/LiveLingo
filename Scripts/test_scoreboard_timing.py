#!/usr/bin/env python3
"""Numeric timing and real service/worker control flow with artificial models.

Run: python3 -B Scripts/test_scoreboard_timing.py
Small fixtures and receipts are retained in this checkout's work/timing-tests.
No MLX, weights, GPU, network listener or third-party dependency is used.
"""
import ast
import contextlib
import importlib.util
import io
import json
import math
import os
from pathlib import Path
import queue
import selectors
import shutil
import subprocess
import sys
import tempfile
import time
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import Mock, patch

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))
sys.dont_write_bytecode = True
import scoreboard_timing as timing

TEST_ROOT = SCRIPTS.parent / "work/timing-tests"
PRIVATE = "private-input-output-id-error-should-never-appear"
FIELDS = {"stage", "wall_seconds", "process_cpu_seconds", "start_mono", "end_mono", "completed"}


def module(name, **attributes):
    result = ModuleType(name)
    result.__dict__.update(attributes)
    return result


def load_script(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


class Clock:
    wall = 100.0
    cpu = 10.0

    def advance(self, wall, cpu):
        self.wall += wall
        self.cpu += cpu


class TimingCase(unittest.TestCase):
    def setUp(self):
        if TEST_ROOT.resolve() != TEST_ROOT:
            raise AssertionError("test directory must not use symlinks")
        TEST_ROOT.mkdir(parents=True, exist_ok=True)
        self.directory = Path(tempfile.mkdtemp(prefix=self._testMethodName + "-", dir=TEST_ROOT))
        self.enterContext(patch.dict(os.environ))
        os.environ.pop(timing.TIMINGS_ENV, None)
        self.clock = Clock()
        self.enterContext(patch.object(timing, "monotonic", side_effect=lambda: self.clock.wall))
        self.enterContext(patch.object(timing, "process_time", side_effect=lambda: self.clock.cpu))

    def log_file(self, name="model-times.jsonl"):
        path = self.directory / name
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(descriptor)
        return path

    def enable(self, path):
        os.environ[timing.TIMINGS_ENV] = str(path)

    def samples(self, path):
        raw = path.read_text()
        self.assertNotIn(PRIVATE, raw)
        rows = [json.loads(line) for line in raw.splitlines()]
        for row in rows:
            self.assertEqual(set(row), FIELDS)
            self.assertIn(row["stage"], timing.STAGES)
            self.assertIs(type(row["completed"]), bool)
            for field in FIELDS - {"stage", "completed"}:
                self.assertIn(type(row[field]), (int, float))
                self.assertTrue(math.isfinite(row[field]))
                self.assertGreaterEqual(row[field], 0)
            self.assertAlmostEqual(row["wall_seconds"], row["end_mono"] - row["start_mono"])
        return rows


class HelperTests(TimingCase):
    def test_success_and_failure_preserve_exception_without_text(self):
        path = self.log_file()
        self.enable(path)
        error = RuntimeError(PRIVATE)
        with timing.measure("asr_load"):
            self.clock.advance(5, 2)
        with self.assertRaises(RuntimeError) as caught:
            with timing.measure("asr_inference"):
                self.clock.advance(7, 3)
                raise error
        self.assertIs(caught.exception, error)
        self.assertEqual(self.samples(path), [
            dict(stage="asr_load", wall_seconds=5, process_cpu_seconds=2,
                 start_mono=100, end_mono=105, completed=True),
            dict(stage="asr_inference", wall_seconds=7, process_cpu_seconds=3,
                 start_mono=105, end_mono=112, completed=False),
        ])

    def test_disabled_and_empty_setting_do_not_read_clocks_or_touch_files(self):
        for value in (None, ""):
            with self.subTest(value=value):
                if value is not None: self.enable(value)
                with patch.object(timing, "monotonic") as wall, patch.object(timing, "process_time") as cpu, \
                        patch.object(timing.os, "lstat") as check, patch.object(timing.os, "open") as opened:
                    with timing.measure("text_step"):
                        result = PRIVATE
                    self.assertEqual(result, PRIVATE)
                    for probe in (wall, cpu, check, opened): probe.assert_not_called()
        self.assertEqual(list(self.directory.iterdir()), [])

    def test_unknown_stage_is_never_serialized(self):
        path = self.log_file()
        self.enable(path)
        with patch.object(timing, "monotonic") as wall:
            for stage in (PRIVATE, {"stage": PRIVATE}, None):
                with timing.measure(stage): pass
            wall.assert_not_called()
        self.assertEqual(path.read_bytes(), b"")

    def test_fixed_purpose_mapping(self):
        for purpose, expected in (("translation", "translation_step"), ("note", "notes_step"),
                                  ("review", "review_step"), ("text", "text_step"),
                                  (PRIVATE, "text_step"), ({"private": PRIVATE}, "text_step")):
            self.assertEqual(timing.generation_stage(purpose), expected)

    def test_missing_relative_directory_symlink_and_fifo_are_rejected(self):
        target = self.log_file()
        link = self.directory / "link"
        link.symlink_to(target)
        fifo = self.directory / "fifo"
        os.mkfifo(fifo, 0o600)
        missing = self.directory / "missing"
        for path in ("relative.jsonl", missing, self.directory, link, fifo):
            with self.subTest(path=str(path)):
                self.enable(path)
                with patch.object(timing.os, "open") as opened:
                    with timing.measure("text_step"): pass
                    opened.assert_not_called()
        self.assertFalse(missing.exists())
        self.assertEqual(target.read_bytes(), b"")

    def test_other_owner_is_rejected(self):
        path = self.log_file()
        self.enable(path)
        foreign = SimpleNamespace(st_mode=path.stat().st_mode, st_uid=os.geteuid() + 1)
        with patch.object(timing.os, "lstat", return_value=foreign), \
                patch.object(timing.os, "open") as opened:
            with timing.measure("text_step"): pass
            opened.assert_not_called()
        self.assertEqual(path.read_bytes(), b"")

    def test_append_flags_preserve_existing_bytes_and_close_descriptor(self):
        path = self.log_file()
        with path.open("ab") as handle: handle.write(b"existing\n")
        self.enable(path)
        with patch.object(timing.os, "open", wraps=os.open) as opened, \
                patch.object(timing.os, "close", wraps=os.close) as closed:
            with timing.measure("language_load"): self.clock.advance(1, 0.5)
            flags = opened.call_args.args[1]
            for required in (os.O_APPEND, os.O_NOFOLLOW, os.O_NONBLOCK):
                self.assertTrue(flags & required)
            self.assertFalse(flags & (os.O_CREAT | os.O_TRUNC))
            closed.assert_called_once()
        self.assertTrue(path.read_bytes().startswith(b"existing\n"))
        self.assertEqual(len(path.read_text().splitlines()), 2)

    def test_replaced_inode_and_opened_nonregular_file_are_rejected(self):
        path, other = self.log_file(), self.log_file("other")
        self.enable(path)
        for destination, flags in ((other, os.O_WRONLY | os.O_APPEND), (self.directory, os.O_RDONLY)):
            with self.subTest(destination=str(destination)):
                descriptor = os.open(destination, flags)
                with patch.object(timing.os, "open", return_value=descriptor), \
                        patch.object(timing.os, "write") as written:
                    with timing.measure("text_step"): pass
                    written.assert_not_called()
                with self.assertRaises(OSError): os.fstat(descriptor)
        self.assertEqual(path.read_bytes(), b"")
        self.assertEqual(other.read_bytes(), b"")

    def test_open_and_write_errors_are_silent_and_preserve_model_errors(self):
        path = self.log_file()
        self.enable(path)
        for operation in ("open", "write"):
            with self.subTest(operation=operation):
                error = ValueError(PRIVATE)
                output, errors = io.StringIO(), io.StringIO()
                with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors), \
                        patch.object(timing.os, operation, side_effect=OSError(PRIVATE)):
                    with timing.measure("text_step"): pass
                    with self.assertRaises(ValueError) as caught:
                        with timing.measure("review_step"): raise error
                    self.assertIs(caught.exception, error)
                self.assertEqual(output.getvalue() + errors.getvalue(), "")
        self.assertEqual(path.read_bytes(), b"")

    def test_clock_or_serialization_failure_does_not_interrupt_body(self):
        path = self.log_file()
        self.enable(path)
        for values in ((RuntimeError(PRIVATE),), (100.0, RuntimeError(PRIVATE)), (100.0, float("nan"))):
            with self.subTest(values=values):
                with patch.object(timing, "monotonic", side_effect=values):
                    with timing.measure("text_step"):
                        result = PRIVATE
                self.assertEqual(result, PRIVATE)
        self.assertEqual(path.read_bytes(), b"")

    def test_two_processes_append_complete_numeric_lines(self):
        path = self.log_file()
        environment = dict(os.environ, **{timing.TIMINGS_ENV: str(path), "TMPDIR": str(self.directory)})
        boot = "import sys; sys.path.insert(0,sys.argv[1]); from scoreboard_timing import measure\nfor _ in range(20):\n with measure('text_step'): pass\n"
        processes = []
        try:
            for _ in range(2):
                processes.append(subprocess.Popen(
                    [sys.executable, "-B", "-I", "-c", boot, str(SCRIPTS)],
                    env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE))
            for process in processes:
                output, errors = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 0, errors.decode())
                self.assertEqual(output + errors, b"")
        finally:
            for process in processes:
                if process.poll() is None:
                    process.kill()
                    process.communicate(timeout=5)
        self.assertEqual(len(self.samples(path)), 40)


class ASRTests(TimingCase):
    def setUp(self):
        super().setUp()
        self.loader = Mock(side_effect=self.load_model)
        stubs = {
            "numpy": module("numpy"), "soundfile": module("soundfile"),
            "scipy": module("scipy"),
            "scipy.signal": module("scipy.signal", butter=Mock(), sosfilt=Mock(), sosfiltfilt=Mock()),
            "mlx_audio": module("mlx_audio"), "mlx_audio.stt": module("mlx_audio.stt"),
            "mlx_audio.stt.utils": module("mlx_audio.stt.utils", load_model=self.loader),
        }
        self.enterContext(patch.dict(sys.modules, stubs))
        self.service = load_script("timing_asr_under_test", SCRIPTS / "qwen_asr_service.py")
        self.addCleanup(self.service.INFERENCE_WORKER.shutdown)
        model_directory = self.directory / "fake-model"
        model_directory.mkdir()
        self.service.MODEL_PATHS = {"1.7b": model_directory, "parakeet": model_directory}
        self.model = SimpleNamespace(generate=Mock(side_effect=self.generate))
        clock = self.clock

        class WaitingLock:
            def __enter__(self): clock.advance(50, 0)
            def __exit__(self, *exception): return False

        self.service.MODEL_LOCK = WaitingLock()
        self.enterContext(contextlib.redirect_stdout(io.StringIO()))

    def load_model(self, path):
        self.clock.advance(5, 2)
        return self.model

    def generate(self, *args, **kwargs):
        self.clock.advance(7, 3)
        return SimpleNamespace(text=" " + PRIVATE + " ")

    def test_cold_and_warm_calls_split_load_and_inference_excluding_lock_wait(self):
        path = self.log_file()
        self.enable(path)
        for _ in range(2):
            self.assertEqual(self.service.transcribe_audio(PRIVATE, "1.7b"), PRIVATE)
        rows = self.samples(path)
        self.assertEqual([row["stage"] for row in rows], ["asr_load", "asr_inference", "asr_inference"])
        self.assertEqual([row["wall_seconds"] for row in rows], [5, 7, 7])
        self.assertEqual([row["process_cpu_seconds"] for row in rows], [2, 3, 3])
        self.assertEqual([row["start_mono"] for row in rows], [150, 155, 212])
        self.assertTrue(all(row["completed"] for row in rows))
        self.loader.assert_called_once()
        self.model.generate.assert_called_with(PRIVATE, language="English", max_tokens=256,
                                               temperature=0.0, verbose=False)

    def test_load_failure_is_recorded_without_an_inference_sample(self):
        path = self.log_file()
        self.enable(path)
        error = RuntimeError(PRIVATE)
        def fail(path):
            self.clock.advance(5, 2)
            raise error
        self.loader.side_effect = fail
        with self.assertRaises(RuntimeError) as caught:
            self.service.transcribe_audio(PRIVATE, "1.7b")
        self.assertIs(caught.exception, error)
        rows = self.samples(path)
        self.assertEqual([(row["stage"], row["completed"]) for row in rows], [("asr_load", False)])
        self.model.generate.assert_not_called()

    def test_inference_failure_is_recorded_and_original_exception_survives(self):
        path = self.log_file()
        self.enable(path)
        error = RuntimeError(PRIVATE)
        def fail(*args, **kwargs):
            self.clock.advance(7, 3)
            raise error
        self.model.generate.side_effect = fail
        with self.assertRaises(RuntimeError) as caught:
            self.service.transcribe_audio(PRIVATE, "1.7b")
        self.assertIs(caught.exception, error)
        self.assertEqual([(row["stage"], row["completed"]) for row in self.samples(path)],
                         [("asr_load", True), ("asr_inference", False)])

    def test_parakeet_and_auto_paths_keep_arguments_and_results(self):
        path = self.log_file()
        self.enable(path)
        self.assertEqual(self.service.transcribe_audio(PRIVATE, "parakeet"), PRIVATE)
        self.model.generate.assert_called_once_with(PRIVATE, verbose=False)
        expected = {"text": PRIVATE, "language": "en"}
        def auto(*args):
            self.clock.advance(11, 4)
            return expected
        with patch.object(self.service, "transcribe_auto", side_effect=auto) as transcribe:
            self.assertIs(self.service.transcribe_audio(PRIVATE, "1.7b", "auto", PRIVATE), expected)
            transcribe.assert_called_once_with(self.model, PRIVATE, PRIVATE, "1.7b")
        self.assertEqual([row["wall_seconds"] for row in self.samples(path)], [5, 7, 5, 11])

    def test_disabled_and_invalid_destination_keep_asr_results(self):
        for setting in (None, self.directory / "missing-log"):
            if setting is not None: self.enable(setting)
            self.assertEqual(self.service.transcribe_audio(PRIVATE, "1.7b"), PRIVATE)
        self.assertFalse((self.directory / "missing-log").exists())
        self.assertEqual(self.model.generate.call_count, 2)

    def test_bundled_asr_imports_sibling_helper_without_source_on_sys_path(self):
        bundle = self.directory / "bundle/ASRRuntime"
        bundle.mkdir(parents=True)
        for source in (SCRIPTS / "qwen_asr_service.py", SCRIPTS / "scoreboard_timing.py"):
            shutil.copyfile(source, bundle / source.name)
        boot = """
import sys, types
sys.path.insert(0, sys.argv[1])
for name in ('numpy', 'soundfile', 'scipy', 'scipy.signal'):
    sys.modules[name] = types.ModuleType(name)
for name in ('butter', 'sosfilt', 'sosfiltfilt'):
    setattr(sys.modules['scipy.signal'], name, lambda *args, **kwargs: None)
import qwen_asr_service, scoreboard_timing
assert qwen_asr_service.measure is scoreboard_timing.measure
qwen_asr_service.INFERENCE_WORKER.shutdown()
print('sibling helper imported')
"""
        environment = dict(os.environ, TMPDIR=str(self.directory))
        environment.pop(timing.TIMINGS_ENV, None)
        result = subprocess.run([sys.executable, "-B", "-I", "-c", boot, str(bundle)],
                                env=environment, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "sibling helper imported\n")
        self.assertEqual(result.stderr, "")


class WorkerTests(TimingCase):
    def setUp(self):
        super().setUp()
        with patch.object(sys, "path", [str(SCRIPTS / "mlx_runtime"), *sys.path]), \
                contextlib.redirect_stdout(io.StringIO()):
            self.worker = load_script("timing_worker_under_test", SCRIPTS / "mlx_runtime/worker.py")
        self.runs = 0

    def run_worker(self, requests, failure=None, resume=False):
        """Run real main; replace only weights, reader thread and protocol sink."""
        commands, events, remaining = queue.Queue(), [], iter(requests)
        clock = self.clock

        def send(kind, request_id=None, **fields):
            events.append(dict(event=kind, id=request_id, **fields))
            if kind in ("ready", "done", "error"):
                commands.put(next(remaining, {"op": "shutdown"}))

        class Engine:
            def __init__(self, path):
                clock.advance(4, 1)
                if failure == "engine": raise RuntimeError(PRIVATE)

        class Generation:
            def __init__(self, engine, prompt, schema, **kwargs):
                clock.advance(2, 0.5)
                if failure == "init": raise RuntimeError(PRIVATE)
                self.identity = "1" * 64
                self.wire = self.text = PRIVATE
                self.thinking_count = self.final_count = self.steps = 0

            def step(self):
                clock.advance(3, 0.75)
                if failure == "step": raise RuntimeError(PRIVATE)
                self.steps += 1
                self.final_count += 1
                return "done" if self.steps == 2 else "prefill"

            def save(self, path): pass

            @classmethod
            def restore(cls, engine, path, expected_identity):
                clock.advance(6, 1.5)
                if failure == "restore": raise RuntimeError(PRIVATE)
                return cls(engine, PRIVATE, {}, prefix=PRIVATE)

        self.runs += 1
        state = self.directory / ("state-" + str(self.runs))
        if resume:
            state.mkdir()
            descriptor = os.open(state / ("1" * 64 + ".safetensors"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            os.close(descriptor)
        stubs = {
            "engine": module("engine", Engine=Engine, Generation=Generation),
            "schemas": module("schemas", note_schema=lambda data: {}, review_schema=lambda data: {}),
            "checks": module("checks", review_checks=lambda data: []),
        }
        reader = Mock(ident=None)
        reader.is_alive.return_value = False
        with patch.dict(sys.modules, stubs), patch.object(sys, "argv", [
                "worker", "--model", PRIVATE, "--state-directory", str(state),
                "--idle-model-seconds", "0", "--idle-cache-release-seconds", "0"]), \
                patch.object(sys, "stdin", SimpleNamespace(fileno=lambda: 0)), \
                patch.object(self.worker.queue, "Queue", return_value=commands), \
                patch.object(self.worker.threading, "Thread", return_value=reader), \
                patch.object(self.worker, "send", side_effect=send), \
                patch.object(self.worker, "discover_mlx", return_value=None), \
                patch.object(self.worker, "parse_review_input", return_value={}), \
                patch.object(self.worker, "bind_review_prompt", side_effect=lambda raw, prompt, data: prompt), \
                contextlib.redirect_stderr(io.StringIO()):
            self.worker.main()
        self.assertEqual(events[-1]["event"], "shutdown")
        self.assertEqual(events[-1]["state"], "ready_to_exit")
        return events

    @staticmethod
    def request(purpose="text", number=0):
        return dict(op="generate", id=PRIVATE + str(number), prompt=PRIVATE,
                    purpose=purpose, input="{}")

    def test_engine_init_and_every_step_use_fixed_purpose_buckets(self):
        path = self.log_file()
        self.enable(path)
        purposes = ("translation", "note", "review", "text", PRIVATE, {"private": PRIVATE})
        events = self.run_worker([self.request(purpose, index) for index, purpose in enumerate(purposes)])
        self.assertEqual(sum(event["event"] == "done" for event in events), len(purposes))
        rows = self.samples(path)
        self.assertEqual(rows[0]["stage"], "language_load")
        self.assertEqual(rows[0]["wall_seconds"], 4)
        self.assertEqual(rows[0]["process_cpu_seconds"], 1)
        self.assertEqual(len(rows), 1 + 3 * len(purposes))
        for index, purpose in enumerate(purposes):
            group = rows[1 + 3 * index:4 + 3 * index]
            self.assertEqual([row["stage"] for row in group], [timing.generation_stage(purpose)] * 3)
            self.assertEqual([row["wall_seconds"] for row in group], [2, 3, 3])
            self.assertEqual([row["process_cpu_seconds"] for row in group], [0.5, 0.75, 0.75])
            self.assertTrue(all(row["completed"] for row in group))

    def test_failed_engine_init_and_step_are_recorded(self):
        expected = {
            "engine": [("language_load", False)],
            "init": [("language_load", True), ("notes_step", False)],
            "step": [("language_load", True), ("notes_step", True), ("notes_step", False)],
        }
        for failure, stages in expected.items():
            with self.subTest(failure=failure):
                path = self.log_file(failure + ".jsonl")
                self.enable(path)
                events = self.run_worker([self.request("note")], failure=failure)
                self.assertEqual(sum(event["event"] == "error" for event in events), 1)
                self.assertEqual([(row["stage"], row["completed"]) for row in self.samples(path)], stages)

    def test_cold_restore_and_failed_restore_include_initialization_and_io(self):
        for failed in (False, True):
            with self.subTest(failed=failed):
                path = self.log_file("restore-" + str(failed) + ".jsonl")
                self.enable(path)
                request = dict(self.request("note"), prefix=PRIVATE)
                events = self.run_worker([request], failure="restore" if failed else None, resume=True)
                rows = self.samples(path)
                self.assertEqual([row["stage"] for row in rows], ["language_load"] + ["notes_step"] * 4)
                self.assertEqual([row["wall_seconds"] for row in rows], [4, 2, 6 if failed else 8, 3, 3])
                self.assertEqual([row["completed"] for row in rows], [True, True, not failed, True, True])
                self.assertEqual(sum(event["event"] == "done" for event in events), 1)
                self.assertEqual(sum(event["event"] == "checkpoint_rejected" for event in events), int(failed))

    def test_enabled_disabled_and_append_failure_leave_protocol_unchanged(self):
        requests = [self.request("note")]
        disabled = self.run_worker(requests)
        path = self.log_file()
        self.enable(path)
        self.assertEqual(self.run_worker(requests), disabled)
        self.assertEqual(len(self.samples(path)), 4)
        with patch.object(timing, "_append", side_effect=OSError(PRIVATE)):
            self.assertEqual(self.run_worker(requests), disabled)
        self.assertEqual(len(self.samples(path)), 4)

    def test_source_and_bundled_worker_import_without_scripts_on_sys_path(self):
        bundle = self.directory / "bundle/mlx_runtime"
        bundle.mkdir(parents=True)
        for source in (SCRIPTS / "mlx_runtime/worker.py", SCRIPTS / "mlx_runtime/review_diagnostics.py",
                       SCRIPTS / "scoreboard_timing.py"):
            shutil.copyfile(source, bundle / source.name)
        boot = "import sys; sys.path.insert(0,sys.argv[1]); stream=sys.stdout; import worker; sys.stdout=stream; print(worker.generation_stage('note'))"
        environment = dict(os.environ, TMPDIR=str(self.directory))
        environment.pop(timing.TIMINGS_ENV, None)
        for directory in (SCRIPTS / "mlx_runtime", bundle):
            with self.subTest(directory=str(directory)):
                result = subprocess.run([sys.executable, "-B", "-I", "-c", boot, str(directory)],
                                        env=environment, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "notes_step\n")
                self.assertEqual(result.stderr, "")


class ReleaseWithoutHelperTests(TimingCase):
    """Match release script selection, using isolated imports and fake weights."""

    def setUp(self):
        super().setUp()
        resources = self.directory / "LiveLingo.app/Contents/Resources"
        self.asr = resources / "ASRRuntime"
        self.language = resources / "LanguageRuntime"
        self.asr.mkdir(parents=True)
        self.language.mkdir()
        shutil.copyfile(SCRIPTS / "qwen_asr_service.py", self.asr / "qwen_asr_service.py")
        # Read the real allowlist without importing or executing the bundler.
        tree = ast.parse((SCRIPTS / "bundle-mlx-app.py").read_text())
        selection = next(node.value for node in tree.body if isinstance(node, ast.Assign)
                         and any(isinstance(target, ast.Name) and target.id == "RUNTIME_MODULES"
                                 for target in node.targets))
        self.runtime_modules = ast.literal_eval(selection)
        self.assertNotIn("scoreboard_timing.py", self.runtime_modules)
        for name in self.runtime_modules:
            self.assertEqual(Path(name).name, name)
            shutil.copyfile(SCRIPTS / "mlx_runtime" / name, self.language / name)
        self.assertEqual({path.name for path in self.asr.iterdir()}, {"qwen_asr_service.py"})
        self.assertEqual({path.name for path in self.language.iterdir()}, set(self.runtime_modules))
        self.assertFalse((resources / "scoreboard_timing.py").exists())
        self.fake_model = self.directory / "fake-model"
        self.fake_model.mkdir()

    def environment(self, path, enabled):
        result = dict(os.environ, TMPDIR=str(self.directory), LIVELINGO_ASR_MODELS=str(self.fake_model))
        result.pop(timing.TIMINGS_ENV, None)
        if enabled: result[timing.TIMINGS_ENV] = str(path)
        return result

    def retain(self, name, value):
        with (self.directory / name).open("x") as handle:
            json.dump(value, handle, indent=2)
            handle.write("\n")

    def test_release_asr_without_helper_imports_and_transcribes_with_either_env(self):
        boot = self.directory / "asr-bootstrap.py"
        boot.write_text('''
import contextlib, importlib.util, io, json, sys, types
from pathlib import Path
sys.path.insert(0, sys.argv[1])
assert importlib.util.find_spec('scoreboard_timing') is None
for name in ('numpy', 'soundfile', 'scipy', 'scipy.signal', 'mlx_audio', 'mlx_audio.stt', 'mlx_audio.stt.utils'):
    sys.modules[name] = types.ModuleType(name)
for name in ('butter', 'sosfilt', 'sosfiltfilt'):
    setattr(sys.modules['scipy.signal'], name, lambda *args, **kwargs: None)
loads = []
error = RuntimeError('artificial model failure')
class Model:
    calls = 0
    fail = False
    def generate(self, *args, **kwargs):
        self.calls += 1
        if self.fail: raise error
        assert kwargs == dict(language='English', max_tokens=256, temperature=0.0, verbose=False)
        return types.SimpleNamespace(text=' artificial result ')
model = Model()
def load_model(path):
    loads.append(path)
    return model
sys.modules['mlx_audio.stt.utils'].load_model = load_model
import qwen_asr_service as service
assert isinstance(service.measure('asr_load'), contextlib.nullcontext)
service.MODEL_PATHS = {'1.7b': Path(sys.argv[2])}
results = []
try:
    with contextlib.redirect_stdout(io.StringIO()):
        for request in ('cold', 'warm'):
            result = service.INFERENCE_WORKER.submit(service.run_registered_transcription,
                request, 'artificial.wav', '1.7b').result(timeout=5)
            assert result == 'artificial result'
            results.append(result)
        model.fail = True
        try:
            service.INFERENCE_WORKER.submit(service.run_registered_transcription,
                'failed', 'artificial.wav', '1.7b').result(timeout=5)
        except RuntimeError as caught:
            assert caught is error
        else:
            raise AssertionError('model failure was swallowed')
        snapshot = service.resource_snapshot()
        assert all(value['state'] == 'finished' for value in snapshot['requests'].values())
finally:
    service.INFERENCE_WORKER.shutdown()
print(json.dumps(dict(timings='unknown', load_calls=len(loads), model_calls=model.calls,
                     successful_calls=len(results), original_error_preserved=True)))
''')
        for enabled in (False, True):
            with self.subTest(enabled=enabled):
                path = self.log_file("asr-env-" + str(enabled) + ".jsonl")
                result = subprocess.run([sys.executable, "-B", "-I", str(boot), str(self.asr), str(self.fake_model)],
                                        env=self.environment(path, enabled), cwd=self.directory,
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, "")
                receipt = json.loads(result.stdout)
                self.assertEqual(receipt, dict(timings="unknown", load_calls=1, model_calls=3,
                                              successful_calls=2, original_error_preserved=True))
                self.assertEqual(path.read_bytes(), b"")
                self.retain("asr-env-" + str(enabled) + "-receipt.json",
                            dict(receipt, env_enabled=enabled, timing_file_bytes=path.stat().st_size,
                                 simulated_bundle=True, helper_present=False, returncode=result.returncode))

    def test_release_worker_without_helper_imports_and_runs_protocol_with_either_env(self):
        boot = self.directory / "worker-bootstrap.py"
        boot.write_text('''
import contextlib, hashlib, importlib.util, sys, types
sys.path.insert(0, sys.argv[1])
assert importlib.util.find_spec('scoreboard_timing') is None
class Engine:
    def __init__(self, path): pass
class Generation:
    def __init__(self, engine, prompt, schema, **kwargs):
        self.identity = hashlib.sha256(prompt.encode()).hexdigest()
        self.wire = self.text = 'artificial result'
        self.steps = self.thinking_count = self.final_count = 0
        self.fail = prompt == 'fail-step'
    def step(self):
        if self.fail: raise RuntimeError('artificial model failure')
        self.steps += 1
        self.final_count += 1
        return 'done' if self.steps == 2 else 'prefill'
engine = types.ModuleType('engine')
engine.Engine, engine.Generation = Engine, Generation
sys.modules['engine'] = engine
import worker
assert worker.generation_stage('text') is None
assert isinstance(worker.measure('language_load'), contextlib.nullcontext)
worker.discover_mlx = lambda: None
sys.argv = ['worker', '--model', 'artificial', '--state-directory', sys.argv[2],
            '--idle-model-seconds', '0', '--idle-cache-release-seconds', '0']
worker.main()
''')
        for enabled in (False, True):
            with self.subTest(enabled=enabled):
                path = self.log_file("worker-env-" + str(enabled) + ".jsonl")
                state = self.directory / ("state-env-" + str(enabled))
                process = subprocess.Popen([sys.executable, "-B", "-I", str(boot), str(self.language), str(state)],
                                           env=self.environment(path, enabled), cwd=self.directory,
                                           stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                pending, events = b"", []
                with selectors.DefaultSelector() as reader:
                    reader.register(process.stdout, selectors.EVENT_READ)

                    def until(kind):
                        nonlocal pending
                        deadline = time.monotonic() + 5
                        while True:
                            while b"\n" in pending:
                                line, pending = pending.split(b"\n", 1)
                                event = json.loads(line)
                                events.append(event)
                                if event.get("event") == kind: return event
                                self.assertNotEqual(event.get("event"), "error", event)
                            remaining = deadline - time.monotonic()
                            self.assertGreater(remaining, 0, "worker protocol timed out")
                            self.assertTrue(reader.select(remaining), "worker protocol timed out")
                            chunk = os.read(process.stdout.fileno(), 65536)
                            self.assertTrue(chunk, "worker closed protocol before " + kind)
                            pending += chunk

                    def send(**command):
                        process.stdin.write((json.dumps(command) + "\n").encode())
                        process.stdin.flush()

                    try:
                        self.assertEqual(until("ready")["version"], 2)
                        for request, prompt, outcome in (("first", "artificial", "done"),
                                                         ("failed", "fail-step", "error"),
                                                         ("recovery", "artificial", "done")):
                            send(op="generate", id=request, prompt=prompt, purpose="text")
                            event = until(outcome)
                            self.assertEqual(event["id"], request)
                            if outcome == "done":
                                self.assertEqual(event["text"], "artificial result")
                                send(op="ack", id=request)
                                self.assertEqual(until("ack")["state"], "released")
                        send(op="shutdown")
                        self.assertEqual(until("shutdown")["state"], "ready_to_exit")
                        process.stdin.close()
                        self.assertEqual(process.wait(timeout=5), 0)
                        stderr = process.stderr.read().decode()
                        self.assertNotIn("scoreboard_timing", stderr)
                        self.assertNotIn("Traceback", stderr)
                        self.assertEqual(path.read_bytes(), b"")
                        self.retain("worker-env-" + str(enabled) + "-receipt.json", dict(
                            timings="unknown", env_enabled=enabled, helper_present=False,
                            simulated_bundle=True, runtime_modules=list(self.runtime_modules),
                            events=[event["event"] for event in events],
                            completed_calls=sum(event["event"] == "done" for event in events),
                            failed_calls=sum(event["event"] == "error" for event in events),
                            returncode=process.returncode, timing_file_bytes=path.stat().st_size))
                    finally:
                        if process.poll() is None:
                            process.terminate()
                            try: process.wait(timeout=5)
                            except subprocess.TimeoutExpired:
                                process.kill()
                                process.wait(timeout=5)
                        for stream in (process.stdin, process.stdout, process.stderr): stream.close()


if __name__ == "__main__":
    unittest.main()
