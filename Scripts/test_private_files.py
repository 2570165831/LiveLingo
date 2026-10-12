"""P1 syscall/race regressions; synthetic fixtures are retained, never deleted."""
from contextlib import contextmanager
import errno
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch

from Scripts import private_files as private, privacy_package
from Scripts.target_eval import corpora, recompute_es_zh_length as length


class PrivateFilesTests(unittest.TestCase):
    def setUp(self):
        scratch = Path(__file__).absolute().parents[2] / "work/sbx2/tool-prefix-fixtures"
        scratch.mkdir(exist_ok=True)
        self.root = Path(tempfile.mkdtemp(prefix=self._testMethodName + "-", dir=scratch))

    @contextmanager
    def granted_prefix_only(self, prefix):
        """Reject explicit ancestor syscalls, including realpath's lstat walk."""
        original_open, original_stat, original_lstat = os.open, os.stat, os.lstat
        calls = []
        def guard(path, dir_fd=None):
            if isinstance(path, int):
                return
            candidate = Path(path)
            if dir_fd is None and candidate.is_absolute():
                self.assertNotIn(candidate, prefix.parents, "explicit syscall above granted prefix")
        def opened(path, flags, *args, **kwargs):
            guard(path, kwargs.get("dir_fd"))
            if kwargs.get("dir_fd") is None and Path(path).is_absolute():
                self.assertTrue(flags & 0x20000000, "Darwin lookup must reject every symlink")
                self.assertFalse(flags & os.O_NOFOLLOW, "Darwin ANY and NOFOLLOW cannot be combined")
            elif flags & os.O_DIRECTORY:
                self.assertTrue(flags & os.O_NOFOLLOW)
                self.assertFalse(flags & 0x20000000)
            calls.append((Path(path), flags, kwargs.get("dir_fd")))
            return original_open(path, flags, *args, **kwargs)
        def stated(path, *args, **kwargs):
            guard(path, kwargs.get("dir_fd"))
            return original_stat(path, *args, **kwargs)
        def lstated(path, *args, **kwargs):
            guard(path, kwargs.get("dir_fd"))
            return original_lstat(path, *args, **kwargs)
        with patch.object(os, "open", opened), patch.object(os, "stat", stated), \
                patch.object(os, "lstat", lstated):
            yield calls

    @unittest.skipUnless(sys.platform == "darwin", "Darwin O_NOFOLLOW_ANY")
    def test_existing_directory_never_opens_or_stats_above_grant(self):
        with self.granted_prefix_only(self.root) as calls:
            with private.open_directory(self.root) as bound:
                bound.require_bound()
                fd = bound.create_file("body.json")
                os.close(fd)
        self.assertTrue(calls)

    @unittest.skipUnless(sys.platform == "darwin", "Darwin O_NOFOLLOW_ANY")
    def test_missing_tree_binds_deepest_prefix_then_creates_relative(self):
        destination = self.root / "new" / "deep"
        with self.granted_prefix_only(self.root) as calls:
            with private.open_directory(destination, create=True, private=True) as bound:
                self.assertEqual(stat.S_IMODE(os.fstat(bound.fd).st_mode), 0o700)
        self.assertTrue(any(path == self.root and dir_fd is None for path, _, dir_fd in calls))
        self.assertTrue(any(path == Path("new") and dir_fd is not None for path, _, dir_fd in calls))

    @unittest.skipUnless(sys.platform == "darwin", "Darwin O_NOFOLLOW_ANY")
    def test_validate_ancestors_never_probes_above_deepest_prefix(self):
        with self.granted_prefix_only(self.root):
            self.assertEqual(private.validate_ancestors(self.root / "missing/deep"), self.root / "missing/deep")

    @unittest.skipUnless(sys.platform == "darwin", "Darwin O_NOFOLLOW_ANY")
    def test_packaging_never_stats_or_opens_above_source_or_destination_grant(self):
        source = self.root / "source"
        source.mkdir()
        (source / "LICENSE").write_text("Synthetic public license\n")
        with self.granted_prefix_only(self.root):
            privacy_package.copy_distribution_tree(source, self.root / "delivery")
        self.assertEqual((self.root / "delivery/LICENSE").read_text(), "Synthetic public license\n")

    @unittest.skipUnless(sys.platform == "darwin", "Darwin O_NOFOLLOW_ANY")
    def test_length_report_never_probes_above_output_grant(self):
        with self.granted_prefix_only(self.root):
            length.write_report({"synthetic": True}, self.root / "report.json", self.root)
        self.assertEqual(stat.S_IMODE((self.root / "report.json").stat().st_mode), 0o600)

    @unittest.skipUnless(sys.platform == "darwin", "Darwin O_NOFOLLOW_ANY")
    def test_corpora_validation_never_probes_above_output_grant(self):
        with patch.dict(os.environ, {corpora.OUTPUT_ROOT_ENV: str(self.root)}), \
                self.granted_prefix_only(self.root):
            corpora.write_json({"synthetic": True}, self.root / "new/report.json")

    @unittest.skipUnless(sys.platform == "darwin", "Darwin O_NOFOLLOW_ANY")
    def test_scoreboard_writable_never_probes_above_work_grant(self):
        spec = importlib.util.spec_from_file_location("Scripts.prefix_scoreboard", Path(__file__).with_name("livelingo-scoreboard.py"))
        scoreboard = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(scoreboard)
        with patch.object(scoreboard, "WORK", self.root), self.granted_prefix_only(self.root):
            scoreboard.write_json(self.root / "new/report.json", {"synthetic": True})

    def test_symlink_in_existing_prefix_or_before_missing_suffix_is_rejected(self):
        target = self.root / "target"
        target.mkdir()
        link = self.root / "link"
        link.symlink_to(target, target_is_directory=True)
        for path in (link, link / "missing/deep"):
            with self.subTest(path=path.name):
                with self.assertRaises(OSError):
                    private.open_directory(path, create=True)
                with self.assertRaises(OSError):
                    private.validate_ancestors(path)
        self.assertEqual(list(target.iterdir()), [])

    def test_bound_existing_prefix_replacement_rejected_before_file_creation(self):
        approved = self.root / "approved"
        approved.mkdir()
        with private.open_directory(approved) as bound:
            approved.rename(self.root / "preserved")
            approved.mkdir()
            with self.assertRaises(OSError):
                bound.create_file("body")
        self.assertEqual(list(approved.iterdir()), [])

    def test_existing_objects_are_not_repaired_and_exclusive_creation_is_preserved(self):
        original = self.root.stat()
        with self.assertRaises(FileExistsError):
            private.open_directory(self.root, create=True, exclusive=True)
        public = self.root / "public"
        public.mkdir(mode=0o755)
        with self.assertRaises(PermissionError):
            private.open_directory(public, private=True)
        self.assertEqual(stat.S_IMODE(public.stat().st_mode), 0o755)
        self.assertEqual(self.root.stat().st_ino, original.st_ino)

    def test_non_enoent_failure_never_retries_parent(self):
        original_open = os.open
        calls = []
        def denied(path, flags, *args, **kwargs):
            calls.append(Path(path))
            if Path(path) == self.root:
                raise PermissionError(errno.EACCES, "synthetic denied")
            return original_open(path, flags, *args, **kwargs)
        with patch.object(os, "open", denied), self.assertRaises(PermissionError):
            private.open_directory(self.root, create=True)
        if sys.platform == "darwin":
            self.assertEqual(calls, [self.root])

    def test_parent_traversal_is_rejected_before_open(self):
        with patch.object(os, "open") as opened, self.assertRaises(ValueError):
            private.open_directory(self.root / ".." / "escape", create=True)
        opened.assert_not_called()

    def test_portable_implementation_retains_ancestor_symlink_checks(self):
        target = self.root / "portable-target"
        target.mkdir()
        link = self.root / "portable-link"
        link.symlink_to(target, target_is_directory=True)
        original_open = os.open
        calls = []
        def portable_open(path, flags, *args, **kwargs):
            self.assertTrue(flags & os.O_NOFOLLOW)
            self.assertFalse(flags & 0x20000000)
            calls.append(Path(path))
            return original_open(path, flags, *args, **kwargs)
        with patch.object(private.sys, "platform", "linux"), patch.object(os, "open", portable_open):
            with private.open_directory(target) as bound:
                bound.require_bound()
            for operation in (private.open_directory, private.validate_ancestors):
                with self.assertRaises(OSError):
                    operation(link / "missing")
        self.assertIn(Path("/"), calls)
        self.assertEqual(list(target.iterdir()), [])

    @unittest.skipUnless(sys.platform == "darwin", "Darwin system aliases")
    def test_system_alias_requires_root_owned_exact_target(self):
        for alias in ("/var", "/tmp", "/etc"):
            root_link = os.stat_result((stat.S_IFLNK | 0o755, 1, 1, 1, 0, 0, 0, 0, 0, 0))
            expected = "/private" + alias
            for target in (expected, expected[1:]):
                with patch.object(Path, "lstat", return_value=root_link) as inspected, \
                        patch.object(os, "readlink", return_value=target):
                    self.assertEqual(private.absolute_path(alias + "/synthetic"), Path(expected + "/synthetic"))
                inspected.assert_called_once_with()
            unowned = os.stat_result((stat.S_IFLNK | 0o755, 1, 1, 1, os.getuid(), 0, 0, 0, 0, 0))
            for state, target in ((unowned, expected), (root_link, "/synthetic/elsewhere"),
                                  (root_link, expected + "/../elsewhere")):
                with patch.object(Path, "lstat", return_value=state), \
                        patch.object(os, "readlink", return_value=target), \
                        patch.object(os, "open") as opened, self.assertRaises(PermissionError):
                    private.open_directory(alias + "/synthetic", create=True)
                opened.assert_not_called()

    def test_new_directory_identity_drift_is_rejected_before_privatizing(self):
        original_open = os.open
        replacement = self.root / "replacement"
        replacement.mkdir(mode=0o755)
        destination = self.root / "new"
        swapped = []
        def replace_before_binding(path, flags, *args, **kwargs):
            if Path(path) == Path("new") and kwargs.get("dir_fd") is not None and destination.exists():
                destination.rename(self.root / "retained-new")
                replacement.rename(destination)
                swapped.append(True)
            return original_open(path, flags, *args, **kwargs)
        with patch.object(os, "open", replace_before_binding), \
                patch.object(private, "privatize_new", wraps=private.privatize_new) as privatize, \
                self.assertRaises(PermissionError):
            private.open_directory(destination, create=True)
        self.assertTrue(swapped)
        privatize.assert_not_called()
        self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o755)

    def test_packaging_parent_swap_after_validation_cannot_redirect_copy(self):
        source = self.root / "source"
        source.mkdir()
        (source / "LICENSE").write_text("Synthetic public license\n")
        approved = self.root / "approved"
        approved.mkdir()
        redirected = self.root / "redirected"
        redirected.mkdir()
        original_inspect = privacy_package.inspect_tree
        swapped = []
        def swap_after_inspection(path, **kwargs):
            counts = original_inspect(path, **kwargs)
            if Path(path) == source and not swapped:
                approved.rename(self.root / "retained-approved")
                approved.symlink_to(redirected, target_is_directory=True)
                swapped.append(True)
            return counts
        with patch.object(privacy_package, "inspect_tree", swap_after_inspection), \
                self.assertRaises((privacy_package.PrivacyError, OSError)):
            privacy_package.copy_distribution_tree(source, approved / "delivery")
        self.assertTrue(swapped)
        self.assertEqual(list(redirected.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
