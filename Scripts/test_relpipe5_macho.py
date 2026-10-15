"""R1/R6 static regressions. Fixtures persist under this task's evidence root."""
import hashlib
from pathlib import Path
import struct
import unittest
from unittest.mock import patch
import uuid

from Scripts import macho_paths as macho


EVIDENCE_ROOT = (Path(__file__).resolve().parents[1] / "work" / "relpipe" / "relpipe5"
                 / "macho-r1-r6-6b93c7e4")
USER_PATH = "/" + "Users/reviewprobe/build/source.rs"
UPSTREAM_PATH = "/" + "Users/runner/work/public/source.c"


def thin(command=None, value="@loader_path/libfoo.dylib", *, endian="<", wide=True,
         before=b"", after=b"", fixed_payload=None, trailer=b""):
    """Hand-assemble commands independently of the production parser."""
    payload = b""
    if command is not None:
        fixed = 24 if command in macho.DYLIB else (32 if command == 0x80000035 else 12)
        field = 24 if command == 0x80000035 else 8
        start = fixed + len(before)
        body = bytearray(fixed)
        if fixed_payload:
            body[12:12 + len(fixed_payload)] = fixed_payload
        body[field:field + 4] = struct.pack(endian + "I", start)
        body += before + value.encode() + b"\0" + after
        alignment = 8 if wide else 4
        body += b"\0" * (-len(body) % alignment)
        body[:8] = struct.pack(endian + "II", command, len(body))
        payload = bytes(body)
    header = struct.pack(endian + ("8I" if wide else "7I"),
                         *([0xFEEDFACF if wide else 0xFEEDFACE, 0x100000C,
                            0, 6, int(command is not None), len(payload), 0]
                           + ([0] if wide else [])))
    return header + payload + trailer


def fat(*slices, endian=">", wide=False, gap=b"", trailer=b""):
    width = 32 if wide else 20
    offset = 8 + len(slices) * width + len(gap)
    table = bytearray(struct.pack(endian + "II", 0xCAFEBABF if wide else 0xCAFEBABE, len(slices)))
    for data in slices:
        table += struct.pack(endian + ("IIQQII" if wide else "IIIII"),
                             *([0x100000C, 0, offset, len(data), 0] + ([0] if wide else [])))
        offset += len(data)
    return bytes(table) + gap + b"".join(slices) + trailer


def hash_bound_approvals(blob, recorded_hash, *paths):
    """Independent caller model: release approvals only on full-file hash match."""
    return paths if hashlib.sha256(blob).hexdigest() == recorded_hash else ()


class StaticMachOTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.run_root = EVIDENCE_ROOT / ("test-fixtures-" + uuid.uuid4().hex)
        cls.run_root.mkdir(parents=True, exist_ok=False)

    def setUp(self):
        self.root = self.run_root / self.id().split(".")[-1]
        self.root.mkdir()
        self.serial = 0

    def fixture(self, blob):
        self.serial += 1
        path = self.root / ("fixture-" + str(self.serial))
        path.write_bytes(blob)
        return path

    def assert_load_rejected(self, blob, reason="local-path-macho-load-command"):
        with self.assertRaisesRegex(macho.PrivacyError, reason):
            macho.inspect_load_paths(self.fixture(blob), {})

    def assert_raw_rejected(self, blob, *, approval=()):
        counts = {"preexisting": 7}
        with self.assertRaisesRegex(macho.PrivacyError, "local-path-macho-build-string"):
            macho.inspect_build_paths(self.fixture(blob), counts, allowed=approval)
        self.assertEqual(counts, {"preexisting": 7})

    def test_four_name_commands_are_accepted_in_all_thin_headers(self):
        for endian in ("<", ">"):
            for wide in (False, True):
                for command, value in ((0x12, "Cocoa"), (0x13, "Carbon"),
                                       (0x14, "LiveLingo"), (0x15, "libobjc")):
                    counts = {}
                    self.assertTrue(macho.inspect_load_paths(
                        self.fixture(thin(command, value, endian=endian, wide=wide)), counts))
                    self.assertEqual(counts["macho_names"], 1)
                    self.assertEqual(counts["macho_load_paths"], 0)

    def test_fileset_entry_is_an_identifier(self):
        self.assertTrue(macho.inspect_load_paths(
            self.fixture(thin(0x80000035, "com.example.component")), {}))

    def test_name_cannot_be_a_private_path(self):
        for command in macho.NAMES:
            self.assert_load_rejected(thin(command, USER_PATH))

    def test_names_are_opaque_and_do_not_select_a_load_location(self):
        for value in ("@loader_path/framework", "/usr/lib/libobjc.dylib", "../Cocoa", "file:Cocoa"):
            self.assertTrue(macho.inspect_load_paths(self.fixture(thin(0x12, value)), {}))

    def test_dependency_and_rpath_do_not_gain_name_exceptions(self):
        for command in (0xC, macho.RPATH, 0xE):
            self.assert_load_rejected(thin(command, "Cocoa"), "nonportable-macho-load-command")

    def test_known_strings_reject_private_bytes_after_nul(self):
        for endian in ("<", ">"):
            for wide in (False, True):
                for command in macho.STRINGS:
                    value = "Cocoa" if command in macho.NAMES else "@loader_path/libfoo.dylib"
                    self.assert_load_rejected(thin(command, value, endian=endian, wide=wide,
                                                   after=b"\0\x01" + USER_PATH.encode()))

    def test_known_strings_reject_private_bytes_before_string_offset(self):
        for command in macho.STRINGS:
            value = "Cocoa" if command in macho.NAMES else "@loader_path/libfoo.dylib"
            self.assert_load_rejected(thin(command, value, before=USER_PATH.encode() + b"\0"))

    def test_fixed_numeric_payload_is_checked_for_hidden_path(self):
        self.assert_load_rejected(thin(0xD, fixed_payload=b"/tmp/x\0"))

    def test_hidden_paths_use_case_and_separator_equivalent_roots(self):
        for value in ("///" + "Users/reviewprobe/build", "/" + "uSeRs/reviewprobe/build"):
            self.assert_load_rejected(thin(macho.RPATH, after=value.encode()))

    def test_zero_padding_and_public_padding_are_accepted(self):
        path = self.fixture(thin(0x12, "Cocoa", before=b"public\0", after=b"public\0"))
        self.assertTrue(macho.inspect_load_paths(path, {}))

    def test_hidden_path_in_second_fat_slice_is_rejected(self):
        for endian in ("<", ">"):
            for wide in (False, True):
                self.assert_load_rejected(fat(thin(0x12, "Cocoa"),
                    thin(macho.RPATH, after=USER_PATH.encode()), endian=endian, wide=wide))

    def test_unknown_command_still_checks_full_payload(self):
        self.assert_load_rejected(thin(0x2D, USER_PATH))

    def test_malformed_string_offsets_and_missing_nul_fail_closed(self):
        blob = thin(0x12, "Cocoa")
        for start in (0, 8, len(blob)):
            altered = blob[:40] + struct.pack("<I", start) + blob[44:]
            self.assert_load_rejected(altered, "invalid-macho-load-commands")
        altered = blob[:44] + b"X" * (len(blob) - 44)
        self.assert_load_rejected(altered, "invalid-macho-load-commands")

    def test_name_commands_do_not_trigger_copy_repair(self):
        path = self.fixture(thin(0x12, "Cocoa"))
        before = path.read_bytes()
        with patch.object(macho.subprocess, "run") as run:
            self.assertEqual(macho.make_portable(path, self.root), [])
            run.assert_not_called()
        self.assertEqual(path.read_bytes(), before)

    def test_hidden_bytes_fail_before_repair_tool_can_run(self):
        path = self.fixture(thin(macho.RPATH, after=USER_PATH.encode()))
        with patch.object(macho.subprocess, "run") as run:
            with self.assertRaises(macho.PrivacyError):
                macho.make_portable(path, self.root)
            run.assert_not_called()

    def test_raw_scan_catches_non_load_region_with_exact_offset_and_hash(self):
        prefix = thin(0xD) + b"\0debug-symbol-prefix:"
        blob = prefix + USER_PATH.encode() + b"\0"
        path = self.fixture(blob)
        self.assertTrue(macho.inspect_load_paths(path, {}))
        report = macho.scan_readable_paths(path)
        self.assertEqual(report["sha256"], hashlib.sha256(blob).hexdigest())
        self.assertEqual(report["size"], len(blob))
        self.assertEqual(report["matches"], [{"offset": len(prefix), "path": USER_PATH, "encoding": "utf-8"}])
        self.assert_raw_rejected(blob)

    def test_raw_scan_covers_fat_gap_and_file_trailer(self):
        for endian in ("<", ">"):
            for wide in (False, True):
                gap = b"\0" + USER_PATH.encode() + b"\0"
                blob = fat(thin(), thin(), endian=endian, wide=wide, gap=gap, trailer=gap)
                report = macho.scan_readable_paths_bytes(blob)
                self.assertEqual([item["offset"] for item in report["matches"]],
                                 [blob.index(USER_PATH.encode()), blob.rindex(USER_PATH.encode())])
                self.assert_raw_rejected(blob)

    def test_raw_scan_covers_second_architecture_and_all_thin_headers(self):
        for endian in ("<", ">"):
            for wide in (False, True):
                blob = fat(thin(), thin(endian=endian, wide=wide, trailer=USER_PATH.encode()))
                self.assertEqual(len(macho.scan_readable_paths_bytes(blob)["matches"]), 1)
                self.assert_raw_rejected(blob)

    def test_raw_scan_catches_all_private_roots_without_ci_exemption(self):
        for root in macho.PRIVATE_ROOTS:
            self.assert_raw_rejected(thin(trailer=(root + "example/source.c").encode()))
        self.assert_raw_rejected(thin(trailer=UPSTREAM_PATH.encode()))

    def test_raw_scan_catches_repeated_slashes_case_urls_and_compiler_operands(self):
        for value in ("///" + "Users/reviewprobe/build", "/" + "uSeRs/reviewprobe/build",
                      "file://localhost" + USER_PATH, "-isystem" + USER_PATH,
                      "~/build/private.c"):
            self.assert_raw_rejected(thin(trailer=value.encode()))

    def test_raw_scan_handles_utf8_and_both_ascii_utf16_orders(self):
        value = "/" + "Users/测试/source.rs"
        prefix = thin() + "字符:".encode()
        report = macho.scan_readable_paths_bytes(prefix + value.encode())
        self.assertEqual(report["matches"][0]["offset"], len(prefix))
        self.assertEqual(report["matches"][0]["path"], value)
        for encoding in ("utf-16-le", "utf-16-be"):
            prefix = thin() + b"\xff"
            blob = prefix + USER_PATH.encode(encoding) + b"\0\0"
            report = macho.scan_readable_paths_bytes(blob)
            self.assertIn({"offset": len(prefix), "path": USER_PATH, "encoding": encoding}, report["matches"])
            for item in report["matches"]:
                encoded = item["path"].encode(item["encoding"])
                self.assertEqual(blob[item["offset"]:item["offset"] + len(encoded)], encoded)
            self.assert_raw_rejected(blob)

    def test_scan_has_no_size_or_region_based_skip(self):
        prefix = thin() + b"\0" * (1024 * 1024 + 13)
        report = macho.scan_readable_paths_bytes(prefix + USER_PATH.encode())
        self.assertEqual(report["matches"][0]["offset"], len(prefix))

    def test_spaces_and_unicode_utf16_paths_cannot_use_prefix_approvals(self):
        for encoding in ("utf-8", "utf-16-le", "utf-16-be"):
            for value in (UPSTREAM_PATH + " private", UPSTREAM_PATH + "测试"):
                prefix = thin() + b"\xff"
                blob = prefix + value.encode(encoding) + b"\0\0"
                report = macho.scan_readable_paths_bytes(blob)
                self.assertIn({"offset": len(prefix), "path": value, "encoding": encoding}, report["matches"])
                self.assert_raw_rejected(blob, approval=(UPSTREAM_PATH,))

    def test_non_macho_returns_false_without_counter_mutation(self):
        counts = {"kept": 1}
        path = self.fixture(USER_PATH.encode())
        self.assertIsNone(macho.scan_readable_paths(path))
        self.assertIsNone(macho.scan_readable_paths_bytes(path.read_bytes()))
        self.assertFalse(macho.inspect_macho_paths(path, counts))
        self.assertEqual(counts, {"kept": 1})

    def test_malformed_macho_magic_does_not_skip_raw_strings(self):
        blob = b"\xcf\xfa\xed\xfe" + USER_PATH.encode()
        self.assertEqual(macho.scan_readable_paths_bytes(blob)["matches"][0]["path"], USER_PATH)
        self.assert_load_rejected(blob, "invalid-macho-load-commands")

    def test_public_system_and_relative_paths_are_not_private(self):
        blob = thin(trailer=b"/usr/lib/libSystem.B.dylib\0/System/Library/Foo\0"
                    b"@loader_path/foo\0/DLC/scipy/foo\0build/source.rs\0"
                    b"/UsersExtra/public\0/homeward/public\0https://example.org/source.c\0")
        self.assertEqual(macho.scan_readable_paths_bytes(blob)["matches"], [])
        counts = {}
        self.assertTrue(macho.inspect_macho_paths(self.fixture(blob), counts))
        self.assertEqual(counts["macho_build_path_files"], 1)

    def test_hash_bound_exact_paths_allow_only_reviewed_strings(self):
        blob = thin(trailer=UPSTREAM_PATH.encode() + b"\0" + UPSTREAM_PATH.encode())
        counts = {}
        allowed = hash_bound_approvals(blob, hashlib.sha256(blob).hexdigest(), UPSTREAM_PATH)
        self.assertTrue(macho.inspect_build_paths(self.fixture(blob), counts,
                                                 allowed=allowed))
        self.assertEqual(counts["macho_build_paths"], 2)
        self.assertEqual(counts["macho_approved_build_paths"], 2)

    def test_stale_hash_rejects_even_same_readable_paths(self):
        blob = thin(trailer=UPSTREAM_PATH.encode())
        changed = blob + b"\0"
        allowed = hash_bound_approvals(changed, hashlib.sha256(blob).hexdigest(), UPSTREAM_PATH)
        self.assertEqual(allowed, ())
        self.assert_raw_rejected(changed, approval=allowed)

    def test_exact_hash_with_unapproved_second_path_rejects(self):
        blob = thin(trailer=UPSTREAM_PATH.encode() + b"\0" + USER_PATH.encode())
        self.assert_raw_rejected(blob, approval=(UPSTREAM_PATH,))

    def test_path_prefix_approval_does_not_approve_a_longer_path(self):
        blob = thin(trailer=(UPSTREAM_PATH + "/secret").encode())
        self.assert_raw_rejected(blob, approval=(UPSTREAM_PATH,))

    def test_approvals_cannot_waive_private_load_or_hidden_command_payload(self):
        for blob in (thin(0xC, UPSTREAM_PATH), thin(macho.RPATH, after=UPSTREAM_PATH.encode())):
            counts = {"kept": 2}
            with self.assertRaisesRegex(macho.PrivacyError, "local-path-macho-load-command"):
                macho.inspect_macho_paths(self.fixture(blob), counts, allowed=(UPSTREAM_PATH,))
            self.assertEqual(counts, {"kept": 2})

    def test_invalid_approvals_fail_closed(self):
        blob = thin(trailer=UPSTREAM_PATH.encode())
        for approval in (None, {}, UPSTREAM_PATH, UPSTREAM_PATH.encode(), [7], [""],
                         ["*"], ["/public/path"], ["/tmp"], ["/tmp/"], ["~/"],
                         [UPSTREAM_PATH + "\0"], [b"\xff"]):
            with self.assertRaisesRegex(macho.PrivacyError, "invalid-macho-build-path-approval"):
                macho.inspect_build_paths(self.fixture(blob), {}, allowed=approval)

    def test_literal_pattern_characters_are_exact_not_wildcard_approvals(self):
        for suffix in ("/name[0]*?.c", "/file*.rs", "/a?.c", "/[file].c"):
            value = UPSTREAM_PATH + suffix
            blob = thin(trailer=value.encode())
            self.assertTrue(macho.inspect_build_paths(self.fixture(blob), {}, allowed=(value,)))
            other = thin(trailer=(UPSTREAM_PATH + "/file-private.rs").encode())
            self.assert_raw_rejected(other, approval=(value,))

    def test_short_and_binary_tilde_fragments_are_suppressed(self):
        for fragment in (b"~/", b"~/x", b"\xff~/xs\xfe", b"abc~/long", b"~+~.~ /~/~0~1~",
                         b"\r~/~0~1~\n"):
            blob = thin(trailer=fragment)
            self.assertEqual(macho.scan_readable_paths_bytes(blob)["matches"], [])

    def test_meaningful_tilde_operands_remain_reviewable(self):
        for value in ("~/.python_history", "~/xy", "~/build/private.c"):
            blob = thin(trailer=value.encode() + b"\0")
            self.assert_raw_rejected(blob)
            self.assertTrue(macho.inspect_build_paths(self.fixture(blob), {}, allowed=(value,)))

    def test_generic_roots_are_not_local_build_diagnostics(self):
        for root in macho.PRIVATE_ROOTS:
            blob = thin(trailer=root.rstrip("/").encode() + b"\0")
            self.assertEqual(macho.scan_readable_paths_bytes(blob)["matches"], [])

    def test_private_absolute_paths_remain_detected_inside_binary_runs(self):
        blob = thin(trailer=b"\xff\xff" + USER_PATH.encode() + b"\xfe\x01")
        self.assert_raw_rejected(blob)

    def test_tilde_operand_filter_does_not_weaken_load_commands(self):
        for value in ("~/", "~/x", "/tmp"):
            self.assert_load_rejected(thin(macho.RPATH, value))

    def test_exact_utf8_bytes_approval_is_supported(self):
        blob = thin(trailer=UPSTREAM_PATH.encode())
        self.assertTrue(macho.inspect_build_paths(self.fixture(blob), {}, allowed=(UPSTREAM_PATH.encode(),)))

    def test_nested_root_components_still_require_one_exact_full_path(self):
        value = UPSTREAM_PATH + "/home/example.c"
        blob = thin(trailer=value.encode())
        report = macho.scan_readable_paths_bytes(blob)
        self.assertEqual([item["path"] for item in report["matches"]], [value])
        self.assertTrue(macho.inspect_build_paths(self.fixture(blob), {}, allowed=(value,)))
        self.assert_raw_rejected(blob, approval=(UPSTREAM_PATH,))

    def test_build_gate_alone_cannot_waive_load_commands(self):
        for blob in (thin(0xC, UPSTREAM_PATH), thin(macho.RPATH, after=UPSTREAM_PATH.encode())):
            with self.assertRaisesRegex(macho.PrivacyError, "local-path-macho-load-command"):
                macho.inspect_build_paths(self.fixture(blob), {}, allowed=(UPSTREAM_PATH,))

    def test_combined_gate_is_atomic_on_raw_failure(self):
        counts = {"macho_files": 5}
        with self.assertRaisesRegex(macho.PrivacyError, "local-path-macho-build-string"):
            macho.inspect_macho_paths(self.fixture(thin(0xD, trailer=USER_PATH.encode())), counts)
        self.assertEqual(counts, {"macho_files": 5})

    def test_static_scan_does_not_launch_tools_or_change_file(self):
        path = self.fixture(thin(0x12, "Cocoa"))
        before = path.read_bytes()
        with patch.object(macho.subprocess, "run", side_effect=AssertionError("must stay static")):
            self.assertTrue(macho.inspect_macho_paths(path, {}))
        self.assertEqual(path.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
