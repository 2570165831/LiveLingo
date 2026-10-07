#!/usr/bin/env python3
"""Offline release-flow tests: tiny fake Apps, fake tools, no credentials/network.

All fixtures, command traces and receipts stay under this worktree's ignored
work/release-flow-tests directory. No real signing, notarization, mounting,
Gatekeeper evaluation or keychain access is performed.
"""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
APP_ID = "11111111-1111-4111-8111-111111111111"
DMG_ID = "22222222-2222-4222-8222-222222222222"

# One dispatcher is installed as separate executables in PATH, including
# notarytool and stapler. xcrun may execute ONLY these local fakes.
FAKE_TOOL = r'''
import json, os, pathlib, shutil, sys, time
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
root = pathlib.Path(os.environ["FAKE_ROOT"])
trace = root / "trace.jsonl"
scenario = os.environ["FAKE_SCENARIO"]
app_id = "11111111-1111-4111-8111-111111111111"
dmg_id = "22222222-2222-4222-8222-222222222222"
def history():
    return [json.loads(line) for line in trace.read_text().splitlines()] if trace.exists() else []
def record(**extra):
    with trace.open("a") as f:
        f.write(json.dumps(dict(tool=name, args=args, **extra)) + "\n")
def fail(message="injected failure", code=1):
    print(message, file=sys.stderr)
    sys.exit(code)
def owned(path):
    path = pathlib.Path(path)
    assert path.resolve().is_relative_to(root.resolve()), "tool target escaped fixture"
    return path
if name == "xcrun":
    assert args[0] in ("notarytool", "stapler"), args
    target = root / "bin" / args[0]
    os.execv(str(target), [str(target), *args[1:]])
elif name == "python-verify-stub":
    if args and pathlib.Path(args[0]).name == "sign-offline-app.py":
        assert "--verify-only" in args, "test must never invoke App signing"
        owned(args[args.index("--app") + 1])
        record()
        if scenario == "preflight-failure": fail()
        print('{"fixtureVerification": true, "realSignatureVerified": false}')
    else:
        os.execv(os.environ["FAKE_REAL_PYTHON"], [os.environ["FAKE_REAL_PYTHON"], *args])
elif name == "notarytool":
    assert "--wait" not in args
    assert args[args.index("--keychain-profile") + 1] == "fixture-profile"
    if "--keychain" in args: owned(args[args.index("--keychain") + 1])
    action = args[0]
    if action == "submit":
        artifact = owned(args[1])
        phase = "app" if artifact.suffix == ".zip" else "dmg"
        sid = app_id if phase == "app" else dmg_id
        record(phase=phase)
        if phase == "app" and scenario == "submit-timeout": time.sleep(10)
        if phase == "app" and scenario == "submit-failure": fail()
        if phase == "app" and scenario == "submit-crash": fail(code=138)
        if phase == "app" and scenario == "submit-malformed":
            print("not JSON"); sys.exit(0)
        if phase == "app" and scenario == "submit-no-id":
            print('{"status":"Accepted"}'); sys.exit(0)
        print(json.dumps(dict(id=sid)))
        if phase == "app" and scenario == "submit-known-id-crash": sys.exit(138)
    elif action == "info":
        phase = "app" if args[1] == app_id else "dmg"
        count = 1 + sum(e["tool"] == name and e["args"][0] == action and
                        e.get("phase") == phase for e in history())
        state = "In Progress" if count == 1 else "Accepted"
        if phase == "app" and scenario == "retry-exhausted":
            record(phase=phase); fail("temporary info failure")
        if phase == "app" and scenario == "transient" and count == 1:
            record(phase=phase); fail("temporary info failure")
        if phase == "app" and scenario == "info-malformed" and count == 1:
            record(phase=phase); print("not JSON"); sys.exit(0)
        if phase == "app" and scenario == "info-timeout":
            record(phase=phase); time.sleep(10)
        if phase == "app" and scenario == "stuck": state = "In Progress"
        if scenario == phase + "-invalid": state = "Invalid"
        if phase == "app" and scenario == "unknown-status": state = "Unknown"
        sid = args[1]
        if phase == "app" and scenario == "wrong-id": sid = dmg_id
        record(phase=phase, status=state)
        print(json.dumps(dict(id=sid, status=state)))
    elif action == "log":
        record()
        print('{"issues":[{"message":"fixture rejection"}]}')
    else: fail("unexpected notarytool command")
elif name == "ditto":
    assert args[:4] == ["-c", "-k", "--sequesterRsrc", "--keepParent"]
    app, output = owned(args[-2]), owned(args[-1])
    assert not (app / ".fake-stapled").exists(), "App ZIP must precede staple"
    record()
    output.write_text(json.dumps(dict(source=str(app))))
elif name == "stapler":
    target = owned(args[-1])
    phase = "app" if target.suffix == ".app" else "dmg"
    mounted = "verify-mount" in target.parts
    record(phase=phase, mounted=mounted)
    marker = target / ".fake-stapled" if phase == "app" else pathlib.Path(str(target) + ".stapled")
    if args[0] == "staple":
        assert any(e.get("phase") == phase and e.get("status") == "Accepted" for e in history())
        if scenario == phase + "-staple-failure": fail()
        marker.write_text("fixture ticket")
    elif args[0] == "validate":
        if scenario == phase + "-validate-failure" and not mounted: fail()
        if mounted and scenario == "mounted-ticket-failure": fail()
        assert marker.exists(), "ticket missing from actual target"
    else: fail("unexpected stapler command")
elif name == "codesign":
    target = owned(args[-1])
    record()
    if "-d" in args:
        print("Authority=Developer ID Application: Fixture (TESTTEAM)", file=sys.stderr)
    elif "--sign" in args:
        assert target.suffix == ".dmg", "no App signing permitted in fixture tests"
        if scenario == "dmg-sign-failure": fail()
        pathlib.Path(str(target) + ".signed").write_text("fixture signature")
    elif "--verify" in args:
        assert "--strict" in args
        if target.suffix == ".app":
            assert "--deep" in args
            assert (target / "Contents" / ".fake-signature").exists()
            if "verify-mount" in target.parts and scenario == "mounted-signature-failure": fail()
        else:
            assert pathlib.Path(str(target) + ".signed").exists()
    else: fail("unexpected codesign command")
elif name == "hdiutil":
    record()
    if args[0] == "create":
        payload = owned(args[args.index("-srcfolder") + 1])
        output = owned(args[-1])
        assert (payload / "LiveLingo.app" / ".fake-stapled").exists()
        assert sorted(p.name for p in payload.iterdir()) == ["Applications", "LiveLingo.app", "使用说明.txt"]
        if scenario == "create-failure": fail()
        output.write_text(json.dumps(dict(payload=str(payload))))
    elif args[0] == "verify":
        json.loads(owned(args[1]).read_text())
    elif args[0] == "attach":
        assert "-readonly" in args and "-nobrowse" in args
        mount = owned(args[args.index("-mountpoint") + 1])
        if scenario == "attach-failure": fail()
        dmg = owned(args[-1])
        payload = owned(json.loads(dmg.read_text())["payload"])
        shutil.copytree(payload, mount, dirs_exist_ok=True, symlinks=True)
    elif args[0] == "detach":
        owned(args[-1])
        if scenario == "detach-failure": fail()
    else: fail("unexpected hdiutil command")
elif name == "spctl":
    owned(args[-1]); record()
    assert args[:3] == ["--assess", "--type", "execute"]
    if scenario == "gatekeeper-failure": fail()
    print("accepted (fixture only)")
else:
    fail("unexpected fake tool: " + name)
'''


class ReleaseFlowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        parent = ROOT / "work" / "release-flow-tests"
        parent.mkdir(parents=True, exist_ok=True)
        cls.scratch = Path(tempfile.mkdtemp(prefix="run-", dir=parent))
        cls.cases = []
        print("Fixture traces retained at: " + str(cls.scratch), flush=True)

    def fixture(self, scenario):
        case = Path(tempfile.mkdtemp(prefix=scenario + "-", dir=self.scratch))
        tools = case / "bin"
        tools.mkdir()
        for name in ("xcrun", "notarytool", "stapler", "codesign", "hdiutil", "spctl",
                     "ditto", "python-verify-stub"):
            tool = tools / name
            tool.write_text("#!" + sys.executable + "\n" + FAKE_TOOL, encoding="utf-8")
            tool.chmod(0o755)
        app = case / "input with spaces" / "LiveLingo.app"
        contents = app / "Contents"
        contents.mkdir(parents=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "LiveLingo"}))
        (contents / ".fake-signature").write_text("fixture, not a real signature")
        for relative in (
            "LanguageRuntime/worker.py", "LanguageRuntime/runtime-manifest.json",
            "ASRRuntime/qwen_asr_service.py", "ASRRuntime/python/bin/python3",
            "THIRD_PARTY_NOTICES.md", "LICENSE",
            "Models/mlx-community/Qwen3.5-4B-MLX-8bit/config.json",
            "Models/lmstudio-community/Qwen3.5-9B-MLX-4bit/config.json",
            "Models/mlx-community/parakeet-tdt-0.6b-v2/config.json",
            "Models/mlx-community/Qwen3-ASR-1.7B-4bit/config.json",
        ):
            item = contents / "Resources" / relative
            item.parent.mkdir(parents=True, exist_ok=True)
            item.write_text("fixture")
        keychain = case / "fixture.keychain-db"
        keychain.write_text("not a keychain; never opened by security or real tools")
        env = {k: v for k, v in os.environ.items() if not k.startswith("LIVELINGO_")}
        env.update(PATH=str(tools) + ":/usr/bin:/bin:/usr/sbin:/sbin",
                   LIVELINGO_PYTHON=str(tools / "python-verify-stub"),
                   FAKE_ROOT=str(case), FAKE_SCENARIO=scenario, FAKE_REAL_PYTHON=sys.executable,
                   PYTHONDONTWRITEBYTECODE="1", PYTHONOPTIMIZE="")
        command = ["/bin/zsh", str(ROOT / "Scripts/build-offline-dmg.sh"), "--app", str(app),
                   "--output", str(case / "release with spaces.dmg"),
                   "--identity", "Developer ID Application: Fixture (TESTTEAM)",
                   "--keychain", str(keychain), "--notary-profile", "fixture-profile",
                   "--notary-timeout", "20", "--notary-command-timeout", "5",
                   "--notary-poll-interval", "0.001", "--notary-max-polls", "6",
                   "--notary-max-retries", "1"]
        return case, app, env, command

    def run_case(self, scenario, extra=(), command_override=None):
        case, app, env, command = self.fixture(scenario)
        if command_override:
            command = command_override(case, app, command)
        result = subprocess.run([*command, *extra], env=env, text=True, capture_output=True, timeout=30,
                                cwd=case)
        (case / "stdout.txt").write_text(result.stdout, encoding="utf-8")
        (case / "stderr.txt").write_text(result.stderr, encoding="utf-8")
        events = [json.loads(line) for line in (case / "trace.jsonl").read_text().splitlines()] \
            if (case / "trace.jsonl").exists() else []
        self.cases.append(dict(scenario=scenario, exitCode=result.returncode, directory=str(case)))
        self.assertFalse((app / ".fake-stapled").exists(), "original input was modified")
        return result, events, case

    def assert_success_order(self, events):
        def index(tool, predicate):
            return next(i for i, e in enumerate(events) if e["tool"] == tool and predicate(e))
        steps = [
            index("python-verify-stub", lambda e: True),
            index("ditto", lambda e: True),
            index("notarytool", lambda e: e["args"][0] == "submit" and e.get("phase") == "app"),
            index("notarytool", lambda e: e.get("phase") == "app" and e.get("status") == "Accepted"),
            index("stapler", lambda e: e["args"][0] == "staple" and e.get("phase") == "app"),
            index("stapler", lambda e: e["args"][0] == "validate" and e.get("phase") == "app" and not e["mounted"]),
            index("hdiutil", lambda e: e["args"][0] == "create"),
            index("codesign", lambda e: "--sign" in e["args"]),
            index("notarytool", lambda e: e["args"][0] == "submit" and e.get("phase") == "dmg"),
            index("notarytool", lambda e: e.get("phase") == "dmg" and e.get("status") == "Accepted"),
            index("stapler", lambda e: e["args"][0] == "staple" and e.get("phase") == "dmg"),
            index("stapler", lambda e: e["args"][0] == "validate" and e.get("phase") == "dmg"),
            index("hdiutil", lambda e: e["args"][0] == "attach"),
            index("stapler", lambda e: e["args"][0] == "validate" and e.get("mounted")),
            index("codesign", lambda e: "--deep" in e["args"] and "verify-mount" in e["args"][-1]),
            index("spctl", lambda e: True),
            index("hdiutil", lambda e: e["args"][0] == "detach"),
        ]
        self.assertEqual(steps, sorted(steps))
        submits = [e for e in events if e["tool"] == "notarytool" and e["args"][0] == "submit"]
        self.assertEqual([e["phase"] for e in submits], ["app", "dmg"])
        for e in events:
            if e["tool"] == "notarytool": self.assertNotIn("--wait", e["args"])

    def test_success_and_recovered_queries(self):
        for scenario in ("success", "transient", "info-malformed", "submit-known-id-crash"):
            with self.subTest(scenario=scenario):
                result, events, case = self.run_case(scenario)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assert_success_order(events)
                receipts = list(case.glob("stage-*/notary-*/receipt.json"))
                self.assertEqual(len(receipts), 2)
                self.assertEqual({json.loads(p.read_text())["status"] for p in receipts}, {"Accepted"})
                self.assertIn("最终 DMG 发布自检通过", result.stdout)

    def test_failures_stop_following_release_steps(self):
        scenarios = {
            "preflight-failure": "ditto",
            "submit-failure": "app-staple",
            "submit-crash": "app-staple",
            "submit-malformed": "app-staple",
            "submit-no-id": "app-staple",
            "app-invalid": "app-staple",
            "wrong-id": "app-staple",
            "unknown-status": "app-staple",
            "app-staple-failure": "create",
            "app-validate-failure": "create",
            "create-failure": "dmg-submit",
            "dmg-sign-failure": "dmg-submit",
            "dmg-invalid": "dmg-staple",
            "dmg-staple-failure": "attach",
            "dmg-validate-failure": "attach",
            "mounted-ticket-failure": "spctl",
            "mounted-signature-failure": "spctl",
            "gatekeeper-failure": "success-message",
            "attach-failure": "spctl",
            "detach-failure": "success-message",
        }
        for scenario, forbidden in scenarios.items():
            with self.subTest(scenario=scenario):
                result, events, case = self.run_case(scenario)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("最终 DMG 发布自检通过", result.stdout)
                for e in events:
                    if forbidden in ("ditto", "spctl"): self.assertNotEqual(e["tool"], forbidden)
                    if forbidden in ("create", "attach"):
                        self.assertFalse(e["tool"] == "hdiutil" and e["args"][0] == forbidden)
                    if forbidden == "dmg-submit":
                        self.assertFalse(e["tool"] == "notarytool" and e["args"][0] == "submit" and e.get("phase") == "dmg")
                    if forbidden.endswith("-staple"):
                        self.assertFalse(e["tool"] == "stapler" and e["args"][0] == "staple" and e.get("phase") == forbidden.split("-")[0])
                if any(e["tool"] == "hdiutil" and e["args"][0] == "attach" for e in events):
                    self.assertTrue(any(e["tool"] == "hdiutil" and e["args"][0] == "detach" for e in events))
                if scenario in ("app-invalid", "dmg-invalid"):
                    self.assertTrue(list(case.glob("stage-*/notary-*/*-log.stdout.json")))
                if scenario.startswith("submit-"):
                    self.assertEqual(sum(e["tool"] == "notarytool" and e["args"][0] == "submit" for e in events), 1)

    def test_poll_and_retry_limits(self):
        for scenario, flag, value, expected in (
            ("stuck", "--notary-max-polls", "2", "poll limit reached"),
            ("retry-exhausted", "--notary-max-polls", "6", "retry limit exceeded"),
        ):
            with self.subTest(scenario=scenario):
                result, events, _ = self.run_case(scenario, (flag, value))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)
                self.assertEqual(sum(e["tool"] == "notarytool" and e["args"][0] == "info" for e in events), 2)
                self.assertFalse(any(e["tool"] == "stapler" for e in events))

    def test_timeouts(self):
        for scenario, flags in (
            ("submit-timeout", ("--notary-command-timeout", "0.2")),
            ("info-timeout", ("--notary-timeout", "0.7", "--notary-command-timeout", "0.2")),
        ):
            with self.subTest(scenario=scenario):
                result, events, _ = self.run_case(scenario, flags)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("timed out", result.stderr)
                self.assertFalse(any(e["tool"] == "stapler" for e in events))
                self.assertEqual(sum(e["tool"] == "notarytool" and e["args"][0] == "submit" for e in events), 1)

    def test_overall_deadline_bounds_poll_sleep(self):
        result, events, _ = self.run_case("stuck", ("--notary-timeout", "0.8",
                                                   "--notary-poll-interval", "10"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("overall deadline", result.stderr)
        self.assertEqual(sum(e["tool"] == "notarytool" and e["args"][0] == "info" for e in events), 1)
        self.assertFalse(any(e["tool"] == "stapler" for e in events))

    def test_resume_by_id_does_not_submit(self):
        def command(case, app, unused):
            return [sys.executable, str(ROOT / "Scripts/notarize-artifact.py"),
                    "--submission-id", APP_ID, "--profile", "fixture-profile",
                    "--receipt-dir", str(case / "resume-receipt"), "--poll-interval", "0.001"]
        result, events, case = self.run_case("resume", command_override=command)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([e["args"][0] for e in events], ["info", "info"])
        self.assertEqual(json.loads((case / "resume-receipt/receipt.json").read_text())["submissionId"], APP_ID)

    def test_dry_run_and_missing_real_artifact_skip(self):
        result, events, _ = self.run_case("dry-run", ("--dry-run",))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events, [])
        self.assertIn("跳过真实产物检查", result.stdout)
        def command(case, app, unused):
            return ["/bin/zsh", str(ROOT / "Scripts/verify-release-dmg.sh")]
        result, events, _ = self.run_case("no-real-dmg", command_override=command)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events, [])
        self.assertIn("跳过真实发布自检", result.stdout)

    def test_existing_output_is_not_overwritten(self):
        def command(case, app, existing):
            (case / "release with spaces.dmg").write_text("keep original")
            return existing
        result, events, case = self.run_case("existing-output", command_override=command)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(events, [])
        self.assertEqual((case / "release with spaces.dmg").read_text(), "keep original")

    def test_missing_explicit_dmg_fails_without_tool_calls(self):
        def command(case, app, unused):
            return ["/bin/zsh", str(ROOT / "Scripts/verify-release-dmg.sh"),
                    "--dmg", str(case / "missing.dmg")]
        result, events, _ = self.run_case("missing-dmg", command_override=command)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(events, [])
        self.assertNotIn("跳过", result.stdout)

    def test_missing_profile_requires_explicit_value(self):
        def command(case, app, existing):
            offset = existing.index("--notary-profile")
            return existing[:offset] + existing[offset + 2:]
        result, events, _ = self.run_case("missing-profile", command_override=command)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(events, [])
        self.assertIn("--notary-profile", result.stderr)

    def test_dangling_output_symlink_is_not_followed(self):
        def command(case, app, existing):
            (case / "release with spaces.dmg").symlink_to(case / "absent-target")
            return existing
        result, events, case = self.run_case("dangling-output", command_override=command)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(events, [])
        self.assertTrue((case / "release with spaces.dmg").is_symlink())
        self.assertFalse((case / "absent-target").exists())

    def test_invalid_bounds_or_placeholder_profile_are_rejected(self):
        for flag, value in (("--notary-profile", "<你的 profile>"), ("--notary-profile", " "),
                            ("--notary-timeout", "0"), ("--notary-command-timeout", "nan"),
                            ("--notary-poll-interval", "inf"), ("--notary-max-polls", "0"),
                            ("--notary-max-retries", "-1")):
            with self.subTest(flag=flag, value=value):
                result, events, _ = self.run_case("invalid-option", (flag, value))
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(events, [])


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(ReleaseFlowTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if hasattr(ReleaseFlowTests, "scratch"):
        summary = dict(success=result.wasSuccessful(), testMethods=result.testsRun,
                       flowScenarios=len(ReleaseFlowTests.cases), cases=ReleaseFlowTests.cases)
        (ReleaseFlowTests.scratch / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        print("Offline flow scenarios: %s; passed: %s" % (len(ReleaseFlowTests.cases), result.wasSuccessful()))
    sys.exit(0 if result.wasSuccessful() else 1)
