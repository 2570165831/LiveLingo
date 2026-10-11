"""Read native load-command strings without executing code or trusting otool text."""
import os
from pathlib import Path
import struct
import subprocess

try:
    from .privacy_package import PrivacyError
except ImportError:
    from privacy_package import PrivacyError


THIN = {b"\xce\xfa\xed\xfe": ("<", 28), b"\xfe\xed\xfa\xce": (">", 28),
        b"\xcf\xfa\xed\xfe": ("<", 32), b"\xfe\xed\xfa\xcf": (">", 32)}
FAT = {b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
       b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True)}
DYLIB = {0xC, 0xD, 0x80000018, 0x8000001F, 0x20, 0x80000023}
RPATH = 0x8000001C
STRINGS = DYLIB | {RPATH, 0xE, 0xF, 0x12, 0x13, 0x14, 0x15, 0x27, 0x80000035}
PRIVATE_ROOTS = ("/" + "Users/", "/home/", "/Volumes/", "/private/var/", "/private/tmp/",
                 "/var/folders/", "/synthetic/")


def load_paths(path):
    """Return (command, string) for every architecture; fail on malformed headers."""
    path = Path(path)
    size = path.stat().st_size
    with path.open("rb") as stream:
        def read(offset, length):
            if offset < 0 or offset + length > size:
                raise PrivacyError("invalid-macho-load-commands")
            stream.seek(offset)
            data = stream.read(length)
            if len(data) != length:
                raise PrivacyError("invalid-macho-load-commands")
            return data

        magic = read(0, min(size, 4))
        if magic not in THIN and magic not in FAT:
            return None
        slices = [(0, size)]
        if magic in FAT:
            endian, wide = FAT[magic]
            count = struct.unpack(endian + "I", read(4, 4))[0]
            if not 1 <= count <= 64:
                raise PrivacyError("invalid-macho-load-commands")
            width = 32 if wide else 20
            table_end = 8 + count * width
            slices = []
            for index in range(count):
                entry = read(8 + index * width, width)
                offset, length = struct.unpack_from(endian + ("QQ" if wide else "II"), entry, 8)
                if offset < table_end or length < 28 or offset + length > size:
                    raise PrivacyError("invalid-macho-load-commands")
                if any(offset < start + span and start < offset + length for start, span in slices):
                    raise PrivacyError("invalid-macho-load-commands")
                slices.append((offset, length))
        result = []
        for start, span in slices:
            magic = read(start, 4)
            if magic not in THIN:
                raise PrivacyError("invalid-macho-load-commands")
            endian, header_size = THIN[magic]
            header = read(start, header_size)
            count, length = struct.unpack_from(endian + "II", header, 16)
            if length > 16 * 1024 * 1024 or header_size + length > span or count > length // 8:
                raise PrivacyError("invalid-macho-load-commands")
            commands = read(start + header_size, length)
            offset = 0
            for _ in range(count):
                if offset + 8 > length:
                    raise PrivacyError("invalid-macho-load-commands")
                command, width = struct.unpack_from(endian + "II", commands, offset)
                alignment = 8 if header_size == 32 else 4
                if width < 8 or width % alignment or offset + width > length:
                    raise PrivacyError("invalid-macho-load-commands")
                if command not in STRINGS:
                    # LC_LINKER_OPTION and future commands can also contain
                    # strings. Scan their complete payload instead of making
                    # unknown command types an escape hatch for user paths.
                    payload = commands[offset + 8:offset + width].decode("utf-8", errors="replace")
                    if private_path(payload):
                        result.append((command, payload))
                if command in STRINGS:
                    minimum = 24 if command in DYLIB else (32 if command == 0x80000035 else 12)
                    field = 24 if command == 0x80000035 else 8
                    if width < minimum:
                        raise PrivacyError("invalid-macho-load-commands")
                    string_offset = struct.unpack_from(endian + "I", commands, offset + field)[0]
                    if not minimum <= string_offset < width:
                        raise PrivacyError("invalid-macho-load-commands")
                    raw = commands[offset + string_offset:offset + width]
                    end = raw.find(b"\0")
                    if end < 0:
                        raise PrivacyError("invalid-macho-load-commands")
                    try:
                        value = raw[:end].decode("utf-8")
                    except UnicodeError:
                        raise PrivacyError("invalid-macho-load-commands") from None
                    if not value or any(not char.isprintable() for char in value):
                        raise PrivacyError("invalid-macho-load-commands")
                    result.append((command, value))
                offset += width
            if offset != length:
                raise PrivacyError("invalid-macho-load-commands")
        return result


def private_path(value):
    return any(root in value for root in PRIVATE_ROOTS) or "file://" in value or value.startswith("~/")


def inspect_load_paths(path, counts):
    paths = load_paths(path)
    if paths is None:
        return False
    if any(private_path(value) for _, value in paths):
        raise PrivacyError("local-path-macho-load-command")
    counts["macho_files"] = counts.get("macho_files", 0) + 1
    counts["macho_load_paths"] = counts.get("macho_load_paths", 0) + len(paths)
    return True


def make_portable(path, root):
    """Repair only a newly copied runtime. Never sign or change the input tree."""
    path, root = Path(path), Path(root)
    paths = load_paths(path)
    if paths is None:
        return []
    changes, arguments = [], []
    for command, value in sorted(set(paths)):
        if not private_path(value):
            continue
        if command == 0xD:
            replacement = "@rpath/" + path.name
            arguments += ["-id", replacement]
        elif command == RPATH or command in DYLIB:
            # The old build root is intentionally not consulted. Resolve only
            # files shipped in this copy, refusing ambiguous library matches.
            candidates = ([p for p in root.rglob(Path(value).name) if p.is_file() and not p.is_symlink()]
                          if command in DYLIB else [])
            if command == RPATH:
                directories = ([root / "lib"] if Path(value).name == "lib" and (root / "lib").is_dir()
                               else [p for p in root.rglob(Path(value).name) if p.is_dir() and not p.is_symlink()])
                if len(directories) != 1:
                    raise PrivacyError("unresolved-private-macho-rpath")
                replacement = "@loader_path/" + os.path.relpath(directories[0], path.parent)
                if (RPATH, replacement) in paths:
                    arguments += ["-delete_rpath", value]
                else:
                    arguments += ["-rpath", value, replacement]
            elif len(candidates) == 1:
                replacement = "@loader_path/" + os.path.relpath(candidates[0], path.parent)
                arguments += ["-change", value, replacement]
            else:
                raise PrivacyError("unresolved-private-macho-dependency")
        else:
            raise PrivacyError("unsupported-private-macho-load-command")
        changes.append({"command": command, "replacement": replacement,
                        "reason": "remove-build-machine-load-path"})
    if arguments:
        result = subprocess.run(["/usr/bin/install_name_tool", *arguments, str(path)], capture_output=True)
        if result.returncode:
            raise PrivacyError("macho-path-repair-failed")
        inspect_load_paths(path, {})
    return changes
