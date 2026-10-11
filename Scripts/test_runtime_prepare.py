"""Synthetic runtime selection, pruning and notice policy; no installed app."""
import ast
from collections import Counter
import csv
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from Scripts import privacy_package as privacy
from Scripts import runtime_prepare as runtime


class RuntimePreparationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="runtime-prepare-test-")
        self.root = Path(self.temp.name).resolve()
        self.base = self.root / "base"
        self.output = self.root / "output"
        self.repo = self.root / "repo"
        self.stdlib = Path("lib/python3.13")
        self.site = self.base / self.stdlib / "site-packages"
        self.write("bin/python3.13", b"#!/bin/sh\nexit 0\n")
        (self.base / "bin/python3").symlink_to("python3.13")
        self.write("lib/python3.13/os.py", b"value = 1\n")
        self.add_distribution("fixture", "1.0", {
            "fixture/__init__.py": b"value = 1\n",
            "fixture-1.0.dist-info/licenses/LICENSE-MIT": b"Copyright fixture\nPermission is hereby granted.\n",
        })
        packaging = self.repo / "Packaging"
        packaging.mkdir(parents=True)
        (packaging / "MLXRuntime.lock.json").write_text(json.dumps({"python": "3.13.7", "fixture": "1.0"}))
        (packaging / "ASRRuntime.lock.json").write_text(json.dumps({"python": "3.13.7", "packages": [{"name": "fixture", "version": "1.0"}]}))
        notices = packaging / "MLXLicenses"
        notices.mkdir()
        (notices / "AUDIT.json").write_text('{"status": "synthetic"}')
        sources = self.repo / "Scripts/mlx_runtime"
        sources.mkdir(parents=True)
        for name in runtime.RUNTIME_MODULES:
            (sources / name).write_text("# synthetic worker\n")

    def tearDown(self):
        self.temp.cleanup()

    def test_supplement_empty_test_directory_is_not_copied(self):
        notices = self.repo / "Packaging/MLXLicenses/native-fixture"
        (notices / "tests").mkdir(parents=True)
        (notices / "LICENSE.txt").write_text("Copyright fixture. Permission is hereby granted.\n")
        self.prepare(mode="language")
        self.assertTrue((self.output / "Licenses/native-fixture/LICENSE.txt").is_file())
        self.assertFalse((self.output / "Licenses/native-fixture/tests").exists())

    def test_supplement_test_license_is_not_silently_lost(self):
        notice = self.repo / "Packaging/MLXLicenses/native-fixture/tests/LICENSE.txt"
        notice.parent.mkdir(parents=True)
        notice.write_text("Copyright fixture. Permission is hereby granted.\n")
        with self.assertRaisesRegex(privacy.PrivacyError, "supplement-license-needs-safe-relative-name"):
            self.prepare(mode="language")

    def write(self, relative, data):
        path = self.base / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def add_distribution(self, name, version, files, *, license_file=None):
        info = self.site / f"{name}-{version}.dist-info"
        info.mkdir(parents=True, exist_ok=True)
        metadata = f"Metadata-Version: 2.4\nName: {name}\nVersion: {version}\n"
        if license_file:
            metadata += f"License-File: {license_file}\n"
        (info / "METADATA").write_text(metadata + "\nOptional README description\n")
        for relative, data in files.items():
            path = self.site / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        rows = [(p, "", "") for p in files]
        rows.extend([(f"{info.name}/METADATA", "", ""), (f"{info.name}/RECORD", "", "")])
        with (info / "RECORD").open("w", newline="") as stream:
            csv.writer(stream).writerows(rows)

    def prepare(self, mode="asr"):
        with patch.object(runtime, "python_version", return_value="3.13.7"):
            return runtime.prepare(self.base, self.output, mode=mode, repo=self.repo, clone=False)

    def test_selects_input_lock_not_active_python_and_removes_extra_distribution(self):
        self.add_distribution("extra", "9.0", {"extra/__init__.py": b"value = 9\n"})
        report = self.prepare()
        self.assertEqual(report["components"], {"fixture": "1.0"})
        self.assertFalse((self.output / self.stdlib / "site-packages/extra").exists())
        self.assertTrue((self.output / self.stdlib / "site-packages/fixture/__init__.py").is_file())

    def test_lock_mismatch_fails_before_creating_output(self):
        (self.repo / "Packaging/ASRRuntime.lock.json").write_text('{"python":"3.13.7","packages":[{"name":"fixture","version":"2.0"}]}')
        with self.assertRaisesRegex(privacy.PrivacyError, "runtime-version-lock-mismatch"):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_python_patch_version_is_checked_for_asr(self):
        with patch.object(runtime, "python_version", return_value="3.13.8"):
            with self.assertRaisesRegex(privacy.PrivacyError, "input-python-version-lock-mismatch"):
                runtime.prepare(self.base, self.output, mode="asr", repo=self.repo, clone=False)
        self.assertFalse(self.output.exists())

    def test_python_patch_version_is_checked_for_language(self):
        with patch.object(runtime, "python_version", return_value="3.13.8"):
            with self.assertRaisesRegex(privacy.PrivacyError, "input-python-version-lock-mismatch"):
                runtime.prepare(self.base, self.output, mode="language", repo=self.repo, clone=False)
        self.assertFalse(self.output.exists())

    def test_python_version_is_read_without_launching_or_loading_the_interpreter(self):
        self.write("lib/libpython3.13.dylib", b"synthetic library\x003.13.7\x00")
        self.assertEqual(runtime.python_version(self.base), "3.13.7")
        self.write("lib/libpython3.13.dylib", b"3.13.7\x003.13.8\x00")
        with self.assertRaisesRegex(privacy.PrivacyError, "version-constant-ambiguous"):
            runtime.python_version(self.base)

    def test_duplicate_distribution_is_rejected(self):
        self.add_distribution("fixture", "2.0", {"another.py": b"value = 2\n"})
        with self.assertRaisesRegex(privacy.PrivacyError, "duplicate-input-distribution"):
            self.prepare()

    def test_prunes_fixtures_gui_build_tools_and_caches_but_preserves_notices(self):
        extra = {
            "fixture/tests/input.mat": b"test binary\0",
            "fixture/test/input.npy": b"test binary\0",
            "fixture/tests/data.csv": b"value\n1\n",
            "fixture/tests/LICENSE-APACHE": b"Apache License\nCopyright fixture\n",
            "fixture/__pycache__/mod.pyc": b"bytecode\0",
            "fixture/dev.pyx": b"cdef int x\n",
            "fixture/dev.pxd": b"cdef int x\n",
            "fixture/dev.f90": b"program unused\n",
            "fixture/meson.build": b"unused build recipe\n",
            "fixture/defaults.txt": b"required runtime resource\n",
        }
        self.add_distribution("fixture", "1.0", {"fixture/__init__.py": b"value = 1\n", **extra,
            "fixture-1.0.dist-info/licenses/LICENSE-MIT": b"Copyright fixture\n"})
        for name in ("lib/tk8.6/messages.msg", "lib/tcl8.6/encoding.enc", "lib/libtk8.6.dylib",
                     "lib/python3.13/idlelib/idle.py", "lib/python3.13/turtledemo/main.py",
                     "lib/python3.13/ensurepip/installer.py", "lib/python3.13/tkinter/main.py",
                     "lib/python3.13/venv/activate.py", "bin/pip3"):
            self.write(name, b"unused\n")
        report = self.prepare()
        for relative in extra:
            path = self.output / self.stdlib / "site-packages" / relative
            if relative.endswith("defaults.txt"):
                self.assertTrue(path.is_file())
            else:
                self.assertFalse(path.exists(), relative)
        apache = next(p for p in report["licenses"] if p["source"].endswith("tests/LICENSE-APACHE"))
        self.assertEqual((self.output / apache["copy"]).read_bytes(), extra["fixture/tests/LICENSE-APACHE"])
        self.assertEqual(apache["sha256"], hashlib.sha256(extra["fixture/tests/LICENSE-APACHE"]).hexdigest())
        self.assertEqual(privacy.inspect_tree(self.output)["excluded"], 0)

    def test_preserves_declared_license_with_custom_filename(self):
        data = b"Copyright custom legal notice\n"
        self.add_distribution("fixture", "1.0", {"fixture/__init__.py": b"value = 1\n",
            "fixture-1.0.dist-info/licenses/LEGAL.txt": data}, license_file="LEGAL.txt")
        report = self.prepare()
        self.assertEqual(len(report["licenses"]), 2)  # Existing MIT file and declared LEGAL.txt.
        legal = next(p for p in report["licenses"] if p["source"].endswith("LEGAL.txt"))
        self.assertEqual((self.output / legal["copy"]).read_bytes(), data)

    def test_optional_api_python_modules_needed_by_eager_imports_are_retained(self):
        selected = {Path("numpy/f2py/__init__.py"), Path("sympy/utilities/mathml/__init__.py"),
                    Path("sympy/parsing/latex/__init__.py")}
        for relative in selected:
            self.assertIsNone(runtime.removal_reason(self.stdlib / "site-packages" / relative, self.stdlib, selected))
        css = Path("sklearn/utils/_repr_html/estimator.css")
        self.assertIsNone(runtime.removal_reason(self.stdlib / "site-packages" / css, self.stdlib, {css}))
        css = Path("tokenizers/tools/visualizer-styles.css")
        self.assertIsNone(runtime.removal_reason(self.stdlib / "site-packages" / css, self.stdlib, {css}))

    def test_distribution_metadata_symlink_is_rejected_before_reading(self):
        path = self.site / "fixture-1.0.dist-info/METADATA"
        original = path.with_suffix(".original")
        path.rename(original)
        path.symlink_to(original)
        with self.assertRaisesRegex(privacy.PrivacyError, "input-distribution-metadata-symlink"):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_removes_installer_paths_and_preserves_metadata_versions(self):
        self.add_distribution("fixture", "1.0", {
            "fixture/__init__.py": b"value = 1\n",
            "fixture-1.0.dist-info/licenses/LICENSE": b"Copyright fixture\n",
            "fixture-1.0.dist-info/direct_url.json": b'{"url":"file:///synthetic/private"}',
            "fixture/py.typed": b"invalid optional marker",
        })
        self.prepare()
        info = self.output / self.stdlib / "site-packages/fixture-1.0.dist-info"
        self.assertFalse((info / "direct_url.json").exists())
        self.assertIn("Version: 1.0", (info / "METADATA").read_text())
        self.assertNotIn("Optional README", (info / "METADATA").read_text())
        self.assertNotIn("direct_url.json", (info / "RECORD").read_text())

    def test_unknown_runtime_resource_is_rejected_and_input_is_unchanged(self):
        self.add_distribution("fixture", "1.0", {"fixture/__init__.py": b"value = 1\n",
            "fixture/data.msgpack": b"\x80\0",
            "fixture-1.0.dist-info/licenses/LICENSE": b"Copyright fixture\n"})
        with self.assertRaisesRegex(privacy.PrivacyError, "unreviewed-binary-package-entry"):
            self.prepare()
        self.assertEqual((self.site / "fixture/data.msgpack").read_bytes(), b"\x80\0")
        self.assertTrue((self.output / "runtime-preparation.json").is_file())

    def test_existing_destination_and_broken_link_are_never_overwritten(self):
        self.output.symlink_to("missing")
        with self.assertRaisesRegex(privacy.PrivacyError, "destination-already-exists"):
            self.prepare()
        self.assertTrue(self.output.is_symlink())

    def test_overlapping_destination_is_rejected(self):
        self.output = self.base / "new"
        with self.assertRaisesRegex(privacy.PrivacyError, "overlapping-runtime-trees"):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_symlink_destination_parent_is_rejected(self):
        link = self.root / "link"
        link.symlink_to(self.root, target_is_directory=True)
        self.output = link / "new"
        with self.assertRaisesRegex(privacy.PrivacyError, "symlink-destination-parent"):
            self.prepare()

    def test_venv_is_rejected(self):
        self.write("pyvenv.cfg", b"home = synthetic\n")
        with self.assertRaisesRegex(privacy.PrivacyError, "input-not-portable-python"):
            self.prepare()

    def test_required_external_symlink_is_rejected(self):
        external = self.root / "external.py"
        external.write_text("value = 1\n")
        path = self.site / "fixture/__init__.py"
        path.rename(path.with_suffix(".original"))
        path.symlink_to(external)
        with self.assertRaisesRegex(privacy.PrivacyError, "external-or-absolute-symlink"):
            self.prepare()

    def test_language_mode_writes_worker_hashes_and_public_manifest(self):
        self.prepare("language")
        manifest = json.loads((self.output / "runtime-manifest.json").read_text())
        self.assertEqual(manifest["missingLicenseFiles"], [])
        self.assertEqual(set(manifest["workerHashes"]), set(runtime.RUNTIME_MODULES))
        self.assertEqual(manifest, privacy.distribution_manifest(manifest))
        self.assertTrue((self.output / "python/bin/python3").is_symlink())

    def test_source_encoding_normalization_keeps_ast_and_only_updates_encoding_header(self):
        data = '# coding: latin-1\ntext = "café"\n# coding: declaration\n'.encode("latin-1")
        normalized = runtime.normalized_python(data)
        self.assertIn(b"coding: utf-8", normalized)
        self.assertIn(b"coding: declaration", normalized)
        self.assertEqual(ast.dump(ast.parse(data)), ast.dump(ast.parse(normalized)))
        control = 'text = "soft\u00adhyphen"\n'.encode()
        self.assertEqual(ast.dump(ast.parse(control)), ast.dump(ast.parse(runtime.normalized_python(control))))

    def test_certifi_comments_are_removed_without_changing_certificates(self):
        original = b"# Synthetic label\n-----BEGIN CERTIFICATE-----\nYWJj\n-----END CERTIFICATE-----\n"
        source = self.write("lib/python3.13/site-packages/certifi/cacert.pem", original)
        target = self.root / "new.pem"
        runtime.copy_runtime_file(source, target, clone=False)
        self.assertEqual(target.read_bytes(), original.split(b"\n", 1)[1])
        self.assertEqual(source.read_bytes(), original)

    def test_normalization_notice_preserves_multiline_docstrings_and_encoding_cookies(self):
        for data in ['"""Module\ndocumentation with soft\u00adhyphen\n"""\nvalue = 1\n'.encode(),
                     '#!/usr/bin/python3\n# coding: latin-1\n"""caf\xe9"""\n'.encode('latin-1')]:
            source = self.write("lib/python3.13/site-packages/fixture/module.py", data)
            target = self.root / "normalized.py"
            runtime.copy_runtime_file(source, target, clone=False)
            self.assertEqual(ast.dump(ast.parse(data)), ast.dump(ast.parse(target.read_bytes())))
            self.assertIn(b"Modified by Li on 2026-10-11", target.read_bytes())


class LegalNoticePolicyTests(unittest.TestCase):
    def test_nonstandard_and_flattened_notice_names_preserve_bytes(self):
        for name in ("LICENSE-MIT", "LICENSE-APACHE", "license-apache-2.0", "LICENSE.thirdparty",
                     "COPYING3.LIB", "UNLICENSE", "wheel.dist-info__licenses__LICENSE", "dragon4_LICENSE.txt"):
            with self.subTest(name=name):
                path = Path(name)
                self.assertTrue(privacy.license_filename(path))
                self.assertIsNotNone(privacy.decode_license_text(path, b"Copyright fixture\nPermission granted.\n"))

    def test_legacy_license_encoding_and_page_separator_are_bounded(self):
        self.assertIsNotNone(privacy.decode_license_text(Path("COPYING.LGPL"), b"Copyright caf\xe9\fLicense\n"))
        self.assertIsNone(privacy.decode_license_text(Path("data.bin"), b"Copyright caf\xe9\fLicense\n"))
        self.assertIsNone(privacy.decode_license_text(Path("LICENSE"), b"Copyright\0License"))
        self.assertIsNotNone(privacy.decode_license_text(Path("License.rtf"), b"{\\rtf1 Copyright License}\0"))
        self.assertIsNone(privacy.decode_license_text(Path("License.rtf"), b"{\\rtf1 Copyright \\object License}\0"))
        self.assertIsNone(privacy.decode_license_text(Path("License.rtf"), b"{\\rtf1 Copyright \\bin3 abc License}\0"))

    def test_code_and_workflow_substring_matches_are_not_notices(self):
        for name in ("copying.rs", "copyright.pm", "license.yml", "LicenseProtection.py", "mod.rs", "data.npy"):
            self.assertFalse(privacy.license_filename(Path(name)), name)

    def test_renamed_structured_private_data_still_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "LICENSE-MIT"
            path.write_text('{"rawText":"synthetic classroom canary"}')
            with self.assertRaisesRegex(privacy.PrivacyError, "classroom-content-metadata"):
                privacy.inspect_metadata_file(path, Counter(), False)
            path.write_text('{"build":"/synthetic/private"}')
            with self.assertRaisesRegex(privacy.PrivacyError, "local-path-metadata"):
                privacy.inspect_metadata_file(path, Counter(), False)
            path.write_text('Copyright fixture\nBuilt at /synthetic/private\n')
            with self.assertRaisesRegex(privacy.PrivacyError, "local-path-metadata"):
                privacy.inspect_metadata_file(path, Counter(), False)

    def test_cargo_declarations_are_parsed_identity_and_content_checked(self):
        path = Path("Licenses/native-cargo-notices/fixture-1.0/DECLARATION-Cargo.toml")
        data = b'[package]\nname="fixture"\nversion="1.0"\nlicense="MIT"\n'
        counts = Counter()
        self.assertTrue(privacy.inspect_cargo_license_declaration(path, data, counts))
        self.assertEqual(counts["metadata_files"], 1)
        for private in (b'\nrawText="synthetic canary"\n', b'\n# /synthetic/private\n', b'\npath="/synthetic/private"\n'):
            with self.assertRaises(privacy.PrivacyError):
                privacy.inspect_cargo_license_declaration(path, data + private, Counter())
        with self.assertRaisesRegex(privacy.PrivacyError, "identity-mismatch"):
            privacy.inspect_cargo_license_declaration(path, data.replace(b'"1.0"', b'"2.0"'), Counter())
        self.assertFalse(privacy.inspect_cargo_license_declaration(Path("Cargo.toml"), data, Counter()))


if __name__ == "__main__":
    unittest.main()
