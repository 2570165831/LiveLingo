#!/usr/bin/env python3
"""Post-hoc threshold comparison and metadata-only case explanations.

This is NOT a selection procedure. It re-applies simulate.simulate() to
already-collected metadata rows for a fixed list of configurations derived from
a frozen parameters file, so an owner can compare alternatives after the
pre-registered freeze. Its output is labelled post hoc and must never replace
or rewrite the frozen parameters or the holdout validation report.

Case explanations describe English false switches and wrong-language switches
with metadata only (split, track, index, times, reference label, probe language
and probabilities, which trigger and confirmation rule fired). Rows marked
private_classroom are never described; they are only counted.

CLI: posthoc.py --input FILE... --parameters parameters.json --output out.json
                [--latin-thresholds 0.55 0.70 ...]
                [--variant NAME:key=value,key=value[:ORIGIN] ...]
All paths come from arguments. Only the standard library is required.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from dataclasses import asdict, replace
from pathlib import Path
from typing import Any, Iterable, Mapping

if __package__:
    from . import simulate
    from .simulate import InputError, Parameters
else:
    import simulate
    from simulate import InputError, Parameters

SCOPE = "post_hoc_comparison_not_preregistered"
WARNING = (
    "Post-hoc comparison computed after the pre-registered dev-only freeze and after "
    "the holdout results were known. It is not a selection procedure, its holdout "
    "numbers are not independent validation of any alternative configuration, and "
    "it does not change the frozen parameters."
)
SPLIT_ORDER = ("dev", "original", "new")
CASE_FAILURES = ("english_false_switch", "wrong_language_switch")
FLOAT_FIELDS = frozenset({
    "latin_threshold", "latin_english_max", "nonlatin_threshold",
    "nonlatin_english_max", "few_mean_threshold", "few_min_threshold",
})
BOOL_FIELDS = frozenset({"latin_consensus", "nonlatin_consensus"})


def _boolean(text: str) -> bool:
    value = text.strip().lower()
    if value in {"on", "true", "1", "yes"}:
        return True
    if value in {"off", "false", "0", "no"}:
        return False
    raise InputError("boolean overrides must be on/off")


def parse_overrides(text: str) -> dict[str, Any]:
    """Parse 'key=value,key=value' into typed Parameters overrides."""
    overrides: dict[str, Any] = {}
    for item in filter(None, (part.strip() for part in text.split(","))):
        key, separator, value = item.partition("=")
        key = key.strip()
        if not separator or key in overrides:
            raise InputError("overrides must be unique key=value pairs")
        if key in FLOAT_FIELDS:
            try:
                overrides[key] = float(value)
            except ValueError as exc:
                raise InputError(f"override {key} must be a number") from exc
        elif key in BOOL_FIELDS:
            overrides[key] = _boolean(value)
        elif key == "policy":
            overrides[key] = value.strip()
        else:
            raise InputError("unsupported override field")
    return overrides


def configurations(
    frozen: Parameters | Mapping[str, Any], latin_thresholds: Iterable[float],
    variants: Iterable[tuple[str, Mapping[str, Any], str]] = (),
) -> list[dict[str, Any]]:
    """Frozen parameters with only latin_threshold changed, plus named variants."""
    base = simulate._parameters(frozen)
    result, names = [], set()
    for threshold in latin_thresholds:
        parameters = replace(base, latin_threshold=float(threshold))
        name = f"latin_{parameters.latin_threshold:.2f}"
        origin = ("frozen (pre-registered dev rule)" if parameters == base
                  else "post hoc: frozen parameters with only latin_threshold changed")
        result.append({"name": name, "origin": origin, "parameters": asdict(parameters)})
        names.add(name)
    for name, overrides, origin in variants:
        if name in names:
            raise InputError("configuration names must be unique")
        names.add(name)
        result.append({"name": name, "origin": origin,
                       "parameters": asdict(replace(base, **dict(overrides)))})
    return result


def comparison_metrics(rows: Iterable[Mapping[str, Any]], parameters: Parameters | Mapping[str, Any]) -> dict[str, Any]:
    """Hard-label metrics, cost, and the probe-failure worst-case English bound."""
    data = list(rows)
    summary = simulate.simulate(data, parameters)
    bound = simulate.probe_failure_sensitivity(data, parameters)
    english = summary["english"]
    return {
        "row_count": summary["row_count"],
        "audio_hours": summary["audio_hours"],
        "english": {key: english[key] for key in ("numerator", "denominator", "rate", "one_sided_95_upper")},
        "languages": summary["languages"],
        "macro_coverage_languages": summary["macro_coverage_languages"],
        "macro_coverage": summary["macro_coverage"],
        "wrong_nonenglish_switch_count": summary["wrong_nonenglish_switch_count"],
        "unlabeled_switch_count": summary["unlabeled_switch_count"],
        "switch_count": summary["switch_count"],
        "probe_count": summary["probe_count"],
        "extra_pk_accepted": summary["extra_pk_accepted"],
        "extra_probe_count_per_audio_hour": summary["extra_probe_count_per_audio_hour"],
        "extra_probe_seconds_per_audio_hour": summary["extra_probe_seconds_per_audio_hour"],
        "selected_probe_failures": summary["selected_probe_failures"],
        "worst_case_probe_failure_english": bound["worst_case"]["english"],
        "worst_case_probe_failure_macro_coverage": bound["worst_case"]["macro_coverage"],
    }


def _triggers(row: Mapping[str, Any], decision: simulate.Decision, parameters: Parameters) -> list[str]:
    fired = []
    if parameters.policy == "P1":
        fired.append("p1_every_segment")
    if not row["parakeet_accepted"]:
        fired.append("parakeet_rejected")
    if parameters.policy == "few":
        mean, minimum = row["pk_mean_probability"], row["pk_min_probability"]
        if mean is not None and mean < parameters.few_mean_threshold:
            fired.append("low_confidence_mean")
        if minimum is not None and minimum < parameters.few_min_threshold:
            fired.append("low_confidence_min")
    if bool(fired) != decision.base_eligible:
        raise InputError("trigger explanation disagrees with the simulator")
    if decision.followup:
        fired.append("followup_after_previous_qualified_segment")
    return fired


def _segment(row: Mapping[str, Any], decision: simulate.Decision, parameters: Parameters) -> dict[str, Any]:
    return {
        "index": row["index"], "start_s": row["start_s"], "end_s": row["end_s"],
        "reference_language": row["reference_language"], "reference_trusted": row["reference_trusted"],
        "selected": decision.selected,
        "trigger": _triggers(row, decision, parameters) if decision.selected else [],
        "reason": decision.reason, "qualified_language": decision.qualified_language,
        "probe_language": row["probe_language"],
        "probe_label_probability": row["probe_label_probability"],
        "probe_english_probability": row["probe_english_probability"],
    }


def explain_cases(
    rows: Iterable[Mapping[str, Any]], parameters: Parameters | Mapping[str, Any],
    failures: Iterable[str] = CASE_FAILURES,
) -> dict[str, Any]:
    """Describe hard-label switch errors with metadata only; never private rows."""
    parameters = simulate._parameters(parameters)
    wanted = set(failures)
    if not wanted <= set(CASE_FAILURES):
        raise InputError("unsupported case failure kind")
    data = simulate._check_rows(rows)
    previous: dict[tuple[str, str, str], tuple[Mapping[str, Any], simulate.Decision]] = {}
    cases, suppressed = [], 0
    for row, decision in zip(data, simulate._decisions(data, parameters)):
        key = simulate._stream_key(row)
        label = simulate._hard_label(row)
        failure = None
        if label == "en" and decision.language:
            failure = "english_false_switch"
        elif label in simulate.NON_ENGLISH and decision.language not in (None, label):
            failure = "wrong_language_switch"
        if failure in wanted:
            if row.get("private_classroom", False):
                suppressed += 1
            else:
                candidate, is_latin = simulate._language_and_script(row["probe_language"], parameters)
                consensus = parameters.latin_consensus if is_latin else parameters.nonlatin_consensus
                prior = previous.get(key)
                case = {
                    "failure": failure, "split": row["split"], "dataset": row["dataset"],
                    "track": row["track"], "index": row["index"],
                    "start_s": row["start_s"], "end_s": row["end_s"],
                    "reference_language": row["reference_language"],
                    "reference_trusted": row["reference_trusted"],
                    "reference_kind": row.get("reference_kind"),
                    "boundary_reason": row.get("boundary_reason"),
                    "floor_interp_waveform_cosine": row.get("floor_interp_waveform_cosine"),
                    "parakeet_accepted": row["parakeet_accepted"],
                    "quality_reason": row.get("quality_reason"),
                    "pk_mean_probability": row["pk_mean_probability"],
                    "pk_min_probability": row["pk_min_probability"],
                    "nl_language": row["nl_language"], "nl_probability": row["nl_probability"],
                    "probe_language": row["probe_language"],
                    "probe_label_probability": row["probe_label_probability"],
                    "probe_english_probability": row["probe_english_probability"],
                    "switch_language": decision.language, "reason": decision.reason,
                    "trigger": _triggers(row, decision, parameters),
                    "gate": {
                        "script": "latin" if is_latin else "non_latin",
                        "label_threshold": parameters.latin_threshold if is_latin else parameters.nonlatin_threshold,
                        "english_max": parameters.latin_english_max if is_latin else parameters.nonlatin_english_max,
                    },
                    "confirmation": ("previous_adjacent_segment_qualified_same_language" if consensus
                                     else "single_segment_no_consensus_required"),
                    "previous_segment": _segment(*prior, parameters) if prior else None,
                }
                if consensus and (case["previous_segment"] is None
                                  or case["previous_segment"]["index"] + 1 != row["index"]
                                  or case["previous_segment"]["qualified_language"] != candidate):
                    raise InputError("confirmation explanation disagrees with the simulator")
                cases.append(case)
        previous[key] = (row, decision)
    return {"parameters": asdict(parameters), "cases": cases, "private_cases_suppressed": suppressed}


def _by_split(rows: list[Mapping[str, Any]]) -> dict[str, list[Mapping[str, Any]]]:
    groups: dict[str, list[Mapping[str, Any]]] = {}
    for row in rows:
        groups.setdefault(row["split"], []).append(row)
    return {split: groups[split] for split in SPLIT_ORDER if split in groups}


def compare(
    rows: Iterable[Mapping[str, Any]], configs: list[dict[str, Any]],
) -> dict[str, Any]:
    """Metrics and cases for every configuration on every split present."""
    groups = _by_split(simulate._check_rows(rows))
    results, cases = [], []
    for config in configs:
        for split, subset in groups.items():
            metrics = comparison_metrics(subset, config["parameters"])
            results.append({"configuration": config["name"], "split": split, **metrics})
            explained = explain_cases(subset, config["parameters"])
            summary = simulate.simulate(subset, config["parameters"])
            english = sum(case["failure"] == "english_false_switch" for case in explained["cases"])
            wrong = sum(case["failure"] == "wrong_language_switch" for case in explained["cases"])
            # Private rows never carry hard labels; the totals must still agree exactly.
            if (english + wrong + explained["private_cases_suppressed"]
                    != summary["english"]["numerator"] + summary["wrong_nonenglish_switch_count"]):
                raise InputError("case explanations disagree with the simulator totals")
            cases.append({"configuration": config["name"], "split": split,
                          "private_cases_suppressed": explained["private_cases_suppressed"],
                          "cases": explained["cases"]})
    return {"scope": SCOPE, "warning": WARNING, "configurations": configs,
            "splits": {split: len(subset) for split, subset in groups.items()},
            "results": results, "cases": cases}


def parse_variant(text: str) -> tuple[str, dict[str, Any], str]:
    name, separator, rest = text.partition(":")
    overrides, _, origin = rest.partition(":")
    if not separator or not name.strip():
        raise InputError("variants must be NAME:key=value,...[:ORIGIN]")
    return name.strip(), parse_overrides(overrides), origin.strip() or "post hoc variant"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--input", nargs="+", required=True, type=Path)
    parser.add_argument("--parameters", required=True, type=Path, help="frozen parameters JSON")
    parser.add_argument("--latin-thresholds", nargs="+", type=float, default=(0.55, 0.70, 0.80, 0.90, 0.97))
    parser.add_argument("--variant", action="append", default=[], help="NAME:key=value,...[:ORIGIN]")
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args(argv)
    try:
        raw = arguments.parameters.read_bytes()
        try:
            frozen = json.loads(raw)
        except (json.JSONDecodeError, UnicodeDecodeError) as exc:
            raise InputError("invalid frozen parameters JSON") from exc
        if not isinstance(frozen, dict) or "parameters" not in frozen:
            raise InputError("frozen parameters file must contain parameters")
        rows, evidence = simulate.read_jsonl(arguments.input, allowed_splits=set(SPLIT_ORDER))
        configs = configurations(frozen["parameters"], arguments.latin_thresholds,
                                 [parse_variant(text) for text in arguments.variant])
        report = compare(rows, configs)
        report.update({
            "created_at_utc": simulate._utc_now(),
            "frozen_parameters_sha256": hashlib.sha256(raw).hexdigest(),
            "frozen_parameters": frozen["parameters"], "inputs": evidence,
        })
        simulate._write_json(arguments.output, report)
        print(simulate._json_text({"scope": SCOPE, "output": str(arguments.output),
                                   "configurations": [config["name"] for config in configs],
                                   "splits": report["splits"]}), end="")
    except (InputError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
