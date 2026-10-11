"""Create a deterministic corresponding-source subset; keep originals elsewhere.

The selected libraries' implementation and build inputs are retained. Unrelated
upstream tests, compiler frontends, documentation, CI and platform IDE payloads
are omitted. A member inventory records every omission and comment redaction.
This is static source preparation, not proof of a byte-identical rebuild.
"""
import bz2
import gzip
import hashlib
import io
import lzma
from pathlib import Path, PurePosixPath
import re
import tarfile

if __package__:
    from .privacy_package import PrivacyError, license_filename
else:
    from privacy_package import PrivacyError, license_filename


def omission(name, package):
    path = PurePosixPath(name)
    if license_filename(Path(path.name)):
        return None
    if any(part.lower() in ("tests", "test", "testsuite", "testdata", "snapshots", ".github",
                            "doc", "docs", "documentation", "examples") for part in path.parts[1:]):
        return "upstream-tests-docs-examples-ci"
    if path.name.startswith("ChangeLog") or path.name.endswith("_test.go") or path.name.startswith("testcase."):
        return "upstream-history-or-test-fixture"
    if (any(part in ("maintainer-scripts", "man1") for part in path.parts[1:])
            or path.name.upper() in ("NEWS", "README", "README.MD", "README.RST", "README.TXT")):
        return "upstream-maintenance-or-documentation"
    if package == "gcc" and (path.parts[1:2] in (("libgo",), ("libada",), ("gnattools",), ("gotools",))
                             or path.parts[1:3] in (("gcc", "ada"), ("gcc", "go"), ("gcc", "m2"), ("gcc", "rust"))):
        return "unbundled-language-components"
    if package == "gcc" and (path.parts[1:3] == ("zlib", "contrib")
                             or path.suffix.lower() in (".gmo", ".mo", ".pdf", ".dvi")
                             or re.search(r"\.info(?:-[0-9]+)?$", path.name)):
        return "unbundled-extensions-or-generated-documentation-catalogs"
    if package == "lame" and (path.parts[1:2] in (("mac",), ("dshow",), ("ACM",), ("vc_solution",))
                              or path.suffix.lower() == ".ico"):
        return "unbundled-platform-ide-or-icon"
    if path.name in (".DS_Store", ".codecov.yml"):
        return "upstream-platform-or-ci-metadata"
    return None


def redact_comment_examples(data):
    """Remove user-path examples only in entire // comment lines; no code edits."""
    lines = data.splitlines(keepends=True)
    changed = 0
    roots = rb"/(?:Users|Volumes|home)/[^\s\"<>]+"
    for index, line in enumerate(lines):
        content = line.lstrip()
        if (content.startswith((b"//", b"dnl ")) or
                re.match(rb"#\s+(?!include\b|define\b|if\b|elif\b|else\b|endif\b|error\b|pragma\b|undef\b)", content)):
            clean, count = re.subn(roots, b"USER_HOME/example", line)
            if count:
                lines[index] = clean
                changed += count
    return b"".join(lines), changed


def redact_c_block_examples(data):
    """Change only C/C++ block-comment examples; quoted strings stay intact."""
    offset = 0
    result = []
    changes = 0
    roots = rb"/(?:Users|Volumes|home)/[^\s\"<>]+"
    next_syntax = re.compile(rb'(?:u8|u|U|L)?R"|["\']|//|/\*')
    raw_string = re.compile(rb'(?:u8|u|U|L)?R"([^()\s]{0,16})\(')
    while offset < len(data):
        found = next_syntax.search(data, offset)
        if found is None:
            result.append(data[offset:])
            break
        if found.start() > offset:
            result.append(data[offset:found.start()])
            offset = found.start()
        raw = raw_string.match(data, offset)
        if raw:
            ending = b")" + raw[1] + b'"'
            end = data.find(ending, offset + len(raw[0]))
            if end < 0:
                raise PrivacyError("unrecognized-source-comment-layout")
            end += len(ending)
        elif data[offset] in (34, 39):
            quote = data[offset]
            end = offset + 1
            while end < len(data) and data[end] != quote:
                end += 2 if data[end] == 92 else 1
            end = min(end + 1, len(data))
        elif data.startswith(b"//", offset):
            end = data.find(b"\n", offset)
            end = len(data) if end < 0 else end + 1
        elif data.startswith(b"/*", offset):
            end = data.find(b"*/", offset + 2)
            if end < 0:
                raise PrivacyError("unrecognized-source-comment-layout")
            end += 2
            clean, count = re.subn(roots, b"USER_HOME/example", data[offset:end])
            result.append(clean)
            changes += count
            offset = end
            continue
        else:
            end = offset + 1
        result.append(data[offset:end])
        offset = end
    return b"".join(result), changes


def omit_trailing_rust_tests(data, name):
    """A trailing cfg(test) module does not enter the distributed library build."""
    if not name.endswith(".rs"):
        return data, False
    marker = b"#[cfg(test)]\nmod tests {"
    if marker not in data:
        return data, False
    def tokens():
        offset = 0
        while offset < len(data):
            if data.startswith(b"//", offset):
                end = data.find(b"\n", offset)
                offset = len(data) if end < 0 else end + 1
            elif data.startswith(b"/*", offset):
                depth = 1
                offset += 2
                while offset < len(data) and depth:
                    if data.startswith(b"/*", offset):
                        depth += 1
                        offset += 2
                    elif data.startswith(b"*/", offset):
                        depth -= 1
                        offset += 2
                    else:
                        offset += 1
                if depth:
                    raise PrivacyError("unrecognized-inline-test-layout")
            else:
                raw = re.match(rb'(?:b)?r(#+)?"', data[offset:])
                if raw and (offset == 0 or not chr(data[offset - 1]).isalnum()):
                    ending = b'"' + (raw[1] or b"")
                    end = data.find(ending, offset + len(raw[0]))
                    if end < 0:
                        raise PrivacyError("unrecognized-inline-test-layout")
                    offset = end + len(ending)
                elif data[offset] == 34:
                    offset += 1
                    while offset < len(data) and data[offset] != 34:
                        offset += 2 if data[offset] == 92 else 1
                    if offset >= len(data):
                        raise PrivacyError("unrecognized-inline-test-layout")
                    offset += 1
                else:
                    char = re.match(rb"'(?:\\(?:u\{[0-9A-Fa-f]+\}|x[0-9A-Fa-f]{2}|.)|[^'\\])'", data[offset:])
                    if char:
                        offset += len(char[0])
                    else:
                        yield offset, data[offset]
                        offset += 1
    sequence = tokens()
    for index, _ in sequence:
        if not data.startswith(marker, index):
            continue
        opening = index + len(marker) - 1
        depth = 0
        for position, char in sequence:
            if position < opening:
                continue
            if char == 123:
                depth += 1
            elif char == 125:
                depth -= 1
                if depth == 0:
                    # A later production item must never be dropped.
                    if data[position + 1:].strip():
                        return data, False
                    return data[:index], True
        raise PrivacyError("unrecognized-inline-test-layout")
    return data, False


def prepare(source, destination, package, version, additions=()):
    source, destination = Path(source), Path(destination)
    if source.is_symlink() or not source.is_file() or destination.exists() or destination.is_symlink():
        raise PrivacyError("invalid-source-archive-preparation-path")
    if any(p.is_symlink() for p in [destination.parent, *destination.parent.parents]):
        raise PrivacyError("symlink-destination-parent")
    with source.open("rb") as stream:
        original = hashlib.file_digest(stream, "sha256").hexdigest()
    root = package + "-" + version
    omitted, redacted, retained, license_hashes = [], [], [], {}
    destination.parent.mkdir(parents=True, exist_ok=True)
    raw_output = destination.open("wb")
    if destination.name.endswith(".xz"):
        compressed = lzma.LZMAFile(raw_output, "w", preset=0)
    elif destination.name.endswith(".bz2"):
        compressed = bz2.BZ2File(raw_output, "w")
    else:
        compressed = gzip.GzipFile(filename="", mode="wb", fileobj=raw_output, mtime=0)
    with raw_output, compressed, tarfile.open(fileobj=compressed, mode="w|", format=tarfile.PAX_FORMAT) as output:
        def emit(name, data, mode):
            member = tarfile.TarInfo(name)
            member.size = len(data)
            member.mode = 0o755 if mode & 0o111 else 0o644
            member.uid = member.gid = member.mtime = 0
            member.uname = member.gname = ""
            output.addfile(member, io.BytesIO(data))

        with tarfile.open(source, "r|*") as archive:
            for member in archive:
                path = PurePosixPath(member.name)
                if path.is_absolute() or ".." in path.parts or not path.parts or path.parts[0] != root:
                    raise PrivacyError("invalid-source-archive-path")
                if member.isdir():
                    continue
                if not member.isfile():
                    raise PrivacyError("unsupported-source-archive-member")
                reason = omission(member.name, package)
                if reason:
                    omitted.append({"path": member.name, "reason": reason})
                    continue
                data = archive.extractfile(member).read()
                if license_filename(Path(member.name)):
                    license_hashes[member.name] = hashlib.sha256(data).hexdigest()
                if license_filename(Path(member.name)):
                    clean, changes, tests_removed = data, 0, False
                else:
                    clean, changes = redact_comment_examples(data)
                    if Path(member.name).suffix in (".c", ".cc", ".cpp", ".h", ".hpp"):
                        clean, extra = redact_c_block_examples(clean)
                        changes += extra
                    clean, tests_removed = omit_trailing_rust_tests(clean, member.name)
                if tests_removed:
                    omitted.append({"path": member.name, "reason": "trailing-cfg-test-module-only"})
                if changes:
                    redacted.append({"path": member.name, "commentExamples": changes,
                                     "originalSHA256": hashlib.sha256(data).hexdigest()})
                emit(member.name, clean, member.mode)
                retained.append({"path": member.name, "sha256": hashlib.sha256(clean).hexdigest()})
        for source_file, relative in additions:
            source_file = Path(source_file)
            if source_file.is_symlink() or not source_file.is_file():
                raise PrivacyError("invalid-source-build-addition")
            name = root + "/release-build/" + relative
            data = source_file.read_bytes()
            emit(name, data, source_file.stat().st_mode)
            retained.append({"path": name, "sha256": hashlib.sha256(data).hexdigest()})
    with destination.open("rb") as stream:
        prepared_hash = hashlib.file_digest(stream, "sha256").hexdigest()
    return {"package": package, "version": version, "originalSHA256": original,
            "preparedSHA256": prepared_hash,
            "retainedFiles": len(retained), "omitted": omitted, "redactedComments": redacted,
            "originalLicenseHashes": license_hashes,
            "retainedInventorySHA256": hashlib.sha256(str(retained).encode()).hexdigest()}
