"""Inspect reviewed corresponding-source tar members without extracting them."""
from pathlib import Path, PurePosixPath
import hashlib
import base64
import json
import re
import unicodedata
import tarfile
import bz2
import gzip
import lzma
import struct
from contextlib import ExitStack

if __package__:
    from .privacy_package import (PrivacyError, JSON_LIMIT, decode_metadata_text,
                                  metadata_kind, parse_metadata, validate_metadata, known_binary,
                                  CONTENT_NAMES, CONTENT_SUFFIXES)
    from .reviewed_resources import scan_host_paths, public_example_spellings
    from .privacy_literals import C_SOURCE_SUFFIXES, inspect_source_literals, unc_source_view
    from .privacy_text import scan_path_operands, replace_public_spelling
    from .macho_paths import scan_binary_paths_bytes
else:
    from privacy_package import (PrivacyError, JSON_LIMIT, decode_metadata_text,
                                 metadata_kind, parse_metadata, validate_metadata, known_binary,
                                 CONTENT_NAMES, CONTENT_SUFFIXES)
    from reviewed_resources import scan_host_paths, public_example_spellings
    from privacy_literals import C_SOURCE_SUFFIXES, inspect_source_literals, unc_source_view
    from privacy_text import scan_path_operands, replace_public_spelling
    from macho_paths import scan_binary_paths_bytes


class PublicSourceTarInfo(tarfile.TarInfo):
    """Inspect complete raw fixed fields before tarfile trims NUL padding.

    The hook also runs for PAX/long-name extension headers, whose ownership
    would otherwise disappear before archive iteration returns a member.
    """
    @classmethod
    def frombuf(cls, buf, encoding, errors):
        member = super().frombuf(buf, encoding, errors)  # Includes tar checksum validation.
        for start, length in ((0, 100), (157, 100), (257, 6), (263, 2),
                              (265, 32), (297, 32), (345, 155)):
            field = buf[start:start + length]
            terminator = field.find(b"\0")
            if terminator >= 0 and any(field[terminator + 1:]):
                raise PrivacyError("nonpublic-source-archive-header")
            scan_host_paths(field, source_code=True)
        # Numeric octal fields may end with NUL/spaces, including the checksum's
        # conventional NUL+space. Arbitrary bytes after NUL are never accepted.
        for start, length in ((100, 8), (108, 8), (116, 8), (124, 12),
                              (136, 12), (148, 8), (329, 8), (337, 8)):
            field = buf[start:start + length]
            scan_host_paths(field, source_code=True)
            if field[:1] in (b"\x80", b"\xff"):
                continue  # GNU base-256 values have no string terminator.
            if not re.fullmatch(rb"[0-7 ]*(?:\0[\0 ]*)?", field):
                raise PrivacyError("nonpublic-source-archive-header")
        if any(buf[500:512]):
            raise PrivacyError("nonpublic-source-archive-header")
        if member.uname or member.gname or member.uid != 0 or member.gid != 0 or member.mtime != 0:
            raise PrivacyError("nonpublic-source-archive-header")
        return member


def source_pax_records(data):
    """Validate each raw record before tarfile can overwrite duplicate keys."""
    result, offset = {}, 0
    prefix = re.compile(rb"([1-9][0-9]*) ")
    while offset < len(data):
        match = prefix.match(data, offset)
        if match is None or len(match[1]) > 10:
            raise PrivacyError("invalid-source-pax-record")
        length = int(match[1])
        end = offset + length
        if length <= match.end() - offset + 2 or end > len(data) or data[end - 1:end] != b"\n":
            raise PrivacyError("invalid-source-pax-record")
        raw_key, equals, raw_value = data[match.end():end - 1].partition(b"=")
        if not raw_key or not equals or b"\0" in raw_key + raw_value:
            raise PrivacyError("invalid-source-pax-record")
        try:
            key, value = raw_key.decode("utf-8"), raw_value.decode("utf-8")
        except UnicodeError:
            raise PrivacyError("invalid-source-pax-record") from None
        if key in result:
            raise PrivacyError("duplicate-source-pax-key")
        scan_host_paths(raw_key + b"=" + raw_value, source_code=True)
        validate_metadata({key: value})
        if key.startswith("GNU.sparse."):
            raise PrivacyError("unsupported-source-archive-member")
        if key == "size" and not re.fullmatch(r"[0-9]{1,10}", value):
            raise PrivacyError("invalid-source-pax-record")
        result[key] = value
        if len(result) > 100000:
            raise PrivacyError("source-archive-expansion-limit")
        offset = end
    return result


def inspect_source_envelope(path):
    """Check the complete decompressed tar, including ignored extension bytes.

    This second bounded stream never extracts or executes a member. tarfile's
    semantic pass alone stops at the first zero block and discards padding.
    """
    with ExitStack() as stack:
        raw = stack.enter_context(Path(path).open("rb"))
        magic = raw.read(6)
        raw.seek(0)
        opener = (gzip.GzipFile if magic.startswith(b"\x1f\x8b") else
                  bz2.BZ2File if magic.startswith(b"BZh") else
                  lzma.LZMAFile if magic.startswith(b"\xfd7zXZ\0") else None)
        stream = (stack.enter_context(gzip.GzipFile(fileobj=raw, mode="rb")) if opener is gzip.GzipFile
                  else stack.enter_context(opener(raw, "rb")) if opener else raw)
        expanded, headers = 0, 0
        global_pax, local_pax = {}, {}
        pending = False

        def read(length):
            nonlocal expanded
            data = stream.read(length)
            expanded += len(data)
            if expanded > 1200 * 1024 * 1024:
                raise PrivacyError("source-archive-expansion-limit")
            if len(data) != length:
                raise PrivacyError("invalid-source-archive")
            return data

        while True:
            block = read(512)
            if block == b"\0" * 512:
                if pending or read(512) != b"\0" * 512:
                    raise PrivacyError("invalid-source-archive")
                while data := stream.read(65536):
                    expanded += len(data)
                    if expanded > 1200 * 1024 * 1024:
                        raise PrivacyError("source-archive-expansion-limit")
                    if any(data):
                        raise PrivacyError("nonzero-source-archive-trailer")
                return
            member = PublicSourceTarInfo.frombuf(block, "utf-8", "surrogateescape")
            headers += 1
            if headers > 150000:
                raise PrivacyError("source-archive-expansion-limit")
            extension = member.type in (tarfile.XHDTYPE, tarfile.XGLTYPE, tarfile.SOLARIS_XHDTYPE,
                                       tarfile.GNUTYPE_LONGNAME, tarfile.GNUTYPE_LONGLINK)
            if ((not extension and not (member.isfile() or member.isdir()))
                    or member.sparse is not None):
                raise PrivacyError("unsupported-source-archive-member")
            size = member.size
            if not extension:
                effective = global_pax | local_pax
                if "size" in effective:
                    size = int(effective["size"])
                local_pax, pending = {}, False
                if member.isdir() and size:
                    raise PrivacyError("unsupported-source-archive-member")
            if size < 0 or size > JSON_LIMIT:
                raise PrivacyError("unsupported-source-archive-member")
            if extension:
                data = read(size)
                if member.type in (tarfile.XHDTYPE, tarfile.XGLTYPE, tarfile.SOLARIS_XHDTYPE):
                    values = source_pax_records(data)
                    target = global_pax if member.type == tarfile.XGLTYPE else local_pax
                    if member.type != tarfile.XGLTYPE and target.keys() & values.keys():
                        raise PrivacyError("duplicate-source-pax-key")
                    target.update(values)
                else:
                    scan_host_paths(data, source_code=True)
                    end = data.find(b"\0")
                    if end < 0 or any(data[end + 1:]):
                        raise PrivacyError("nonpublic-source-archive-header")
                pending = True
            else:
                remaining = size
                while remaining:
                    amount = min(remaining, 65536)
                    read(amount)
                    remaining -= amount
            if any(read(-size % 512)):
                raise PrivacyError("nonzero-source-archive-padding")


def inspect_source_macho(data, counts):
    """Parse all native slices in memory; no filesystem loads or extraction."""
    if __package__:
        from .macho_paths import THIN, FAT, STRINGS, DYLIB, allowed_load_path, private_path
    else:
        from macho_paths import THIN, FAT, STRINGS, DYLIB, allowed_load_path, private_path
    if data[:4] not in THIN and data[:4] not in FAT:
        return False

    def read(offset, length, start=0, span=None):
        span = len(data) if span is None else span
        if offset < start or length < 0 or offset + length > start + span:
            raise PrivacyError("invalid-macho-load-commands")
        return data[offset:offset + length]

    slices = [(0, len(data))]
    if data[:4] in FAT:
        endian, wide = FAT[data[:4]]
        count = struct.unpack(endian + "I", read(4, 4))[0]
        if not 1 <= count <= 64:
            raise PrivacyError("invalid-macho-load-commands")
        width = 32 if wide else 20
        table_end = 8 + count * width
        slices = []
        for index in range(count):
            record = read(8 + index * width, width)
            start, span = struct.unpack_from(endian + ("QQ" if wide else "II"), record, 8)
            if (start < table_end or span < 28 or start + span > len(data)
                    or any(start < other + length and other < start + span for other, length in slices)):
                raise PrivacyError("invalid-macho-load-commands")
            slices.append((start, span))
    paths = 0
    for start, span in slices:
        magic = read(start, 4, start, span)
        if magic not in THIN:
            raise PrivacyError("invalid-macho-load-commands")
        endian, header_size = THIN[magic]
        header = read(start, header_size, start, span)
        count, length = struct.unpack_from(endian + "II", header, 16)
        if length > 16 * 1024 * 1024 or count > length // 8:
            raise PrivacyError("invalid-macho-load-commands")
        commands = read(start + header_size, length, start, span)
        offset = 0
        for _ in range(count):
            if offset + 8 > length:
                raise PrivacyError("invalid-macho-load-commands")
            command, width = struct.unpack_from(endian + "II", commands, offset)
            if width < 8 or width % (8 if header_size == 32 else 4) or offset + width > length:
                raise PrivacyError("invalid-macho-load-commands")
            payload = commands[offset + 8:offset + width]
            if private_path(payload.decode("utf-8", errors="replace")):
                raise PrivacyError("local-path-macho-load-command")
            if command in STRINGS:
                minimum = 24 if command in DYLIB else 32 if command == 0x80000035 else 12
                field = 24 if command == 0x80000035 else 8
                if width < minimum:
                    raise PrivacyError("invalid-macho-load-commands")
                string_offset = struct.unpack_from(endian + "I", commands, offset + field)[0]
                if not minimum <= string_offset < width:
                    raise PrivacyError("invalid-macho-load-commands")
                raw_value = commands[offset + string_offset:offset + width]
                end = raw_value.find(b"\0")
                if end < 0:
                    raise PrivacyError("invalid-macho-load-commands")
                try:
                    value = raw_value[:end].decode("utf-8")
                except UnicodeError:
                    raise PrivacyError("invalid-macho-load-commands") from None
                if not value or any(not c.isprintable() for c in value):
                    raise PrivacyError("invalid-macho-load-commands")
                if not allowed_load_path(command, value):
                    raise PrivacyError("nonportable-macho-load-command")
                paths += 1
            offset += width
        if offset != length:
            raise PrivacyError("invalid-macho-load-commands")
    counts["macho_files"] = counts.get("macho_files", 0) + 1
    counts["macho_load_paths"] = counts.get("macho_load_paths", 0) + paths
    return True


def source_member_approvals(item):
    """Decode exact public spelling and opaque regression fixture approvals."""
    root = item["package"] + "-" + item["version"]

    def validate(name, digest):
        if not isinstance(name, str) or not isinstance(digest, str):
            raise PrivacyError("invalid-source-member-approval")
        path = PurePosixPath(name)
        if (path.is_absolute() or ".." in path.parts or "\\" in name or str(path) != name
                or not path.parts or path.parts[0] != root
                or not re.fullmatch(r"[0-9a-f]{64}", digest)):
            raise PrivacyError("invalid-source-member-approval")

    entries = item.get("publicSourceHostPathExamples", {})
    fixtures = item.get("opaqueSourceFixtures", {})
    if not isinstance(entries, dict) or not isinstance(fixtures, dict):
        raise PrivacyError("invalid-source-member-approval")
    examples = {}
    for name, entry in entries.items():
        if not isinstance(entry, dict):
            raise PrivacyError("invalid-source-member-approval")
        digest = entry.get("sha256")
        validate(name, digest)
        examples[name] = (digest, public_example_spellings(entry.get("examples"), source_only=True))
    for name, digest in fixtures.items():
        validate(name, digest)
    return examples, fixtures


def source_public_view(value, allowed, *, source_code=False):
    """Preserve all metadata rules while neutralizing exact approved spellings."""
    if isinstance(value, str):
        for public in sorted(allowed, key=len, reverse=True):
            if public == "/":
                if value == public:
                    value = "PUBLIC_UPSTREAM_EXAMPLE"
                continue  # A documentation root token must not mask other paths.
            # Removing the leading slash of an approved local URI path would
            # turn its empty authority into an invented hostname. Neutralize
            # only the complete URI for that exact approved path, never a
            # remote authority or a longer path that merely shares its prefix.
            if public.startswith("/"):
                value = re.sub(r'(?<![\w+.-])(?i:file://(?:localhost)?)' + re.escape(public)
                               + r'(?=$|[\s"\'<>`,])',
                               "PUBLIC_UPSTREAM_EXAMPLE", value)
            value = replace_public_spelling(value, public, source_code=source_code)
    elif isinstance(value, dict):
        result = {}
        for key, item in value.items():
            key = source_public_view(key, allowed)
            if key in result:
                raise PrivacyError("duplicate-public-source-metadata-key")
            result[key] = source_public_view(item, allowed)
        value = result
    elif isinstance(value, list):
        value = [source_public_view(item, allowed) for item in value]
    return value


def source_metadata_view(value):
    """Recognize Go vendor SHA-1 digests without treating '/' as a host path.

    The exact field, canonical encoding and digest width are checked. Both the
    original string and decoded bytes retain the machine-path check; no other
    string or metadata key is omitted from the ordinary recursive policy.
    """
    if isinstance(value, dict):
        result = {}
        for key, item in value.items():
            if key == "checksumSHA1" and isinstance(item, str):
                scan_host_paths(item.encode("utf-8"), source_code=True)
                try:
                    decoded = base64.b64decode(item, validate=True)
                except ValueError:
                    raise PrivacyError("invalid-source-checksum") from None
                if len(decoded) != 20 or base64.b64encode(decoded).decode("ascii") != item:
                    raise PrivacyError("invalid-source-checksum")
                scan_host_paths(decoded, source_code=True)
                result[key] = "VALIDATED_SHA1_DIGEST"
            else:
                result[key] = source_metadata_view(item)
        return result
    if isinstance(value, list):
        return [source_metadata_view(item) for item in value]
    return value


def source_json(data, name):
    """Decode complete JSON or a sequence of complete JSON test events.

    Every event goes through the strict duplicate-key parser. Recognized C/C++
    syntax such as [[gnu::nonnull]] retains the raw/source-literal checks;
    it is not treated as malformed JSON just because it begins with '['.
    """
    try:
        return parse_metadata(data, "json")
    except PrivacyError as error:
        if error.args[0] != "invalid-package-json":
            raise
        # The shared parser wraps duplicate-key errors as invalid JSON. A
        # complete JSON document must not enter the source-syntax fallback.
        try:
            json.loads(data)
        except (ValueError, UnicodeError, RecursionError):
            pass
        else:
            raise
        if Path(name).suffix.lower() in C_SOURCE_SUFFIXES | {".inc"}:
            return None
        if Path(name).suffix != ".json":
            raise
    text = decode_metadata_text(data)
    if text is None:
        raise PrivacyError("invalid-source-json-sequence")
    decoder, offset, events = json.JSONDecoder(), 0, []
    while offset < len(text):
        start = offset
        while start < len(text) and text[start].isspace():
            start += 1
        if start == len(text):
            break
        try:
            _, end = decoder.raw_decode(text, start)
        except ValueError:
            raise PrivacyError("invalid-source-json-sequence") from None
        events.append(parse_metadata(text[start:end].encode("utf-8"), "json"))
        if end < len(text) and not text[end].isspace():
            raise PrivacyError("invalid-source-json-sequence")
        offset = end
    if len(events) < 2:
        raise PrivacyError("invalid-source-json-sequence")
    return events


def source_text(data, name):
    """Identify legacy source text, including literal ANSI terminal escapes.

    Autoconf/Automake and colored's Rust source contain ESC/backspace literals.
    They are recognized only in source/build filenames, never arbitrary blobs.
    NUL and other binary controls remain unsupported.
    """
    text = decode_metadata_text(data)
    if text is not None:
        return text
    for encoding in ("utf-8", "cp1252"):
        try:
            text = data.decode(encoding)
        except UnicodeError:
            continue
        allowed = "\x07\x08\x1b" if (Path(name).suffix in (".rs", ".sh", ".in", ".nas", ".c", ".cc", ".cpp", ".h", ".hpp", ".snap")
                                  or Path(name).name in ("configure", "test-driver")) else ""
        if (re.search(r"\.info(?:-[0-9]+)?$", name) and
                (text.startswith("This is ") or text.startswith("\x1f")) and "\x1f\n" in text):
            allowed += "\x00\x08\x1f\x7f"  # GNU Info node/index separators.
        if all(c.isprintable() or c.isspace() or c in allowed or unicodedata.category(c) == "Cf" for c in text):
            return text
    return None


def source_catalog(data, name):
    """Decode bounded GNU gettext catalogs, including every msgid/msgstr."""
    import struct
    if Path(name).suffix not in (".mo", ".gmo"):
        return False
    if len(data) < 28:
        raise PrivacyError("invalid-source-catalog")
    magic = data[:4]
    endian = {b"\xde\x12\x04\x95": "<", b"\x95\x04\x12\xde": ">"}.get(magic)
    if endian is None:
        raise PrivacyError("invalid-source-catalog")
    revision, count, original, translated, hashes, hash_offset = struct.unpack_from(endian + "6I", data, 4)
    if revision != 0 or count > 100000 or hash_offset + hashes * 4 > len(data):
        raise PrivacyError("invalid-source-catalog")
    for table in (original, translated):
        if table < 28 or table + count * 8 > len(data):
            raise PrivacyError("invalid-source-catalog")
        for index in range(count):
            length, offset = struct.unpack_from(endian + "II", data, table + index * 8)
            if offset + length >= len(data) or data[offset + length] != 0:
                raise PrivacyError("invalid-source-catalog")
            scan_host_paths(data[offset:offset + length], source_code=True)
    return True


def inspect_source_xml(data, *, allowed=()):
    """Inspect XML source/build markup without resolving DTDs or entities online.

    Source substitutions and C++ header references are relative build syntax.
    All other attributes, text, comments and literal entity declarations retain
    the metadata policy. External declarations are inspected, never fetched.
    """
    from xml.parsers.expat import ParserCreate, ExpatError
    def value(text, field=None):
        if text is None:
            return
        text = source_public_view(text, allowed)
        scan_host_paths(text.encode(), source_code=True)
        kind = metadata_kind(text.encode())
        if kind:
            try:
                parsed = parse_metadata(text.encode(), kind)
            except PrivacyError as error:
                # XML documentation uses bracketed standard citations, ranges
                # and Tcl examples. They are prose/code, not JSON documents.
                # Complete JSON and all attributes retain the normal policy.
                if kind != "json" or field or error.args[0] != "invalid-package-json":
                    raise
            else:
                validate_metadata(parsed)
        text = re.sub(r"(?:\$\([A-Za-z_][A-Za-z0-9_]*\)|\$\{[A-Za-z_][A-Za-z0-9_.-]*\}|@[A-Za-z_][A-Za-z0-9_]*@)/",
                      "RELATIVE_BUILD_DIR/", text)
        text = re.sub(r"([A-Za-z0-9_-]+)\+\+/", r"\1CPP/", text)
        text = text.replace("+/", "%2B/")  # e.g. the relative gtk+/gdk build path.
        if field:
            validate_metadata({field: text})
    parser = ParserCreate(namespace_separator="}")
    parser.buffer_text = True
    stack = []
    def start(name, attrs):
        local = name.split("}")[-1]
        validate_metadata({local: None})
        stack.append(local)
        for field, text in attrs.items():
            if field in ("select", "match", "test") and "www.w3.org/1999/XSL/Transform" in name:
                scan_host_paths(source_public_view(text, allowed).encode(), source_code=True)
            else:
                value(text, field)
    parser.StartElementHandler = start
    parser.EndElementHandler = lambda name: stack.pop()
    parser.CharacterDataHandler = lambda text: value(text, stack[-1] if stack and stack[-1] in
        ("path", "dir", "directory", "file", "filename", "uri", "url") else None)
    parser.CommentHandler = value
    parser.ProcessingInstructionHandler = lambda name, text: value(text)
    parser.EntityDeclHandler = lambda name, parameter, literal, base, system, public, notation: [value(x) for x in (literal, system, public)]
    parser.StartDoctypeDeclHandler = lambda name, system, public, internal: [value(x) for x in (system, public)]
    parser.ExternalEntityRefHandler = lambda *args: 1
    try:
        parser.Parse(data, True)
    except ExpatError:
        raise PrivacyError("invalid-source-archive-metadata") from None


def cargo_source_view(value):
    """Cargo features and package globs name package objects, not host files."""
    import copy
    value = copy.deepcopy(value)
    package = value.get("package", {})
    if not isinstance(package, dict):
        return value  # Cargo.lock has an array of packages, not a package table.
    for field in ("include", "exclude"):
        if isinstance(package.get(field), list):
            package[field] = ["https://crate-files.invalid/" + item if isinstance(item, str)
                              and re.fullmatch(r"[A-Za-z0-9_.*?/!\[\]-]+", item) else item
                              for item in package[field]]
    if isinstance(value.get("features"), dict):
        for key, items in value["features"].items():
            if isinstance(items, list):
                value["features"][key] = ["https://crate-features.invalid/" + item if isinstance(item, str)
                                         and re.fullmatch(r"[A-Za-z0-9_.?-]+/[A-Za-z0-9_.-]+", item)
                                         else item for item in items]
    return value


def inspect_source_archive(path, item, counts):
    seen = set()
    total = 0
    examples, fixtures = source_member_approvals(item)
    try:
        with tarfile.open(path, "r|*", tarinfo=PublicSourceTarInfo) as archive:
            for member in archive:
                name = PurePosixPath(member.name)
                if (name.is_absolute() or ".." in name.parts or "\\" in member.name
                        or member.name in seen or not name.parts
                        or name.parts[0] != item["package"] + "-" + item["version"]):
                    raise PrivacyError("invalid-source-archive-path")
                seen.add(member.name)
                if member.uname or member.gname or member.uid != 0 or member.gid != 0 or member.mtime != 0:
                    raise PrivacyError("nonpublic-source-archive-header")
                validate_metadata(member.pax_headers)
                if member.isdir():
                    continue
                if not member.isfile() or not 0 <= member.size <= JSON_LIMIT:
                    raise PrivacyError("unsupported-source-archive-member")
                if name.name.lower() in CONTENT_NAMES or name.name.lower().endswith(CONTENT_SUFFIXES):
                    raise PrivacyError("classroom-content-file")
                total += member.size
                if len(seen) > 150000 or total > 1024 * 1024 * 1024:
                    raise PrivacyError("source-archive-expansion-limit")
                data = archive.extractfile(member).read()
                allowed = ()
                if member.name in examples:
                    digest, allowed = examples[member.name]
                    if hashlib.sha256(data).hexdigest() != digest:
                        raise PrivacyError("source-member-example-hash-mismatch")
                if member.name in fixtures and hashlib.sha256(data).hexdigest() != fixtures[member.name]:
                    raise PrivacyError("opaque-source-fixture-hash-mismatch")
                text = source_text(data, member.name)
                binary = known_binary(Path(member.name), data[:4096], len(data))
                if allowed and (text is None or binary):
                    reason = item["publicSourceHostPathExamples"][member.name].get("reason")
                    if not isinstance(reason, str) or not reason.strip():
                        raise PrivacyError("invalid-source-member-approval")
                    validate_metadata(reason)
                raw_view = data
                for public in sorted(allowed, key=len, reverse=True):
                    if public != "/":
                        raw_view = raw_view.replace(public.encode("utf-8"), b"PUBLIC_UPSTREAM_EXAMPLE")
                unc_view = (unc_source_view(source_public_view(text, allowed, source_code=True), member.name).encode("utf-8")
                            if text is not None else None)
                scan_host_paths(raw_view, source_code=True, unc_view=unc_view)
                # Every binary member receives the same whole-file path scan,
                # including unreferenced catalog tails and opaque fixtures.
                # Approvals above bind this member's complete hash and reason;
                # compare exact decoded paths rather than replacing prefixes.
                if text is None or binary:
                    matches = scan_binary_paths_bytes(data)["matches"]
                    if any(match["path"] not in allowed for match in matches):
                        raise PrivacyError("local-path-source-binary")
                inspect_source_macho(data, counts)
                if binary:
                    counts["opaque_binary_files"] += 1
                    counts["source_archive_members"] = counts.get("source_archive_members", 0) + 1
                    continue
                if text is not None:
                    plain = "".join(c for c in text if unicodedata.category(c) != "Cf")
                    def check(value, *, source_code=False):
                        value = "".join(c for c in value if unicodedata.category(c) != "Cf")
                        scan_path_operands(source_public_view(value, allowed, source_code=source_code),
                                           raw_source=source_code, name=member.name)
                    check(plain, source_code=True)
                    inspect_source_literals(text, member.name, check)
                kind = metadata_kind(data)
                if name.suffix.lower() in (".yaml", ".yml"):
                    raise PrivacyError("unsupported-source-archive-metadata")
                xml_source = (text is not None and text.lstrip().startswith("<?xml") and "<plist" not in text[:1024]
                              or (kind != "plist" and name.suffix.lower() in (".xml", ".vcproj", ".vsprops", ".svg", ".tag")))
                if xml_source:
                    inspect_source_xml(data, allowed=allowed)
                elif name.suffix == ".toml" or name.name == "Cargo.lock":
                    import tomllib
                    try:
                        value = tomllib.loads(data.decode("utf-8"))
                    except (UnicodeError, ValueError):
                        raise PrivacyError("invalid-source-archive-metadata") from None
                    validate_metadata(source_public_view(cargo_source_view(value), allowed))
                elif kind:
                    value = source_json(data, member.name) if kind == "json" else parse_metadata(data, kind)
                    validate_metadata(source_metadata_view(source_public_view(value, allowed)))
                elif text is None:
                    if source_catalog(data, member.name):
                        counts["source_catalog_files"] = counts.get("source_catalog_files", 0) + 1
                        counts["source_archive_members"] = counts.get("source_archive_members", 0) + 1
                        continue
                    if member.name in fixtures:
                        counts["opaque_source_fixtures"] = counts.get("opaque_source_fixtures", 0) + 1
                        counts["opaque_binary_files"] += 1
                        counts["source_archive_members"] = counts.get("source_archive_members", 0) + 1
                        continue
                    raise PrivacyError("unreviewed-source-archive-binary")
                counts["source_archive_members"] = counts.get("source_archive_members", 0) + 1
        inspect_source_envelope(path)
    except (tarfile.TarError, OSError, EOFError, lzma.LZMAError, struct.error, RecursionError):
        raise PrivacyError("invalid-source-archive") from None
    if not seen:
        raise PrivacyError("empty-source-archive")
    if examples.keys() - seen:
        raise PrivacyError("missing-source-member-example")
    if fixtures.keys() - seen:
        raise PrivacyError("missing-opaque-source-fixture")
