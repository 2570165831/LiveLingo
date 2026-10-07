"""Synthetic packaging boundaries; no models, signing, mounting or user data."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from Scripts import privacy_package as privacy


ROOT = Path(__file__).resolve().parent.parent
CANARY = "synthetic classroom canary"


def load_script(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), ROOT / "Scripts" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    with patch.dict(sys.modules, privacy_package=privacy):
        spec.loader.exec_module(module)
    return module


class PrivacyPackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="privacy-package-tests-")
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / "source"
        self.source.mkdir()
        self.output = self.root / "delivery"

    def tearDown(self):
        self.temporary.cleanup()

    def write(self, relative, text=CANARY, root=None):
        path = (root or self.source) / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def manifest(self, python="python"):
        return {"components": [{"name": "fixture", "version": "1.0", "licenses": ["LICENSE"],
                                 "source": "https://example.invalid/releases/fixture", "sha256": "abc"}],
                "python": python, "workerHashes": {"worker.py": "def"}, "missingLicenseFiles": [],
                "nativeTransitiveNoticeAudit": {"status": "fixture", "scope": "Synthetic public notices"}}

    def test_recovery_copies_run_records_metrics_and_sidecars_are_omitted(self):
        private = [".migration-source-fixture/transcript.txt", "nested/.migration-source/session.json",
                   "migration-recovery.json", ".cli-runtime/run.json", "nested/run.json",
                   "classroom-metrics.json", "classroom_metrics.txt", "ReviewDiagnostics/input.json",
                   "Checkpoints/prompt.safetensors", "durable-transcription/work.jsonl",
                   "nested/.DS_Store", "nested/._LICENSE", ".git/config", "trace.log", "worker.pyc"]
        for name in private:
            self.write(name)
        translation_files = [self.write(".translation-content/input.txt"),
                             self.write(".translation-content/translations.jsonl")]
        translation_directory = self.source / ".translation-content"
        translation_directory.chmod(0o700)
        for path in translation_files:
            path.chmod(0o600)
        def identity(path):
            value = path.lstat()
            return (value.st_ino, value.st_size, value.st_mtime_ns, value.st_mode)
        before = {path: identity(path) for path in [translation_directory, *translation_files]}
        license_path = self.write("Licenses/fixture/LICENSE", "Synthetic license must be retained")
        self.write("Licenses/fixture/source.json", '{"url":"https://example.invalid/LICENSE","revision":"abc"}')
        def guard(operation):
            def checked(path, *args, **kwargs):
                if ".translation-content" in path.parts:
                    raise AssertionError("private translation directory must not be traversed or read")
                return operation(path, *args, **kwargs)
            return checked
        with patch.object(Path, "iterdir", guard(Path.iterdir)), \
             patch.object(Path, "read_text", guard(Path.read_text)), \
             patch.object(Path, "read_bytes", guard(Path.read_bytes)):
            result = privacy.copy_distribution_tree(self.source, self.output)
        self.assertGreater(result["excluded"], 0)
        for name in private:
            self.assertFalse((self.output / name).exists(), name)
            self.assertEqual((self.source / name).read_text(), CANARY)
        self.assertFalse((self.output / ".translation-content").exists())
        for path, prior in before.items():
            self.assertEqual(identity(path), prior)
        self.assertEqual((self.output / "Licenses/fixture/LICENSE").read_bytes(), license_path.read_bytes())
        self.assertTrue((self.output / "Licenses/fixture/source.json").is_file())

    def test_copy_public_manifest_keeps_notices_hashes_and_original_provenance(self):
        original = self.manifest(str(self.root / "private-build/python"))
        original["buildRecord"] = {"sourceDirectory": str(self.root / "private-build")}
        path = self.write("runtime-manifest.json", json.dumps(original))
        before = path.read_bytes()
        privacy.copy_distribution_tree(self.source, self.output)
        public = json.loads((self.output / "runtime-manifest.json").read_text())
        self.assertEqual(public["python"], "python")
        self.assertNotIn("buildRecord", public)
        for key in ("components", "workerHashes", "nativeTransitiveNoticeAudit", "missingLicenseFiles"):
            self.assertEqual(public[key], original[key])
        self.assertEqual(path.read_bytes(), before)
        self.assertNotIn(str(self.root), (self.output / "runtime-manifest.json").read_text())

    def test_read_only_check_refuses_old_manifest_and_preserves_it(self):
        path = self.write("runtime-manifest.json", json.dumps(self.manifest(str(self.root / "python"))))
        before = path.read_bytes()
        with self.assertRaises(privacy.PrivacyError):
            privacy.inspect_tree(self.source)
        self.assertEqual(path.read_bytes(), before)

    def test_public_manifest_is_idempotent_and_does_not_modify_input(self):
        original = self.manifest()
        before = json.dumps(original)
        public = privacy.distribution_manifest(original)
        self.assertEqual(public, privacy.distribution_manifest(public))
        self.assertEqual(json.dumps(original), before)

    def test_invalid_manifest_fails_without_creating_delivery(self):
        for contents in ("not JSON", "[]", '{"components":"wrong"}'):
            with self.subTest(contents=contents):
                self.write("runtime-manifest.json", contents)
                with self.assertRaises(privacy.PrivacyError):
                    privacy.copy_distribution_tree(self.source, self.output)
                self.assertFalse(self.output.exists())

    def test_local_paths_in_public_nested_metadata_are_rejected(self):
        for value in (str(self.root / "private"), "built from /private/build/python", "file:///private/build",
                      "C:\\private\\build", "~/private-build"):
            with self.subTest(value=value):
                manifest = self.manifest()
                manifest["nativeTransitiveNoticeAudit"]["source"] = value
                with self.assertRaises(privacy.PrivacyError):
                    privacy.distribution_manifest(manifest)

    def test_source_urls_and_relative_license_paths_are_allowed(self):
        privacy.validate_metadata({"source": "https://example.invalid/opt/source/archive",
                                   "download_url": "//example.invalid/opt/source/archive",
                                   "license": "Licenses/fixture/LICENSE", "model": "../Models/fixture"})

    def test_model_config_absolute_name_or_path_is_explicitly_rejected(self):
        for value in (str(self.root / "build-model"), "file:///private/build/model", "C:\\private\\model",
                      "//host.invalid/private-model"):
            with self.subTest(value=value):
                original = self.write("config.json", json.dumps({"_name_or_path": value, "model_type": "fixture"}))
                before = original.read_bytes()
                with self.assertRaisesRegex(privacy.PrivacyError, "local-path-metadata"):
                    privacy.copy_distribution_tree(self.source, self.output)
                self.assertFalse(self.output.exists())
                self.assertEqual(original.read_bytes(), before)
        self.write("config.json", '{"_name_or_path":"mlx-community/fixture","model_type":"fixture"}')
        privacy.copy_distribution_tree(self.source, self.output)

    def test_portable_python_required_files_and_hidden_dylibs_are_preserved(self):
        required = {"bin/python3.13": "synthetic interpreter", "lib/libpython3.13.dylib": "synthetic dylib",
                    "lib/python3.13/os.py": "# synthetic stdlib", "lib/python3.13/encodings/__init__.py": "# encodings",
                    "lib/python3.13/site-packages/sklearn/.dylibs/libomp.dylib": "synthetic OpenMP",
                    "lib/python3.13/site-packages/fixture/data/required.txt": "synthetic package data",
                    "lib/python3.13/site-packages/fixture-1.dist-info/METADATA": "Name: fixture\nVersion: 1\n",
                    "lib/python3.13/site-packages/fixture-1.dist-info/LICENSE": "synthetic license",
                    "lib/python3.13/site-packages/fixture-1.dist-info/RECORD": "fixture/__init__.py,,\n",
                    "lib/python3.13/site-packages/sympy/testing/__init__.py": "# exported test helper"}
        for name, text in required.items():
            self.write(name, text)
        (self.source / "bin/python3").symlink_to("python3.13")
        self.write("lib/python3.13/site-packages/scipy/io/tests/data/test.wav", "synthetic self-test fixture")
        privacy.copy_distribution_tree(self.source, self.output)
        for name in required:
            self.assertEqual((self.output / name).read_bytes(), (self.source / name).read_bytes())
        self.assertEqual(os.readlink(self.output / "bin/python3"), "python3.13")
        self.assertFalse((self.output / "lib/python3.13/site-packages/scipy/io/tests").exists())

    def test_checked_in_license_and_source_metadata_passes_without_rewriting(self):
        for relative in ("Packaging/ASRRuntime.lock.json", "Packaging/MLXRuntime.lock.json",
                         "Packaging/MLXLicenses/AUDIT.json", "Packaging/ModelNotices/sources.json",
                         "Packaging/ModelNotices/asr-sources.json"):
            with self.subTest(path=relative):
                original = (ROOT / relative).read_bytes()
                privacy.validate_metadata(json.loads(original))
                self.assertEqual((ROOT / relative).read_bytes(), original)

    def test_plain_body_files_are_refused_even_in_nested_runtime(self):
        for name in ("transcript.txt", "nested/notes.md", "nested/recording.wav", "nested/lesson.srt"):
            with self.subTest(name=name):
                path = self.write(name)
                with self.assertRaises(privacy.PrivacyError):
                    privacy.copy_distribution_tree(self.source, self.output)
                self.assertFalse(self.output.exists())
                self.assertEqual(path.read_text(), CANARY)
                path.unlink()

    def test_renamed_json_with_body_fields_is_refused(self):
        for value in ({"transcript": CANARY}, {"segments": [{"originalText": CANARY}]},
                      {"nested": {"translated_text": CANARY}}, {"learningNotes": CANARY}):
            with self.subTest(value=value):
                self.write("config.json", json.dumps(value))
                with self.assertRaises(privacy.PrivacyError):
                    privacy.copy_distribution_tree(self.source, self.output)
                self.assertFalse(self.output.exists())

    def test_unknown_app_resource_is_refused_without_reading_body(self):
        self.write("Contents/Info.plist", "synthetic plist")
        self.write("Contents/Resources/handout.txt")
        with self.assertRaisesRegex(privacy.PrivacyError, "unexpected-app-resource"):
            privacy.copy_distribution_tree(self.source, self.output)
        self.assertFalse(self.output.exists())

    def test_model_config_cannot_hide_body_json(self):
        self.write("Contents/Resources/Models/fixture/config.json", json.dumps({"rawText": CANARY}))
        with self.assertRaises(privacy.PrivacyError):
            privacy.inspect_tree(self.source)

    def test_relative_internal_interpreter_link_is_preserved(self):
        self.write("python/bin/python3.13", "synthetic interpreter")
        (self.source / "python/bin/python3").symlink_to("python3.13")
        privacy.copy_distribution_tree(self.source, self.output)
        self.assertEqual(os.readlink(self.output / "python/bin/python3"), "python3.13")
        self.assertEqual((self.output / "python/bin/python3").read_text(), "synthetic interpreter")

    def test_external_absolute_and_cyclic_links_are_rejected(self):
        target = self.write("elsewhere/secret", root=self.root)
        self.write("safe")
        for link in (str(target), "../elsewhere/secret", str(self.source / "safe"), "escape",
                     "/usr/lib/../../" + str(target).lstrip("/")):
            with self.subTest(link=link):
                path = self.source / "escape"
                path.symlink_to(link)
                with self.assertRaises(privacy.PrivacyError):
                    privacy.copy_distribution_tree(self.source, self.output)
                self.assertFalse(self.output.exists())
                path.unlink()
        self.assertEqual(target.read_text(), CANARY)

    def test_link_to_excluded_private_file_is_refused(self):
        self.write(".migration-source-fixture/private")
        (self.source / "safe").symlink_to(".migration-source-fixture/private")
        with self.assertRaisesRegex(privacy.PrivacyError, "symlink-to-private-record"):
            privacy.copy_distribution_tree(self.source, self.output)

    def test_excluded_symlink_is_not_followed(self):
        target = self.write("elsewhere/secret", root=self.root)
        (self.source / ".migration-source-fixture").symlink_to(target.parent)
        privacy.copy_distribution_tree(self.source, self.output)
        self.assertFalse((self.output / ".migration-source-fixture").exists())
        self.assertEqual(target.read_text(), CANARY)

    def test_json_symlink_cannot_bypass_manifest_checks(self):
        self.write("opaque.txt", json.dumps(self.manifest(str(self.root / "python"))))
        (self.source / "runtime-manifest.json").symlink_to("opaque.txt")
        with self.assertRaisesRegex(privacy.PrivacyError, "structured-metadata-symlink"):
            privacy.copy_distribution_tree(self.source, self.output)

    def test_system_library_symlink_is_preserved(self):
        (self.source / "system-library").symlink_to("/usr/lib/libSystem.B.dylib")
        privacy.copy_distribution_tree(self.source, self.output)
        self.assertEqual(os.readlink(self.output / "system-library"), "/usr/lib/libSystem.B.dylib")

    def test_existing_dangling_or_overlapping_destination_is_not_written(self):
        self.output.mkdir()
        sentinel = self.write("sentinel", "keep destination", root=self.output)
        with self.assertRaises(privacy.PrivacyError):
            privacy.copy_distribution_tree(self.source, self.output)
        self.assertEqual(sentinel.read_text(), "keep destination")
        link = self.root / "dangling"
        link.symlink_to("missing")
        for destination in (link, self.source, self.source / "nested", self.root):
            with self.subTest(destination=destination.name):
                with self.assertRaises(privacy.PrivacyError):
                    privacy.copy_distribution_tree(self.source, destination)
        self.assertFalse((self.source / "nested").exists())

    def test_source_root_and_destination_parent_symlinks_are_refused(self):
        link = self.root / "linked-source"
        link.symlink_to(self.source, target_is_directory=True)
        with self.assertRaises(privacy.PrivacyError):
            privacy.copy_distribution_tree(link, self.output)
        with self.assertRaises(privacy.PrivacyError):
            privacy.copy_distribution_tree(self.source, link / "delivery")

    def test_special_files_fail_before_copy(self):
        os.mkfifo(self.source / "pipe")
        with self.assertRaisesRegex(privacy.PrivacyError, "special-package-entry"):
            privacy.copy_distribution_tree(self.source, self.output)
        self.assertFalse(self.output.exists())

    def test_large_unreviewed_json_is_refused(self):
        for name in ("diagnostic.json", "tokenizer.json"):
            with self.subTest(name=name), patch.object(privacy, "JSON_LIMIT", 128):
                path = self.write(name, " " * 129)
                with self.assertRaisesRegex(privacy.PrivacyError, "unreviewed-large-json"):
                    privacy.inspect_tree(self.source)
                path.unlink()

    def test_required_tokenizer_vocabulary_and_public_provenance_are_preserved(self):
        value = {"model": {"vocab": {"transcript": 1, "/private/build/": 2}, "merges": []},
                 "added_tokens": [{"content": "/private/build/", "special": False}],
                 "source": "https://example.invalid/tokenizer"}
        original = self.write("tokenizer.json", json.dumps(value))
        privacy.copy_distribution_tree(self.source, self.output)
        self.assertEqual((self.output / "tokenizer.json").read_bytes(), original.read_bytes())

    def test_tokenizer_metadata_cannot_hide_body_outside_vocabulary(self):
        self.write("tokenizer.json", json.dumps({"model": {"vocab": {}}, "rawText": CANARY}))
        with self.assertRaises(privacy.PrivacyError):
            privacy.copy_distribution_tree(self.source, self.output)
        self.assertFalse(self.output.exists())

    def test_other_tokenizer_formats_keep_vocabulary_but_refuse_private_config(self):
        values = {"vocab.json": {"transcript": 1, "/private/build/token": 2},
                  "added_tokens.json": {"/private/build/token": 3},
                  "tokenizer_config.json": {"added_tokens_decoder": {"3": {"content": "/private/build/token"}},
                                            "bos_token": "/private/build/token", "tokenizer_class": "Fixture"},
                  "special_tokens_map.json": {"bos_token": {"content": "/private/build/token"}}}
        for name, value in values.items():
            self.write(name, json.dumps(value))
        privacy.copy_distribution_tree(self.source, self.output)
        for name in values:
            self.assertEqual((self.output / name).read_bytes(), (self.source / name).read_bytes())
        privacy.validate_json_metadata({"model": {"vocab": {"transcript": 1}}}, "tokenizer.json")
        with self.assertRaisesRegex(privacy.PrivacyError, "local-path-metadata"):
            privacy.validate_json_metadata({"_name_or_path": str(self.root / "model"),
                                            "added_tokens_decoder": {}}, "tokenizer_config.json")

    def test_dmg_layout_allows_only_expected_top_level_and_shortcut(self):
        (self.source / "LiveLingo.app/Contents").mkdir(parents=True)
        self.write("使用说明.txt", "synthetic installation instructions")
        (self.source / "Applications").symlink_to("/Applications")
        privacy.inspect_tree(self.source, layout="dmg")
        extra = self.write(".migration-source-fixture/private")
        with self.assertRaisesRegex(privacy.PrivacyError, "unexpected-package-top-level"):
            privacy.inspect_tree(self.source, layout="dmg")
        self.assertEqual(extra.read_text(), CANARY)

    def test_app_notary_container_rejects_even_a_public_extra_file(self):
        (self.source / "LiveLingo.app/Contents").mkdir(parents=True)
        privacy.inspect_tree(self.source, layout="app-only")
        self.write("README.txt", "public but not part of App-only container")
        with self.assertRaises(privacy.PrivacyError):
            privacy.inspect_tree(self.source, layout="app-only")

    def test_cli_check_emits_only_fixed_error_and_does_not_touch_input(self):
        path = self.write("innocent.json", json.dumps({"transcript": CANARY, "path": str(self.root)}))
        before = path.read_bytes()
        result = subprocess.run([sys.executable, str(ROOT / "Scripts/privacy_package.py"), "check",
                                 "--root", str(self.source)], capture_output=True, text=True,
                                env={"PYTHONDONTWRITEBYTECODE": "1", "TMPDIR": str(self.root)})
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(CANARY, result.stdout + result.stderr)
        self.assertNotIn(str(self.root), result.stdout + result.stderr)
        self.assertIn("classroom-content-metadata", result.stderr)
        self.assertEqual(path.read_bytes(), before)

    def test_cli_copy_then_check_public_delivery(self):
        self.write("runtime-manifest.json", json.dumps(self.manifest(str(self.root / "python"))))
        self.write(".cli-runtime/run.json")
        for command in (["copy", "--source", str(self.source), "--output", str(self.output)],
                        ["check", "--root", str(self.output)]):
            result = subprocess.run([sys.executable, str(ROOT / "Scripts/privacy_package.py"), *command],
                                    capture_output=True, text=True, env={"PYTHONDONTWRITEBYTECODE": "1",
                                                                      "TMPDIR": str(self.root)})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["privacyPackage"], "passed")

    def test_bundle_entry_point_omits_recovery_and_sanitizes_legacy_manifest(self):
        bundle = load_script("bundle-mlx-app")
        repo = self.root / "repo"
        for path in ("LICENSE", "Packaging/THIRD_PARTY_NOTICES.md", "Scripts/qwen_asr_service.py"):
            self.write(path, "synthetic public file", repo)
        for name in bundle.RUNTIME_MODULES:
            self.write("Scripts/mlx_runtime/" + name, "# synthetic runtime module", repo)
        notices = {n for _, n in bundle.LANGUAGE_MODELS}
        notices.update(n for _, n, _ in bundle.ASR_MODELS)
        notices.update(n for _, _, n in bundle.ASR_MODELS)
        notices.add("Qwen3.5-9B-MLX-4bit-README.md")
        for name in notices:
            self.write("Packaging/ModelNotices/" + name, "synthetic official notice", repo)
        for name in ("sources.json", "asr-sources.json"):
            self.write("Packaging/ModelNotices/" + name, '[{"url":"https://example.invalid/LICENSE"}]', repo)
        self.write("Packaging/ASRRuntime.lock.json", "{}", repo)
        self.write("Packaging/MLXLicenses/AUDIT.json", '{"status":"fixture"}', repo)
        app = self.root / "LiveLingo.app"
        info = app / "Contents/Info.plist"
        info.parent.mkdir(parents=True)
        info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "fixture.app"}))
        self.write(".migration-source-fixture/transcript.txt", root=app)
        runtime = self.root / "runtime"
        original = self.write("runtime-manifest.json", json.dumps(self.manifest(str(self.root / "python"))), runtime)
        self.write(".cli-runtime/run.json", root=runtime)
        models = self.root / "models"
        for relative in [r for r, _ in bundle.LANGUAGE_MODELS] + [r for r, _, _ in bundle.ASR_MODELS]:
            self.write(relative + "/config.json", '{"model_type":"synthetic"}', models)
            self.write(relative + "/.migration-source-fixture/transcript.txt", root=models)
        asr = self.root / "asr-python"
        self.write("bin/python3", "synthetic interpreter", asr)
        (asr / "lib/python3.13").mkdir(parents=True)
        output = self.root / "candidate/LiveLingo.app"
        before = original.read_bytes()
        args = ["bundle-mlx-app.py", "--app", str(app), "--runtime", str(runtime), "--models", str(models),
                "--asr-models", str(models), "--asr-python", str(asr), "--output", str(output),
                "--asr-service", str(repo / "Scripts/qwen_asr_service.py")]
        with patch.object(bundle, "REPO_ROOT", repo), patch.object(bundle, "is_apfs", return_value=False), \
             patch.object(bundle, "repair_portable_asr_dylib_links"), patch.object(sys, "argv", args), \
             contextlib.redirect_stdout(io.StringIO()):
            bundle.main()
        public = json.loads((output / "Contents/Resources/LanguageRuntime/runtime-manifest.json").read_text())
        self.assertEqual(public["python"], "python")
        self.assertEqual(public["components"][0]["source"], self.manifest()["components"][0]["source"])
        self.assertEqual(original.read_bytes(), before)
        self.assertEqual((app / ".migration-source-fixture/transcript.txt").read_text(), CANARY)
        self.assertFalse(any(p.name.startswith(".migration-source") for p in output.rglob("*")))
        self.assertFalse((output / "Contents/Resources/LanguageRuntime/.cli-runtime").exists())
        privacy.inspect_tree(output)

    def test_unsigned_release_entry_point_checks_product_before_signing(self):
        source = (ROOT / "Scripts/build-release.sh").read_text()
        stub = self.root / "xcodebuild-stub"
        stub.write_text("#!/bin/sh\nexit 0\n")
        stub.chmod(0o755)
        source = source.replace('project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"',
                                'project_root="' + str(ROOT) + '"').replace("/usr/bin/xcodebuild", str(stub))
        script = self.root / "build-release-stub.sh"
        script.write_text(source)
        derived = self.root / "derived"
        app = derived / "Build/Products/Release/LiveLingo.app"
        self.write("Contents/Info.plist", "synthetic plist", app)
        env = {"LIVELINGO_DERIVED_DATA_PATH": str(derived), "LIVELINGO_PYTHON": sys.executable,
               "TMPDIR": str(self.root), "PYTHONDONTWRITEBYTECODE": "1", "PATH": "/usr/bin:/bin"}
        result = subprocess.run(["/bin/bash", str(script)], capture_output=True, text=True, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('"privacyPackage": "passed"', result.stdout)
        private = self.write(".cli-runtime/run.json", root=app)
        env["LIVELINGO_SIGN_IDENTITY"] = "fixture must never be signed"
        result = subprocess.run(["/bin/bash", str(script)], capture_output=True, text=True, env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("privacy-package:", result.stderr)
        self.assertNotIn("Set LIVELINGO_CERTIFICATE_PATH", result.stderr)
        self.assertEqual(private.read_text(), CANARY)


if __name__ == "__main__":
    unittest.main()
