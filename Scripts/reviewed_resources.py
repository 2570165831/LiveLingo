"""Exact, versioned release resources; never infer approval from a suffix.

All approvals are repository-owned and bound to the complete content hash.
Recognized representations are decoded without executing or unpickling them.
The ordinary metadata and entry policies still apply to everything else.
"""
import hashlib
import json
import os
import stat
from pathlib import Path, PurePosixPath
import re

if __package__:
    from .private_files import open_directory
    from .privacy_package import (PrivacyError, read_json, validate_metadata,
                                  decode_metadata_text, parse_metadata, metadata_kind,
                                  decode_license_text, JSON_LIMIT)
else:
    from private_files import open_directory
    from privacy_package import (PrivacyError, read_json, validate_metadata,
                                 decode_metadata_text, parse_metadata, metadata_kind,
                                 decode_license_text, JSON_LIMIT)


MANIFEST = Path(__file__).resolve().parent.parent / "Packaging/PrivacyResources.json"
RESOURCE_ROOT = "Contents/Resources/"


def entries():
    # Do not cache: an audit/packaging edit must immediately invalidate approval.
    # Hold a symlink-free directory handle instead of probing ancestors above
    # the caller's grant. Darwin checks every component in the kernel.
    try:
        with open_directory(MANIFEST.parent) as parent:
            descriptor = os.open(MANIFEST.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
                                 dir_fd=parent.fd)
            with os.fdopen(descriptor, "rb") as stream:
                before = os.fstat(stream.fileno())
                if not stat.S_ISREG(before.st_mode) or before.st_size > JSON_LIMIT:
                    raise PrivacyError("invalid-reviewed-resource-manifest")
                data = stream.read(JSON_LIMIT + 1)
                after = os.fstat(stream.fileno())
                if (len(data) > JSON_LIMIT or len(data) != before.st_size
                        or (before.st_size, before.st_mtime_ns, before.st_ctime_ns)
                        != (after.st_size, after.st_mtime_ns, after.st_ctime_ns)):
                    raise PrivacyError("invalid-reviewed-resource-manifest")
            parent.require_bound()
        value = parse_metadata(data, "json")
    except OSError:
        raise PrivacyError("invalid-reviewed-resource-manifest") from None
    if not isinstance(value, dict) or value.get("version") != 1 or not isinstance(value.get("resources"), list):
        raise PrivacyError("invalid-reviewed-resource-manifest")
    validate_metadata(value)
    result = {}
    for item in value["resources"]:
        if not isinstance(item, dict) or not all(isinstance(item.get(k), str) and item[k]
                                               for k in ("path", "sha256", "format", "package", "version", "reason")):
            raise PrivacyError("invalid-reviewed-resource-manifest")
        name = item["path"]
        path = PurePosixPath(name)
        if (not name.startswith(RESOURCE_ROOT) or path.is_absolute() or ".." in path.parts
                or str(path) != name or "\\" in name or name in result
                or not re.fullmatch(r"[0-9a-f]{64}", item["sha256"])):
            raise PrivacyError("invalid-reviewed-resource-manifest")
        result[name] = item
    return result


def tree_prefix(root):
    """Recognize the explicit staging layouts used by the unchanged bundler."""
    if (root / "runtime-manifest.json").is_file() and (root / "python/lib/python3.13").is_dir():
        return RESOURCE_ROOT + "LanguageRuntime/"
    if (root / "lib/python3.13/site-packages").is_dir() and (root / "bin/python3").is_file():
        return RESOURCE_ROOT + "ASRRuntime/python/"
    if (root / "mlx-community/parakeet-tdt-0.6b-v2/config.json").is_file():
        return RESOURCE_ROOT + "Models/"
    if (root.name == "parakeet-tdt-0.6b-v2" and root.parent.name == "mlx-community"
            and (root / "config.json").is_file()):
        # The unchanged bundler checks each model directory before copying it.
        return RESOURCE_ROOT + "Models/mlx-community/parakeet-tdt-0.6b-v2/"
    return ""


def schema_view(value):
    """A fragment-only JSON Pointer is a schema reference, not a host path."""
    if isinstance(value, dict):
        return {k: ("https://json-schema.invalid/" + v if k in ("$ref", "$recursiveRef", "$dynamicRef")
                    and isinstance(v, str) and re.fullmatch(r"(?:meta/(?:core|validation))?#(?:/.*)?", v)
                    else schema_view(v))
                for k, v in value.items()}
    if isinstance(value, list):
        return [schema_view(item) for item in value]
    return value


def public_example_spellings(examples, *, source_only=False):
    """Validate reviewed public spellings used only with exact file hashes."""
    if not isinstance(examples, list) or not examples:
        raise PrivacyError("invalid-reviewed-public-examples")
    allowed = []
    for example in examples:
        if not isinstance(example, dict) or set(example) != {"style", "path"} or not isinstance(example["path"], str):
            raise PrivacyError("invalid-reviewed-public-examples")
        value = example["path"]
        if value.startswith(("/", "\\")) or ".." in PurePosixPath(value.replace("\\", "/")).parts:
            raise PrivacyError("invalid-reviewed-public-examples")
        if example["style"] == "posix" and value.startswith(("home/", "opt/homebrew/", "usr/local/opt/")):
            allowed.append("/" + value)
        elif example["style"] == "windows" and value.startswith(("Users\\", "Documents and Settings\\")):
            allowed.extend(["C:\\" + value, "C:\\\\" + value.replace("\\", "\\\\")])
        elif example["style"] == "windows-url" and value.startswith("Users/"):
            allowed.append("/C:/" + value)
        elif example["style"] == "file-url-hex" and re.fullmatch(r"(?:[0-9a-f]{2}){1,4096}", value):
            try:
                spelling = bytes.fromhex(value).decode("utf-8")
            except UnicodeError:
                raise PrivacyError("invalid-reviewed-public-examples") from None
            if not re.fullmatch(r'file://[^\s"\'<>]+', spelling, re.I):
                raise PrivacyError("invalid-reviewed-public-examples")
            allowed.append(spelling)
        elif source_only and example["style"] == "rooted-package" and re.fullmatch(r"[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*", value):
            spelling = "/" + value
            scan_host_paths(spelling.encode(), source_code=True)
            allowed.append(spelling)
        elif source_only and example["style"] == "source-literal-hex" and re.fullmatch(r"(?:[0-9a-f]{2}){1,4096}", value):
            try:
                spelling = bytes.fromhex(value).decode("utf-8")
            except UnicodeError:
                raise PrivacyError("invalid-reviewed-public-examples") from None
            if not all(c.isprintable() for c in spelling):
                raise PrivacyError("invalid-reviewed-public-examples")
            scan_host_paths(spelling.encode(), source_code=True)
            allowed.append(spelling)
        elif source_only and example["style"] == "binary-readable-hex" and re.fullmatch(r"(?:[0-9a-f]{2}){1,16384}", value):
            if __package__:
                from .macho_paths import _exact_build_path_approvals
            else:
                from macho_paths import _exact_build_path_approvals
            # Source archives bind both complete archive and member hashes;
            # binary-member callers also require a review reason. No root or
            # prefix approval: this uses the native scanner's exact grammar.
            allowed.extend(_exact_build_path_approvals([bytes.fromhex(value)]))
        else:
            raise PrivacyError("invalid-reviewed-public-examples")
    return allowed


def inspect(path, relative, approvals, counts):
    item = approvals.get(relative)
    if item is None:
        return False
    if path.is_symlink():
        raise PrivacyError("reviewed-resource-symlink")
    with path.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    if digest != item["sha256"]:
        raise PrivacyError("reviewed-resource-hash-mismatch")
    data = path.read_bytes() if item["format"] != "source-tar" else b""
    kind = metadata_kind(data)
    if kind and item["format"] not in ("json-schema", "parakeet-config"):
        validate_metadata(parse_metadata(data, kind))
        raise PrivacyError("reviewed-resource-format-mismatch")
    if item["format"] == "json-schema":
        validate_metadata(schema_view(parse_metadata(data, "json")))
        counts["metadata_files"] += 1
    elif item["format"] == "parakeet-config":
        value = parse_metadata(data, "json")
        if not isinstance(value, dict) or not isinstance(value.get("joint"), dict):
            raise PrivacyError("invalid-reviewed-model-vocabulary")
        vocabulary = value["joint"].get("vocabulary")
        if not isinstance(vocabulary, list) or not vocabulary or not all(isinstance(v, str) for v in vocabulary):
            raise PrivacyError("invalid-reviewed-model-vocabulary")
        for token in vocabulary:
            scan_host_paths(token.encode("utf-8"))
        value = dict(value)
        if "labels" in value:
            if value["labels"] != vocabulary:
                raise PrivacyError("invalid-reviewed-model-vocabulary")
            value.pop("labels")  # The export's identical spelling mirror.
        value["joint"] = {k: v for k, v in value["joint"].items() if k != "vocabulary"}
        validate_metadata(value)
        counts["metadata_files"] += 1
    elif item["format"] in ("python-public-examples", "text-public-examples"):
        if __package__:
            from .privacy_text import inspect_text
        else:
            from privacy_text import inspect_text
        allowed = public_example_spellings(item.get("publicHostPathExamples"))
        inspect_text(data, path.name, allowed=allowed)
        counts["path_scanned_text_files"] = counts.get("path_scanned_text_files", 0) + 1
    elif item["format"] == "source-build-text":
        if __package__:
            from .source_archive import source_text
            from .privacy_literals import inspect_source_literals
        else:
            from source_archive import source_text
            from privacy_literals import inspect_source_literals
        text = source_text(data, path.name)
        if text is None:
            raise PrivacyError("invalid-reviewed-build-text")
        allowed = public_example_spellings(item["publicHostPathExamples"]) if "publicHostPathExamples" in item else []
        if __package__:
            from .privacy_text import scan_path_operands
        else:
            from privacy_text import scan_path_operands
        def scan(value):
            for public in allowed:
                value = value.replace(public, "PUBLIC_UPSTREAM_EXAMPLE")
            scan_path_operands(value)
        scan(text)
        inspect_source_literals(text, path.name, scan)
        counts["path_scanned_text_files"] = counts.get("path_scanned_text_files", 0) + 1
    elif item["format"] in ("lark-grammar", "css"):
        text = decode_metadata_text(data)
        if text is None:
            raise PrivacyError("invalid-reviewed-text-resource")
        # Block host paths before removing syntax that contains slash delimiters.
        scan_host_paths(data)
        if item["format"] == "css":
            for comment in re.findall(r"/\*(.*?)\*/", text, flags=re.S):
                inspect_comment(comment)
            text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
            validate_metadata(text)
        else:
            # Lark regular-expression terminals and // comments are not paths.
            # Still inspect quoted literals, including imports/resource names.
            inspect_lark_literals(text)
        counts["metadata_files"] += 1
    elif item["format"] == "numeric-msgpack":
        inspect_numeric_msgpack(data)
        counts["metadata_files"] += 1
    elif item["format"] == "source-tar":
        if __package__:
            from .source_archive import inspect_source_archive
        else:
            from source_archive import inspect_source_archive
        inspect_source_archive(path, item, counts)
    elif item["format"] == "macho-public-build-strings":
        if __package__:
            from .macho_paths import inspect_macho_paths
        else:
            from macho_paths import inspect_macho_paths
        examples = item.get("publicBuildPathsHex")
        if not isinstance(examples, list) or not examples:
            raise PrivacyError("invalid-macho-build-path-approval")
        allowed = []
        for value in examples:
            if not isinstance(value, str) or not re.fullmatch(r"(?:[0-9a-f]{2}){1,16384}", value):
                raise PrivacyError("invalid-macho-build-path-approval")
            allowed.append(bytes.fromhex(value))
        if not inspect_macho_paths(path, counts, allowed=allowed):
            raise PrivacyError("reviewed-resource-format-mismatch")
        with path.open("rb") as stream:
            if hashlib.file_digest(stream, "sha256").hexdigest() != item["sha256"]:
                raise PrivacyError("reviewed-resource-hash-mismatch")
    elif item["format"] == "notice-text":
        inspect_notice_text(path, data)
        counts["metadata_files"] += 1
    else:
        raise PrivacyError("unsupported-reviewed-resource-format")
    counts["reviewed_resource_files"] = counts.get("reviewed_resource_files", 0) + 1
    return True


def scan_host_paths(data, *, source_code=False):
    """Scan source/grammar bytes without confusing operators with metadata.

    Structured metadata additionally receives the existing recursive policy.
    These roots identify machine/user/build locations, unlike public source
    expressions such as system header includes or regular-expression slashes.
    """
    data = re.sub(rb"https?://[^\s\"<>]+", b"", data, flags=re.I)
    roots = (rb"(?:(?<![\w:/.])|(?<=-I)|(?<=-L)|(?<=\.\.))"
             rb"/(?:Users|Volumes|home|private/(?:tmp|var)|var/folders|opt/homebrew|usr/local/(?:Cellar|opt)|synthetic)/")
    # Public source may implement file:// and shell ~ expansion. Those syntax
    # tokens disclose no actual location; parsed metadata still rejects them.
    syntax = rb"[A-Za-z]:[/\\](?:Users|Documents and Settings)[/\\]"
    if not source_code:
        syntax = rb"file://|~[/\\]|" + syntax
    if (re.search(roots, data, re.I) or re.search(syntax, data, re.I)
            or re.search(rb"file:///+(?:Users|Volumes|home|private/(?:tmp|var)|synthetic)/", data, re.I)):
        raise PrivacyError("local-path-metadata")


def inspect_numeric_msgpack(data):
    """Decode librosa's numeric interval map with no third-party import.

    Only finite numeric keys and arrays of signed integer exponents are allowed.
    Strings, byte blobs, extensions, booleans and executable objects cannot hide
    metadata here. This deliberately is not a general MessagePack exemption.
    """
    import math
    import struct
    offset = 0

    def read(length):
        nonlocal offset
        chunk = data[offset:offset + length]
        if len(chunk) != length:
            raise PrivacyError("invalid-numeric-msgpack")
        offset += length
        return chunk

    def number(code):
        if code <= 0x7f:
            return code
        if code >= 0xe0:
            return code - 256
        formats = {0xca: (4, ">f"), 0xcb: (8, ">d"), 0xcc: (1, ">B"), 0xcd: (2, ">H"),
                   0xce: (4, ">I"), 0xcf: (8, ">Q"), 0xd0: (1, ">b"), 0xd1: (2, ">h"),
                   0xd2: (4, ">i"), 0xd3: (8, ">q")}
        if code not in formats:
            raise PrivacyError("invalid-numeric-msgpack")
        size, form = formats[code]
        result = struct.unpack(form, read(size))[0]
        if not math.isfinite(result):
            raise PrivacyError("invalid-numeric-msgpack")
        return result

    def value(depth=0):
        if depth > 8:
            raise PrivacyError("invalid-numeric-msgpack")
        code = read(1)[0]
        if 0x80 <= code <= 0x8f or code in (0xde, 0xdf):
            count = code & 0xf if code < 0x90 else int.from_bytes(read(2 if code == 0xde else 4), "big")
            if count > 100000:
                raise PrivacyError("invalid-numeric-msgpack")
            result = {}
            for _ in range(count):
                key, item = value(depth + 1), value(depth + 1)
                if not isinstance(key, (int, float)) or key in result:
                    raise PrivacyError("invalid-numeric-msgpack")
                result[key] = item
            return result
        if 0x90 <= code <= 0x9f or code in (0xdc, 0xdd):
            count = code & 0xf if code < 0xa0 else int.from_bytes(read(2 if code == 0xdc else 4), "big")
            if count > 100000:
                raise PrivacyError("invalid-numeric-msgpack")
            return [value(depth + 1) for _ in range(count)]
        return number(code)

    result = value()
    if offset != len(data) or not isinstance(result, dict):
        raise PrivacyError("invalid-numeric-msgpack")
    return result


def inspect_notice_text(path, data):
    """Inspect an exact upstream notice's representation, without rewriting it.

    Comment delimiters, HTML closing tags, RTF controls, public signature armor
    and Debian license identifiers are syntax, not machine paths. Any actual
    path outside those bounded representations still reaches validate_metadata.
    """
    if decode_license_text(path, data) is None:
        raise PrivacyError("invalid-reviewed-notice")
    scan_host_paths(data)
    try:
        text = data.rstrip(b"\0").decode("utf-8")
    except UnicodeError:
        text = data.rstrip(b"\0").decode("cp1252")
    if path.suffix.lower() == ".rtf":
        if not text.startswith("{\\rtf1") or re.search(r"\\(?:object|objdata|pict|bin|filetbl)(?![A-Za-z])", text):
            raise PrivacyError("invalid-reviewed-notice")
        text = re.sub(r"\\[a-zA-Z]+-?[0-9]* ?|\\[{}\\]", "", text)
    if path.suffix.lower() == ".html":
        from html.parser import HTMLParser

        class NoticeHTML(HTMLParser):
            def handle_starttag(self, tag, attrs):
                for _, value in attrs:
                    if value is not None:
                        validate_metadata(value)

            def handle_data(self, value):
                validate_metadata(value)

            def handle_comment(self, value):
                validate_metadata(value)
        parser = NoticeHTML(convert_charrefs=True)
        parser.feed(text)
        parser.close()
        return
    # Armor is a detached public author signature, not license prose. Decode it
    # as well so its bytes cannot hide machine paths after base64 conversion.
    import base64
    def armor(match):
        body = match[0].split("\n\n", 1)[-1].split("-----END", 1)[0]
        lines = [line for line in body.splitlines() if not line.startswith("=")]
        try:
            raw = base64.b64decode("".join(lines), validate=True)
        except ValueError:
            raise PrivacyError("invalid-reviewed-notice") from None
        scan_host_paths(raw)
        return ""
    text = re.sub(r"-----BEGIN PGP (?:PUBLIC KEY BLOCK|SIGNATURE|MESSAGE)-----.*?-----END PGP (?:PUBLIC KEY BLOCK|SIGNATURE|MESSAGE)-----", armor, text, flags=re.S)
    text = re.sub(r"^[ \t]*(?://|/\*+|\*+/|\*)", "", text, flags=re.M)
    text = re.sub(r"/\*+|\*+/", "", text)
    text = text.replace("CWI)/MIT", "CWI) and MIT")
    if path.name == "LICENSE.cpython.txt":
        text = re.sub(r"/MIT(?![A-Za-z0-9/])", "MIT", text)
    # This exact Debian identifier refers to a public standard license, not an
    # installation on the packaging machine. Keep its original bytes in output.
    text = re.sub(r"/usr/share/common-licenses/(Apache-2\.0|LGPL-2)(?![A-Za-z0-9./_-])",
                  r"https://www.debian.org/legal/licenses/\1", text)
    validate_metadata(text)


def inspect_lark_literals(text):
    """Lex literal strings separately from regex terminals and line comments."""
    offset = 0
    while offset < len(text):
        char = text[offset]
        if text.startswith("//", offset):
            end = text.find("\n", offset)
            inspect_comment(text[offset + 2:len(text) if end < 0 else end], grammar=True)
            offset = len(text) if end < 0 else end + 1
        elif char in "\"'":
            end = offset + 1
            while end < len(text):
                if text[end] == "\\":
                    end += 2
                elif text[end] == char:
                    break
                else:
                    end += 1
            if end >= len(text):
                raise PrivacyError("invalid-reviewed-grammar")
            literal = text[offset + 1:end]
            if literal not in ("/", "//", "/*", "*/"):
                validate_metadata(literal)
            offset = end + 1
        elif char == "/":
            end = offset + 1
            while end < len(text):
                if text[end] == "\\":
                    end += 2
                elif text[end] == "/":
                    break
                else:
                    end += 1
            if end >= len(text):
                raise PrivacyError("invalid-reviewed-grammar")
            offset = end + 1
        else:
            offset += 1


def inspect_comment(text, *, grammar=False):
    """Comment syntax cannot conceal parseable private metadata."""
    text = re.sub(r"^[ \t]*\*[ \t]?", "", text, flags=re.M).strip()
    data = text.encode("utf-8")
    kind = metadata_kind(data)
    if kind:
        validate_metadata(parse_metadata(data, kind))
    elif grammar:
        scan_host_paths(data)
        # This grammar documents a terminal as "float = /regex/". Restrict
        # syntax handling to that complete equation; ordinary comments retain
        # the same recursive text/path checks, including public URL handling.
        text = re.sub(r"^(\s*[A-Za-z_]\w*\s*=\s*)/(?:\\.|[^/\n])+/[a-z]*\s*$",
                      r"\1REGEX", text)
        validate_metadata(text)
    else:
        validate_metadata(text)
