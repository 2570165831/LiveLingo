"""Synthetic recovery path/ACL regressions; no real recordings are inspected."""
import contextlib
import importlib
import io
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from test_recover_orphan_recordings import orphan_wav, pcm_bytes

recover = importlib.import_module("recover-orphan-recordings")


class RecoveryPrivatePathsTests(unittest.TestCase):
    def setUp(self):
        # Retain these small synthetic fixtures alongside the gate evidence.
        self.root = Path(tempfile.mkdtemp(prefix="recovery-private-paths-")).resolve()
        self.scan = self.root / "scan"
        session = self.scan / "LiveLingo-Live-SYNTHETIC"
        session.mkdir(parents=True)
        self.source = session / "recording.wav"
        self.original = orphan_wav(pcm_bytes(600))
        self.source.write_bytes(self.original)

    def run_main(self, *args):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = recover.main(list(args))
        self.assertEqual(self.source.read_bytes(), self.original)
        return code, stdout.getvalue(), stderr.getvalue()

    def export(self, output):
        return self.run_main("--root", str(self.scan), "--export", "--output", str(output))

    def acl(self, path):
        return subprocess.check_output(["/bin/ls", "-lde", str(path)], text=True)

    def inheritable_acl(self, path):
        subprocess.run(["/bin/chmod", "+a", "everyone allow read,write,execute,"
                        "readattr,readextattr,readsecurity,file_inherit,directory_inherit", str(path)],
                       check=True, capture_output=True)

    def test_output_symlink_ancestor_is_rejected_before_scan(self):
        foreign = self.root / "foreign"
        foreign.mkdir(mode=0o700)
        linked = self.root / "linked"
        linked.symlink_to(foreign, target_is_directory=True)
        with patch.object(recover, "candidates", wraps=recover.candidates) as scan:
            code, _, _ = self.export(linked / "export")
        self.assertEqual(code, 2)
        scan.assert_not_called()
        self.assertEqual(list(foreign.iterdir()), [])

    def test_input_symlink_ancestor_is_rejected_before_scan(self):
        linked = self.root / "linked"
        linked.symlink_to(self.root, target_is_directory=True)
        with patch.object(recover, "candidates", wraps=recover.candidates) as scan:
            code, _, _ = self.run_main("--root", str(linked / "scan"))
        self.assertEqual(code, 2)
        scan.assert_not_called()

    def test_dotdot_cannot_hide_a_symlink_ancestor(self):
        foreign = self.root / "foreign"
        foreign.mkdir(mode=0o700)
        (self.root / "linked").symlink_to(foreign, target_is_directory=True)
        code, _, _ = self.export(self.root / "linked" / ".." / "export")
        self.assertEqual(code, 2)
        self.assertFalse((self.root / "export").exists())

    def test_output_swap_before_export_cannot_redirect_pcm(self):
        output, displaced = self.root / "export", self.root / "displaced"
        foreign = self.root / "foreign"
        foreign.mkdir(mode=0o700)
        original_scan = recover.candidates

        def swap(roots):
            output.rename(displaced)
            output.symlink_to(foreign, target_is_directory=True)
            yield from original_scan(roots)

        with patch.object(recover, "candidates", side_effect=swap):
            code, _, _ = self.export(output)
        self.assertEqual(code, 1)
        self.assertEqual(list(foreign.iterdir()), [])

    def test_parent_swap_during_export_preserves_failure_in_bound_directory(self):
        output, displaced = self.root / "export", self.root / "displaced"
        foreign = self.root / "foreign"
        foreign.mkdir(mode=0o700)
        original_header = recover.header_bytes

        def swap(*args):
            output.rename(displaced)
            output.symlink_to(foreign, target_is_directory=True)
            return original_header(*args)

        with patch.object(recover, "header_bytes", side_effect=swap):
            code, _, _ = self.export(output)
        self.assertEqual(code, 1)
        self.assertEqual(list(foreign.iterdir()), [])
        self.assertEqual(len(list(displaced.glob("*.incomplete"))), 1)

    def test_higher_ancestor_swap_cannot_redirect_failure_preservation(self):
        parent = self.root / "parent"
        output = parent / "export"
        displaced, foreign = self.root / "displaced", self.root / "foreign"
        foreign.mkdir(mode=0o700)
        (foreign / "export").mkdir(mode=0o700)
        original_header = recover.header_bytes

        def swap(*args):
            parent.rename(displaced)
            parent.symlink_to(foreign, target_is_directory=True)
            return original_header(*args)

        with patch.object(recover, "header_bytes", side_effect=swap):
            code, _, _ = self.export(output)
        self.assertEqual(code, 1)
        self.assertEqual(list((foreign / "export").iterdir()), [])
        self.assertEqual(len(list((displaced / "export").glob("*.incomplete"))), 1)

    def test_root_swap_after_validation_is_rejected_before_inspection(self):
        displaced = self.root / "original-scan"
        foreign = self.root / "foreign-scan"
        session = foreign / "LiveLingo-Live-FOREIGN"
        session.mkdir(parents=True)
        (session / "recording.wav").write_bytes(orphan_wav(pcm_bytes(900)))
        original_scan = recover.candidates

        def swap(roots):
            self.scan.rename(displaced)
            self.scan.symlink_to(foreign, target_is_directory=True)
            yield from original_scan(roots)

        with patch.object(recover, "candidates", side_effect=swap), \
                patch.object(recover, "inspect") as inspect:
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = recover.main(["--root", str(self.scan)])
        self.assertEqual(code, 1)
        inspect.assert_not_called()
        self.assertEqual((displaced / self.source.parent.name / "recording.wav").read_bytes(), self.original)

    @unittest.skipUnless(sys.platform == "darwin", "macOS inherited ACL regression")
    def test_new_recovery_directories_and_pcm_remove_inherited_acl(self):
        self.inheritable_acl(self.root)
        output = self.root / "new-parent" / "export"
        code, _, stderr = self.export(output)
        self.assertEqual(code, 0, stderr)
        for path, mode in [(output.parent, 0o700), (output, 0o700),
                           (output / (self.source.parent.name + ".wav"), 0o600)]:
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), mode)
            self.assertNotIn("allow", self.acl(path))

    @unittest.skipUnless(sys.platform == "darwin", "macOS inherited ACL regression")
    def test_existing_allow_acl_directory_is_rejected_without_permission_changes(self):
        output = self.root / "export"
        output.mkdir(mode=0o700)
        self.inheritable_acl(output)
        before = self.acl(output)
        code, _, _ = self.export(output)
        self.assertEqual(code, 2)
        self.assertEqual(self.acl(output), before)
        self.assertEqual(list(output.iterdir()), [])

    @unittest.skipUnless(sys.platform == "darwin", "macOS inherited ACL regression")
    def test_direct_export_file_removes_inherited_acl(self):
        self.inheritable_acl(self.root)
        target = self.root / "direct.wav"
        recover.export_recording(self.source, recover.inspect(self.source), target)
        self.assertNotIn("allow", self.acl(target))


if __name__ == "__main__":
    unittest.main()
