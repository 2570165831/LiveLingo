"""Synthetic CLI failures only; subprocess tripwires forbid data and runtimes.

Keep temporary fixtures for inspection. Before the shared helper is introduced,
the parser unit probes deliberately use argparse to demonstrate the baseline.
The separate existence check prevents that fallback from hiding a missing fix.
"""
import argparse
import builtins
from contextlib import redirect_stderr, redirect_stdout
import importlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
import wave


ROOT = Path(__file__).resolve().parents[1]
CANARY = "SYNTHETIC_PRIVATE_ARG_R10_8CC1_正文\nCANARY_CONTINUED"
PROGRAM_CANARY = "SYNTHETIC_PRIVATE_PROGRAM_R10"
FIXED_ERROR = "invalid_arguments; use --help for usage."
RECOVERY_ERROR = ("参数无效：必须显式指定 --root；导出还需 --export 和 --output。"
                  "请用 --help 查看用法。")
OWNED_ENTRIES = {"benchmark", "scorer", "calibrate", "classroom_metrics", "energy",
                 "metrics", "prefix_cache", "checkpoints"}

try:
    from Scripts.privacy_cli import PrivateArgumentParser
except ModuleNotFoundError as error:
    if error.name != "Scripts.privacy_cli":
        raise
    PrivateArgumentParser = argparse.ArgumentParser


class PrivateParserTests(unittest.TestCase):
    def parser(self, **kwargs):
        return PrivateArgumentParser(prog="synthetic-cli", **kwargs)

    def rejected(self, parser, argv):
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(sys, "argv", [PROGRAM_CANARY, *argv]), \
             redirect_stdout(stdout), redirect_stderr(stderr):
            with self.assertRaises(SystemExit) as exited:
                parser.parse_args(argv)
        self.assertEqual(exited.exception.code, 2)
        self.assertEqual(stdout.getvalue(), "")
        self.assertNotIn(CANARY, stderr.getvalue())
        self.assertNotIn(PROGRAM_CANARY, stderr.getvalue())
        self.assertIn(FIXED_ERROR, stderr.getvalue())
        self.assertIn("usage: synthetic-cli", stderr.getvalue())
        return stderr.getvalue()

    def test_shared_helper_exists(self):
        self.assertNotEqual(PrivateArgumentParser, argparse.ArgumentParser)

    def test_prog_must_be_explicit(self):
        with patch.object(sys, "argv", [PROGRAM_CANARY]):
            with self.assertRaises(TypeError):
                PrivateArgumentParser()

    def test_unknown_option(self):
        self.rejected(self.parser(), ["--" + CANARY])

    def test_unknown_positional(self):
        self.rejected(self.parser(), [CANARY])

    def test_invalid_integer(self):
        parser = self.parser()
        parser.add_argument("--count", type=int)
        self.rejected(parser, ["--count", CANARY])

    def test_invalid_float(self):
        parser = self.parser()
        parser.add_argument("--seconds", type=float)
        self.rejected(parser, ["--seconds", CANARY])

    def test_invalid_choice(self):
        parser = self.parser()
        parser.add_argument("--target", choices=("en", "zh-Hans"))
        self.rejected(parser, ["--target", CANARY])

    def test_missing_required_option(self):
        parser = self.parser()
        parser.add_argument("--input", required=True)
        self.rejected(parser, [])

    def test_missing_option_value(self):
        parser = self.parser()
        parser.add_argument("--input")
        self.rejected(parser, ["--input"])

    def test_missing_required_positional(self):
        parser = self.parser()
        parser.add_argument("input")
        self.rejected(parser, [])

    def test_invalid_positional_type(self):
        parser = self.parser()
        parser.add_argument("count", type=int)
        self.rejected(parser, [CANARY])

    def test_invalid_positional_choice(self):
        parser = self.parser()
        parser.add_argument("target", choices=("en", "zh-Hans"))
        self.rejected(parser, [CANARY])

    def test_missing_subcommand(self):
        parser = self.parser()
        parser.add_subparsers(required=True).add_parser("check")
        self.rejected(parser, [])

    def test_unknown_subcommand(self):
        parser = self.parser()
        parser.add_subparsers(required=True).add_parser("check")
        self.rejected(parser, [CANARY])

    def test_subparser_inherits_private_parser(self):
        parser = self.parser()
        child = parser.add_subparsers(required=True).add_parser("check")
        self.assertIsInstance(child, PrivateArgumentParser)
        child.add_argument("--count", type=int)
        self.rejected(parser, ["check", "--count", CANARY])

    def test_argument_type_exception(self):
        def invalid(value):
            raise argparse.ArgumentTypeError(value)
        parser = self.parser()
        parser.add_argument("--input", type=invalid)
        self.rejected(parser, ["--input", CANARY])

    def test_exit_on_error_false_cannot_expose_argument_error(self):
        parser = self.parser(exit_on_error=False)
        parser.add_argument("--count", type=int)
        self.rejected(parser, ["--count", CANARY])

    def test_error_method_discards_free_message(self):
        stderr = io.StringIO()
        with redirect_stderr(stderr), self.assertRaises(SystemExit) as exited:
            self.parser().error(CANARY)
        self.assertEqual(exited.exception.code, 2)
        self.assertNotIn(CANARY, stderr.getvalue())
        self.assertIn(FIXED_ERROR, stderr.getvalue())

    def test_sensitive_argv_zero_is_absent_from_help(self):
        stdout = io.StringIO()
        with patch.object(sys, "argv", [PROGRAM_CANARY, "--help"]), \
             redirect_stdout(stdout), self.assertRaises(SystemExit) as exited:
            self.parser().parse_args(["--help"])
        self.assertEqual(exited.exception.code, 0)
        self.assertNotIn(PROGRAM_CANARY, stdout.getvalue())
        self.assertIn("synthetic-cli", stdout.getvalue())

    def test_valid_values_and_abbreviations_are_preserved(self):
        parser = self.parser()
        parser.add_argument("--count", type=int, required=True)
        parser.add_argument("--target", choices=("en", "zh-Hans"), default="en")
        self.assertEqual(vars(parser.parse_args(["--cou", "3"])),
                         {"count": 3, "target": "en"})


# No process environment is inherited or inspected. The audit hook also rejects
# a regression which would reach a model, input artifact, build or network call.
PROBE = r'''
import importlib.abc
import os
from pathlib import Path
import runpy
import sys

mode, root, entry, argv_zero, *arguments = sys.argv[1:]
if mode == "alias":
    sys.path.insert(0, str(Path(root) / "Scripts"))
else:
    sys.path[:0] = [root, str(Path(root) / "Scripts")]
sys.dont_write_bytecode = True
code_rules = Path(root) / "Fixtures/scoreboard-v1/normalizer-v1.json"

class NoRuntime(importlib.abc.MetaPathFinder):
    def find_spec(self, fullname, path=None, target=None):
        if fullname.split(".")[0] in {
            "mlx", "mlx_lm", "mlx_audio", "numpy", "torch", "transformers",
            "huggingface_hub", "engine", "qwen_asr_service",
        }:
            raise AssertionError("BLOCKED_RUNTIME")

sys.meta_path.insert(0, NoRuntime())

def audit(event, values):
    if event.startswith("socket.") or event in {
        "subprocess.Popen", "os.system", "os.posix_spawn", "os.mkdir",
        "os.remove", "os.rmdir", "os.rename", "os.chmod", "os.chown",
    }:
        raise AssertionError("BLOCKED_SIDE_EFFECT")
    if event == "open":
        name, mode, flags = values
        if flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND):
            raise AssertionError("BLOCKED_WRITE")
        if isinstance(name, (str, bytes)):
            artifact = Path(os.fsdecode(name))
            if artifact.suffix in {".json", ".jsonl", ".wav", ".plist", ".txt", ".safetensors"}:
                # scoreboard_metrics imports this fixed public code rule set.
                # No selected input, other JSON, or symlink gets this exception.
                if artifact != code_rules or artifact.is_symlink():
                    raise AssertionError("BLOCKED_INPUT_ARTIFACT")

sys.addaudithook(audit)
sys.argv = [argv_zero, *arguments]
if mode in {"module", "alias"}:
    runpy.run_module(entry, run_name="__main__", alter_sys=False)
else:
    runpy.run_path(str(Path(root) / entry), run_name="__main__")
'''


ENTRIES = {
    "benchmark": ("Scripts/benchmark-asr-chunking.py",
                  ["--audio", "input.wav", "--model", "local-model", "--output", "output.json"],
                  "--duration-seconds", ["--chunk-seconds", CANARY], None, None),
    "scorer": ("Scripts/evaluate-learning-quality.py",
               ["--corpus", "corpus.json", "--results", "results", "--output", "output.json"],
               "--target", None, ["--target", CANARY], None),
    "calibrate": ("Scripts/target_eval/calibrate.py",
                  ["--cli", "synthetic-cli", "--un-root", "synthetic-un", "--output", "output.json"],
                  "--batch-size", ["--batch-size", CANARY], ["--targets", CANARY], None),
    "package": ("Scripts/privacy_package.py", ["check", "--root", "synthetic-root"],
                "--root", None, ["--layout", CANARY], [CANARY]),
    "recovery": ("Scripts/recover-orphan-recordings.py", ["--root", "synthetic-root"],
                 "--root", None, None, None),
    "scoreboard": ("Scripts/livelingo-scoreboard.py",
                   ["run", "--fixtures", "synthetic-fixtures", "--runtime", "runtime.json",
                    "--build", "synthetic-build", "--out", "synthetic-run", "--no-energy", "--skip-authored"],
                   "--repeats", ["--repeats", CANARY], ["--profile", CANARY], [CANARY]),
    "classroom_metrics": ("Scripts/classroom-metrics.py", ["report", "--output", "output.json"],
                          "--output", ["watch-rss", "--pid", CANARY,
                                       "--executable", "synthetic", "--output", "output.json"],
                          None, [CANARY]),
    "energy": ("Scripts/scoreboard_energy.py", ["--out", "synthetic-output"],
               "--seconds", ["--seconds", CANARY], None, None),
    "corpora": ("Scripts/target_eval/corpora.py",
                ["un", "--input", "synthetic-un", "--output", "output.jsonl"],
                "--output", None, None, [CANARY, "--output", "output.jsonl"]),
    "metrics": ("Scripts/target_eval/metrics.py", ["score", "input.jsonl", "--output", "output.json"],
                "--output", ["compare", "a.jsonl", "b.jsonl", "--iterations", CANARY,
                             "--output", "output.json"], None, [CANARY]),
    "strategies": ("Scripts/target_eval/run_strategies.py",
                   ["--prompts-dir", "synthetic-prompts", "--corpus", "jsonl", "--input", "input.jsonl",
                    "--targets", "en", "--routes", "direct", "--output-dir", "synthetic-output",
                    "--dry-run", "--no-energy"],
                   "--final-budget", ["--final-budget", CANARY], ["--profile", CANARY], None),
    "prefix_cache": ("Scripts/benchmark-prefix-cache.py",
                     ["--model", "local-model", "--baseline-engine", "synthetic-engine.py", "--output", "output"],
                     "--limit", ["--limit", CANARY], None, None),
    "checkpoints": ("Scripts/benchmark-checkpoints.py", ["--model", "local-model", "--output", "output"],
                    "--output", None, None, None),
}


class PrivateCLIEntryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = Path(tempfile.mkdtemp(prefix="private-cli-arguments-"))
        (cls.scratch / "tmp").mkdir()

    def run_entry(self, mode, file, arguments):
        entry = (file[len("Scripts/"):-3].replace("/", ".") if mode == "alias" else
                 file[:-3].replace("/", ".") if mode == "module" else file)
        command = ([sys.executable, "-B", str(ROOT / file), *arguments] if mode == "native"
                   else [sys.executable, "-B", "-c", PROBE, mode, str(ROOT), entry,
                         PROGRAM_CANARY, *arguments])
        result = subprocess.run(
            command,
            cwd=self.scratch, env={"PATH": os.defpath, "TMPDIR": str(self.scratch / "tmp")},
            capture_output=True, text=True, timeout=15, check=False,
        )
        output = result.stdout + result.stderr
        self.assertNotIn("BLOCKED_", output, "failure must occur during argument parsing")
        self.assertNotIn(CANARY, output)
        self.assertNotIn(PROGRAM_CANARY, output)
        self.assertNotIn(str(ROOT), output)
        self.assertEqual(sorted(p.name for p in self.scratch.iterdir()), ["tmp"])
        return result


def entry_test(mode, file, arguments, *, help_only=False, fixed_error=FIXED_ERROR):
    def test(self):
        result = self.run_entry(mode, file, arguments)
        self.assertEqual(result.returncode, 0 if help_only else 2, result.stderr)
        if help_only:
            self.assertIn("--help", result.stdout)
        else:
            self.assertEqual(result.stdout, "")
            self.assertIn(FIXED_ERROR, result.stderr)
            if fixed_error != FIXED_ERROR:
                self.assertIn(fixed_error, result.stderr)
    return test


for name, (file, base, value_option, typed, choice, bad_command) in ENTRIES.items():
    cases = {"unknown_option": [*base, "--" + CANARY],
             "extra_positional": [*base, CANARY],
             "missing_value": [*base, value_option], "help": ["--help"]}
    if name != "energy":
        cases["missing_required"] = []
    if typed is not None:
        # Some subcommands have their own base rather than the report command.
        cases["invalid_type"] = typed if name in {"classroom_metrics", "metrics"} else [*base, *typed]
    if choice is not None:
        cases["invalid_choice"] = [*base, *choice]
    if bad_command is not None:
        cases["invalid_command_or_positional_choice"] = bad_command
    modes = ("direct", "module", "alias") if name in {"calibrate", "metrics"} else ("direct", "module")
    for mode in modes:
        for case, arguments in cases.items():
            setattr(PrivateCLIEntryTests, f"test_{name}_{mode}_{case}",
                    entry_test(mode, file, arguments, help_only=case == "help",
                               fixed_error=RECOVERY_ERROR if name == "recovery" else FIXED_ERROR))
    if name in OWNED_ENTRIES:
        # Exercise the real script-directory import fallback from a foreign cwd.
        # These exact unknown flags must fail before any preflight or backend.
        for case in ("unknown_option", "help"):
            setattr(PrivateCLIEntryTests, f"test_{name}_native_{case}",
                    entry_test("native", file, cases[case], help_only=case == "help"))


class PrivateOutputIntegrationTests(unittest.TestCase):
    def load_entry(self, name):
        spec = importlib.util.spec_from_file_location(name.replace("-", "_"), ROOT / "Scripts" / (name + ".py"))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_benchmark_delegates_exclusive_creation_to_private_helper(self):
        benchmark = self.load_entry("benchmark-asr-chunking")
        scratch = Path(tempfile.mkdtemp(prefix="private-cli-benchmark-output-"))
        audio = scratch / "input.wav"
        audio.write_bytes(b"synthetic; audio_info is replaced")
        model = scratch / "local-model"
        model.mkdir()
        (model / "config.json").write_text("{}")
        output = scratch / "new" / "output.json"
        factory = Mock(side_effect=OSError(CANARY))
        argv = [PROGRAM_CANARY, "--audio", str(audio), "--model", str(model), "--output", str(output)]
        with patch.object(sys, "argv", argv), \
             patch.object(benchmark, "audio_info", return_value=(16000, 16000)), \
             patch.object(benchmark, "create_private_file", factory, create=True), \
             patch.object(benchmark.os, "open", side_effect=OSError(CANARY)), \
             patch.object(benchmark, "run", side_effect=AssertionError("benchmark core forbidden")) as core, \
             redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as exited:
            benchmark.main()
        self.assertEqual(exited.exception.code, 2)
        factory.assert_called_once_with(output)
        core.assert_not_called()
        self.assertFalse(output.exists())

    def test_scorer_delegates_exclusive_creation_to_private_helper(self):
        scorer = self.load_entry("evaluate-learning-quality")
        scratch = Path(tempfile.mkdtemp(prefix="private-cli-scorer-output-"))
        output = scratch / "new" / "output.json"
        factory = Mock(side_effect=OSError(CANARY))
        with patch.object(scorer, "score", return_value={"version": 2, "integrityStatus": "pass"}), \
             patch.object(scorer, "create_private_file", factory, create=True), \
             patch.object(scorer.os, "open", side_effect=OSError(CANARY)), \
             self.assertRaises(OSError):
            scorer.main(["--corpus", "synthetic-corpus", "--results", "synthetic-results", "--output", str(output)])
        factory.assert_called_once_with(output)
        self.assertFalse(output.exists())

    def test_benchmark_new_output_uses_real_private_helper_with_fake_core(self):
        from Scripts.private_files import create_private_file
        benchmark = self.load_entry("benchmark-asr-chunking")
        scratch = Path(tempfile.mkdtemp(prefix="private-cli-benchmark-real-output-"))
        audio = scratch / "input.wav"
        with wave.open(str(audio), "wb") as stream:
            stream.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            stream.writeframes(b"\0\0" * 16000)
        model = scratch / "local-model"
        model.mkdir()
        (model / "config.json").write_text("{}")
        parent = scratch / "existing-parent"
        parent.mkdir()
        parent.chmod(0o755)  # Only this newly created synthetic fixture.
        before = parent.stat()
        output = parent / "output.json"
        factory = Mock(wraps=create_private_file)
        with patch.object(sys, "argv", [PROGRAM_CANARY, "--audio", str(audio), "--model", str(model),
                                       "--output", str(output)]), \
             patch.object(benchmark, "create_private_file", factory, create=True), \
             patch.object(benchmark, "run", return_value=None):
            self.assertEqual(benchmark.main(), 0)
        factory.assert_called_once_with(output)
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        self.assertEqual(parent.stat().st_mode, before.st_mode)
        self.assertEqual(parent.stat().st_ino, before.st_ino)
        self.assertEqual(json.loads(output.read_text())["status"], "completed")

    def test_scorer_new_output_uses_real_private_helper(self):
        from Scripts.private_files import create_private_file
        scorer = self.load_entry("evaluate-learning-quality")
        scratch = Path(tempfile.mkdtemp(prefix="private-cli-scorer-real-output-"))
        output = scratch / "new" / "nested" / "output.json"
        factory = Mock(wraps=create_private_file)
        with patch.object(scorer, "create_private_file", factory, create=True), \
             patch.object(scorer, "score", return_value={"version": 2, "integrityStatus": "pass"}), \
             redirect_stdout(io.StringIO()):
            self.assertEqual(scorer.main(["--corpus", "synthetic-corpus", "--results", "synthetic-results",
                                         "--output", str(output)]), 0)
        factory.assert_called_once_with(output)
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        self.assertEqual(output.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(output.parent.parent.stat().st_mode & 0o777, 0o700)


class StopBeforeModel(BaseException):
    pass


class PrivateModelRootPreflightTests(unittest.TestCase):
    load_entry = PrivateOutputIntegrationTests.load_entry

    # These tests stop at the first model import. They never import the runtime
    # or execute a generation, including when run against the unsafe baseline.
    def fixture(self, name):
        module = self.load_entry(name)
        module.ROOT = Path(__file__).resolve().parents[1]
        scratch = Path(tempfile.mkdtemp(prefix="private-cli-model-root-"))
        model = scratch / "local-model"
        model.mkdir()
        engine = scratch / "synthetic-original-engine.py"
        engine.write_text("# synthetic; never executed\n")
        output = scratch / "existing-parent" / "new-state-root"
        output.parent.mkdir()
        argv = [PROGRAM_CANARY, "--model", str(model), "--output", str(output)]
        if name == "benchmark-prefix-cache":
            argv.extend(["--baseline-engine", str(engine)])
        return module, output, argv

    def block_model_import(self, original_import):
        def guarded(name, *args, **kwargs):
            if name == "engine" or name.startswith("mlx") or name in {"schemas", "numpy"}:
                raise StopBeforeModel()
            return original_import(name, *args, **kwargs)
        return guarded

    def helper_failure(self, name):
        module, output, argv = self.fixture(name)
        factory = Mock(side_effect=StopBeforeModel())
        with patch.object(sys, "argv", argv), \
             patch.object(module, "make_private_directory", factory, create=True), \
             patch.object(builtins, "__import__", self.block_model_import(builtins.__import__)), \
             self.assertRaises(StopBeforeModel):
            module.main()
        factory.assert_called_once_with(output, exclusive=True)
        self.assertFalse(output.exists())

    def actual_root(self, name):
        from Scripts.private_files import make_private_directory, require_private_acl
        module, output, argv = self.fixture(name)
        # Only the synthetic parent's ACL is changed. A private output root must
        # break inheritance before any model state or generated content exists.
        if sys.platform == "darwin":
            subprocess.run(["/bin/chmod", "+a", "everyone allow read,write,execute,file_inherit,directory_inherit",
                            str(output.parent)], check=True, capture_output=True)
        before = output.parent.stat()
        factory = Mock(wraps=make_private_directory)
        with patch.object(sys, "argv", argv), \
             patch.object(module, "make_private_directory", factory, create=True), \
             patch.object(builtins, "__import__", self.block_model_import(builtins.__import__)), \
             self.assertRaises(StopBeforeModel):
            module.main()
        factory.assert_called_once_with(output, exclusive=True)
        self.assertEqual(output.stat().st_mode & 0o777, 0o700)
        self.assertEqual(list(output.iterdir()), [])
        self.assertEqual(output.parent.stat().st_mode, before.st_mode)
        self.assertEqual(output.parent.stat().st_ino, before.st_ino)
        descriptor = os.open(output, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            require_private_acl(descriptor)
        finally:
            os.close(descriptor)

    def existing_root(self, name, *, as_file=False):
        from Scripts.private_files import make_private_directory
        module, output, argv = self.fixture(name)
        if as_file:
            retained = output
            retained.write_text(CANARY)
            retained.chmod(0o400)  # Only this newly created synthetic fixture.
        else:
            output.mkdir(mode=0o700)
            retained = output / "retained-synthetic.txt"
            retained.write_text(CANARY)
        before = output.stat()
        factory = Mock(wraps=make_private_directory)
        with patch.object(sys, "argv", argv), \
             patch.object(module, "make_private_directory", factory, create=True), \
             patch.object(builtins, "__import__", self.block_model_import(builtins.__import__)), \
             self.assertRaises(FileExistsError):
            module.main()
        factory.assert_called_once_with(output, exclusive=True)
        self.assertEqual(output.stat().st_mode, before.st_mode)
        self.assertEqual(output.stat().st_ino, before.st_ino)
        self.assertEqual(retained.read_text(), CANARY)

    def raced_root(self, name):
        from Scripts.private_files import make_private_directory
        module, output, argv = self.fixture(name)
        retained = output / "racer-synthetic.txt"
        state = {}
        def race(path, **kwargs):
            path.mkdir(mode=0o700)
            retained.write_text(CANARY)
            state["before"] = path.stat()
            return make_private_directory(path, **kwargs)
        factory = Mock(side_effect=race)
        with patch.object(sys, "argv", argv), \
             patch.object(module, "make_private_directory", factory, create=True), \
             patch.object(builtins, "__import__", self.block_model_import(builtins.__import__)), \
             self.assertRaises((FileExistsError, StopBeforeModel)) as stopped:
            module.main()
        self.assertIsInstance(stopped.exception, FileExistsError,
                              "a raced private directory must be rejected before the model import")
        factory.assert_called_once_with(output, exclusive=True)
        self.assertEqual(output.stat().st_mode, state["before"].st_mode)
        self.assertEqual(output.stat().st_ino, state["before"].st_ino)
        self.assertEqual(retained.read_text(), CANARY)

    def test_checkpoints_helper_rejection_stops_before_model(self):
        self.helper_failure("benchmark-checkpoints")

    def test_prefix_cache_helper_rejection_stops_before_model(self):
        self.helper_failure("benchmark-prefix-cache")

    def test_checkpoints_new_root_mode_and_inherited_acl(self):
        self.actual_root("benchmark-checkpoints")

    def test_prefix_cache_new_root_mode_and_inherited_acl(self):
        self.actual_root("benchmark-prefix-cache")

    def test_checkpoints_existing_output_is_preserved(self):
        self.existing_root("benchmark-checkpoints")

    def test_prefix_cache_existing_output_is_preserved(self):
        self.existing_root("benchmark-prefix-cache")

    def test_checkpoints_existing_file_is_preserved(self):
        self.existing_root("benchmark-checkpoints", as_file=True)

    def test_prefix_cache_existing_file_is_preserved(self):
        self.existing_root("benchmark-prefix-cache", as_file=True)

    def test_checkpoints_raced_private_root_is_rejected(self):
        self.raced_root("benchmark-checkpoints")

    def test_prefix_cache_raced_private_root_is_rejected(self):
        self.raced_root("benchmark-prefix-cache")


if __name__ == "__main__":
    unittest.main()
