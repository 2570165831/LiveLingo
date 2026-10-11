"""Native privacy gate regressions using bounded synthetic Mach-O files."""
import struct
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from Scripts import macho_paths as macho
from Scripts import privacy_package as privacy


def image(command=0xD, value="@rpath/libpython3.13.dylib", endian="<"):
    fixed = 24 if command in macho.DYLIB else 12
    text = value.encode() + b"\0"
    width = (fixed + len(text) + 7) // 8 * 8
    data = struct.pack(endian + "III", command, width, fixed) + b"\0" * (fixed - 12)
    data += text + b"\0" * (width - fixed - len(text))
    header = struct.pack(endian + "8I", 0xFEEDFACF, 0x100000C, 0, 6, 1, width, 0, 0)
    return header + data


class MachOPathTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.path = self.root / "libpython3.13.dylib"

    def tearDown(self):
        self.temporary.cleanup()

    def test_gate_rejects_home_paths_in_dylib_id_dependencies_and_rpath(self):
        for command in [0xD, 0xC, 0x80000018, 0x8000001F, macho.RPATH, 0xE, 0x27, 0x2D]:
            for value in ["/" + "Users/synthetic/libpython3.13.dylib", "/private/var/folders/synthetic/lib"]:
                with self.subTest(command=command, value=value):
                    self.path.write_bytes(image(command, value))
                    with self.assertRaisesRegex(privacy.PrivacyError, "local-path-macho-load-command"):
                        privacy.inspect_tree(self.root)

    def test_relative_and_system_paths_pass_in_both_byte_orders(self):
        for endian in ["<", ">"]:
            for value in ["@rpath/libpython3.13.dylib", "@loader_path/../lib/libpython3.13.dylib",
                          "/usr/lib/libSystem.B.dylib", "/System/Library/Frameworks/Foundation.framework/Foundation"]:
                self.path.write_bytes(image(0xC, value, endian))
                self.assertEqual(privacy.inspect_tree(self.root)["macho_files"], 1)

    def test_private_path_in_second_universal_slice_is_rejected(self):
        first = image()
        second = image(macho.RPATH, "/private/var/folders/synthetic/lib")
        offset = 48
        fat = struct.pack(">II", 0xCAFEBABE, 2)
        fat += struct.pack(">IIIII", 0x100000C, 0, offset, len(first), 0)
        fat += struct.pack(">IIIII", 0x1000007, 0, offset + len(first), len(second), 0)
        self.path.write_bytes(fat + first + second)
        with self.assertRaisesRegex(privacy.PrivacyError, "local-path-macho-load-command"):
            privacy.inspect_tree(self.root)

    def test_malformed_commands_fail_closed(self):
        good = image()
        for data in [good[:-1], good[:32] + struct.pack("<II", 0xD, 0) + good[40:],
                     good[:40] + struct.pack("<I", 99999) + good[44:]]:
            self.path.write_bytes(data)
            with self.assertRaisesRegex(privacy.PrivacyError, "invalid-macho-load-commands"):
                privacy.inspect_tree(self.root)

    def test_copy_repair_changes_id_without_signing_and_checks_result(self):
        self.path.write_bytes(image(0xD, "/" + "Users/synthetic/libpython3.13.dylib"))
        def repair(command, **kwargs):
            self.assertEqual(command[:3], ["/usr/bin/install_name_tool", "-id", "@rpath/libpython3.13.dylib"])
            self.path.write_bytes(image())
            return type("Result", (), {"returncode": 0})()
        with patch.object(macho.subprocess, "run", side_effect=repair):
            self.assertEqual(len(macho.make_portable(self.path, self.root)), 1)
        self.assertEqual(macho.load_paths(self.path), [(0xD, "@rpath/libpython3.13.dylib")])

    def test_unknown_private_dependency_is_not_guessed(self):
        self.path.write_bytes(image(0xC, "/" + "Users/synthetic/missing.dylib"))
        with self.assertRaisesRegex(privacy.PrivacyError, "unresolved-private-macho-dependency"):
            macho.make_portable(self.path, self.root)

    def test_private_rpath_is_relocated_to_the_shipped_lib_directory(self):
        (self.root / "lib").mkdir()
        self.path.write_bytes(image(macho.RPATH, "/" + "Users/synthetic/lib"))
        def repair(command, **kwargs):
            self.assertEqual(command[1:4], ["-rpath", "/" + "Users/synthetic/lib", "@loader_path/lib"])
            self.path.write_bytes(image(macho.RPATH, "@loader_path/lib"))
            return type("Result", (), {"returncode": 0})()
        with patch.object(macho.subprocess, "run", side_effect=repair):
            macho.make_portable(self.path, self.root)


if __name__ == "__main__":
    unittest.main()
