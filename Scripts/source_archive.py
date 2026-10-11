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
        allowed = "\x07\x08\x1b" if (Path(name).suffix in (".rs", ".sh", ".in", ".nas", ".c", ".cc", ".cpp", ".h", ".hpp")
                                  or Path(name).name in ("configure", "test-driver")) else ""
        if Path(name).suffix == ".info":
            allowed += "\x1f"
        if all(c.isprintable() or c.isspace() or c in allowed or unicodedata.category(c) == "Cf" for c in text):
            return text
    return None


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
                if name.suffix.lower() == ".xml" and kind != "plist":
                    import xml.etree.ElementTree as xml
                    if re.search(rb"<!DOCTYPE|<!ENTITY", data, re.I):
                        raise PrivacyError("invalid-source-archive-metadata")
                    try:
                        document = xml.fromstring(data)
                    except xml.ParseError:
                        raise PrivacyError("invalid-source-archive-metadata") from None
                    for node in document.iter():
                        validate_metadata(node.attrib)
                        validate_metadata(node.text or "")
                        validate_metadata(node.tail or "")
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
                    if not known_binary(Path(member.name), data[:4096], len(data)):
                        raise PrivacyError("unreviewed-source-archive-binary")
                    counts["opaque_binary_files"] += 1
                counts["source_archive_members"] = counts.get("source_archive_members", 0) + 1
    except (tarfile.TarError, OSError, EOFError):
        raise PrivacyError("invalid-source-archive") from None
    if not seen:
        raise PrivacyError("empty-source-archive")
