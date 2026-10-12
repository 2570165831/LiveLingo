"""Remove diagnosed build paths from new native copies; never execute them.

Rust source locations are diagnostic strings. The MLX default path is the last
fallback after four colocated/bundle lookups; disable the build-only fallback
with an empty string. Runtime overrides and colocated resources stay intact.
Future source builds should use Rust prefix remapping and METAL_PATH="".
"""
import hashlib
from pathlib import Path
import re
import struct
import subprocess

try:
    from .privacy_package import PrivacyError
    from .macho_paths import THIN, FAT, load_paths
except ImportError:
    from privacy_package import PrivacyError
    from macho_paths import THIN, FAT, load_paths


HOST_ROOT = b"/" + b"Users/"


def sections(data):
    """Locate every file-backed section without interpreting its instructions."""
    data = bytes(data)
    slices = [(0, len(data))]
    if data[:4] in FAT:
        endian, wide = FAT[data[:4]]
        count = struct.unpack_from(endian + "I", data, 4)[0]
        width = 32 if wide else 20
        slices = [struct.unpack_from(endian + ("QQ" if wide else "II"), data, 8 + i * width + 8)
                  for i in range(count)]
    result = []
    for start, span in slices:
        endian, header = THIN[data[start:start + 4]]
        count, length = struct.unpack_from(endian + "II", data, start + 16)
        cpu = struct.unpack_from(endian + "I", data, start + 4)[0]
        offset = start + header
        for _ in range(count):
            command, size = struct.unpack_from(endian + "II", data, offset)
            if command in (0x1, 0x19):
                wide = command == 0x19
                fixed, width = (72, 80) if wide else (56, 68)
                nsects = struct.unpack_from(endian + "I", data, offset + (64 if wide else 48))[0]
                if fixed + nsects * width > size:
                    raise PrivacyError("invalid-native-section-table")
                for index in range(nsects):
                    record = offset + fixed + index * width
                    name = data[record:record + 16].split(b"\0")[0].decode()
                    segment = data[record + 16:record + 32].split(b"\0")[0].decode()
                    length = struct.unpack_from(endian + ("Q" if wide else "I"), data, record + (40 if wide else 36))[0]
                    file_offset = struct.unpack_from(endian + "I", data, record + (48 if wide else 40))[0]
                    flags = struct.unpack_from(endian + "I", data, record + (64 if wide else 56))[0]
                    if length and file_offset and flags & 0xff not in (1, 12, 18):
                        if file_offset + length > span:
                            raise PrivacyError("invalid-native-section-bounds")
                        result.append((cpu, segment, name, start + file_offset, length))
            offset += size
    return result


def section_hashes(data):
    return {(cpu, segment, name): hashlib.sha256(data[offset:offset + size]).hexdigest()
            for cpu, segment, name, offset, size in sections(data)}


def sanitize_build_paths(path, root):
    """Only mutate explicit new copies of the three diagnosed native objects."""
    path, root = Path(path), Path(root)
    if path.is_symlink() or root.is_symlink() or not path.resolve().is_relative_to(root.resolve()):
        raise PrivacyError("invalid-native-build-path-copy")
    if not (path.name == "LiveLingo" or path.suffix in (".so", ".dylib")):
        return None
    if load_paths(path) is None:
        return None
    original = path.read_bytes()
    cython_root = rb"/(?:private/)?var/folders/[^\0\n]+"
    cython_paths = list(re.finditer(cython_root, original))
    has_local_user = HOST_ROOT + b"li/" in original
    if not has_local_user and not cython_paths:
        return None
    original_sections = section_hashes(original)
    result = subprocess.run(["/usr/bin/strip", "-S", str(path)], capture_output=True)
    if result.returncode:
        raise PrivacyError("native-debug-path-strip-failed")
    data = bytearray(path.read_bytes())
    edits = []
    for cpu, segment, name, offset, size in sections(data):
        if (segment, name) != ("__TEXT", "__cstring"):
            continue
        chunk = bytes(data[offset:offset + size])
        pattern = re.escape(HOST_ROOT) + rb"[^\0\n]+|" + cython_root
        for match in re.finditer(pattern, chunk):
            value = match[0]
            if value.startswith((b"/private/var/folders/", b"/var/folders/")):
                tail = next((tail for tail in (b"numpy/__init__.cython-30.pxd", b"_cyutility.pyx")
                             if value.endswith(tail)), None)
                if path.suffix != ".so" or tail is None:
                    raise PrivacyError("unrecognized-cython-build-diagnostic")
                length = len(value) - len(tail)
                replacement = b"cython-source/" + b"_" * (length - len(b"cython-source/") - 1) + b"/" + tail
                reason = "length-preserving-cython-diagnostic-prefix-remap"
            elif path.name.startswith("outlines_core."):
                prefix = re.match(rb".+/cargo/registry/src/index\.crates\.io-[0-9a-f]+/", value)
                if not prefix or not value.endswith(b".rs"):
                    raise PrivacyError("unrecognized-rust-build-diagnostic")
                length = len(prefix[0])
                replacement = b"cargo-source/" + b"_" * (length - len(b"cargo-source/") - 1) + b"/" + value[length:]
                reason = "length-preserving-rust-diagnostic-prefix-remap"
            elif path.name == "libmlx.dylib":
                if not value.endswith(b"/mlx.metallib") or b"/mlx/backend/metal/kernels/" not in value:
                    raise PrivacyError("unrecognized-mlx-build-fallback")
                replacement = b"\0" * len(value)
                reason = "disable-build-only-last-metallib-fallback"
            else:
                raise PrivacyError("unexpected-main-executable-cstring-path")
            assert len(replacement) == len(value)
            start = offset + match.start()
            data[start:start + len(value)] = replacement
            edits.append({"offset": start, "length": len(value), "architecture": cpu,
                          "section": segment + "," + name, "action": reason})
    path.write_bytes(data)
    final_sections = section_hashes(data)
    changed = [",".join((segment, name)) for (cpu, segment, name), digest in original_sections.items()
               if final_sections.get((cpu, segment, name)) != digest]
    if any(name != "__TEXT,__cstring" for name in changed):
        raise PrivacyError("native-build-path-change-outside-cstring")
    load_paths(path)
    return {"originalSHA256": hashlib.sha256(original).hexdigest(),
            "preparedSHA256": hashlib.sha256(data).hexdigest(),
            "debugSymbolsStripped": True, "cstringEdits": edits,
            "changedFileBackedSections": changed, "instructionsUnchanged": True,
            "validation": "Static sections and load commands only; runtime acceptance pending."}
