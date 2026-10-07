#!/usr/bin/env python3
"""Small synthetic orchestration tests. No model, server or real audio replay."""
import base64
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import select
import signal
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("livelingo_scoreboard", Path(__file__).with_name("livelingo-scoreboard.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

SENTINEL = "PRIVATE_CLASSROOM_SENTINEL_do_not_export"
SEGMENT = "00000000-0000-0000-0000-000000000001"

FAKE = r'''
import base64, hashlib, json, os, pathlib, sys, time
args = sys.argv[1:]
root = pathlib.Path(args[args.index('--output') + 1]); root.mkdir()
sentinel = 'PRIVATE_CLASSROOM_SENTINEL_do_not_export'
segment = '00000000-0000-0000-0000-000000000001'
if '--translate-file' in args:
    source = pathlib.Path(args[args.index('--translate-file') + 1]).read_text()
    destination = pathlib.Path(args[args.index('--translation-output') + 1])
    with destination.open('x') as stream:
        for index, text in enumerate(source.split('||')):
            stream.write(json.dumps(dict(index=index, text='合成译文')) + '\n')
    destination.chmod(0o600)
    print(json.dumps(dict(event='runtime_cleanup',confirmed=True)))
    time.sleep(.1)
    sys.exit(0)
row = dict(id=segment,startTime=0.,endTime=.1,english=sentinel,
           chinese=sentinel,translationState='failed')
(root/'bilingual.jsonl').write_text(json.dumps(row)+'\n')
journal = root/'durable-transcription'; journal.mkdir()
record = dict(id=segment,sessionID=segment,start=0.,end=.1,status='completed',
              candidateText=sentinel,appleEvidence=sentinel,automaticRetryCount=1)
payload = json.dumps(dict(version=1,sequence=0,sessionID=segment,records=[record])).encode()
(journal/'snapshot.json').write_text(json.dumps(dict(payload=base64.b64encode(payload).decode(),
                                                 sha256=hashlib.sha256(payload).hexdigest())))
(journal/'work.jsonl').write_text('')
for row in [dict(event='capture',kind='silent-pcm-replay',text=sentinel),
            dict(event='state',pendingTranscription=0,segments=1,unresolvedTranscription=1),
            dict(event='processing_finished',segments=1,translated=0,unresolvedTranscription=1,
                 otherLanguageTranscription=0,stopSeconds=.02,summaryStatus=sentinel),
            dict(event='saved_verified',segments=1,missingTranslations=1),
            dict(event='runtime_cleanup',confirmed=True)]:
    print(json.dumps(row),flush=True)
print(json.dumps(dict(event='cli_failed',reason='processingIncomplete',detail=sentinel)),file=sys.stderr,flush=True)
print(sentinel,file=sys.stderr,flush=True)
with pathlib.Path(os.environ['LIVELINGO_SCOREBOARD_TIMINGS']).open('a') as f:
    f.write(json.dumps(dict(stage='asr_inference',wall_seconds=.01,process_cpu_seconds=.005,
                           start_mono=0.,end_mono=.01,completed=True))+'\n')
time.sleep(.22)
sys.exit(1)
'''


class ScoreboardPrivateOutputTests(unittest.TestCase):
    """Synthetic filesystem evidence; no build, classroom input or runtime."""

    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="scoreboard-private-")).resolve()
        self.enterContext(patch.object(m, "WORK", self.root))
        self.enterContext(patch.object(m, "DEFAULT", self.root / "history"))

    @staticmethod
    def acl(path):
        result = subprocess.run(["/bin/ls", "-lde", str(path)], check=True,
                                capture_output=True, text=True)
        return result.stdout.splitlines()[1:]

    def inherited_acl(self, path):
        subprocess.run(["/bin/chmod", "+a", "everyone allow read,write,file_inherit,directory_inherit",
                        str(path)], check=True, capture_output=True)
        canary = path / "acl-canary"
        canary.write_text("synthetic")
        self.assertTrue(any("everyone inherited allow" in row for row in self.acl(canary)))

    def snapshot(self, path):
        info = path.stat()
        return stat.S_IMODE(info.st_mode), info.st_uid, info.st_ino, self.acl(path)

    @unittest.skipUnless(sys.platform == "darwin", "macOS inherited ACL")
    def test_new_directory_clears_inherited_acl_before_private_writes(self):
        self.inherited_acl(self.root)
        out = m.new_directory(self.root / "nested" / "result")
        m.write_json(out / "body.json", {"text": "synthetic private body"})
        with m.exclusive(out / "body.bin", binary=True) as stream:
            stream.write(b"synthetic private body")
        for directory in (out.parent, out):
            self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o700)
            self.assertEqual(self.acl(directory), [])
        for name in ("body.json", "body.bin"):
            self.assertEqual(stat.S_IMODE((out / name).stat().st_mode), 0o600)
            self.assertEqual(self.acl(out / name), [])

    @unittest.skipUnless(sys.platform == "darwin", "macOS inherited ACL")
    def test_exclusive_clears_new_file_acl_without_changing_existing_parent(self):
        parent = self.root / "existing"
        parent.mkdir(mode=0o700)
        self.inherited_acl(parent)
        before = self.snapshot(parent)
        m.write_json(parent / "body.json", {"text": "synthetic"})
        self.assertEqual(self.snapshot(parent), before)
        self.assertEqual(self.acl(parent / "body.json"), [])
        self.assertEqual(stat.S_IMODE((parent / "body.json").stat().st_mode), 0o600)

    def test_private_readonly_directory_and_file_are_not_upgraded(self):
        parent = self.root / "readonly"
        parent.mkdir(mode=0o500)
        before = parent.stat().st_mode
        with self.assertRaises((m.Rejected, OSError, ValueError)):
            m.new_directory(parent / "child")
        self.assertEqual(parent.stat().st_mode, before)
        self.assertFalse((parent / "child").exists())
        output = m.new_directory(self.root / "output")
        body = output / "body.json"
        body.write_text("synthetic retained body")
        body.chmod(0o400)
        before = body.stat().st_mode, body.read_bytes()
        with self.assertRaises((m.Rejected, OSError, ValueError)):
            m.write_json(body, {"text": "replacement"})
        self.assertEqual((body.stat().st_mode, body.read_bytes()), before)

    @unittest.skipUnless(sys.platform == "darwin", "macOS inherited ACL")
    def test_history_and_lock_creation_clear_inherited_acl(self):
        self.inherited_acl(self.root)
        out = m.new_directory(self.root / "result")
        with patch.object(m, "markdown", return_value="synthetic report\n"):
            m.write_report(out, {"headline": {"runs_total": 0}})
        lock_directory = self.root / "lock"
        with m.session_lock(lock_directory):
            pass
        lock = lock_directory / ".lock"
        before = self.snapshot(lock)
        with m.session_lock(lock_directory):
            pass
        self.assertEqual(self.snapshot(lock), before)
        for path in (m.DEFAULT, lock_directory):
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o700)
            self.assertEqual(self.acl(path), [])
        for path in (m.DEFAULT / "history.jsonl", lock):
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(self.acl(path), [])

    @unittest.skipUnless(sys.platform == "darwin", "macOS ACL validation")
    def test_history_append_refuses_public_allow_acl_and_readonly_files(self):
        for index, (mode, acl) in enumerate(((0o644, False), (0o600, True), (0o400, False), (0o600, "deny-allow"))):
            with self.subTest(mode=mode, acl=acl):
                directory = self.root / f"history-{index}"
                directory.mkdir(mode=0o700)
                history = directory / "history.jsonl"
                history.write_text("synthetic retained prefix\n")
                history.chmod(mode)
                if acl == "deny-allow":
                    subprocess.run(["/bin/chmod", "+a", "everyone deny execute", str(history)],
                                   check=True, capture_output=True)
                if acl:
                    subprocess.run(["/bin/chmod", "+a", "everyone allow read,write", str(history)],
                                   check=True, capture_output=True)
                before = self.snapshot(history), history.read_bytes()
                out = m.new_directory(self.root / f"report-{index}")
                with patch.object(m, "DEFAULT", directory), patch.object(m, "markdown", return_value="synthetic\n"), \
                        self.assertRaises((m.Rejected, OSError, ValueError)):
                    m.write_report(out, {"headline": {"runs_total": 0}})
                self.assertEqual((self.snapshot(history), history.read_bytes()), before)

    @unittest.skipUnless(sys.platform == "darwin", "macOS ACL validation")
    def test_history_append_preserves_existing_private_file(self):
        m.DEFAULT.mkdir(mode=0o700)
        history = m.DEFAULT / "history.jsonl"
        history.write_text("synthetic retained prefix\n")
        history.chmod(0o600)
        before = self.snapshot(history)
        out = m.new_directory(self.root / "report")
        with patch.object(m, "markdown", return_value="synthetic\n"):
            m.write_report(out, {"headline": {"runs_total": 0}})
        self.assertEqual(self.snapshot(history), before)
        self.assertTrue(history.read_text().startswith("synthetic retained prefix\n"))
        self.assertEqual(len(history.read_text().splitlines()), 2)

    @unittest.skipUnless(sys.platform == "darwin", "macOS ACL validation")
    def test_lock_refuses_public_allow_acl_and_readonly_files(self):
        for index, (mode, acl) in enumerate(((0o644, False), (0o600, True), (0o400, False), (0o600, "deny-allow"))):
            with self.subTest(mode=mode, acl=acl):
                directory = self.root / f"lock-{index}"
                directory.mkdir(mode=0o700)
                lock = directory / ".lock"
                lock.write_text("synthetic retained lock")
                lock.chmod(mode)
                if acl == "deny-allow":
                    subprocess.run(["/bin/chmod", "+a", "everyone deny execute", str(lock)],
                                   check=True, capture_output=True)
                if acl:
                    subprocess.run(["/bin/chmod", "+a", "everyone allow read,write", str(lock)],
                                   check=True, capture_output=True)
                before = self.snapshot(lock), lock.read_bytes()
                with self.assertRaises((m.Rejected, OSError, ValueError)):
                    with m.session_lock(directory):
                        pass
                self.assertEqual((self.snapshot(lock), lock.read_bytes()), before)

    def test_parser_errors_use_fixed_prog_and_omit_private_arguments(self):
        with patch.object(sys, "argv", ["synthetic-program-" + SENTINEL]), \
                contextlib.redirect_stderr(io.StringIO()) as error, self.assertRaises(SystemExit):
            m.parser().parse_args(["run", "--repeats", SENTINEL])
        self.assertNotIn(SENTINEL, error.getvalue())
        self.assertIn("livelingo-scoreboard", error.getvalue())

    def test_public_code_parent_is_unchanged_when_creating_private_file(self):
        parent = self.root / "public-code"
        parent.mkdir(mode=0o755)
        before = parent.stat().st_mode
        with m.exclusive(parent / "synthetic.py") as stream:
            stream.write("# public synthetic code\n")
        self.assertEqual(parent.stat().st_mode, before)
        self.assertEqual(stat.S_IMODE((parent / "synthetic.py").stat().st_mode), 0o600)

    def test_directory_reservation_race_refuses_existing_inode_without_mutation(self):
        out = self.root / "already-reserved"
        out.mkdir(mode=0o700)
        sentinel = out / "retained"
        sentinel.write_text("synthetic retained content")
        before = out.stat().st_mode, out.stat().st_ino, sentinel.read_bytes()
        with patch.object(Path, "exists", return_value=False), self.assertRaises(FileExistsError):
            m.new_directory(out)
        self.assertEqual((out.stat().st_mode, out.stat().st_ino, sentinel.read_bytes()), before)

    def test_lock_refuses_symlink_ancestor_above_immediate_parent(self):
        target = self.root / "synthetic-lock-target"
        target.mkdir(mode=0o700)
        link = self.root / "redirect"
        link.symlink_to(target, target_is_directory=True)
        directory = link / "middle" / "parent" / "lock"
        with patch.object(m, "default_machine_lock_directory", return_value=directory), \
                self.assertRaises(m.Rejected):
            with m.session_lock():
                pass
        self.assertEqual(list(target.iterdir()), [])

    def test_new_directory_identity_drift_is_refused_before_acl_or_mode_changes(self):
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

                with patch.object(m.os, "open", side_effect=open_output), \
                        patch.object(m.os, "fstat", side_effect=fstat_output), \
                        patch.object(m, "privatize_new", wraps=m.privatize_new) as privatize, \
                        self.assertRaises((OSError, m.Rejected)):
                    m.new_directory(out)
                privatize.assert_not_called()
                if drift == "replacement":
                    self.assertEqual((out.stat().st_mode, out.stat().st_ino), before)

    @unittest.skipUnless(sys.platform == "darwin", "macOS deny ACL")
    def test_private_history_and_lock_deny_acl_is_preserved(self):
        directory = self.root / "deny-acl"
        directory.mkdir(mode=0o700)
        subprocess.run(["/bin/chmod", "+a", "everyone deny delete", str(directory)],
                       check=True, capture_output=True)
        paths = [directory / "history.jsonl", directory / ".lock"]
        for path in paths:
            path.write_text("synthetic retained prefix\n")
            path.chmod(0o600)
            subprocess.run(["/bin/chmod", "+a", "everyone deny execute", str(path)],
                           check=True, capture_output=True)
        before = [self.snapshot(path) for path in (directory, *paths)]
        with m.session_lock(directory):
            pass
        out = m.new_directory(self.root / "deny-report")
        with patch.object(m, "DEFAULT", directory), patch.object(m, "markdown", return_value="synthetic\n"):
            m.write_report(out, {"headline": {"runs_total": 0}})
        self.assertEqual([self.snapshot(path) for path in (directory, *paths)], before)
        self.assertTrue(paths[0].read_text().startswith("synthetic retained prefix\n"))

    def test_history_and_lock_refuse_hardlinks_without_modifying_shared_inode(self):
        for name in ("history.jsonl", ".lock"):
            with self.subTest(name=name):
                directory = self.root / ("history-hardlink" if name == "history.jsonl" else "lock-hardlink")
                directory.mkdir(mode=0o700)
                path = directory / name
                path.write_text("synthetic shared inode\n")
                path.chmod(0o600)
                alias = directory / "alias"
                os.link(path, alias)
                before = path.stat().st_mode, path.stat().st_nlink, path.read_bytes()
                if name == "history.jsonl":
                    out = m.new_directory(self.root / "hardlink-report")
                    with patch.object(m, "DEFAULT", directory), patch.object(m, "markdown", return_value="synthetic\n"), \
                            self.assertRaises(m.Rejected):
                        m.write_report(out, {"headline": {"runs_total": 0}})
                else:
                    with self.assertRaises(m.Rejected):
                        with m.session_lock(directory):
                            pass
                self.assertEqual((path.stat().st_mode, path.stat().st_nlink, path.read_bytes()), before)
                self.assertEqual(alias.read_bytes(), before[2])

    def test_build_copy_allows_public_code_with_synthetic_compiler_only(self):
        archive_bytes = io.BytesIO()
        files = {"Scripts/mlx_runtime/worker.py": b"# synthetic worker\n",
                 "Scripts/qwen_asr_service.py": b"# synthetic service\n",
                 "Scripts/scoreboard_timing.py": b"# synthetic timing\n"}
        with tarfile.open(fileobj=archive_bytes, mode="w") as archive:
            for name in ("Scripts", "Scripts/mlx_runtime"):
                entry = tarfile.TarInfo(name)
                entry.type, entry.mode = tarfile.DIRTYPE, 0o755
                archive.addfile(entry)
            for name, content in files.items():
                entry = tarfile.TarInfo(name)
                entry.size, entry.mode = len(content), 0o644
                archive.addfile(entry, io.BytesIO(content))
        runtime = self.root / "synthetic-runtime"
        runtime.mkdir(mode=0o755)
        python = runtime / "python"
        python.write_bytes(b"synthetic executable; never executed")
        config = {"python": str(python), "models": str(runtime),
                  "asr_site_packages": str(runtime), "language_site_packages": str(runtime)}
        original_run = subprocess.run

        def fake_compile(arguments, **kwargs):
            if arguments[0] != "bash":
                return original_run(arguments, **kwargs)
            compiled = Path(arguments[2])
            compiled.mkdir(mode=0o700)
            for name in ("livelingo-cli", "livelingo-virtual-player"):
                binary = compiled / name
                binary.write_bytes(b"synthetic binary; never executed")
                binary.chmod(0o755)
            source = Path(kwargs["cwd"])
            for name in files:
                (source / name).chmod(0o644)
            (source / "Scripts/mlx_runtime").chmod(0o755)
            return subprocess.CompletedProcess(arguments, 0)

        def fake_command(arguments, **kwargs):
            if arguments[:2] == ["git", "archive"]:
                return archive_bytes.getvalue()
            if arguments == ["xcrun", "swiftc", "--version"]:
                return b"synthetic compiler version"
            self.fail("unexpected command in synthetic build")

        out = self.root / "synthetic-build"
        with patch.object(m, "DERIVED", self.root / "derived"), \
                patch.object(m, "runtime_config", return_value=config), \
                patch.object(m, "git", return_value="a" * 40), \
                patch.object(m, "command", side_effect=fake_command), \
                patch.object(m.subprocess, "run", side_effect=fake_compile), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(m.build(m.argparse.Namespace(runtime=runtime, commit="synthetic", out=out)), out)
        self.assertEqual(stat.S_IMODE(out.stat().st_mode), 0o700)
        for name in ("mlx_runtime/worker.py", "ASRRuntime/qwen_asr_service.py", "mlx_runtime/scoreboard_timing.py"):
            self.assertEqual(stat.S_IMODE((out / name).stat().st_mode), 0o644)
        self.assertEqual(stat.S_IMODE(runtime.stat().st_mode), 0o755)
        self.assertEqual(stat.S_IMODE((out / "build-provenance.json").stat().st_mode), 0o600)


class ScoreboardOrchestrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(tempfile.mkdtemp(prefix="scoreboard-orchestration-"))
        cls.lock_directory = cls.root / "common.git" / "work" / "scoreboard"
        for attribute, value in (("WORK", cls.root), ("DEFAULT", cls.root / "scoreboard")):
            override = patch.object(m, attribute, value)
            override.start()
            cls.addClassCleanup(override.stop)
        override = patch.object(m, "default_machine_lock_directory", return_value=cls.lock_directory)
        override.start()
        cls.addClassCleanup(override.stop)
        cls.build = cls.root / "fake-build"
        cls.build.mkdir()
        cls.cli = cls.build / "livelingo-cli"
        cls.cli.write_text("#!" + sys.executable + "\n" + FAKE)
        cls.cli.chmod(0o700)
        cls.fixtures = cls.root / "fixtures"
        cls.fixtures.mkdir()
        (cls.fixtures / "rules").mkdir()
        files = {}
        for name in ("ruler.json", "normalizer-v1.json", "cs50-glossary-v1.json", "translation-authored-80.json"):
            path = cls.fixtures / "rules" / name
            path.write_bytes((m.RULES / name).read_bytes())
            files["rules/" + name] = m.sha256(path)
        # One tenth of a second of silence. No audio device is ever opened.
        data = bytes(3200 * 2)
        fmt = struct.pack("<HHIIHH", 1, 1, 32000, 64000, 2, 16)
        blob = b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt " + struct.pack("<I", 16) + fmt + b"data" + struct.pack("<I", len(data)) + data
        audio = cls.fixtures / "private.wav"
        audio.write_bytes(blob)
        files[audio.name] = m.sha256(audio)
        cls.clip = dict(id="private-0928-30m", privacy="private", tiers=["smoke"],
                        audio="private.wav", audio_seconds=.1, frames=3200)
        manifest = dict(schema="livelingo-fixtures/1", id="ruler-1", files=files, clips=[cls.clip])
        (cls.fixtures / "fixtures-manifest.json").write_text(json.dumps(manifest))

    def path(self, suffix):
        return self.root / (self.id().split(".")[-1] + "-" + suffix)

    def args(self, out):
        return m.parser().parse_args(["run", "--fixtures", str(self.fixtures), "--build", str(self.build),
                                      "--tier", "smoke", "--no-energy", "--out", str(out)])

    @staticmethod
    def provider():
        # Unit tests inject only Python identities. An unrelated real CLI/GPU
        # regression is excluded from this synthetic provider, never altered.
        return {pid: row for pid, row in m.read_processes().items()
                if Path(row["executable"]).name in {Path(sys.executable).name, "Python", "python3", "python3.11"}}

    @staticmethod
    def oslog(execution, directory):
        m.write_jsonl(directory / "oslog-numeric.jsonl", [
            dict(timestamp=execution["spawn_wall"] + .001, category="ReplayClock", kind="replay", event="start"),
            dict(timestamp=execution["spawn_wall"] + .151, category="TranslationLatency", kind="caption",
                 event="request", id=SEGMENT, elapsed_ms=0.)])
        return "synthetic"

    def test_private_failed_run_still_scores_and_offline_score_agrees(self):
        out = self.path("online")
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = m.run(self.args(out), provider=self.provider, log_collector=self.oslog)
        self.assertEqual(code, 0)
        report = m.read_json(out / "scoreboard.json")
        run = report["clips"][self.clip["id"]]["runs"][0]
        self.assertEqual(run["validity"]["outcome"], "completed_with_unresolved")
        self.assertFalse(run["validity"]["success"])
        self.assertEqual(run["transcription"]["completed_with_unresolved"], 1)
        self.assertEqual(run["model_times"]["stages"]["asr_inference"]["wall_seconds"], .01)
        self.assertEqual(report["headline"]["runs_verified"], 0)
        self.assertNotIn(SENTINEL, stdout.getvalue() + stderr.getvalue())
        self.assertNotIn(SENTINEL, (out / "scoreboard.json").read_text() + (out / "scoreboard.md").read_text())
        for path in (out / "clips").rglob("*"):
            if path.is_file() and "session" not in path.parts:
                self.assertNotIn(SENTINEL, path.read_text())
        rescored = self.path("offline")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(m.score(m.parser().parse_args(["score", "--run-dir", str(out), "--out", str(rescored)])), 0)
        self.assertEqual(report, m.read_json(rescored / "scoreboard.json"))

    def test_authored_runner_uses_private_files_instead_of_content_arguments(self):
        out = self.path("authored-private-files")
        args = self.args(out)
        args.tier, args.skip_authored = "standard", False
        manifest_path = self.fixtures / "fixtures-manifest.json"
        original_manifest = manifest_path.read_bytes()
        manifest = json.loads(original_manifest)
        manifest["clips"][0]["tiers"].append("standard")
        manifest_path.write_text(json.dumps(manifest))
        captured = []
        popen = subprocess.Popen
        def check_popen(arguments, *positional, **keywords):
            if str(arguments[0]) == str(self.cli):
                self.assertNotIn("--translate-text", arguments)
                if "--translate-file" in arguments:
                    captured.append(arguments)
                    source = Path(arguments[arguments.index("--translate-file") + 1])
                    self.assertEqual(source.parent.name, ".translation-content")
                    self.assertEqual(source.stat().st_mode & 0o777, 0o600)
                    self.assertEqual(source.parent.stat().st_mode & 0o777, 0o700)
                    self.assertNotIn(source.read_text(), arguments)
            return popen(arguments, *positional, **keywords)
        try:
            with patch.object(m.subprocess, "Popen", side_effect=check_popen), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(m.run(args, provider=self.provider, log_collector=self.oslog), 0)
        finally:
            manifest_path.write_bytes(original_manifest)
        self.assertEqual(len(captured), 1)
        self.assertTrue((out / "translate-A-9b-000/.translation-content/translations.jsonl").is_file())
        self.assertNotIn("合成译文", (out / "scoreboard.json").read_text())

    def test_existing_output_is_refused_without_overwriting(self):
        out = self.path("existing")
        out.mkdir()
        canary = out / "canary"
        canary.write_text("keep")
        with self.assertRaises(m.Rejected):
            m.run(self.args(out), provider=lambda: {})
        self.assertEqual(canary.read_text(), "keep")

    def test_busy_process_refused_before_creating_output(self):
        out = self.path("busy")
        provider = lambda: {123: dict(pid=123, executable="/synthetic/livelingo-cli", state="S")}
        with self.assertRaises(m.Rejected) as failure:
            m.run(self.args(out), provider=provider)
        self.assertEqual(failure.exception.reason, "another_livelingo_run_active")
        self.assertFalse(out.exists())

    def test_lock_blocks_a_second_writer_and_is_reusable(self):
        path = self.path("lock")
        with m.session_lock(path):
            with self.assertRaises(m.Rejected):
                with m.session_lock(path):
                    pass
        with m.session_lock(path):
            pass
        self.assertTrue((path / ".lock").is_file())

    def checkout_modules(self, suffix):
        # Minimal Git metadata fixtures, not registered worktrees or commits.
        root = self.path(suffix)
        common = root / "common.git"
        (common / "objects").mkdir(parents=True)
        (common / "refs" / "heads").mkdir(parents=True)
        (common / "HEAD").write_text("ref: refs/heads/synthetic\n")
        modules = []
        for name in ("checkout-a", "checkout-b"):
            checkout = root / name
            checkout.mkdir()
            metadata = common / "worktrees" / name
            metadata.mkdir(parents=True)
            (metadata / "HEAD").write_text("ref: refs/heads/synthetic\n")
            (metadata / "commondir").write_text("../../\n")
            (metadata / "gitdir").write_text(str(checkout / ".git") + "\n")
            (checkout / ".git").write_text("gitdir: " + str(metadata) + "\n")
            spec = importlib.util.spec_from_file_location(name, Path(m.__file__))
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            module.ROOT = checkout
            module.WORK = checkout / "work"
            module.DEFAULT = module.WORK / ("output-" + name)
            modules.append(module)
        return common, modules

    def test_default_lock_is_shared_across_checkouts_and_outputs(self):
        common, (first, second) = self.checkout_modules("shared-lock")
        expected = common / "work" / "scoreboard"
        self.assertNotEqual(first.DEFAULT, second.DEFAULT)
        self.assertEqual(first.default_machine_lock_directory(), expected)
        self.assertEqual(second.default_machine_lock_directory(), expected)
        for owner, contender in ((first, second), (second, first)):
            with owner.session_lock():
                # There is no CLI/worker, so the process guard alone passes.
                contender.preflight_processes(lambda: {})
                with self.assertRaises(contender.Rejected) as rejected:
                    with contender.session_lock():
                        self.fail("different checkout/output bypassed the shared lock")
                self.assertEqual(rejected.exception.reason, "scoreboard_busy")
        inode = (expected / ".lock").stat().st_ino
        with second.session_lock():
            self.assertEqual((expected / ".lock").stat().st_ino, inode)
        self.assertFalse(first.DEFAULT.exists())
        self.assertFalse(second.DEFAULT.exists())

    def test_default_lock_ignores_cwd_and_git_environment_overrides(self):
        common, (first, second) = self.checkout_modules("git-routing")
        overrides = {"GIT_DIR": str(self.root / "unrelated.git"),
                     "GIT_WORK_TREE": str(second.ROOT), "GIT_COMMON_DIR": str(self.root / "wrong-common"),
                     "LIVELINGO_SCOREBOARD_OUT": str(second.DEFAULT)}
        with contextlib.chdir(second.ROOT), patch.dict(os.environ, overrides):
            self.assertEqual(first.default_machine_lock_directory(), common / "work" / "scoreboard")
        self.assertFalse((common / "work").exists())

    def test_default_lock_rejects_symlink_parents_and_file(self):
        for component in ("work", "scoreboard", ".lock"):
            with self.subTest(component=component):
                common, (first, _) = self.checkout_modules("symlink-lock-" + component)
                directory = common / "work" / "scoreboard"
                target = self.path("lock-target-" + component)
                if component == ".lock":
                    directory.mkdir(parents=True)
                    target.write_text("keep")
                    (directory / component).symlink_to(target)
                else:
                    target.mkdir()
                    link = common / component if component == "work" else directory
                    link.parent.mkdir(parents=True, exist_ok=True)
                    link.symlink_to(target, target_is_directory=True)
                with self.assertRaises(first.Rejected) as rejected:
                    with first.session_lock():
                        self.fail("shared lock followed a symlink")
                self.assertEqual(rejected.exception.reason, "symlink_output")
                if component == ".lock":
                    self.assertEqual(target.read_text(), "keep")
                else:
                    self.assertEqual(list(target.iterdir()), [])

    def test_idle_baseline_lock_blocks_other_checkout_without_cli_or_worker(self):
        _, (first, second) = self.checkout_modules("idle-baseline")
        args = self.args(first.DEFAULT / "run")
        args.no_energy = False
        args.idle_seconds = 120
        sampler = Mock()

        class IdleProbeComplete(Exception):
            pass

        def idle_probe(seconds):
            self.assertEqual(seconds, 120)
            self.assertEqual(second.busy_processes({}), [])
            second.preflight_processes(lambda: {})
            with self.assertRaises(second.Rejected) as rejected:
                with second.session_lock():
                    self.fail("runner entered during scoreboard idle baseline")
            self.assertEqual(rejected.exception.reason, "scoreboard_busy")
            self.assertFalse(second.DEFAULT.exists())
            raise IdleProbeComplete()

        with patch.object(first.energy, "PowerSampler", return_value=sampler), \
                patch.object(first, "pause_window", side_effect=idle_probe) as pause, \
                patch.object(first, "execute_cli") as execute, self.assertRaises(IdleProbeComplete):
            first.run(args, provider=lambda: {})
        pause.assert_called_once_with(120)
        execute.assert_not_called()
        sampler.start.assert_called_once_with()
        sampler.stop.assert_called_once_with()
        with second.session_lock():
            pass

    def test_read_processes_adds_command_without_changing_identity(self):
        row = dict(pid=42, uid=os.getuid(), state="S", started="current", executable="/synthetic/python3")
        identity = m.classroom.identity(row)
        command_line = "/synthetic/python3 Scripts/mlx_runtime/worker.py --model synthetic --state-directory state"
        with patch.object(m.classroom, "read_processes", return_value={42: row}), \
                patch.object(m.subprocess, "check_output", return_value="42 " + command_line + "\n"):
            rows = m.read_processes()
        self.assertEqual(m.classroom.identity(rows[42]), identity)
        self.assertEqual(rows[42]["command"], command_line)
        self.assertEqual(m.busy_processes(rows), [42])

    def test_standalone_workers_and_owned_pid_exclusion(self):
        for executable, command_line in (
                ("/synthetic/python3.13", "/synthetic/python3.13 Scripts/mlx_runtime/worker.py --model model --state-directory state"),
                ("/synthetic/LanguageRuntime/python/bin/Python", "/synthetic/LanguageRuntime/python/bin/Python /synthetic/LanguageRuntime/worker.py --model=model --state-directory=state"),
                ("/synthetic/python3 -u Scripts/mlx_runtime/worker.py --model model --state-directory state", None),
                ("/synthetic path/python3", '"/synthetic path/python3" "/synthetic path/mlx_runtime/worker.py" --model model --state-directory state')):
            with self.subTest(executable=executable):
                row = dict(pid=42, executable=executable, state="S")
                if command_line is not None:
                    row["command"] = command_line
                provider = lambda: {42: row}
                self.assertEqual(m.busy_processes(provider()), [42])
                with self.assertRaises(m.Rejected) as rejected:
                    m.preflight_processes(provider)
                self.assertEqual(rejected.exception.reason, "another_livelingo_run_active")
                self.assertEqual(m.busy_processes(provider(), owned_pids=(42,)), [])
                m.preflight_processes(provider, owned_pids=(42,))
                other = dict(row, pid=43)
                self.assertEqual(m.busy_processes({42: row, 43: other}, owned_pids=(42,)), [43])
                with self.assertRaises(m.Rejected):
                    m.preflight_processes(lambda: {42: row, 43: other}, owned_pids=(42,))

    def test_unrelated_python_and_zombies_are_not_busy(self):
        commands = ("python3 Scripts/mlx_runtime/worker.py --state-directory state",
                    "python3 Scripts/mlx_runtime/worker.py --model model",
                    "python3 Scripts/worker.py --model model --state-directory state",
                    "python3 Scripts/mlx_runtime/worker.py.bak --model model --state-directory state",
                    "sh Scripts/mlx_runtime/worker.py --model model --state-directory state")
        for command_line in commands:
            with self.subTest(command=command_line):
                row = dict(pid=42, executable=command_line.split()[0], command=command_line, state="S")
                self.assertEqual(m.busy_processes({42: row}), [])
        worker = dict(pid=42, executable="python3", state="Z",
                      command="python3 Scripts/mlx_runtime/worker.py --model model --state-directory state")
        rows = {42: worker, 43: dict(pid=43, executable="/synthetic/livelingo-cli", state="S"),
                44: dict(pid=44, executable="/synthetic/LiveLingo.app/Contents/MacOS/LiveLingo", state="S")}
        self.assertEqual(m.busy_processes(rows), [43, 44])
        self.assertEqual(m.busy_processes(rows, owned_pids=(43,)), [44])

    def test_independent_worker_process_is_detected_without_loading_a_model(self):
        worker = self.path("independent-worker") / "mlx_runtime" / "worker.py"
        worker.parent.mkdir(parents=True)
        worker.write_text("import sys\nprint('ready', flush=True)\nsys.stdin.read()\n")
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
        process = subprocess.Popen([sys.executable, str(worker), "--model", "synthetic",
                                    "--state-directory", str(worker.parent / "state")],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   cwd=worker.parent, env=env)
        try:
            ready, _, _ = select.select([process.stdout], [], [], 5)
            self.assertTrue(ready, "inert worker did not signal readiness")
            self.assertEqual(process.stdout.readline(), b"ready\n")
            rows = m.read_processes()
            self.assertIn(process.pid, rows)
            self.assertEqual(m.busy_processes({process.pid: rows[process.pid]}), [process.pid])
            with self.assertRaises(m.Rejected):
                m.preflight_processes(lambda: {process.pid: rows[process.pid]})
            m.preflight_processes(lambda: {process.pid: rows[process.pid]}, owned_pids=(process.pid,))
        finally:
            process.stdin.close()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(timeout=5)
            process.stdout.close()
            process.stderr.close()

    def test_json_and_md_creation_are_exclusive(self):
        out = m.new_directory(self.path("exclusive"))
        m.write_json(out / "scoreboard.json", {"number": 1})
        with self.assertRaises(m.Rejected):
            m.write_json(out / "scoreboard.json", {"number": 2})
        with m.exclusive(out / "scoreboard.md") as stream:
            stream.write("1\n")
        with self.assertRaises(m.Rejected):
            m.exclusive(out / "scoreboard.md")
        self.assertEqual(m.read_json(out / "scoreboard.json"), {"number": 1})

    def test_output_symlink_and_escape_rejected(self):
        target = self.path("target")
        target.mkdir()
        link = self.path("link")
        link.symlink_to(target, target_is_directory=True)
        for path in (link / "new", m.ROOT / "Scripts/new-output", Path("/tmp/scoreboard-escape")):
            with self.subTest(path=path), self.assertRaises(m.Rejected):
                m.new_directory(path)

    def test_manifest_requires_member_hashes_and_safe_paths(self):
        manifest = m.verify_fixtures(self.fixtures)
        self.assertEqual(len(manifest["clips"]), 1)
        with self.assertRaises(m.Rejected):
            m.fixture_path(self.fixtures, "../outside")
        with self.assertRaises(m.Rejected):
            m.fixture_path(self.fixtures, "/outside")

    def test_abba_sequence_and_invalid_counts(self):
        self.assertEqual(m.run_order(2, 2), list("ABBA"))
        self.assertEqual(m.run_order(2, 3), list("ABBAAB"))
        self.assertEqual(m.run_order(1, 3), list("AAA"))
        for builds, repeats, order in ((2, 2, "AB"), (1, 1, "A"), (3, 1, None), (2, 2, "ABBC")):
            with self.assertRaises(m.Rejected):
                m.run_order(builds, repeats, order)

    def test_abba_substitute_runs_keep_builds_separate(self):
        out = self.path("abba")
        args = self.args(out)
        args.builds = str(self.build) + "," + str(self.build)
        args.repeats, args.order = 2, "ABBA"
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(m.run(args, provider=self.provider, log_collector=self.oslog), 0)
        local = m.read_json(out / "run-manifest.json")
        self.assertEqual([item["build"] for item in local["records"]], list("ABBA"))
        self.assertEqual([item["repeat"] for item in local["records"]], [1,1,2,2])
        report = m.read_json(out / "scoreboard.json")
        self.assertEqual(set(report["groups"]), {"A/9b","B/9b"})
        self.assertEqual(report["groups"]["A/9b"]["summary"]["private_unresolved"]["n"], 2)
        self.assertNotIn("asr_norm_rate_cs50_pooled", report["headline"])
        self.assertIn("9b", report["ab_comparison"])

    def test_build_dependency_changes_are_refused_without_starting_a_model(self):
        root = self.path("dependency-build")
        root.mkdir()
        paths = {}
        for relative in ("livelingo-cli", "ASRRuntime/qwen_asr_service.py", "ASRRuntime/python/bin/python3",
                         "ASRRuntime/scoreboard_timing.py", "language-python-host", "mlx_runtime/worker.py",
                         "Models/weights.bin", "asr-packages/module.py", "language-packages/module.py", "python-host"):
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"synthetic dependency\n")
            paths[relative] = path
        paths["livelingo-cli"].chmod(0o700)
        provenance = dict(commit="1" * 40, dirty=False, cli_sha256=m.sha256(paths["livelingo-cli"]),
            asr_service_sha256=m.sha256(paths["ASRRuntime/qwen_asr_service.py"]),
            asr_host_sha256=m.sha256(paths["ASRRuntime/python/bin/python3"]),
            language_host_sha256=m.sha256(paths["language-python-host"]),
            asr_timing_sha256=m.sha256(paths["ASRRuntime/scoreboard_timing.py"]),
            external_python_sha256=m.sha256(paths["python-host"]),
            mlx_runtime_tree=m.tree_manifest(root/"mlx_runtime"), models_manifest=m.tree_manifest(root/"Models"),
            asr_packages_manifest=m.tree_manifest(root/"asr-packages"), language_packages_manifest=m.tree_manifest(root/"language-packages"),
            runtime_sources=dict(python=str(paths["python-host"]), asr_site_packages=str(root/"asr-packages"),
                                 language_site_packages=str(root/"language-packages"), models=str(root/"Models")))
        m.write_json(root/"build-provenance.json",provenance)
        cli, safe = m.build_info(root)
        self.assertEqual(cli,paths["livelingo-cli"])
        self.assertTrue(safe["runtime_hashes_verified"])
        self.assertTrue(safe["external_dependency_hashes_verified"])
        self.assertNotIn(str(root),json.dumps(safe))
        for relative, path in paths.items():
            before = path.read_bytes()
            try:
                with self.subTest(dependency=relative):
                    path.write_bytes(before+b"changed\n")
                    with self.assertRaises(m.Rejected) as rejected:
                        m.build_info(root)
                    self.assertEqual(rejected.exception.code,3)
            finally:
                path.write_bytes(before)

    def test_build_without_provenance_keeps_runtime_verification_unknown(self):
        _, provenance = m.build_info(self.build)
        self.assertFalse(provenance["runtime_hashes_verified"])
        self.assertFalse(provenance["external_dependency_hashes_verified"])
        self.assertIsNone(provenance["commit"])

    def test_build_provenance_allowlist_drops_private_text_and_dependency_paths(self):
        provenance = dict(commit=SENTINEL, dirty=SENTINEL, cli_sha256="a"*64, detail=SENTINEL,
                          runtime_sources=dict(models="/private/"+SENTINEL),
                          models_manifest=dict(sha256="b"*64,files=2,text=SENTINEL))
        safe = m.safe_build_provenance(provenance)
        self.assertNotIn(SENTINEL,json.dumps(safe))
        self.assertNotIn("runtime_sources",safe)
        self.assertEqual(safe["models_manifest"],dict(sha256="b"*64,files=2))
        self.assertIsNone(safe["commit"])
        self.assertIsNone(safe["dirty"])

    def test_timeout_signals_the_actual_owned_substitute_and_retains_numeric_evidence(self):
        out = m.new_directory(self.path("timeout"))
        execution, _ = m.execute_cli(self.cli,["--replay",str(self.fixtures/"private.wav"),"--output",str(out/"session")],
                                      out,.1,provider=self.provider)
        self.assertTrue(execution["timeout"])
        self.assertTrue(execution["identity_verified"])
        self.assertFalse(execution["ownership_uncertain"])
        self.assertNotEqual(execution["exit_code"],0)
        self.assertEqual(execution["residual_owned_processes"],0)
        self.assertNotIn(SENTINEL,(out/"events.ndjson").read_text()+(out/"stderr-numeric.jsonl").read_text())

    def test_signalling_only_spawned_unchanged_identity(self):
        process = Mock(pid=42)
        process.poll.return_value = None
        row = dict(pid=42, uid=os.getuid(), started="current", executable="/synthetic/livelingo-cli")
        identity = m.classroom.identity(row)
        self.assertTrue(m.signal_owned(process, identity, lambda: {42: row}, signal.SIGINT))
        process.send_signal.assert_called_once_with(signal.SIGINT)
        process.send_signal.reset_mock()
        reused = dict(row, started="different")
        self.assertFalse(m.signal_owned(process, identity, lambda: {42: reused}, signal.SIGTERM))
        self.assertFalse(m.signal_owned(process, None, lambda: {42: row}, signal.SIGTERM))
        process.send_signal.assert_not_called()

    def test_event_white_list_drops_text_and_unknown_reason(self):
        row = m.safe_event(dict(event="cli_failed", reason=SENTINEL, code=1, text=SENTINEL, path=SENTINEL))
        self.assertEqual(row, {"event": "cli_failed", "code": 1})
        self.assertIsNone(m.safe_event(dict(event=SENTINEL, segments=1)))
        self.assertNotIn("segments", m.safe_event(dict(event="state", segments=True)))

    def test_srt_and_wave_parser_small_sample(self):
        cues = m.parse_srt("1\n00:00:00,000 --> 00:00:00,100\n<i>Synthetic example</i>\n")
        self.assertEqual(cues[0]["end_rel"], .1)
        self.assertEqual(cues[0]["text"], "Synthetic example")
        self.assertEqual(m.wav_info(self.fixtures / "private.wav")["frames"], 3200)
        with self.assertRaises(m.Rejected):
            m.parse_srt("1\ninvalid\n" + SENTINEL)

    def test_translation_output_markers_multiline_and_failure_prefix(self):
        result = m.translation_outputs("model=synthetic\nOUTPUT[0]=第一行\n第二行\nOUTPUT[1]=下一句\n")
        self.assertEqual(result, {0: "第一行\n第二行", 1: "下一句"})
        self.assertEqual(m.translation_outputs("model=synthetic\n"), {})

    def test_private_translation_file_multiline_and_partial_failure(self):
        destination = self.path("translation.jsonl")
        self.assertEqual(m.translation_file_outputs(destination), {})
        destination.write_text(json.dumps({"index": 0, "text": "第一行\n第二行"}) + "\n")
        self.assertEqual(m.translation_file_outputs(destination), {0: "第一行\n第二行"})
        destination.write_text(json.dumps({"index": 2, "text": SENTINEL}) + "\n")
        with self.assertRaises(m.Rejected) as caught:
            m.translation_file_outputs(destination)
        self.assertNotIn(SENTINEL, str(caught.exception))

    def test_compare_uses_paired_ci_noise_and_accuracy_guardrail(self):
        def group(errors, energy, censored=False):
            values = [dict(asr_critical_cs50_pooled=e, net_j_per_audio_min_pooled=j) for e, j in zip(errors, energy)]
            head = dict(asr_critical_cs50_pooled=sum(errors)/len(errors), energy_comparable=True,
                        latency_full_population_quantiles=not censored)
            return dict(profile="9b", headline=head, preview_backends={"cs50-w3-search": ["modern"]},
                        repeat_headlines=[dict(headline=v) for v in values])
        floors = {"asr_critical_cs50_pooled": {"threshold": .5}, "net_j_per_audio_min_pooled": {"threshold": 5}}
        result = m.compare_groups(group([0, 0, 0], [100, 100, 100]), group([2, 2, 2], [80, 80, 80]), noise=floors)
        self.assertEqual(result["metrics"]["asr_critical_cs50_pooled"]["conclusion"], "worse")
        self.assertEqual(result["metrics"]["net_j_per_audio_min_pooled"]["conclusion"], "better")
        self.assertEqual(result["outcome"], "tradeoff")
        self.assertEqual(result["metrics"]["asr_critical_cs50_pooled"]["paired"]["ci95"], [2, 2])

    def test_compare_rejects_unknown_backend_and_unmeasured_joules(self):
        group = dict(profile="9b", headline=dict(energy_comparable=False, latency_full_population_quantiles=False),
                     preview_backends={"private-0928-30m": ["unknown"]},
                     repeat_headlines=[dict(headline=dict(private_unresolved=1, net_j_per_audio_min_pooled=None))])
        result = m.compare_groups(group, group)
        self.assertEqual(result["metrics"]["private_unresolved"]["conclusion"], "not_comparable")
        self.assertIsNone(result["metrics"]["net_j_per_audio_min_pooled"]["delta"])

    def test_phase_energy_uses_clock_boundaries_and_adjacent_idle_power(self):
        samples = [dict(start_mono=0., end_mono=10., is_delta=True, rails_j=dict(cpu=10.,gpu=20.,ane=5.),
                        source="ioreport",mode="energy_counters",busy_seconds=dict(cpu=0.,gpu=0.,ane=None))]
        execution = dict(spawn_mono=2.,exit_mono=6.,clock_offset_start=100.)
        events = [dict(recv_mono=5.,line=dict(event="processing_finished"))]
        measured = dict(rails_idle_w={key:{"used":value} for key,value in dict(cpu=.1,gpu=.2,ane=.05).items()})
        result = m.phase_energy(measured,samples,execution,events,dict(monotonic_export_valid=True,t0=103.),1.)
        self.assertTrue(result["phase_boundaries_valid"])
        for value in result["phases_net_j"].values():
            self.assertAlmostEqual(value, 3.15)
        self.assertAlmostEqual(sum(result["phases_net_j"].values()),12.6)

    def test_missing_private_census_does_not_become_zero(self):
        run = dict(transcription=dict(other_language=None,failed=None,unresolved=None),
                   validity=dict(outcome="failed",success=False),energy=dict(comparable=False),
                   translation=dict(untranslated_segments=0),
                   latency=dict(latency_valid=False,censored={key:0 for key in ["en_commit","zh_first","zh_final","zh_final_from_start"]},
                                unmeasured={key:1 for key in ["en_commit","zh_first","zh_final","zh_final_from_start"]},
                                **{key:{"steady":dict(censored=0,unmeasured=1)} for key in ["en_commit","zh_first","zh_final","zh_final_from_start"]}))
        result = m.headline({"private-0928-30m":dict(privacy="private",audio_seconds=1.,runs=[run])})
        self.assertIsNone(result["private_unresolved"])
        self.assertIsNone(result["private_failed"])
        self.assertIsNone(result["asr_edits_cs50"])
        self.assertFalse(result["latency_full_population_quantiles"])


if __name__ == "__main__":
    unittest.main()
