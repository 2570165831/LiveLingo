"""Private, app-owned checkpoint files; no tensor or model imports."""
from contextlib import contextmanager
import ctypes
import errno
import os
from pathlib import Path
import re
import secrets
import stat
import sys

_IDENTITY = re.compile(r'[0-9a-f]{64}')
_RECORD = re.compile(r'[0-9a-f]{64}(?:\.(?:[0-9a-f]{32}\.)?pending)?\.safetensors')
_DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
_ACL_API = None


def _strip_extended_acl(fd):
    """Remove inherited macOS allow entries on the already validated descriptor."""
    if sys.platform != 'darwin':
        return
    global _ACL_API
    if _ACL_API is None:
        api = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
        signatures = {
            'acl_get_fd_np': ([ctypes.c_int, ctypes.c_int], ctypes.c_void_p),
            'acl_get_entry': ([ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)], ctypes.c_int),
            'acl_get_tag_type': ([ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)], ctypes.c_int),
            'acl_delete_entry': ([ctypes.c_void_p, ctypes.c_void_p], ctypes.c_int),
            'acl_set_fd_np': ([ctypes.c_int, ctypes.c_void_p, ctypes.c_int], ctypes.c_int),
            'acl_free': ([ctypes.c_void_p], ctypes.c_int),
        }
        for name, (arguments, result) in signatures.items():
            getattr(api, name).argtypes = arguments
            getattr(api, name).restype = result
        _ACL_API = api
    api = _ACL_API
    def read_acl():
        ctypes.set_errno(0)
        acl = api.acl_get_fd_np(fd, 0x100)  # ACL_TYPE_EXTENDED.
        if acl or ctypes.get_errno() == errno.ENOENT:
            return acl  # The validated fd exists; ENOENT means no ACL.
        raise OSError(ctypes.get_errno(), 'Private checkpoint ACL read failed')

    def first_allow(acl):
        selector = 0  # ACL_FIRST_ENTRY, then ACL_NEXT_ENTRY.
        while True:
            entry = ctypes.c_void_p()
            ctypes.set_errno(0)
            result = api.acl_get_entry(acl, selector, ctypes.byref(entry))
            if not entry.value and (result >= 0 or
                                    (result == -1 and ctypes.get_errno() == errno.EINVAL)):
                return None  # Both empty/end forms occur on Darwin.
            if result < 0 or not entry.value:
                raise OSError(ctypes.get_errno(), 'Private checkpoint ACL read failed')
            tag = ctypes.c_int()
            if api.acl_get_tag_type(entry, ctypes.byref(tag)) != 0:
                raise OSError(ctypes.get_errno(), 'Private checkpoint ACL read failed')
            if tag.value == 1:  # ACL_EXTENDED_ALLOW; leave DENY and all other entries.
                return entry
            selector = -1  # ACL_NEXT_ENTRY in the macOS SDK.

    acl = read_acl()
    if not acl:
        return
    changed = False
    try:
        while (entry := first_allow(acl)) is not None:
            if api.acl_delete_entry(acl, entry) != 0:
                raise OSError(ctypes.get_errno(), 'Private checkpoint ACL update failed')
            changed = True  # Restart enumeration after deleting an entry.
        if changed and api.acl_set_fd_np(fd, acl, 0x100) != 0:
            raise OSError(ctypes.get_errno(), 'Private checkpoint ACL update failed')
    finally:
        api.acl_free(acl)
    if changed:
        verified = read_acl()
        if verified:
            try:
                if first_allow(verified) is not None:
                    raise OSError('Private checkpoint ACL verification failed')
            finally:
                api.acl_free(verified)


class CheckpointSafetyError(ValueError):
    """A fixed classification, without paths or file contents."""


@contextmanager
def _state_fd(directory, create=True):
    """Traverse by descriptor so no directory component follows a symlink."""
    path = Path(os.path.abspath(directory))
    if path == Path(path.anchor):
        raise CheckpointSafetyError('Invalid checkpoint directory')
    fd = os.open(path.anchor, _DIRECTORY_FLAGS)
    try:
        for component in path.parts[1:]:
            if create:
                try:
                    os.mkdir(component, 0o700, dir_fd=fd)
                except FileExistsError:
                    pass
            child = os.open(component, _DIRECTORY_FLAGS, dir_fd=fd)
            os.close(fd)
            fd = child
        info = os.fstat(fd)
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
            raise CheckpointSafetyError('Invalid checkpoint directory owner or type')
        os.fchmod(fd, stat.S_IMODE(info.st_mode) & 0o700)
        _strip_extended_acl(fd)
        yield fd
    finally:
        os.close(fd)


def _record_info(fd, name):
    """Validate and restrict a regular, unshared file without following links."""
    try:
        info = os.stat(name, dir_fd=fd, follow_symlinks=False)
    except FileNotFoundError:
        return None
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
            or info.st_nlink != 1):
        raise CheckpointSafetyError('Invalid checkpoint file owner or type')
    leaf = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
    try:
        current = os.fstat(leaf)
        if ((current.st_dev, current.st_ino) != (info.st_dev, info.st_ino)
                or current.st_uid != os.getuid() or current.st_nlink != 1
                or not stat.S_ISREG(current.st_mode)):
            raise CheckpointSafetyError('Checkpoint file changed')
        mode = stat.S_IMODE(current.st_mode) & 0o600
        if stat.S_IMODE(current.st_mode) != mode:
            os.fchmod(leaf, mode)
        _strip_extended_acl(leaf)
        return os.fstat(leaf)
    finally:
        os.close(leaf)


def _remove_record(fd, name, expected=None):
    if expected is not None:
        try:
            info = os.stat(name, dir_fd=fd, follow_symlinks=False)
        except FileNotFoundError:
            return False
        if _token(info) != expected:
            return False
    if _record_info(fd, name) is not None:
        os.unlink(name, dir_fd=fd)
        return True
    return False


def prepare_state_directory(directory):
    """Repeatable migration: tighten records, preserving every unknown writer."""
    with _state_fd(directory) as fd:
        names = [name for name in os.listdir(fd) if _RECORD.fullmatch(name)]
        for name in names:
            _record_info(fd, name)


def _token(info):
    # Production saves replace the inode atomically. Timestamp changes used by
    # cache rotation do not transfer request ownership to somebody else.
    return (info.st_dev, info.st_ino)


def checkpoint_token(directory, identity):
    """Metadata ownership evidence captured only after this request writes."""
    if not isinstance(identity, str) or _IDENTITY.fullmatch(identity) is None:
        raise CheckpointSafetyError('Invalid checkpoint identity')
    with _state_fd(directory) as fd:
        info = _record_info(fd, identity + '.safetensors')
        return _token(info) if info is not None else None


def remove_checkpoint(directory, identity, expected=None):
    """Release a final record; historical partial writes have unknown owners."""
    if not isinstance(identity, str) or _IDENTITY.fullmatch(identity) is None:
        raise CheckpointSafetyError('Invalid checkpoint identity')
    with _state_fd(directory) as fd:
        if expected is not None:
            name = identity + '.safetensors'
            try:
                info = os.stat(name, dir_fd=fd, follow_symlinks=False)
            except FileNotFoundError:
                return False
            # A matching content key is not request ownership. A replaced or
            # modified record belongs to somebody else; leave its mode intact.
            if _token(info) != expected:
                return False
            _remove_record(fd, name)
            return True
        _remove_record(fd, identity + '.safetensors')


def checkpoint_records(directory):
    """Metadata for validated complete records, used by the worker's byte budget."""
    with _state_fd(directory) as fd:
        return [(Path(directory) / name, _record_info(fd, name)) for name in os.listdir(fd)
                if re.fullmatch(r'[0-9a-f]{64}\.safetensors', name)]


def atomic_checkpoint(path, write):
    """Keep the previous record on failure; never leave our partial write."""
    path = Path(os.path.abspath(path))
    if not path.name.endswith('.safetensors') or path.name.endswith('.pending.safetensors'):
        raise CheckpointSafetyError('Invalid checkpoint filename')
    pending = path.with_name(path.stem + '.' + secrets.token_hex(16) + '.pending.safetensors')
    with _state_fd(path.parent) as fd:
        _record_info(fd, path.name)
        leaf = os.open(pending.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                       0o600, dir_fd=fd)
        expected = _token(os.fstat(leaf))
        try:
            _strip_extended_acl(leaf)
        except BaseException:
            os.close(leaf)
            _remove_record(fd, pending.name, expected=expected)
            raise
        else:
            os.close(leaf)
        try:
            # Native tensor serializers require a filename. The directory is
            # private and the file is already created with mode 0600.
            write(str(pending))
            info = os.stat(pending.name, dir_fd=fd, follow_symlinks=False)
            if _token(info) != expected:
                raise CheckpointSafetyError('Checkpoint writer replaced the pending file')
            info = _record_info(fd, pending.name)
            if info is None or _token(info) != expected:
                raise CheckpointSafetyError('Checkpoint writer did not produce a file')
            _record_info(fd, path.name)
            os.replace(pending.name, path.name, src_dir_fd=fd, dst_dir_fd=fd)
            _record_info(fd, path.name)
        finally:
            _remove_record(fd, pending.name, expected=expected)


def load_checkpoint(path, read):
    """Validate legacy records before any serializer reads their header/tensors."""
    path = Path(os.path.abspath(path))
    with _state_fd(path.parent, create=False) as fd:
        if _record_info(fd, path.name) is None:
            raise FileNotFoundError('Checkpoint is missing')
        return read(str(path))
