"""Synthetic syscall faults without adding any filesystem ACL entries."""
import ctypes
import errno
from pathlib import Path
import stat
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import checkpoints


class EmptyACL:
    """Real ACL allocation, with the ABI's nil/-1 and errno failure results."""
    def __init__(self, api, *, read_error=None, set_error=None):
        self.api = api
        self.read_error = read_error
        self.set_error = set_error
        self.read_calls = self.set_calls = 0

    def __getattr__(self, name):
        return getattr(self.api, name)

    def acl_get_fd_np(self, fd, acl_type):
        self.read_calls += 1
        if self.read_error is not None:
            ctypes.set_errno(self.read_error)
            return None
        return self.api.acl_init(0)

    def acl_set_fd_np(self, fd, acl, acl_type):
        self.set_calls += 1
        if self.set_error is not None:
            ctypes.set_errno(self.set_error)
            return -1
        return 0


@unittest.skipUnless(sys.platform == 'darwin', 'Darwin checkpoint syscall faults')
class CheckpointMetadataErrorsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='checkpoint-metadata-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.api = checkpoints._acl_api()

    def target(self, replacing, tag):
        directory = self.root / tag
        directory.mkdir(mode=0o700)
        path = directory / ('d' * 64 + '.safetensors')
        if replacing:
            path.write_bytes(b'previous synthetic checkpoint')
            path.chmod(0o600)
        return path

    @staticmethod
    def write(path):
        Path(path).write_bytes(b'new synthetic checkpoint')

    def assert_saved(self, path):
        self.assertEqual(path.read_bytes(), b'new synthetic checkpoint')
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(path.stat().st_nlink, 1)
        self.assertEqual(list(path.parent.glob('*.pending.safetensors')), [])

    def assert_previous(self, path, replacing, inode):
        if replacing:
            self.assertEqual(path.read_bytes(), b'previous synthetic checkpoint')
            self.assertEqual(path.stat().st_ino, inode)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        else:
            self.assertFalse(path.exists())
        self.assertEqual(list(path.parent.glob('*.pending.safetensors')), [])

    def test_already_private_fchmod_enotsup_or_eperm_saves_new_and_replacement(self):
        for replacing in (False, True):
            for code in (errno.ENOTSUP, errno.EPERM):
                with self.subTest(replacing=replacing, errno=code):
                    path = self.target(replacing, f'mode-{replacing}-{code}')
                    if not replacing:
                        path = path.parent / 'new' / 'nested' / path.name
                    acl = EmptyACL(self.api)
                    with patch.object(checkpoints, '_ACL_API', acl), \
                         patch.object(checkpoints.os, 'fchmod',
                                      side_effect=OSError(code, 'Synthetic fchmod failure')) as chmod:
                        checkpoints.atomic_checkpoint(path, self.write)
                    self.assertGreaterEqual(chmod.call_count, 2)
                    self.assert_saved(path)
                    self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)

    def test_acl_get_enotsup_saves_new_and_replacement(self):
        for replacing in (False, True):
            with self.subTest(replacing=replacing):
                path = self.target(replacing, f'read-{replacing}')
                acl = EmptyACL(self.api, read_error=errno.ENOTSUP)
                with patch.object(checkpoints, '_ACL_API', acl):
                    checkpoints.atomic_checkpoint(path, self.write)
                self.assertGreater(acl.read_calls, 0)
                self.assert_saved(path)

    def test_unix_modes_unavailable_saves_new_and_replacement(self):
        real_stat = checkpoints.os.fstat
        reported = []
        def synthetic_permissions(fd):
            info = real_stat(fd)
            if stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode):
                values = {name: getattr(info, name) for name in dir(info) if name.startswith('st_')}
                values['st_mode'] = stat.S_IFMT(info.st_mode) | 0o777
                reported.append(stat.S_IMODE(values['st_mode']))
                return SimpleNamespace(**values)
            return info
        for replacing in (False, True):
            with self.subTest(replacing=replacing):
                path = self.target(replacing, f'mode-less-{replacing}')
                if not replacing:
                    path = path.parent / 'new' / 'nested' / path.name
                acl = EmptyACL(self.api, read_error=errno.ENOTSUP, set_error=errno.ENOTSUP)
                with patch.object(checkpoints, '_ACL_API', acl), \
                     patch.object(checkpoints.os, 'fstat', side_effect=synthetic_permissions), \
                     patch.object(checkpoints.os, 'fchmod',
                                  side_effect=OSError(errno.ENOTSUP, 'Unix modes unavailable')) as chmod:
                    checkpoints.atomic_checkpoint(path, self.write)
                self.assertGreaterEqual(chmod.call_count, 2)
                self.assert_saved(path)
        self.assertTrue(reported)
        self.assertEqual(set(reported), {0o777})

    def test_empty_acl_set_enotsup_or_eperm_saves_replacement(self):
        for code in (errno.ENOTSUP, errno.EPERM):
            with self.subTest(errno=code):
                path = self.target(True, f'set-{code}')
                acl = EmptyACL(self.api, set_error=code)
                with patch.object(checkpoints, '_ACL_API', acl):
                    checkpoints.atomic_checkpoint(path, self.write)
                self.assertEqual(acl.set_calls, 1)
                self.assert_saved(path)

    def test_acl_set_failure_cannot_discard_existing_constraints(self):
        for code in (errno.ENOTSUP, errno.EPERM):
            with self.subTest(errno=code):
                path = self.target(True, f'constraints-{code}')
                inode = path.stat().st_ino
                acl = EmptyACL(self.api, set_error=code)
                with patch.object(checkpoints, '_ACL_API', acl), \
                     patch.object(checkpoints, '_acl_bytes', side_effect=[b'existing denial', b'']), \
                     self.assertRaises(OSError):
                    checkpoints.atomic_checkpoint(path, self.write)
                self.assertEqual(acl.set_calls, 1)
                self.assert_previous(path, True, inode)

    def test_failed_fchmod_does_not_accept_a_nonprivate_pending_inode(self):
        real_chmod = checkpoints.os.fchmod
        for replacing in (False, True):
            for code in (errno.ENOTSUP, errno.EPERM):
                with self.subTest(replacing=replacing, errno=code):
                    path = self.target(replacing, f'unsafe-mode-{replacing}-{code}')
                    inode = path.stat().st_ino if replacing else None
                    def widen_then_fail(fd, mode):
                        real_chmod(fd, 0o644)
                        raise OSError(code, 'Synthetic fchmod failure')
                    with patch.object(checkpoints.os, 'fchmod', side_effect=widen_then_fail), \
                         self.assertRaises(OSError) as caught:
                        checkpoints.atomic_checkpoint(path, self.write)
                    self.assertEqual(caught.exception.errno, code)
                    self.assert_previous(path, replacing, inode)

    def test_acl_get_eperm_does_not_guess_that_permissions_are_empty(self):
        for replacing in (False, True):
            with self.subTest(replacing=replacing):
                path = self.target(replacing, f'unreadable-acl-{replacing}')
                inode = path.stat().st_ino if replacing else None
                acl = EmptyACL(self.api, read_error=errno.EPERM)
                with patch.object(checkpoints, '_ACL_API', acl), \
                     self.assertRaises(OSError) as caught:
                    checkpoints.atomic_checkpoint(path, self.write)
                self.assertEqual(caught.exception.errno, errno.EPERM)
                self.assert_previous(path, replacing, inode)

    def test_replace_errors_preserve_previous_without_a_link_fallback(self):
        for replacing in (False, True):
            for code in (errno.ENOTSUP, errno.EPERM, errno.EXDEV):
                with self.subTest(replacing=replacing, errno=code):
                    path = self.target(replacing, f'forbidden-rename-{replacing}-{code}')
                    inode = path.stat().st_ino if replacing else None
                    with patch.object(checkpoints.os, 'replace',
                                      side_effect=OSError(code, 'Synthetic rename failure')) as rename, \
                         patch.object(checkpoints.os, 'link') as link, \
                         self.assertRaises(OSError) as caught:
                        checkpoints.atomic_checkpoint(path, self.write)
                    self.assertEqual(caught.exception.errno, code)
                    self.assertEqual(rename.call_count, 1)
                    self.assertEqual(rename.call_args.kwargs['src_dir_fd'],
                                     rename.call_args.kwargs['dst_dir_fd'])
                    link.assert_not_called()
                    self.assert_previous(path, replacing, inode)
