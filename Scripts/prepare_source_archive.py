"""Create a deterministic corresponding-source subset; keep originals elsewhere.

Build inputs (including manuals, documentation and Automake test includes) are
retained before considering explicitly optional payloads. A member inventory
and in-archive modification notice record changes. Rebuild checks are separate;
this preparer does not prove a byte-identical rebuild.
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


BUILD_SUFFIXES = frozenset({".am", ".in", ".m4", ".mk", ".cmake", ".texi", ".tex",
                            ".pod", ".1", ".3", ".info", ".def", ".map", ".opt"})
BUILD_NAMES = frozenset({"configure", "configure.ac", "configure.in", "Makefile", "Makefile.in",
                         "Makefile.am", "CMakeLists.txt", "meson.build", "Cargo.toml", "Cargo.lock"})
OPTIONAL_FILES = {
    "lame": {"testcase.wav", "testcase.mp3", "mac/LAME.mcp"},
    "mpg123": {"src/tests/sweep.mp3"},
    "flac": {"test/metaflac.flac.in", "test/metaflac.flac.ok", "test/metaflac-test-files/case65-expect.meta"},
}


def omission(name, package):
    path = PurePosixPath(name)
    if license_filename(Path(path.name)):
        return None
    relative = PurePosixPath(*path.parts[1:]).as_posix()
    if relative in OPTIONAL_FILES.get(package, set()):
        return "optional-binary-regression-or-legacy-ide-input"
    if package == "gcc" and (path.parts[1:2] in (("libgo",), ("libada",), ("gnattools",), ("gotools",))
                             or path.parts[1:3] in (("gcc", "ada"), ("gcc", "go"), ("gcc", "m2"), ("gcc", "rust"),
                                                    ("gcc", "d"), ("gcc", "jit"), ("gcc", "objc"), ("gcc", "objcp"))):
        return "unbundled-language-components"
    if (path.name in BUILD_NAMES or path.suffix in BUILD_SUFFIXES
            or re.search(r"\.info-[0-9]+$", path.name)):
        return None
    if package == "flac" and (path.parts[1:3] in (("test", "foreign-metadata-test-files"),
                                                 ("test", "flac-to-flac-metadata-test-files"))):
        return "optional-audio-regression-fixture"
    if path.parts[1:2] == (".github",) or path.name in (".DS_Store", ".codecov.yml"):
        return "upstream-platform-or-ci-metadata"
    if package == "gcc" and any(part == "testsuite" for part in path.parts[1:]):
        return "optional-compiler-regression-input"
    if package == "gcc" and path.parts[1:3] == ("zlib", "contrib"):
        return "optional-zlib-contributed-programs"
    if package == "gcc" and path.parts[1:2] in (("maintainer-scripts",), ("contrib",)):
        return "optional-upstream-release-or-regression-maintenance"
    if (package == "gcc" and path.parts[1:4] == ("libstdc++-v3", "doc", "xml")
            and path.suffix.lower() in (".xml", ".pdf")):
        return "optional-libstdcxx-supplementary-docbook-publication"
    if package == "libvorbis" and path.suffix.lower() == ".pdf":
        return "optional-prerendered-specification"
    if path.name.startswith("ChangeLog"):
        return "optional-upstream-history"
    if package == "lame" and path.suffix.lower() == ".ico":
        return "optional-platform-icon"
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
    omitted, redacted, retained, license_hashes, modifications = [], [], [], {}, []
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
                    clean, changes = ((data, 0) if re.search(r"\.info(?:-[0-9]+)?$", path.name)
                                      else redact_comment_examples(data))
                    if Path(member.name).suffix in (".c", ".cc", ".cpp", ".h", ".hpp"):
                        clean, extra = redact_c_block_examples(clean)
                        changes += extra
                # Preserve inline Rust tests. Only this public Windows fixture
                # needs its home-directory example made neutral; production
                # code and the complete test module remain present.
                if package == "inferno" and path.parts[1:] == ("src", "flamegraph", "color", "palettes.rs"):
                    clean, count = re.subn(re.escape(b"C:/" + b"Users/User/AppData/Local/Programs/"), b'C:/Public/Programs/', clean)
                    changes += count
                    escaped = b"C:\\\\" + b"Users\\\\User\\\\AppData\\\\Local\\\\Programs\\\\"
                    clean, count = re.subn(re.escape(escaped), lambda match: b"C:\\\\Public\\\\Programs\\\\", clean)
                    changes += count
                # Documentation examples and exporter metadata do not enter
                # compiled code. GNU Info offsets must keep their original
                # positions, so replacements there have exactly equal length.
                document = (any(part in ("doc", "docs") for part in path.parts[1:])
                            or path.name.startswith("README"))
                info = bool(re.search(r"\.info(?:-[0-9]+)?$", path.name))
                if (document or info) and not license_filename(Path(member.name)):
                    def neutral(match):
                        return (b"EXAMPLE" + b"_" * (len(match[0]) - 7)) if info else b"UPSTREAM_HOME/example"
                    # Markup entities delimit escaped tags as surely as '<'.
                    # In HTML/XML stop before an entity rather than swallowing
                    # the escaped closing tag into a home-path replacement.
                    markup = path.suffix.lower() in (".html", ".htm", ".xml")
                    roots = (rb"/(?:Users|Volumes|home)/[^\s\"<>&]+" if markup
                             else rb"/(?:Users|Volumes|home)/[^\s\"<>]+")
                    clean, count = re.subn(roots, neutral, clean)
                    changes += count
                if changes:
                    description = b"Modified by Li on 2026-10-11: neutralize upstream home-path examples; see MODIFICATIONS.json."
                    if info:
                        clean += b"\n" + description + b"\n"
                    elif path.suffix == ".texi":
                        clean = b"@c " + description + b"\n" + clean
                    elif (path.suffix.lower() in (".man", ".roff")
                          or re.fullmatch(r"\.[1-9][A-Za-z]*", path.suffix)):
                        clean = b'.\\" ' + description + b"\n" + clean
                    elif clean.lstrip().startswith(b"<?xml") or path.suffix == ".html":
                        # XML declarations must stay at the beginning.
                        notice = b"<!-- " + description + b" -->\n"
                        if clean.startswith(b"<?xml"):
                            end = clean.find(b"?>") + 2
                            clean = clean[:end] + b"\n" + notice + clean[end:]
                        else:
                            clean = notice + clean
                    else:
                        syntax = b"//" if path.suffix in (".c", ".cc", ".cpp", ".h", ".hpp", ".rs") else b"#"
                        notice = syntax + b" " + description + b"\n"
                        if clean.startswith(b"#!"):
                            first, rest = clean.split(b"\n", 1)
                            clean = first + b"\n" + notice + rest
                        else:
                            clean = notice + clean
                    redacted.append({"path": member.name, "commentExamples": changes,
                                     "originalSHA256": hashlib.sha256(data).hexdigest()})
                    modifications.append({"path": member.name, "date": "2026-10-11", "contributor": "Li",
                        "change": "Neutralize public upstream home-path examples; retain code and inline test modules.",
                        "reason": "Distribution privacy policy; no build-machine locations in source copies.",
                        "originalSHA256": hashlib.sha256(data).hexdigest(),
                        "preparedSHA256": hashlib.sha256(clean).hexdigest()})
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
        import json
        from collections import Counter
        notice = {"package": package, "version": version, "date": "2026-10-11", "contributor": "Li",
                  "policy": "Retain build sources, generated manuals, documentation and build scripts. Only explicitly optional payloads are omitted; original license bytes are preserved. Archive ownership and timestamps are normalized.",
                  "modified": modifications, "omittedCount": len(omitted),
                  "omissionReasons": dict(Counter(item["reason"] for item in omitted)),
                  "omittedInventorySHA256": hashlib.sha256(json.dumps(omitted, sort_keys=True).encode()).hexdigest(),
                  "added": ["release-build/" + relative for _, relative in additions]}
        data = (json.dumps(notice, indent=2) + "\n").encode()
        emit(root + "/MODIFICATIONS.json", data, 0o644)
        retained.append({"path": root + "/MODIFICATIONS.json", "sha256": hashlib.sha256(data).hexdigest()})
    with destination.open("rb") as stream:
        prepared_hash = hashlib.file_digest(stream, "sha256").hexdigest()
    return {"package": package, "version": version, "originalSHA256": original,
            "preparedSHA256": prepared_hash,
            "retainedFiles": len(retained), "omitted": omitted, "redactedComments": redacted,
            "modified": modifications, "modificationNotice": root + "/MODIFICATIONS.json",
            "originalLicenseHashes": license_hashes,
            "retainedInventorySHA256": hashlib.sha256(str(retained).encode()).hexdigest()}
