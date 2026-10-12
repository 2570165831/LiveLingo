"""Compile disposable host fixtures and inspect them; never load or execute."""
from pathlib import Path
import subprocess
import tempfile
import unittest
from Scripts import native_build_paths as native
from Scripts.privacy_package import PrivacyError


class NativeBuildPathTests(unittest.TestCase):
    def compile(self, root, name, literal):
        source = root / (name + ".c")
        source.write_text('const char *diagnostic(void) { return "' + literal + '"; }\n')
        path = root / name
        subprocess.run(["/usr/bin/xcrun", "clang", "-dynamiclib", "-g", str(source),
                        "-Wl,-install_name,@rpath/" + name, "-o", str(path)],
                       check=True, capture_output=True)
        return path

    def test_rust_diagnostics_remap_without_instruction_changes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            private = "/" + "Users/li/build/cargo/registry/src/index.crates.io-aabbcc/serde/src/lib.rs"
            path = self.compile(root, "outlines_core.fixture.so", private)
            result = native.sanitize_build_paths(path, root)
            self.assertEqual(len(result["cstringEdits"]), 1)
            self.assertEqual(result["changedFileBackedSections"], ["__TEXT,__cstring"])
            self.assertNotIn(private.encode(), path.read_bytes())
            self.assertIn(b"serde/src/lib.rs", path.read_bytes())

    def test_llvm_metal_build_fallback_is_empty_after_sanitization(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            private = "/" + "Users/li/build/mlx/backend/metal/kernels//mlx.metallib"
            path = self.compile(root, "libmlx.dylib", private)
            result = native.sanitize_build_paths(path, root)
            change = result["cstringEdits"][0]
            self.assertEqual(path.read_bytes()[change["offset"]:change["offset"] + change["length"]],
                             bytes(change["length"]))
            self.assertTrue(result["instructionsUnchanged"])

    def test_cython_diagnostic_temporary_directory_is_remapped(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            private = "/private/var/folders/fixture/T/build-env-x/lib/python3.13/site-packages/numpy/__init__.cython-30.pxd"
            path = self.compile(root, "cython.fixture.so", private)
            result = native.sanitize_build_paths(path, root)
            self.assertEqual(len(result["cstringEdits"]), 1)
            self.assertNotIn(private.encode(), path.read_bytes())
            self.assertIn(b"numpy/__init__.cython-30.pxd", path.read_bytes())

    def test_unknown_private_operand_and_outside_copy_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = self.compile(root, "libmlx.dylib", "/" + "Users/li/private/runtime-resource.bin")
            with self.assertRaises(PrivacyError):
                native.sanitize_build_paths(path, root)
            with self.assertRaises(PrivacyError):
                native.sanitize_build_paths(path, root / "other")
