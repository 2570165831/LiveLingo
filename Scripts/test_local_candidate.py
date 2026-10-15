import json
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tempfile
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

try:
    from . import local_candidate as candidate
except ImportError:
    import local_candidate as candidate


class LocalCandidateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()

    def test_input_change_is_detected_even_with_same_size(self):
        runtime = self.root / "runtime"; runtime.mkdir()
        file = runtime / "weights"; file.write_bytes(b"abcd")
        receipt = {"schema": 1, "contracts": {"lock": "fixed"}, "inputs": {
            "models": {"path": str(runtime), "fingerprint": candidate.fingerprint(runtime)}}}
        with patch.object(candidate, "contract_hashes", return_value={"lock": "fixed"}):
            candidate.check_inputs(receipt)
            file.write_bytes(b"abce")
            with self.assertRaisesRegex(ValueError, "input changed"):
                candidate.check_inputs(receipt)

    def test_changed_lock_or_preparation_policy_rejects_reuse(self):
        with patch.object(candidate, "contract_hashes", return_value={"lock": "new"}):
            with self.assertRaisesRegex(ValueError, "policy/lock changed"):
                candidate.check_inputs({"schema": 1, "contracts": {"lock": "old"}, "inputs": {}})

    def test_output_roots_cannot_overwrite_inputs_or_each_other(self):
        candidate.disjoint_outputs([self.root / 'app', self.root / 'records', self.root / 'dd'], [self.root / 'models'])
        for outputs, inputs in [([self.root / 'models'], [self.root / 'models']),
                                ([self.root / 'models/dd'], [self.root / 'models']),
                                ([self.root], [self.root / 'models']),
                                ([self.root / 'app', self.root / 'app/dd'], [])]:
            with self.subTest(outputs=outputs), self.assertRaises(ValueError):
                candidate.disjoint_outputs(outputs, inputs)

    def test_separate_child_sessions_are_paused_without_signaling_other_agents(self):
        with patch.object(candidate, 'pulse', return_value=(((1, '0:00'), (2, '0:00')), {77})), \
             patch.object(candidate.os, 'getpgid', side_effect=lambda pid: pid), \
             patch.object(candidate.os, 'kill') as kill:
            candidate.signal_other_descendants(1, signal.SIGSTOP)
        kill.assert_called_once_with(2, signal.SIGSTOP)

    def test_executable_modes_and_link_targets_are_fingerprinted(self):
        root = self.root / "tree"; root.mkdir()
        file = root / "tool"; file.write_bytes(b"data"); file.chmod(0o644)
        first = candidate.fingerprint(root)
        file.chmod(0o755)
        self.assertNotEqual(first, candidate.fingerprint(root))
        link = root / "link"; link.symlink_to("tool")
        second = candidate.fingerprint(root)
        link.unlink(); link.symlink_to("other")
        self.assertNotEqual(second, candidate.fingerprint(root))

    def test_resume_accepts_final_signed_writer_but_rejects_tampering(self):
        app = self.root / "app"; app.mkdir(); (app / "main").write_bytes(b"signed")
        stages = {"clone": {"artifact": {"sha256": "old"}},
                  "sign": {"artifact": candidate.fingerprint(app)}}
        candidate.reusable(stages, {"clone": app, "sign": app})
        (app / "main").write_bytes(b"forged")
        with self.assertRaisesRegex(ValueError, "artifact changed"):
            candidate.reusable(stages, {"clone": app, "sign": app})

    def test_quarantine_keeps_exact_bytes_instead_of_deleting(self):
        artifact = self.root / "failed"; artifact.mkdir(); (artifact / "main").write_bytes(b"keep")
        with patch.object(candidate.subprocess, "run", return_value=SimpleNamespace(returncode=1, stdout="", stderr="")):
            candidate.quarantine(artifact, self.root)
        receipts = [json.loads(line) for line in (self.root / "quarantine.jsonl").read_text().splitlines()]
        self.assertEqual([row["phase"] for row in receipts], ["planned", "completed"])
        receipt = receipts[-1]
        self.assertFalse(artifact.exists())
        self.assertEqual((Path(receipt["destination"]) / "main").read_bytes(), b"keep")

    def test_live_holders_prevent_quarantine(self):
        artifact = self.root / "active"; artifact.mkdir()
        with patch.object(candidate.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout="42\n", stderr="")):
            with self.assertRaisesRegex(ValueError, "active"):
                candidate.quarantine(artifact, self.root)
        self.assertTrue(artifact.is_dir())

    def test_partial_image_reports_are_quarantined_as_regular_files(self):
        report = self.root / "final-image-metadata.json"; report.write_bytes(b"failed image audit")
        with patch.object(candidate.subprocess, "run", return_value=SimpleNamespace(returncode=1, stdout="", stderr="")) as lsof:
            candidate.quarantine(report, self.root)
        self.assertNotIn("+D", lsof.call_args.args[0])
        receipt = json.loads((self.root / "quarantine.jsonl").read_text().splitlines()[-1])
        self.assertEqual(Path(receipt["destination"]).read_bytes(), b"failed image audit")
        self.assertFalse(report.exists())

    def test_plan_keeps_unsigned_reference_and_has_no_notary_commands(self):
        args = SimpleNamespace(work=str(self.root / "artifacts"), records=str(self.root / "records"),
                               derived_data=str(self.root / "dd"), python="/usr/bin/python3",
                               identity="Developer ID Application: Test", certificate=str(self.root / "test.cer"),
                               keychain=str(self.root / "test.keychain-db"))
        inputs = {name: {"path": str(self.root / name)} for name in ("language", "asr", "models")}
        commands, artifacts = candidate.plan(args, inputs)
        self.assertIn("--candidate-only", commands["dmg"])
        self.assertIn("--candidate-only", commands["dmg-verify"])
        for stage in ("dmg", "dmg-verify"):
            command = commands[stage]
            self.assertTrue(Path(command[command.index("--mount-point") + 1]).is_relative_to(args.records))
            self.assertTrue(Path(command[command.index("--xattr-report") + 1]).is_relative_to(args.records))
        self.assertEqual(commands["dmg"][commands["dmg"].index("--image-method") + 1], "hybrid")
        self.assertNotEqual(artifacts["assemble"], artifacts["sign"])
        self.assertEqual(commands["clone"][0:2], ["/bin/cp", "-cR"])
        for command in commands.values():
            self.assertFalse(any(Path(arg).name in ("notarytool", "stapler", "open") for arg in command))

    def fake_child(self):
        return SimpleNamespace(pid=333333, poll=lambda: None, wait=lambda timeout: 0, returncode=0)

    def test_free_machine_poll_does_not_reset_stall_timeout(self):
        clock = [0.0]
        def sleep(seconds):
            clock[0] += seconds
        with patch.object(candidate.time, "monotonic", side_effect=lambda: clock[0]), \
             patch.object(candidate.time, "sleep", side_effect=sleep), \
             patch.object(candidate.subprocess, "run", return_value=SimpleNamespace(returncode=0)), \
             patch.object(candidate.subprocess, "Popen", return_value=self.fake_child()), \
             patch.object(candidate, "pulse", return_value=(((333333, "0:00"),), set())), \
             patch.object(candidate, "signal_other_descendants"), \
             patch.object(candidate.os, "killpg") as kill:
            with self.assertRaisesRegex(RuntimeError, "15 minutes"):
                candidate.execute(["fixture"], self.root / "log", self.root / "gate", {})
        self.assertGreaterEqual(clock[0], 900)
        self.assertLess(clock[0], 905)
        self.assertIn((333333, signal.SIGTERM), [call.args for call in kill.call_args_list])

    def test_interaction_agent_stops_only_owned_child_group(self):
        with patch.object(candidate.subprocess, "run", return_value=SimpleNamespace(returncode=0)), \
             patch.object(candidate.subprocess, "Popen", return_value=self.fake_child()), \
             patch.object(candidate, "pulse", side_effect=[((), set()), ((), {77})]), \
             patch.object(candidate, "signal_other_descendants"), \
             patch.object(candidate.os, "killpg") as kill:
            with self.assertRaisesRegex(RuntimeError, "SecurityAgent"):
                candidate.execute(["fixture"], self.root / "log", self.root / "gate", {})
        self.assertTrue(all(call.args[0] == 333333 for call in kill.call_args_list))

    def test_failed_signing_resumes_from_fresh_clone_without_rebuilding_or_replacing_reference(self):
        work = self.root / "artifacts"; records = self.root / "records"; dd = self.root / "dd"
        bare = dd / "Build/Products/Release/LiveLingo.app"
        unsigned = work / "unsigned/LiveLingo.app"; signed = work / "signed/LiveLingo.app"
        inputs = {}
        for name in ("language", "asr", "models"):
            directory = self.root / name; directory.mkdir()
            inputs[name] = {"path": str(directory), "fingerprint": candidate.fingerprint(directory)}
        receipt = self.root / "inputs.json"
        receipt.write_text(json.dumps({"schema": 1, "contracts": {}, "inputs": inputs}))
        args = ["run", "--commit", "f" * 40, "--work", str(work), "--records", str(records),
                "--derived-data", str(dd), "--inputs-receipt", str(receipt),
                "--machine-free", str(self.root / "gate"), "--identity", "Developer ID Application: Fixture",
                "--certificate", str(self.root / "fixture.cer"), "--keychain", str(self.root / "fixture.keychain"),
                "--python", sys.executable, "--expected-version", "0.3.0"]
        executed = []; attempts = [0]; verification_attempts = [0]
        def execute(command, log, gate, env, **kwargs):
            stage = log.name.rsplit("-", 1)[0]; executed.append(stage); log.write_text("synthetic fixture")
            if stage == "build":
                (bare / "Contents").mkdir(parents=True)
                (bare / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleShortVersionString": "0.3.0"}))
                (bare / "main").write_bytes(b"unsigned")
            elif stage in ("assemble", "clone"):
                target = unsigned if stage == "assemble" else signed
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copytree(bare if stage == "assemble" else unsigned, target)
            elif stage == "sign":
                attempts[0] += 1
                (signed / "main").write_bytes(b"partial" if attempts[0] == 1 else b"signed")
                (records / "signing-run/before-signing.json").write_text("synthetic fixture")
            elif stage == "dmg":
                (work / "dmg").mkdir(); (work / "dmg/LiveLingo-candidate.dmg").write_bytes(b"synthetic image")
            elif stage == "dmg-verify":
                verification_attempts[0] += 1
                with (records / "final-image-metadata.json").open("x") as stream:
                    stream.write("synthetic image metadata")
            failed = stage == "sign" and attempts[0] == 1 or stage == "dmg-verify" and verification_attempts[0] == 1
            return {"exitCode": 1 if failed else (3 if stage == "assessment" else 0),
                    "wallSeconds": 1, "log": str(log)}
        def git(command, **kwargs):
            return "" if "status" in command else "f" * 40 + "\n"
        handlers = {value: signal.getsignal(value) for value in (signal.SIGTERM, signal.SIGHUP)}
        self.addCleanup(lambda: [signal.signal(key, value) for key, value in handlers.items()])
        real_mkdir = Path.mkdir; interrupted_directory = [False]
        def mkdir(path, *positional, **kwargs):
            result = real_mkdir(path, *positional, **kwargs)
            if path == work / "signed" and not interrupted_directory[0]:
                interrupted_directory[0] = True
                raise OSError("synthetic interruption after directory creation")
            return result
        with patch.object(candidate, "contract_hashes", return_value={}), \
             patch.object(candidate.Path, "mkdir", mkdir), \
             patch.object(candidate.subprocess, "check_output", side_effect=git), \
             patch.object(candidate.subprocess, "run", side_effect=lambda command, **kwargs: SimpleNamespace(
                 returncode=1 if command[0] == "/usr/sbin/lsof" else 0, stdout="", stderr="")), \
             patch.object(candidate, "execute", side_effect=execute):
            with self.assertRaisesRegex(OSError, "synthetic interruption"):
                candidate.main(args)
            self.assertEqual(json.loads((records / "state.json").read_text())["running"], "clone")
            with self.assertRaisesRegex(RuntimeError, "stage failed: sign"):
                candidate.main(args)
            self.assertEqual((unsigned / "main").read_bytes(), b"unsigned")
            with self.assertRaisesRegex(RuntimeError, "stage failed: dmg-verify"):
                candidate.main(args)
            self.assertEqual(candidate.main(args), 0)
            self.assertEqual((unsigned / "main").read_bytes(), b"unsigned")
            self.assertEqual((signed / "main").read_bytes(), b"signed")
            self.assertEqual(executed.count("build"), 1)
            self.assertEqual(executed.count("assemble"), 1)
            self.assertEqual(executed.count("clone"), 2)
            self.assertEqual(executed.count("dmg"), 1)
            self.assertEqual(executed.count("dmg-verify"), 2)
            before = executed[:]
            self.assertEqual(candidate.main(args), 0)
            self.assertEqual(before, executed)
            (unsigned / "main").write_bytes(b"tampered")
            with self.assertRaisesRegex(ValueError, "artifact changed"):
                candidate.main(args)


if __name__ == "__main__":
    unittest.main()
