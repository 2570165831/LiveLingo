"""Descriptor-only checkpoint directory regressions; no runtime/model imports."""
import errno
import os
from pathlib import Path
import stat
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import checkpoints


@unittest.skipUnless(sys.platform == 'darwin', 'Darwin O_NOFOLLOW_ANY contract')
class CheckpointDirectoryTests(unittest.TestCase):
    def setUp(self):
        # Keep synthetic evidence in the invocation's temporary root.
        self.root = Path(tempfile.mkdtemp(prefix='checkpoint-directory-')).resolve()

    def test_existing_prefix_is_the_only_absolute_open(self):
        original = os.open
        calls = []

        def allowed(name, flags, *args, **kwargs):
            calls.append((str(name), flags, kwargs.get('dir_fd')))
            if kwargs.get('dir_fd') is None:
                self.assertEqual(Path(name), self.root)
                self.assertTrue(flags & 0x20000000)
            return original(name, flags, *args, **kwargs)

        with patch.object(checkpoints.os, 'open', side_effect=allowed):
            checkpoints.prepare_state_directory(self.root)
        self.assertEqual(len(calls), 1)

    def test_missing_tail_never_opens_or_stats_above_existing_prefix(self):
        target = self.root / 'new' / 'nested'
        original_open, original_stat = os.open, os.stat
        absolute = []
        relative = []

        def allowed(name, flags, *args, **kwargs):
            if kwargs.get('dir_fd') is None:
                path = Path(name)
                self.assertTrue(path == self.root or self.root in path.parents)
                self.assertTrue(flags & 0x20000000)
                absolute.append(path)
            else:
                self.assertIn(str(name), ('new', 'nested'))
                relative.append(str(name))
            return original_open(name, flags, *args, **kwargs)

        def allowed_stat(name, *args, **kwargs):
            if kwargs.get('dir_fd') is None:
                path = Path(name)
                self.assertTrue(path == self.root or self.root in path.parents)
            return original_stat(name, *args, **kwargs)

        with patch.object(checkpoints.os, 'open', side_effect=allowed), \
             patch.object(checkpoints.os, 'stat', side_effect=allowed_stat):
            checkpoints.prepare_state_directory(target)
        self.assertEqual(absolute, [target, target.parent, self.root])
        self.assertEqual(relative, ['new', 'new', 'nested', 'nested'])
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o700)

    def test_missing_read_only_open_does_not_fall_back_to_ancestors(self):
        target = self.root / 'missing'
        with patch.object(checkpoints.os, 'open', wraps=os.open) as opened:
            with self.assertRaises(FileNotFoundError):
                with checkpoints._state_fd(target, create=False):
                    pass
        self.assertEqual(opened.call_count, 1)
        self.assertEqual(Path(opened.call_args.args[0]), target)

    def test_access_denial_is_not_treated_as_a_missing_prefix(self):
        with patch.object(checkpoints.os, 'open', side_effect=PermissionError(errno.EPERM, 'denied')) as opened:
            with self.assertRaises(PermissionError):
                checkpoints.prepare_state_directory(self.root / 'missing')
        self.assertEqual(opened.call_count, 1)

    def test_symlinks_at_leaf_ancestor_and_missing_tail_are_rejected(self):
        target = self.root / 'real'
        target.mkdir()
        (target / 'existing').mkdir()
        link = self.root / 'link'
        link.symlink_to(target, target_is_directory=True)
        for path in (link, link / 'existing', link / 'missing' / 'nested'):
            with self.subTest(path=path.name), self.assertRaises(OSError):
                checkpoints.prepare_state_directory(path)
        self.assertEqual(sorted(p.name for p in target.iterdir()), ['existing'])

    def test_foreign_owner_is_rejected_without_changing_permissions(self):
        original = os.fstat

        def foreign(fd):
            info = original(fd)
            values = {name: getattr(info, name) for name in dir(info) if name.startswith('st_')}
            return SimpleNamespace(**(values | {'st_uid': os.getuid() + 1}))

        with patch.object(checkpoints.os, 'fstat', side_effect=foreign), \
             patch.object(checkpoints.os, 'fchmod') as chmod, \
             self.assertRaises(checkpoints.CheckpointSafetyError):
            checkpoints.prepare_state_directory(self.root)
        chmod.assert_not_called()

    def test_new_directory_replaced_before_open_is_not_tightened(self):
        foreign = self.root / 'foreign'
        foreign.mkdir(mode=0o755)
        original = os.open
        swapped = False

        def replacing(name, flags, *args, **kwargs):
            nonlocal swapped
            if name == 'created' and kwargs.get('dir_fd') is not None and not swapped:
                # The first attempt is absent; replacement follows mkdir/stat.
                if (self.root / 'created').exists():
                    swapped = True
                    (self.root / 'created').rename(self.root / 'claimed')
                    foreign.rename(self.root / 'created')
            return original(name, flags, *args, **kwargs)

        with patch.object(checkpoints.os, 'open', side_effect=replacing), \
             self.assertRaisesRegex(checkpoints.CheckpointSafetyError, 'changed'):
            checkpoints.prepare_state_directory(self.root / 'created')
        self.assertTrue(swapped)
        self.assertEqual(stat.S_IMODE((self.root / 'created').stat().st_mode), 0o755)

    def test_parent_traversal_and_root_are_rejected(self):
        for path in (self.root / 'missing' / '..' / 'state', Path('/')):
            with self.subTest(path=str(path)), self.assertRaises(checkpoints.CheckpointSafetyError):
                checkpoints.prepare_state_directory(path)


if __name__ == '__main__':
    unittest.main()
