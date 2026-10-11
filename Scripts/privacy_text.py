"""Scan ordinary text and decoded Python literals, without executing input."""
import ast
import io
import tokenize
import unicodedata
import warnings

try:
    from .privacy_package import PrivacyError, decode_metadata_text
    from .reviewed_resources import scan_host_paths
except ImportError:
    from privacy_package import PrivacyError, decode_metadata_text
    from reviewed_resources import scan_host_paths


def inspect_text(data, name, *, allowed=()):
    def check(text):
        text = "".join(c for c in text if unicodedata.category(c) != "Cf")
        for public in allowed:
            text = text.replace(public, "PUBLIC_UPSTREAM_EXAMPLE")
        scan_host_paths(text.encode("utf-8", errors="surrogatepass"), source_code=True)
    if name.endswith((".py", ".pyi")):
        try:
            encoding, _ = tokenize.detect_encoding(io.BytesIO(data).readline)
            text = data.decode(encoding)
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", SyntaxWarning)
                warnings.simplefilter("ignore", DeprecationWarning)
                tree = ast.parse(text)
        except (UnicodeError, SyntaxError, ValueError):
            raise PrivacyError("invalid-package-python-source") from None
        check(text)
        if __package__:
            from .privacy_literals import inspect_python_literals
        else:
            from privacy_literals import inspect_python_literals
        inspect_python_literals(text, check)
    else:
        text = decode_metadata_text(data)
        if text is None:
            raise PrivacyError("unreviewed-binary-package-entry")
        check(text)
