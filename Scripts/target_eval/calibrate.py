"""Calibrate the real Swift target acceptance CLI on local curated UN turns.

No model, tokenizer or Python acceptance implementation is used. All decisions,
including the length guard, come from ``CLI judge``. A turn is never split into
sentences or realigned using text lengths. Reports are exclusively created under
the directory configured by LIVELINGO_TARGET_EVAL_OUTPUT_ROOT; existing files
are never overwritten.
"""
from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import dataclass
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import subprocess
from typing import Iterable, Sequence
import unicodedata

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
            raise ValueError(f"duplicate CLI JSON field: {key}")
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
                timeout_seconds: float = 120) -> tuple[list[dict], list[dict]]:
    """subprocess.run uses communicate to drain both pipes while sending input."""
    _positive_integer(batch_size, "batch size")
    _positive_number(timeout_seconds, "timeout seconds")
    records, diagnostics = [], []
    for offset in range(0, len(cases), batch_size):
        batch = cases[offset:offset + batch_size]
        payload = "".join(json.dumps(case.request, ensure_ascii=False, allow_nan=False) + "\n"
                          for case in batch)
        try:
            process = subprocess.run([str(cli), "judge"], input=payload,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     text=True, encoding="utf-8", check=False,
                                     timeout=timeout_seconds, cwd=c.repository_root())
        except (OSError, subprocess.TimeoutExpired, UnicodeError) as error:
            raise ValueError(f"Swift judge could not finish batch {offset // batch_size + 1}: "
                             f"{type(error).__name__}") from error
        if process.returncode != 0:
            raise ValueError(f"Swift judge exited {process.returncode}: {process.stderr[-4096:]}")
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
            records.append({**returned[case.request["id"]], "turn_id": case.turn_id,
                            "case_kind": case.kind,
                            "source_language": case.request["sourceLanguage"],
                            "candidate_language": case.candidate_language})
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
              bootstrap_seed: int = clusters.DEFAULT_SEED) -> dict:
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
                                        timeout_seconds=timeout_seconds)
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
                          "letters": "NFC normalization, then Unicode letters (isalpha; Lu/Ll/Lt/Lm/Lo); no accent folding; marks/digits/punctuation excluded",
                          "count_validation": "every CLI count and ratio checked against Python Unicode letters",
                          "length_quantiles": "all good references, including rejected ones; target/source letters; zero-letter sources undefined",
                          "quantile_method": "sorted sample, linear interpolation at (n - 1) * q",
                          "maximum_length_ratio_override": maximum_length_ratio,
                          "guard_defaults": {
                              "policy": "Swift CLI fixed per-target/per-source parameters, unless explicitly overridden; output limit = max(sourceLetters, 24) * maximumRatio + 12. Their declared p99.5 provenance is compared with the observed sample per source; a mismatch is reported, never tuned away.",
                              "automatic_tuning": False,
                              "sample_relationship": "defaults calibrated from the same UN turns used here; in-sample diagnostics, not independent validation",
                              "observed_values": "per-source observed_letter_guard plus exact maximumOutputLetters in each verdict"},
                          "token_ratio": {"measured": False, "reason": "no tokenizer or model loaded"},
                          "scope_limit": "turn-level diagnostics; not sentence-level caption acceptance or translation-quality proof"},
              "execution": {"case_count": len(cases), "batch_size": batch_size,
                            "judge_batch_count": (len(cases) + batch_size - 1) // batch_size,
                            "timeout_seconds_per_batch": timeout_seconds,
                            "cli_stderr": diagnostics,
                            "stderr_policy": "byte counts and SHA-256 only; raw diagnostics omitted to avoid machine-path disclosure"},
              "targets": summarize(records, targets, bootstrap_resamples=bootstrap_resamples,
                                   bootstrap_seed=bootstrap_seed), "verdicts": records}
    c.write_json(report, destination)
    return report


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", required=True, type=Path)
    parser.add_argument("--un-root", type=Path, default=c.repository_root().parent / "data" / "un")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--targets", nargs="+", choices=TARGET_LOCALES, default=TARGET_LOCALES)
    parser.add_argument("--include-partial", action="store_true")
    parser.add_argument("--maximum-length-ratio", type=float)
    parser.add_argument("--batch-size", type=int, default=128)
    parser.add_argument("--timeout-seconds", type=float, default=120)
    parser.add_argument("--bootstrap-resamples", type=int, default=clusters.DEFAULT_RESAMPLES)
    parser.add_argument("--bootstrap-seed", type=int, default=clusters.DEFAULT_SEED)
    args = parser.parse_args(argv)
    try:
        report = calibrate(cli=args.cli, un_root=args.un_root, output=args.output,
                           targets=args.targets, include_partial=args.include_partial,
                           maximum_length_ratio=args.maximum_length_ratio,
                           batch_size=args.batch_size, timeout_seconds=args.timeout_seconds,
                           bootstrap_resamples=args.bootstrap_resamples,
                           bootstrap_seed=args.bootstrap_seed)
    except (ValueError, OSError) as error:
        parser.error(str(error))
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
