#!/usr/bin/env python3
"""Private legacy-installer files and an authenticated loopback-only client.

Stdlib only. Never chmod an existing file/directory. Token values stay in memory
and private plist bodies; CLI arguments contain paths, never credentials.
Packaging/install.command embeds this exact source for the historical layout.
"""
import argparse
from contextlib import contextmanager
import ctypes
import errno
import http.client
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import stat
import sys
from urllib.parse import urlencode
import uuid

ACL_TYPE = 0x100
ACL_ALLOW = 1
_ACL_API = None
MAX_PLIST_BYTES = 1024 * 1024
MAX_AUDIO_BYTES = 16 * 1024 * 1024


def _acl_api():
    global _ACL_API
    if _ACL_API is None:
        api = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
        signatures = {
            "acl_get_fd_np": ([ctypes.c_int, ctypes.c_int], ctypes.c_void_p),
            "acl_get_entry": ([ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)], ctypes.c_int),
            "acl_get_tag_type": ([ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)], ctypes.c_int),
            "acl_delete_entry": ([ctypes.c_void_p, ctypes.c_void_p], ctypes.c_int),
            "acl_create_entry": ([ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_void_p)], ctypes.c_int),
            "acl_copy_entry": ([ctypes.c_void_p, ctypes.c_void_p], ctypes.c_int),
            "acl_init": ([ctypes.c_int], ctypes.c_void_p),
            "acl_set_fd_np": ([ctypes.c_int, ctypes.c_void_p, ctypes.c_int], ctypes.c_int),
            "acl_to_text": ([ctypes.c_void_p, ctypes.POINTER(ctypes.c_ssize_t)], ctypes.c_void_p),
            "acl_free": ([ctypes.c_void_p], ctypes.c_int),
            "renameatx_np": ([ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint], ctypes.c_int),
        }
        for name, (arguments, result) in signatures.items():
            getattr(api, name).argtypes = arguments
            getattr(api, name).restype = result
        _ACL_API = api
    return _ACL_API


def _read_acl(fd):
    ctypes.set_errno(0)
    value = _acl_api().acl_get_fd_np(fd, ACL_TYPE)
    if value or ctypes.get_errno() == errno.ENOENT:
        return value
    raise OSError("Private installer ACL read failed")


def _entries(value):
    selector = 0
    while value:
        entry = ctypes.c_void_p()
        ctypes.set_errno(0)
        result = _acl_api().acl_get_entry(value, selector, ctypes.byref(entry))
        if not entry.value and (result >= 0 or (result == -1 and ctypes.get_errno() == errno.EINVAL)):
            return
        if result < 0 or not entry.value:
            raise OSError("Private installer ACL enumeration failed")
        tag = ctypes.c_int()
        if _acl_api().acl_get_tag_type(entry, ctypes.byref(tag)) != 0:
            raise OSError("Private installer ACL tag read failed")
        yield entry, tag.value
        selector = -1  # ACL_NEXT_ENTRY on macOS.


def _acl_state(fd):
    if sys.platform != "darwin":
        raise OSError("Private installer requires macOS ACL verification")
    value = _read_acl(fd)
    if not value:
        return False, b""
    api = _acl_api()
    try:
        has_allow = any(tag == ACL_ALLOW for _, tag in _entries(value))
        size = ctypes.c_ssize_t()
        text = api.acl_to_text(value, ctypes.byref(size))
        if not text:
            raise OSError("Private installer ACL snapshot failed")
        try:
            return has_allow, ctypes.string_at(text, size.value)
        finally:
            api.acl_free(text)
    finally:
        api.acl_free(value)


def _owned_regular(fd):
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
        raise OSError("Private installer rejected file owner, type or hard link")
    return info


def _verify_private(fd, mode):
    info = _owned_regular(fd)
    if stat.S_IMODE(info.st_mode) != mode or _acl_state(fd)[0]:
        raise OSError("Private installer permission verification failed")


def make_new_file_private(fd, existing_fd=None):
    """Only a newly O_EXCL-created inode may be passed here, before body writes."""
    _owned_regular(fd)
    os.fchmod(fd, 0o600)
    api = _acl_api()
    value = ctypes.c_void_p(_read_acl(fd) or api.acl_init(0))
    if not value.value:
        raise OSError("Private installer ACL allocation failed")
    try:
        while True:
            entry = next((entry for entry, tag in _entries(value) if tag == ACL_ALLOW), None)
            if entry is None:
                break
            if api.acl_delete_entry(value, entry) != 0:
                raise OSError("Private installer ALLOW ACL removal failed")
        if existing_fd is not None:
            previous = _read_acl(existing_fd)
            try:
                for entry, tag in _entries(previous):
                    if tag == ACL_ALLOW:
                        raise OSError("Private installer rejected existing ALLOW ACL")
                    copied = ctypes.c_void_p()
                    if api.acl_create_entry(ctypes.byref(value), ctypes.byref(copied)) != 0:
                        raise OSError("Private installer ACL preservation failed")
                    if api.acl_copy_entry(copied, entry) != 0:
                        raise OSError("Private installer ACL preservation failed")
            finally:
                if previous:
                    api.acl_free(previous)
        if api.acl_set_fd_np(fd, value, ACL_TYPE) != 0:
            raise OSError("Private installer ACL update failed")
    finally:
        api.acl_free(value)
    _verify_private(fd, 0o600)


@contextmanager
def _directory(path):
    path = Path(path).absolute()
    if ".." in path.parts:
        raise OSError("Private installer rejected parent traversal")
    fd = os.open(path.anchor, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for component in path.parts[1:]:
            next_fd = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        if os.fstat(fd).st_uid != os.getuid():
            raise OSError("Private installer rejected directory owner")
        yield fd
    finally:
        os.close(fd)


def _existing(parent, name, writable=False, private=False):
    try:
        info = os.stat(name, dir_fd=parent, follow_symlinks=False)
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
        raise OSError("Private installer rejected existing owner, type or link")
    mode = stat.S_IMODE(info.st_mode)
    if writable and mode != 0o600:
        raise OSError("Private installer will not change existing permission constraints")
    if private and (mode & ~0o600 or not mode & 0o400):
        raise OSError("Private installer rejected nonprivate credential file")
    fd = os.open(name, (os.O_RDWR if writable else os.O_RDONLY) | os.O_NOFOLLOW | os.O_NONBLOCK,
                 dir_fd=parent)
    try:
        opened = _owned_regular(fd)
        fields = ("st_dev", "st_ino", "st_mode", "st_uid", "st_gid", "st_nlink", "st_ctime_ns", "st_flags")
        if any(getattr(opened, field, 0) != getattr(info, field, 0) for field in fields):
            raise OSError("Private installer detected existing target change")
        if (writable or private) and _acl_state(fd)[0]:
            raise OSError("Private installer will not change existing ALLOW ACLs")
        return fd
    except BaseException:
        os.close(fd)
        raise


def _snapshot(fd):
    info = _owned_regular(fd)
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid, info.st_nlink,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns, getattr(info, "st_flags", 0), _acl_state(fd)[1])


def _read_bytes(fd):
    if _owned_regular(fd).st_size > MAX_PLIST_BYTES:
        raise OSError("Private installer credential file is too large")
    os.lseek(fd, 0, os.SEEK_SET)
    data = bytearray()
    while chunk := os.read(fd, min(65536, MAX_PLIST_BYTES + 1 - len(data))):
        data.extend(chunk)
        if len(data) > MAX_PLIST_BYTES:
            raise OSError("Private installer credential file is too large")
    return bytes(data)


def _new_file(parent, prefix, payload, existing_fd=None):
    for _ in range(8):
        name = prefix + "-" + uuid.uuid4().hex + ".plist"
        try:
            fd = os.open(name, os.O_CREAT | os.O_EXCL | os.O_RDWR | os.O_NOFOLLOW, 0o600, dir_fd=parent)
            break
        except FileExistsError:
            continue
    else:
        raise OSError("Private installer could not reserve an exclusive name")
    try:
        # Any ACL failure leaves an empty inode, never an unprotected token body.
        make_new_file_private(fd, existing_fd)
        offset = 0
        while offset < len(payload):
            count = os.write(fd, payload[offset:])
            if count <= 0:
                raise OSError("Private installer short write")
            offset += count
        os.fsync(fd)
        _verify_private(fd, 0o600)
        return name, fd
    except BaseException:
        # Owned private/empty pending evidence is retained, never bulk-deleted.
        os.close(fd)
        raise


def _retain_bytes(payload, directory, prefix):
    with _directory(directory) as parent:
        name, fd = _new_file(parent, prefix, payload)
        os.close(fd)
        return Path(directory) / name


def retain_private_copy(source, directory, prefix="old-asr-plist"):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", prefix):
        raise ValueError("Invalid private copy prefix")
    source = Path(source)
    with _directory(source.parent) as parent:
        fd = _existing(parent, source.name)
        if fd is None:
            raise FileNotFoundError("Private installer copy source is missing")
        try:
            before = _snapshot(fd)
            payload = _read_bytes(fd)
            if _snapshot(fd) != before:
                raise OSError("Private installer copy source changed")
            return _retain_bytes(payload, directory, prefix)
        finally:
            os.close(fd)


def check_target(path):
    path = Path(path)
    try:
        with _directory(path.parent) as parent:
            fd = _existing(parent, path.name, writable=True)
            if fd is not None:
                os.close(fd)
    except FileNotFoundError:
        # Existing path components were checked; the installer creates the rest.
        return


def write_private_bytes(path, payload, backup_directory=None, retained_directory=None):
    path = Path(path)
    result = {"target": path, "backup": None, "generated": None}
    with _directory(path.parent) as parent:
        previous = _existing(parent, path.name, writable=True)
        pending_fd = None
        try:
            before = _snapshot(previous) if previous is not None else None
            if previous is not None and backup_directory is not None:
                result["backup"] = _retain_bytes(_read_bytes(previous), backup_directory, "old-asr-plist")
            name, pending_fd = _new_file(parent, ".livelingo-asr-pending", payload, previous)
            if retained_directory is not None:
                result["generated"] = _retain_bytes(payload, retained_directory, "generated-asr-plist")
            if previous is not None:
                now = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
                if (now.st_dev, now.st_ino) != before[:2] or _snapshot(previous) != before:
                    raise OSError("Private installer target changed before commit")
            else:
                try:
                    os.stat(path.name, dir_fd=parent, follow_symlinks=False)
                except FileNotFoundError:
                    pass
                else:
                    raise OSError("Private installer target appeared before commit")
            if previous is None:
                # RENAME_EXCL (sys/stdio.h) refuses a target appearing after the last check.
                if _acl_api().renameatx_np(parent, os.fsencode(name), parent, os.fsencode(path.name), 0x4) != 0:
                    raise OSError(ctypes.get_errno(), "Private installer exclusive commit failed")
            else:
                os.replace(name, path.name, src_dir_fd=parent, dst_dir_fd=parent)
            installed = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
            if (installed.st_dev, installed.st_ino) != (os.fstat(pending_fd).st_dev, os.fstat(pending_fd).st_ino):
                raise OSError("Private installer final inode verification failed")
            _verify_private(pending_fd, 0o600)
        finally:
            if previous is not None:
                os.close(previous)
            if pending_fd is not None:
                os.close(pending_fd)
    return result


def install_launchagent(path, program_arguments, logs_directory, models_directory=None,
                        backup_directory=None, retained_directory=None):
    environment = {"LIVELINGO_ASR_TOKEN": secrets.token_hex(32)}
    if models_directory is not None:
        environment["LIVELINGO_ASR_MODELS"] = str(models_directory)
    body = {"Label": "com.jianhongli.LiveLingoASR", "ProgramArguments": program_arguments,
            "EnvironmentVariables": environment, "RunAtLoad": True, "KeepAlive": True,
            "ThrottleInterval": 5, "ProcessType": "Interactive",
            "StandardOutPath": str(Path(logs_directory) / "asr.log"),
            "StandardErrorPath": str(Path(logs_directory) / "asr-error.log")}
    return write_private_bytes(path, plistlib.dumps(body), backup_directory, retained_directory)


def read_token_file(path):
    path = Path(path)
    with _directory(path.parent) as parent:
        fd = _existing(parent, path.name, private=True)
        if fd is None:
            raise FileNotFoundError("Private installer token file is missing")
        try:
            before = _snapshot(fd)
            payload = _read_bytes(fd)
            if _snapshot(fd) != before:
                raise OSError("Private installer token file changed")
        finally:
            os.close(fd)
    token = plistlib.loads(payload).get("EnvironmentVariables", {}).get("LIVELINGO_ASR_TOKEN")
    if not isinstance(token, str) or not re.fullmatch(r"[A-Za-z0-9_-]{32,256}", token):
        raise ValueError("Private installer token file is invalid")
    return token


def request_from_token_file(path, audio=None, model="0.6b", language="English",
                            connection_factory=http.client.HTTPConnection):
    token = read_token_file(path)
    if model not in {"0.6b", "1.7b"} or language not in {"English", "auto"}:
        raise ValueError("Unsupported client model or language")
    if audio is not None and not 0 < len(audio) <= MAX_AUDIO_BYTES:
        raise ValueError("Client audio body is empty or too large")
    route = "/health" if audio is None else "/transcribe?" + urlencode({"model": model, "language": language})
    # Numeric loopback avoids DNS, proxies and shared stores. No redirect handling.
    connection = connection_factory("127.0.0.1", 18765, timeout=2 if audio is None else 120)
    try:
        connection.request("GET" if audio is None else "POST", route, body=audio,
                           headers={"X-LiveLingo-Token": token, "Content-Type": "audio/wav"})
        response = connection.getresponse()
        if response.status != 200:
            raise OSError("Authenticated ASR client request failed")
        data = response.read(MAX_PLIST_BYTES + 1)
        if len(data) > MAX_PLIST_BYTES:
            raise ValueError("Authenticated ASR response is too large")
        result = json.loads(data)
        if not isinstance(result, dict) or (audio is None and (result.get("ok") is not True or result.get("auth") is not True)):
            raise ValueError("Authenticated ASR response is invalid")
        if isinstance(result.get("text"), str):
            result["text"] = result["text"].replace(token, "<redacted>")
        return result
    finally:
        connection.close()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    check = commands.add_parser("check-target")
    check.add_argument("--plist", required=True, type=Path)
    install = commands.add_parser("install")
    install.add_argument("--plist", required=True, type=Path)
    install.add_argument("--logs-dir", required=True, type=Path)
    install.add_argument("--backup-dir", required=True, type=Path)
    install.add_argument("--retain-generated", action="store_true")
    install.add_argument("--models-dir", type=Path)
    runner = install.add_mutually_exclusive_group(required=True)
    runner.add_argument("--runner")
    runner.add_argument("--python")
    install.add_argument("--service-script")
    export = commands.add_parser("export-helper")
    source = export.add_mutually_exclusive_group(required=True)
    source.add_argument("--source", type=Path)
    source.add_argument("--installer", type=Path)
    export.add_argument("--output", required=True, type=Path)
    for command in ("health", "client"):
        client = commands.add_parser(command)
        client.add_argument("--token-file", required=True, type=Path,
                            help="private installed LaunchAgent plist; the token is never an argument")
        if command == "client":
            client.add_argument("--audio-file", required=True, type=Path)
            client.add_argument("--model", choices=("0.6b", "1.7b"), default="0.6b")
            client.add_argument("--language", choices=("English", "auto"), default="English")
    arguments = parser.parse_args(argv)
    if arguments.command == "check-target":
        check_target(arguments.plist)
    elif arguments.command == "install":
        program = [arguments.runner] if arguments.runner else [arguments.python, arguments.service_script]
        if not all(program):
            raise ValueError("Python service script is required")
        program += ["--host", "127.0.0.1", "--port", "18765"]
        install_launchagent(arguments.plist, program, arguments.logs_dir, arguments.models_dir,
                            arguments.backup_dir, arguments.backup_dir if arguments.retain_generated else None)
    elif arguments.command == "export-helper":
        if arguments.source:
            payload = arguments.source.read_bytes()
        else:
            text = arguments.installer.read_text()
            payload = (text.split("<<'LIVELINGO_PRIVATE_INSTALL_HELPER'\n", 1)[1]
                       .split("\nLIVELINGO_PRIVATE_INSTALL_HELPER\n", 1)[0] + "\n").encode()
        write_private_bytes(arguments.output, payload)
    elif arguments.command == "health":
        request_from_token_file(arguments.token_file)
    else:
        with arguments.audio_file.open("rb") as stream:
            audio = stream.read(MAX_AUDIO_BYTES + 1)
        result = request_from_token_file(arguments.token_file, audio, arguments.model, arguments.language)
        # Only transcription text is emitted; even an echoing server cannot print the token.
        text = result.get("text")
        if not isinstance(text, str):
            raise ValueError("Authenticated ASR transcription is invalid")
        print(json.dumps({"text": text}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, TypeError, KeyError, IndexError, AttributeError, http.client.HTTPException):
        print("Private installer/client operation failed.", file=sys.stderr)
        sys.exit(1)
