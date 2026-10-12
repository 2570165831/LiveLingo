"""R3/R7 synthetic archive regressions; no fixture is executed or removed."""
import bz2
from collections import Counter
import gzip
import hashlib
import io
import lzma
from pathlib import Path
import struct
import tarfile
import time
import unittest

from Scripts import reviewed_resources as reviewed
from Scripts import source_archive as source
from Scripts.privacy_package import PrivacyError


OUTPUT = Path(__file__).resolve().parent.parent / "work/relpipe/relpipe5/archive-r3-r7-20261012-a"
ROOT = "fixture-1.0/"
RESOURCE = "Contents/Resources/LanguageRuntime/Licenses/fixture/source.tar"
HOST = ("/" + "Users/reviewprobe/build").encode()
C_SUFFIXES = (".c", ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp", ".hxx", ".m", ".mm", ".inc")


def header(name, size, kind=tarfile.REGTYPE):
    info = tarfile.TarInfo(name)
    info.type, info.size = kind, size
    return info.tobuf(format=tarfile.USTAR_FORMAT)


def entry(name, data, kind=tarfile.REGTYPE):
    return header(name, len(data), kind) + data + b"\0" * (-len(data) % 512)


def archive(name="main.c", data=b"int value = 0;\n", prefix=b""):
    return prefix + entry(ROOT + name, data) + b"\0" * 1024


def pax_record(key, value):
    body = key.encode() + b"=" + value + b"\n"
    size = len(body) + 2
    while True:
        result = str(size).encode() + b" " + body
        if len(result) == size:
            return result
        size = len(result)


def pax(data, kind=tarfile.XHDTYPE):
    return entry("././@PaxHeader", data, kind)


def macho(value=b"@loader_path/libsafe.dylib", *, endian="<", command=0xC, tail=b""):
    fixed = 24 if command in (0xC, 0xD) else 12
    payload = value + b"\0" + tail
    width = (fixed + len(payload) + 7) // 8 * 8
    load = struct.pack(endian + "III", command, width, fixed) + b"\0" * (fixed - 12)
    load += payload + b"\0" * (width - fixed - len(payload))
    return struct.pack(endian + "8I", 0xFEEDFACF, 0x100000C, 0, 6, 1, width, 0, 0) + load


def catalog(tail=b"", endian="<"):
    return struct.pack(endian + "7I", 0x950412DE, 0, 0, 28, 28, 0, 28) + tail


class ArchiveRegressionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = OUTPUT / ("fixtures-" + str(time.time_ns()))
        cls.scratch.mkdir(parents=True)
        cls.serial = 0

    def check(self, data, *, fixtures=None, examples=None, digest=None):
        type(self).serial += 1
        path = self.scratch / (str(self.serial) + ".tar")
        path.write_bytes(data)
        item = {"path": RESOURCE, "sha256": digest or hashlib.sha256(data).hexdigest(),
                "format": "source-tar", "package": "fixture", "version": "1.0",
                "reason": "Synthetic static regression input; never executed."}
        if fixtures is not None:
            item["opaqueSourceFixtures"] = fixtures
        if examples is not None:
            item["publicSourceHostPathExamples"] = examples
        counts = Counter()
        self.assertTrue(reviewed.inspect(path, RESOURCE, {RESOURCE: item}, counts))
        return counts

    def test_duplicate_pax_private_then_public(self):
        data = pax_record("comment", HOST) + pax_record("comment", b"public")
        with self.assertRaises(PrivacyError):
            self.check(archive(prefix=pax(data)))

    def test_duplicate_pax_public_values_are_rejected(self):
        data = pax_record("comment", b"first") + pax_record("comment", b"second")
        with self.assertRaisesRegex(PrivacyError, "duplicate-source-pax-key"):
            self.check(archive(prefix=pax(data)))

    def test_unique_pax_records_are_accepted(self):
        data = pax_record("comment", b"public") + pax_record("path", (ROOT + "renamed.c").encode())
        self.assertEqual(self.check(archive(prefix=pax(data)))["source_archive_members"], 1)

    def test_global_pax_duplicate_records_are_rejected(self):
        data = pax_record("comment", HOST) + pax_record("comment", b"public")
        with self.assertRaises(PrivacyError):
            self.check(archive(prefix=pax(data, tarfile.XGLTYPE)))

    def test_pax_ignored_nul_tail_is_rejected(self):
        with self.assertRaises(PrivacyError):
            self.check(archive(prefix=pax(pax_record("comment", b"public") + b"\0" + HOST)))

    def test_member_padding_private_bytes_are_rejected(self):
        data = bytearray(archive(data=b"x"))
        data[513:513 + len(HOST)] = HOST
        with self.assertRaises(PrivacyError):
            self.check(bytes(data))

    def test_member_padding_nonzero_bytes_are_rejected(self):
        data = bytearray(archive(data=b"x"))
        data[1023] = 1
        with self.assertRaisesRegex(PrivacyError, "nonzero-source-archive-padding"):
            self.check(bytes(data))

    def test_private_bytes_after_zero_end_are_rejected(self):
        with self.assertRaises(PrivacyError):
            self.check(archive() + HOST)

    def test_appended_second_tar_is_rejected(self):
        with self.assertRaisesRegex(PrivacyError, "nonzero-source-archive-trailer"):
            self.check(archive() + archive("extra.c"))

    def test_missing_second_end_block_is_rejected(self):
        with self.assertRaisesRegex(PrivacyError, "invalid-source-archive"):
            self.check(archive()[:-512])

    def test_compressed_archives_keep_envelope_checks(self):
        for compress in (gzip.compress, bz2.compress, lzma.compress):
            with self.subTest(format=compress.__module__):
                self.assertEqual(self.check(compress(archive()))["source_archive_members"], 1)
                with self.assertRaises(PrivacyError):
                    self.check(compress(archive() + HOST))

    def test_known_macho_private_dependency_is_rejected(self):
        with self.assertRaises(PrivacyError):
            self.check(archive("libprobe.dylib", macho(HOST + b"/libprobe.dylib")))

    def test_macho_nonload_raw_bytes_are_rejected(self):
        with self.assertRaises(PrivacyError):
            self.check(archive("libprobe.dylib", macho() + b"\0" + HOST))

    def test_macho_string_nul_tail_is_rejected(self):
        with self.assertRaises(PrivacyError):
            self.check(archive("libprobe.dylib", macho(tail=HOST)))

    def test_macho_nonportable_dependency_is_rejected(self):
        with self.assertRaisesRegex(PrivacyError, "nonportable-macho-load-command"):
            self.check(archive("libprobe.dylib", macho(b"/build/libprobe.dylib")))

    def test_malformed_macho_is_rejected(self):
        data = bytearray(macho())
        struct.pack_into("<I", data, 36, 0x100000)
        with self.assertRaisesRegex(PrivacyError, "invalid-macho-load-commands"):
            self.check(archive("libprobe.dylib", bytes(data)))

    def test_macho_without_recognized_suffix_is_still_checked(self):
        with self.assertRaisesRegex(PrivacyError, "invalid-macho-load-commands"):
            self.check(archive("testdata/native", macho()[:32]))

    def test_clean_macho_unknown_suffix_still_needs_exact_fixture_approval(self):
        data = macho()
        with self.assertRaisesRegex(PrivacyError, "unreviewed-source-archive-binary"):
            self.check(archive("testdata/native", data))
        fixtures = {ROOT + "testdata/native": hashlib.sha256(data).hexdigest()}
        self.assertEqual(self.check(archive("testdata/native", data), fixtures=fixtures)["opaque_source_fixtures"], 1)

    def test_portable_macho_both_byte_orders_are_accepted(self):
        for endian in ("<", ">"):
            with self.subTest(endian=endian):
                self.assertEqual(self.check(archive("libprobe.dylib", macho(endian=endian)))["macho_files"], 1)

    def test_catalog_unreferenced_tail_is_rejected(self):
        for endian in ("<", ">"):
            with self.subTest(endian=endian):
                with self.assertRaises(PrivacyError):
                    self.check(archive("locale.mo", catalog(HOST, endian)))

    def test_catalog_hash_table_bytes_are_scanned(self):
        data = bytearray(catalog(b"\0" * 32))
        struct.pack_into("<II", data, 20, 8, 28)
        data[28:28 + len(HOST)] = HOST
        with self.assertRaises(PrivacyError):
            self.check(archive("locale.mo", bytes(data)))

    def test_empty_catalog_both_byte_orders_are_accepted(self):
        for endian in ("<", ">"):
            with self.subTest(endian=endian):
                self.assertEqual(self.check(archive("locale.mo", catalog(endian=endian)))["source_catalog_files"], 1)

    def test_known_image_binary_raw_bytes_are_scanned(self):
        with self.assertRaises(PrivacyError):
            self.check(archive("probe.png", b"\x89PNG\r\n\x1a\n\0" + HOST))

    def test_opaque_hash_approval_does_not_waive_raw_paths(self):
        data = b"\0\x01" + HOST
        fixtures = {ROOT + "testdata/probe.bin": hashlib.sha256(data).hexdigest()}
        with self.assertRaises(PrivacyError):
            self.check(archive("testdata/probe.bin", data), fixtures=fixtures)

    def test_valid_cpp_attribute_all_supported_suffixes(self):
        for suffix in C_SUFFIXES:
            for spelling in (suffix, suffix.upper()):
                with self.subTest(suffix=spelling):
                    self.assertEqual(self.check(archive("probe" + spelling,
                        b"[[maybe_unused]] const int value = 0;\n"))["source_archive_members"], 1)

    def test_cpp_encoded_path_all_literal_suffixes(self):
        for suffix in C_SUFFIXES[:-1]:
            with self.subTest(suffix=suffix):
                with self.assertRaises(PrivacyError):
                    self.check(archive("probe" + suffix, b'[[maybe_unused]] const char *p="\\057Users\\057reviewprobe\\057build";'))

    def test_cpp_complete_metadata_still_has_strict_duplicate_keys(self):
        for suffix in C_SUFFIXES:
            with self.subTest(suffix=suffix):
                with self.assertRaisesRegex(PrivacyError, "invalid-package-json"):
                    self.check(archive("probe" + suffix, b'{"key":1,"key":2}'))

    def test_cpp_complete_metadata_still_rejects_classroom_fields(self):
        with self.assertRaises(PrivacyError):
            self.check(archive("probe.cxx", b'{"rawText":"classroom canary"}'))

    def test_old_hash_does_not_approve_modified_tar(self):
        with self.assertRaisesRegex(PrivacyError, "reviewed-resource-hash-mismatch"):
            self.check(archive() + HOST, digest=hashlib.sha256(archive()).hexdigest())

    def test_existing_unicode_path_control_is_rejected(self):
        with self.assertRaises(PrivacyError):
            self.check(archive("probe.py", b'BUILD="\\u002fUsers\\u002freviewprobe\\u002fbuild"'))

    def test_existing_uname_hidden_path_control_is_rejected(self):
        data = bytearray(archive())
        data[265:265 + 1 + len(HOST)] = b"\0" + HOST
        data[148:156] = b" " * 8
        data[148:156] = ("%06o\0 " % sum(data[:512])).encode()
        with self.assertRaisesRegex(PrivacyError, "nonpublic-source-archive-header"):
            self.check(bytes(data))

    def test_exact_public_example_is_preserved(self):
        data = b'const char *p="/home/public/example";\n'
        examples = {ROOT + "probe.cpp": {"sha256": hashlib.sha256(data).hexdigest(),
            "examples": [{"style": "posix", "path": "home/public/example"}],
            "reason": "Synthetic public upstream documentation example."}}
        self.assertEqual(self.check(archive("probe.cpp", data), examples=examples)["source_archive_members"], 1)

    def test_source_repeated_slashes_are_path_operands(self):
        with self.assertRaisesRegex(PrivacyError, "local-path-metadata"):
            self.check(archive("probe.py", b'BUILD="//' + HOST + b'"\n'))

    def test_source_localhost_file_url_is_a_path_operand(self):
        with self.assertRaisesRegex(PrivacyError, "local-path-metadata"):
            self.check(archive("probe.cxx", b'const char *p="file://localhost' + HOST + b'";\n'))

    def test_source_compiler_flag_is_a_path_operand(self):
        with self.assertRaisesRegex(PrivacyError, "local-path-metadata"):
            self.check(archive("Makefile", b'CPPFLAGS = -isystem' + HOST + b'\n'))

    def test_source_operand_public_url_and_nested_system_path_controls(self):
        for name, data in (("probe.py", b'URL="https://example.invalid' + HOST + b'"\n'),
                           ("probe.cxx", b'const char *p="/boot/home/public/example";\n'),
                           ("Makefile", b'CPPFLAGS = -isystem/usr/include\n')):
            with self.subTest(name=name):
                self.assertEqual(self.check(archive(name, data))["source_archive_members"], 1)

    def test_source_build_text_uses_the_same_operand_policy(self):
        cases = (("probe.py", b'BUILD="//' + HOST + b'"\n'),
                 ("probe.cxx", b'const char *p="file://localhost' + HOST + b'";\n'),
                 ("Makefile", b'CPPFLAGS = -isystem' + HOST + b'\n'))
        for name, data in cases:
            with self.subTest(name=name):
                type(self).serial += 1
                folder = self.scratch / ("build-text-" + str(self.serial))
                folder.mkdir()
                target = folder / name
                target.write_bytes(data)
                item = {"path": RESOURCE, "sha256": hashlib.sha256(data).hexdigest(),
                        "format": "source-build-text", "package": "fixture", "version": "1.0",
                        "reason": "Synthetic operand regression, never executed."}
                with self.assertRaisesRegex(PrivacyError, "local-path-metadata"):
                    reviewed.inspect(target, RESOURCE, {RESOURCE: item}, Counter())

    def binary_example(self, data):
        return {ROOT + "testdata/probe.bin": {"sha256": hashlib.sha256(data).hexdigest(),
            "examples": [{"style": "posix", "path": "home/public/example"}],
            "reason": "Exact upstream binary regression path example, bound to this member."}}

    def test_binary_public_example_needs_exact_member_hash_and_reason(self):
        data = b"\0\x01/home/public/example\0"
        fixtures = {ROOT + "testdata/probe.bin": hashlib.sha256(data).hexdigest()}
        examples = self.binary_example(data)
        self.assertEqual(self.check(archive("testdata/probe.bin", data), fixtures=fixtures,
                                   examples=examples)["opaque_source_fixtures"], 1)
        examples[ROOT + "testdata/probe.bin"].pop("reason")
        with self.assertRaisesRegex(PrivacyError, "invalid-source-member-approval"):
            self.check(archive("testdata/probe.bin", data), fixtures=fixtures, examples=examples)
        with self.assertRaisesRegex(PrivacyError, "source-member-example-hash-mismatch"):
            self.check(archive("testdata/probe.bin", data + b"changed"), examples=self.binary_example(data))

    def test_binary_public_example_does_not_waive_other_paths(self):
        data = b"\0\x01/home/public/example\0" + HOST
        fixtures = {ROOT + "testdata/probe.bin": hashlib.sha256(data).hexdigest()}
        with self.assertRaisesRegex(PrivacyError, "local-path-metadata"):
            self.check(archive("testdata/probe.bin", data), fixtures=fixtures, examples=self.binary_example(data))

    def test_binary_public_example_does_not_waive_envelope(self):
        data = b"\0\x01/home/public/example\0"
        fixtures = {ROOT + "testdata/probe.bin": hashlib.sha256(data).hexdigest()}
        with self.assertRaisesRegex(PrivacyError, "nonzero-source-archive-trailer"):
            self.check(archive("testdata/probe.bin", data) + HOST,
                       fixtures=fixtures, examples=self.binary_example(data))

    def test_long_name_extension_ignored_bytes_are_rejected(self):
        name = (ROOT + "renamed.c").encode()
        with self.assertRaises(PrivacyError):
            self.check(archive(prefix=entry("././@LongLink", name + b"\0" + HOST, tarfile.GNUTYPE_LONGNAME)))
        self.assertEqual(self.check(archive(prefix=entry("././@LongLink", name + b"\0",
                                                       tarfile.GNUTYPE_LONGNAME)))["source_archive_members"], 1)

    def test_duplicate_keys_across_local_pax_headers_are_rejected(self):
        before = pax(pax_record("comment", b"public")) + pax(pax_record("comment", b"also public"))
        with self.assertRaisesRegex(PrivacyError, "duplicate-source-pax-key"):
            self.check(archive(prefix=before))

    def test_pax_size_override_keeps_padding_alignment(self):
        prefix = pax(pax_record("size", b"4"))
        body = header(ROOT + "main.c", 1) + b"int " + b"\0" * 508 + b"\0" * 1024
        self.assertEqual(self.check(prefix + body)["source_archive_members"], 1)

    def test_universal_macho_second_slice_is_checked(self):
        first, second = macho(), macho(b"/build/second.dylib")
        offset = 48
        fat = struct.pack(">II", 0xCAFEBABE, 2)
        fat += struct.pack(">IIIII", 0x100000C, 0, offset, len(first), 0)
        fat += struct.pack(">IIIII", 0x1000007, 0, offset + len(first), len(second), 0)
        with self.assertRaisesRegex(PrivacyError, "nonportable-macho-load-command"):
            self.check(archive("libprobe.dylib", fat + first + second))

    def test_universal_macho_overlapping_slices_are_rejected(self):
        first = macho()
        fat = struct.pack(">II", 0xCAFEBABE, 2)
        for _ in range(2):
            fat += struct.pack(">IIIII", 0x100000C, 0, 48, len(first), 0)
        with self.assertRaisesRegex(PrivacyError, "invalid-macho-load-commands"):
            self.check(archive("libprobe.dylib", fat + first))


if __name__ == "__main__":
    unittest.main()
