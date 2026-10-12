"""Full hash-bound archive/native regressions; fixtures are static only."""
from collections import Counter
import hashlib
import os
from pathlib import Path
import struct
import tarfile
import time
import unittest
from unittest.mock import patch

from Scripts import macho_paths as macho, reviewed_resources as reviewed
from Scripts.privacy_package import PrivacyError, validate_metadata


RESOURCE = "Contents/Resources/LanguageRuntime/Licenses/fixture/source.tar"
ENCODINGS = ("utf-8", "utf-16-le", "utf-16-be")
HOME = "/" + "Users/reviewprobe/private"
WINDOWS = (r"C:\Users\reviewprobe\build\worker.c",
           r"D:\Documents and Settings\reviewprobe\build\worker.c",
           r"C:\\Users\\reviewprobe\\build\\worker.c",
           "C:/" + "Users/reviewprobe/build/worker.c", r"\\build-host\share\worker.c")


def thin(tail=b""):
    return struct.pack("<8I", 0xFEEDFACF, 0x100000C, 0, 6, 0, 0, 0, 0) + tail


def catalog(tail=b""):
    return struct.pack("<7I", 0x950412DE, 0, 0, 28, 28, 0, 28) + tail


def archive(name, data):
    header = tarfile.TarInfo("fixture-1.0/" + name)
    header.size = len(data)
    return header.tobuf(format=tarfile.USTAR_FORMAT) + data + b"\0" * (-len(data) % 512) + b"\0" * 1024


class BinaryPrivacyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        parent = Path(os.environ.get("LIVELINGO_RELPIPE_TEST_OUTPUT",
                                    Path(__file__).resolve().parents[1] / "work/relpipe/relpipe6/binary-tests"))
        cls.root = parent / ("fixtures-" + str(time.time_ns()))
        cls.root.mkdir(parents=True)
        cls.serial = 0

    def fixture(self, data):
        type(self).serial += 1
        path = self.root / str(type(self).serial)
        path.write_bytes(data)
        return path

    def source(self, name, data, *, examples=None, stale=False, opaque=False):
        blob = archive(name, data)
        item = dict(path=RESOURCE, sha256=hashlib.sha256(blob if not stale else b"old").hexdigest(),
                    format="source-tar", package="fixture", version="1.0",
                    reason="Static regression; fixture never executed")
        if opaque:
            item["opaqueSourceFixtures"] = {"fixture-1.0/" + name: hashlib.sha256(data).hexdigest()}
        if examples is not None:
            item["publicSourceHostPathExamples"] = {"fixture-1.0/" + name: {
                "sha256": hashlib.sha256(data).hexdigest(), "examples": examples,
                "reason": "Exact public upstream regression example"}}
        counts = Counter()
        self.assertTrue(reviewed.inspect(self.fixture(blob), RESOURCE, {RESOURCE: item}, counts))
        return counts

    def test_archive_all_binary_formats_and_encodings_reject_private_tails(self):
        for name, prefix, opaque in (("probe.dylib", thin(), False), ("locale.mo", catalog(), False),
                                      ("image.png", b"\x89PNG\r\n\x1a\n", False), ("fixture.bin", b"\0\1", True)):
            for encoding in ENCODINGS:
                with self.subTest(name=name, encoding=encoding):
                    with self.assertRaises(PrivacyError):
                        self.source(name, prefix + b"\0" + HOME.encode(encoding) + b"\0\0", opaque=opaque)

    def test_archive_stale_hash_rejected_before_scan(self):
        with self.assertRaisesRegex(PrivacyError, "reviewed-resource-hash-mismatch"):
            self.source("probe.dylib", thin(HOME.encode("utf-16-le")), stale=True)

    def test_archive_exact_public_binary_example_all_encodings(self):
        value = "/home/upstream/public/example.c"
        examples = [{"style": "posix", "path": value[1:]}]
        for name, prefix in (("probe.dylib", thin()), ("locale.mo", catalog())):
            for encoding in ENCODINGS:
                with self.subTest(name=name, encoding=encoding):
                    data = prefix + b"\0" + value.encode(encoding) + b"\0\0"
                    self.source(name, data, examples=examples)
                    with self.assertRaises(PrivacyError):
                        self.source(name, data + HOME.encode(encoding) + b"\0\0", examples=examples)

    def test_archive_approval_cannot_mask_a_longer_private_string(self):
        value = "/home/upstream/public"
        examples = [{"style": "posix", "path": value[1:]}]
        with self.assertRaisesRegex(PrivacyError, "local-path-source-binary"):
            self.source("probe.dylib", thin((value + "/private.c").encode("utf-16-be")), examples=examples)

    def test_binary_readable_hex_binds_exact_spelling_in_all_encodings(self):
        for value in ("/tmp//upstream.c", "//home/upstream/public.c%", r"\\upstream-host\share\public.c"):
            examples = [{"style": "binary-readable-hex", "path": value.encode().hex()}]
            for encoding in ENCODINGS:
                with self.subTest(value=value, encoding=encoding):
                    data = thin() + b"\0" + value.encode(encoding) + b"\0\0"
                    self.source("probe.dylib", data, examples=examples)
                    with self.assertRaises(PrivacyError):
                        self.source("probe.dylib", thin((value + "/other.c").encode(encoding)), examples=examples)

    def test_binary_readable_hex_is_not_a_pattern(self):
        examples = [{"style": "binary-readable-hex", "path": b"/tmp/*".hex()}]
        with self.assertRaisesRegex(PrivacyError, "local-path-source-binary"):
            self.source("probe.dylib", thin(b"/tmp/private.c"), examples=examples)

    def test_macho_windows_all_encodings_and_offsets(self):
        for value in WINDOWS:
            for encoding in ENCODINGS:
                with self.subTest(value=value, encoding=encoding):
                    prefix = thin() + b"\0\xff"
                    blob = prefix + value.encode(encoding) + b"\0\0"
                    matches = macho.scan_readable_paths_bytes(blob)["matches"]
                    self.assertIn({"offset": len(prefix), "path": value, "encoding": encoding}, matches)
                    with self.assertRaisesRegex(PrivacyError, "local-path-macho-build-string"):
                        macho.inspect_build_paths(self.fixture(blob), {})

    def test_macho_exact_hash_bound_windows_approval(self):
        value = WINDOWS[0]
        blob = thin(value.encode("utf-16-le") + b"\0\0")
        path = self.fixture(blob)
        resource = "Contents/Resources/LanguageRuntime/python/lib/libfixture.dylib"
        item = dict(path=resource, sha256=hashlib.sha256(blob).hexdigest(),
                    format="macho-public-build-strings", package="fixture", version="1.0",
                    reason="Exact public upstream fixture", publicBuildPathsHex=[value.encode().hex()])
        self.assertTrue(reviewed.inspect(path, resource, {resource: item}, Counter()))
        path.write_bytes(blob + b"extra")
        with self.assertRaisesRegex(PrivacyError, "reviewed-resource-hash-mismatch"):
            reviewed.inspect(path, resource, {resource: item}, Counter())

    def test_macho_windows_home_and_unc_compiler_operands(self):
        for value in WINDOWS:
            for prefix in ("-I", "-L", "-isystem", "-isystem=", "-iquote "):
                for encoding in ENCODINGS:
                    with self.subTest(value=value, prefix=prefix, encoding=encoding):
                        blob = thin() + b"\0" + (prefix + value).encode(encoding) + b"\0\0"
                        matches = macho.scan_readable_paths_bytes(blob)["matches"]
                        self.assertTrue(any(match["path"] == value for match in matches))
                        with self.assertRaises(PrivacyError):
                            macho.inspect_build_paths(self.fixture(blob), {})
        for encoding in ENCODINGS:
            value = WINDOWS[0]
            matches = macho.scan_readable_paths_bytes(
                thin() + b"\0" + ("__symbol_" + value).encode(encoding) + b"\0\0")["matches"]
            self.assertTrue(any(match["path"] == value for match in matches))

    def test_posix_label_suffix_is_not_a_forward_slash_drive(self):
        value = "/" + "Users/reviewprobe/build/source.rs"
        for encoding in ENCODINGS:
            blob = thin() + b"\0" + ("prefix:" + value).encode(encoding) + b"\0\0"
            matches = macho.scan_readable_paths_bytes(blob)["matches"]
            self.assertTrue(any(match["path"] == value for match in matches))
            self.assertFalse(any(match["path"].startswith("x:") for match in matches))

    def test_generic_binary_clean_and_public_https_controls(self):
        for value in ("https://example.org/source.c", "public syntax file:", "Cocoa"):
            for encoding in ENCODINGS:
                self.assertEqual(macho.scan_binary_paths_bytes(value.encode(encoding))["matches"], [])
        for name, data in (("probe.dylib", thin()), ("locale.mo", catalog())):
            self.source(name, data)

    def test_metadata_and_binary_share_windows_policy(self):
        for value in WINDOWS:
            self.assertTrue(macho.private_path(value))
            with self.assertRaises(PrivacyError):
                validate_metadata({"path": value})

    def test_assembler_preserves_already_portable_native_bytes(self):
        from Scripts.test_privacy_package import load_script
        bundle = load_script("bundle-mlx-app")
        python = self.root / "asr-python"
        packages = python / "lib/python3.13/site-packages"
        libomp = packages / "sklearn/.dylibs/libomp.dylib"
        extension = packages / "numba/np/ufunc/omppool.fixture.so"
        libomp.parent.mkdir(parents=True)
        extension.parent.mkdir(parents=True)
        libomp.write_bytes(b"fixture")
        extension.write_bytes(thin())
        replacement = "@loader_path/../../../sklearn/.dylibs/libomp.dylib"
        with patch.dict("sys.modules", macho_paths=macho), \
             patch.object(macho, "load_paths", return_value=[(0xC, replacement)]), \
             patch.object(bundle, "run") as run:
            bundle.repair_portable_asr_dylib_links(python)
            run.assert_not_called()
        self.assertEqual(extension.read_bytes(), thin())


if __name__ == "__main__":
    unittest.main()
