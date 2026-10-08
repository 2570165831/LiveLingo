"""Synthetic packaging boundaries; no models, signing, mounting or user data."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

from Scripts import privacy_package as privacy
from Scripts.test_model_files import write_model


ROOT = Path(__file__).resolve().parent.parent
CANARY = "synthetic classroom canary"


def load_script(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), ROOT / "Scripts" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    with patch.dict(sys.modules, privacy_package=privacy):
        spec.loader.exec_module(module)
    return module


class PrivacyPackageTests(unittest.TestCase):
    def test_duplicate_json_and_plist_keys_and_private_xml_comments_are_rejected(self):
        samples = [
            ("config.json", b'{"path":"/synthetic/private","path":"public"}'),
            ("config.plist", b'<plist version="1.0"><dict><key>path</key><string>/synthetic/private</string>'
             b'<key>path</key><string>public</string></dict></plist>'),
            ("config.plist", b'<plist version="1.0"><!-- built at /synthetic/private -->'
             b'<dict><key>name</key><string>public</string></dict></plist>'),
        ]
        for index, (name, data) in enumerate(samples):
            with self.subTest(name=name, data=data):
                source = self.root / f"metadata-{index}"
                source.mkdir()
                output = self.root / f"delivery-{index}"
                path = self.write(name, data, root=source)
                with self.assertRaises(privacy.PrivacyError):
                    privacy.copy_distribution_tree(source, output)
                self.assertFalse(output.exists())
                self.assertEqual(path.read_bytes(), data)
                path.unlink()

    def test_normal_typing_path_certificate_and_openstep_resources_are_preserved(self):
        # Generate a disposable synthetic certificate outside the package.
        certificate = self.root / "synthetic-public.pem"
        subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                        "-keyout", str(self.root / "synthetic-test.key"), "-out", str(certificate),
                        "-days", "1", "-subj", "/CN=Synthetic fixture"], check=True, capture_output=True)
        resources = {"fixture/py.typed": b"", "fixture.pth": b"relative/package\n",
                     "public.pem": certificate.read_bytes(),
                     "en.lproj/InfoPlist.strings": '/* public resource */\n"Name" = "合成资源";\n'.encode()}
        for index, (name, data) in enumerate(resources.items()):
            with self.subTest(name=name):
                source = self.root / f"resource-{index}"
                source.mkdir()
                output = self.root / f"resource-delivery-{index}"
                self.write(name, data, root=source)
                privacy.copy_distribution_tree(source, output)
                self.assertEqual((output / name).read_bytes(), data)

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
        if isinstance(text, bytes):
            path.write_bytes(text)
        else:
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
        native = b"\xcf\xfa\xed\xfe" + b"\x00" * 28
        required = {"bin/python3.13": "synthetic interpreter", "lib/libpython3.13.dylib": native,
                    "lib/python3.13/os.py": "# synthetic stdlib", "lib/python3.13/encodings/__init__.py": "# encodings",
                    "lib/python3.13/site-packages/sklearn/.dylibs/libomp.dylib": native,
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
        info = self.write("Contents/Info.plist", "")
        info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "fixture.app"}))
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

    def bundle_inputs(self, bundle):
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
            write_model(models / relative, bundle.REQUIRED_MODEL_FILES[relative],
                        {"model-00001-of-00002.safetensors": ["a.weight"],
                         "model-00002-of-00002.safetensors": ["b.weight"]})
            self.write(relative + "/.migration-source-fixture/transcript.txt", root=models)
        asr = self.root / "asr-python"
        self.write("bin/python3", "synthetic interpreter", asr)
        (asr / "lib/python3.13").mkdir(parents=True)
        output = self.root / "candidate/LiveLingo.app"
        args = ["bundle-mlx-app.py", "--app", str(app), "--runtime", str(runtime), "--models", str(models),
                "--asr-models", str(models), "--asr-python", str(asr), "--output", str(output),
                "--asr-service", str(repo / "Scripts/qwen_asr_service.py")]
        return repo, app, original, models, output, args

    def run_bundle(self, bundle, repo, args):
        with patch.object(bundle, "REPO_ROOT", repo), patch.object(bundle, "is_apfs", return_value=False), \
             patch.object(bundle, "repair_portable_asr_dylib_links"), patch.object(sys, "argv", args), \
             contextlib.redirect_stdout(io.StringIO()):
            bundle.main()

    def test_bundle_entry_point_omits_recovery_and_sanitizes_legacy_manifest(self):
        bundle = load_script("bundle-mlx-app")
        repo, app, original, _, output, args = self.bundle_inputs(bundle)
        before = original.read_bytes()
        self.run_bundle(bundle, repo, args)
        public = json.loads((output / "Contents/Resources/LanguageRuntime/runtime-manifest.json").read_text())
        self.assertEqual(public["python"], "python")
        self.assertEqual(public["components"][0]["source"], self.manifest()["components"][0]["source"])
        self.assertEqual(original.read_bytes(), before)
        self.assertEqual((app / ".migration-source-fixture/transcript.txt").read_text(), CANARY)
        self.assertFalse(any(p.name.startswith(".migration-source") for p in output.rglob("*")))
        self.assertFalse((output / "Contents/Resources/LanguageRuntime/.cli-runtime").exists())
        privacy.inspect_tree(output)
        for relative in bundle.REQUIRED_MODEL_FILES:
            self.assertTrue((output / "Contents/Resources/Models" / relative / "model-00002-of-00002.safetensors").is_file())

    def test_bundle_entry_point_refuses_models_missing_weights_shards_or_loader_files(self):
        bundle = load_script("bundle-mlx-app")
        repo, _, _, models, output, args = self.bundle_inputs(bundle)
        damage = {"shard": "lmstudio-community/Qwen3.5-9B-MLX-4bit/model-00002-of-00002.safetensors",
                  "tokenizer": "mlx-community/Qwen3.5-4B-MLX-8bit/tokenizer.json",
                  "asr-vocabulary": "mlx-community/Qwen3-ASR-1.7B-4bit/merges.txt"}
        for kind, relative in damage.items():
            with self.subTest(kind=kind):
                path = models / relative
                data = path.read_bytes()
                path.unlink()
                with self.assertRaises(SystemExit) as raised:
                    self.run_bundle(bundle, repo, args)
                self.assertIn("model source " + str(Path(relative).parent) + " is incomplete", str(raised.exception))
                self.assertIn(path.name, str(raised.exception))
                self.assertFalse(output.exists())
                path.write_bytes(data)
        # The no-index fallback still needs at least one model*.safetensors file.
        parakeet = models / "mlx-community/parakeet-tdt-0.6b-v2"
        for name in ("model.safetensors.index.json", "model-00001-of-00002.safetensors",
                     "model-00002-of-00002.safetensors"):
            (parakeet / name).unlink()
        with self.assertRaises(SystemExit) as raised:
            self.run_bundle(bundle, repo, args)
        self.assertIn("no model*.safetensors weights", str(raised.exception))
        self.assertFalse(output.exists())

    def test_bundle_final_check_rejects_a_candidate_with_a_missing_shard(self):
        bundle = load_script("bundle-mlx-app")
        repo, _, _, _, output, args = self.bundle_inputs(bundle)
        self.run_bundle(bundle, repo, args)
        bundle.check_required_paths(output)
        (output / "Contents/Resources/Models/mlx-community/Qwen3-ASR-1.7B-4bit/model-00001-of-00002.safetensors").unlink()
        with self.assertRaises(SystemExit) as raised:
            bundle.check_required_paths(output)
        self.assertIn("mlx-community/Qwen3-ASR-1.7B-4bit: missing weight file: model-00001-of-00002.safetensors",
                      str(raised.exception))
        self.assertNotIn(str(self.root), str(raised.exception))

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
        info = self.write("Contents/Info.plist", "", app)
        info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "fixture.app"}))
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


class PrivacyPackageMetadataTests(unittest.TestCase):
    """All payloads are synthetic; inspect and copy must agree on coverage."""

    setUp = PrivacyPackageTests.setUp
    tearDown = PrivacyPackageTests.tearDown

    def case(self, payload, filename="metadata.plist"):
        directory = Path(tempfile.mkdtemp(prefix="metadata-case-", dir=self.source))
        path = directory / filename
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(payload)
        return directory, path, self.root / (directory.name + "-delivery")

    def reject(self, payload, filename="metadata.plist", reason=None):
        directory, path, destination = self.case(payload, filename)
        before = path.lstat()
        for operation in (lambda: privacy.inspect_tree(directory),
                          lambda: privacy.copy_distribution_tree(directory, destination)):
            with self.assertRaisesRegex(privacy.PrivacyError, reason or ".+"):
                operation()
        self.assertFalse(destination.exists())
        self.assertEqual(path.read_bytes(), payload)
        after = path.lstat()
        self.assertEqual((before.st_ino, before.st_mode, before.st_mtime_ns),
                         (after.st_ino, after.st_mode, after.st_mtime_ns))

    def check_plist(self, value, fmt, reason):
        self.reject(plistlib.dumps(value, fmt=fmt), reason=reason)

    def test_xml_plist_rejects_nested_private_key(self):
        self.check_plist({"outer": [{"translated_text": CANARY}]}, plistlib.FMT_XML,
                         "classroom-content-metadata")

    def test_binary_plist_rejects_nested_private_key(self):
        self.check_plist({"outer": [{"transcriptSegments": [CANARY]}]}, plistlib.FMT_BINARY,
                         "classroom-content-metadata")

    def test_xml_plist_rejects_nested_local_path_key(self):
        self.check_plist({"outer": [{"/private": "public"}]}, plistlib.FMT_XML,
                         "local-path-metadata")

    def test_binary_plist_rejects_nested_local_path_key(self):
        self.check_plist({"outer": [{"generated in /private": "public"}]}, plistlib.FMT_BINARY,
                         "local-path-metadata")

    def test_xml_plist_rejects_nested_local_path_string(self):
        self.check_plist({"outer": [{"description": "generated in /private"}]}, plistlib.FMT_XML,
                         "local-path-metadata")

    def test_binary_plist_rejects_nested_local_path_string(self):
        self.check_plist({"outer": [{"description": "generated in /private"}]}, plistlib.FMT_BINARY,
                         "local-path-metadata")

    def check_path_data(self, fmt):
        for encoding in ("utf-8", "utf-16", "utf-16-le", "utf-16-be"):
            with self.subTest(encoding=encoding):
                self.check_plist({"outer": [{"data": "generated in /private".encode(encoding)}]},
                                 fmt, "local-path-metadata")

    def test_xml_plist_rejects_nested_local_path_data(self):
        self.check_path_data(plistlib.FMT_XML)

    def test_binary_plist_rejects_nested_local_path_data(self):
        self.check_path_data(plistlib.FMT_BINARY)

    def test_plist_data_rejects_embedded_structured_content(self):
        for fmt in (plistlib.FMT_XML, plistlib.FMT_BINARY):
            for data in (json.dumps({"rawText": CANARY}).encode(),
                         plistlib.dumps({"nested": [{"transcript": CANARY}]}, fmt=fmt)):
                with self.subTest(format=fmt, prefix=data[:8]):
                    self.check_plist({"outer": [{"data": data}]}, fmt,
                                     "classroom-content-metadata")

    def test_plist_data_rejects_unidentified_binary(self):
        for fmt in (plistlib.FMT_XML, plistlib.FMT_BINARY):
            with self.subTest(format=fmt):
                self.check_plist({"outer": [{"data": b"\xff\x00\xfe\x81"}]}, fmt,
                                 "unreviewed-metadata-data")

    def test_json_rejects_single_component_paths_in_keys_and_prose(self):
        for value in ({"note": "generated in /private"}, {"outer": [{"/secret": "public"}]},
                      {"note": "generated in C:/private"}, {"note": "from file:///secret"}):
            with self.subTest(value=value):
                self.reject(json.dumps(value).encode(), "metadata.json", "local-path-metadata")

    def test_normal_info_plist_fields_and_public_data_survive_copy(self):
        value = {"CFBundleIdentifier": "invalid.example.fixture", "CFBundleExecutable": "LiveLingo",
                 "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
                 "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True,
                 "NSMicrophoneUsageDescription": "Synthetic public microphone purpose",
                 "CFBundleURLTypes": [{"CFBundleURLSchemes": ["fixture"]}],
                 "publicData": b"public fixture", "source": "https://example.invalid/source",
                 "relative": "Resources/fixture"}
        for fmt in (plistlib.FMT_XML, plistlib.FMT_BINARY):
            with self.subTest(format=fmt):
                payload = plistlib.dumps(value, fmt=fmt)
                directory, path, destination = self.case(payload, "Contents/Info.plist")
                before = path.lstat()
                counts = privacy.copy_distribution_tree(directory, destination)
                self.assertEqual(counts["metadata_files"], 1)
                self.assertEqual(counts["opaque_binary_files"], 0)
                delivered = destination / "Contents/Info.plist"
                self.assertEqual(delivered.read_bytes(), payload)
                self.assertEqual(plistlib.loads(delivered.read_bytes()), value)
                self.assertEqual(privacy.inspect_tree(destination)["metadata_files"], 1)
                self.assertEqual(path.lstat().st_mode, before.st_mode)
                self.assertEqual(delivered.lstat().st_mode, before.st_mode)

    def test_info_plist_functional_field_is_not_a_privacy_exemption(self):
        self.check_plist({"CFBundleIdentifier": "generated in /private"}, plistlib.FMT_XML,
                         "local-path-metadata")

    def test_malformed_json_and_plist_fail_before_copy(self):
        for filename, data in (("metadata.json", b'{"nested":'),
                               ("metadata.plist", b"not a plist"),
                               ("metadata.plist", b"bplist00broken"),
                               ("metadata.plist", b"<?xml version='1.0'?><plist><dict>")):
            with self.subTest(filename=filename, data=data):
                self.reject(data, filename, "invalid-package-(json|plist)")

    def test_metadata_signatures_are_checked_without_known_suffix(self):
        for payload in (plistlib.dumps({"rawText": CANARY}, fmt=plistlib.FMT_XML),
                        plistlib.dumps({"transcript": CANARY}, fmt=plistlib.FMT_BINARY),
                        json.dumps({"learningNotes": CANARY}).encode()):
            with self.subTest(prefix=payload[:8]):
                self.reject(payload, "public.resource", "classroom-content-metadata")

    def test_unsupported_structured_formats_are_not_passed(self):
        for filename, payload in (("metadata.xml", b'<metadata path="/private"/>'),
                                  ("metadata.yaml", b"description: generated in /private"),
                                  ("metadata.toml", b'description = "generated in /private"'),
                                  ("InfoPlist.strings", b'"description" = "public";'),
                                  ("metadata.resource", b"bplist01unknown"),
                                  ("metadata.resource", b"<?xml broken"),
                                  ("metadata.resource", b'{"rawText":')):
            with self.subTest(filename=filename, prefix=payload[:8]):
                self.reject(payload, filename)

    def test_plist_symlink_cannot_bypass_metadata_checks(self):
        directory, target, destination = self.case(plistlib.dumps({"transcript": CANARY}), "opaque.txt")
        (directory / "metadata.plist").symlink_to("opaque.txt")
        with self.assertRaisesRegex(privacy.PrivacyError, "structured-metadata-symlink"):
            privacy.copy_distribution_tree(directory, destination)
        self.assertFalse(destination.exists())
        self.assertEqual(plistlib.loads(target.read_bytes()), {"transcript": CANARY})

    def test_metadata_size_limit_covers_plist_and_renamed_payloads(self):
        for filename in ("metadata.plist", "metadata.resource"):
            for fmt in (plistlib.FMT_XML, plistlib.FMT_BINARY):
                with self.subTest(filename=filename, format=fmt), patch.object(privacy, "JSON_LIMIT", 128):
                    self.reject(plistlib.dumps({"public": "x" * 200}, fmt=fmt), filename,
                                "unreviewed-large-metadata")

    def test_known_app_binaries_are_reported_as_opaque(self):
        fixtures = {"Contents/MacOS/LiveLingo": b"\xcf\xfa\xed\xfe" + b"\x00" * 28,
                    "Contents/PkgInfo": b"APPL????",
                    "Contents/Resources/Assets.car": b"BOMStore" + b"\x00" * 24,
                    "Contents/Resources/AppIcon.icns": b"icns\x00\x00\x00\x08",
                    "runtime/libfixture.dylib": b"\xcf\xfa\xed\xfe" + b"\x00" * 28,
                    "runtime/default.metallib": b"MTLB" + b"\x00" * 28,
                    "Contents/Resources/AppIcon.icon/Assets/fixture.png": b"\x89PNG\r\n\x1a\n" + b"\x00" * 24}
        for filename, payload in fixtures.items():
            with self.subTest(filename=filename):
                directory, _, destination = self.case(payload, filename)
                counts = privacy.copy_distribution_tree(directory, destination)
                self.assertEqual(counts["files"], 1)
                self.assertEqual(counts["opaque_binary_files"], 1)
                self.assertEqual(counts["metadata_files"], 0)
                self.assertEqual((destination / filename).read_bytes(), payload)

    def test_unknown_binary_and_disguised_known_suffix_are_rejected(self):
        for filename in ("metadata.bin", "runtime/libfixture.dylib", "Contents/Resources/Assets.car"):
            with self.subTest(filename=filename):
                self.reject(b"\x00\xff\x81synthetic opaque bytes", filename,
                            "unreviewed-binary-package-entry")

    def test_code_resources_hash_data_has_an_explicit_opaque_boundary(self):
        value = {"files": {"Resources/LICENSE": b"\xff" * 20},
                 "files2": {"Resources/LICENSE": {"hash": b"\xfe" * 20, "hash2": b"\xfd" * 32}}}
        directory, _, destination = self.case(plistlib.dumps(value), "Contents/_CodeSignature/CodeResources")
        counts = privacy.copy_distribution_tree(directory, destination)
        self.assertEqual(counts["metadata_files"], 1)
        self.assertEqual(counts["opaque_metadata_fields"], 3)
        self.assertEqual(plistlib.loads((destination / "Contents/_CodeSignature/CodeResources").read_bytes()), value)

    def test_hash_named_field_does_not_exempt_unrelated_binary_data(self):
        self.check_plist({"hash": b"\xff" * 20}, plistlib.FMT_BINARY, "unreviewed-metadata-data")
        self.reject(plistlib.dumps({"extra": {"hash": b"\xff" * 20}}),
                    "Contents/_CodeSignature/CodeResources", "unreviewed-metadata-data")

    def test_plain_files_are_counted_without_claiming_content_review(self):
        directory, _, destination = self.case(b"Synthetic public license", "LICENSE")
        counts = privacy.copy_distribution_tree(directory, destination)
        self.assertEqual(counts["unreviewed_text_files"], 1)
        self.assertEqual(counts["metadata_files"], 0)
        self.assertEqual(counts["opaque_binary_files"], 0)

    def test_safetensors_header_is_checked_without_reviewing_tensor_payload(self):
        header = json.dumps({"weight": {"dtype": "F32", "shape": [1], "data_offsets": [0, 4]},
                             "__metadata__": {"source": "https://example.invalid/model"}}).encode()
        payload = struct.pack("<Q", len(header)) + header + b"\x00" * 4
        directory, _, destination = self.case(payload, "weights.safetensors")
        counts = privacy.copy_distribution_tree(directory, destination)
        self.assertEqual(counts["metadata_files"], 1)
        self.assertEqual(counts["opaque_binary_files"], 1)
        self.assertEqual((destination / "weights.safetensors").read_bytes(), payload)
        for value in ({"__metadata__": {"description": "generated in /private"}},
                      {"__metadata__": {"rawText": CANARY}}):
            header = json.dumps(value).encode()
            self.reject(struct.pack("<Q", len(header)) + header + b"\x00" * 4,
                        "weights.safetensors")
        self.reject(b"\x00\xffinvalid safetensors", "weights.safetensors")

    def test_metadata_unknown_types_and_cycles_fail_with_fixed_reasons(self):
        cyclic = []
        cyclic.append(cyclic)
        for value in ({"value": object()}, cyclic):
            with self.subTest(value_type=type(value).__name__):
                with self.assertRaises(privacy.PrivacyError):
                    privacy.validate_metadata(value)
        with self.assertRaisesRegex(privacy.PrivacyError, "local-path-metadata"):
            privacy.validate_metadata({b"generated in /private": ("public",)})

    def test_excluded_private_plist_is_not_read_or_copied(self):
        directory, path, destination = self.case(b"invalid private plist", ".migration-source-fixture/private.plist")
        def guard(operation):
            def checked(candidate, *args, **kwargs):
                if ".migration-source-fixture" in candidate.parts:
                    raise AssertionError("excluded private metadata must not be read")
                return operation(candidate, *args, **kwargs)
            return checked
        with patch.object(Path, "read_bytes", guard(Path.read_bytes)), \
             patch.object(Path, "open", guard(Path.open)):
            counts = privacy.copy_distribution_tree(directory, destination)
        self.assertEqual(counts["excluded"], 1)
        self.assertEqual(counts["metadata_files"], 0)
        self.assertFalse((destination / ".migration-source-fixture").exists())
        self.assertEqual(path.read_bytes(), b"invalid private plist")

    def test_text_prefix_does_not_hide_unknown_binary_or_delayed_metadata(self):
        self.reject(b"public " * 700 + b"\x00\xff", "metadata.resource",
                    "unreviewed-binary-package-entry")
        self.reject(b" " * 5000 + json.dumps({"transcript": CANARY}).encode(),
                    "metadata.resource", "classroom-content-metadata")

    def test_printable_signature_hash_is_still_reported_as_opaque(self):
        value = {"files": {"Resources/LICENSE": b"a" * 20}}
        directory, _, destination = self.case(plistlib.dumps(value), "Contents/_CodeSignature/CodeResources")
        self.assertEqual(privacy.copy_distribution_tree(directory, destination)["opaque_metadata_fields"], 1)

    def test_binary_exemption_cannot_cover_metadata_or_data_attachments(self):
        payload = b"\xcf\xfa\xed\xfe" + b"\x00" * 28
        for filename in ("metadata.plist", "metadata.json", "metadata.yaml", "metadata.data"):
            with self.subTest(filename=filename):
                self.reject(payload, filename)
        self.check_plist({"data": payload}, plistlib.FMT_BINARY, "unreviewed-metadata-data")

    def test_package_cli_uses_fixed_private_parser(self):
        for arguments in (["check", "--root", str(self.source), CANARY],
                          ["check", "--root", str(self.source), "--layout", CANARY], [CANARY]):
            with self.subTest(arguments=arguments):
                stdout, stderr = io.StringIO(), io.StringIO()
                with patch.object(sys, "argv", [CANARY, *arguments]), \
                     contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr), \
                     self.assertRaises(SystemExit) as error:
                    privacy.main()
                self.assertEqual(error.exception.code, 2)
                self.assertNotIn(CANARY, stdout.getvalue() + stderr.getvalue())
                self.assertNotIn(str(self.source), stdout.getvalue() + stderr.getvalue())
                self.assertIn("invalid_arguments", stderr.getvalue())
                self.assertIn("privacy-package", stderr.getvalue())

    def test_unknown_decodable_file_formats_fail_closed(self):
        for filename in ("metadata.blob", "metadata.payload", "metadata.data", "metadata.bin", "opaque"):
            with self.subTest(filename=filename):
                self.reject(b"opaque synthetic metadata text", filename, "unsupported-package-file-format")

    def test_known_script_license_and_prose_formats_keep_unreviewed_boundary(self):
        for filename in ("LICENSE", "README", "fixture-LICENSE", "notices.txt", "script.py", "tool.sh",
                         "fixture-1.dist-info/METADATA", "bin/python3.13"):
            with self.subTest(filename=filename):
                payload = b"Synthetic public fixture"
                directory, _, destination = self.case(payload, filename)
                counts = privacy.copy_distribution_tree(directory, destination)
                self.assertEqual(counts["unreviewed_text_files"], 1)
                self.assertEqual(counts["metadata_files"], 0)
                self.assertEqual((destination / filename).read_bytes(), payload)

    def test_generic_interface_keys_are_not_classroom_content(self):
        value = {"CFBundleIdentifier": "invalid.example.fixture", "prompt": "Public dialog purpose",
                 "input": {"description": "Public interface"}, "output": "Public format"}
        for fmt in (plistlib.FMT_XML, plistlib.FMT_BINARY):
            with self.subTest(format=fmt):
                directory, _, destination = self.case(plistlib.dumps(value, fmt=fmt), "Contents/Info.plist")
                self.assertEqual(privacy.copy_distribution_tree(directory, destination)["metadata_files"], 1)


if __name__ == "__main__":
    unittest.main()
