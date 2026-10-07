#!/usr/bin/env python3
"""Offline release tests. Explicit absolute stubs; temp fixtures removed on exit.

No real signing, keychains, notarytool, stapler, spctl or mounting. Image stubs
snapshot their source, so later edits cannot masquerade as image contents.
"""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parent.parent
APP_ID = "11111111-1111-4111-8111-111111111111"
DMG_ID = "22222222-2222-4222-8222-222222222222"
IDENTITY = "Developer ID Application: Fixture (TESTTEAM)"
# Recognizable ARM64 MH_EXECUTE header only; no fixture native code is executed.
NATIVE_FIXTURE = struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, 0, 0, 0, 0)
FAKE_TOOL = r'''
import json, os, pathlib, plistlib, shutil, signal, sys, time
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
root = pathlib.Path(os.environ["FAKE_ROOT"])
trace = root / "trace.jsonl"
scenario = os.environ["FAKE_SCENARIO"]
identity = "Developer ID Application: Fixture (TESTTEAM)"
app_id = "11111111-1111-4111-8111-111111111111"
dmg_id = "22222222-2222-4222-8222-222222222222"
def history():
    return [json.loads(line) for line in trace.read_text().splitlines()] if trace.exists() else []
def record(**extra):
    with trace.open("a") as f:
        f.write(json.dumps(dict(tool=name, args=args, pid=os.getpid(), **extra)) + "\n")
def fail(message="injected failure", code=1):
    print(message, file=sys.stderr, flush=True)
    sys.exit(code)
def owned(value):
    path = pathlib.Path(value)
    assert path.is_absolute() and path.resolve().is_relative_to(root.resolve()), "escaped fixture: " + str(path)
    return path

def image(path):
    return json.loads(owned(path).read_text())
def save_image(path, value):
    owned(path).write_text(json.dumps(value))
def prior(tool, predicate):
    return any(e["tool"] == tool and predicate(e) for e in history())
if name == "python-verify-stub":
    if args and pathlib.Path(args[0]).name == "sign-offline-app.py":
        assert "--verify-only" in args and args[args.index("--identity") + 1] == identity
        target = owned(args[args.index("--app") + 1])
        record()
        if scenario == "preflight-failure": fail()
        assert (target / "Contents/.fake-signature").exists()
    else:
        if args and pathlib.Path(args[0]).name == "notarize-artifact.py":
            if scenario == "resume-receipt-missing" and "--submission-id" in args:
                fail("interrupted before query receipt creation", 143)
            if os.environ.get("FAKE_EXPECT_BOUNDS"):
                for flag, value in json.loads(os.environ["FAKE_EXPECT_BOUNDS"]).items():
                    assert args[args.index(flag) + 1] == value, "incorrect helper budget: " + flag
                record(budgetChecked=True)
        if (args and pathlib.Path(args[0]).name == "release-state.py" and
                args[1] == "record-artifact" and args[3] == "stapledDMG" and scenario == "stapled-checkpoint-failure"):
            fail("interrupted after staple, before checkpoint", 143)
        os.execv(os.environ["FAKE_REAL_PYTHON"], [os.environ["FAKE_REAL_PYTHON"], *args])
elif name == "notarytool":
    assert "--wait" not in args
    assert args[args.index("--keychain-profile") + 1] == "fixture-profile"
    if os.environ.get("FAKE_NOTARY_KEYCHAIN"):
        assert args[args.index("--keychain") + 1] == os.environ["FAKE_NOTARY_KEYCHAIN"]
    else:
        assert "--keychain" not in args, "signing keychain leaked into profile search"
    action = args[0]
    if action == "submit":
        assert "--no-progress" in args and "--output-format" not in args, "submit must stream text"
        artifact = owned(args[1]); data = image(artifact); phase = data["kind"]
        sid = app_id if phase == "app" else dmg_id
        assert artifact.suffix == ".dmg", "no non-ZIP64 ZIP upload"
        if phase == "dmg":
            assert data["signed"]
            assert prior("codesign", lambda e: "--verify" in e["args"] and e["args"][-1] == str(artifact))
            assert prior("hdiutil", lambda e: e["args"][:2] == ["verify", str(artifact)])
        record(phase=phase)
        if scenario == phase + "-auth-failure": fail("HTTP status code: 401. Invalid credentials")
        if scenario == phase + "-profile-failure": fail("No Keychain password item found for profile: fixture-profile")
        if scenario == phase + "-submit-failure": fail("connection lost")
        if scenario == phase + "-submit-crash": fail(code=138)
        if scenario == phase + "-submit-malformed": print("garbled output", flush=True); sys.exit(0)
        if scenario == phase + "-submit-no-id": print("Successfully uploaded file", flush=True); sys.exit(0)
        print("Submission ID received\n  id: " + sid, flush=True)
        if scenario == "interrupt-upload":
            (root / "upload-ready").write_text(str(os.getpid()))
            time.sleep(300)
        if scenario == phase + "-submit-known-id-crash": fail("upload interrupted", 138)
        print("Successfully uploaded file\n  id: " + sid + "\n  path: " + str(artifact), flush=True)
    elif action == "info":
        assert args[args.index("--output-format") + 1] == "json"
        assert args[1] in (app_id, dmg_id)
        phase = "app" if args[1] == app_id else "dmg"
        count = 1 + sum(e["tool"] == name and e["args"][0] == action and e.get("phase") == phase for e in history())
        state = "In Progress" if count == 1 else "Accepted"
        record(phase=phase)
        if scenario == phase + "-retry-exhausted": fail("temporary info failure")
        if scenario == phase + "-transient" and count == 1: fail("temporary info failure")
        if scenario == phase + "-info-malformed" and count == 1: print("not JSON"); sys.exit(0)
        if scenario == phase + "-stuck": state = "In Progress"
        if scenario in (phase + "-invalid", phase + "-log-failure"): state = "Invalid"
        if scenario == phase + "-rejected": state = "Rejected"
        if scenario == "unknown-status": state = "Unknown"
        sid = dmg_id if scenario == "wrong-id" and phase == "app" else args[1]
        record(phase=phase, status=state, result=True)
        print(json.dumps(dict(id=sid, status=state)))
    elif action == "log":
        phase = "app" if args[1] == app_id else "dmg"
        record(phase=phase)
        if scenario == phase + "-log-failure": fail("diagnostic log unavailable")
        print('{"issues":[{"message":"fixture rejection"}]}')
    else: fail("unexpected notarytool action")
elif name == "ditto":
    assert args[:2] == ["--rsrc", "--extattr"], "stage copy must preserve metadata"
    source, target = owned(args[-2]), owned(args[-1])
    record()
    if scenario == "copy-failure": fail()
    if source.is_dir(): shutil.copytree(source, target, symlinks=True)
    else: shutil.copy2(source, target, follow_symlinks=False)
elif name == "stapler":
    target = owned(args[-1]); phase = "app" if target.suffix == ".app" else "dmg"
    mounted = "verify-mount" in target.parts or "standalone-mount" in target.parts
    count = 1 + sum(e["tool"] == name and e["args"][0] == args[0] and e.get("phase") == phase for e in history())
    record(phase=phase, mounted=mounted)
    marker = target / ".fake-stapled"
    if args[0] == "staple":
        assert not mounted
        assert prior("notarytool", lambda e: e.get("phase") == phase and e.get("status") == "Accepted")
        if scenario == phase + "-staple-failure": fail("ticket service unavailable", 68)
        if scenario == phase + "-staple-transient" and count == 1: fail("ticket service unavailable", 68)
        if phase == "app": marker.write_text(json.dumps({"fixture": "notarization ticket"}))
        else:
            data = image(target); assert data["signed"]; data["stapled"] = True; save_image(target, data)
    elif args[0] == "validate":
        if scenario == phase + "-validate-failure" and not mounted: fail()
        if mounted and scenario == "mounted-ticket-failure": fail()
        if mounted and scenario == "interrupt-verify":
            (root / "verify-ready").write_text(str(os.getpid()))
            time.sleep(300)
        assert marker.exists() if phase == "app" else image(target).get("stapled"), "ticket absent from exact target"
    else: fail("unexpected stapler action")
elif name == "codesign":
    target = owned(args[-1]); phase = "app" if target.suffix == ".app" else "dmg"
    mounted = "verify-mount" in target.parts or "standalone-mount" in target.parts
    stapled = (target / ".fake-stapled").exists() if phase == "app" else image(target).get("stapled", False)
    record(phase=phase, mounted=mounted, stapled=stapled)
    if "-d" in args:
        authority = "Developer ID Application: Wrong (OTHER)" if scenario == phase + "-authority-failure" or (mounted and scenario == "mounted-authority-failure") else identity
        print("Authority=" + authority, file=sys.stderr)
    elif "--sign" in args:
        assert phase == "dmg", "no App signing in flow tests"
        assert "--timestamp" in args and "--force" in args
        assert args[args.index("--sign") + 1] == identity
        assert args[args.index("--keychain") + 1] == str(root / "fixture.keychain-db")
        if scenario == "dmg-sign-failure": fail()
        data = image(target); data["signed"] = True; save_image(target, data)
    elif "--verify" in args:
        assert "--strict" in args
        if phase == "app":
            assert "--deep" in args and (target / "Contents/.fake-signature").exists()
            if not mounted and not stapled and target.parent.name == "LiveLingo" and scenario == "staged-pre-verify-failure": fail()
            if not mounted and stapled and scenario == "app-post-verify-failure": fail()
            if mounted and scenario == "mounted-signature-failure": fail()
        else:
            assert image(target)["signed"]
            if scenario == "dmg-signature-failure": fail()
    else: fail("unexpected codesign action")
elif name == "hdiutil":
    action = args[0]
    if action == "create":
        payload = owned(args[args.index("-srcfolder") + 1]); output = owned(args[-1])
        assert args[args.index("-format") + 1] == "UDZO"
        assert int(args[args.index("-size") + 1].removesuffix("b")) >= 256 * 1024**2
        assert args[args.index("-imagekey") + 1] == "zlib-level=6"
        entries = sorted(p.name for p in payload.iterdir())
        phase = "app" if entries == ["LiveLingo.app"] else "dmg"
        app = payload / "LiveLingo.app"
        assert prior("codesign", lambda e: e.get("phase") == "app" and "--verify" in e["args"] and e["args"][-1] == str(app))
        if phase == "app": assert not (app / ".fake-stapled").exists()
        else:
            assert entries == ["Applications", "LiveLingo.app", "使用说明.txt"]
            assert (app / ".fake-stapled").exists()
            assert prior("stapler", lambda e: e["args"] == ["validate", str(app)])
            assert prior("codesign", lambda e: e["args"][-1] == str(app) and "--verify" in e["args"] and e["stapled"])
        record(phase=phase)
        if scenario == phase + "-create-failure": fail()
        snapshot = root / ("image-snapshot-%s" % sum(e["tool"] == name and e["args"][0] == "create" for e in history()))
        shutil.copytree(payload, snapshot, symlinks=True)
        save_image(output, dict(kind=phase, snapshot=str(snapshot), signed=False, stapled=False))
    elif action == "verify":
        data = image(args[1]); record(phase=data["kind"])
        if scenario == data["kind"] + "-image-verify-failure": fail()
    elif action == "attach":
        assert "-plist" in args and "-readonly" in args and "-nobrowse" in args
        mount = owned(args[args.index("-mountpoint") + 1]); data = image(args[-1])
        record()
        if scenario == "attach-failure": fail("attach failed without device")
        if scenario == "attach-malformed": print("not a plist"); sys.exit(0)
        shutil.copytree(owned(data["snapshot"]), mount, dirs_exist_ok=True, symlinks=True)
        if scenario == "privacy-mounted":
            private = mount / "LiveLingo.app/.migration-source-fixture"
            private.mkdir(); (private / "transcript.txt").write_text("synthetic classroom canary")
        (root / "mounted.json").write_text(json.dumps(dict(device="/dev/disk999", mount=str(mount), image=str(owned(args[-1])))))
        if scenario == "interrupt-attach":
            (root / "attach-ready").write_text(str(os.getpid()))
            time.sleep(300)
        sys.stdout.buffer.write(plistlib.dumps({"system-entities":[{"dev-entry":"/dev/disk999"}, {"dev-entry":"/dev/disk999s1", "mount-point":str(mount)}]}))
        if scenario == "attach-partial-failure": sys.exit(1)
    elif action == "info":
        assert args == ["info", "-plist"]
        record()
        images = []
        if (root / "mounted.json").exists():
            data = json.loads((root / "mounted.json").read_text())
            images = [{"image-path":data["image"], "system-entities":[{"dev-entry":data["device"]},
                      {"dev-entry":data["device"] + "s1", "mount-point":data["mount"]}]}]
        sys.stdout.buffer.write(plistlib.dumps({"images": images}))
    elif action == "detach":
        assert args == ["detach", "/dev/disk999"], "detach must use device, not an ordinary directory"
        data = json.loads((root / "mounted.json").read_text()); mount = owned(data["mount"])
        count = 1 + sum(e["tool"] == name and e["args"][0] == action for e in history())
        record()
        if scenario == "detach-failure" or (scenario == "detach-transient" and count == 1): fail("Resource busy")
        for child in mount.iterdir():
            if child.is_symlink() or child.is_file(): child.unlink()
            else: shutil.rmtree(child)
        (root / "mounted.json").unlink()
    else: fail("unexpected hdiutil action")
elif name == "spctl":
    target = owned(args[-1]); phase = "dmg" if target.suffix == ".dmg" else "app"
    record(phase=phase)
    assert "--verbose=2" in args
    if phase == "dmg":
        assert args[:5] == ["--assess", "--type", "open", "--context", "context:primary-signature"]
        assert image(target)["stapled"] and image(target)["signed"]
    else:
        assert args[:3] == ["--assess", "--type", "execute"]
        assert (target / ".fake-stapled").exists()
    if scenario == phase + "-gatekeeper-failure": fail()
    print("accepted\nsource=" + ("Unnotarized Developer ID" if scenario == "dmg-gatekeeper-wrong-source" else "Notarized Developer ID"))
else: fail("unexpected fake tool: " + name)
'''


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


class ReleaseFlowTests(unittest.TestCase):
    cases = []
    mutations = 0

    @classmethod
    def setUpClass(cls):
        cls.scratch_parent = Path(tempfile.gettempdir()).resolve()
        cls.scratch = Path(tempfile.mkdtemp(prefix="livelingo-release-tests-", dir=cls.scratch_parent))
        print("Offline fixtures: " + str(cls.scratch), flush=True)

    @classmethod
    def tearDownClass(cls):
        assert cls.scratch.parent == cls.scratch_parent and not cls.scratch.is_symlink()
        shutil.rmtree(cls.scratch)
        print("Offline fixtures removed: " + str(not cls.scratch.exists()), flush=True)

    def fixture(self, scenario):
        case = Path(tempfile.mkdtemp(prefix=scenario + "-", dir=self.scratch))
        tools = case / "bin"; tools.mkdir()
        for name in ("notarytool", "stapler", "codesign", "hdiutil", "spctl", "ditto", "python-verify-stub"):
            tool = tools / name
            tool.write_text("#!" + sys.executable + "\n" + FAKE_TOOL)
            tool.chmod(0o755)
        app = case / "input with spaces/LiveLingo.app"
        contents = app / "Contents"; contents.mkdir(parents=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "LiveLingo"}))
        (contents / ".fake-signature").write_text(json.dumps({"fixture": "not a real signature"}))
        for relative in ("LanguageRuntime/worker.py", "LanguageRuntime/runtime-manifest.json", "ASRRuntime/qwen_asr_service.py",
                         "ASRRuntime/python/bin/python3", "THIRD_PARTY_NOTICES.md", "LICENSE",
                         "Models/mlx-community/Qwen3.5-4B-MLX-8bit/config.json", "Models/lmstudio-community/Qwen3.5-9B-MLX-4bit/config.json",
                         "Models/mlx-community/parakeet-tdt-0.6b-v2/config.json", "Models/mlx-community/Qwen3-ASR-1.7B-4bit/config.json"):
            item = contents / "Resources" / relative; item.parent.mkdir(parents=True, exist_ok=True); item.write_text("fixture")
            if relative == "ASRRuntime/python/bin/python3":
                item.write_bytes(NATIVE_FIXTURE)
            elif item.suffix == ".json":
                item.write_text(json.dumps({"components": [], "python": "python"}
                                           if item.name == "runtime-manifest.json" else {}))
        keychain = case / "fixture.keychain-db"; keychain.write_text("not a keychain")
        env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": str(self.scratch)}
        env.update(LIVELINGO_TEST_TOOL_DIR=str(tools), LIVELINGO_PYTHON=str(tools / "python-verify-stub"),
                   FAKE_ROOT=str(case), FAKE_SCENARIO=scenario, FAKE_REAL_PYTHON=sys.executable,
                   PYTHONDONTWRITEBYTECODE="1", PYTHONOPTIMIZE="")
        command = ["/bin/zsh", str(ROOT / "Scripts/build-offline-dmg.sh"), "--app", str(app),
                   "--output", str(case / "release with spaces.dmg"), "--identity", IDENTITY,
                   "--keychain", str(keychain), "--notary-profile", "fixture-profile",
                   "--notary-timeout", "60", "--notary-command-timeout", "30", "--notary-poll-interval", "0.001",
                   "--notary-max-polls", "6", "--notary-max-retries", "1", "--staple-max-attempts", "3", "--staple-retry-delay", "0.001"]
        return case, app, env, command

    def events(self, case):
        return [json.loads(line) for line in (case / "trace.jsonl").read_text().splitlines()] if (case / "trace.jsonl").exists() else []

    def execute(self, case, env, command):
        result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=90, cwd=case)
        self.cases.append(dict(scenario=env["FAKE_SCENARIO"], exitCode=result.returncode))
        return result, self.events(case)

    def run_case(self, scenario, extra=(), override=None):
        case, app, env, command = self.fixture(scenario)
        if override: command = override(case, app, command, env)
        result, events = self.execute(case, env, [*command, *extra])
        self.assertFalse((app / ".fake-stapled").exists(), "original input was modified")
        return result, events, case

    @staticmethod
    def calls(events, tool, action=None, phase=None):
        return [e for e in events if e["tool"] == tool and (action is None or e["args"][0] == action) and
                (phase is None or e.get("phase") == phase) and not e.get("result")]

    def assert_success_order(self, events):
        def at(tool, predicate):
            return next(i for i, e in enumerate(events) if e["tool"] == tool and predicate(e))
        steps = [at("ditto", lambda e: True),
                 at("codesign", lambda e: "--verify" in e["args"] and e.get("phase") == "app" and not e["stapled"]),
                 at("hdiutil", lambda e: e["args"][0] == "create" and e.get("phase") == "app"),
                 at("notarytool", lambda e: e["args"][0] == "submit" and e.get("phase") == "app"),
                 at("notarytool", lambda e: e.get("phase") == "app" and e.get("status") == "Accepted"),
                 at("stapler", lambda e: e["args"][0] == "staple" and e.get("phase") == "app"),
                 at("stapler", lambda e: e["args"][0] == "validate" and e.get("phase") == "app" and not e["mounted"]),
                 at("codesign", lambda e: "--verify" in e["args"] and e.get("phase") == "app" and e["stapled"] and not e["mounted"]),
                 at("hdiutil", lambda e: e["args"][0] == "create" and e.get("phase") == "dmg"),
                 at("codesign", lambda e: "--sign" in e["args"]),
                 at("codesign", lambda e: "--verify" in e["args"] and e.get("phase") == "dmg"),
                 at("hdiutil", lambda e: e["args"][0] == "verify" and e.get("phase") == "dmg"),
                 at("notarytool", lambda e: e["args"][0] == "submit" and e.get("phase") == "dmg"),
                 at("notarytool", lambda e: e.get("phase") == "dmg" and e.get("status") == "Accepted"),
                 at("stapler", lambda e: e["args"][0] == "staple" and e.get("phase") == "dmg"),
                 at("stapler", lambda e: e["args"][0] == "validate" and e.get("phase") == "dmg"),
                 at("spctl", lambda e: e.get("phase") == "dmg"),
                 at("hdiutil", lambda e: e["args"][0] == "attach"),
                 at("stapler", lambda e: e["args"][0] == "validate" and e["mounted"]),
                 at("codesign", lambda e: "--verify" in e["args"] and e["mounted"]),
                 at("spctl", lambda e: e.get("phase") == "app"),
                 at("hdiutil", lambda e: e["args"][0] == "detach")]
        self.assertEqual(steps, sorted(steps))
        self.assertEqual([e["phase"] for e in self.calls(events, "notarytool", "submit")], ["app", "dmg"])

    def test_success_and_transient_recovery(self):
        for scenario in ("success", "app-transient", "dmg-transient", "app-info-malformed", "dmg-info-malformed",
                         "app-staple-transient", "dmg-staple-transient", "detach-transient"):
            with self.subTest(scenario=scenario):
                result, events, case = self.run_case(scenario)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assert_success_order(events)
                receipts = list(case.glob("stage-*/run-*/notary-*/receipt.json"))
                self.assertEqual(len(receipts), 2)
                self.assertTrue(all(json.loads(p.read_text())["uploadComplete"] for p in receipts))
                self.assertTrue(all(json.loads(p.read_text())["status"] == "Accepted" for p in receipts))
                self.assertTrue((case / "release with spaces.dmg").is_file())
                self.assertFalse(list(case.glob("stage-*/verify-mount")))
                self.assertIn("最终 DMG 发布自检通过", result.stdout)

    def test_failure_injections_do_not_publish(self):
        scenarios = ("preflight-failure", "copy-failure", "staged-pre-verify-failure", "app-create-failure", "app-image-verify-failure",
                     "app-authority-failure", "app-submit-failure", "app-submit-crash", "app-submit-malformed", "app-submit-no-id",
                     "app-submit-known-id-crash", "app-auth-failure", "app-profile-failure", "app-invalid", "app-rejected", "app-log-failure",
                     "wrong-id", "unknown-status", "app-staple-failure", "app-validate-failure", "app-post-verify-failure",
                     "dmg-create-failure", "dmg-sign-failure", "dmg-signature-failure", "dmg-image-verify-failure", "dmg-authority-failure",
                     "dmg-submit-known-id-crash", "dmg-auth-failure", "dmg-invalid", "dmg-rejected", "dmg-log-failure",
                     "dmg-staple-failure", "dmg-validate-failure", "dmg-gatekeeper-failure", "dmg-gatekeeper-wrong-source",
                     "mounted-ticket-failure", "mounted-signature-failure", "mounted-authority-failure", "app-gatekeeper-failure", "attach-failure", "attach-malformed",
                     "attach-partial-failure", "detach-failure")
        for scenario in scenarios:
            with self.subTest(scenario=scenario):
                result, events, case = self.run_case(scenario)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn("最终 DMG 发布自检通过", result.stdout)
                self.assertFalse((case / "release with spaces.dmg").exists())
                if "submit-" in scenario or scenario.endswith(("auth-failure", "profile-failure")):
                    phase = scenario.split("-")[0]
                    self.assertEqual(len(self.calls(events, "notarytool", "submit", phase)), 1)
                    self.assertEqual(self.calls(events, "notarytool", "info", phase), [])
                    receipt = json.loads(next(case.glob("stage-*/run-*/notary-" + phase + "/receipt.json")).read_text())
                    self.assertFalse(receipt["uploadComplete"])
                    if scenario.endswith(("auth-failure", "profile-failure")):
                        self.assertIn("authentication/profile failed", result.stderr)
                        self.assertNotIn("submission outcome unknown", result.stderr)
                        self.assertEqual(receipt["status"], "Authentication/profile failed")
                    else:
                        self.assertIn("submission outcome unknown", result.stderr)
                if scenario in ("attach-failure", "attach-malformed"):
                    self.assertFalse(self.calls(events, "hdiutil", "detach"))
                    self.assertFalse(list(case.glob("stage-*/verify-mount")))
                if scenario == "attach-partial-failure":
                    self.assertEqual(len(self.calls(events, "hdiutil", "detach")), 1)
                if scenario == "detach-failure":
                    self.assertEqual(len(self.calls(events, "hdiutil", "detach")), 3)
                if scenario in ("app-staple-failure", "dmg-staple-failure"):
                    self.assertEqual(len(self.calls(events, "stapler", "staple", scenario.split("-")[0])), 3)
                if scenario.endswith("log-failure"):
                    self.assertIn("log", result.stderr)

    def test_private_signed_inputs_are_rejected_without_mutation_or_upload(self):
        for kind in ("recovery", "manifest", "body", "metrics", "unexpected-resource", "symlink"):
            with self.subTest(kind=kind):
                case, app, env, command = self.fixture("privacy-input-" + kind)
                if kind == "recovery":
                    item = app / ".migration-source-fixture/transcript.txt"
                elif kind == "manifest":
                    item = app / "Contents/Resources/LanguageRuntime/runtime-manifest.json"
                elif kind == "body":
                    item = app / "Contents/Resources/LanguageRuntime/innocent.json"
                elif kind == "metrics":
                    item = app / "Contents/Resources/LanguageRuntime/classroom-metrics.json"
                elif kind == "unexpected-resource":
                    item = app / "Contents/Resources/handout.txt"
                else:
                    item = app / "Contents/Resources/LanguageRuntime/escape"
                item.parent.mkdir(parents=True, exist_ok=True)
                if kind == "manifest":
                    item.write_text(json.dumps({"components": [], "python": str(case / "private-python")}))
                elif kind == "body":
                    item.write_text(json.dumps({"originalText": "synthetic classroom canary"}))
                elif kind == "symlink":
                    item.symlink_to(case)
                else:
                    item.write_text("synthetic classroom canary")
                before = os.readlink(item) if item.is_symlink() else item.read_bytes()
                result, events = self.execute(case, env, command)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("privacy-package:", result.stderr)
                self.assertNotIn("synthetic classroom canary", result.stdout + result.stderr)
                self.assertEqual(before, os.readlink(item) if item.is_symlink() else item.read_bytes())
                self.assertFalse(self.calls(events, "hdiutil", "create"))
                self.assertFalse(self.calls(events, "notarytool", "submit"))
                self.assertFalse((case / "release with spaces.dmg").exists())

    def test_resumed_private_stage_is_rejected_before_more_notary_calls(self):
        case, app, env, command = self.fixture("app-stuck")
        result, before = self.execute(case, env, command)
        self.assertNotEqual(result.returncode, 0)
        stage = next(case.glob("stage-*"))
        private = stage / "LiveLingo/LiveLingo.app/.cli-runtime/run.json"
        private.parent.mkdir(); private.write_text("synthetic private run")
        env["FAKE_SCENARIO"] = "success"
        result, after = self.execute(case, env, [command[0], command[1], "--resume-stage", str(stage),
                                                 "--notary-profile", "fixture-profile"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("privacy-package:", result.stderr)
        self.assertEqual(self.calls(before, "notarytool"), self.calls(after, "notarytool"))
        self.assertEqual(private.read_text(), "synthetic private run")
        self.assertFalse((case / "release with spaces.dmg").exists())

    def test_mounted_privacy_failure_detaches_and_does_not_publish(self):
        result, events, case = self.run_case("privacy-mounted")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("privacy-package:", result.stderr)
        self.assertEqual(len(self.calls(events, "hdiutil", "detach")), 1)
        self.assertFalse((case / "release with spaces.dmg").exists())
        self.assertFalse(list(case.glob("stage-*/verify-mount")))

    def test_resume_entire_build_reuses_uploads(self):
        for scenario in ("app-stuck", "app-retry-exhausted", "app-staple-failure", "dmg-stuck", "dmg-retry-exhausted", "dmg-staple-failure", "stapled-checkpoint-failure", "mounted-ticket-failure"):
            with self.subTest(scenario=scenario):
                case, app, env, command = self.fixture(scenario)
                result, before = self.execute(case, env, command)
                self.assertNotEqual(result.returncode, 0)
                stage = next(case.glob("stage-*"))
                env["FAKE_SCENARIO"] = "success"
                resumed = [command[0], command[1], "--resume-stage", str(stage), "--notary-profile", "fixture-profile",
                           "--notary-poll-interval", "0.001", "--staple-retry-delay", "0.001"]
                if scenario == "app-stuck": resumed += ["--app-submission-id", APP_ID]
                if scenario == "dmg-stuck": resumed += ["--dmg-submission-id", DMG_ID]
                result, after = self.execute(case, env, resumed)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual([e["phase"] for e in self.calls(after, "notarytool", "submit")], ["app", "dmg"])
                if scenario.startswith("dmg") or scenario == "mounted-ticket-failure":
                    self.assertEqual(len(self.calls(before, "hdiutil", "create")), len(self.calls(after, "hdiutil", "create")))
                self.assertFalse((app / ".fake-stapled").exists())
                self.assertTrue((case / "release with spaces.dmg").exists())

    def test_missing_query_receipt_never_reuploads(self):
        for phase in ("app", "dmg"):
            with self.subTest(phase=phase):
                case, app, env, command = self.fixture(phase + "-stuck")
                result, before = self.execute(case, env, command)
                self.assertNotEqual(result.returncode, 0)
                stage = next(case.glob("stage-*"))
                resumed = [command[0], command[1], "--resume-stage", str(stage), "--notary-profile", "fixture-profile",
                           "--notary-poll-interval", "0.001"]
                env["FAKE_SCENARIO"] = "resume-receipt-missing"
                result, events = self.execute(case, env, resumed)
                self.assertNotEqual(result.returncode, 0)
                state = json.loads((stage / "release-state.json").read_text())
                self.assertFalse(Path(state[phase + "Receipt"]).exists())
                self.assertTrue(Path(state[phase + "PreviousReceipt"]).exists())
                env["FAKE_SCENARIO"] = "success"
                result, events = self.execute(case, env, resumed + ["--resubmit-incomplete"])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual([e["phase"] for e in self.calls(events, "notarytool", "submit")], ["app", "dmg"])

    def test_incomplete_id_needs_explicit_new_upload(self):
        case, app, env, command = self.fixture("app-submit-known-id-crash")
        result, events = self.execute(case, env, command)
        self.assertNotEqual(result.returncode, 0)
        receipt = json.loads(next(case.glob("stage-*/run-*/notary-app/receipt.json")).read_text())
        self.assertEqual(receipt["submissionId"], APP_ID)
        self.assertFalse(receipt["uploadComplete"])
        stage = next(case.glob("stage-*")); env["FAKE_SCENARIO"] = "success"
        resumed = [command[0], command[1], "--resume-stage", str(stage), "--notary-profile", "fixture-profile", "--notary-poll-interval", "0.001"]
        for flags in ([], ["--app-submission-id", APP_ID]):
            result, events = self.execute(case, env, resumed + flags)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(len(self.calls(events, "notarytool", "submit")), 1)
        result, events = self.execute(case, env, resumed + ["--resubmit-incomplete"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([e["phase"] for e in self.calls(events, "notarytool", "submit")], ["app", "app", "dmg"])

    def test_mutated_stage_image_is_not_resumed(self):
        case, app, env, command = self.fixture("dmg-stuck")
        self.execute(case, env, command)
        stage = next(case.glob("stage-*")); state = json.loads((stage / "release-state.json").read_text())
        Path(state["releaseDMG"]).write_text("changed artifact")
        env["FAKE_SCENARIO"] = "success"
        result, events = self.execute(case, env, [command[0], command[1], "--resume-stage", str(stage), "--notary-profile", "fixture-profile"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("已改变", result.stderr)
        self.assertEqual(len(self.calls(events, "notarytool", "submit")), 2)

    def test_poll_and_retry_limits_for_both_phases(self):
        for phase in ("app", "dmg"):
            for suffix, extra, expected in (("stuck", ["--notary-max-polls", "2"], "poll limit reached"),
                                            ("retry-exhausted", [], "retry limit exceeded")):
                with self.subTest(phase=phase, suffix=suffix):
                    result, events, _ = self.run_case(phase + "-" + suffix, extra)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(expected, result.stderr)
                    self.assertEqual(len(self.calls(events, "notarytool", "info", phase)), 2)
                    self.assertFalse(self.calls(events, "stapler", "staple", phase))

    def test_separate_notary_keychain(self):
        def command(case, app, existing, env):
            profile_keychain = case / "profile-only.keychain-db"; profile_keychain.write_text("fixture")
            env["FAKE_NOTARY_KEYCHAIN"] = str(profile_keychain)
            return existing + ["--notary-keychain", str(profile_keychain)]
        result, events, _ = self.run_case("separate-keychain", override=command)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_no_ambient_path_release_tools(self):
        def command(case, app, existing, env):
            poison = case / "poison"; poison.mkdir()
            for name in ("codesign", "hdiutil", "xcrun", "notarytool", "spctl", "ditto", "stapler"):
                tool = poison / name; tool.write_text("#!/bin/sh\nexit 99\n"); tool.chmod(0o755)
            env["PATH"] = str(poison)
            return existing
        result, _, _ = self.run_case("path-poison", override=command)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_system_python_stdlib_compatibility(self):
        def command(case, app, existing, env):
            env["FAKE_REAL_PYTHON"] = "/usr/bin/python3"
            return existing
        result, events, _ = self.run_case("system-python", override=command)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_success_order(events)

    def test_build_forwards_nondefault_notary_budgets(self):
        def command(case, app, existing, env):
            env["FAKE_EXPECT_BOUNDS"] = json.dumps({"--submit-timeout":"1234", "--timeout":"456", "--command-timeout":"17"})
            return existing + ["--notary-submit-timeout", "1234", "--notary-timeout", "456", "--notary-command-timeout", "17"]
        result, events, _ = self.run_case("budget-forwarding", override=command)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sum(e.get("budgetChecked", False) for e in events), 2)

    def test_skip_or_invalid_inputs_never_call_tools(self):
        for mode in ("dry-run", "verify-no-dmg", "verify-missing-dmg", "existing-output", "dangling-output", "missing-profile"):
            def command(case, app, existing, env):
                if mode == "dry-run": return existing + ["--dry-run"]
                if mode.startswith("verify-"):
                    return ["/bin/zsh", str(ROOT / "Scripts/verify-release-dmg.sh")] + ([] if mode == "verify-no-dmg" else ["--dmg", str(case / "missing.dmg")])
                if mode == "existing-output": (case / "release with spaces.dmg").write_text("keep original")
                if mode == "dangling-output": (case / "release with spaces.dmg").symlink_to(case / "absent-target")
                if mode == "missing-profile":
                    at = existing.index("--notary-profile"); return existing[:at] + existing[at+2:]
                return existing
            with self.subTest(mode=mode):
                result, events, case = self.run_case(mode, override=command)
                self.assertEqual(events, [])
                self.assertEqual(result.returncode == 0, mode in ("dry-run", "verify-no-dmg"))
                if mode == "existing-output": self.assertEqual((case / "release with spaces.dmg").read_text(), "keep original")
                if mode == "dangling-output": self.assertFalse((case / "absent-target").exists())

    def test_invalid_bounds_are_rejected_before_tools(self):
        for flag, value in (("--notary-profile", "<你的 profile>"), ("--notary-profile", " "), ("--notary-timeout", "0"),
                            ("--notary-submit-timeout", "-1"), ("--notary-submit-timeout", "nan"), ("--notary-command-timeout", "nan"),
                            ("--notary-poll-interval", "inf"), ("--notary-max-polls", "0"), ("--notary-max-retries", "-1"), ("--staple-max-attempts", "0")):
            with self.subTest(flag=flag, value=value):
                result, events, _ = self.run_case("invalid-option", [flag, value])
                self.assertNotEqual(result.returncode, 0); self.assertEqual(events, [])

    def test_zip_upload_is_not_an_unvalidated_fallback(self):
        def command(case, app, unused, env):
            archive = case / "unvalidated.zip"; archive.write_text("fixture")
            return [sys.executable, str(ROOT / "Scripts/notarize-artifact.py"), "--artifact", str(archive),
                    "--profile", "fixture-profile", "--receipt-dir", str(case / "zip-receipt")]
        result, events, case = self.run_case("zip-rejected", override=command)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ZIP uploads are not supported", result.stderr)
        self.assertEqual(events, [])
        self.assertFalse((case / "zip-receipt").exists())

    def test_protected_and_symlinked_output_locations(self):
        for output in ("/Applications/LiveLingo.dmg", "/System/tmp/a.dmg", "/Library/a.dmg", "/usr/a.dmg", "/Volumes/a.dmg", str(Path.home() / "a.dmg")):
            with self.subTest(output=output):
                result, events, _ = self.run_case("protected-output", ["--output", output])
                self.assertNotEqual(result.returncode, 0); self.assertEqual(events, [])
        def command(case, app, existing, env):
            (case / "alias").symlink_to("/Applications")
            return existing + ["--output", str(case / "alias/release.dmg")]
        result, events, _ = self.run_case("aliased-output", override=command)
        self.assertNotEqual(result.returncode, 0); self.assertEqual(events, [])
        def input_alias(case, app, existing, env):
            (case / "input-alias").symlink_to(app)
            return existing + ["--output", str(case / "input-alias/release.dmg")]
        result, events, _ = self.run_case("output-in-aliased-input", override=input_alias)
        self.assertNotEqual(result.returncode, 0); self.assertEqual(events, [])
        def stage_command(case, app, existing, env):
            env["LIVELINGO_OFFLINE_OUTPUT_DIR"] = "/Applications"
            return existing
        result, events, _ = self.run_case("protected-staging", override=stage_command)
        self.assertNotEqual(result.returncode, 0); self.assertEqual(events, [])

    def wait_until(self, predicate, process):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if predicate(): return
            if process.poll() is not None: self.fail("process exited before synchronization: " + str(process.returncode))
            time.sleep(0.01)
        self.fail("fixture synchronization deadline exceeded")

    def test_upload_signals_keep_early_id_and_stop_child(self):
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            with self.subTest(sig=sig):
                case, app, env, unused = self.fixture("interrupt-upload")
                artifact = case / "App-notarization.dmg"; artifact.write_text(json.dumps(dict(kind="app")))
                receipt = case / "interrupted-receipt/receipt.json"
                command = [sys.executable, str(ROOT / "Scripts/notarize-artifact.py"), "--artifact", str(artifact), "--profile", "fixture-profile", "--receipt-dir", str(receipt.parent)]
                process = subprocess.Popen(command, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    self.wait_until(lambda: (case / "upload-ready").exists() and receipt.exists() and json.loads(receipt.read_text()).get("submissionId") == APP_ID, process)
                    child_pid = int((case / "upload-ready").read_text())
                    process.send_signal(sig)
                    stdout, stderr = process.communicate(timeout=15)
                    self.assertNotEqual(process.returncode, 0)
                    data = json.loads(receipt.read_text()); self.assertEqual(data["submissionId"], APP_ID); self.assertFalse(data["uploadComplete"])
                    self.assertNotIn("Resume with --submission-id", stderr)
                    with self.assertRaises(ProcessLookupError): os.kill(child_pid, 0)
                    self.assertFalse(self.calls(self.events(case), "notarytool", "info"))
                    self.cases.append(dict(scenario="signal-" + str(sig), exitCode=process.returncode))
                finally:
                    if process.poll() is None: process.kill(); process.communicate()

    def test_verify_signals_detach_the_reported_device(self):
        for sig in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(sig=sig):
                case, app, env, command = self.fixture("interrupt-verify")
                process = subprocess.Popen(command, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
                try:
                    self.wait_until(lambda: (case / "verify-ready").exists(), process)
                    os.killpg(process.pid, sig)
                    stdout, stderr = process.communicate(timeout=15)
                    self.assertNotEqual(process.returncode, 0)
                    self.assertEqual(len(self.calls(self.events(case), "hdiutil", "detach")), 1)
                    self.assertFalse(list(case.glob("stage-*/verify-mount")))
                    self.assertNotIn("最终 DMG 发布自检通过", stdout)
                    self.cases.append(dict(scenario="verify-signal-" + str(sig), exitCode=process.returncode))
                finally:
                    if process.poll() is None: os.killpg(process.pid, signal.SIGKILL); process.communicate()

    def test_signals_during_attach_recover_the_exact_device(self):
        for sig in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(sig=sig):
                case, app, env, command = self.fixture("interrupt-attach")
                process = subprocess.Popen(command, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
                try:
                    self.wait_until(lambda: (case / "attach-ready").exists(), process)
                    os.killpg(process.pid, sig)
                    stdout, stderr = process.communicate(timeout=15)
                    self.assertNotEqual(process.returncode, 0)
                    events = self.events(case)
                    self.assertEqual(len(self.calls(events, "hdiutil", "info")), 1)
                    self.assertEqual(len(self.calls(events, "hdiutil", "detach")), 1)
                    self.assertFalse(list(case.glob("stage-*/verify-mount")))
                    self.assertFalse((case / "mounted.json").exists())
                    self.assertNotIn("最终 DMG 发布自检通过", stdout)
                    self.cases.append(dict(scenario="attach-signal-" + str(sig), exitCode=process.returncode))
                finally:
                    if process.poll() is None: os.killpg(process.pid, signal.SIGKILL); process.communicate()

    def test_signing_arguments_without_real_signing(self):
        signing = module("sign_offline_fixture", ROOT / "Scripts/sign-offline-app.py")
        case, app, env, unused = self.fixture("sign-arguments")
        main = app / "Contents/MacOS/LiveLingo"; main.parent.mkdir(); main.write_bytes(NATIVE_FIXTURE)
        helper = app / "Contents/MacOS/helper"; helper.write_bytes(NATIVE_FIXTURE)
        # Exercise the real signing command construction, intercept every tool call.
        commands = []
        with patch.object(signing, "run", side_effect=lambda c, **kw: commands.append(c)), \
             patch.object(signing.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")):
            signing.sign(app, IDENTITY, str(case / "fixture.keychain-db"), case / "app.plist", case / "inherit.plist",
                         [(main, [{"filetype": signing.MH_EXECUTE}]), (helper, [{"filetype": signing.MH_EXECUTE}])])
        self.assertGreaterEqual(len(commands), 2)
        for command in commands:
            self.assertEqual(command[0], "/usr/bin/codesign")
            self.assertEqual(command[command.index("--options") + 1], "runtime")
            self.assertIn("--timestamp", command)
            self.assertEqual(command[command.index("--sign") + 1], IDENTITY)
            self.assertEqual(command[command.index("--keychain") + 1], str(case / "fixture.keychain-db"))

    def worker(self):
        notary = module("notary_fixture", ROOT / "Scripts/notarize-artifact.py")
        case, app, env, unused = self.fixture("deterministic-clock")
        artifact = case / "container.dmg"; artifact.write_text("fixture")
        receipts = case / "receipts"; receipts.mkdir()
        args = SimpleNamespace(artifact=artifact, submission_id=None, receipt_dir=receipts,
                               timeout=3600, submit_timeout=0, command_timeout=60, profile="fixture-profile",
                               notary_keychain=None, max_polls=3, max_retries=0, poll_interval=30)
        worker = notary.Notarizer(args)
        worker.notarytool = str(case / "bin/notarytool")
        return notary, worker

    def test_upload_budget_is_independent_of_processing_budget(self):
        for limit in (0, 72000):
            with self.subTest(limit=limit):
                notary, worker = self.worker(); worker.args.submit_timeout = limit
                clock = [100.0]; calls = []
                def execute(action, command, timeout):
                    calls.append(action)
                    if action == "submit":
                        self.assertIsNone(worker.deadline)
                        self.assertEqual(timeout, limit or None)
                        self.assertIn("--no-progress", command)
                        self.assertNotIn("--output-format", command)
                        clock[0] += 100000  # Simulated long upload; no wall-clock delay.
                        worker.observe_submit_line("id: " + APP_ID)
                        self.assertEqual(json.loads((worker.args.receipt_dir / "receipt.json").read_text())["submissionId"], APP_ID)
                        worker.observe_submit_line("Successfully uploaded file")
                        return 0, "", "", False
                    self.assertEqual(action, "info")
                    self.assertEqual(timeout, 60)
                    self.assertEqual(worker.deadline, clock[0] + 3600)
                    self.assertEqual(command[command.index("--output-format") + 1], "json")
                    return 0, json.dumps(dict(id=APP_ID, status="Accepted")), "", False
                with patch.object(notary.time, "monotonic", side_effect=lambda: clock[0]), \
                     patch.object(worker, "resolve_notarytool"), patch.object(worker, "execute", side_effect=execute):
                    worker.run()
                self.assertEqual(calls, ["submit", "info"])
                self.assertTrue(worker.receipt["uploadComplete"])

    def test_submit_and_info_timeouts_without_timing_races(self):
        # Drive the actual pipe/deadline loop with a logical clock and inert
        # process/selector. No interpreter startup must beat a short timeout.
        for action in ("submit", "info"):
            with self.subTest(action=action):
                notary, worker = self.worker()
                read_out, write_out = os.pipe(); read_err, write_err = os.pipe()
                process = SimpleNamespace(stdout=os.fdopen(read_out, "rb"), stderr=os.fdopen(read_err, "rb"), returncode=None)
                process.poll = lambda: process.returncode
                process.wait = lambda **kwargs: process.returncode
                selector = MagicMock(); selector.get_map.return_value = {"pending": True}; selector.select.return_value = []
                clock = [0.0]
                def tick():
                    clock[0] += 0.5
                    return clock[0]
                def stop(unused): process.returncode = -9
                try:
                    with patch.object(notary.time, "monotonic", side_effect=tick), \
                         patch.object(notary.subprocess, "Popen", return_value=process), \
                         patch.object(notary.selectors, "DefaultSelector", return_value=selector), \
                         patch.object(worker, "stop_process_group", side_effect=stop) as stopped:
                        code, stdout, stderr, timed_out = worker.execute(action, ["inert"], 2)
                    self.assertTrue(timed_out); self.assertEqual(code, -9); stopped.assert_called_once_with(process)
                finally:
                    os.close(write_out); os.close(write_err)
                    if not process.stdout.closed: process.stdout.close()
                    if not process.stderr.closed: process.stderr.close()
        notary, worker = self.worker(); calls = []
        def execute(action, command, timeout):
            calls.append(action)
            if action == "submit":
                worker.observe_submit_line("id: " + APP_ID)
                worker.observe_submit_line("Successfully uploaded file")
                return 0, "", "", False
            return -9, "", "fixture timeout", True
        with patch.object(worker, "resolve_notarytool"), patch.object(worker, "execute", side_effect=execute):
            with self.assertRaisesRegex(notary.NotarizationError, "info retry limit exceeded: info exit -9, command timed out"):
                worker.run()
        self.assertEqual(calls, ["submit", "info"])

    def test_processing_deadline_bounds_commands_and_pause(self):
        notary, worker = self.worker(); clock = [99.0]; worker.deadline = 100.0
        captured = []
        with patch.object(notary.time, "monotonic", side_effect=lambda: clock[0]), \
             patch.object(worker, "execute", side_effect=lambda action, command, timeout: captured.append(timeout)):
            worker.command("info", APP_ID); worker.command("log", APP_ID)
        self.assertEqual(captured, [1, 1])
        with patch.object(notary.time, "monotonic", side_effect=lambda: clock[0]), \
             patch.object(notary.time, "sleep", side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)):
            with self.assertRaisesRegex(notary.NotarizationError, "processing deadline"):
                worker.pause()
        self.assertEqual(clock[0], 100)

    def test_notary_flag_mutations_are_rejected(self):
        source = (ROOT / "Scripts/notarize-artifact.py").read_text()
        for name, before, after in (("no-progress", '["--no-progress"]', '[]'),
                                   ("info-json", '["--output-format", "json"]', '[]'),
                                   ("profile", '"--keychain-profile", self.args.profile', '"--wrong-profile", self.args.profile')):
            with self.subTest(mutation=name):
                self.assertIn(before, source)
                case, app, env, unused = self.fixture("notary-mutation-" + name)
                artifact = case / "container.dmg"; artifact.write_text(json.dumps(dict(kind="app")))
                path = case / "mutated-notary.py"; path.write_text(source.replace(before, after))
                command = [sys.executable, str(path), "--artifact", str(artifact), "--profile", "fixture-profile", "--receipt-dir", str(case / "receipt"),
                           "--max-retries", "0", "--poll-interval", "0.001"]
                result, _ = self.execute(case, env, command)
                self.assertNotEqual(result.returncode, 0)
                type(self).mutations += 1

    def test_critical_mutations_are_rejected(self):
        source = (ROOT / "Scripts/build-offline-dmg.sh").read_text()
        mutations = {
            "timestamp": (' --timestamp "${staged_dmg}"', ' "${staged_dmg}"'),
            "sign-keychain": (' --keychain "${keychain_path}" --timestamp', ' --timestamp'),
            "upload-budget": ('--submit-timeout "${notary_submit_timeout}"', ''),
            "processing-budget": ('--timeout "${notary_timeout}"', ''),
            "query-budget": ('--command-timeout "${notary_command_timeout}"', ''),
            "post-app-verify": ('  "${codesign_bin}" --verify --deep --strict --verbose=2 "${staged_app}"', '  : # removed post-staple verify'),
            "pre-app-verify": ('"${codesign_bin}" --verify --deep --strict --verbose=2 "${staged_app}"\ncheck_authority', ': # removed pre-upload verify\ncheck_authority'),
            "dmg-strict-verify": ('  "${codesign_bin}" --verify --strict --verbose=2 "${staged_dmg}"', '  : # removed DMG verification'),
            "dmg-image-verify": ('  "${hdiutil_bin}" verify "${staged_dmg}"', '  : # removed image verification'),
            "staple-order": ('  staple_with_retry "${staged_app}"', '  : # removed staple before image creation'),
            "staple-before-acceptance": ('notarize_phase app "${app_container}" "${app_submission_id}"\nif [[ "$(state_get appStapled)" != yes ]]; then\n  staple_with_retry "${staged_app}"',
                                        'staple_with_retry "${staged_app}"\nif [[ "$(state_get appStapled)" != yes ]]; then\n  notarize_phase app "${app_container}" "${app_submission_id}"'),
        }
        for name, (before, after) in mutations.items():
            with self.subTest(mutation=name):
                self.assertIn(before, source)
                case, app, env, command = self.fixture("mutation-" + name)
                env["FAKE_EXPECT_BOUNDS"] = json.dumps({"--submit-timeout":"0", "--timeout":"60", "--command-timeout":"30"})
                # Keep project_root explicit; the mutated entry point itself stays in our temp fixture.
                mutated = source.replace('project_root="${0:A:h:h}"', 'project_root="' + str(ROOT) + '"').replace(before, after)
                path = case / "mutated-build.sh"; path.write_text(mutated); command[1] = str(path)
                result, _ = self.execute(case, env, command)
                self.assertNotEqual(result.returncode, 0, name + " mutation escaped checks")
                type(self).mutations += 1


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(ReleaseFlowTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    print("Offline flow executions: %s; mutation checks: %s; test methods: %s; passed: %s" %
          (len(ReleaseFlowTests.cases), ReleaseFlowTests.mutations, result.testsRun, result.wasSuccessful()))
    sys.exit(0 if result.wasSuccessful() else 1)
