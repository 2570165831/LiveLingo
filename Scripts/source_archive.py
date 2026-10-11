"""Inspect reviewed corresponding-source tar members without extracting them."""
from pathlib import Path, PurePosixPath
import re
import unicodedata
import tarfile

if __package__:
    from .privacy_package import (PrivacyError, JSON_LIMIT, decode_metadata_text,
                                  metadata_kind, parse_metadata, validate_metadata, known_binary,
                                  CONTENT_NAMES, CONTENT_SUFFIXES)
    from .reviewed_resources import scan_host_paths
else:
    from privacy_package import (PrivacyError, JSON_LIMIT, decode_metadata_text,
                                 metadata_kind, parse_metadata, validate_metadata, known_binary,
                                 CONTENT_NAMES, CONTENT_SUFFIXES)
    from reviewed_resources import scan_host_paths


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
    if Path(name).suffix not in (".mo", ".gmo") or len(data) < 28:
        return False
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


def inspect_source_xml(data):
    """Inspect XML source/build markup without resolving DTDs or entities online.

    Source substitutions and C++ header references are relative build syntax.
    All other attributes, text, comments and literal entity declarations retain
    the metadata policy. External declarations are inspected, never fetched.
    """
    from xml.parsers.expat import ParserCreate, ExpatError
    def value(text, field=None):
        if text is None:
            return
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
        text = re.sub(r"(?:\$\([A-Za-z_][A-Za-z0-9_]*\)|@[A-Za-z_][A-Za-z0-9_]*@)/",
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
                scan_host_paths(text.encode(), source_code=True)
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
    try:
        with tarfile.open(path, "r|*") as archive:
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
                scan_host_paths(data, source_code=True)
                text = source_text(data, member.name)
                if text is not None:
                    plain = "".join(c for c in text if unicodedata.category(c) != "Cf")
                    scan_host_paths(plain.encode("utf-8"), source_code=True)
                kind = metadata_kind(data)
                if name.suffix.lower() in (".yaml", ".yml"):
                    raise PrivacyError("unsupported-source-archive-metadata")
                xml_source = (data.lstrip().startswith(b"<?xml") and b"<plist" not in data[:1024]
                              or (kind != "plist" and name.suffix.lower() in (".xml", ".vcproj", ".vsprops", ".svg", ".tag")))
                if xml_source:
                    inspect_source_xml(data)
                elif name.suffix == ".toml" or name.name == "Cargo.lock":
                    import tomllib
                    try:
                        value = tomllib.loads(data.decode("utf-8"))
                    except (UnicodeError, ValueError):
                        raise PrivacyError("invalid-source-archive-metadata") from None
                    validate_metadata(cargo_source_view(value))
                elif kind:
                    validate_metadata(parse_metadata(data, kind))
                elif text is None:
                    if source_catalog(data, member.name):
                        counts["source_catalog_files"] = counts.get("source_catalog_files", 0) + 1
                        counts["source_archive_members"] = counts.get("source_archive_members", 0) + 1
                        continue
                    if not known_binary(Path(member.name), data[:4096], len(data)):
                        raise PrivacyError("unreviewed-source-archive-binary")
                    counts["opaque_binary_files"] += 1
                counts["source_archive_members"] = counts.get("source_archive_members", 0) + 1
    except (tarfile.TarError, OSError, EOFError):
        raise PrivacyError("invalid-source-archive") from None
    if not seen:
        raise PrivacyError("empty-source-archive")
