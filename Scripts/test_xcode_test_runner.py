"""Test runner ownership, filtered evidence, and timeout cleanup with synthetic processes."""

import argparse
from contextlib import ExitStack
import importlib.util
import io
import json
from pathlib import Path
import signal
import subprocess
import tempfile
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import Mock, call, patch


def source_layout():
    directory = Path(__file__).resolve().parent
    # The runner resolves its output root; resolve here too so that the default
    # macOS TMPDIR (/var/folders -> /private/var/folders) yields the same keys.
    return directory.parent, directory / "run-xcode-tests.py", Path(tempfile.gettempdir()).resolve()


REPO, RUNNER_SOURCE, WORK = source_layout()
FILTER_SOURCE = REPO / "Scripts/run-preview-tool.py"
SYNTHETIC_UID = 4242
RUNNER_PID = 810000

FAILURE_OUTPUT = (
    "Build preparation\n"
    "EnvironmentVariables = {\n"
    "    TOKEN = SYNTHETIC_BRACE_TOKEN\n"
    "    NESTED = {\n"
    "        TOKEN = SYNTHETIC_NESTED_TOKEN\n"
    "    }\n"
    "}\n"
    "environment variables:\n"
    "    SYNTHETIC_INDENT_TOKEN\n"
    "    TOKEN = SYNTHETIC_INDENT_ASSIGNMENT\n"
    "\n"
    "export API_TOKEN=SYNTHETIC_EXPORT_TOKEN\n"
    "setenv BUILD_SECRET=SYNTHETIC_SETENV_TOKEN\n"
    "    BARE_SECRET = SYNTHETIC_ASSIGNMENT_TOKEN\n"
    "warning: environment unavailable SYNTHETIC_WARNING_TOKEN\n"
    "Test Case '-[SyntheticSuite testFails]' started.\n"
    "error: a synthetic test failed\n"
    "** TEST FAILED **\n"
)
FILTERED_FAILURE = (
    "Build preparation\n"
    "warning: [environment diagnostic omitted]\n"
    "Test Case '-[SyntheticSuite testFails]' started.\n"
    "error: a synthetic test failed\n"
    "** TEST FAILED **\n"
)
LAST_TEST = "Test Case '-[SyntheticSuite testFails]' started."
FORBIDDEN_OUTPUT = (
    "SYNTHETIC_BRACE_TOKEN",
    "SYNTHETIC_NESTED_TOKEN",
    "SYNTHETIC_INDENT_TOKEN",
    "SYNTHETIC_INDENT_ASSIGNMENT",
    "SYNTHETIC_EXPORT_TOKEN",
    "SYNTHETIC_SETENV_TOKEN",
    "SYNTHETIC_ASSIGNMENT_TOKEN",
    "SYNTHETIC_WARNING_TOKEN",
    "EnvironmentVariables =",
    "export API_TOKEN=",
    "setenv BUILD_SECRET=",
    "BARE_SECRET =",
)


def compile_module(name, source):
    module = ModuleType(name)
    module.__file__ = str(source)
    exec(compile(source.read_text(encoding="utf-8"), str(source), "exec"),
         module.__dict__)
    return module


def load_runner():
    redactor = compile_module("_synthetic_runner_redactor", FILTER_SOURCE)
    # Avoid executing a filesystem loader (which could write __pycache__).
    spec = SimpleNamespace(loader=SimpleNamespace(exec_module=lambda module: None))
    with patch.object(importlib.util, "spec_from_file_location", return_value=spec), \
            patch.object(importlib.util, "module_from_spec", return_value=redactor):
        runner = compile_module("_synthetic_xcode_runner", RUNNER_SOURCE)
    runner.REPO = REPO
    return runner


class InlineReader:
    """Deliver synthetic stdout at poll time without starting a real thread."""

    def __init__(self, *, target, daemon):
        self.target = target
        self.started = False
        self.done = False

    def start(self):
        self.started = True

    def deliver(self):
        if self.started and not self.done:
            self.done = True
            self.target()

    def join(self, timeout=None):
        self.deliver()


class RecordedWriter:
    """Record each chunk before the underlying file receives any bytes."""

    def __init__(self, stream, chunks):
        self.stream = stream
        self.chunks = chunks

    def __enter__(self):
        self.stream.__enter__()
        return self

    def __exit__(self, *args):
        return self.stream.__exit__(*args)

    def write(self, text):
        self.chunks.append(text)
        return self.stream.write(text)

    def writelines(self, lines):
        for line in lines:
            self.write(line)

    def __getattr__(self, name):
        return getattr(self.stream, name)


class RunnerHarness:
    """Confine main() to mock processes plus disposable synthetic evidence."""

    def __init__(self, case, *, exit_code=65, timeout=False, escalate=False):
        self.case = case
        self.runner = load_runner()
        self.temporary = tempfile.TemporaryDirectory(
            prefix=".unittest-xcode-runner-", dir=WORK)
        self.output = Path(self.temporary.name) / "evidence"
        self.output.mkdir()
        self.dd = Path("/synthetic/DerivedData")
        self.args = argparse.Namespace(
            name="synthetic", derived_data=self.dd, output_root=self.output,
            parallel="YES", workers=2, only=["SyntheticSuite/testFails"],
            action="test", keep_workers=False)
        self.timeout = timeout
        self.escalate = escalate
        self.exit_code = (-signal.SIGKILL if escalate else -signal.SIGTERM) \
            if timeout else exit_code
        self.guard_exit_code = 0
        self.guard_commands = []
        self.sandboxed = False
        self.now = 0.0
        self.launched = False
        self.sample_count = 0
        self.sample_pids = {RUNNER_PID}
        self.runner_row = (1, SYNTHETIC_UID, "/synthetic/xcodebuild")
        self.observed = {RUNNER_PID: self.runner_row}
        self.fresh = dict(self.observed)
        self.reader = None
        self.writes = {}
        self.lock_streams = []
        self.real_open = Path.open
        self.real_mkdir = Path.mkdir
        self.process = SimpleNamespace(
            pid=RUNNER_PID, stdout=io.StringIO(FAILURE_OUTPUT),
            poll=Mock(side_effect=self.poll), wait=Mock(side_effect=self.wait))
        # Replace the module's os reference, never patch.dict/copy os.environ.
        self.os = SimpleNamespace(
            environ={"SYNTHETIC_RUNNER_ENV": "literal-only"},
            getuid=Mock(return_value=SYNTHETIC_UID),
            getloadavg=Mock(return_value=(0.0, 0.0, 0.0)),
            kill=Mock(), killpg=Mock())
        self.subprocess = SimpleNamespace(
            PIPE=subprocess.PIPE, STDOUT=subprocess.STDOUT,
            TimeoutExpired=subprocess.TimeoutExpired,
            Popen=Mock(side_effect=self.popen),
            run=Mock(side_effect=self.run_subprocess),
            check_output=Mock(side_effect=AssertionError("real ps is forbidden")))
        self.printed = Mock()
        self.stack = ExitStack()

    def __enter__(self):
        replacements = {
            "os": self.os,
            "subprocess": self.subprocess,
            "processes": Mock(side_effect=self.process_table),
            "preference_events": Mock(return_value=([
                "TEST_PREFERENCE_CREATED suite=LiveLingo-Test-00000000-0000-0000-0000-000000000001\n",
                "TEST_PREFERENCE_CLEANED suite=LiveLingo-Test-00000000-0000-0000-0000-000000000001\n",
            ], ["synthetic preference audit"])),
            "retire_workers": Mock(return_value=["worker-810001-synthetic"]),
            "sandboxed_host": Mock(side_effect=lambda app: self.sandboxed),
            "threading": SimpleNamespace(Thread=self.make_reader),
            "time": SimpleNamespace(
                monotonic=lambda: self.now,
                sleep=Mock(side_effect=AssertionError("wall-clock sleep is forbidden"))),
            "fcntl": SimpleNamespace(
                LOCK_EX=2, LOCK_NB=4, flock=Mock()),
            "sys": SimpleNamespace(executable="/synthetic/python"),
        }
        for name, value in replacements.items():
            self.stack.enter_context(patch.object(self.runner, name, value))
        self.stack.enter_context(patch.object(
            self.runner, "print", self.printed, create=True))
        self.stack.enter_context(patch.object(
            argparse.ArgumentParser, "parse_args", return_value=self.args))
        # Path.home() must not consult the real HOME environment either.
        self.stack.enter_context(patch.object(
            Path, "home", return_value=Path("/synthetic/home")))
        self.stack.enter_context(patch.object(
            Path, "mkdir", autospec=True, side_effect=self.mkdir))
        self.stack.enter_context(patch.object(
            Path, "open", autospec=True, side_effect=self.open))
        return self

    def __exit__(self, *args):
        self.stack.close()
        for stream in self.lock_streams:
            stream.close()
        self.process.stdout.close()
        self.temporary.cleanup()

    def executable(self, dd=None, name="LiveLingo"):
        return str((self.dd if dd is None else dd) /
                   "Build/Products/Debug/LiveLingo.app/Contents/MacOS" / name)

    def mkdir(self, path, *args, **kwargs):
        if path in (self.dd, self.dd / "tmp"):
            return None
        self.case.assertEqual(path.resolve(), self.output.resolve())
        return self.real_mkdir(path, *args, **kwargs)

    def open(self, path, mode="r", buffering=-1, encoding=None,
             errors=None, newline=None):
        if path == self.dd / ".test-run.lock":
            self.case.assertEqual(mode, "a")
            stream = io.StringIO()
            self.lock_streams.append(stream)
            return stream
        self.case.assertTrue(path.resolve().is_relative_to(self.output.resolve()),
                             "runner attempted I/O outside synthetic evidence")
        stream = self.real_open(path, mode=mode, buffering=buffering,
                                encoding=encoding, errors=errors, newline=newline)
        if any(character in mode for character in "wax"):
            return RecordedWriter(stream, self.writes.setdefault(path, []))
        return stream

    def popen(self, command, **kwargs):
        self.case.assertEqual(command[0], "/usr/bin/xcodebuild")
        self.command = command
        self.case.assertEqual(kwargs["cwd"], REPO)
        self.case.assertTrue(kwargs["start_new_session"])
        self.case.assertEqual(kwargs["env"], {
            "SYNTHETIC_RUNNER_ENV": "literal-only",
            "TMPDIR": str(self.dd / "tmp"),
        })
        self.launched = True
        return self.process

    def make_reader(self, **kwargs):
        self.reader = InlineReader(**kwargs)
        return self.reader

    def poll(self):
        if self.timeout:
            self.now = 1800.0
        self.reader.deliver()
        return None if self.timeout else self.exit_code

    def wait(self, timeout=None):
        if self.escalate and timeout == 15:
            raise subprocess.TimeoutExpired(["synthetic-xcodebuild"], timeout)
        return self.exit_code

    def process_table(self):
        if not self.launched:
            return {}
        # Deliver a fresh identity snapshot only after all deadline samples.
        if self.timeout and self.sample_count >= len(self.sample_pids):
            return dict(self.fresh)
        return dict(self.observed)

    def run_subprocess(self, command, **kwargs):
        if command[:4] == ["/usr/bin/xcrun", "xcresulttool", "get", "log"]:
            self.case.assertIn("action", command)
            return SimpleNamespace(stdout=json.dumps({
                "testDetails": {"emittedOutput": FAILURE_OUTPUT}
            }), stderr="", returncode=0)
        if command[0] == "/usr/bin/sample":
            self.case.assertIn(int(command[1]), self.sample_pids,
                               "runner sampled a process it does not own")
            self.case.assertEqual(command[-1], "/dev/stdout")
            self.sample_count += 1
            return SimpleNamespace(stdout=FAILURE_OUTPUT, returncode=0)
        self.case.assertEqual(command[0], "/synthetic/python")
        self.case.assertIn(Path(command[1]).name,
                           ("check_build_warnings.py", "check_test_preferences.py"))
        filename = "synthetic-preferences.log" if Path(command[1]).name == "check_test_preferences.py" else "synthetic.log"
        self.case.assertEqual(command[2], str(self.output / filename))
        self.guard_commands.append(command)
        return SimpleNamespace(stdout=FAILURE_OUTPUT, returncode=self.guard_exit_code)

    def receipt(self):
        return json.loads((self.output / "synthetic.json").read_text(encoding="utf-8"))

    def assert_filtered_writes(self):
        self.case.assertTrue(self.writes)
        for path, chunks in self.writes.items():
            for chunk in chunks:
                for forbidden in FORBIDDEN_OUTPUT:
                    self.case.assertNotIn(forbidden, chunk,
                                          "unfiltered data reached a file write")
            persisted = path.read_text(encoding="utf-8")
            for forbidden in FORBIDDEN_OUTPUT:
                self.case.assertNotIn(forbidden, persisted)
        for printed in self.printed.call_args_list:
            for forbidden in FORBIDDEN_OUTPUT:
                self.case.assertNotIn(forbidden, str(printed))
        self.case.assertFalse(self.dd.exists(), "a real DerivedData directory was created")


class ProcessOwnershipTests(unittest.TestCase):
    def setUp(self):
        self.runner = load_runner()
        self.dd = Path("/synthetic/DerivedData with space")
        self.runner.DD = self.dd
        self.runner.os = SimpleNamespace(getuid=Mock(return_value=SYNTHETIC_UID))

    def executable(self, dd=None, name="LiveLingo"):
        return str((self.dd if dd is None else dd) /
                   "Build/Products/Debug/LiveLingo.app/Contents/MacOS" / name)

    def test_process_table_preserves_uid_and_executable_path_with_spaces(self):
        executable = self.executable()
        rows = ("  PID  PPID   UID COMM\n"
                f"810001 810000 4242 {executable}\n"
                "810002 1 4243 /synthetic/Other Host\n"
                "\n")
        check_output = Mock(return_value=rows)
        self.runner.subprocess = SimpleNamespace(check_output=check_output)
        self.assertEqual(self.runner.processes(), {
            810001: (810000, 4242, executable),
            810002: (1, 4243, "/synthetic/Other Host"),
        })
        check_output.assert_called_once_with(
            ["/bin/ps", "-axo", "pid,ppid,uid,comm"], text=True)

    def test_owned_hosts_accepts_current_build_and_exact_executable(self):
        first = (RUNNER_PID, SYNTHETIC_UID, self.executable())
        clone = (RUNNER_PID, SYNTHETIC_UID, str(self.dd /
                 "Build/Products/Debug/LiveLingo (2).app/Contents/MacOS/LiveLingo"))
        self.runner.processes = Mock(return_value={810001: first, 810002: clone})
        self.assertEqual(self.runner.owned_hosts(), {810001: first, 810002: clone})

    def test_owned_hosts_excludes_other_build_prefix_uid_and_executable(self):
        rejected = {
            "another build": self.executable(Path("/synthetic/other DerivedData")),
            "same-prefix DerivedData": self.executable(Path(str(self.dd) + "-other")),
            "same-prefix Products": str(self.dd /
                "Build/Products-other/Debug/LiveLingo.app/Contents/MacOS/LiveLingo"),
            "outside Products": str(self.dd /
                "Logs/LiveLingo.app/Contents/MacOS/LiveLingo"),
            "executable suffix": self.executable(name="LiveLingoHelper"),
            "executable prefix": self.executable(name="OtherLiveLingo"),
            "different executable": self.executable(name="Other"),
            "relative path": "Build/Products/Debug/LiveLingo.app/Contents/MacOS/LiveLingo",
        }
        accepted = (RUNNER_PID, SYNTHETIC_UID, self.executable())
        for label, executable in rejected.items():
            with self.subTest(label=label):
                self.runner.processes = Mock(return_value={
                    810001: accepted,
                    810002: (RUNNER_PID, SYNTHETIC_UID, executable),
                    810003: (RUNNER_PID, SYNTHETIC_UID + 1, self.executable()),
                })
                self.assertEqual(self.runner.owned_hosts(), {810001: accepted})

    def test_owned_hosts_rejects_paths_escaping_products_or_derived_data(self):
        escaped_paths = (
            str(self.dd) + "/Build/Products/../OtherProducts/Debug/"
            "LiveLingo.app/Contents/MacOS/LiveLingo",
            str(self.dd) + "/Build/Products/../../../other DerivedData/"
            "Build/Products/Debug/LiveLingo.app/Contents/MacOS/LiveLingo",
        )
        for executable in escaped_paths:
            with self.subTest(executable=executable):
                self.runner.processes = Mock(return_value={
                    810001: (RUNNER_PID, SYNTHETIC_UID, executable),
                })
                self.assertEqual(self.runner.owned_hosts(), {})


class FilteringTests(unittest.TestCase):
    def setUp(self):
        self.filtered = load_runner().redact.filtered

    def test_failure_diagnostics_survive_environment_and_assignment_filtering(self):
        self.assertEqual("".join(self.filtered(iter(FAILURE_OUTPUT.splitlines(True)))),
                         FILTERED_FAILURE)

    def test_all_supported_assignment_forms_are_filtered(self):
        lines = ("TOKEN=SYNTHETIC_ONE\n", "  export TOKEN = SYNTHETIC_TWO\n",
                 "setenv TOKEN=SYNTHETIC_THREE\n", "_TOKEN_2 = SYNTHETIC_FOUR\n",
                 "error: expected TOKEN=value in a synthetic assertion\n")
        self.assertEqual(list(self.filtered(iter(lines))), [lines[-1]])

    def test_environment_heading_variants_are_filtered(self):
        for heading in ("environment", "Environment variables", "EnvironmentVariables", "SetEnv"):
            with self.subTest(heading=heading):
                lines = (heading + " {\n", "  SYNTHETIC_BODY\n", "}\n", "error: retained\n")
                self.assertEqual(list(self.filtered(iter(lines))), ["error: retained\n"])

    def test_indented_environment_ends_at_same_indent_without_blank_line(self):
        lines = ("  environment variables:\n", "    SYNTHETIC_BODY\n",
                 "  error: retained\n", "ordinary diagnostic\n")
        self.assertEqual(list(self.filtered(iter(lines))), list(lines[-2:]))

    def test_unterminated_environment_at_eof_never_leaks_partial_body(self):
        cases = (
            ("safe diagnostic\n", "EnvironmentVariables {\n", " SYNTHETIC_BODY\n"),
            ("safe diagnostic\n", "environment:\n", " SYNTHETIC_BODY\n"),
        )
        for lines in cases:
            with self.subTest(heading=lines[1]):
                self.assertEqual(list(self.filtered(iter(lines))), ["safe diagnostic\n"])

    def test_environment_warning_is_replaced_without_losing_warning_signal(self):
        self.assertEqual(list(self.filtered(iter((
            "warning: SetEnv { SYNTHETIC_INLINE }\n", "error: retained\n")))),
            ["warning: [environment diagnostic omitted]\n", "error: retained\n"])


class PreferenceAuditTests(unittest.TestCase):
    def test_only_new_observed_hosts_contribute_complete_events(self):
        runner = load_runner()
        event = "TEST_PREFERENCE_CREATED suite=LiveLingo-Test-00000000-0000-0000-0000-000000000001\n"
        with tempfile.TemporaryDirectory(dir=WORK) as temporary:
            scratch = Path(temporary)
            old = scratch / "worker-810001-00000000-0000-0000-0000-000000000001"
            current = scratch / "worker-810001-00000000-0000-0000-0000-000000000002"
            other = scratch / "worker-810002-00000000-0000-0000-0000-000000000003"
            for directory in (old, current, other):
                directory.mkdir()
            (old / "test-preferences.events").write_text("old run must not be read\n")
            (other / "test-preferences.events").write_text("unobserved host must not be read\n")
            path = current / "test-preferences.events"
            path.write_text(event)
            self.assertEqual(runner.preference_events(scratch, {810001}, {old.name}),
                             ([event], [str(path)]))

    def test_symlink_or_malformed_audit_fails_without_reading_replacement(self):
        runner = load_runner()
        with tempfile.TemporaryDirectory(dir=WORK) as temporary:
            scratch = Path(temporary)
            worker = scratch / "worker-810001-00000000-0000-0000-0000-000000000001"
            worker.mkdir()
            target = scratch / "replacement"
            target.write_text("synthetic replacement content\n")
            path = worker / "test-preferences.events"
            path.symlink_to(target)
            with self.assertRaisesRegex(ValueError, "invalid preference audit file"):
                runner.preference_events(scratch, {810001}, set())
            self.assertEqual(target.read_text(), "synthetic replacement content\n")
            # Remove only the link owned by this disposable synthetic fixture.
            path.unlink()
            path.write_text("malformed synthetic event\n")
            with self.assertRaisesRegex(ValueError, "invalid preference audit event"):
                runner.preference_events(scratch, {810001}, set())


class HostOutputTests(unittest.TestCase):
    def test_outer_host_output_is_not_repeated_by_child_activities(self):
        runner = load_runner()
        section = {
            "testDetails": {"emittedOutput": "synthetic outer output\n"},
            "subsections": [{"testDetails": {"emittedOutput": "duplicate child output\n"}}],
            "commandInvocationDetails": {"emittedOutput": "unrelated metadata"},
        }
        self.assertEqual(list(runner.test_host_output(section)), ["synthetic outer output\n"])

    def test_independent_hosts_are_retained_and_non_test_metadata_is_ignored(self):
        runner = load_runner()
        section = {"subsections": [
            {"testDetails": {"emittedOutput": "first host\n"}},
            {"testDetails": {"wasSkipped": False}, "subsections": [
                {"testDetails": {"emittedOutput": "second host\n"}}]},
            {"commandInvocationDetails": {"emittedOutput": "unrelated metadata"}},
        ]}
        self.assertEqual(list(runner.test_host_output(section)), ["first host\n", "second host\n"])


class RunnerEvidenceTests(unittest.TestCase):
    def test_failed_build_filters_every_write_before_disk_and_retains_failure(self):
        with RunnerHarness(self, exit_code=65) as harness:
            self.assertEqual(harness.runner.main(), 65)
            self.assertEqual((harness.output / "synthetic.log").read_text(), FILTERED_FAILURE)
            self.assertEqual(harness.writes[harness.output / "synthetic.log"],
                             FILTERED_FAILURE.splitlines(True))
            receipt = harness.receipt()
            self.assertEqual(receipt["exit_code"], 65)
            self.assertFalse(receipt["timed_out"])
            self.assertEqual(receipt["last_test"], LAST_TEST)
            harness.subprocess.Popen.assert_called_once()
            harness.subprocess.run.assert_not_called()
            harness.os.kill.assert_not_called()
            harness.os.killpg.assert_not_called()
            harness.assert_filtered_writes()

    def test_failing_guards_filter_both_files_and_printed_diagnostics(self):
        with RunnerHarness(self, exit_code=0) as harness:
            harness.guard_exit_code = 1
            self.assertEqual(harness.runner.main(), 1)
            for name in ("check_build_warnings", "check_test_preferences"):
                self.assertEqual((harness.output / f"synthetic-{name}.txt").read_text(),
                                 FILTERED_FAILURE)
            receipt = harness.receipt()
            self.assertEqual(receipt["exit_code"], 0)
            self.assertEqual([guard["exit_code"] for guard in receipt["guards"]], [1, 1])
            self.assertEqual(harness.subprocess.run.call_count, 3)
            self.assertEqual(receipt["host_output_source"],
                             "xcresult action log testDetails.emittedOutput")
            self.assertEqual((harness.output / "synthetic.log").read_text(),
                             FILTERED_FAILURE + FILTERED_FAILURE + "\n")
            harness.assert_filtered_writes()

    def test_duplicate_log_name_preserves_all_existing_evidence_before_launch(self):
        with RunnerHarness(self) as harness:
            filenames = ("synthetic.log", "synthetic.json", "synthetic.pid",
                         f"synthetic-sample-1-pid{RUNNER_PID}.txt",
                         "synthetic-check_build_warnings.txt")
            for name in filenames:
                (harness.output / name).write_text("previous synthetic evidence\n")
            old_result = harness.output / "synthetic.xcresult"
            # Use the saved method: the harness intentionally permits no runner mkdir here.
            harness.real_mkdir(old_result)
            (old_result / "previous.txt").write_text("previous synthetic result\n")
            paths = [harness.output / name for name in filenames] + [old_result / "previous.txt"]
            before = {path: path.read_bytes() for path in paths}
            harness.writes.clear()
            with self.assertRaises(FileExistsError):
                harness.runner.main()
            self.assertEqual({path: path.read_bytes() for path in paths}, before)
            harness.subprocess.Popen.assert_not_called()
            harness.subprocess.run.assert_not_called()
            harness.os.kill.assert_not_called()
            harness.os.killpg.assert_not_called()
            self.assertEqual(harness.writes, {})
            self.assertFalse(harness.dd.exists())

    def test_duplicate_sample_name_does_not_truncate_existing_stack_evidence(self):
        with RunnerHarness(self, timeout=True) as harness:
            sample = harness.output / f"synthetic-sample-1-pid{RUNNER_PID}.txt"
            sample.write_text("previous synthetic stack\n")
            harness.writes.clear()
            self.assertEqual(harness.runner.main(), 124)
            self.assertEqual(sample.read_text(), "previous synthetic stack\n")
            self.assertNotIn(sample, harness.writes)
            harness.os.killpg.assert_called_once_with(RUNNER_PID, signal.SIGTERM)
            self.assertEqual(harness.receipt()["samples"][0]["error"],
                             "sample evidence already exists")
            harness.assert_filtered_writes()


class GateAndCleanupTests(unittest.TestCase):
    def test_full_run_cleans_before_testing_and_requires_compile_and_events(self):
        with RunnerHarness(self, exit_code=0) as harness:
            harness.args.only = []
            self.assertEqual(harness.runner.main(), 0)
            command = harness.command
            start = command.index("CODE_SIGNING_ALLOWED=NO") + 1
            self.assertEqual(command[start:start + 2], ["clean", "test"])
            self.assertFalse(any(item.startswith("-only-testing") for item in command))
            warnings, preferences = harness.guard_commands
            self.assertEqual(warnings[3:], ["--require-compiled-targets", "LiveLingo", "LiveLingoTests"])
            self.assertEqual(preferences[3:], [])
            self.assertFalse(harness.runner.preference_events.call_args.kwargs["allow_empty"])
            harness.runner.retire_workers.assert_called_once()
            self.assertEqual(harness.receipt()["removed_workers"], ["worker-810001-synthetic"])

    def test_focused_run_may_have_no_suites_but_still_requires_full_compile(self):
        with RunnerHarness(self, exit_code=0) as harness:
            self.assertEqual(harness.runner.main(), 0)
            command = harness.command
            start = command.index("CODE_SIGNING_ALLOWED=NO") + 1
            self.assertEqual(command[start:start + 2], ["clean", "test"])
            self.assertEqual(command[-1], "-only-testing:SyntheticSuite/testFails")
            warnings, preferences = harness.guard_commands
            self.assertEqual(warnings[3:], ["--require-compiled-targets", "LiveLingo", "LiveLingoTests"])
            self.assertEqual(preferences[3:], ["--allow-no-events"])
            self.assertTrue(harness.runner.preference_events.call_args.kwargs["allow_empty"])

    def test_failed_guard_or_keep_flag_retains_worker_directories(self):
        with RunnerHarness(self, exit_code=0) as harness:
            harness.guard_exit_code = 1
            self.assertEqual(harness.runner.main(), 1)
            harness.runner.retire_workers.assert_not_called()
            self.assertNotIn("removed_workers", harness.receipt())
        with RunnerHarness(self, exit_code=0) as harness:
            harness.args.keep_workers = True
            self.assertEqual(harness.runner.main(), 0)
            harness.runner.retire_workers.assert_not_called()

    def test_without_building_refuses_a_sandboxed_host_before_launch(self):
        with RunnerHarness(self, exit_code=0) as harness:
            harness.args.action = "test-without-building"
            harness.sandboxed = True
            with patch("sys.stderr", io.StringIO()), self.assertRaises(SystemExit):
                harness.runner.main()
            harness.subprocess.Popen.assert_not_called()
        with RunnerHarness(self, exit_code=0) as harness:
            harness.args.action = "test-without-building"
            # Nothing is compiled: the warning gate must fail on its own log.
            harness.guard_exit_code = 1
            self.assertEqual(harness.runner.main(), 1)
            command = harness.command
            self.assertEqual(command[command.index("CODE_SIGNING_ALLOWED=NO") + 1], "test-without-building")
            self.assertNotIn("clean", command)


class WorkerDirectoryTests(unittest.TestCase):
    def layout(self, scratch):
        names = {
            "old": "worker-810001-00000000-0000-0000-0000-000000000001",
            "current": "worker-810001-00000000-0000-0000-0000-000000000002",
            "other": "worker-810002-00000000-0000-0000-0000-000000000003",
        }
        paths = {key: scratch / name for key, name in names.items()}
        for path in paths.values():
            path.mkdir()
            (path / "screenshots").mkdir()
            (path / "screenshots" / "synthetic.png").write_bytes(b"synthetic")
        return paths

    def test_focused_empty_audit_requires_an_attributed_worker_and_no_strangers(self):
        runner = load_runner()
        with tempfile.TemporaryDirectory(dir=WORK) as temporary:
            scratch = Path(temporary)
            paths = self.layout(scratch)
            previous = {paths["old"].name}
            with self.assertRaisesRegex(ValueError, "no preference audit events"):
                runner.preference_events(scratch, {810001}, previous)
            with self.assertRaisesRegex(ValueError, "no preference audit events"):
                runner.preference_events(scratch, {810001}, previous, allow_empty=True)
            previous.add(paths["other"].name)
            self.assertEqual(runner.preference_events(scratch, {810001}, previous, allow_empty=True),
                             ([], []))
            with self.assertRaisesRegex(ValueError, "no preference audit events"):
                runner.preference_events(scratch, {810009}, previous, allow_empty=True)

    def test_retire_removes_only_this_invocations_observed_workers(self):
        runner = load_runner()
        with tempfile.TemporaryDirectory(dir=WORK) as temporary:
            scratch = Path(temporary) / "tmp"
            scratch.mkdir()
            outside = Path(temporary) / "outside"
            outside.mkdir()
            (outside / "keep.txt").write_text("synthetic outside content\n")
            paths = self.layout(scratch)
            link = scratch / "worker-810001-00000000-0000-0000-0000-000000000004"
            link.symlink_to(outside, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "invalid worker directory"):
                runner.retire_workers(scratch, {810001}, {paths["old"].name})
            self.assertTrue((outside / "keep.txt").exists())
            link.unlink()
            self.assertEqual(runner.retire_workers(scratch, {810001}, {paths["old"].name}),
                             [paths["current"].name])
            self.assertFalse(paths["current"].exists())
            self.assertTrue((paths["old"] / "screenshots" / "synthetic.png").exists())
            self.assertTrue((paths["other"] / "screenshots" / "synthetic.png").exists())
            self.assertTrue((outside / "keep.txt").exists())


class TimeoutTerminationTests(unittest.TestCase):
    def test_sample_timeout_preserves_filtered_partial_output_and_still_stops_runner(self):
        with RunnerHarness(self, timeout=True) as harness:
            original = harness.run_subprocess

            def timed_out(command, **kwargs):
                result = original(command, **kwargs)
                if command[0] == "/usr/bin/sample":
                    raise subprocess.TimeoutExpired(command, 20, output=FAILURE_OUTPUT)
                return result

            harness.subprocess.run.side_effect = timed_out
            self.assertEqual(harness.runner.main(), 124)
            sample = harness.receipt()["samples"][0]
            self.assertEqual(sample["error"], "sample timeout")
            self.assertEqual(Path(sample["path"]).read_text(), FILTERED_FAILURE)
            harness.os.killpg.assert_called_once_with(RUNNER_PID, signal.SIGTERM)
            harness.assert_filtered_writes()

    def test_sample_launch_failure_does_not_disable_deadline_cleanup(self):
        with RunnerHarness(self, timeout=True) as harness:
            original = harness.run_subprocess

            def unavailable(command, **kwargs):
                result = original(command, **kwargs)
                if command[0] == "/usr/bin/sample":
                    raise OSError("synthetic diagnostic failure")
                return result

            harness.subprocess.run.side_effect = unavailable
            self.assertEqual(harness.runner.main(), 124)
            self.assertEqual(harness.receipt()["samples"][0]["error"], "sample invocation failed")
            harness.os.killpg.assert_called_once_with(RUNNER_PID, signal.SIGTERM)
            harness.assert_filtered_writes()

    def test_timeout_rechecks_uid_executable_parent_and_missing_pid_before_term(self):
        with RunnerHarness(self, timeout=True) as harness:
            owned = {pid: (RUNNER_PID, SYNTHETIC_UID, harness.executable())
                     for pid in (810001, 810002, 810003, 810004, 810005)}
            unrelated = {
                810011: (RUNNER_PID, SYNTHETIC_UID,
                         harness.executable(Path("/synthetic/other DerivedData"))),
                810012: (RUNNER_PID, SYNTHETIC_UID,
                         harness.executable(Path(str(harness.dd) + "-neighbor"))),
                810013: (RUNNER_PID, SYNTHETIC_UID + 1, harness.executable()),
                810014: (RUNNER_PID, SYNTHETIC_UID, harness.executable(name="LiveLingoHelper")),
            }
            harness.observed.update(owned | unrelated)
            harness.sample_pids |= set(owned)
            harness.fresh = dict(harness.observed)
            harness.fresh[810002] = (RUNNER_PID, SYNTHETIC_UID + 1, harness.executable())
            harness.fresh[810003] = (RUNNER_PID, SYNTHETIC_UID,
                                    harness.executable(Path("/synthetic/other DerivedData")))
            harness.fresh[810004] = (999999, SYNTHETIC_UID, harness.executable())
            del harness.fresh[810005]
            self.assertEqual(harness.runner.main(), 124)
            self.assertEqual(harness.os.kill.call_args_list, [call(810001, signal.SIGTERM)])
            self.assertEqual(harness.os.killpg.call_args_list,
                             [call(RUNNER_PID, signal.SIGTERM)])
            self.assertEqual(harness.process.wait.call_args_list, [call(timeout=15), call()])
            receipt = harness.receipt()
            self.assertTrue(receipt["timed_out"])
            self.assertEqual(receipt["exit_code"], -signal.SIGTERM)
            self.assertEqual({host["pid"] for host in receipt["host_identities"]}, set(owned))
            self.assertEqual({sample["pid"] for sample in receipt["samples"]},
                             harness.sample_pids)
            self.assertTrue(all(sample["reason"] == "30 minute deadline"
                                for sample in receipt["samples"]))
            for sample in receipt["samples"]:
                self.assertEqual(Path(sample["path"]).read_text(), FILTERED_FAILURE)
            harness.assert_filtered_writes()

    def test_timeout_escalates_only_mock_owned_process_group_after_wait_expires(self):
        with RunnerHarness(self, timeout=True, escalate=True) as harness:
            self.assertEqual(harness.runner.main(), 124)
            harness.os.kill.assert_not_called()
            self.assertEqual(harness.os.killpg.call_args_list, [
                call(RUNNER_PID, signal.SIGTERM), call(RUNNER_PID, signal.SIGKILL),
            ])
            self.assertEqual(harness.process.wait.call_args_list, [call(timeout=15), call()])
            self.assertTrue(harness.receipt()["timed_out"])
            self.assertEqual(harness.receipt()["exit_code"], -signal.SIGKILL)
            harness.assert_filtered_writes()

    def test_host_disappearing_at_term_does_not_prevent_group_cleanup(self):
        with RunnerHarness(self, timeout=True) as harness:
            host = (RUNNER_PID, SYNTHETIC_UID, harness.executable())
            harness.observed[810001] = host
            harness.fresh[810001] = host
            harness.sample_pids.add(810001)
            harness.os.kill.side_effect = ProcessLookupError("synthetic vanished host")
            self.assertEqual(harness.runner.main(), 124)
            harness.os.kill.assert_called_once_with(810001, signal.SIGTERM)
            harness.os.killpg.assert_called_once_with(RUNNER_PID, signal.SIGTERM)
            harness.assert_filtered_writes()


if __name__ == "__main__":
    unittest.main()
