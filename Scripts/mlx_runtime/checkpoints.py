"""Private new checkpoints, conserving existing permissions; no model imports."""
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


def _acl_api():
    global _ACL_API
    if _ACL_API is None:
        api = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
        signatures = {
            'acl_get_fd_np': ([ctypes.c_int, ctypes.c_int], ctypes.c_void_p),
            'acl_get_entry': ([ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)], ctypes.c_int),
            'acl_get_tag_type': ([ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)], ctypes.c_int),
            'acl_delete_entry': ([ctypes.c_void_p, ctypes.c_void_p], ctypes.c_int),
            'acl_set_fd_np': ([ctypes.c_int, ctypes.c_void_p, ctypes.c_int], ctypes.c_int),
            'acl_init': ([ctypes.c_int], ctypes.c_void_p),
            'acl_create_entry': ([ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_void_p)], ctypes.c_int),
            'acl_copy_entry': ([ctypes.c_void_p, ctypes.c_void_p], ctypes.c_int),
            'acl_to_text': ([ctypes.c_void_p, ctypes.POINTER(ctypes.c_ssize_t)], ctypes.c_void_p),
            'acl_free': ([ctypes.c_void_p], ctypes.c_int),
        }
        for name, (arguments, result) in signatures.items():
            getattr(api, name).argtypes = arguments
            getattr(api, name).restype = result
        _ACL_API = api
    return _ACL_API


def _read_extended_acl(fd):
    ctypes.set_errno(0)
    acl = _acl_api().acl_get_fd_np(fd, 0x100)  # ACL_TYPE_EXTENDED.
    if acl or ctypes.get_errno() == errno.ENOENT:
        return acl  # The validated fd exists; ENOENT means no ACL.
    raise OSError(ctypes.get_errno(), 'Private checkpoint ACL read failed')


def _acl_bytes(acl):
    """Compare full Darwin ACLs, including flags and entry order."""
    api = _acl_api()
    length = ctypes.c_ssize_t()
    data = api.acl_to_text(acl, ctypes.byref(length))
    if not data:
        raise OSError(ctypes.get_errno(), 'Checkpoint ACL verification failed')
    try:
        return ctypes.string_at(data, length.value)
    finally:
        api.acl_free(data)


def _acl_entries(acl):
    api = _acl_api()
    selector = 0
    while True:
        entry = ctypes.c_void_p()
        ctypes.set_errno(0)
        result = api.acl_get_entry(acl, selector, ctypes.byref(entry))
        if not entry.value and (result >= 0 or
                                (result == -1 and ctypes.get_errno() == errno.EINVAL)):
            return
        if result < 0 or not entry.value:
            raise OSError(ctypes.get_errno(), 'Private checkpoint ACL read failed')
        yield entry
        selector = -1


def _acl_entry_bytes(entry):
    api = _acl_api()
    acl = ctypes.c_void_p(api.acl_init(1))
    if not acl.value:
        raise OSError(ctypes.get_errno(), 'Checkpoint ACL copy failed')
    try:
        copied = ctypes.c_void_p()
        if (api.acl_create_entry(ctypes.byref(acl), ctypes.byref(copied)) != 0 or
                api.acl_copy_entry(copied, entry) != 0):
            raise OSError(ctypes.get_errno(), 'Checkpoint ACL copy failed')
        return _acl_bytes(acl)
    finally:
        api.acl_free(acl)


def _merge_new_denials(acl, destination):
    """Keep new inherited denies alongside the unchanged legacy ACL sequence."""
    api = _acl_api()
    inherited = _read_extended_acl(destination)
    if not inherited:
        return
    try:
        known = {_acl_entry_bytes(entry) for entry in _acl_entries(acl)}
        for entry in _acl_entries(inherited):
            tag = ctypes.c_int()
            if api.acl_get_tag_type(entry, ctypes.byref(tag)) != 0:
                raise OSError(ctypes.get_errno(), 'Private checkpoint ACL read failed')
            if tag.value != 2:  # ACL_EXTENDED_DENY.
                continue
            key = _acl_entry_bytes(entry)
            if key not in known:
                copied = ctypes.c_void_p()
                if (api.acl_create_entry(ctypes.byref(acl), ctypes.byref(copied)) != 0 or
                        api.acl_copy_entry(copied, entry) != 0):
                    raise OSError(ctypes.get_errno(), 'Checkpoint ACL copy failed')
                known.add(key)
    finally:
        api.acl_free(inherited)


def _strip_extended_acl(fd):
    """Remove allow entries only from a newly created, validated app inode."""
    if sys.platform != 'darwin':
        return
    api = _acl_api()

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

    acl = _read_extended_acl(fd)
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
        verified = _read_extended_acl(fd)
        if verified:
            try:
                if first_allow(verified) is not None:
                    raise OSError('Private checkpoint ACL verification failed')
            finally:
                api.acl_free(verified)


def _copy_permissions(source, destination):
    """Copy constraints to our new inode without changing the existing one."""
    info = os.fstat(source)
    mode = stat.S_IMODE(info.st_mode)
    api = _acl_api() if sys.platform == 'darwin' else None
    acl = ctypes.c_void_p()
    try:
        if api:
            acl.value = _read_extended_acl(source) or api.acl_init(0)
            if not acl.value:
                raise OSError(ctypes.get_errno(), 'Checkpoint ACL copy failed')
            _merge_new_denials(acl, destination)
            expected_acl = _acl_bytes(acl)
        current = os.fstat(destination)
        if (current.st_uid, current.st_gid) != (info.st_uid, info.st_gid):
            os.fchown(destination, info.st_uid, info.st_gid)
        os.fchmod(destination, mode)
        if api:
            if api.acl_set_fd_np(destination, acl, 0x100) != 0:
                raise OSError(ctypes.get_errno(), 'Checkpoint ACL copy failed')
            verified = _read_extended_acl(destination) or api.acl_init(0)
            if not verified:
                raise OSError(ctypes.get_errno(), 'Checkpoint ACL verification failed')
            try:
                if _acl_bytes(verified) != expected_acl:
                    raise OSError('Checkpoint ACL verification failed')
            finally:
                api.acl_free(verified)
        current = os.fstat(destination)
        if (stat.S_IMODE(current.st_mode), current.st_uid, current.st_gid) != (
                mode, info.st_uid, info.st_gid):
            raise OSError('Checkpoint permission verification failed')
        # ACL/mode changes update ctime. Refuse a changing permission snapshot.
        if os.fstat(source).st_ctime_ns != info.st_ctime_ns:
            raise CheckpointSafetyError('Checkpoint file changed')
        return info
    finally:
        if acl.value:
            api.acl_free(acl)


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
            created = None
            if create:
                try:
                    os.mkdir(component, 0o700, dir_fd=fd)
                    created = os.stat(component, dir_fd=fd, follow_symlinks=False)
                except FileExistsError:
                    pass
            child = os.open(component, _DIRECTORY_FLAGS, dir_fd=fd)
            os.close(fd)
            fd = child
            if created is not None:
                info = os.fstat(fd)
                if _token(info) != _token(created):
                    raise CheckpointSafetyError('Checkpoint directory changed')
                if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
                    raise CheckpointSafetyError('Invalid checkpoint directory owner or type')
                os.fchmod(fd, 0o700)
                _strip_extended_acl(fd)
        info = os.fstat(fd)
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
            raise CheckpointSafetyError('Invalid checkpoint directory owner or type')
        yield fd
    finally:
        os.close(fd)


@contextmanager
def _record_fd(fd, name, writable=False):
    """Validate by descriptor; a write open checks the kernel without truncating."""
    try:
        info = os.stat(name, dir_fd=fd, follow_symlinks=False)
    except FileNotFoundError:
        yield None
        return
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
            or info.st_nlink != 1):
        raise CheckpointSafetyError('Invalid checkpoint file owner or type')
    access = os.O_WRONLY if writable else os.O_RDONLY
    leaf = os.open(name, access | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
    try:
        current = os.fstat(leaf)
        if ((current.st_dev, current.st_ino) != (info.st_dev, info.st_ino)
                or current.st_uid != os.getuid() or current.st_nlink != 1
                or not stat.S_ISREG(current.st_mode)):
            raise CheckpointSafetyError('Checkpoint file changed')
        yield leaf
    finally:
        os.close(leaf)


def _record_info(fd, name, writable=False):
    """Read metadata without changing any existing mode or ACL."""
    with _record_fd(fd, name, writable=writable) as leaf:
        return os.fstat(leaf) if leaf is not None else None


def _remove_record(fd, name, expected=None):
    if expected is not None:
        try:
            info = os.stat(name, dir_fd=fd, follow_symlinks=False)
        except FileNotFoundError:
            return False
        if _token(info) != expected:
            return False
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_nlink != 1):
            raise CheckpointSafetyError('Invalid checkpoint file owner or type')
        # Our pending inode may already have restrictive copied permissions.
        # Unlink needs directory access, not a read open on that inode.
        os.unlink(name, dir_fd=fd)
        return True
    if _record_info(fd, name) is not None:
        os.unlink(name, dir_fd=fd)
        return True
    return False


def prepare_state_directory(directory):
    """Create private directories and validate existing records without migration."""
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
    try:
        with _state_fd(directory, create=False) as fd:
            info = _record_info(fd, identity + '.safetensors')
            return _token(info) if info is not None else None
    except FileNotFoundError:
        return None


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
    try:
        with _state_fd(directory, create=False) as fd:
            return [(Path(directory) / name, _record_info(fd, name)) for name in os.listdir(fd)
                    if re.fullmatch(r'[0-9a-f]{64}\.safetensors', name)]
    except FileNotFoundError:
        return []


def atomic_checkpoint(path, write):
    """Keep the previous record on failure; never leave our partial write."""
    path = Path(os.path.abspath(path))
    if not path.name.endswith('.safetensors') or path.name.endswith('.pending.safetensors'):
        raise CheckpointSafetyError('Invalid checkpoint filename')
    pending = path.with_name(path.stem + '.' + secrets.token_hex(16) + '.pending.safetensors')
    with _state_fd(path.parent) as fd:
        previous = _record_info(fd, path.name, writable=True)
        leaf = os.open(pending.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                       0o600, dir_fd=fd)
        expected = _token(os.fstat(leaf))
        try:
            os.fchmod(leaf, 0o600)
            _strip_extended_acl(leaf)
            # Native tensor serializers require a filename. The directory is
            # descriptor-validated; our pending inode starts at mode 0600.
            write(str(pending))
            info = os.stat(pending.name, dir_fd=fd, follow_symlinks=False)
            if _token(info) != expected:
                raise CheckpointSafetyError('Checkpoint writer replaced the pending file')
            info = _record_info(fd, pending.name)
            if info is None or _token(info) != expected:
                raise CheckpointSafetyError('Checkpoint writer did not produce a file')
            os.fchmod(leaf, 0o600)
            _strip_extended_acl(leaf)
            # Re-open after serialization so a newly denied write is respected.
            with _record_fd(fd, path.name, writable=True) as target:
                current = os.fstat(target) if target is not None else None
                if ((current is None) != (previous is None) or
                        (current is not None and _token(current) != _token(previous))):
                    raise CheckpointSafetyError('Checkpoint file changed')
                if target is not None:
                    copied = _copy_permissions(target, leaf)
                    checked = _record_info(fd, path.name, writable=True)
                    if (checked is None or _token(checked) != _token(copied)
                            or checked.st_ctime_ns != copied.st_ctime_ns):
                        raise CheckpointSafetyError('Checkpoint file changed')
                os.replace(pending.name, path.name, src_dir_fd=fd, dst_dir_fd=fd)
        finally:
            try:
                os.close(leaf)
            finally:
                _remove_record(fd, pending.name, expected=expected)


def load_checkpoint(path, read):
    """Validate records without permission changes before a serializer reads."""
    path = Path(os.path.abspath(path))
    with _state_fd(path.parent, create=False) as fd:
        if _record_info(fd, path.name) is None:
            raise FileNotFoundError('Checkpoint is missing')
        return read(str(path))
