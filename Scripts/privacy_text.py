"""Scan ordinary text and identified source literals without executing input."""
import ast
import io
import re
import tokenize
import unicodedata
from urllib.parse import unquote, urlsplit
import warnings

try:
    from .privacy_package import PrivacyError, decode_metadata_text
    from .reviewed_resources import scan_host_paths
    from .privacy_literals import PYTHON_SOURCE_SUFFIXES, inspect_source_literals, source_format, unc_source_view
    from .privacy_roots import PublicRegexSpelling, PublicSourceSyntax
except ImportError:
    from privacy_package import PrivacyError, decode_metadata_text
    from reviewed_resources import scan_host_paths
    from privacy_literals import PYTHON_SOURCE_SUFFIXES, inspect_source_literals, source_format, unc_source_view
    from privacy_roots import PublicRegexSpelling, PublicSourceSyntax


_PUBLIC_URL = re.compile(r'https?://[^\s"<>]+', re.I)
_ABSOLUTE_OPERAND = re.compile(r'(?:(?<![\w:/.])|(?<=\.\.))(?P<path>/+[^\s"\'<>]*)')
_FILE_URL = re.compile(r'(?=(?P<url>(?<![\w+.-])file://[^\s"\'<>]*))', re.I)
_FILE_AUTHORITY_TEMPLATE = re.compile(
    r'(?:%s|%\([A-Za-z_][A-Za-z_0-9]*\)s|\$[A-Za-z_][A-Za-z_0-9]*|\$?\{(?:[A-Za-z_][A-Za-z_0-9]*|[0-9]*|%s)\})')
_COMPILER_OPERAND = re.compile(
    r'(?<![\w.-])(?:-isystem|-iquote|-idirafter|-iframework|-isysroot|-include|-imacros|-I|-L|-F)'
    r'(?:[ \t]+|=)?(?P<path>/+[^\s"\'<>]*)')


def replace_public_spelling(text, public, *, source_code=False):
    """A reviewed file URI approves its complete spelling, never a host prefix."""
    if isinstance(public, PublicSourceSyntax):
        return re.sub(r'(?m)^' + re.escape(public) + r'(?=$|[\x00-\x1f])',
                      "PUBLIC_UPSTREAM_SOURCE_SYNTAX", text)
    if isinstance(public, PublicRegexSpelling):
        if not source_code:
            return "PUBLIC_UPSTREAM_EXAMPLE" if text == public else text
        return re.sub(re.escape(public) + r'(?=$|[\s"\'<>`|;,])',
                      "PUBLIC_UPSTREAM_EXAMPLE", text)
    if public.startswith("\\\\"):
        # Spaces, commas, semicolons and apostrophes can be filename bytes.
        # Source delimiters are allowed only on the raw source pass; decoded
        # literals are checked again with the stricter complete-path boundary.
        boundary = r'(?=$|[\x00-\x1f"<>|])'
        if source_code:
            boundary = r'(?=$|[\x00-\x1f"\'<>`|])'
        return re.sub(re.escape(public) + boundary, "PUBLIC_UPSTREAM_EXAMPLE", text)
    if public.lower().startswith("file://"):
        return re.sub(re.escape(public) + r'(?=$|[\s"\'<>`|;,])',
                      "PUBLIC_UPSTREAM_EXAMPLE", text)
    return text.replace(public, "PUBLIC_UPSTREAM_EXAMPLE")


def scan_path_operands(text, *, raw_source=False, name=""):
    """Normalize absolute operands, file URL components and compiler paths.

    Whole-text slash replacement would turn public URLs or /boot/home source
    paths into host roots. Preserve those contexts and pass each identified
    operand separately to the existing root policy.
    """
    view = unc_source_view(text, name).encode("utf-8", errors="surrogatepass") if raw_source else None
    scan_host_paths(text.encode("utf-8", errors="surrogatepass"), source_code=True, unc_view=view)
    text = _PUBLIC_URL.sub("", text)
    for pattern in (_ABSOLUTE_OPERAND, _COMPILER_OPERAND):
        for match in pattern.finditer(text):
            operand = re.sub(r"/+", "/", match["path"])
            # UNC is checked on the raw-source view and on decoded literals.
            # A POSIX regex operand must not re-interpret raw escape spellings.
            scan_host_paths(operand.encode("utf-8", errors="surrogatepass"), source_code=True, unc_view=b"")
    for match in _FILE_URL.finditer(text):
        literal = match["url"]
        # A scheme-only shell case glob implements URL syntax, naming no host.
        if re.fullmatch(r"file://\*\)?", literal, re.I):
            continue
        try:
            url = urlsplit(literal)
        except ValueError:
            raise PrivacyError("invalid-file-url") from None
        # Decode components separately and once: an encoded slash in an
        # authority must not be reparsed as a local path or hide its hostname.
        path = unquote(url.path)
        operand = re.sub(r"/+", "/", path)
        # The authority policy below owns decoded UNC shares and its stable
        # failure reason; POSIX and drive-home paths still reject here.
        scan_host_paths(operand.encode("utf-8", errors="surrogatepass"), source_code=True, unc_view=b"")
        authority = unquote(url.netloc).casefold()
        unc = path.replace("\\", "/")
        if ((authority not in ("", "localhost")
             and not _FILE_AUTHORITY_TEMPLATE.fullmatch(url.netloc))
                or (unc.startswith("//") and unc.lstrip("/"))):
            # Even a remote system/share path discloses a machine name. Exact
            # hash-bound upstream examples are removed by the caller first.
            raise PrivacyError("unreviewed-file-url-authority")
        # A share can also occur inside a local file-URL path. Preserve the
        # authority reason above without suppressing those embedded UNC names.
        scan_host_paths(operand.encode("utf-8", errors="surrogatepass"), source_code=True)


def inspect_text(data, name, *, allowed=()):
    def check(text, *, source_code=False):
        text = "".join(c for c in text if unicodedata.category(c) != "Cf")
        for public in allowed:
            text = replace_public_spelling(text, public, source_code=source_code)
        scan_path_operands(text, raw_source=source_code, name=name)
    header = data.partition(b"\n")[0].decode("ascii", errors="replace")
    if source_format(header, name) in PYTHON_SOURCE_SUFFIXES:
        try:
            encoding, _ = tokenize.detect_encoding(io.BytesIO(data).readline)
            text = data.decode(encoding)
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", SyntaxWarning)
                warnings.simplefilter("ignore", DeprecationWarning)
                ast.parse(text)
        except (UnicodeError, SyntaxError, ValueError, RecursionError):
            raise PrivacyError("invalid-package-python-source") from None
    else:
        text = decode_metadata_text(data)
        if text is None:
            raise PrivacyError("unreviewed-binary-package-entry")
    check(text, source_code=True)
    inspect_source_literals(text, name, check)
