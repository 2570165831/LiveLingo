"""Decoded configuration privacy and relocation with synthetic inputs only."""
import ast
from contextlib import contextmanager
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from Scripts import privacy_package as privacy
from Scripts import reviewed_resources as reviewed
from Scripts import runtime_configuration as config
from Scripts.runtime_prepare import removal_reason


@contextmanager
def temporary():
    task = Path(__file__).resolve().parent.parent / "work/relpipe"
    task.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix="configuration-tests-", dir=task))
    try:
        yield str(directory)
    finally:
        superseded = task / "superseded"
        superseded.mkdir(exist_ok=True)
        directory.rename(superseded / directory.name)


class RuntimeConfigurationTests(unittest.TestCase):
    def test_sysconfig_install_directories_follow_the_copy_location(self):
        private = "/" + "Users/synthetic/build/python"
        original = ("# Upstream Copyright fixture; keep this comment.\n"
                    "build_time_vars = " + repr({"prefix": private, "exec_prefix": private,
                    "LIBDIR": private + "/lib", "BINDIR": private + "/bin",
                    "CONFIG_ARGS": "--enable-shared --prefix=" + private,
                    "PY_CFLAGS_NODIST": "-arch arm64 -fprofile-instr-use=" + private + "/profile -O3",
                    "abs_builddir": private, "VERSION": "3.13", "SIZEOF_VOID_P": 8}) + "\n").encode()
        clean, fields = config.prepare_configuration(original, "lib/python3.13/_sysconfigdata__darwin_darwin.py")
        self.assertTrue(clean.startswith(b"# Upstream Copyright fixture; keep this comment."))
        for directory in ("first-copy", "second-copy"):
            with temporary() as location:
                base = Path(location) / directory
                file = base / "lib/python3.13/_sysconfigdata__darwin_darwin.py"
                scope = {"__file__": str(file)}
                exec(compile(clean, "synthetic-config", "exec"), scope)
                values = scope["build_time_vars"]
                self.assertEqual(values["prefix"], str(base))
                self.assertEqual(values["LIBDIR"], str(base / "lib"))
                self.assertEqual(values["SIZEOF_VOID_P"], 8)
                self.assertEqual(values["CONFIG_ARGS"], "--enable-shared")
                self.assertEqual(values["PY_CFLAGS_NODIST"], "-arch arm64 -O3")
                self.assertEqual(values["abs_builddir"], "")
        self.assertEqual(len(fields), 7)
        self.assertNotIn(private.encode(), clean)

    def test_scientific_config_omits_build_locations_and_keeps_compiler_version(self):
        original = ("# Copyright fixture\nCONFIG = _cleanup(" + repr({"Compilers": {
            "fortran": {"version": "13.4.0"}, "pythran": {"include directory": "../../private/var/folders/build/lib"}},
            "Python Information": {"path": "/private/var/folders/build/bin/python", "version": "3.13"}}) + ")\n").encode()
        clean, fields = config.prepare_configuration(original, "site-packages/scipy/__config__.py")
        scope = {"_cleanup": lambda value: value}
        exec(compile(clean, "synthetic-scipy-config", "exec"), scope)
        self.assertEqual(scope["CONFIG"]["Compilers"]["fortran"]["version"], "13.4.0")
        self.assertEqual(scope["CONFIG"]["Python Information"]["path"], "")
        self.assertEqual(len(fields), 2)

    def test_unknown_sysconfig_field_fails_instead_of_silently_rewriting(self):
        original = ("build_time_vars = " + repr({"UNKNOWN_REQUIRED_PATH": "/" + "Users/synthetic/build"})).encode()
        with self.assertRaisesRegex(privacy.PrivacyError, "unrecognized-host-bound-sysconfig-field"):
            config.prepare_configuration(original, "_sysconfigdata__darwin_darwin.py")

    def test_non_generated_python_ast_is_preserved(self):
        original = b"path = '/home/public/example'\n"
        self.assertEqual(config.prepare_configuration(original, "package/ordinary.py"), (original, []))

    def test_build_configuration_is_omitted_from_inference_runtime(self):
        stdlib = Path("lib/python3.13")
        for relative in ("lib/pkgconfig/python.pc", "lib/python3.13/config-3.13-darwin/Makefile", "include/python3.13/pyconfig.h", "pyvenv.cfg"):
            self.assertIsNotNone(removal_reason(Path(relative), stdlib, {}))


class PlainTextPathGateTests(unittest.TestCase):
    def test_actual_tree_route_rejects_plain_and_decoded_python_paths(self):
        private = "/" + "Users/synthetic/private"
        probes = [
            ("module.py", "value = " + repr(private)),
            ("module.py", "value = '" + ''.join('\\u%04x' % ord(c) for c in private) + "'"),
            ("module.py", "value = '" + ''.join('\\%03o' % ord(c) for c in private) + "'"),
            ("module.py", "value = b'" + ''.join('\\x%02x' % ord(c) for c in private) + "'"),
            ("module.py", "value = '/' + 'Users/synthetic/private'"),
            ("README.md", "Build directory: " + private),
            ("settings.txt", "-I/opt/homebrew/Cellar/gcc/lib"),
            ("module.py", "value = '../../private/var/folders/build/metadata'"),
            ("module.py", "value = '/var/folders/build/metadata'"),
        ]
        for name, source in probes:
            with self.subTest(name=name, source_kind=source[:6]), temporary() as directory:
                path = Path(directory) / name
                before = source.encode()
                path.write_bytes(before)
                with self.assertRaisesRegex(privacy.PrivacyError, "local-path-metadata"):
                    privacy.inspect_tree(directory)
                self.assertEqual(path.read_bytes(), before)

    def test_public_urls_and_system_header_examples_are_allowed(self):
        with temporary() as directory:
            (Path(directory) / "module.py").write_text("URL='https://example.invalid/home/public'\nHEADER='/usr/include/header.h'\n")
            self.assertEqual(privacy.inspect_tree(directory)["path_scanned_text_files"], 1)

    def test_public_example_approval_is_exact_and_other_literals_still_fail(self):
        relative = "Contents/Resources/LanguageRuntime/python/lib/python3.13/site-packages/fixture.py"
        public = b"value = '/home/public/example'\n"
        with temporary() as directory:
            root = Path(directory)
            file = root / relative
            file.parent.mkdir(parents=True)
            file.write_bytes(public)
            manifest = root / "approvals.json"
            item = {"path": relative, "sha256": hashlib.sha256(public).hexdigest(),
                    "format": "python-public-examples", "package": "fixture", "version": "1.0",
                    "reason": "Synthetic public upstream example", "publicHostPathExamples": [{"style": "posix", "path": "home/public/example"}]}
            manifest.write_text(json.dumps({"version": 1, "resources": [item]}))
            app = root / "app"
            app.mkdir()
            target = app / relative
            target.parent.mkdir(parents=True)
            target.write_bytes(public)
            with patch.object(reviewed, "MANIFEST", manifest):
                self.assertEqual(privacy.inspect_tree(app)["reviewed_resource_files"], 1)
                target.write_bytes(public + ("leak = " + repr('/' + 'Users/synthetic/private')).encode())
                with self.assertRaisesRegex(privacy.PrivacyError, "hash-mismatch"):
                    privacy.inspect_tree(app)
                item["sha256"] = hashlib.sha256(target.read_bytes()).hexdigest()
                manifest.write_text(json.dumps({"version": 1, "resources": [item]}))
                with self.assertRaisesRegex(privacy.PrivacyError, "local-path-metadata"):
                    privacy.inspect_tree(app)


if __name__ == "__main__":
    unittest.main()
