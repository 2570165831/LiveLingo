"""Read explicitly supplied local public corpora and export only to task work space."""
from __future__ import annotations

import argparse
from contextlib import ExitStack
from dataclasses import asdict, dataclass, field
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
from typing import Callable, Iterable, Mapping, Sequence
import unicodedata
import xml.etree.ElementTree as ET
import zipfile

from .reference_annotations import apply_reference_annotations

UN_LOCALES = ("ar", "zh", "en", "fr", "ru", "es")
OUTPUT_ROOT_ENV = "LIVELINGO_TARGET_EVAL_OUTPUT_ROOT"


@dataclass(frozen=True)
class ParallelUnit:
    id: str
    corpus: str
    texts: dict[str, str]
    metadata: dict = field(default_factory=dict)


@dataclass(frozen=True)
class CorpusResult:
    units: tuple[ParallelUnit, ...]
    excluded: tuple[dict, ...] = ()


@dataclass(frozen=True)
class Cue:
    id: str
    start_ms: int
    end_ms: int
    text: str


@dataclass(frozen=True)
class SubtitleAlignment:
    units: tuple[ParallelUnit, ...]
    unmatched: dict[str, tuple[str, ...]]


def repository_root() -> Path:
    return Path(__file__).resolve().parents[2]


def output_root() -> Path:
    """Read a required external directory, independent of checkout placement."""
    configured = os.environ.get(OUTPUT_ROOT_ENV)
    if not configured:
        raise ValueError(f"{OUTPUT_ROOT_ENV} is required; set it to an existing absolute "
                         "directory outside the repository")
    root = Path(configured)
    if not root.is_absolute():
        raise ValueError(f"{OUTPUT_ROOT_ENV} must be an absolute directory path")
    if root.resolve() != root:
        raise ValueError(f"{OUTPUT_ROOT_ENV} must not use symlinks or '..' components")
    if root.is_relative_to(repository_root()):
        raise ValueError(f"{OUTPUT_ROOT_ENV} must be outside the repository")
    if not root.is_dir():
        raise ValueError(f"{OUTPUT_ROOT_ENV} directory must already exist")
    return root


def validate_output_path(path: str | Path) -> Path:
    """Reject the checkout, paths outside the configured root and symlinks.

    Check the environment root and destination before creating any directory.
    """
    destination = Path(os.path.abspath(path))
    root = output_root()
    resolved = destination.resolve()
    if resolved.is_relative_to(repository_root()):
        raise ValueError("evaluation output must not be written inside the repository")
    if destination == root or not destination.is_relative_to(root):
        raise ValueError("evaluation output must be a file inside the configured output root")
    if not resolved.is_relative_to(root):
        raise ValueError("evaluation output resolves outside the configured output root")
    for ancestor in (destination, *destination.parents):
        if ancestor == root.parent:
            break
        if ancestor.is_symlink():
            raise ValueError("evaluation output must not use symlinks")
    return destination


def _write_text(path: str | Path, content: str) -> Path:
    destination = validate_output_path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    validate_output_path(destination)
    # Exclusive creation also refuses existing files and dangling leaf symlinks.
    with destination.open("x", encoding="utf-8", newline="\n") as handle:
        handle.write(content)
    return destination


def write_jsonl(units: Iterable[ParallelUnit], path: str | Path) -> Path:
    validate_output_path(path)
    content = "".join(json.dumps(asdict(unit), ensure_ascii=False, sort_keys=True,
                                 allow_nan=False) + "\n" for unit in units)
    return _write_text(path, content)


def write_json(value: dict, path: str | Path) -> Path:
    validate_output_path(path)
    return _write_text(path, json.dumps(value, ensure_ascii=False, sort_keys=True,
                                       indent=2, allow_nan=False) + "\n")


def _positive_integer(value: object, label: str) -> int:
    if type(value) is not int or value <= 0:
        raise ValueError(f"{label} must be a positive integer")
    return value


def _text(value: object, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{label} must be nonempty text")
    return value


def _un_turn_notes(data: dict, turn_indices: set[int]) -> dict[str, dict[int, list[dict]]]:
    """Index curated diagnostics without silently dropping malformed selectors."""
    notes = {}
    for field in ("language_note_conflicts", "mapping_corrections"):
        entries = data.get(field, [])
        if not isinstance(entries, list):
            raise ValueError(f"UN {field} must be a list")
        by_turn = {}
        for entry in entries:
            if not isinstance(entry, dict):
                raise ValueError(f"UN {field} entries must be objects")
            if field == "language_note_conflicts":
                indices = [_positive_integer(entry.get("index"), "UN conflict turn index")]
            else:
                indices = entry.get("affected_english_indices")
                if not isinstance(indices, list) or not indices:
                    raise ValueError("UN mapping correction requires affected_english_indices")
                indices = [_positive_integer(i, "UN correction turn index") for i in indices]
            if any(i not in turn_indices for i in indices):
                raise ValueError(f"UN {field} refers to an unknown turn")
            for index in dict.fromkeys(indices):
                by_turn.setdefault(index, []).append(entry)
        notes[field] = by_turn
    return notes


def read_un_meeting(path: str | Path, *, include_partial: bool = False) -> CorpusResult:
    """Use the local turns.json schema, preserving curated six-way mappings.

    Incomplete extracted text is excluded by default and always reported. Raw
    record turn counts may differ after a curated correction; never realign by
    zipping raw records. Only catalogue-listed, hash-bound reference annotations
    are applied in memory and retained in metadata. Raw files are never changed.
    No timestamps are inferred from text length.
    """
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    if (not isinstance(data, dict) or type(data.get("schema_version")) is not int
            or data["schema_version"] != 1):
        raise ValueError("unsupported UN turns schema (expected schema_version 1)")
    meeting = _text(data.get("id"), "UN meeting id")
    turns = data.get("turns")
    if not isinstance(turns, list) or not turns:
        raise ValueError("UN meeting must contain turns")
    if type(data.get("turn_count")) is not int or data["turn_count"] != len(turns):
        raise ValueError("UN turn_count does not match the mapped turns")
    if data.get("country_header_checks_all_passed") is False:
        raise ValueError("UN curated speaker mapping failed its header checks")
    mapped_counts = data.get("mapped_turn_counts")
    if mapped_counts is not None and (not isinstance(mapped_counts, dict) or any(
            type(mapped_counts.get(locale)) is not int or mapped_counts[locale] != len(turns)
            for locale in UN_LOCALES)):
        raise ValueError("UN six-language mapped counts do not match")
    indices = []
    for turn in turns:
        if not isinstance(turn, dict):
            raise ValueError("UN turn must be an object")
        indices.append(_positive_integer(turn.get("index"), "UN turn index"))
    if len(set(indices)) != len(indices):
        raise ValueError("duplicate UN turn index")
    notes = _un_turn_notes(data, set(indices))
    units, excluded = [], []
    for turn, index in zip(turns, indices, strict=True):
        texts, statuses = turn.get("texts"), turn.get("text_status")
        if not isinstance(texts, dict) or not isinstance(statuses, dict):
            raise ValueError("UN turn requires texts and text_status by locale")
        six_texts = {locale: _text(texts.get(locale), f"UN {locale} text")
                     for locale in UN_LOCALES}
        six_statuses = {locale: _text(statuses.get(locale), f"UN {locale} text_status")
                        for locale in UN_LOCALES}
        unit_id = f"{meeting}:turn:{index}"
        partial = {locale: status for locale, status in six_statuses.items()
                   if status != "extracted"}
        turn_notes = {field: by_turn.get(index, []) for field, by_turn in notes.items()}
        if partial:
            excluded.append({"id": unit_id, "text_status": partial,
                             "included_by_request": include_partial, **turn_notes})
            if not include_partial:
                continue
        metadata = {"turn_index": index, "text_status": six_statuses,
                    "original_language": turn.get("original_language"),
                    "original_languages": turn.get("original_languages", []),
                    "alignment": "curated-turn-index",
                    "audio_alignment": "not-used", **turn_notes}
        six_texts, annotations = apply_reference_annotations(meeting, index, six_texts)
        if annotations:
            metadata["reference_annotations"] = annotations
        units.append(ParallelUnit(unit_id, "un", six_texts, metadata))
    return CorpusResult(tuple(units), tuple(excluded))


def read_un(root: str | Path, *, include_partial: bool = False) -> CorpusResult:
    """Read only S_PV.*/turns.json; never scan audio, records or quarantines."""
    paths = sorted(Path(root).glob("S_PV.*/turns.json"))
    if not paths:
        raise ValueError("no UN S_PV.*/turns.json files found")
    units, excluded, seen = [], [], set()
    for path in paths:
        result = read_un_meeting(path, include_partial=include_partial)
        for unit in result.units:
            if unit.id in seen:
                raise ValueError("duplicate UN meeting/turn identity")
            seen.add(unit.id)
        units.extend(result.units)
        excluded.extend(result.excluded)
    return CorpusResult(tuple(units), tuple(excluded))


_TIMESTAMP = r"(\d{2,}):([0-5]\d):([0-5]\d)[,.](\d{3})"
_TIMING = re.compile(rf"^{_TIMESTAMP}\s+-->\s+{_TIMESTAMP}(?:[ \t]+.*)?$")


def _milliseconds(parts: Sequence[str]) -> int:
    hours, minutes, seconds, milliseconds = map(int, parts)
    return ((hours * 60 + minutes) * 60 + seconds) * 1000 + milliseconds


def _validate_cues(cues: Sequence[Cue]) -> None:
    seen, previous_start = set(), -1
    for cue in cues:
        _text(cue.id, "cue id")
        _text(cue.text, "cue text")
        if cue.id in seen:
            raise ValueError("duplicate subtitle cue id")
        seen.add(cue.id)
        if (type(cue.start_ms) is not int or type(cue.end_ms) is not int
                or cue.start_ms < 0 or cue.end_ms <= cue.start_ms):
            raise ValueError("subtitle cue must have positive duration in integer milliseconds")
        if cue.start_ms < previous_start:
            raise ValueError("subtitle cues must be ordered by start time")
        previous_start = cue.start_ms


def read_srt(path: str | Path) -> tuple[Cue, ...]:
    """Parse UTF-8/BOM SRT, retaining multiline text and inline markup verbatim."""
    text = Path(path).read_text(encoding="utf-8-sig")
    blocks = re.split(r"\n(?:[ \t]*\n)+", text.strip()) if text.strip() else []
    cues = []
    for block in blocks:
        lines = block.splitlines()
        if len(lines) < 3 or not lines[0].strip().isdigit():
            raise ValueError("SRT cue needs a numeric index, timing line and text")
        timing = _TIMING.fullmatch(lines[1].strip())
        if timing is None:
            raise ValueError("malformed SRT timestamp")
        cues.append(Cue(str(int(lines[0].strip())),
                        _milliseconds(timing.groups()[:4]),
                        _milliseconds(timing.groups()[4:]), "\n".join(lines[2:])))
    _validate_cues(cues)
    return tuple(cues)


def align_subtitles(cues_by_locale: Mapping[str, Sequence[Cue]], *,
                    corpus: str = "cs50", document_id: str = "subtitles") -> SubtitleAlignment:
    """Group connected positive overlaps across locales (one/many in either side).

    Touching endpoints do not overlap. Each cue appears once. A connected group
    missing any requested locale is withheld and its IDs reported as unmatched;
    transitive overlaps can produce a long group, whose cue IDs and span remain
    visible for later review. This is temporal alignment, not a semantic claim.
    """
    if len(cues_by_locale) < 2:
        raise ValueError("subtitle alignment requires at least two locales")
    _text(document_id, "subtitle document id")
    nodes = []
    for locale, cues in sorted(cues_by_locale.items()):
        _text(locale, "subtitle locale")
        _validate_cues(cues)
        nodes.extend((locale, cue) for cue in cues)
    nodes.sort(key=lambda item: (item[1].start_ms, item[0], item[1].id))
    parents = list(range(len(nodes)))

    def find(index):
        while parents[index] != index:
            parents[index] = parents[parents[index]]
            index = parents[index]
        return index

    active = []
    for i, (locale, cue) in enumerate(nodes):
        active = [j for j in active if nodes[j][1].end_ms > cue.start_ms]
        for j in active:
            if nodes[j][0] != locale:
                parents[find(i)] = find(j)
        active.append(i)
    groups = {}
    for i, node in enumerate(nodes):
        groups.setdefault(find(i), []).append(node)
    units = []
    unmatched = {locale: [] for locale in sorted(cues_by_locale)}
    for group in groups.values():
        grouped = {locale: [cue for lang, cue in group if lang == locale]
                   for locale in sorted(cues_by_locale)}
        if not all(grouped.values()):
            for locale, cues in grouped.items():
                unmatched[locale].extend(cue.id for cue in cues)
            continue
        start, end = min(cue.start_ms for _, cue in group), max(cue.end_ms for _, cue in group)
        metadata = {"alignment": "positive-time-overlap-component", "start_ms": start,
                    "end_ms": end, "cue_ids": {locale: [cue.id for cue in cues]
                                                 for locale, cues in grouped.items()}}
        units.append(ParallelUnit(f"{document_id}:group:{len(units) + 1}", corpus,
                                  {locale: "\n".join(cue.text for cue in cues)
                                   for locale, cues in grouped.items()}, metadata))
    return SubtitleAlignment(tuple(units), {k: tuple(v) for k, v in unmatched.items()})


def read_cs50_srts(paths: Mapping[str, str | Path], *, document_id: str) -> SubtitleAlignment:
    return align_subtitles({locale: read_srt(path) for locale, path in paths.items()},
                           corpus="cs50", document_id=document_id)


def read_ted_srts(paths: Mapping[str, str | Path], *, document_id: str) -> SubtitleAlignment:
    """Local SRT interface only; no downloads, language guessing or license assertion."""
    return align_subtitles({locale: read_srt(path) for locale, path in paths.items()},
                           corpus="ted", document_id=document_id)


def _opus_document(value: str, locale: str) -> str:
    """OPUS language directories differ; the stable talk basename must agree."""
    path = Path(value)
    if (path.is_absolute() or ".." in path.parts or len(path.parts) != 2
            or path.parts[0] != locale or not path.name.endswith(".xml.gz")):
        raise ValueError("invalid OPUS document identity")
    return path.name.removesuffix(".xml.gz")


def _opus_links(path: Path, source: str, target: str) -> dict:
    documents = {}
    with gzip.open(path, "rb") as handle:
        for _, group in ET.iterparse(handle, events=("end",)):
            if group.tag != "linkGrp":
                continue
            document = _opus_document(group.attrib.get("fromDoc", ""), source)
            if document != _opus_document(group.attrib.get("toDoc", ""), target):
                raise ValueError("OPUS alignment joins different talks")
            if document in documents:
                raise ValueError("duplicate OPUS talk alignment")
            links = {}
            for link in group.findall("link"):
                fields = link.attrib.get("xtargets", "").split(";")
                if len(fields) != 2:
                    raise ValueError("invalid OPUS xtargets")
                left, right = (tuple(field.split()) for field in fields)
                # Empty alignments are omissions, not translations.
                if not left or not right:
                    continue
                if len(set(left)) != len(left) or len(set(right)) != len(right):
                    raise ValueError("duplicate OPUS sentence ID within an alignment")
                pivot, translated = (left, right) if source == "en" else (right, left)
                if pivot in links:
                    raise ValueError("ambiguous duplicate OPUS English anchor")
                links[pivot] = translated
            documents[document] = links
            group.clear()
    return documents


def _opus_sentences(archive: zipfile.ZipFile, locale: str, document: str) -> dict[str, str]:
    member = f"TED2020/raw/{locale}/{document}.xml"
    if archive.namelist().count(member) != 1:
        raise ValueError("OPUS raw talk must have exactly one archive member")
    # Read a known member in memory; never extract files or fetch external DTDs.
    data = archive.read(member)
    if b"<!ENTITY" in data:
        raise ValueError("OPUS XML entity declarations are unsupported")
    texts = {}
    for sentence in ET.fromstring(data).iter("s"):
        identity = _text(sentence.attrib.get("id"), "OPUS sentence ID")
        if identity in texts:
            raise ValueError("duplicate OPUS raw sentence ID")
        texts[identity] = _text("".join(sentence.itertext()), "OPUS sentence")
    return texts


def read_ted_opus(raw_paths: Mapping[str, str | Path], alignment_paths: Sequence[dict]) -> CorpusResult:
    """One deterministic, text-deduplicated six-way reference per TED talk.

    Use only exact English sentence-ID tuples shared by all five official XCES
    alignments. Concatenate a many-to-many alignment in its supplied ID order;
    never guess sentence matches from text or length. Selection is independent
    of text length, verdicts and the later document-level holdout split.
    """
    if set(raw_paths) != set(UN_LOCALES):
        raise ValueError("OPUS calibration requires raw en/es/fr/zh/ru/ar archives")
    mappings, raw_locales = {}, {"en": "en"}
    for spec in alignment_paths:
        source, target = spec["source"], spec["target"]
        if (source == "en") == (target == "en"):
            raise ValueError("OPUS calibration alignments must have one English pivot")
        locale = spec["locale"]
        if locale not in set(UN_LOCALES) - {"en"} or locale in mappings:
            raise ValueError("duplicate or unsupported OPUS mapped locale")
        raw_locales[locale] = target if source == "en" else source
        mappings[locale] = _opus_links(Path(spec["path"]), source, target)
    if set(mappings) != set(UN_LOCALES) - {"en"}:
        raise ValueError("OPUS requires five distinct English-pivot alignments")
    documents = sorted(set.union(*(set(mapping) for mapping in mappings.values())))
    seen_texts = {locale: set() for locale in UN_LOCALES}
    units, excluded = [], []
    with ExitStack() as stack:
        archives = {locale: stack.enter_context(zipfile.ZipFile(path))
                    for locale, path in raw_paths.items()}
        for document in documents:
            if any(document not in mapping for mapping in mappings.values()):
                excluded.append({"document_id": document, "reason": "missing_parallel_talk"})
                continue
            anchors = set.intersection(*(set(mapping[document]) for mapping in mappings.values()))
            ordered = sorted(anchors, key=lambda ids: hashlib.sha256(json.dumps(
                [document, ids], separators=(",", ":")).encode()).digest())
            if not ordered:
                excluded.append({"document_id": document, "reason": "no_exact_common_anchor"})
                continue
            sentences = {locale: _opus_sentences(archives[locale], raw_locales[locale], document)
                         for locale in UN_LOCALES}
            duplicate_candidates = 0
            for pivot in ordered:
                ids = {"en": pivot, **{locale: mapping[document][pivot]
                                        for locale, mapping in mappings.items()}}
                try:
                    texts = {locale: " ".join(sentences[locale][identity] for identity in values)
                             for locale, values in ids.items()}
                except KeyError as error:
                    raise ValueError("OPUS alignment refers to a missing raw sentence") from error
                normalized = {locale: " ".join(unicodedata.normalize("NFC", text).split())
                              for locale, text in texts.items()}
                if any(text in seen_texts[locale] for locale, text in normalized.items()):
                    duplicate_candidates += 1
                    continue
                for locale, text in normalized.items():
                    seen_texts[locale].add(text)
                identity = json.dumps(["ted2020", document, pivot], separators=(",", ":"))
                units.append(ParallelUnit(identity, "ted2020", texts, {
                    "document_id": document, "split_group": f"ted2020:{document}",
                    "alignment": "exact-common-English-XCES-anchor", "sentence_ids": ids,
                    "reference_status": "community-human", "eligible_anchor_count": len(anchors),
                    "duplicate_candidates_skipped": duplicate_candidates,
                    "selection": "first SHA-256-ranked anchor with unique NFC text in every locale"}))
                break
            else:
                excluded.append({"document_id": document, "reason": "only_duplicate_references"})
    return CorpusResult(tuple(units), tuple(excluded))


def read_public_manifest(path: str | Path, *,
                         on_input: Callable[[Path], None] | None = None) -> tuple[CorpusResult, list[Path]]:
    """Only explicitly listed public files; no discovery of classroom/UN data.

    Relative paths resolve against the manifest directory. Unknown reference
    authorship stays visible and is excluded from fitting by calibrate.py.
    FLORES+ JSONL preserves article URLs as split groups, across dev/devtest.
    """
    manifest = Path(path).resolve()
    if on_input:
        on_input(manifest)
    data = json.loads(manifest.read_text(encoding="utf-8"))
    if (type(data.get("schema_version")) is not int or data["schema_version"] != 1
            or not isinstance(data.get("corpora"), list)):
        raise ValueError("public manifest requires schema_version 1 and corpora list")
    files, units, excluded = [manifest], [], []

    def local(value):
        candidate = Path(_text(value, "manifest input path"))
        resolved = (candidate if candidate.is_absolute() else manifest.parent / candidate).resolve()
        if not resolved.is_file():
            raise ValueError("manifest input file is missing")
        if on_input and resolved not in files:
            on_input(resolved)
        files.append(resolved)
        return resolved

    for spec in data["corpora"]:
        name = spec["format"]
        if name == "opus-ted2020":
            raw = {locale: local(value) for locale, value in spec["raw"].items()}
            alignments = [{**item, "path": local(item["path"])} for item in spec["alignments"]]
            result = read_ted_opus(raw, alignments)
            units.extend(result.units)
            excluded.extend(result.excluded)
        elif name == "cs50-srt":
            document = _text(spec["document_id"], "CS50 document ID")
            result = read_cs50_srts({locale: local(value) for locale, value in spec["files"].items()},
                                    document_id=document)
            status = _text(spec["reference_status"], "CS50 reference status")
            for unit in result.units:
                units.append(ParallelUnit(unit.id, unit.corpus, unit.texts, {
                    **unit.metadata, "document_id": document, "split_group": f"cs50:{document}",
                    "reference_status": status}))
            excluded.append({"document_id": document, "unmatched_cues": result.unmatched})
        elif name == "flores-plus-jsonl":
            rows = {}
            for locale, value in spec["files"].items():
                rows[locale] = {}
                for line in local(value).read_text(encoding="utf-8").splitlines():
                    row = json.loads(line)
                    key = (row["split"], str(row["id"]))
                    if key in rows[locale]:
                        raise ValueError("duplicate FLORES+ split/ID")
                    _text(row.get("text"), "FLORES+ text")
                    _text(row.get("url"), "FLORES+ article URL required for holdout")
                    rows[locale][key] = row
            if len(rows) < 2 or not all(set(values) == set(next(iter(rows.values())))
                                        for values in rows.values()):
                raise ValueError("FLORES+ JSONL locales must have identical split/ID keys")
            for key in sorted(next(iter(rows.values()))):
                articles = {values[key]["url"] for values in rows.values()}
                if len(articles) != 1:
                    raise ValueError("FLORES+ locales disagree on source article")
                article = articles.pop()
                identity = json.dumps(["flores-plus", *key], separators=(",", ":"))
                units.append(ParallelUnit(identity, "flores-plus",
                    {locale: values[key]["text"] for locale, values in rows.items()}, {
                        "document_id": article, "split_group": f"flores-plus:{article}",
                        "reference_status": "human", "alignment": "explicit-split-ID"}))
        else:
            raise ValueError("unsupported public corpus manifest format")
    if not units or len({unit.id for unit in units}) != len(units):
        raise ValueError("public manifest has no units or duplicate identities")
    return CorpusResult(tuple(units), tuple(excluded)), sorted(set(files))


def read_flores_plus(paths: Mapping[str, str | Path], *, split: str = "devtest") -> tuple[ParallelUnit, ...]:
    """Read caller-supplied UTF-8 line-aligned files; keys are explicit locale labels.

    For example, label a supplied eng_Latn file ``en`` and zho_Hant ``zh-Hant``.
    Do not drop blank lines and shift the alignment, or truncate unequal files.
    """
    if len(paths) < 2:
        raise ValueError("FLORES+ requires at least two locale files")
    _text(split, "FLORES+ split")
    lines = {}
    for locale, path in sorted(paths.items()):
        _text(locale, "FLORES+ locale")
        # newline="" preserves bare CR so it can be rejected, while CRLF is an
        # explicit supported newline convention rather than a hidden extra row.
        with Path(path).open(encoding="utf-8-sig", newline="") as handle:
            rows = handle.read().replace("\r\n", "\n").split("\n")
        if rows[-1] == "":
            rows.pop()
        if any(re.search(r"[\r\x0b\x0c\x1c-\x1e\x85\u2028\u2029]", row) for row in rows):
            raise ValueError(f"FLORES+ {locale} contains a non-newline line separator")
        lines[locale] = rows
    lengths = {len(rows) for rows in lines.values()}
    if len(lengths) != 1 or 0 in lengths:
        raise ValueError("FLORES+ locale files must have equal, nonzero line counts")
    units = []
    for i in range(next(iter(lengths))):
        texts = {locale: _text(rows[i], f"FLORES+ {locale} line {i + 1}")
                 for locale, rows in lines.items()}
        units.append(ParallelUnit(f"flores-plus:{split}:{i + 1}", "flores-plus", texts,
                                  {"alignment": "supplied-line-index", "split": split}))
    return tuple(units)


def _locale_files(values: Sequence[str]) -> dict[str, Path]:
    paths = {}
    for value in values:
        locale, separator, path = value.partition("=")
        if not separator or not locale or not path or locale in paths:
            raise ValueError("locale files must be unique LOCALE=PATH arguments")
        paths[locale] = Path(path)
    return paths


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("corpus", choices=("un", "cs50", "ted", "flores-plus"))
    parser.add_argument("--input", help="local UN data root")
    parser.add_argument("--locale-file", action="append", default=[], metavar="LOCALE=PATH")
    parser.add_argument("--document-id", help="unique CS50/TED video identifier")
    parser.add_argument("--split", default="devtest")
    parser.add_argument("--include-partial", action="store_true", help="UN only; retain reported partial turns")
    parser.add_argument("--output", required=True,
                        help=f"new JSONL file inside the directory set by {OUTPUT_ROOT_ENV}")
    args = parser.parse_args(argv)
    try:
        destination = validate_output_path(args.output)
        if args.corpus == "un":
            if not args.input or args.locale_file:
                raise ValueError("UN requires --input and does not use --locale-file")
            result = read_un(args.input, include_partial=args.include_partial)
            units, diagnostics = result.units, {"incomplete_turns": result.excluded}
        else:
            if args.input or args.include_partial:
                raise ValueError("--input and --include-partial are UN-only")
            paths = _locale_files(args.locale_file)
            if args.corpus == "flores-plus":
                units, diagnostics = read_flores_plus(paths, split=args.split), {}
            else:
                if not args.document_id:
                    raise ValueError("CS50/TED requires --document-id")
                reader = read_cs50_srts if args.corpus == "cs50" else read_ted_srts
                result = reader(paths, document_id=args.document_id)
                units, diagnostics = result.units, {"unmatched_cues": result.unmatched}
        # Store coverage diagnostics in every exported unit; also print them when
        # zero units align so an empty output cannot conceal excluded data.
        exported = (ParallelUnit(u.id, u.corpus, u.texts,
                                 {**u.metadata, "corpus_diagnostics": diagnostics}) for u in units)
        write_jsonl(exported, destination)
        print(json.dumps({"unit_count": len(units), **diagnostics}, ensure_ascii=False))
    except (OSError, ValueError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
