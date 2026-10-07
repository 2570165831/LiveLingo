"""Narrow, hash-bound corrections to local references, never to raw records.

The catalogue is evidence metadata, not a general confusable-character filter.
Only the named reference and exact original text may receive a correction.
"""
from __future__ import annotations

from copy import deepcopy
from dataclasses import dataclass
import hashlib
from typing import Mapping


@dataclass(frozen=True)
class ReferenceAnnotation:
    id: str
    meeting: str
    turn_index: int
    locale: str
    original_text_sha256: str
    unicode_scalar_offset: int
    original: str
    replacement: str
    provenance: dict


ANNOTATIONS = (
    ReferenceAnnotation(
        id="un-S_PV.10142-turn-9-en-U03A4",
        meeting="S/PV.10142", turn_index=9, locale="en",
        original_text_sha256="c8df1a159803b112f28fcc26904b5af7ecf1463faca2a0b0474e45f26cb0f611",
        unicode_scalar_offset=3408, original="\u03a4", replacement="T",
        provenance={
            "kind": "official-record-text-layer-reference-defect",
            "source_url": "https://documents.un.org/doc/undoc/pro/n26/093/60/pdf/n2609360.pdf",
            "record_pdf": "S_PV.10142/record-en.pdf",
            "record_pdf_sha256": "92dffaa06c144bc7cc5de324ac9a2c88fa437182707fd75d28e9e4fb9ef313c1",
            "record_text": "S_PV.10142/record-en.txt",
            "record_text_sha256": "4a415b385068538b7a66319c80644dfb663a839187595b0667e26eb5373d8932",
            "record_page_one_based": 11,
            "record_text_line_one_based": 564,
            "record_text_unicode_scalar_offset": 47825,
            "verification": "Local PDF page 11 independently re-extracted with pdftotext -layout; U+03A4 also occurs in the stored record text and curated English turn. No network verification.",
            "rationale": "Greek capital Tau in the initial letter of an English word is a reference transcription defect; annotate as Latin capital T before evaluation. The nonLatinScript acceptance rule stays unchanged.",
            "raw_files_modified": False,
        }),
)


def apply_reference_annotations(meeting: str, turn_index: int,
                                texts: Mapping[str, str]) -> tuple[dict[str, str], list[dict]]:
    corrected, applied = dict(texts), []
    for annotation in ANNOTATIONS:
        if (annotation.meeting, annotation.turn_index) != (meeting, turn_index):
            continue
        original = corrected[annotation.locale]
        original_hash = hashlib.sha256(original.encode("utf-8")).hexdigest()
        offset = annotation.unicode_scalar_offset
        if (original_hash != annotation.original_text_sha256
                or original[offset:offset + len(annotation.original)] != annotation.original):
            raise ValueError(f"reference annotation no longer matches its original: {annotation.id}")
        replacement = (original[:offset] + annotation.replacement
                       + original[offset + len(annotation.original):])
        corrected[annotation.locale] = replacement
        applied.append({
            "id": annotation.id, "turn_id": f"{meeting}:turn:{turn_index}",
            "locale": annotation.locale,
            "unicode_scalar_offset": offset, "offset_basis": "zero-based Python Unicode scalars",
            "original_codepoints": [f"U+{ord(ch):04X}" for ch in annotation.original],
            "replacement_codepoints": [f"U+{ord(ch):04X}" for ch in annotation.replacement],
            "original_text_sha256": original_hash,
            "annotated_text_sha256": hashlib.sha256(replacement.encode("utf-8")).hexdigest(),
            "provenance": deepcopy(annotation.provenance),
        })
    return corrected, applied
