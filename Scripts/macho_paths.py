"""Statically inspect Mach-O load commands and all raw readable path strings."""
import hashlib
import mmap
import os
from pathlib import Path
import posixpath
import re
import struct
import subprocess

try:
    from .privacy_package import PrivacyError
    from .privacy_roots import PRIVATE_ROOTS, WINDOWS_PRIVATE_PATH_PATTERN
except ImportError:
    from privacy_package import PrivacyError
    from privacy_roots import PRIVATE_ROOTS, WINDOWS_PRIVATE_PATH_PATTERN


THIN = {b"\xce\xfa\xed\xfe": ("<", 28), b"\xfe\xed\xfa\xce": (">", 28),
        b"\xcf\xfa\xed\xfe": ("<", 32), b"\xfe\xed\xfa\xcf": (">", 32)}
FAT = {b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
       b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True)}
DYLIB = {0xC, 0xD, 0x80000018, 0x8000001F, 0x20, 0x80000023}
ID_DYLIB = 0xD
DEPENDENCIES = DYLIB - {ID_DYLIB}
RPATH = 0x8000001C
STRINGS = DYLIB | {RPATH, 0xE, 0xF, 0x12, 0x13, 0x14, 0x15, 0x27, 0x80000035}
# loader.h describes these as framework/client/library names or fileset IDs,
# not paths used by dyld to select a file.
NAMES = {0x12, 0x13, 0x14, 0x15, 0x80000035}
SYSTEM_ROOTS = ("/usr/lib", "/System/Library", "/Library/Apple/System/Library")
LOADER_ANCHORS = ("@loader_path", "@executable_path", "@rpath")


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
                    # Check the fixed payload, the gap before lc_str, and all
                    # bytes after its first NUL. Keep the actual string separate
                    # so load_paths can still report a private ID for copy repair.
                    hidden = (commands[offset + 8:offset + string_offset] + b"\0"
                              + raw[end + 1:])
                    if private_path(hidden.decode("utf-8", errors="replace")):
                        raise PrivacyError("local-path-macho-load-command")
                    result.append((command, value))
                offset += width
            if offset != length:
                raise PrivacyError("invalid-macho-load-commands")
        return result


def private_path(value):
    return bool(_READABLE_ROOT.search(value))


def allowed_load_path(command, value):
    """Allow portable loads; upstream identities are a separate namespace.

    delocate assigns /DLC identities to avoid collisions between wheel libraries,
    while rewriting actual dependencies to @loader_path. Relative build IDs
    (for example protobuf's bazel-out ID) likewise do not select a load location.
    These identity exceptions never apply to dependencies or LC_RPATH.
    """
    if private_path(value):
        return False
    if command in NAMES:
        # These are opaque names/IDs, not a load location. Privacy still applies
        # to their contents; do not invent a filename grammar for upstream IDs.
        return bool(value) and all(char.isprintable() for char in value)
    if any(value == anchor or value.startswith(anchor + "/") for anchor in LOADER_ANCHORS):
        return True
    normalized = posixpath.normpath(value)
    if value.startswith("/") and any(normalized == root or normalized.startswith(root + "/")
                                     for root in SYSTEM_ROOTS):
        return True
    if command == ID_DYLIB:
        components = value.split("/")
        if any(part in (".", "..") for part in components):
            return False
        if value.startswith("/DLC/") and len(components) >= 4:
            return True
        # Keep ordinary upstream relative IDs, not unrecognized dyld macros,
        # URLs, or machine-specific absolute identifiers.
        return not value.startswith(("/", "@", "~")) and ":" not in value
    return False


def inspect_load_paths(path, counts):
    paths = load_paths(path)
    if paths is None:
        return False
    if any(private_path(value) for _, value in paths):
        raise PrivacyError("local-path-macho-load-command")
    if any(command in STRINGS and not allowed_load_path(command, value)
           for command, value in paths):
        raise PrivacyError("nonportable-macho-load-command")
    counts["macho_files"] = counts.get("macho_files", 0) + 1
    counts["macho_load_paths"] = counts.get("macho_load_paths", 0) + sum(
        command in STRINGS - NAMES for command, _ in paths)
    counts["macho_names"] = counts.get("macho_names", 0) + sum(
        command in NAMES for command, _ in paths)
    return True


# Match the private roots even in compiler operands, symbol names, repeated
# slashes, and file URLs. Do not implicitly approve runner/CI/Homebrew paths.
_READABLE_ROOT = re.compile(
    "|".join(re.escape(root.rstrip("/")).replace("/", "/+")
             + r"(?:/+|(?=$|\s))" for root in PRIVATE_ROOTS)
    + r"|file:/+|~[\\/]+|" + WINDOWS_PRIVATE_PATH_PATTERN, re.IGNORECASE)
_READABLE_BYTES = re.compile(rb"[\x20-\x7e\x80-\xff]{4,}")
_UTF16_LE = re.compile(rb"(?:[\x20-\x7e]\x00){4,}")
_UTF16_BE = re.compile(rb"(?:\x00[\x20-\x7e]){4,}")
_PATH_END = frozenset("\"'<>`|;")
_BARE_BUILD_ROOTS = frozenset(root.rstrip("/").lower() for root in PRIVATE_ROOTS)
_COMPILER_BOUNDARY = re.compile(
    r"(?<![\w.-])(?:-isystem|-iquote|-idirafter|-iframework|-isysroot|-include|-imacros|-I|-L|-F)"
    r"(?:[ \t]+|=)?$")


def _effective_build_operand(value, context, start, has_string_edge):
    """Suppress generic roots and short/binary tilde coincidences, not formats."""
    if posixpath.normpath(value).lower() in _BARE_BUILD_ROOTS:
        return False
    if value.startswith("\\\\"):
        # A valid host/share spelling at an operand or binary string edge is
        # UNC. Random instruction/table bytes and embedded regex fragments
        # with no such edge are not readable host operands.
        if not all(char.isprintable() for char in value):
            return False
        if (start and context[start - 1].isprintable()
                and context[start - 1] not in " \t\"'=:(<"
                and not _COMPILER_BOUNDARY.search(context[:start])):
            return False
        if not start and not has_string_edge:
            return False
    if value.startswith(("~/", "~\\")):
        # A short ~/ byte sequence is common in instructions/tables. Require
        # a real operand boundary, a printable run and at least two suffix
        # characters. No section-wide exemption: absolute private roots are
        # still scanned even when surrounded by binary data.
        if len(value[2:].strip()) < 2 or not all(char.isprintable() for char in context):
            return False
        if start and context[start - 1] not in " \t\"'=:(<":
            return False
        if not start and not has_string_edge:
            return False
    return True


def _utf16_path_at(data, offset, encoding):
    """Extend an ASCII root through printable Unicode without truncating approval."""
    chars = []
    while offset + 2 <= len(data):
        unit = bytes(data[offset:offset + 2])
        order = "little" if encoding == "utf-16-le" else "big"
        code = int.from_bytes(unit, order)
        width = 4 if 0xD800 <= code <= 0xDBFF else 2
        try:
            char = bytes(data[offset:offset + width]).decode(encoding)
        except UnicodeError:
            break
        if not char.isprintable() or char in _PATH_END:
            break
        chars.append(char)
        offset += width
    return "".join(chars)


def _readable_matches(data):
    """Yield exact whole-file byte offsets; no section/command exemptions."""
    matches = []
    for pattern, encoding in ((_READABLE_BYTES, "utf-8"),
                              (_UTF16_LE, "utf-16-le"), (_UTF16_BE, "utf-16-be")):
        for run in pattern.finditer(data):
            text = run.group().decode(encoding, errors="surrogateescape")
            covered_until = -1
            for root in _READABLE_ROOT.finditer(text):
                if root.start() < covered_until:
                    continue
                end = root.end()
                while (end < len(text) and text[end].isprintable()
                       and text[end] not in _PATH_END):
                    end += 1
                value = text[root.start():end]
                offset = run.start() + len(text[:root.start()].encode(
                    encoding, errors="surrogateescape"))
                if encoding != "utf-8":
                    value = _utf16_path_at(data, offset, encoding)
                has_string_edge = (run.start() == 0 or run.end() == len(data)
                                   or data[run.start() - 1:run.start()] == b"\0"
                                   or data[run.end():run.end() + 1] == b"\0")
                if not _effective_build_operand(value, text, root.start(), has_string_edge):
                    continue
                covered_until = root.start() + len(value)
                matches.append({"offset": offset, "path": value, "encoding": encoding})
    return sorted(matches, key=lambda item: (item["offset"], item["encoding"], item["path"]))


def scan_readable_paths_bytes(data):
    """Report private readable paths anywhere in thin/fat Mach-O raw bytes.

    Returns None for other magic, otherwise {sha256, size, matches}. Each match
    has a whole-file byte offset, exact path spelling and encoding. Covers UTF-8
    and UTF-16 paths with ASCII roots in all sections, string tables, gaps and trailers;
    this is not a decoder for arbitrary compressed/encoded data. Recognized
    magic never exempts content, even if structural parsing would fail. Call
    inspect_load_paths too when validating the container/load graph.
    """
    if data[:4] not in THIN and data[:4] not in FAT:
        return None
    return scan_binary_paths_bytes(data)


def scan_binary_paths_bytes(data):
    """Scan complete binary bytes before any magic/suffix-based dispatch.

    No container type, opaque-fixture hash or catalog string table narrows this
    scan. Exact public approvals are applied by the hash-verifying caller.
    """
    return {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data),
            "matches": _readable_matches(data)}


def scan_readable_paths(path):
    """Read-only whole-file scan, without loading native code or launching tools."""
    with Path(path).open("rb") as stream:
        if stream.read(4) not in THIN.keys() | FAT.keys():
            return None
        with mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
            return scan_readable_paths_bytes(data)


def _exact_build_path_approvals(allowed):
    """Only exact readable path strings; hash binding belongs to the caller."""
    invalid = "invalid-macho-build-path-approval"
    if isinstance(allowed, (str, bytes, bytearray, dict)):
        raise PrivacyError(invalid)
    try:
        entries = tuple(allowed)
    except TypeError:
        raise PrivacyError(invalid) from None
    approvals = set()
    for value in entries:
        if isinstance(value, bytes):
            try:
                value = value.decode("utf-8")
            except UnicodeError:
                raise PrivacyError(invalid) from None
        if not isinstance(value, str) or not value:
            raise PrivacyError(invalid)
        try:
            findings = _readable_matches(value.encode("utf-8"))
        except UnicodeError:
            raise PrivacyError(invalid) from None
        if (len(findings) != 1 or findings[0]["offset"] != 0
                or findings[0]["path"] != value):
            raise PrivacyError(invalid)
        approvals.add(value)
    return frozenset(approvals)


def inspect_build_paths(path, counts, *, allowed=()):
    """Reject private paths anywhere in Mach-O raw readable strings.

    allowed is an iterable of exact full public upstream paths (UTF-8 bytes or
    strings), supplied ONLY after the caller verifies a manifest's full-file
    SHA-256 and review reason against this same file. This API does not supply,
    persist or authenticate that approval. Never reuse allowed for another
    file/build or after mutation; no filename/format/directory/prefix exemption.

    The normal load-command gate stays strict, even for an approved diagnostic
    string: validation here calls it with private counters, so it cannot be
    waived or counted twice. Packaging should still call inspect_load_paths
    independently for its load-graph counts. Build counters change only after
    both checks succeed. Returns False for non-Mach-O.

    Error messages omit contents. scan_readable_paths provides private internal
    evidence including SHA-256 and offsets; do not publish its private paths.
    """
    approvals = _exact_build_path_approvals(allowed)
    if not inspect_load_paths(path, {}):
        return False
    report = scan_readable_paths(path)
    if report is None:
        raise PrivacyError("changed-macho-build-path-input")
    if any(item["path"] not in approvals for item in report["matches"]):
        raise PrivacyError("local-path-macho-build-string")
    counts["macho_build_path_files"] = counts.get("macho_build_path_files", 0) + 1
    counts["macho_build_paths"] = counts.get("macho_build_paths", 0) + len(report["matches"])
    counts["macho_approved_build_paths"] = counts.get("macho_approved_build_paths", 0) + len(
        report["matches"])
    return True


def inspect_macho_paths(path, counts, *, allowed=()):
    """Optional combined static gate with atomic load/build counter updates."""
    updated = dict(counts)
    if not inspect_load_paths(path, updated):
        return False
    inspect_build_paths(path, updated, allowed=allowed)
    counts.update(updated)
    return True


def make_portable(path, root):
    """Repair only a newly copied runtime. Never sign or change the input tree."""
    path, root = Path(path), Path(root)
    paths = load_paths(path)
    if paths is None:
        return []
    if (path.is_symlink() or root.is_symlink() or not root.is_dir()
            or not path.resolve().is_relative_to(root.resolve())):
        raise PrivacyError("invalid-macho-repair-path")
    changes, arguments = [], []
    def bundled_dependency(value):
        # Consult only regular files inside this prepared copy. Never inspect
        # an old absolute path or guess between duplicate bundled libraries.
        candidates = [p for p in root.rglob(Path(value).name)
                      if p.is_file() and not p.is_symlink()
                      and p.resolve().is_relative_to(root.resolve())]
        if len(candidates) != 1:
            raise PrivacyError("unresolved-private-macho-dependency")
        return "@loader_path/" + os.path.relpath(candidates[0], path.parent)

    unsafe_rpaths = [value for command, value in sorted(set(paths))
                     if command == RPATH and not allowed_load_path(command, value)]
    repaired_dependencies = set()
    if unsafe_rpaths:
        # Deleting a build search directory is safe for the static load graph
        # only after @rpath imports no longer need it. Resolve those imports to
        # unique shipped files, or fail before running install_name_tool.
        for command, value in sorted(set(paths)):
            if command in DEPENDENCIES and value.startswith("@rpath/"):
                replacement = bundled_dependency(value)
                arguments += ["-change", value, replacement]
                repaired_dependencies.add(value)
                changes.append({"command": command, "action": "replaced", "replacement": replacement,
                                "reason": "resolve-shipped-library-before-removing-build-rpath"})
    for command, value in sorted(set(paths)):
        if allowed_load_path(command, value):
            continue
        if command == ID_DYLIB:
            replacement = "@rpath/" + path.name
            arguments += ["-id", replacement]
        elif command == RPATH:
            replacement = None
            arguments += ["-delete_rpath", value]
        elif command in DEPENDENCIES:
            if value in repaired_dependencies:
                continue
            replacement = bundled_dependency(value)
            arguments += ["-change", value, replacement]
        else:
            raise PrivacyError("unsupported-private-macho-load-command")
        changes.append({"command": command, "action": "removed" if replacement is None else "replaced",
                        "replacement": replacement,
                        "reason": "remove-build-machine-load-path"})
    if arguments:
        result = subprocess.run(["/usr/bin/install_name_tool", *arguments, str(path)], capture_output=True)
        if result.returncode:
            raise PrivacyError("macho-path-repair-failed")
        inspect_load_paths(path, {})
    return changes
