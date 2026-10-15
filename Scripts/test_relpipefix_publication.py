"""Publication contracts using static signed bytes and host interpreters only.

Keep every synthetic fixture in the caller's evidence directory. No real
signature, mount, keychain, native runtime or publication operation is used.
"""
from contextlib import redirect_stderr, redirect_stdout
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import unittest
from unittest.mock import patch
import uuid

from Scripts import privacy_package as privacy, reviewed_resources as reviewed
from Scripts import signed_resource_review as review
from Scripts.test_relpipe6_signed_resources import thin, simulated_sign, PUBLIC, RELATIVE


ROOT = Path(__file__).resolve().parents[1]


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "Scripts" / filename)
    result = importlib.util.module_from_spec(spec)
    # CLI modules resolve their adjacent helpers just as direct execution does.
    with patch.object(sys, "path", [str(ROOT / "Scripts"), *sys.path]):
        spec.loader.exec_module(result)
    return result


class PublicationContractTests(unittest.TestCase):
    def setUp(self):
        output = Path(os.environ.get("LIVELINGO_RELPIPE_TEST_OUTPUT", ROOT / "work/relpipefix-tests"))
        self.root = output / (self._testMethodName + "-" + uuid.uuid4().hex)
        self.root.mkdir(parents=True)
        self.app = self.root / "LiveLingo.app"
        self.native = self.app / RELATIVE
        self.native.parent.mkdir(parents=True)
        source = thin()
        self.native.write_bytes(source)
        self.manifest = self.root / "manifest.json"
        self.manifest.write_text(json.dumps({"version": 1, "resources": [{
            "path": RELATIVE, "sha256": hashlib.sha256(source).hexdigest(),
            "format": "macho-public-build-strings", "package": "fixture", "version": "1",
            "reason": "Synthetic static publication fixture", "publicBuildPathsHex": [PUBLIC.encode().hex()]
        }]}))
        self.index = patch.object(reviewed, "MANIFEST", self.manifest)
        self.index.start()
        self.addCleanup(self.index.stop)
        capture = review.capture_before_signing(self.app)
        self.native.write_bytes(simulated_sign(source))
        review.finalize_signed_review(self.app, capture)

    def check(self, root=None, *options):
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(sys, "argv", ["privacy-package", "check", "--root", str(root or self.app), *options]), \
                redirect_stdout(stdout), redirect_stderr(stderr):
            code = privacy.main()
        return code, stdout.getvalue(), stderr.getvalue()

    def test_default_check_authenticates_signed_native_hashes(self):
        code, stdout, stderr = self.check()
        self.assertEqual(code, 0, stderr)
        self.assertEqual(json.loads(stdout)["reviewed_resource_files"], 1)

    def test_default_check_detects_receipt_in_dmg_layout(self):
        (self.root / "Applications").symlink_to("/Applications")
        (self.root / "使用说明.txt").write_text("Install the app.\n")
        # The manifest is a host-only file; mount payload remains separate.
        payload = self.root / "payload"
        payload.mkdir()
        for name in ("LiveLingo.app", "Applications", "使用说明.txt"):
            (self.root / name).rename(payload / name)
        self.app = payload / "LiveLingo.app"
        code, stdout, stderr = self.check(payload, "--layout", "dmg")
        self.assertEqual(code, 0, stderr)
        self.assertEqual(json.loads(stdout)["reviewed_resource_files"], 1)

    def test_explicit_final_rejects_signed_bytes_against_preparation_hash(self):
        code, stdout, stderr = self.check(None, "--phase", "final")
        self.assertEqual(code, 1)
        self.assertIn("reviewed-resource-hash-mismatch", stderr)
        self.assertEqual(stdout, "")

    def test_invalid_receipt_cannot_fall_back_to_final(self):
        (self.app / review.RECEIPT_PATH).write_text("{}")
        code, stdout, stderr = self.check()
        self.assertEqual(code, 1)
        self.assertIn("invalid-signed-review-receipt", stderr)
        self.assertEqual(stdout, "")

    def test_unsigned_tree_keeps_final_default(self):
        unsigned = self.root / "unsigned"
        unsigned.mkdir()
        (unsigned / "fixture.json").write_text('{"name":"fixture"}')
        code, stdout, stderr = self.check(unsigned)
        self.assertEqual(code, 0, stderr)
        self.assertEqual(json.loads(stdout)["metadata_files"], 1)

    def test_python39_privacy_gate_rejects_before_reviewed_resource_scan(self):
        cargo = self.app / "Contents/Resources/LanguageRuntime/Licenses/native-cargo-notices/fixture-1/DECLARATION-Cargo.toml"
        cargo.parent.mkdir(parents=True)
        cargo.write_text('[package]\nname="fixture"\nversion="1"\nlicense="MIT"\n')
        bootstrap = ("import sys; from pathlib import Path; sys.path.insert(0, sys.argv[1]); "
                     "import privacy_package, reviewed_resources; "
                     "reviewed_resources.MANIFEST=Path(sys.argv[2]); "
                     "sys.argv=['privacy-package','check','--root',sys.argv[3],'--phase','signed']; "
                     "raise SystemExit(privacy_package.main())")
        result = subprocess.run(["/usr/bin/python3", "-B", "-c", bootstrap, str(ROOT / "Scripts"),
                                 str(self.manifest), str(self.app)], text=True, capture_output=True,
                                env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"), timeout=15)
        version = subprocess.run(["/usr/bin/python3", "-c", "import sys; print(sys.version_info < (3, 11))"],
                                 text=True, capture_output=True, check=True)
        if version.stdout.strip() != "True":
            self.skipTest("system Python is no longer below the supported publication minimum")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Python 3.11", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertNotIn("file_digest", result.stderr)

    def test_version_boundary_before_privacy_scan(self):
        for version in ((3, 9), (3, 10), (3, 11), (3, 13)):
            with self.subTest(version=version), patch.object(sys, "version_info", version), \
                    patch.object(privacy, "inspect_tree", return_value={}) as scan:
                code, _, stderr = self.check(None, "--phase", "signed")
                self.assertEqual(code, int(version < (3, 11)))
                self.assertEqual(scan.call_count, int(version >= (3, 11)))
                if version < (3, 11):
                    self.assertIn("Python 3.11", stderr)

    def test_real_cli_catches_helper_privacy_errors_without_traceback(self):
        tree = self.root / "private-tree"
        tree.mkdir()
        (tree / "probe.py").write_text('BUILD=r"\\\\private-host\\share\\source.c"\n')
        result = subprocess.run([sys.executable, "-B", str(ROOT / "Scripts/privacy_package.py"),
                                 "check", "--root", str(tree)], text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 1)
        self.assertIn("privacy-package: local-path-metadata", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertNotIn(str(tree), result.stderr)

    def test_verify_only_reports_missing_signed_receipt_without_running_tools(self):
        signing = module("relpipefix_sign", "sign-offline-app.py")
        with patch.dict(sys.modules, signed_resource_review=review, privacy_package=privacy), \
                patch.object(review, "approvals_for_app", side_effect=privacy.PrivacyError("invalid-signed-resource-file")), \
                patch.object(signing, "run") as run, \
                self.assertRaisesRegex(SystemExit, "signed-resource review failed: invalid-signed-resource-file"):
            signing.verify(self.app, None, (14, 0), [], [])
        run.assert_not_called()

    def test_signing_hint_quotes_app_and_includes_all_required_flags(self):
        bundler = module("relpipefix_bundle", "bundle-mlx-app.py")
        app = "work/has spaces/LiveLingo.app"
        arguments = shlex.split(bundler.signing_next_step(app))
        self.assertEqual(arguments[arguments.index("--app") + 1], app)
        for option in ("--identity", "--certificate", "--keychain", "--review-capture"):
            self.assertLess(arguments.index(option) + 1, len(arguments))
        self.assertTrue(Path(arguments[arguments.index("--review-capture") + 1]).is_absolute())

    def test_documented_signing_command_has_capture_and_host_python(self):
        text = (ROOT / "docs/BUILDING.md").read_text()
        command = text.split('"$LIVELINGO_PYTHON" Scripts/sign-offline-app.py --app ', 1)[1].split("\n\n", 1)[0]
        self.assertIn("--review-capture", command)
        self.assertIn("Python 3.11", text)
        self.assertIn("--privacy-phase signed", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
