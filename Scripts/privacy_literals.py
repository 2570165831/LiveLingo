"""Inspect decoded source literals without executing the source.

Callers supply a ``scan(str)`` callback so source and runtime policies can share
decoding while retaining their own path rules. Only already identified text
belongs here; opaque binary payloads must not be passed to these functions.
"""
import ast
import io
from pathlib import PurePosixPath
import re
import shlex
import tokenize
import unicodedata
import warnings

if __package__:
    from .privacy_package import PrivacyError
else:
    from privacy_package import PrivacyError


C_SOURCE_SUFFIXES = frozenset({".c", ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp", ".hxx", ".m", ".mm"})
PYTHON_SOURCE_SUFFIXES = frozenset({".py", ".pyi"})
SHELL_SOURCE_SUFFIXES = frozenset({".sh", ".bash", ".zsh"})
SOURCE_SUFFIXES = (C_SOURCE_SUFFIXES | PYTHON_SOURCE_SUFFIXES | SHELL_SOURCE_SUFFIXES
                   | {".rs", ".js", ".mjs", ".cjs", ".go", ".patch", ".diff", ".html", ".htm"})


def source_suffix(name):
    path = PurePosixPath(name)
    suffix = path.suffix.lower()
    return PurePosixPath(path.stem).suffix.lower() if suffix == ".in" else suffix


def _shebang_suffix(text):
    """Recognize a bounded interpreter declaration; never run env or a shell.

    Only standard interpreter locations, env's optional -S, and flags without
    operands are recognized. Assignments, wrappers, -c/code, substitutions and
    arbitrary executable paths cannot select a source decoder.
    """
    line = text.partition("\n")[0].rstrip("\r")
    if not line.startswith("#!") or len(line) > 512 or not line.isascii():
        return ""
    try:
        words = shlex.split(line[2:], comments=False, posix=True)
    except ValueError:
        return ""
    if not words:
        return ""
    interpreter, flags = words[0], words[1:]
    if interpreter == "/usr/bin/env":
        if flags[:1] == ["-S"]:
            flags = flags[1:]
        if not flags:
            return ""
        interpreter, flags = flags[0], flags[1:]
        if "/" in interpreter:
            return ""
    elif PurePosixPath(interpreter).parent.as_posix() not in ("/bin", "/usr/bin"):
        return ""
    interpreter = PurePosixPath(interpreter).name
    if re.fullmatch(r"python(?:[23](?:\.[0-9]+)*)?", interpreter):
        if all(re.fullmatch(r"-[BEIOsSux]+", flag) for flag in flags):
            return ".py"
    elif interpreter in ("sh", "bash", "zsh", "dash", "ksh"):
        if all(re.fullmatch(r"-[aefnuvx]+", flag) or flag in ("--noprofile", "--norc") for flag in flags):
            return ".sh"
    return ""


def source_format(text, name):
    """Use a known suffix first, then a finite shebang or upstream shell name."""
    suffix = source_suffix(name)
    if suffix in SOURCE_SUFFIXES:
        return suffix
    if PurePosixPath(name).name in ("configure", "test-driver"):
        return ".sh"
    return _shebang_suffix(text)


def _scan(value, scan):
    if isinstance(value, bytes):
        if __package__:
            from .privacy_package import decode_metadata_text
        else:
            from privacy_package import decode_metadata_text
        value = decode_metadata_text(value) or value.decode("latin-1")
    if isinstance(value, str):
        scan("".join(c for c in value if unicodedata.category(c) != "Cf"))


def _default_scan(value):
    if __package__:
        from .reviewed_resources import scan_host_paths
    else:
        from reviewed_resources import scan_host_paths
    scan_host_paths(value.encode("utf-8", errors="surrogatepass"), source_code=True)


def _text(data):
    if isinstance(data, str):
        return data
    if __package__:
        from .privacy_package import decode_metadata_text
    else:
        from privacy_package import decode_metadata_text
    value = decode_metadata_text(data)
    if value is None:
        raise PrivacyError("invalid-source-literal-text")
    return value


def inspect_python_literals(text, scan=None):
    """Inspect AST string/byte constants; tokenize legacy Python on syntax errors.

    Parsing folds adjacent literals and exposes f-string constant pieces. No
    imports, expressions, calls or interpolation in the source are evaluated.
    Legacy Python source can have Python-2-only statement syntax; its individual
    string tokens still receive literal-only decoding rather than being waived.
    """
    text, scan = _text(text), scan or _default_scan
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", SyntaxWarning)
            warnings.simplefilter("ignore", DeprecationWarning)
            tree = ast.parse(text)
    except SyntaxError:
        tree = None
    except (ValueError, RecursionError):
        raise PrivacyError("invalid-python-source-literals") from None
    if tree is not None:
        concatenations = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Constant):
                _scan(node.value, scan)
            elif isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
                concatenations.add(node)
        # Scan each maximal pure-literal sum once. Names/calls/operators other
        # than Add are never evaluated, even when nested inside a source call.
        nested = {child for node in concatenations for child in (node.left, node.right)
                  if child in concatenations}
        for node in concatenations - nested:
            stack, pieces = [node], []
            while stack:
                current = stack.pop()
                if isinstance(current, ast.Constant) and isinstance(current.value, (str, bytes)):
                    pieces.append(current.value)
                elif isinstance(current, ast.BinOp) and isinstance(current.op, ast.Add):
                    stack.extend((current.right, current.left))
                else:
                    pieces.append(None)  # A name/call breaks, rather than extends, a sum.
            group = []
            for value in [*pieces, None]:
                if group and (value is None or type(value) is not type(group[0])):
                    if len(group) > 1:
                        _scan(group[0][:0].join(group), scan)
                    group = []
                if value is not None:
                    group.append(value)
        return
    try:
        for token in tokenize.generate_tokens(io.StringIO(text).readline):
            if token.type != tokenize.STRING:
                continue
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", SyntaxWarning)
                warnings.simplefilter("ignore", DeprecationWarning)
                value = ast.literal_eval(token.string)
            _scan(value, scan)
    except PrivacyError:
        raise
    except (SyntaxError, ValueError, tokenize.TokenError, IndentationError):
        # Compiler/source test inputs may intentionally be syntactically
        # invalid. Recover quoted fragments without evaluating any expressions;
        # every decodable fragment still reaches the caller's path callback.
        for _, _, value in _quoted_literals(text, "python"):
            _scan(value, scan)
    except RecursionError:
        raise PrivacyError("invalid-python-source-literals") from None


def _decode_escapes(body, style):
    """Decode once, respecting escaped backslashes and each format's widths."""
    result = []
    offset = 0
    simple = {"n": "\n", "r": "\r", "t": "\t", "a": "\a", "b": "\b",
              "f": "\f", "v": "\v", "\\": "\\", '"': '"', "'": "'"}
    while offset < len(body):
        if body[offset] != "\\" or offset + 1 == len(body):
            result.append(body[offset])
            offset += 1
            continue
        tail = body[offset + 1:]
        char = tail[0]
        length, value = 1, None
        if char in simple:
            value = simple[char]
        elif char in "\r\n":
            length = 2 if tail.startswith("\r\n") else 1
            if style == "rust":
                length += len(tail[length:]) - len(tail[length:].lstrip())
            value = ""
        else:
            match = None
            if style in ("rust", "javascript") and tail.startswith("u{"):
                match = re.match(r"u\{([0-9A-Fa-f_]+)\}", tail)
                base = 16
            elif char in "uU" and style != "rust":
                match = re.match(char + r"([0-9A-Fa-f]{" + ("4" if char == "u" else "8") + "})", tail)
                base = 16
            elif char == "x":
                width = "+" if style == "c" else "{1,2}" if style == "shell" else "{2}"
                match = re.match(r"x([0-9A-Fa-f]" + width + ")", tail)
                base = 16
            elif char in "01234567" and style != "rust":
                match = re.match(r"([0-7]{1,3})", tail)
                base = 8
            elif char == "0" and style == "rust":
                value = "\0"
            if match:
                number = int(match[1].replace("_", ""), base)
                if number > 0x10ffff and style == "c" and char == "x":
                    number &= 0xff  # GCC's narrow byte escape truncation.
                if number <= 0x10ffff:
                    value, length = chr(number), len(match[0])
        if value is None:
            value = "\\" + char  # Unsupported syntax remains visible; never recurse.
        result.append(value)
        offset += length + 1
    return "".join(result)


def _quoted_literals(text, style):
    """Lex C/Rust strings, preserving raw strings and skipping comments."""
    offset = 0
    syntax = re.compile(r"[\"'`/]|\b(?:u8|u|U|L)?R\"|\b(?:b|c)?r#{0,255}\"")
    while offset < len(text):
        found = syntax.search(text, offset)
        if found is None:
            break
        offset = found.start()
        if text.startswith("//", offset):
            end = text.find("\n", offset)
            offset = len(text) if end < 0 else end + 1
            continue
        if text.startswith("/*", offset):
            end, depth = offset + 2, 1
            while depth:
                closing = text.find("*/", end)
                if closing < 0:
                    break
                nested = text.find("/*", end, closing) if style == "rust" else -1
                if nested >= 0:
                    depth += 1
                    end = nested + 2
                else:
                    depth -= 1
                    end = closing + 2
            if depth:
                return  # An intentionally unterminated comment has no later literals.
            offset = end
            continue
        raw = None
        boundary = offset == 0 or not (text[offset - 1].isalnum() or text[offset - 1] == "_")
        if boundary and style == "c":
            raw = re.match(r'(?:u8|u|U|L)?R"([^()\s]{0,16})\(', text[offset:])
            ending = ")" + raw[1] + '"' if raw else None
        elif boundary and style == "rust":
            raw = re.match(r'(?:b|c)?r(#{0,255})"', text[offset:])
            ending = '"' + raw[1] if raw else None
        if raw:
            start = offset + len(raw[0])
            end = text.find(ending, start)
            if end < 0:
                yield offset, len(text), text[start:]
                return
            yield offset, end + len(ending), text[start:end]
            offset = end + len(ending)
            continue
        char = text[offset]
        if char == "`" and style == "go":
            # Go raw strings preserve backslashes and discard carriage returns.
            end = text.find("`", offset + 1)
            if end < 0:
                yield offset, len(text), text[offset + 1:].replace("\r", "")
                return
            yield offset, end + 1, text[offset + 1:end].replace("\r", "")
            offset = end + 1
            continue
        if char not in "\"'":
            offset += 1
            continue
        if char == "'" and style in ("c", "rust"):
            # Character tokens contain no path. Ignore prose apostrophes in
            # preprocessor diagnostics rather than treating them as strings.
            char_body = r"(?:\\(?:[0-7]{1,3}|x[0-9A-Fa-f]+|u\{[0-9A-Fa-f_]+\}|u[0-9A-Fa-f]{4}|U[0-9A-Fa-f]{8}|.)|[^'\\\n])"
            character = re.match("'" + char_body + ("+" if style == "c" else "") + "'", text[offset:])
            offset += len(character[0]) if character else 1
            continue
        start, end = offset + 1, offset + 1
        while end < len(text) and text[end] != char:
            end += 2 if text[end] == "\\" else 1
        if end >= len(text):
            yield offset, len(text), _decode_escapes(text[start:], style)
            return
        yield offset, end + 1, _decode_escapes(text[start:end], style)
        offset = end + 1


def _javascript_literals(text):
    """Lex JS strings/templates and regex tokens without compiling any input."""
    offset, expression_start, previous = 0, True, ""
    parens = []
    words = re.compile(r"[$A-Za-z_][$\w]*|[0-9]+(?:\.[0-9]+)?")
    regexp = re.compile(r"/((?:\\[^\r\n]|\[(?:\\[^\r\n]|[^\]\\\r\n])*\]|[^/\\[\r\n])*)/[A-Za-z]*")
    while offset < len(text):
        char = text[offset]
        if char.isspace():
            offset += 1
            continue
        if text.startswith("//", offset):
            end = text.find("\n", offset)
            offset = len(text) if end < 0 else end + 1
            continue
        if text.startswith("/*", offset):
            end = text.find("*/", offset + 2)
            if end < 0:
                raise PrivacyError("invalid-source-literal-layout")
            offset = end + 2
            continue
        if char in "\"'`":
            end = offset + 1
            while end < len(text) and text[end] != char:
                end += 2 if text[end] == "\\" else 1
            if end >= len(text):
                raise PrivacyError("invalid-source-literal-layout")
            yield offset, end + 1, _decode_escapes(text[offset + 1:end], "javascript")
            offset, expression_start, previous = end + 1, False, "literal"
            continue
        if char == "/" and expression_start:
            match = regexp.match(text, offset)
            if match:
                yield offset, match.end(), _decode_escapes(match[1], "javascript")
                offset, expression_start, previous = match.end(), False, "literal"
                continue
        word = words.match(text, offset)
        if word:
            previous = word[0]
            expression_start = previous in {"return", "throw", "case", "delete", "void", "typeof",
                                           "new", "in", "instanceof", "yield", "await", "else", "do"}
            offset = word.end()
            continue
        if char == "(":
            parens.append(previous in {"if", "while", "for", "with", "switch", "catch"})
            expression_start = True
        elif char == ")":
            expression_start = parens.pop() if parens else False
        elif char in "] .":
            expression_start = False
        elif text[offset:offset + 2] in ("++", "--"):
            offset += 1  # Preserve the prefix/postfix expression context.
        else:
            expression_start = True
        previous = char
        offset += 1


def _shell_literals(text):
    """Lex constant shell word pieces, without expanding variables or commands.

    ANSI-C escapes apply only outside ordinary quotes. Constant adjacent pieces
    share a word; expansions break that group so names/calls are never resolved.
    """
    offset, pieces, boundary = 0, [], True
    delimiters = " \t\r\n;|&()<>="
    while offset < len(text):
        char = text[offset]
        if char in delimiters or char == "#" and boundary:
            if pieces:
                yield "".join(pieces)
                pieces = []
            if char == "#":
                end = text.find("\n", offset)
                offset = len(text) if end < 0 else end + 1
            else:
                offset += 1
            boundary = char != "="
            continue
        boundary = False
        if text.startswith("$'", offset):
            start, end = offset + 2, offset + 2
            while end < len(text) and text[end] != "'":
                end += 2 if text[end] == "\\" else 1
            value = _decode_escapes(text[start:end], "shell")
            yield value
            pieces.append(value)
            offset = min(end + 1, len(text))
            continue
        if char == "'":
            end = text.find("'", offset + 1)
            end = len(text) if end < 0 else end
            value = text[offset + 1:end]
            yield value
            pieces.append(value)
            offset = min(end + 1, len(text))
            continue
        if char == '"':
            offset += 1
            value = []
            while offset < len(text) and text[offset] != '"':
                char = text[offset]
                if char == "\\" and offset + 1 < len(text) and text[offset + 1] in '$`"\\\n':
                    if text[offset + 1] != "\n":
                        value.append(text[offset + 1])
                    offset += 2
                elif char == "`" or char == "$" and offset + 1 < len(text) and (text[offset + 1].isalnum() or text[offset + 1] in "_{("):
                    if value:
                        fragment = "".join(value)
                        yield fragment
                        pieces.append(fragment)
                    if pieces:
                        yield "".join(pieces)
                    pieces, value = [], []
                    # The expansion is an opaque separator, not a literal.
                    match = re.match(r"\$(?:[A-Za-z_][A-Za-z_0-9]*|\{[^}]*\})", text[offset:])
                    offset += len(match[0]) if match else 1
                else:
                    value.append(char)
                    offset += 1
            fragment = "".join(value)
            yield fragment
            pieces.append(fragment)
            offset = min(offset + 1, len(text))
            continue
        if char == "$" or char == "`":
            if pieces:
                yield "".join(pieces)
            pieces = []
            match = re.match(r"\$(?:[A-Za-z_][A-Za-z_0-9]*|\{[^}]*\})", text[offset:])
            offset += len(match[0]) if match else 1
            continue
        if char == "\\" and offset + 1 < len(text):
            if text[offset + 1] != "\n":
                pieces.append(text[offset + 1])
            offset += 2
        else:
            pieces.append(char)
            offset += 1
    if pieces:
        yield "".join(pieces)


def _patch_literals(text, scan):
    """Inspect both sides of unified source hunks; never apply a patch."""
    target, before, after = None, [], []
    def flush():
        if target is None:
            return
        for lines in (before, after):
            data = "\n".join(lines)
            if PurePosixPath(target).suffix.lower() in (".patch", ".diff"):
                for _, _, value in _quoted_literals(data, "c"):
                    _scan(value, scan)
            else:
                inspect_source_literals(data, target, scan)
    for line in text.splitlines():
        if line.startswith("--- "):
            flush()
            before, after = [], []
            name = line[4:].split("\t", 1)[0]
            if name.startswith('"') and name.endswith('"'):
                name = _decode_escapes(name[1:-1], "c")
            _scan(name, scan)
            target = name
        elif line.startswith("+++ "):
            name = line[4:].split("\t", 1)[0]
            if name.startswith('"') and name.endswith('"'):
                name = _decode_escapes(name[1:-1], "c")
            _scan(name, scan)
            if name != "/dev/null":
                target = name
        elif line.startswith("-"):
            before.append(line[1:])
        elif line.startswith("+"):
            after.append(line[1:])
        elif line.startswith(" "):
            before.append(line[1:])
            after.append(line[1:])
    flush()


def inspect_source_literals(data, name, scan=None):
    """Apply bounded, format-specific decoding to an identified source member."""
    text, scan = _text(data), scan or _default_scan
    suffix = source_format(text, name)
    if suffix in PYTHON_SOURCE_SUFFIXES:
        inspect_python_literals(text, scan)
    elif suffix in (".patch", ".diff"):
        _patch_literals(text, scan)
    elif suffix in C_SOURCE_SUFFIXES | {".rs", ".js", ".mjs", ".cjs", ".go"}:
        style = "rust" if suffix == ".rs" else "go" if suffix == ".go" else "javascript" if suffix in (".js", ".mjs", ".cjs") else "c"
        if style == "c":
            text = re.sub(r"\\\r?\n", "", text)
        previous_end, adjacent = 0, ""
        iterator = _javascript_literals(text) if style == "javascript" else _quoted_literals(text, style)
        for start, end, value in iterator:
            _scan(value, scan)
            # Adjacent C string literals are a single string after compilation.
            gap = re.sub(r"/\*.*?\*/|//[^\n]*", "", text[previous_end:start], flags=re.S)
            gap = re.sub(r"\b(?:u8|u|U|L)\s*$", "", gap)
            joins = style == "c" and not gap.strip() or style in ("javascript", "go") and gap.strip() == "+"
            adjacent = adjacent + value if joins else value
            if adjacent != value:
                _scan(adjacent, scan)
            previous_end = end
    elif suffix in SHELL_SOURCE_SUFFIXES:
        for value in _shell_literals(text):
            _scan(value, scan)
    elif suffix in (".html", ".htm"):
        from html.parser import HTMLParser
        class SourceHTML(HTMLParser):
            def handle_starttag(self, tag, attrs):
                for _, value in attrs:
                    if value is not None:
                        _scan(value, scan)
            def handle_data(self, value):
                _scan(value, scan)
            def handle_comment(self, value):
                _scan(value, scan)
        parser = SourceHTML(convert_charrefs=True)
        parser.feed(text)
        parser.close()
