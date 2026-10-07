"""Offline, hash-bound es/zh length arithmetic for the copyfix review.

Read only the four existing meetings; never invoke the acceptance CLI. This
separate diagnostic leaves calibrate.py and its frozen tests unchanged. Reports
are created exclusively under the sibling work/dd-copyfix directory.
"""
from __future__ import annotations

import argparse
from collections import defaultdict
from dataclasses import dataclass
from fractions import Fraction
import hashlib
import json
from pathlib import Path
from typing import Sequence
import unicodedata


LOCALES = ("ar", "zh", "en", "fr", "ru", "es")
MEETINGS = (
    ("10142", "8f23724176b6bfab8011556c1fe1149440e880d574934118bfa0c6ca95f8f459", 18, 18),
    ("10153", "28edc8c70bae200a5d9cbfe392eaaf6ee5676a292908b30c1e811b3c44a13326", 17, 17),
    ("10168", "8411e448f9ab11dda919e3ad9b240a94ede6088d24e99cb1de23eba9d12d8331", 24, 22),
    ("10192", "44ce01bcd28997f781062bb378f32729e3e798da3eeb413d3b59303a2cb940ca", 28, 28),
)
FLOOR = 24
ALLOWANCE = 12
QUANTILE = Fraction(199, 200)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def letter_count(text: str) -> int:
    return sum(unicodedata.category(char) in ("Lu", "Ll", "Lt", "Lm", "Lo")
               for char in unicodedata.normalize("NFC", text))


def exact_number(value: Fraction) -> dict:
    return {"value": float(value), "numerator": value.numerator,
            "denominator": value.denominator}


def ceil_hundredth(value: Fraction) -> Fraction:
    scaled = value * 100
    return Fraction(-(-scaled.numerator // scaled.denominator), 100)


@dataclass(frozen=True)
class Observation:
    turn_id: str
    source: str
    target: str

    def __post_init__(self) -> None:
        if not self.turn_id or not isinstance(self.source, str) or not isinstance(self.target, str):
            raise ValueError("an observation requires identity and text")
        if self.source_letters == 0 or self.target_letters == 0:
            raise ValueError("es/zh ratios require positive source and target letter counts")

    @property
    def source_letters(self) -> int:
        return letter_count(self.source)

    @property
    def target_letters(self) -> int:
        return letter_count(self.target)

    @property
    def raw_ratio(self) -> Fraction:
        return Fraction(self.target_letters, self.source_letters)

    @property
    def floor_ratio(self) -> Fraction:
        return Fraction(self.target_letters, max(self.source_letters, FLOOR))

    def public(self) -> dict:
        return {"turn_id": self.turn_id, "source_letters": self.source_letters,
                "target_letters": self.target_letters,
                "source_raw_utf8_sha256": sha256(self.source.encode("utf-8")),
                "source_nfc_utf8_sha256": sha256(unicodedata.normalize("NFC", self.source).encode("utf-8")),
                "target_raw_utf8_sha256": sha256(self.target.encode("utf-8")),
                "target_nfc_utf8_sha256": sha256(unicodedata.normalize("NFC", self.target).encode("utf-8")),
                "raw_ratio": exact_number(self.raw_ratio),
                "floor_ratio": exact_number(self.floor_ratio)}


def read_meeting(path: Path, expected_id: str, expected_sha256: str) -> tuple[list[Observation], dict]:
    raw = path.read_bytes()
    if sha256(raw) != expected_sha256:
        raise ValueError("meeting hash differs from the reviewed raw data")
    data = json.loads(raw)
    turns = data.get("turns")
    if (type(data.get("schema_version")) is not int or data["schema_version"] != 1
            or data.get("id") != expected_id or not isinstance(turns, list) or not turns
            or type(data.get("turn_count")) is not int or data["turn_count"] != len(turns)
            or data.get("country_header_checks_all_passed") is not True):
        raise ValueError("invalid curated meeting schema or mapping")
    mapped = data.get("mapped_turn_counts")
    if not isinstance(mapped, dict) or any(
            type(mapped.get(locale)) is not int or mapped[locale] != len(turns) for locale in LOCALES):
        raise ValueError("six-language mapped turn counts disagree")
    observations, excluded, seen = [], [], set()
    for turn in turns:
        index = turn.get("index")
        if type(index) is not int or index <= 0 or index in seen:
            raise ValueError("invalid or duplicate curated turn index")
        seen.add(index)
        texts, statuses = turn.get("texts"), turn.get("text_status")
        if not isinstance(texts, dict) or not isinstance(statuses, dict) or any(
                not isinstance(texts.get(locale), str) or not texts[locale].strip()
                or not isinstance(statuses.get(locale), str) or not statuses[locale].strip()
                for locale in LOCALES):
            raise ValueError("a curated turn needs six nonempty texts and statuses")
        identity = f"{expected_id}:turn:{index}"
        partial = {locale: statuses[locale] for locale in LOCALES if statuses[locale] != "extracted"}
        if partial:
            excluded.append({"turn_id": identity, "text_status": partial})
        else:
            observations.append(Observation(identity, texts["zh"], texts["es"]))
    return observations, {"path": f"{path.parent.name}/turns.json", "bytes": len(raw),
                          "sha256": sha256(raw), "total_turns": len(turns),
                          "included_turns": len(observations), "excluded": excluded}


def deduplicate_source(rows: Sequence[Observation]) -> tuple[list[Observation], list[dict]]:
    groups = defaultdict(list)
    for row in rows:
        groups[unicodedata.normalize("NFC", row.source)].append(row)
    retained, duplicates = [], []
    for source, group in groups.items():
        representative = min(group, key=lambda row: (-row.raw_ratio, row.turn_id))
        retained.append(representative)
        if len(group) > 1:
            duplicates.append({"source_nfc_utf8_sha256": sha256(source.encode("utf-8")),
                               "turn_ids": sorted(row.turn_id for row in group),
                               "retained_turn_id": representative.turn_id,
                               "selection": "largest target/source ratio; ties use smallest turn ID"})
    return retained, duplicates


def quantile_summary(rows: Sequence[Observation], *, floor_adjusted: bool = False) -> dict:
    if not rows:
        raise ValueError("a quantile requires observations")
    ratio = (lambda row: row.floor_ratio) if floor_adjusted else (lambda row: row.raw_ratio)
    ordered = sorted(rows, key=lambda row: (ratio(row), row.turn_id))
    position = (len(ordered) - 1) * QUANTILE
    low = position.numerator // position.denominator
    high = -(-position.numerator // position.denominator)
    weight = position - low
    result = ratio(ordered[low]) + (ratio(ordered[high]) - ratio(ordered[low])) * weight
    return {"sample_count": len(ordered), "ratio_denominator": "max(source_letters, 24)" if floor_adjusted else "source_letters",
            "p99_5": exact_number(result), "ceil_0_01": float(ceil_hundredth(result)),
            "max": exact_number(ratio(ordered[-1])),
            "interpolation": {"zero_based_position": exact_number(position),
                              "lower_index": low, "upper_index": high,
                              "upper_weight": exact_number(weight),
                              "lower_observation": ordered[low].public(),
                              "upper_observation": ordered[high].public()}}


def length_only_check(rows: Sequence[Observation], coefficient: Fraction) -> dict:
    rejected = []
    for row in rows:
        limit = max(row.source_letters, FLOOR) * coefficient + ALLOWANCE
        if row.target_letters > limit:
            rejected.append({**row.public(), "maximum_output_letters": exact_number(limit),
                             "excess_letters": exact_number(row.target_letters - limit)})
    return {"coefficient": float(coefficient), "reference_count": len(rows),
            "length_rejected_count": len(rejected), "length_rejected": rejected,
            "scope": "arithmetic only; not a Swift verdict or translation-quality result"}


def build_report(rows: Sequence[Observation]) -> dict:
    if not rows or len({row.turn_id for row in rows}) != len(rows):
        raise ValueError("observations must have distinct turn identities")
    deduplicated, duplicates = deduplicate_source(rows)
    short = [row for row in rows if row.source_letters < FLOOR]
    long = [row for row in rows if row.source_letters >= FLOOR]
    summaries = {"all_raw": quantile_summary(rows),
                 "source_deduplicated_raw": quantile_summary(deduplicated),
                 "source_at_least_24_raw": quantile_summary(long),
                 "all_floor_adjusted": quantile_summary(rows, floor_adjusted=True)}
    if short:
        summaries["source_below_24_raw"] = quantile_summary(short)
        summaries["source_below_24_floor_adjusted"] = quantile_summary(short, floor_adjusted=True)
    provisional = Fraction(str(summaries["source_at_least_24_raw"]["ceil_0_01"]))
    required = max(Fraction(row.target_letters - ALLOWANCE, max(row.source_letters, FLOOR))
                   for row in rows)
    preservation = ceil_hundredth(required)
    return {"schema_version": 1, "target_locale": "es", "source_language": "zh",
            "methods": {
                "letters": "NFC then Unicode Lu/Ll/Lt/Lm/Lo scalars; all scripts included, no accent folding",
                "unicode_database_version": unicodedata.unidata_version,
                "selection": "all six texts nonempty and all six statuses extracted; never filter by length or verdict",
                "references": "raw curated whole turns, not sentences; no es/zh reference annotation applied",
                "quantile": "sort ratios; linear interpolation at (n-1)*199/200 with exact rational arithmetic",
                "rounding": "ceil(p99.5*100)/100 using exact integers",
                "source_deduplication": "identical NFC Chinese whole text; no trimming or punctuation removal; retain largest ratio once",
                "stratification": "source_letters < 24 versus >= 24, before any verdict",
                "floor_adjustment": "target_letters/max(source_letters,24); the fixed +12 is not subtracted for quantiles",
                "length_check": "target_letters <= max(source_letters,24)*coefficient+12; arithmetic only"},
            "sample_count": len(rows), "distinct_nfc_sources": len(deduplicated),
            "source_duplicate_groups": duplicates, "quantiles": summaries,
            "recommendation": {"provisional_p99_5_coefficient": float(provisional),
                               "basis": "ceiling of >=24-source p99.5; compare all-floor-adjusted ceiling",
                               "minimum_coefficient_to_preserve_this_sample": exact_number(required),
                               "sample_preserving_ceil_0_01": float(preservation),
                               "sample_preservation_basis": "max((target_letters-12)/max(source_letters,24)); NOT p99.5",
                               "swift_constants_modified": False},
            "length_only_checks": [length_only_check(rows, value) for value in dict.fromkeys(
                (Fraction(544, 100), Fraction(str(summaries["source_deduplicated_raw"]["ceil_0_01"])),
                 provisional, preservation))],
            "holdout": {"present": False, "independent_quality_gate_passed": False,
                        "limitations": "same 85 calibration turns; repeated meeting/template dependencies; no model, CLI verdict, subtitle or overlength-leak validation"},
            "observations": [row.public() for row in rows]}


def recompute(un_root: Path) -> dict:
    rows, meetings = [], []
    for mid, digest, total, included in MEETINGS:
        selected, metadata = read_meeting(un_root / f"S_PV.{mid}/turns.json", f"S/PV.{mid}", digest)
        if metadata["total_turns"] != total or metadata["included_turns"] != included:
            raise ValueError("reviewed complete/partial turn counts changed")
        rows.extend(selected)
        meetings.append(metadata)
    report = build_report(rows)
    files = [{key: meeting[key] for key in ("path", "bytes", "sha256")} for meeting in meetings]
    canonical = json.dumps(files, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    for file in files:
        raw = (un_root / file["path"]).read_bytes()
        if len(raw) != file["bytes"] or sha256(raw) != file["sha256"]:
            raise ValueError("raw input changed during recomputation")
    report["corpus"] = {"files": files, "manifest_sha256": sha256(canonical),
                        "manifest_hash_method": "SHA-256 of compact sorted-key UTF-8 files array",
                        "meetings": meetings, "input_unchanged_after_calculation": True,
                        "total_turn_count": sum(meeting["total_turns"] for meeting in meetings),
                        "included_turn_count": len(rows),
                        "excluded_turn_count": sum(len(meeting["excluded"]) for meeting in meetings)}
    report["script"] = {"path": "Scripts/target_eval/recompute_es_zh_length.py",
                        "sha256": sha256(Path(__file__).read_bytes())}
    return report


def write_report(report: dict, output: Path, output_root: Path) -> None:
    for path in (output, output_root):
        if any(part.is_symlink() for part in (path, *path.parents)):
            raise ValueError("report paths must not traverse symlinks")
    root, destination = output_root.resolve(), output.resolve()
    repository = Path(__file__).resolve().parents[2]
    if (not root.is_dir() or repository == root or repository in root.parents
            or destination.parent != root):
        raise ValueError("report must be directly inside its existing external output root")
    content = json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True, allow_nan=False) + "\n"
    with destination.open("x", encoding="utf-8") as handle:
        handle.write(content)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--un-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)
    output_root = Path(__file__).resolve().parents[3] / "work/dd-copyfix"
    try:
        report = recompute(args.un_root)
        write_report(report, args.output, output_root)
    except (ValueError, OSError) as error:
        parser.error(str(error))
    print(json.dumps({"output_basename": args.output.name, "sample_count": report["sample_count"],
                      "manifest_sha256": report["corpus"]["manifest_sha256"],
                      "recommendation": report["recommendation"]}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
