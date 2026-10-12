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
    from .privacy_literals import PYTHON_SOURCE_SUFFIXES, inspect_source_literals, source_format
except ImportError:
    from privacy_package import PrivacyError, decode_metadata_text
    from reviewed_resources import scan_host_paths
    from privacy_literals import PYTHON_SOURCE_SUFFIXES, inspect_source_literals, source_format


_PUBLIC_URL = re.compile(r'https?://[^\s"<>]+', re.I)
_ABSOLUTE_OPERAND = re.compile(r'(?:(?<![\w:/.])|(?<=\.\.))(?P<path>/+[^\s"\'<>]*)')
_FILE_URL = re.compile(r'(?<![\w+.-])file://(?:localhost)?/+[^\s"\'<>]*', re.I)
_COMPILER_OPERAND = re.compile(
    r'(?<![\w.-])(?:-isystem|-iquote|-idirafter|-iframework|-isysroot|-include|-imacros|-I|-L|-F)'
    r'(?:[ \t]+|=)?(?P<path>/+[^\s"\'<>]*)')


def scan_path_operands(text):
    """Normalize only absolute operands, local file URLs and compiler paths.

    Whole-text slash replacement would turn public URLs or /boot/home source
    paths into host roots. Preserve those contexts and pass each identified
    operand separately to the existing root policy.
    """
    scan_host_paths(text.encode("utf-8", errors="surrogatepass"), source_code=True)
    text = _PUBLIC_URL.sub("", text)
    for pattern in (_ABSOLUTE_OPERAND, _COMPILER_OPERAND):
        for match in pattern.finditer(text):
            operand = re.sub(r"/+", "/", match["path"])
            scan_host_paths(operand.encode("utf-8", errors="surrogatepass"), source_code=True)
    for match in _FILE_URL.finditer(text):
        path = unquote(urlsplit(match[0]).path)
        path = re.sub(r"/+", "/", path)
        scan_host_paths(path.encode("utf-8", errors="surrogatepass"), source_code=True)


def inspect_text(data, name, *, allowed=()):
    def check(text):
        text = "".join(c for c in text if unicodedata.category(c) != "Cf")
        for public in allowed:
            text = text.replace(public, "PUBLIC_UPSTREAM_EXAMPLE")
        scan_path_operands(text)
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
    check(text)
    inspect_source_literals(text, name, check)
