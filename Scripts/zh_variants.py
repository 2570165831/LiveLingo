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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=RESOURCE_ROOT)
    parser.add_argument("--mode", choices=["s2tw", "s2hk", "s2twp"], default="s2tw")
    parser.add_argument("--project-tables", action="store_true")
    args = parser.parse_args()
    try:
        sys.stdout.write(Converter(args.root).convert(sys.stdin.read(), args.mode, project_tables=args.project_tables))
    except (OSError, ValueError) as error:
        parser.exit(1, f"Chinese variant dictionaries unavailable: {error}\n")


if __name__ == "__main__":
    main()
