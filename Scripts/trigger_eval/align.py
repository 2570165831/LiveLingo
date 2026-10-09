"""Conservative public UN alignment using English interpretation word anchors.

No language-ID predictions are used to make reference labels. The printed
original-language annotations supply labels; ASR supplies time anchors only.
Official edited records and interpretation are not verbatim audio truth.
"""
from __future__ import annotations

import bisect
from difflib import SequenceMatcher
import re
import unicodedata

LANGUAGES = {"Arabic": "ar", "Chinese": "zh", "English": "en",
             "French": "fr", "Russian": "ru", "Spanish": "es"}


def words(text):
    normalized = unicodedata.normalize("NFKD", text).casefold()
    normalized = "".join(c for c in normalized if not unicodedata.combining(c))
    return re.findall(r"[\w]+(?:['’][\w]+)*", normalized, flags=re.UNICODE)


def official_words(turn_document):
    result = []
    turns = turn_document.get("turns", turn_document)
    for ordinal, turn in enumerate(turns):
        text = turn.get("texts", {}).get("en", turn.get("text", ""))
        header = turn.get("records", {}).get("en", {}).get("header", turn.get("header", "")) or ""
        note = re.search(r"\(spoke in (\w+)\)", header)
        language = LANGUAGES.get(note.group(1)) if note else "en"
        # Existing turns carry more precise intraturn language ranges.
        ranges = turn.get("language_segments_in_english_record")
        if not ranges:
            ranges = []
            start = 0
            for marker in re.finditer(r"\(spoke in (Arabic|Chinese|English|French|Russian|Spanish)\)", text):
                ranges.append({"language": language, "text_start_char": start,
                               "text_end_char": marker.start()})
                language, start = LANGUAGES[marker.group(1)], marker.end()
            ranges.append({"language": language, "text_start_char": start, "text_end_char": len(text)})
        for subindex, segment in enumerate(ranges):
            language = segment["language"]
            snippet = text[segment["text_start_char"]:segment["text_end_char"]]
            for token in words(snippet):
                result.append({"word": token, "language": language,
                               "turn": ordinal + 1, "group": f"{ordinal + 1}:{subindex}"})
    return result


def timed_words(tokens, offset=0):
    """Join Parakeet subword pieces into words, retaining observed token times."""
    text, positions = "", []
    for token in tokens:
        for char in token.text:
            text += char
            positions.append((offset + token.start, offset + token.end))
    result = []
    for match in re.finditer(r"\w+(?:['’]\w+)*", text, re.UNICODE):
        normalized = words(match.group())
        if normalized:
            result.append({"word": normalized[0], "start_s": positions[match.start()][0],
                           "end_s": positions[match.end() - 1][1]})
    return result


def make_anchors(turn_document, observed, *, minimum_block=5):
    reference = official_words(turn_document)
    matcher = SequenceMatcher(None, [r["word"] for r in reference],
                              [r["word"] for r in observed], autojunk=False)
    anchors = []
    blocks = matcher.get_matching_blocks()
    for block_index, block in enumerate(blocks):
        if block.size < minimum_block:
            continue
        for i in range(block.size):
            ref, hyp = reference[block.a + i], observed[block.b + i]
            anchors.append({"time_s": (hyp["start_s"] + hyp["end_s"]) / 2,
                            "language": ref["language"], "turn": ref["turn"],
                            "group": ref["group"], "block": block_index})
    anchors.sort(key=lambda a: a["time_s"])
    return anchors, {"reference_words": len(reference), "observed_words": len(observed),
                     "matched_anchor_words": len(anchors), "minimum_exact_block_words": minimum_block,
                     "label_source": "official_language_annotations_only"}


def label_window(start, end, anchors, *, max_anchor_gap=20., boundary_margin=2.):
    if not anchors:
        return None, False, "no_public_alignment_anchors"
    times = [a["time_s"] for a in anchors]
    left = bisect.bisect_right(times, start) - 1
    right = bisect.bisect_left(times, end)
    if left < 0 or right >= len(anchors):
        return None, False, "unbracketed_audio"
    first, last = anchors[left], anchors[right]
    if start - first["time_s"] > max_anchor_gap or last["time_s"] - end > max_anchor_gap:
        return None, False, "distant_anchors"
    languages = {a["language"] for a in anchors[left:right + 1]}
    if len(languages) != 1 or next(iter(languages)) not in LANGUAGES.values():
        return None, False, "language_boundary_or_unknown"
    language = first["language"]
    # Guard against interpretation lag and segmentation at speaker switches.
    nearby = anchors[bisect.bisect_left(times, start - boundary_margin):
                     bisect.bisect_right(times, end + boundary_margin)]
    if any(a["language"] != language for a in nearby):
        return None, False, "near_language_boundary"
    return language, True, "bracketed_official_word_anchors"
