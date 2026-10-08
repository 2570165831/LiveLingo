"""Offline P4/P5 regressions; all synthetic fixtures stay in the supplied TMPDIR."""
import errno
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import Mock, patch

if __package__:
    from . import test_data_safety as base
else:
    import test_data_safety as base


class OutputIdentityTests(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp(prefix=self._testMethodName + '-'))
        self.observations = {}
        self.addCleanup(self.archive)

    def archive(self):
        destination = self.directory.parent / 'p4-p5-preserved'
        destination.mkdir(exist_ok=True)
        self.directory.rename(destination / self.directory.name)

    def recovery(self):
        return base.source_module('Scripts/recover-orphan-recordings.py')

    recording = base.RecoveryDataSafetyTests.recording

    def bound_path(self, path, directory_fd=None):
        path = Path(path)
        if path.is_absolute() or directory_fd is None:
            return path
        state = os.fstat(directory_fd)
        for directory in (self.directory, *self.directory.rglob('*')):
            if directory.is_symlink() or not directory.is_dir():
                continue
            current = directory.stat()
            if (current.st_dev, current.st_ino) == (state.st_dev, state.st_ino):
                return directory / path
        raise AssertionError('The directory fd must belong to this synthetic fixture')

    def output_ancestor_swap(self, fallback):
        module = self.recovery()
        source = self.recording(module)
        before = source.read_bytes()
        layout = module.inspect(source)
        expected = module.header_bytes(layout.fmt_chunk, layout.usable) + before[layout.data_offset:]
        approved = self.directory / 'selected-output'
        approved.mkdir()
        preserved = self.directory / 'preserved-selected-output'
        redirected = self.directory / 'different-synthetic-output'
        redirected.mkdir()
        sentinel = redirected / 'foreign.txt'
        sentinel.write_bytes(b'foreign directory stays unchanged')
        target = approved / 'recovered.wav'
        real_path_open, real_fd_open = Path.open, module.os.open
        swapped = False

        def swap():
            nonlocal swapped
            approved.rename(preserved)
            approved.symlink_to(redirected, target_is_directory=True)
            swapped = True

        def raced_path_open(path, mode='r', *args, **kwargs):
            if mode == 'xb' and path.parent == approved and not swapped:
                swap()
            return real_path_open(path, mode, *args, **kwargs)

        def raced_fd_open(path, flags, *args, **kwargs):
            if flags & os.O_CREAT and str(path).endswith('.pending') and not swapped:
                swap()
            return real_fd_open(path, flags, *args, **kwargs)

        if fallback:
            module.os.link = Mock(side_effect=OSError(errno.ENOTSUP, 'synthetic hardlink unavailable'))
        module.os.open = raced_fd_open
        error = None
        with patch.object(Path, 'open', raced_path_open):
            try:
                module.export_recording(source, layout, target)
            except OSError as caught:
                error = caught
        self.observations.update(swapped=swapped, rejected=error is not None,
                                 redirected_final_exists=(redirected / target.name).exists(),
                                 source_unchanged=source.read_bytes() == before)
        self.assertTrue(swapped, 'The output creation race must actually fire')
        self.assertEqual(source.read_bytes(), before)
        self.assertEqual(sentinel.read_bytes(), b'foreign directory stays unchanged')
        self.assertIsNotNone(error, str(self.observations))
        self.assertEqual(list(redirected.iterdir()), [sentinel])
        incomplete = list(preserved.glob('recovered.wav.*.incomplete'))
        self.assertEqual(len(incomplete), 1)
        self.assertEqual(incomplete[0].read_bytes(), expected)

    def test_output_ancestor_swap_cannot_redirect_hardlink_success(self):
        self.output_ancestor_swap(False)

    def test_output_ancestor_swap_cannot_redirect_fallback_success(self):
        self.output_ancestor_swap(True)

    def test_fallback_pending_identity_swap_never_publishes_foreign_final(self):
        module = self.recovery()
        source = self.recording(module)
        before = source.read_bytes()
        layout = module.inspect(source)
        expected = module.header_bytes(layout.fmt_chunk, layout.usable) + before[layout.data_offset:]
        target = self.directory / 'pending-swap.wav'
        retained = self.directory / 'preserved-owned-pending.wav'
        foreign = b'synthetic unrelated bytes'
        real_rename = module.rename_no_replace
        swapped_paths = []
        module.os.link = Mock(side_effect=OSError(errno.ENOTSUP, 'synthetic hardlink unavailable'))

        def replaced_before_rename(pending, final, *args, **kwargs):
            original = self.bound_path(pending, kwargs.get('src_dir_fd'))
            if not swapped_paths:
                original.rename(retained)
                original.write_bytes(foreign)
                swapped_paths.append(original)
            return real_rename(pending, final, *args, **kwargs)

        module.rename_no_replace = replaced_before_rename
        with self.assertRaises(OSError):
            module.export_recording(source, layout, target)
        self.observations.update(swapped=bool(swapped_paths), final_exists=target.exists(),
                                 owned_complete_preserved=retained.read_bytes() == expected,
                                 source_unchanged=source.read_bytes() == before)
        self.assertTrue(swapped_paths, 'The pre-rename replacement must actually fire')
        self.assertEqual(retained.read_bytes(), expected)
        self.assertEqual(source.read_bytes(), before)
        self.assertFalse(target.exists(), str(self.observations))
        self.assertEqual(swapped_paths[0].read_bytes(), foreign, 'Do not delete the other writer\'s pending')

    def test_hardlink_pending_replacement_is_not_unconditionally_unlinked(self):
        module = self.recovery()
        source = self.recording(module)
        before = source.read_bytes()
        layout = module.inspect(source)
        expected = module.header_bytes(layout.fmt_chunk, layout.usable) + before[layout.data_offset:]
        target = self.directory / 'hardlink-pending-swap.wav'
        retained = self.directory / 'preserved-owned-pending.wav'
        foreign = b'synthetic competing pending'
        real_link = module.os.link
        replaced = []

        def replace_after_link(pending, final, **kwargs):
            real_link(pending, final, **kwargs)
            original = self.bound_path(pending, kwargs.get('src_dir_fd'))
            original.rename(retained)
            original.write_bytes(foreign)
            replaced.append(original)

        module.os.link = replace_after_link
        error = None
        try:
            module.export_recording(source, layout, target)
        except OSError as caught:
            error = caught
        self.observations.update(replaced=bool(replaced), rejected=error is not None,
                                 foreign_pending_exists=replaced[0].exists(),
                                 source_unchanged=source.read_bytes() == before)
        self.assertEqual(source.read_bytes(), before)
        self.assertEqual(retained.read_bytes(), expected)
        self.assertTrue(replaced[0].exists(), str(self.observations))
        self.assertEqual(replaced[0].read_bytes(), foreign)
        self.assertIsNotNone(error)
        self.assertFalse(target.exists())
        incomplete = list(self.directory.glob('hardlink-pending-swap.wav.*.incomplete'))
        self.assertEqual(len(incomplete), 1)
        self.assertEqual(incomplete[0].read_bytes(), expected)

    def test_output_swap_at_directory_sync_uses_bound_fd_and_preserves_owned_wav(self):
        module = self.recovery()
        source = self.recording(module)
        before = source.read_bytes()
        layout = module.inspect(source)
        expected = module.header_bytes(layout.fmt_chunk, layout.usable) + before[layout.data_offset:]
        approved = self.directory / 'selected-output'
        approved.mkdir()
        selected = approved.stat()
        preserved = self.directory / 'preserved-selected-output'
        redirected = self.directory / 'different-synthetic-output'
        redirected.mkdir()
        target = approved / 'recovered.wav'
        real_sync = module.os.fsync
        sync_identities = []

        def swap_at_sync(fd):
            state = os.fstat(fd)
            if stat.S_ISDIR(state.st_mode):
                sync_identities.append((state.st_dev, state.st_ino))
                approved.rename(preserved)
                approved.symlink_to(redirected, target_is_directory=True)
            return real_sync(fd)

        module.os.fsync = swap_at_sync
        with self.assertRaises(OSError):
            module.export_recording(source, layout, target)
        self.assertEqual(sync_identities, [(selected.st_dev, selected.st_ino)])
        self.assertEqual(source.read_bytes(), before)
        self.assertEqual(list(redirected.iterdir()), [])
        self.assertFalse((preserved / target.name).exists(), 'Own failed output must use its incomplete name')
        incomplete = list(preserved.glob('recovered.wav.*.incomplete'))
        self.assertEqual(len(incomplete), 1)
        self.assertEqual(incomplete[0].read_bytes(), expected)


if __name__ == '__main__':
    unittest.main(verbosity=2)
