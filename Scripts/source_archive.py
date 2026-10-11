"""Inspect reviewed corresponding-source tar members without extracting them."""
from pathlib import Path, PurePosixPath
import hashlib
import base64
import json
import re
import unicodedata
import tarfile

if __package__:
    from .privacy_package import (PrivacyError, JSON_LIMIT, decode_metadata_text,
                                  metadata_kind, parse_metadata, validate_metadata, known_binary,
                                  CONTENT_NAMES, CONTENT_SUFFIXES)
    from .reviewed_resources import scan_host_paths, public_example_spellings
    from .privacy_literals import inspect_source_literals
else:
    from privacy_package import (PrivacyError, JSON_LIMIT, decode_metadata_text,
                                 metadata_kind, parse_metadata, validate_metadata, known_binary,
                                 CONTENT_NAMES, CONTENT_SUFFIXES)
    from reviewed_resources import scan_host_paths, public_example_spellings
    from privacy_literals import inspect_source_literals


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


def source_public_view(value, allowed):
    """Preserve all metadata rules while neutralizing exact approved spellings."""
    if isinstance(value, str):
        for public in sorted(allowed, key=len, reverse=True):
            if public == "/":
                if value == public:
                    value = "PUBLIC_UPSTREAM_EXAMPLE"
                continue  # A documentation root token must not mask other paths.
            value = value.replace(public, "PUBLIC_UPSTREAM_EXAMPLE")
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
        if Path(name).suffix in (".c", ".cc", ".cpp", ".C", ".h", ".hpp", ".inc"):
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
                if not member.isfile() or member.size > JSON_LIMIT:
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
                if known_binary(Path(member.name), data[:4096], len(data)):
                    counts["opaque_binary_files"] += 1
                    counts["source_archive_members"] = counts.get("source_archive_members", 0) + 1
                    continue
                text = source_text(data, member.name)
                if text is not None:
                    plain = "".join(c for c in text if unicodedata.category(c) != "Cf")
                    def check(value):
                        value = "".join(c for c in value if unicodedata.category(c) != "Cf")
                        scan_host_paths(source_public_view(value, allowed).encode("utf-8", errors="surrogatepass"), source_code=True)
                    check(plain)
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
    except (tarfile.TarError, OSError, EOFError):
        raise PrivacyError("invalid-source-archive") from None
    if not seen:
        raise PrivacyError("empty-source-archive")
    if examples.keys() - seen:
        raise PrivacyError("missing-source-member-example")
    if fixtures.keys() - seen:
        raise PrivacyError("missing-opaque-source-fixture")
