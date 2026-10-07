"""Calibrate the real Swift target acceptance CLI on local curated UN turns.

No model, tokenizer or Python acceptance implementation is used. All decisions,
including the length guard, come from ``CLI judge``. A turn is never split into
sentences or realigned using text lengths. Reports are exclusively created under
the directory configured by LIVELINGO_TARGET_EVAL_OUTPUT_ROOT; existing files
are never overwritten.
"""
from __future__ import annotations

from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import subprocess
import sys
from typing import Callable, Iterable, Sequence
import unicodedata

if not __package__:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    __package__ = "Scripts.target_eval"

try:
    from Scripts.privacy_cli import PrivateArgumentParser
except ModuleNotFoundError as error:
    if error.name != "Scripts":
        raise
    from privacy_cli import PrivateArgumentParser
from . import corpora as c
from . import clusters
from . import metrics as m

TARGET_LOCALES = ("es", "fr", "en")
REUSED_COMMIT = "b4abd77454e74c4646b62bbde8c26e1bb94703f4"
KINDS = ("good", "echo", "wrong")


@dataclass(frozen=True)
class CalibrationCase:
    turn_id: str
    kind: str
    candidate_language: str
    request: dict


def _positive_number(value: object, label: str) -> float:
    if (isinstance(value, bool) or not isinstance(value, (int, float))
            or not math.isfinite(value) or value <= 0):
        raise ValueError(f"{label} must be a finite positive number")
    return float(value)


def _positive_integer(value: object, label: str) -> int:
    if type(value) is not int or value <= 0:
        raise ValueError(f"{label} must be a positive integer")
    return value


def make_cases(units: Iterable[c.ParallelUnit], *,
               targets: Sequence[str] = TARGET_LOCALES,
               maximum_length_ratio: float | None = None) -> tuple[CalibrationCase, ...]:
    """One good and echo plus four wrong-language candidates per source/target.

    Each target uses the other five languages as sources. In particular en/en
    pass-through is absent, so legal English copies do not enter the echo metric.
    Nothing is discarded based on text length, a verdict or identical references.
    """
    if (not targets or len(set(targets)) != len(targets)
            or any(target not in TARGET_LOCALES for target in targets)):
        raise ValueError("targets must be distinct en/es/fr locales")
    if maximum_length_ratio is not None:
        maximum_length_ratio = _positive_number(maximum_length_ratio, "maximum length ratio")
    cases, seen = [], set()
    for unit in units:
        if not isinstance(unit.id, str) or not unit.id.strip() or unit.id in seen:
            raise ValueError("UN turn identities must be nonempty and unique")
        seen.add(unit.id)
        if set(unit.texts) != set(c.UN_LOCALES) or any(
                not isinstance(text, str) or not text.strip() for text in unit.texts.values()):
            raise ValueError("calibration requires six nonempty mapped UN texts")
        for target in targets:
            for source in c.UN_LOCALES:
                if source == target:
                    continue
                candidates = [("good", target), ("echo", source)] + [
                    ("wrong", locale) for locale in c.UN_LOCALES
                    if locale not in (source, target)]
                for kind, candidate_language in candidates:
                    # JSON array IDs avoid delimiter ambiguity in curated turn IDs.
                    identity = json.dumps([unit.id, target, source, kind, candidate_language],
                                          ensure_ascii=False, separators=(",", ":"))
                    request = {"id": identity, "source": unit.texts[source],
                               "candidate": unit.texts[candidate_language],
                               "sourceLanguage": source, "targetLocale": target}
                    if maximum_length_ratio is not None:
                        request["maximumLengthRatio"] = maximum_length_ratio
                    cases.append(CalibrationCase(unit.id, kind, candidate_language, request))
    if not cases:
        raise ValueError("no eligible curated UN turns to calibrate")
    return tuple(cases)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _corpus_files(root: Path) -> list[dict]:
    paths = sorted(root.glob("S_PV.*/turns.json"))
    if not paths:
        raise ValueError("no UN S_PV.*/turns.json files found")
    return [{"path": str(path.relative_to(root)), "sha256": sha256_file(path),
             "bytes": path.stat().st_size} for path in paths]


def load_un(root: Path, *, include_partial: bool = False) -> tuple[c.CorpusResult, dict]:
    before = _corpus_files(root)
    result = c.read_un(root, include_partial=include_partial)
    if before != _corpus_files(root):
        raise ValueError("UN turns files changed while being read")
    excluded = [row for row in result.excluded if not row["included_by_request"]]
    per_language = Counter(locale for row in result.excluded for locale in row["text_status"])
    status_counts = Counter(status for row in result.excluded
                            for status in row["text_status"].values())
    canonical = json.dumps(before, ensure_ascii=False, sort_keys=True,
                           separators=(",", ":")).encode("utf-8")
    annotations = [annotation for unit in result.units
                   for annotation in unit.metadata.get("reference_annotations", [])]
    return result, {"corpus": "un", "alignment_unit": "curated-speech-turn",
                    "files": before, "file_count": len(before),
                    "manifest_sha256": hashlib.sha256(canonical).hexdigest(),
                    "manifest_hash_method": "SHA-256 of compact sorted-key UTF-8 files array",
                    "total_turn_count": len(result.units) + len(excluded),
                    "included_turn_count": len(result.units),
                    "excluded_turn_count": len(excluded),
                    "partial_turn_count": len(result.excluded),
                    "include_partial": include_partial,
                    "partial_text_counts_by_language": dict(sorted(per_language.items())),
                    "partial_text_status_counts": dict(sorted(status_counts.items())),
                    "reference_annotation_count": len(annotations),
                    "reference_annotations": annotations,
                    "partial_turns": list(result.excluded)}


def _json_object(pairs: list[tuple[str, object]]) -> dict:
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate CLI JSON field")
        value[key] = item
    return value


def _json_constant(value: str) -> None:
    raise ValueError(f"nonfinite CLI JSON value: {value}")


def _validate_verdict(row: object, case: CalibrationCase) -> dict:
    required = {"id", "targetLocale", "accepted", "rejection", "reason", "sourceLetters",
                "candidateLetters", "lengthRatio", "lengthAccepted", "maximumOutputLetters",
                "stablePrefix", "sourceNumbers", "targetNumbers", "detectedLanguage",
                "candidateLanguages"}
    if not isinstance(row, dict) or not required.issubset(row):
        raise ValueError("CLI verdict is missing required judge fields")
    request = case.request
    if row["id"] != request["id"] or row["targetLocale"] != request["targetLocale"]:
        raise ValueError("CLI verdict identity/target does not match the request")
    for field in ("accepted", "lengthAccepted"):
        if type(row[field]) is not bool:
            raise ValueError(f"CLI {field} must be a Boolean")
    rejection = row["rejection"]
    if rejection is not None and (not isinstance(rejection, str) or not rejection.strip()):
        raise ValueError("CLI rejection must be a nonempty code or null")
    if row["accepted"] != (rejection is None):
        raise ValueError("CLI accepted/rejection fields disagree")
    if not isinstance(row["reason"], str) or not row["reason"].strip():
        raise ValueError("CLI reason must be nonempty text")
    if not isinstance(row["stablePrefix"], str):
        raise ValueError("CLI stablePrefix must be text")
    detected = row["detectedLanguage"]
    if detected is not None and (not isinstance(detected, str) or not detected.strip()):
        raise ValueError("CLI detectedLanguage must be text or null")
    for field in ("sourceNumbers", "targetNumbers", "candidateLanguages"):
        if not isinstance(row[field], list) or any(
                not isinstance(item, str) or not item.strip() for item in row[field]):
            raise ValueError(f"CLI {field} must be a list of nonempty strings")
    measured = m.length_ratio(unicodedata.normalize("NFC", request["source"]),
                              unicodedata.normalize("NFC", request["candidate"]), unit="letters")
    for field, count in (("sourceLetters", measured["source_count"]),
                         ("candidateLetters", measured["target_count"])):
        if type(row[field]) is not int or row[field] != count:
            raise ValueError(f"CLI {field} disagrees with Unicode-letter count")
    ratio = row["lengthRatio"]
    if measured["ratio"] is None:
        if ratio is not None:
            raise ValueError("CLI lengthRatio must be null for a zero-letter source")
    elif (isinstance(ratio, bool) or not isinstance(ratio, (int, float))
          or not math.isfinite(ratio)
          or not math.isclose(ratio, measured["ratio"], rel_tol=1e-12, abs_tol=1e-12)):
        raise ValueError("CLI lengthRatio disagrees with measured letter counts")
    maximum = row["maximumOutputLetters"]
    if (isinstance(maximum, bool) or not isinstance(maximum, (int, float))
            or not math.isfinite(maximum) or maximum < 0):
        raise ValueError("CLI maximumOutputLetters must be finite and nonnegative")
    if row["lengthAccepted"] != (row["candidateLetters"] <= maximum):
        raise ValueError("CLI lengthAccepted disagrees with its reported letter limit")
    diagnostic_keys = {"configuredMaximumLengthRatio", "minimumSourceLetters", "absoluteLetterAllowance"}
    if diagnostic_keys.intersection(row):
        if not diagnostic_keys.issubset(row):
            raise ValueError("CLI letter-policy diagnostics must be complete")
        configured = _positive_number(row["configuredMaximumLengthRatio"], "configured maximum length ratio")
        floor = _positive_integer(row["minimumSourceLetters"], "minimum source letters")
        allowance = row["absoluteLetterAllowance"]
        if type(allowance) is not int or allowance < 0:
            raise ValueError("CLI absolute letter allowance must be a nonnegative integer")
        expected = max(row["sourceLetters"], floor) * configured + allowance
        if not math.isclose(maximum, expected, rel_tol=1e-12, abs_tol=1e-12):
            raise ValueError("CLI output limit disagrees with configured letter policy")
    return row


def judge_cases(cli: Path, cases: Sequence[CalibrationCase], *, batch_size: int = 128,
                timeout_seconds: float = 120, include_content: bool = False,
                on_batch: Callable[[int, int], None] | None = None) -> tuple[list[dict], list[dict]]:
    """subprocess.run uses communicate to drain both pipes while sending input."""
    _positive_integer(batch_size, "batch size")
    _positive_number(timeout_seconds, "timeout seconds")
    records, diagnostics = [], []
    for offset in range(0, len(cases), batch_size):
        batch = cases[offset:offset + batch_size]
        payload = "".join(json.dumps(case.request, ensure_ascii=False, allow_nan=False) + "\n"
                          for case in batch)
        try:
            arguments = [str(cli), "judge"] + (["--include-content"] if include_content else [])
            process = subprocess.run(arguments, input=payload,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     text=True, encoding="utf-8", check=False,
                                     timeout=timeout_seconds, cwd=c.repository_root())
        except (OSError, subprocess.TimeoutExpired, UnicodeError) as error:
            raise ValueError(f"Swift judge could not finish batch {offset // batch_size + 1}: "
                             f"{type(error).__name__}") from None
        if process.returncode != 0:
            raise ValueError(f"Swift judge exited {process.returncode}; raw diagnostics omitted")
        if process.stderr:
            data = process.stderr.encode("utf-8")
            diagnostics.append({"batch": offset // batch_size + 1, "stderr_bytes": len(data),
                                "stderr_sha256": hashlib.sha256(data).hexdigest(),
                                "truncated": len(process.stderr) > 4096})
        # JSONL is separated by LF, not Python's broader Unicode splitlines set.
        lines = process.stdout.split("\n")
        if lines and lines[-1] == "":
            lines.pop()
        expected = {case.request["id"]: case for case in batch}
        if len(expected) != len(batch) or len(lines) != len(batch):
            raise ValueError("CLI judge must return exactly one row per request")
        returned = {}
        for line in lines:
            row = json.loads(line, object_pairs_hook=_json_object, parse_constant=_json_constant)
            if (not isinstance(row, dict) or not isinstance(row.get("id"), str)
                    or row["id"] not in expected or row["id"] in returned):
                raise ValueError("CLI judge returned an unknown or duplicate request identity")
            returned[row["id"]] = _validate_verdict(row, expected[row["id"]])
        for case in batch:
            verdict = dict(returned[case.request["id"]])
            if not include_content:
                verdict.update(stablePrefix="", sourceNumbers=[], targetNumbers=[])
            records.append({**verdict, "turn_id": case.turn_id,
                            "case_kind": case.kind,
                            "source_language": case.request["sourceLanguage"],
                            "candidate_language": case.candidate_language})
        if on_batch:
            on_batch(offset + len(batch), len(cases))
    return records, diagnostics


def letter_ratio_quantiles(values: Iterable[float | None]) -> dict:
    observed = list(values)
    measured = sorted(value for value in observed if value is not None)
    result = {"unit": "unicode-letters", "sample_count": len(observed),
              "defined_count": len(measured), "undefined_count": len(observed) - len(measured)}
    for name, quantile in (("p50", .5), ("p95", .95), ("p99", .99), ("p99.5", .995)):
        result[name] = m._percentile(measured, quantile) if measured else None
    result["max"] = measured[-1] if measured else None
    return result


def reference_letter_audit(units: Iterable[c.ParallelUnit], *, target: str) -> dict:
    """Measure zh references in the production letter unit, without judging.

    LatinTargetLengthGuard.letterCount applies NFC and counts Lu/Ll/Lt/Lm/Lo
    scalars, including non-Han letters in mixed sources. The separate Han-only
    denominator below is a diagnostic, never the production ratio. The current
    local corpus has 85 complete turns; its quantiles remain provisional,
    in-sample values to recalibrate after expansion and an independent holdout.
    """
    if target not in TARGET_LOCALES:
        raise ValueError("reference length target must be en/es/fr")

    def han_letter(char: str) -> bool:
        # Exactly TranslationAcceptance.isHan ranges, restricted to letters.
        code = ord(char)
        return unicodedata.category(char).startswith("L") and any(
            low <= code <= high for low, high in (
                (0x3400, 0x4DBF), (0x4E00, 0x9FFF), (0xF900, 0xFAFF),
                (0x20000, 0x2FA1F), (0x30000, 0x323AF)))

    rows = []
    for unit in units:
        source = unicodedata.normalize("NFC", unit.texts["zh"])
        reference = unicodedata.normalize("NFC", unit.texts[target])
        counts = m.length_ratio(source, reference, unit="letters")
        han = sum(han_letter(char) for char in source)
        other = counts["source_count"] - han
        composition = ("mixed_han_and_other_letters" if han and other else
                       "han_only" if han else "no_han_letters")
        rows.append({"turn_id": unit.id, "source_letters": counts["source_count"],
                     "source_han_letters": han, "source_other_letters": other,
                     "target_letters": counts["target_count"],
                     "source_composition": composition,
                     "production_letter_ratio": counts["ratio"],
                     "han_denominator_ratio": counts["target_count"] / han if han else None})

    def summarize_lengths(group: Sequence[dict]) -> dict:
        return {"sample_count": len(group),
                "source_letters": sum(row["source_letters"] for row in group),
                "source_han_letters": sum(row["source_han_letters"] for row in group),
                "source_other_letters": sum(row["source_other_letters"] for row in group),
                "target_letters": sum(row["target_letters"] for row in group),
                "production_letter_ratio": letter_ratio_quantiles(
                    row["production_letter_ratio"] for row in group)}

    quantiles = letter_ratio_quantiles(row["production_letter_ratio"] for row in rows)
    han_quantiles = letter_ratio_quantiles(row["han_denominator_ratio"] for row in rows)
    han_quantiles["unit"] = "target-unicode-letters/source-Han-letter-scalars"
    return {"source_locale": "zh", "target_locale": target, "sample_count": len(rows),
            "counting_method": "LatinTargetLengthGuard.letterCount: NFC then Lu/Ll/Lt/Lm/Lo scalars",
            "production_letter_ratio": quantiles,
            "han_denominator_diagnostic": han_quantiles,
            "by_source_composition": {
                composition: summarize_lengths([row for row in rows
                                               if row["source_composition"] == composition])
                for composition in ("han_only", "mixed_han_and_other_letters", "no_han_letters")},
            "provisional_p99_5_ceiling": (
                math.ceil(quantiles["p99.5"] * 100) / 100 if quantiles["p99.5"] is not None else None),
            "ratio_derivation": "ceil(in-sample production-letter p99.5 * 100) / 100; no added ratio margin",
            "quantile_method": "sorted sample, linear interpolation at (n - 1) * 0.995",
            "provisional": True, "independent_validation": False,
            "requires_expanded_holdout": True,
            "sample_relationship": "in-sample UN speech-turn references; recalibrate after expanding meetings/sources and validate on a separate holdout; not a 1% false-rejection proof",
            "scope_limit": "reference length measurements only; no Python acceptance decisions or Swift policy tuning",
            "rows": rows}


def _rate(numerator: int, denominator: int) -> dict:
    return {"numerator": numerator, "denominator": denominator,
            "rate": numerator / denominator if denominator else None}


def _summarize(records: Sequence[dict], *, bootstrap_resamples: int = clusters.DEFAULT_RESAMPLES,
               bootstrap_seed: int = clusters.DEFAULT_SEED) -> dict:
    groups = {kind: [row for row in records if row["case_kind"] == kind] for kind in KINDS}
    rejected = {kind: sum(not row["accepted"] for row in rows) for kind, rows in groups.items()}
    wrong_by_candidate = {}
    for locale in sorted({row["candidate_language"] for row in groups["wrong"]}):
        rows = [row for row in groups["wrong"] if row["candidate_language"] == locale]
        wrong_by_candidate[locale] = {
            "interception": _rate(sum(not row["accepted"] for row in rows), len(rows)),
            "clustered_interception": clusters.summarize_clusters(
                rows, resamples=bootstrap_resamples, seed=bootstrap_seed)["wrong_language_interception"],
            "reason_counts": dict(sorted(Counter(row["reason"] for row in rows).items())),
            "rejection_counts": dict(sorted(Counter(row["rejection"] for row in rows
                                                      if row["rejection"] is not None).items()))}
    observed_ratios = [row["maximumOutputLetters"] / max(row["sourceLetters"], 24)
                       for row in groups["good"]]
    quantiles = letter_ratio_quantiles(row["lengthRatio"] for row in groups["good"])
    rounded = math.ceil(quantiles["p99.5"] * 100) / 100 if quantiles["p99.5"] is not None else None
    configured = sorted({row["configuredMaximumLengthRatio"] for row in groups["good"]
                         if "configuredMaximumLengthRatio" in row})
    return {"turn_count": len({row["turn_id"] for row in records}),
            "clustered_by_turn_reference": clusters.summarize_clusters(
                records, resamples=bootstrap_resamples, seed=bootstrap_seed),
            "case_counts": {kind: len(rows) for kind, rows in groups.items()},
            "false_rejection": _rate(rejected["good"], len(groups["good"])),
            "echo_interception": _rate(rejected["echo"], len(groups["echo"])),
            "wrong_language_interception": _rate(rejected["wrong"], len(groups["wrong"])),
            "reason_counts": {kind: dict(sorted(Counter(row["reason"] for row in rows).items()))
                              for kind, rows in groups.items()},
            "rejection_counts": {kind: dict(sorted(Counter(row["rejection"] for row in rows
                                                            if row["rejection"] is not None).items()))
                                 for kind, rows in groups.items()},
            "length_rejected_counts": {kind: sum(not row["lengthAccepted"] for row in rows)
                                       for kind, rows in groups.items()},
            "reference_letter_length_ratio": quantiles,
            "observed_letter_guard": {
                "sample_p99.5_ceiling_to_0.01": rounded,
                "configured_matches_sample_p99.5_ceiling": (
                    math.isclose(configured[0], rounded, rel_tol=0, abs_tol=1e-12)
                    if len(configured) == 1 and rounded is not None else None),
                "provenance_comparison": "Diagnostic only; no ratio changes. Per-source breakdown is needed when multiple configured ratios are pooled.",
                "documented_minimum_source_letters": 24,
                "documented_formula": "max(sourceLetters, 24) * maximumRatio + 12",
                "observed_effective_limit_ratio": {
                    "sample_count": len(observed_ratios),
                    "min": min(observed_ratios) if observed_ratios else None,
                    "max": max(observed_ratios) if observed_ratios else None},
                "configured_policy_diagnostics": {
                    "reported_count": sum("configuredMaximumLengthRatio" in row for row in groups["good"]),
                    "maximum_ratios": sorted({row["configuredMaximumLengthRatio"] for row in groups["good"] if "configuredMaximumLengthRatio" in row}),
                    "absolute_allowances": sorted({row["absoluteLetterAllowance"] for row in groups["good"] if "absoluteLetterAllowance" in row})},
                "exact_limits": "maximumOutputLetters in each verdict"},
            "wrong_language_by_candidate": wrong_by_candidate}


def summarize(records: Sequence[dict], targets: Sequence[str], *,
              bootstrap_resamples: int = clusters.DEFAULT_RESAMPLES,
              bootstrap_seed: int = clusters.DEFAULT_SEED) -> dict:
    settings = {"bootstrap_resamples": bootstrap_resamples, "bootstrap_seed": bootstrap_seed}
    result = {}
    for target in targets:
        rows = [row for row in records if row["targetLocale"] == target]
        result[target] = _summarize(rows, **settings)
        result[target]["by_source"] = {
            source: _summarize([row for row in rows if row["source_language"] == source], **settings)
            for source in c.UN_LOCALES if source != target}
    return result


def calibrate(*, cli: str | Path, un_root: str | Path, output: str | Path,
              targets: Sequence[str] = TARGET_LOCALES, include_partial: bool = False,
              maximum_length_ratio: float | None = None, batch_size: int = 128,
              timeout_seconds: float = 120, bootstrap_resamples: int = clusters.DEFAULT_RESAMPLES,
              bootstrap_seed: int = clusters.DEFAULT_SEED, include_content: bool = False) -> dict:
    destination = c.validate_output_path(output)
    if destination.exists():
        raise FileExistsError("calibration output already exists")
    _positive_integer(batch_size, "batch size")
    _positive_number(timeout_seconds, "timeout seconds")
    clusters.validate_settings(bootstrap_resamples, bootstrap_seed)
    executable = Path(cli).resolve()
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError("--cli must point to an executable Swift target-acceptance CLI")
    cli_hash = sha256_file(executable)
    corpus, corpus_metadata = load_un(Path(un_root).resolve(), include_partial=include_partial)
    cases = make_cases(corpus.units, targets=targets, maximum_length_ratio=maximum_length_ratio)
    records, diagnostics = judge_cases(executable, cases, batch_size=batch_size,
                                        timeout_seconds=timeout_seconds, include_content=include_content)
    if cli_hash != sha256_file(executable):
        raise ValueError("Swift CLI executable changed during calibration")
    python_files = {name: sha256_file(Path(__file__).with_name(name))
                    for name in ("calibrate.py", "corpora.py", "metrics.py", "__init__.py")}
    report = {"schema_version": 2, "corpus": corpus_metadata,
              "tools": {"swift_cli": {"basename": executable.name, "sha256": cli_hash,
                                       "subcommand": "judge"},
                        "python_version": platform.python_version(),
                        "unicode_database_version": unicodedata.unidata_version,
                        "python_file_sha256": python_files,
                        "additional_python_file_sha256": {
                            name: sha256_file(Path(__file__).with_name(name))
                            for name in ("clusters.py", "reference_annotations.py")},
                        "reused_from_commit": REUSED_COMMIT},
              "methods": {"evaluation_unit": "curated speech turn; never sentence-aligned",
                          "source_languages": list(c.UN_LOCALES), "target_locales": list(targets),
                          "good": "same turn's human target-language reference",
                          "echo": "unchanged full source turn; source == target is excluded",
                          "wrong": "same turn in each of the four other non-source/non-target reference locales; labels test language/script interception, not semantic quality",
                          "weighting": "comparison counts are descriptive; inferential summaries weight turn/reference clusters equally; no filtering by verdict or length",
                          "rates": "fractions; descriptive comparison numerators/denominators are not independent sample sizes; confidence intervals resample whole turn/reference clusters",
                          "holdout": {"present": False, "turn_count": 0,
                                      "limitations": "No independent sentence/caption holdout. Fixed length parameters originate from these same UN turns. Synthetic tests check software behavior, not generalization."},
                          "one_percent_gate": {"established": False,
                                               "reason": "In-sample turn/reference diagnostics with no independent holdout cannot establish a 1% population false-rejection limit; bootstrap degeneracy at zero failures does not prove it."},
                          "letters": "LatinTargetLengthGuard.letterCount unit: NFC normalization, then Unicode letter scalars (Lu/Ll/Lt/Lm/Lo), including non-Han letters in mixed sources; no accent folding; marks/digits/punctuation excluded",
                          "count_validation": "every CLI count and ratio checked against Python Unicode letters",
                          "length_quantiles": "all good references, including rejected ones; target/source letters; zero-letter sources undefined",
                          "quantile_method": "sorted sample, linear interpolation at (n - 1) * q",
                          "maximum_length_ratio_override": maximum_length_ratio,
                          "guard_defaults": {
                              "policy": "Swift CLI fixed per-target/per-source parameters, unless explicitly overridden; output limit = max(sourceLetters, 24) * maximumRatio + 12. Their declared p99.5 provenance is compared with the observed sample per source; a mismatch is reported, never tuned away.",
                              "automatic_tuning": False,
                              "sample_relationship": "production defaults originate from 85 complete local UN turns; reusing those turns gives provisional in-sample diagnostics, not independent validation; recalibrate after expanding meetings/sources and verify a separate holdout",
                              "observed_values": "per-source observed_letter_guard plus exact maximumOutputLetters in each verdict"},
                          "token_ratio": {"measured": False, "reason": "no tokenizer or model loaded"},
                          "scope_limit": "turn-level diagnostics; not sentence-level caption acceptance or translation-quality proof"},
              "reference_length_audits": {
                  f"{target}_from_zh": reference_letter_audit(corpus.units, target=target)
                  for target in targets},
              "execution": {"case_count": len(cases), "batch_size": batch_size,
                            "judge_batch_count": (len(cases) + batch_size - 1) // batch_size,
                            "timeout_seconds_per_batch": timeout_seconds,
                            "cli_stderr": diagnostics,
                            "stderr_policy": "byte counts and SHA-256 only; raw diagnostics omitted to avoid machine-path disclosure"},
              "targets": summarize(records, targets, bootstrap_resamples=bootstrap_resamples,
                                   bootstrap_seed=bootstrap_seed), "content_included": include_content}
    if include_content:
        report["verdicts"] = records
    else:
        # Per-turn rows and annotations may contain literal reference material.
        for audit in report["reference_length_audits"].values():
            audit.pop("rows", None)
        report["corpus"].pop("reference_annotations", None)
        report["corpus"].pop("partial_turns", None)
    c.write_json(report, destination)
    return report


SOURCE_STRATA = {"zh": "han", "en": "latin", "es": "latin", "fr": "latin",
                 "ru": "cyrillic", "ar": "arabic"}
PUBLIC_MINIMUM_SAMPLES = 600
PUBLIC_SPLIT_SEED = 20261008


def binomial_upper95(failures: int, count: int) -> float | None:
    """One-sided exact Clopper-Pearson upper bound, including zero failures.

    Used on one observation per document, or on the conservative event 'any
    failed comparison in this document'. Never count reused language pairs as
    independent observations. Independence between documents remains assumed.
    """
    if (type(count) is not int or type(failures) is not int
            or count < 0 or failures < 0 or failures > count):
        raise ValueError("invalid binomial counts")
    if not count:
        return None
    if failures == count:
        return 1.0
    if failures == 0:
        return -math.expm1(math.log(.05) / count)
    coefficients = [math.lgamma(count + 1) - math.lgamma(i + 1)
                    - math.lgamma(count - i + 1) for i in range(failures + 1)]
    low, high = 0.0, 1.0
    for _ in range(60):
        p = (low + high) / 2
        terms = [value + i * math.log(p) + (count - i) * math.log1p(-p)
                 for i, value in enumerate(coefficients)]
        peak = max(terms)
        log_cdf = peak + math.log(math.fsum(math.exp(value - peak) for value in terms))
        if log_cdf > math.log(.05):
            low = p
        else:
            high = p
    return high


def partition_public_units(units: Sequence[c.ParallelUnit], *, seed: int = PUBLIC_SPLIT_SEED) -> dict:
    """Whole article/talk split, one unit per group, no length/verdict filtering."""
    if type(seed) is not int:
        raise ValueError("split seed must be an integer")
    groups = {}
    for unit in units:
        group = c._text(unit.metadata.get("split_group"), "public split group")
        groups.setdefault(group, []).append(unit)
    result = {"training": [], "holdout": [], "auxiliary": []}
    seen = {locale: set() for locale in c.UN_LOCALES}
    duplicates = 0
    for group, rows in sorted(groups.items()):
        statuses = {row.metadata.get("reference_status") for row in rows}
        if len(statuses) != 1:
            raise ValueError("one public document has conflicting reference statuses")
        qualified = statuses.issubset({"human", "community-human"})
        split = ("holdout" if int(hashlib.sha256(json.dumps([seed, group],
                 separators=(",", ":")).encode()).hexdigest(), 16) % 3 == 0 else "training")
        if not qualified:
            split = "auxiliary"
        ordered = sorted(rows, key=lambda row: hashlib.sha256(row.id.encode()).digest())
        for row in ordered:
            normalized = {locale: " ".join(unicodedata.normalize("NFC", text).split())
                          for locale, text in row.texts.items()}
            if any(locale not in c.UN_LOCALES for locale in normalized):
                raise ValueError("public calibration supports explicit en/es/fr/zh/ru/ar locales")
            if qualified and any(text in seen[locale] for locale, text in normalized.items()):
                duplicates += 1
                continue
            if qualified:
                for locale, text in normalized.items():
                    seen[locale].add(text)
            result[split].append(row)
            break
    return {**result, "duplicate_candidates_skipped": duplicates,
            "input_group_count": len(groups)}


def make_public_cases(units: Sequence[c.ParallelUnit], *, targets: Sequence[str] = TARGET_LOCALES,
                      negatives: bool = True, ratios: dict | None = None) -> tuple[CalibrationCase, ...]:
    if not targets or len(set(targets)) != len(targets) or any(t not in TARGET_LOCALES for t in targets):
        raise ValueError("targets must be distinct en/es/fr locales")
    cases = []
    for unit in units:
        for target in targets:
            if target not in unit.texts:
                continue
            for source in sorted(unit.texts):
                if source == target:
                    continue
                candidates = [("good", target)]
                if negatives:
                    candidates += [("echo", source)] + [("wrong", locale) for locale in sorted(unit.texts)
                                                         if locale not in (source, target)]
                for kind, locale in candidates:
                    identity = json.dumps([unit.id, target, source, kind, locale], separators=(",", ":"))
                    request = {"id": identity, "targetLocale": target, "sourceLanguage": source,
                               "source": unit.texts[source], "candidate": unit.texts[locale]}
                    ratio = (ratios or {}).get(target, {}).get(source)
                    if ratio is not None:
                        request["maximumLengthRatio"] = _positive_number(ratio, "public ratio")
                    cases.append(CalibrationCase(unit.id, kind, locale, request))
    return tuple(cases)


def public_quantiles(values: Iterable[float | None]) -> dict:
    observed = list(values)
    measured = sorted(value for value in observed if value is not None)
    return {"sample_count": len(observed), "defined_count": len(measured),
            "undefined_count": len(observed) - len(measured),
            **{name: m._percentile(measured, q) if measured else None for name, q in
               (("p01", .01), ("p05", .05), ("p50", .5), ("p90", .9),
                ("p95", .95), ("p99", .99), ("p99.5", .995))},
            "max": measured[-1] if measured else None}


def fit_public_ratios(records: Sequence[dict], *, minimum_samples: int = PUBLIC_MINIMUM_SAMPLES) -> dict:
    _positive_integer(minimum_samples, "minimum independent samples")
    result = {target: {} for target in TARGET_LOCALES}
    for target in TARGET_LOCALES:
        for source in c.UN_LOCALES:
            if source == target:
                continue
            rows = [row for row in records if row["targetLocale"] == target
                    and row["source_language"] == source and row["case_kind"] == "good"]
            if len({row["group_id"] for row in rows}) != len(rows):
                raise ValueError("fitting must have at most one reference per document/direction")
            policies = {(row["minimumSourceLetters"], row["absoluteLetterAllowance"]) for row in rows}
            if len(policies) > 1:
                raise ValueError("CLI source floor/absolute allowance changed during fitting")
            required = [max(0.0, (row["candidateLetters"] - row["absoluteLetterAllowance"])
                            / max(row["sourceLetters"], row["minimumSourceLetters"])) for row in rows]
            quantiles = public_quantiles(required)
            value = quantiles["p99.5"]
            proposed = math.ceil(value * 100) / 100 if value is not None and value > 0 else None
            sufficient = len(rows) >= minimum_samples and proposed is not None
            result[target][source] = {
                "training_documents": len(rows), "source_stratum": SOURCE_STRATA[source],
                "raw_letter_ratio": public_quantiles(row["lengthRatio"] for row in rows),
                "required_policy_ratio": quantiles, "proposed_ratio": proposed,
                "candidate_ratio": proposed if sufficient else None,
                "sample_sufficient": sufficient,
                "retained_floor_and_allowance": list(next(iter(policies))) if policies else None}
    return result


def _public_rate(rows: Sequence[dict], *, kind: str, length_only: bool = False) -> dict:
    selected = [row for row in rows if row["case_kind"] == kind]
    failed = [row for row in selected if not row["lengthAccepted" if length_only else "accepted"]]
    groups = {row["group_id"] for row in selected}
    affected = {row["group_id"] for row in failed}
    return {**_rate(len(failed), len(selected)),
            "documents": len(groups), "documents_with_any_rejection": len(affected),
            "document_any_rejection_rate": len(affected) / len(groups) if groups else None,
            "upper95": binomial_upper95(len(affected), len(groups)),
            "upper95_scope": "any rejection per document; conservative bound for comparison rate; IID documents assumed",
            "rejection_counts": dict(sorted(Counter(row["rejection"] for row in failed).items(),
                                            key=lambda item: str(item[0])))}


def summarize_public(records: Sequence[dict], targets: Sequence[str]) -> dict:
    def negative(rows, kind):
        selected = [row for row in rows if row["case_kind"] == kind]
        intercepted = [row for row in selected if not row["accepted"]]
        groups = {row["group_id"] for row in selected}
        missed = {row["group_id"] for row in selected if row["accepted"]}
        return {"numerator": len(intercepted), "denominator": len(selected),
                "interception_rate": len(intercepted) / len(selected) if selected else None,
                "documents": len(groups), "documents_with_any_missed_negative": len(missed),
                "miss_upper95": binomial_upper95(len(missed), len(groups)),
                "miss_upper95_scope": "any accepted negative per document, IID documents assumed",
                "ambiguous_label_count": sum(row.get("label_ambiguous", False) for row in selected),
                "rejection_counts": dict(sorted(Counter(row["rejection"] for row in intercepted).items()))}

    def summary(rows):
        return {"reference_false_rejection": _public_rate(rows, kind="good"),
                "reference_length_false_rejection": _public_rate(rows, kind="good", length_only=True),
                "echo_interception": negative(rows, "echo"),
                "wrong_language_interception": negative(rows, "wrong")}
    result = {}
    for target in targets:
        rows = [row for row in records if row["targetLocale"] == target]
        result[target] = {**summary(rows),
            "by_source": {source: summary([row for row in rows if row["source_language"] == source])
                          for source in c.UN_LOCALES if source != target},
            "by_stratum": {stratum: summary([row for row in rows if row["source_stratum"] == stratum])
                           for stratum in ("han", "latin", "cyrillic", "arabic")},
            "wrong_by_candidate": {
                locale: negative([row for row in rows if row["candidate_language"] == locale], "wrong")
                for locale in sorted({row["candidate_language"] for row in rows if row["case_kind"] == "wrong"})}}
    return result


def calibrate_public(*, cli: str | Path, manifest: str | Path, output: str | Path,
                     targets: Sequence[str] = TARGET_LOCALES, batch_size: int = 512,
                     timeout_seconds: float = 120, seed: int = PUBLIC_SPLIT_SEED,
                     minimum_samples: int = PUBLIC_MINIMUM_SAMPLES) -> dict:
    """Fit once on training documents; evaluate unchanged and proposed guards.

    This function never edits Swift constants or changes the fitted quantile
    after reading the holdout. All full acceptance decisions use CLI judge.
    """
    destination = c.validate_output_path(output)
    if destination.exists():
        raise FileExistsError("public calibration output already exists")
    executable = Path(cli).resolve()
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError("--cli must be an executable Swift target-acceptance CLI")
    cli_hash = sha256_file(executable)
    python_hashes = {name: sha256_file(Path(__file__).with_name(name))
                     for name in ("calibrate.py", "corpora.py", "metrics.py")}
    snapshots = {}
    manifest_root = Path(manifest).resolve().parent

    def observe(path):
        snapshots[path] = {"file": (path.relative_to(manifest_root).as_posix()
                                   if path.is_relative_to(manifest_root) else path.name),
                           "bytes": path.stat().st_size, "sha256": sha256_file(path)}

    corpus, files = c.read_public_manifest(manifest, on_input=observe)
    inputs = [snapshots[path] for path in files]
    partitions = partition_public_units(corpus.units, seed=seed)
    unit_metadata = {unit.id: {"group_id": unit.metadata["split_group"], "corpus": unit.corpus,
                     "reference_status": unit.metadata["reference_status"]} for unit in corpus.units}
    diagnostics = []
    receipts = []

    def run(name, units, *, negatives, ratios=None):
        cases = make_public_cases(units, targets=targets, negatives=negatives, ratios=ratios)
        print(f"public calibration: starting {name}, {len(cases)} cases", file=sys.stderr, flush=True)
        records, messages = judge_cases(executable, cases, batch_size=batch_size,
            timeout_seconds=timeout_seconds,
            on_batch=lambda done, total: print(f"public calibration: {name} {done}/{total}",
                                               file=sys.stderr, flush=True))
        by_case = {case.request["id"]: case for case in cases}
        unit_texts = {unit.id: unit.texts for unit in units}
        for row in records:
            row.update(unit_metadata[row["turn_id"]])
            row["source_stratum"] = SOURCE_STRATA[row["source_language"]]
            case = by_case[row["id"]]
            row["label_ambiguous"] = (case.kind != "good" and unicodedata.normalize("NFC", case.request["candidate"])
                == unicodedata.normalize("NFC", unit_texts[case.turn_id][case.request["targetLocale"]]))
        diagnostics.extend({"phase": name, **message} for message in messages)
        sidecar = c.validate_output_path(destination.with_name(destination.stem + "-" + name + ".jsonl"))
        sidecar.parent.mkdir(parents=True, exist_ok=True)
        c.validate_output_path(sidecar)
        with sidecar.open("x", encoding="utf-8", newline="\n") as handle:
            for row in records:
                handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True, allow_nan=False) + "\n")
        receipts.append({"phase": name, "file": sidecar.name, "case_count": len(records),
                         "sha256": sha256_file(sidecar)})
        print(f"public calibration: {name}, {len(records)} Swift verdicts", file=sys.stderr, flush=True)
        return records

    training = run("training", partitions["training"], negatives=False)
    fits = fit_public_ratios(training, minimum_samples=minimum_samples)
    ratios = {target: {source: fit["candidate_ratio"] for source, fit in sources.items()
                       if fit["candidate_ratio"] is not None} for target, sources in fits.items()}
    baseline = summarize_public(run("holdout-baseline", partitions["holdout"], negatives=True), targets)
    candidate = summarize_public(run("holdout-candidate", partitions["holdout"], negatives=True, ratios=ratios), targets)
    auxiliary = summarize_public(run("auxiliary", partitions["auxiliary"], negatives=True), targets)
    for target, sources in fits.items():
        if target not in targets:
            continue
        for source, fit in sources.items():
            validation = candidate[target]["by_source"][source]["reference_length_false_rejection"]
            fit["holdout_documents"] = validation["documents"]
            fit["holdout_sample_sufficient"] = validation["documents"] >= minimum_samples
            fit["length_one_percent_bound_established"] = (validation["upper95"] is not None
                                                           and validation["upper95"] <= .01)
            fit["sample_eligible_for_update"] = fit["sample_sufficient"] and fit["holdout_sample_sufficient"]
    if cli_hash != sha256_file(executable) or any(row["sha256"] != sha256_file(path)
                                               for row, path in zip(inputs, files)):
        raise ValueError("public input or Swift CLI changed during calibration")
    if any(digest != sha256_file(Path(__file__).with_name(name)) for name, digest in python_hashes.items()):
        raise ValueError("Python calibration code changed during execution")
    report = {"schema_version": 1, "created_at_utc": datetime.now(timezone.utc).isoformat(),
        "input_files": inputs, "cli_sha256": cli_hash,
        "python_file_sha256": python_hashes,
        "methods": {
            "letters": "NFC Unicode Lu/Ll/Lt/Lm/Lo scalars, cross-checked on every Swift verdict",
            "strata": SOURCE_STRATA, "quantiles": "linear interpolation at (n - 1) * q",
            "fit": "ceil(training p99.5 of max(0, (targetLetters - existingAllowance) / max(sourceLetters, existingFloor)) * 100) / 100; no added margin",
            "floor_allowance": "existing Swift values retained, not independently calibrated; incorporated in required-policy-ratio fitting",
            "split": "SHA-256 of JSON [seed, corpus:document] modulo 3 == 0 is holdout; all language directions share the same split",
            "seed": seed, "minimum_documents_per_direction_per_split": minimum_samples,
            "selection": "one nonduplicate reference per document, selected by SHA-256 independently of lengths/verdicts; no sentence-random split",
            "confidence": "one-sided 95% exact Clopper-Pearson on independent document events; multi-comparison summaries bound any rejection per document; no simultaneous 15-direction claim",
            "negatives": "unchanged non-target source, and other human-language references of the same aligned segment; source == target excluded",
            "limitations": "approximate document independence only; repeated speakers/translators unmodeled; volunteer subtitle alignment is not classroom-oral or semantic-quality validation; reverse and non-English directions often invert/pivot English-authored references; locale variants may be unspecified",
            "holdout_use": "proposed constants frozen before holdout; no retuning from holdout outcomes; Swift edits require separate review of sample sufficiency and limitations"},
        "corpus": {"input_units": len(corpus.units), "excluded": list(corpus.excluded),
                   "partition_duplicate_candidates_skipped": partitions["duplicate_candidates_skipped"],
                   "input_groups": partitions["input_group_count"]},
        "partitions": {split: [{"id": unit.id, "group_id": unit.metadata["split_group"], "corpus": unit.corpus,
                                "reference_status": unit.metadata["reference_status"]} for unit in partitions[split]]
                       for split in ("training", "holdout", "auxiliary")},
        "fits": fits, "holdout_baseline": baseline, "holdout_candidate": candidate,
        "auxiliary_unverified_references": auxiliary, "verdict_files": receipts, "cli_stderr": diagnostics}
    c.write_json(report, destination)
    return report


def main(argv: Sequence[str] | None = None) -> int:
    parser = PrivateArgumentParser(prog="target-eval-calibrate", description=__doc__)
    parser.add_argument("--cli", required=True, type=Path)
    parser.add_argument("--un-root", type=Path, default=c.repository_root().parent / "data" / "un")
    parser.add_argument("--public-manifest", type=Path,
                        help="explicit local public-corpus manifest; bypasses UN/default input discovery")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--targets", nargs="+", choices=TARGET_LOCALES, default=TARGET_LOCALES)
    parser.add_argument("--include-partial", action="store_true")
    parser.add_argument("--include-content", action="store_true",
                        help="Save literal prefix/number diagnostics and per-turn details; keep this report private")
    parser.add_argument("--maximum-length-ratio", type=float)
    parser.add_argument("--batch-size", type=int, default=128)
    parser.add_argument("--timeout-seconds", type=float, default=120)
    parser.add_argument("--bootstrap-resamples", type=int, default=clusters.DEFAULT_RESAMPLES)
    parser.add_argument("--bootstrap-seed", type=int, default=clusters.DEFAULT_SEED)
    parser.add_argument("--split-seed", type=int, default=PUBLIC_SPLIT_SEED)
    parser.add_argument("--minimum-samples", type=int, default=PUBLIC_MINIMUM_SAMPLES)
    args = parser.parse_args(argv)
    try:
        if args.public_manifest:
            if args.include_partial or args.maximum_length_ratio is not None:
                raise ValueError("public holdout mode does not accept UN partials or a pre-tuned ratio override")
            report = calibrate_public(cli=args.cli, manifest=args.public_manifest, output=args.output,
                                      targets=args.targets, batch_size=args.batch_size,
                                      timeout_seconds=args.timeout_seconds, seed=args.split_seed,
                                      minimum_samples=args.minimum_samples)
            print(json.dumps({"output": Path(args.output).name,
                              "documents": {key: len(value) for key, value in report["partitions"].items()},
                              "candidate_ratios": {target: {source: fit["candidate_ratio"]
                                                    for source, fit in sources.items()}
                                                   for target, sources in report["fits"].items()}}, sort_keys=True))
            return 0
        report = calibrate(cli=args.cli, un_root=args.un_root, output=args.output,
                           targets=args.targets, include_partial=args.include_partial,
                           maximum_length_ratio=args.maximum_length_ratio,
                           batch_size=args.batch_size, timeout_seconds=args.timeout_seconds,
                           bootstrap_resamples=args.bootstrap_resamples,
                           bootstrap_seed=args.bootstrap_seed, include_content=args.include_content)
    except (ValueError, OSError) as error:
        parser.error("calibration_failed; raw diagnostics omitted")
    print(json.dumps({"output": c.validate_output_path(args.output).relative_to(c.output_root()).as_posix(),
                      "included_turn_count": report["corpus"]["included_turn_count"],
                      "excluded_turn_count": report["corpus"]["excluded_turn_count"],
                      "case_count": report["execution"]["case_count"],
                      "targets": {target: {key: report["targets"][target][key] for key in (
                          "false_rejection", "echo_interception", "wrong_language_interception",
                          "clustered_by_turn_reference",
                          "reference_letter_length_ratio")} for target in args.targets}},
                     ensure_ascii=False, sort_keys=True, allow_nan=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
