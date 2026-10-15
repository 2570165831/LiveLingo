"""Read leading source notices without importing or executing their source.

This module does not decide what to prune or write any files. The caller must
collect notices before deleting sources, then save each returned ``data`` under
a safe relative name. Package membership comes from the caller's locked RECORD
selection, never from the active Python environment.
"""
from collections.abc import Callable, Collection, Iterable
from dataclasses import dataclass
import hashlib
from pathlib import PurePath, PurePosixPath
import re


# Bound comment scanning, not source-file size: a short notice on a large source
# remains eligible. An unfinished/overlong header is never returned truncated.
MAX_HEADER_BYTES = 128 * 1024
_SPACE = b" \t\r\n\f"
_BLOCKS = ((b"/*", b"*/"), (b"<!--", b"-->"), (b"{#", b"#}"),
           (b"<%--", b"--%>"), (b"<%doc>", b"</%doc>"),
           (b"{% comment %}", b"{% endcomment %}"))
_DIRECTIVE = re.compile(
    rb"#[ \t]*(?:include(?:_next)?|define|undef|if|ifdef|ifndef|elif|else|endif|"
    rb"pragma|error|warning|line|import)\b")
_NOTICE = re.compile(
    rb"\bcopyright\b|\bSPDX-(?:License-Identifier|FileCopyrightText)[ \t]*:|"
    rb"\blicen[sc](?:e|ed|ing)\b|\ball rights reserved\b|"
    rb"\bpermission is hereby granted\b|\bredistribution and use\b|"
    rb"\bpublic domain\b", re.IGNORECASE)


def _text(data: bytes) -> bool:
    """Accept UTF-8 and legacy single-byte source comments, reject controls."""
    if any(byte < 32 and byte not in _SPACE for byte in data) or b"\x7f" in data:
        return False
    try:
        text = data.decode("utf-8-sig")
    except UnicodeDecodeError:
        text = data.decode("latin-1")
    return all(char.isprintable() or char in " \t\r\n\f" for char in text)


def extract_notice(data: bytes) -> bytes | None:
    """Return an exact byte prefix containing a leading legal comment region.

    Recognizes C block/line comments, Python/Cython ``#``, Fortran ``!`` and
    fixed-column ``C/c/*`` comments, and common template comment delimiters.
    Blank lines and consecutive comment blocks belong to the same region, so
    separated BSD clauses and human modification credits are kept together.
    A BOM, shebang and encoding comment in that region are preserved verbatim.

    Stop at the first source token, including C preprocessor directives; never
    search code or docstrings for a later notice. Only bounded, complete text
    comments qualify. UTF-16, binary and malformed leading comments yield None.
    This is a conservative header extractor, not a license classifier or a
    parser for commented-out programs.
    """
    sample = data[:8192]
    if any(byte < 32 and byte not in _SPACE or byte == 127 for byte in sample):
        return None
    prefix = data[:MAX_HEADER_BYTES + 1]
    pos = 3 if prefix.startswith(b"\xef\xbb\xbf") else 0
    end = 0
    family = None
    while pos < len(prefix):
        while pos < len(prefix) and prefix[pos] in _SPACE:
            pos += 1
        if pos >= len(prefix):
            break
        block = next(((opening, closing) for opening, closing in _BLOCKS
                      if prefix.startswith(opening, pos)), None)
        if block:
            opening, closing = block
            block_family = "c" if opening == b"/*" else "template"
            if family is not None and family != block_family:
                break
            family = block_family
            close = prefix.find(closing, pos + len(opening))
            if close < 0:
                return None
            pos = close + len(closing)
            # Include the original spaces and line ending after a block, but
            # never a source token on the same line.
            tail = pos
            while tail < len(prefix) and prefix[tail] in b" \t\r":
                tail += 1
            if tail < len(prefix) and prefix[tail:tail + 1] == b"\n":
                pos = tail + 1
        else:
            line_start = prefix.rfind(b"\n", 0, pos) + 1
            # Fixed-form Fortran markers must really be in column one. Reject
            # the obvious assignment spelling, which can be source in Python.
            fixed_fortran = (family in (None, "fortran") and pos == line_start
                             and prefix[pos:pos + 1] in (b"C", b"c", b"*")
                             and prefix[pos + 1:pos + 2] in (b" ", b"\t", b"\r", b"\n", b"")
                             and not prefix[pos + 1:].lstrip(b" \t").startswith(b"="))
            slash = family in (None, "c") and prefix.startswith(b"//", pos)
            hash_comment = (family in (None, "hash") and prefix.startswith(b"#", pos)
                            and not _DIRECTIVE.match(prefix, pos))
            bang = family in (None, "fortran") and prefix.startswith(b"!", pos)
            if not (slash or hash_comment or fixed_fortran or bang):
                break
            family = "c" if slash else "hash" if hash_comment else "fortran"
            close = prefix.find(b"\n", pos)
            pos = len(prefix) if close < 0 else close + 1
        if pos > MAX_HEADER_BYTES:
            return None
        end = pos
    if not end or end > MAX_HEADER_BYTES:
        return None
    notice = data[:end]
    return notice if _text(notice) and _NOTICE.search(notice) else None


@dataclass(frozen=True)
class EmbeddedNotice:
    """Bytes to save plus portable provenance; no absolute source locations."""

    source: str
    source_sha256: str
    notice_sha256: str
    data: bytes


def _relative(value: str | PurePath) -> PurePosixPath:
    raw = str(value)
    path = PurePosixPath(raw)
    if (not raw or path.is_absolute() or "\\" in raw or ":" in raw
            or any(part in ("", ".", "..") for part in raw.split("/"))
            or any(ord(char) < 32 or ord(char) == 127 for char in raw)):
        raise ValueError("embedded-notice-path-must-be-safe-relative")
    return path


def collect_notices(
    removed_paths: Iterable[str | PurePath],
    read_bytes: Callable[[str], bytes],
    *,
    stdlib: str | PurePath,
    selected_files: Collection[str | PurePath],
) -> list[EmbeddedNotice]:
    """Collect removed notices, excluding unselected site-packages files.

    ``removed_paths`` and callback paths are runtime-root relative; stdlib is
    typically ``lib/python3.13``. ``selected_files`` contains exact site-packages
    relative RECORD paths, including selected sources that will be pruned.
    Tests, examples and all file suffixes are covered. Unselected package files
    are excluded before reading; all other listed removed paths are eligible.
    The callback must read regular files inside the input root without following
    symlinks. Exceptions propagate: missing/unreadable inputs are not silently
    counted as having no notice. This helper performs no filesystem operations.
    """
    library = _relative(stdlib)
    site = library / "site-packages"
    selected = {_relative(path) for path in selected_files}
    removed = sorted({_relative(path) for path in removed_paths})
    results = []
    for path in removed:
        if path.is_relative_to(site):
            if path.relative_to(site) not in selected:
                continue
        data = read_bytes(path.as_posix())
        notice = extract_notice(data)
        if notice is not None:
            results.append(EmbeddedNotice(
                source=path.as_posix(), source_sha256=hashlib.sha256(data).hexdigest(),
                notice_sha256=hashlib.sha256(notice).hexdigest(), data=notice))
    return results
