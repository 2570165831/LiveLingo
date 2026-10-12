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


    def test_metadata_and_binary_share_windows_policy(self):
        for value in WINDOWS:
            self.assertTrue(macho.private_path(value))
            with self.assertRaises(PrivacyError):
                validate_metadata({"path": value})



if __name__ == "__main__":
    unittest.main()
