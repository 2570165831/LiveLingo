"""Private *new* artifacts and descriptor-bound, non-symlink directories.

Existing objects are checked, never chmodded or stripped of their ACLs. macOS
ACL operations use the opened descriptor before any sensitive bytes are written.
"""
from __future__ import annotations

import ctypes
import errno
import os
from pathlib import Path
import stat
import sys


def absolute_path(path: str | Path) -> Path:
    value = Path(path).expanduser()
    # Do not normalize a symlink/../ component away before inspecting ancestors.
    if ".." in value.parts:
        raise ValueError("parent traversal is not allowed")
    return value.absolute()


def _acl_library():
    library = ctypes.CDLL(None, use_errno=True)
    library.acl_init.argtypes = [ctypes.c_int]
    library.acl_init.restype = ctypes.c_void_p
    library.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
    library.acl_get_fd_np.restype = ctypes.c_void_p
    library.acl_set_fd.argtypes = [ctypes.c_int, ctypes.c_void_p]
    library.acl_valid.argtypes = [ctypes.c_void_p]
    library.acl_get_entry.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)]
    library.acl_get_tag_type.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)]
    library.acl_free.argtypes = [ctypes.c_void_p]
    return library


def _acl_error() -> OSError:
    return OSError(ctypes.get_errno(), "private artifact ACL operation failed")


def require_private_acl(descriptor: int) -> None:
    """Reject any allow ACE on existing macOS objects, preserving deny ACEs."""
    if sys.platform != "darwin":
        # Other POSIX platforms may have an access or default ACL. Do not claim
        # those objects are private when such an ACL has not been inspected.
        for key in ("system.posix_acl_access", "system.posix_acl_default"):
            try:
                os.getxattr(descriptor, key)
            except OSError as error:
                if error.errno not in (errno.ENODATA, errno.ENOTSUP):
                    raise
            else:
                raise PermissionError("unverified extended ACL")
        return
    library = _acl_library()
    acl = library.acl_get_fd_np(descriptor, 0x100)
    if not acl:
        if ctypes.get_errno() == errno.ENOENT:
            return  # macOS represents an absent extended ACL with ENOENT.
        raise _acl_error()
    try:
        if library.acl_valid(acl) != 0:
            raise _acl_error()
        entry, tag = ctypes.c_void_p(), ctypes.c_int()
        entry_id = 0  # ACL_FIRST_ENTRY
        while True:
            result = library.acl_get_entry(acl, entry_id, ctypes.byref(entry))
            # Darwin's documented end-of-list result is -1/EINVAL, unlike
            # POSIX implementations which return 0/1 for iteration.
            if result == -1 and ctypes.get_errno() == errno.EINVAL:
                break
            if result != 0 or library.acl_get_tag_type(entry, ctypes.byref(tag)) != 0:
                raise _acl_error()
            if tag.value != 2:  # ACL_EXTENDED_DENY; unknown entries also fail closed.
                raise PermissionError("directory has an allowing or unknown ACL")
            entry_id = -1  # ACL_NEXT_ENTRY
    finally:
        library.acl_free(acl)


def privatize_new(descriptor: int, mode: int) -> None:
    """Use only immediately after exclusive creation; never for an old inode."""
    if sys.platform == "darwin":
        library = _acl_library()
        empty = library.acl_init(0)
        if not empty:
            raise _acl_error()
        try:
            if library.acl_set_fd(descriptor, empty) != 0:
                raise _acl_error()
        finally:
            library.acl_free(empty)
    else:
        for key in ("system.posix_acl_access", "system.posix_acl_default"):
            try:
                os.removexattr(descriptor, key)
            except OSError as error:
                if error.errno not in (errno.ENODATA, errno.ENOTSUP):
                    raise
    os.fchmod(descriptor, mode)
    require_private_acl(descriptor)
    state = os.fstat(descriptor)
    if state.st_uid != os.getuid() or stat.S_IMODE(state.st_mode) != mode:
        raise PermissionError("private artifact owner or mode is invalid")


class BoundDirectory:
    def __init__(self, path: Path, descriptors: list[tuple[Path, int]]):
        self.path = path
        self._descriptors = descriptors
        self.fd = descriptors[-1][1]

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def close(self):
        for _, descriptor in reversed(self._descriptors):
            os.close(descriptor)
        self._descriptors.clear()

    def require_bound(self):
        """Detect ancestor replacement; actual I/O still uses the held fd."""
        for path, descriptor in self._descriptors:
            current, opened = path.lstat(), os.fstat(descriptor)
            if (not stat.S_ISDIR(current.st_mode)
                    or (current.st_dev, current.st_ino) != (opened.st_dev, opened.st_ino)):
                raise OSError("directory path was replaced")

    def create_file(self, name: str, flags: int = os.O_WRONLY) -> int:
        if Path(name).name != name or name in ("", ".", ".."):
            raise ValueError("output requires a single filename")
        self.require_bound()
        descriptor = os.open(name, flags | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             0o600, dir_fd=self.fd)
        try:
            privatize_new(descriptor, 0o600)
            return descriptor
        except BaseException:
            os.close(descriptor)
            # Keep the empty failed artifact for diagnosis; never write content.
            raise


def open_directory(path: str | Path, *, create: bool = False,
                   private: bool = False, exclusive: bool = False) -> BoundDirectory:
    destination = absolute_path(path)
    descriptors = []
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    try:
        root = Path(destination.anchor)
        descriptor = os.open(root, flags)
        descriptors.append((root, descriptor))
        if exclusive and len(destination.parts) == 1:
            raise FileExistsError("directory already exists")
        for index, name in enumerate(destination.parts[1:], start=1):
            parent = descriptor
            created = False
            if exclusive and index == len(destination.parts) - 1:
                os.mkdir(name, 0o700, dir_fd=parent)
                created = True
                claimed = os.stat(name, dir_fd=parent, follow_symlinks=False)
            try:
                descriptor = os.open(name, flags, dir_fd=parent)
            except FileNotFoundError:
                if not create or created:
                    raise
                os.mkdir(name, 0o700, dir_fd=parent)
                created = True
                claimed = os.stat(name, dir_fd=parent, follow_symlinks=False)
                descriptor = os.open(name, flags, dir_fd=parent)
            root = root / name
            descriptors.append((root, descriptor))
            if created:
                opened = os.fstat(descriptor)
                if ((opened.st_dev, opened.st_ino) != (claimed.st_dev, claimed.st_ino)
                        or opened.st_uid != os.getuid()):
                    raise PermissionError("new directory was replaced before binding")
                privatize_new(descriptor, 0o700)
        bound = BoundDirectory(destination, descriptors)
        bound.require_bound()
        if private:
            state = os.fstat(bound.fd)
            if state.st_uid != os.getuid() or stat.S_IMODE(state.st_mode) != 0o700:
                raise PermissionError("existing private directory must be owned and mode 0700")
            require_private_acl(bound.fd)
        return bound
    except BaseException:
        for _, descriptor in reversed(descriptors):
            os.close(descriptor)
        raise


def prepare_private_directory(path: str | Path) -> BoundDirectory:
    return open_directory(path, create=True, private=True)


def validate_ancestors(path: str | Path) -> Path:
    """Allow a missing leaf/tree, but reject symlinks in every existing prefix."""
    destination = absolute_path(path)
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    descriptor = os.open(destination.anchor, flags)
    try:
        for name in destination.parts[1:]:
            try:
                child = os.open(name, flags, dir_fd=descriptor)
            except FileNotFoundError:
                break
            os.close(descriptor)
            descriptor = child
    finally:
        os.close(descriptor)
    return destination


def make_private_directory(path: str | Path, *, exclusive: bool = False) -> None:
    with open_directory(path, create=True, private=True, exclusive=exclusive):
        pass


def create_private_file(path: str | Path, flags: int = os.O_WRONLY) -> int:
    destination = absolute_path(path)
    # Existing parents can be public; a new file has its own mode/ACL checked.
    with open_directory(destination.parent, create=True) as directory:
        return directory.create_file(destination.name, flags)
