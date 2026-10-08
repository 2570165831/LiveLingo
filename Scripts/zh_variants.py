"""Offline scalar-based mirror of ChineseScriptConverter; no inference or ICU fallback."""
from __future__ import annotations

import argparse
from pathlib import Path
import sys

RESOURCE_ROOT = Path(__file__).resolve().parents[1] / "LiveLingo/Resources/ZhVariants"


class Dictionary:
    def __init__(self, root: Path, names: list[str]):
        self.trie = {}
        for name in names:
            for line in (root / name).read_text(encoding="utf-8").splitlines():
                if not line.strip() or line.startswith("#"):
                    continue
                fields = line.split("\t")
                if len(fields) != 2 or not fields[0] or not fields[1].split():
                    raise ValueError(f"Invalid dictionary: {name}")
                node = self.trie
                for scalar in fields[0]:
                    node = node.setdefault(scalar, {})
                node.setdefault(None, fields[1].split()[0])

    def match(self, text: str, start: int):
        node, best = self.trie, None
        for index in range(start, len(text)):
            node = node.get(text[index])
            if node is None:
                break
            if None in node:
                best = index + 1, node[None]
        return best

    def segment(self, text: str):
        segments, pending, index = [], "", 0
        while index < len(text):
            match = self.match(text, index)
            if match:
                if pending:
                    segments.append(pending)
                    pending = ""
                segments.append(text[index:match[0]])
                index = match[0]
            else:
                pending += text[index]
                index += 1
        if pending:
            segments.append(pending)
        return segments


def convert_group(text: str, dictionaries: list[Dictionary]) -> str:
    output, index = [], 0
    while index < len(text):
        match = next((m for d in dictionaries if (m := d.match(text, index))), None)
        if match:
            output.append(match[1])
            index = match[0]
        else:
            output.append(text[index])
            index += 1
    return "".join(output)


class RenderText:
    """Protect technical UTF-8 ranges without parsing/re-serializing their data.

    This scanner is mirrored in ChineseScriptConverter.RenderText. OpenCC's
    raw convert() and upstream fixtures deliberately do not use it.
    """

    def __init__(self, text: str):
        self.data = text.encode("utf-8")
        self.protected = bytearray(len(self.data))
        self.inline_blocks = [0] * len(self.data)
        self._blocks()
        self.blocks = self.protected.copy()
        self._inline_code()
        self._latex()
        self._json_keys()

    def _mark(self, start, end):
        self.protected[start:end] = b"\1" * (end - start)

    def _escaped(self, index):
        start = index
        while start > 0 and self.data[start - 1] == 92:
            start -= 1
        return (index - start) % 2 != 0

    def _run_end(self, index, byte):
        while index < len(self.data) and self.data[index] == byte:
            index += 1
        return index

    def _space_end(self, index, end=None):
        end = len(self.data) if end is None else end
        while index < end and self.data[index] in b" \t\r\n":
            index += 1
        return index

    def _balanced_end(self, index):
        closing = {123: 125, 91: 93}.get(self.data[index])
        if closing is None:
            return None
        stack = [closing]
        index += 1
        while index < len(self.data):
            byte = self.data[index]
            if byte == 92:
                index += 2
                continue
            if byte == 123 or (byte == 91 and stack[-1] != 125):
                stack.append(125 if byte == 123 else 93)
            elif byte == stack[-1]:
                stack.pop()
                if not stack:
                    return index + 1
            index += 1
        return None

    def _indentation(self, index, end, columns=0):
        while index < end and self.data[index] in b" \t":
            columns += 1 if self.data[index] == 32 else 4 - columns % 4
            index += 1
        return index, columns

    def _list_marker_end(self, index, end):
        if index == end:
            return None
        marker_end = index
        if self.data[index] in b"-+*":
            marker_end += 1
        else:
            while marker_end < end and 48 <= self.data[marker_end] <= 57 and marker_end - index < 9:
                marker_end += 1
            if marker_end == index or marker_end == end or self.data[marker_end] not in b".)":
                return None
            marker_end += 1
        return marker_end if marker_end == end or self.data[marker_end] in b" \t" else None

    def _heading(self, index, end):
        if index == end or self.data[index] != 35:
            return False
        last = self._run_end(index, 35)
        return last - index <= 6 and (last == end or self.data[last] in b" \t")

    def _rule(self, index, end):
        if index == end or self.data[index] not in b"*-_=":
            return False
        marker = self.data[index]
        body = self.data[index:end].replace(b" ", b"").replace(b"\t", b"")
        return len(body) >= (1 if marker == 61 else 3) and all(byte == marker for byte in body)

    def _interrupts_paragraph(self, index, columns, end):
        return columns <= 3 and index < end and (
            self.data[index] == 62 or self._heading(index, end) or self._rule(index, end)
            or self._list_marker_end(index, end) is not None
            or (self.data[index] in b"`~" and self._run_end(index, self.data[index]) - index >= 3))

    def _blocks(self):
        data, containers, fence = self.data, [], None
        indented, previous_blank, paragraph, block_id = False, True, False, 0
        start = 0
        while start < len(data):
            newline = data.find(b"\n", start)
            end = len(data) if newline < 0 else newline + 1
            content_end = end
            while content_end > start and data[content_end - 1] in b"\r\n":
                content_end -= 1
            index, columns = self._indentation(start, content_end)
            matched = 0
            for kind, indent in containers:
                if kind == "quote":
                    if columns > 3 or index == content_end or data[index] != 62:
                        break
                    index += 1
                    if index < content_end and data[index] in b" \t":
                        index += 1
                    index, columns = self._indentation(index, content_end)
                else:
                    if index != content_end and columns < indent:
                        break
                    columns = max(0, columns - indent)
                matched += 1
            if matched < len(containers):
                # Lazy continuation applies to paragraphs, never fenced code.
                lazy = (paragraph and not previous_blank and fence is None and not indented
                        and index < content_end and not self._interrupts_paragraph(index, columns, content_end))
                if not lazy:
                    containers = containers[:matched]
                    fence, indented, paragraph = None, False, False

            if fence is not None and containers == fence[2]:
                self._mark(start, end)
                marker_end = self._run_end(index, fence[0]) if index < content_end else index
                if columns <= 3 and marker_end - index >= fence[1] and self._space_end(marker_end, content_end) == content_end:
                    fence = None
                previous_blank, paragraph, start = index == content_end, False, end
                continue

            opened_container = False
            while columns <= 3 and index < content_end:
                if data[index] == 62:
                    containers.append(("quote", 0))
                    index += 1
                    if index < content_end and data[index] in b" \t":
                        index += 1
                    index, columns = self._indentation(index, content_end)
                elif not self._rule(index, content_end) and (marker_end := self._list_marker_end(index, content_end)) is not None:
                    marker_width = marker_end - index
                    next_index, next_columns = self._indentation(marker_end, content_end, columns + marker_width)
                    padding = next_columns - columns - marker_width
                    spacing = padding if 0 < padding <= 4 else 1
                    containers.append(("list", columns + marker_width + spacing))
                    index, columns = next_index, max(0, padding - spacing)
                else:
                    break
                opened_container = True

            blank = index == content_end
            marker_end = self._run_end(index, data[index]) if not blank and data[index] in b"`~" else index
            count = marker_end - index
            if columns <= 3 and count >= 3 and (data[index] == 126 or b"`" not in data[marker_end:content_end]):
                fence = (data[index], count, containers.copy())
                self._mark(start, end)
                indented, paragraph = False, False
            elif indented and blank:
                self._mark(start, end)
            elif columns >= 4 and (indented or previous_blank or opened_container):
                self._mark(start, end)
                indented, paragraph = True, False
            else:
                indented = False
                if blank:
                    paragraph = False
                else:
                    separate = columns <= 3 and (self._heading(index, content_end) or self._rule(index, content_end))
                    if not paragraph or opened_container or separate:
                        block_id += 1
                    self.inline_blocks[start:end] = [block_id] * (end - start)
                    paragraph = not separate
            previous_blank, start = blank, end

    def _inline_code(self):
        data, index = self.data, 0
        while index < len(data):
            if self.protected[index] or data[index] != 96 or self._escaped(index):
                index += 1
                continue
            opening_end = self._run_end(index, 96)
            cursor, closing_end = opening_end, None
            while cursor < len(data) and not self.protected[cursor] and self.inline_blocks[cursor] == self.inline_blocks[index]:
                if data[cursor] == 96:
                    end = self._run_end(cursor, 96)
                    if end - cursor == opening_end - index:
                        closing_end = end
                        break
                    cursor = end
                else:
                    cursor += 1
            if closing_end is not None:
                self._mark(index, closing_end)
                index = closing_end
            else:
                index = opening_end

    def _delimiter_end(self, start, delimiter):
        cursor = start
        while cursor < len(self.data):
            if self.blocks[cursor]:
                return None
            if self.data.startswith(delimiter, cursor) and not self._escaped(cursor):
                return cursor + len(delimiter)
            cursor += 1
        return None

    def _has_math_syntax(self, start, end):
        body = self.data[start:end].strip(b" \t\r\n")
        operators = b"_^\\=+-*/<>"
        if not body or body[-1] in operators or b"\r" in body or b"\n" in body:
            return False
        if any(mark.encode() in body for mark in "，。；！？："):
            return False
        return any(byte in operators for byte in body)

    def _latex(self):
        data, index = self.data, 0
        math_environments = {b"math", b"displaymath", b"equation", b"equation*", b"align", b"align*", b"aligned", b"gather", b"gather*", b"multline", b"multline*", b"eqnarray", b"eqnarray*", b"cases", b"matrix", b"pmatrix", b"bmatrix", b"vmatrix", b"Vmatrix"}
        while index < len(data):
            if self.protected[index] or self._escaped(index):
                index += 1
                continue
            if data[index] == 36:
                opening_end = self._run_end(index, 36)
                length = opening_end - index
                if length not in (1, 2) or opening_end == len(data):
                    index = opening_end
                    continue
                cursor, closing = opening_end, None
                while cursor < len(data) and not self.blocks[cursor]:
                    if data[cursor] == 36 and not self._escaped(cursor):
                        end = self._run_end(cursor, 36)
                        if end - cursor == length:
                            conventional = data[opening_end] not in b" \t\r\n" and not 48 <= data[opening_end] <= 57 and data[cursor - 1] not in b" \t\r\n"
                            if length == 2 or ((end == len(data) or not 48 <= data[end] <= 57) and (conventional or self._has_math_syntax(opening_end, cursor))):
                                closing = end
                        # A rejected single-dollar pair is prose/currency. Do
                        # not search past it and consume a later real formula.
                        if closing is not None or length == 1:
                            break
                        cursor = end
                    else:
                        cursor += 1
                if closing is not None:
                    self._mark(index, closing)
                    index = closing
                else:
                    index = opening_end
                continue
            if data[index] != 92 or index + 1 == len(data):
                index += 1
                continue
            if data[index + 1] in b"([":
                end = self._delimiter_end(index + 2, b"\\)" if data[index + 1] == 40 else b"\\]")
                if end is not None:
                    self._mark(index, end)
                    index = end
                    continue
            command_end = index + 1
            while command_end < len(data):
                byte = data[command_end]
                length = 1 if byte < 128 else (2 if byte < 224 else (3 if byte < 240 else 4))
                if not data[command_end:command_end + length].decode("utf-8").isalpha():
                    break
                command_end += length
            if command_end == index + 1:
                index += 2
                continue
            command = data[index + 1:command_end]
            if command_end < len(data) and data[command_end] == 42:
                command_end += 1
            end = command_end
            if command == b"verb" and end < len(data) and data[end] not in b" \t\r\n":
                closing = data.find(data[end:end + 1], end + 1)
                if closing >= 0 and b"\n" not in data[end:closing]:
                    end = closing + 1
            else:
                while True:
                    group = self._space_end(end)
                    if group == len(data) or data[group] not in b"{[":
                        break
                    group_end = self._balanced_end(group)
                    if group_end is None:
                        break
                    if command == b"begin" and group == self._space_end(command_end) and data[group + 1:group_end - 1] in math_environments:
                        environment = data[group + 1:group_end - 1]
                        math_end = self._delimiter_end(group_end, b"\\end{" + environment + b"}")
                        if math_end is not None:
                            end = math_end
                            break
                    end = group_end
            self._mark(index, end)
            index = end

    def _json_keys(self):
        data, stack, index = self.data, [], 0
        while index < len(data):
            if self.protected[index]:
                index += 1
                continue
            byte = data[index]
            if byte == 123:
                following = self._space_end(index + 1)
                if stack or (following < len(data) and data[following] in (34, 125)):
                    stack.append(123)
            elif byte == 91 and stack:
                stack.append(91)
            elif byte in (125, 93) and stack and stack[-1] == (123 if byte == 125 else 91):
                stack.pop()
            elif byte == 34:
                end = index + 1
                while end < len(data):
                    if data[end] == 92:
                        end += 2
                    elif data[end] == 34 or data[end] in b"\r\n":
                        break
                    else:
                        end += 1
                if end < len(data) and data[end] == 34:
                    end += 1
                    following = self._space_end(end)
                    if stack and stack[-1] == 123 and following < len(data) and data[following] == 58:
                        self._mark(index, end)
                    index = end
                    continue
            index += 1

    def render(self, convert):
        result, start = [], 0
        while start < len(self.data):
            end = start + 1
            while end < len(self.data) and self.protected[end] == self.protected[start]:
                end += 1
            text = self.data[start:end].decode("utf-8")
            result.append(text if self.protected[start] else convert(text))
            start = end
        return "".join(result)


class Converter:
    def __init__(self, root: Path = RESOURCE_ROOT):
        self.phrases = Dictionary(root, ["STPhrases.txt"])
        self.characters = Dictionary(root, ["STCharacters.txt"])
        self.tw = Dictionary(root, ["TWVariants.txt"])
        self.hk = Dictionary(root, ["HKVariants.txt"])
        self.tw_phrases = Dictionary(root, ["TWPhrasesIT.txt", "TWPhrasesName.txt", "TWPhrasesOther.txt"])
        self.reviewed = Dictionary(root, ["TW-reviewed-phrases.txt"])
        self.tw_overlay = Dictionary(root, ["LiveLingo-TW-overlay.txt"])
        self.hk_overlay = Dictionary(root, ["LiveLingo-HK-overlay.txt"])

    def convert(self, text: str, mode="s2tw", *, project_tables=False) -> str:
        if mode not in ("s2tw", "s2hk", "s2twp"):
            raise ValueError("Unsupported conversion mode")
        result = []
        for segment in self.phrases.segment(text):
            segment = convert_group(segment, [self.phrases, self.characters])
            if mode == "s2twp":
                segment = convert_group(segment, [self.tw_phrases])
            result.append(convert_group(segment, [self.hk if mode == "s2hk" else self.tw]))
        text = "".join(result)
        if project_tables:
            text = convert_group(text, [self.hk_overlay] if mode == "s2hk" else [self.tw_overlay, self.reviewed])
        return text

    def render(self, text: str, mode="s2tw", *, project_tables=False) -> str:
        if mode not in ("s2tw", "s2hk", "s2twp"):
            raise ValueError("Unsupported conversion mode")
        return RenderText(text).render(lambda prose: self.convert(prose, mode, project_tables=project_tables))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=RESOURCE_ROOT)
    parser.add_argument("--mode", choices=["s2tw", "s2hk", "s2twp"], default="s2tw")
    parser.add_argument("--project-tables", action="store_true")
    parser.add_argument("--render", action="store_true", help="Preserve code, JSON keys and LaTeX while rendering prose")
    args = parser.parse_args()
    try:
        converter = Converter(args.root)
        operation = converter.render if args.render else converter.convert
        text = sys.stdin.buffer.read().decode("utf-8")
        sys.stdout.buffer.write(operation(text, args.mode, project_tables=args.project_tables).encode("utf-8"))
    except (OSError, ValueError) as error:
        parser.exit(1, f"Chinese variant dictionaries unavailable: {error}\n")


if __name__ == "__main__":
    main()
