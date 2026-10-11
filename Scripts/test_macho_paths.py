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


def combined_image(*paths):
    commands = b"".join(image(command, value)[32:] for command, value in paths)
    return struct.pack("<8I", 0xFEEDFACF, 0x100000C, 0, 6, len(paths), len(commands), 0, 0) + commands


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

    def test_dlc_identity_exception_does_not_allow_second_slice_dependency(self):
        first = image(macho.ID_DYLIB, "/DLC/scipy/.dylibs/libfoo.dylib")
        second = image(0xC, "/DLC/scipy/.dylibs/libfoo.dylib")
        offset = 48
        fat = struct.pack(">II", 0xCAFEBABE, 2)
        fat += struct.pack(">IIIII", 0x100000C, 0, offset, len(first), 0)
        fat += struct.pack(">IIIII", 0x1000007, 0, offset + len(first), len(second), 0)
        self.path.write_bytes(fat + first + second)
        with self.assertRaisesRegex(privacy.PrivacyError, "nonportable-macho-load-command"):
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

    def test_unused_private_rpath_is_removed(self):
        self.path.write_bytes(image(macho.RPATH, "/" + "Users/synthetic/lib"))
        def repair(command, **kwargs):
            self.assertEqual(command[1:3], ["-delete_rpath", "/" + "Users/synthetic/lib"])
            self.path.write_bytes(image())
            return type("Result", (), {"returncode": 0})()
        with patch.object(macho.subprocess, "run", side_effect=repair):
            change, = macho.make_portable(self.path, self.root)
        self.assertEqual(change["action"], "removed")
        self.assertIsNone(change["replacement"])

    def test_homebrew_and_other_non_system_absolute_loads_are_rejected(self):
        for command in [*macho.DEPENDENCIES, macho.RPATH, 0xE, 0xF]:
            for value in ["/opt/homebrew/Cellar/gcc@13/13.4.0/lib/gcc/13", "/usr/local/lib/libomp.dylib",
                          "/opt/local/lib/libomp.dylib", "/build/libfoo.dylib", "/DLC/scipy/.dylibs/libfoo.dylib",
                          "libfoo.dylib", "@loader_path_extra/libfoo.dylib",
                          "/usr/lib/../../opt/libfoo.dylib", "/System/Library/../../opt/libfoo.dylib"]:
                with self.subTest(command=command, value=value):
                    self.path.write_bytes(image(command, value))
                    with self.assertRaises(privacy.PrivacyError):
                        privacy.inspect_tree(self.root)

    def test_upstream_dlc_and_relative_install_ids_are_preserved(self):
        for value in ["/DLC/scipy/.dylibs/libfoo.dylib", "bazel-out/k8-opt/bin/python/lib_message_binary.so",
                      "libupstream.dylib"]:
            with self.subTest(value=value):
                self.path.write_bytes(image(macho.ID_DYLIB, value))
                before = self.path.read_bytes()
                self.assertEqual(privacy.inspect_tree(self.root)["macho_files"], 1)
                with patch.object(macho.subprocess, "run") as run:
                    self.assertEqual(macho.make_portable(self.path, self.root), [])
                    run.assert_not_called()
                self.assertEqual(before, self.path.read_bytes())

    def test_system_prefix_boundary_cannot_hide_external_path(self):
        for value in ["/usr/library/foo", "/System/LibraryExtra/foo", "/DLC/../build/libfoo.dylib"]:
            self.path.write_bytes(image(macho.ID_DYLIB, value))
            with self.assertRaises(privacy.PrivacyError):
                privacy.inspect_tree(self.root)

    def test_rpath_dependency_becomes_shipped_relative_before_homebrew_removal(self):
        library = self.root / "lib" / "libfoo.dylib"
        library.parent.mkdir()
        library.write_bytes(image())
        unsafe = "/opt/homebrew/Cellar/foo/1.0/lib"
        self.path.write_bytes(combined_image((0xC, "@rpath/libfoo.dylib"), (macho.RPATH, unsafe)))
        def repair(command, **kwargs):
            self.assertEqual(command[1:-1], ["-change", "@rpath/libfoo.dylib", "@loader_path/lib/libfoo.dylib",
                                            "-delete_rpath", unsafe])
            self.path.write_bytes(image(0xC, "@loader_path/lib/libfoo.dylib"))
            return type("Result", (), {"returncode": 0})()
        with patch.object(macho.subprocess, "run", side_effect=repair):
            self.assertEqual(len(macho.make_portable(self.path, self.root)), 2)

    def test_homebrew_rpath_repair_refuses_missing_or_ambiguous_rpath_import(self):
        for duplicate in [False, True]:
            if duplicate:
                for directory in ["a", "b"]:
                    (self.root / directory).mkdir()
                    (self.root / directory / "libfoo.dylib").write_bytes(image())
            self.path.write_bytes(combined_image((0xC, "@rpath/libfoo.dylib"),
                                                 (macho.RPATH, "/opt/homebrew/lib")))
            before = self.path.read_bytes()
            with patch.object(macho.subprocess, "run") as run:
                with self.assertRaisesRegex(privacy.PrivacyError, "unresolved-private-macho-dependency"):
                    macho.make_portable(self.path, self.root)
                run.assert_not_called()
            self.assertEqual(before, self.path.read_bytes())

    def test_non_system_absolute_dependency_is_repaired_to_unique_shipped_file(self):
        library = self.root / "libfoo.dylib"
        library.write_bytes(image())
        self.path.write_bytes(image(0xC, "/build/libfoo.dylib"))
        def repair(command, **kwargs):
            self.assertEqual(command[1:-1], ["-change", "/build/libfoo.dylib", "@loader_path/libfoo.dylib"])
            self.path.write_bytes(image(0xC, "@loader_path/libfoo.dylib"))
            return type("Result", (), {"returncode": 0})()
        with patch.object(macho.subprocess, "run", side_effect=repair):
            macho.make_portable(self.path, self.root)

    def test_repair_outside_prepared_root_is_refused(self):
        self.path.write_bytes(image(macho.RPATH, "/opt/homebrew/lib"))
        outside = self.root / "copy"
        outside.mkdir()
        with patch.object(macho.subprocess, "run") as run:
            with self.assertRaisesRegex(privacy.PrivacyError, "invalid-macho-repair-path"):
                macho.make_portable(self.path, outside)
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
