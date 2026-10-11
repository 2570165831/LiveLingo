#!/usr/bin/env python3
"""Causal trigger evaluation using segment metadata only (no text payloads).

API: simulate(rows, Parameters(...)) -> a JSON-serializable aggregate report.
CLI: scan --input DEV... --output-dir DIR
     freeze --input DEV... --scan-report DIR/scan.json --output parameters.json
            [--freeze-threshold .90 --freeze-nonlatin-consensus on]
     validate --input ORIGINAL NEW --parameters parameters.json --output FILE

Only a confirmed decision on the current segment counts as a switch or coverage.
The first probability-qualified segment can request a follow-up probe, but is
never retroactively covered. NL metadata is diagnostic, not an extra decision
gate. Language code strings are not classified by their characters: e.g. "zh"
uses the non-Latin gate. Explicit script subtags override the code lookup.

The pure simulation and confidence interval implementation need only stdlib.
Scan plotting additionally requires matplotlib. All paths come from arguments.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import re
import sys
from collections import Counter
from dataclasses import asdict, dataclass, replace
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Mapping, NamedTuple


PARAMETER_VERSION = "trigger-eval-v1"
REPORT_VERSION = 1
LANGUAGES = ("en", "fr", "es", "ar", "zh", "ru")
NON_ENGLISH = LANGUAGES[1:]
LATIN_THRESHOLDS = tuple(i / 100 for i in range(50, 96, 5)) + (0.97,)
# Codes for languages conventionally written in Latin. Unknown scripts use the
# stricter non-Latin gate; callers can explicitly configure this code set.
LATIN_LANGUAGES = (
    "af", "bs", "ca", "cs", "cy", "da", "de", "en", "es", "et", "eu",
    "fi", "fr", "ga", "gl", "hr", "hu", "id", "is", "it", "la", "lt",
    "lv", "ms", "mt", "nb", "nl", "nn", "no", "pl", "pt", "ro", "sk",
    "sl", "sq", "sv", "sw", "tr", "vi", "zu",
)
# Accepted 2026-10-09 by the main reviewer (Claude Code): deterministic Qwen
# language-probe failures are measured as "no switch", as the App falls back to
# English. They are counted and bounded, never silently dropped.
PROBE_FAILURE_MODES = ("no_switch", "worst_case")
# Sentinel emitted only by the pessimistic worst-case accounting mode.
WORST_CASE_SWITCH = "probe_failure_worst_case"
TRACK_PROBE_FAILURE_LIMIT = 0.01
CORPUS_PROBE_FAILURE_LIMIT = 0.02
# Fixed ValueError messages raised by qwen_asr_service.probe_language.
PROBE_ERROR_CLASSES = (
    "Unsupported prompt suffix", "Unparsed language head",
    "Ambiguous language head", "Unterminated language head",
)
PROBE_FAILURE_SENSITIVITY_DEFINITION = (
    "(a) no_switch: a failed probe yields no switch and breaks the confirmation chain, "
    "matching the App's English fallback. (b) worst_case: every selected failed probe "
    "emits a switch to an unknown language (a false switch on trusted-English segments) "
    "and satisfies the next segment's follow-up/consensus; non-English coverage is the "
    "per-language minimum of (a) and the worst-case simulation, so a failed probe is "
    "always a miss and no wildcard confirmation is credited."
)
RECONSTRUCTION_NOTES = {
    "few_confidence": (
        "Original source parameters unavailable. Reconstructed defaults are "
        "mean < 0.90 OR min < 0.05; actual values are recorded in parameters."
    ),
    "segmentation": (
        "6s开始静音尾搜索，8s最大，250ms能量帧，500ms静音，-35dBFS；不等同App preview"
    ),
    "segmentation_origin": "Historical chunking was lost; these are collector reconstruction settings.",
    "reference": (
        "Only trusted non-null reference labels contribute to hard English "
        "risk and selection coverage. Classroom model_proxy labels are "
        "descriptive aggregates only. Unlabeled rows still advance causal state."
    ),
    "probe_failures": (
        "Deterministic Qwen language-probe failures are allowed and counted "
        "(no_switch, the App's English fallback); collections stop on any "
        "Parakeet failure, input-hash change, >1% probe failures on a track or "
        ">2% in a corpus. A worst-case bound is reported separately."
    ),
}
REQUIRED_FIELDS = frozenset({
    "dataset", "split", "track", "index", "start_s", "end_s",
    "reference_language", "reference_trusted", "parakeet_accepted",
    "pk_mean_probability", "pk_min_probability", "pk_word_count",
    "pk_words_per_second", "nl_language", "nl_probability", "probe_language",
    "probe_label_probability", "probe_english_probability", "probe_seconds",
    "probe_error",
})
OPTIONAL_FIELDS = frozenset({
    "private_classroom", "reference_kind", "schema", "boundary_reason",
    "parakeet_seconds", "parakeet_error", "pk_emitted_tokens",
    "pk_mean_log_probability", "pk_min_log_probability", "pk_char_count",
    "english_gate_accepted", "quality_reason", "nl_english_probability",
    "slice_audio_sha256", "floor_interp_waveform_cosine",
})
BOUNDARY_REASONS = frozenset({"maximum", "quiet_tail", "end_of_input", "surviving_census"})
QUALITY_REASONS = frozenset({"emptyTranscript", "invalidText", "implausiblyShort", "repeatedLoop", "runawayText"})
LANGUAGE_PATTERN = re.compile(r"[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*\Z")


class InputError(ValueError):
    """An error whose message contains metadata locations, never row contents."""


def _number(value: Any, *, nullable: bool = False) -> bool:
    return (nullable and value is None) or (
        isinstance(value, (int, float)) and not isinstance(value, bool)
        and math.isfinite(value)
    )


@dataclass(frozen=True)
class Parameters:
    policy: str = "few"
    latin_threshold: float = 0.90
    latin_english_max: float = 0.01
    nonlatin_threshold: float = 0.90
    nonlatin_english_max: float = 0.05
    few_mean_threshold: float = 0.90
    few_min_threshold: float = 0.05
    latin_consensus: bool = True
    nonlatin_consensus: bool = True
    latin_languages: tuple[str, ...] = LATIN_LANGUAGES
    failure_metadata_limit: int = 100

    def __post_init__(self) -> None:
        if not isinstance(self.policy, str) or self.policy not in {"P0", "P1", "few"}:
            raise InputError("policy must be P0, P1, or few")
        for name in (
            "latin_threshold", "latin_english_max", "nonlatin_threshold",
            "nonlatin_english_max", "few_mean_threshold", "few_min_threshold",
        ):
            value = getattr(self, name)
            if not _number(value) or not 0 <= value <= 1:
                raise InputError(f"{name} must be a finite probability")
        if type(self.latin_consensus) is not bool or type(self.nonlatin_consensus) is not bool:
            raise InputError("consensus settings must be booleans")
        if self.policy == "few" and not self.latin_consensus:
            raise InputError("few requires consecutive Latin-language confirmation")
        if type(self.failure_metadata_limit) is not int or self.failure_metadata_limit < 0:
            raise InputError("failure_metadata_limit must be a nonnegative integer")
        if not isinstance(self.latin_languages, (list, tuple)) or any(
            not isinstance(code, str) or not re.fullmatch(r"[a-z]{2,3}", code)
            for code in self.latin_languages
        ):
            raise InputError("latin_languages must contain language codes")
        object.__setattr__(self, "latin_languages", tuple(self.latin_languages))


def _parameters(value: Parameters | Mapping[str, Any]) -> Parameters:
    if isinstance(value, Parameters):
        return value
    if not isinstance(value, Mapping):
        raise InputError("parameters must be Parameters or a mapping")
    try:
        return Parameters(**value)
    except TypeError as exc:
        raise InputError("unknown or malformed parameter fields") from exc


def _check_row(row: Mapping[str, Any], location: str) -> None:
    if not isinstance(row, Mapping):
        raise InputError(f"{location}: expected a metadata object")
    if set(row) - REQUIRED_FIELDS - OPTIONAL_FIELDS:
        raise InputError(f"{location}: unexpected fields; text payloads are unsupported")
    if REQUIRED_FIELDS - set(row):
        raise InputError(f"{location}: required metadata fields missing")
    for field in ("dataset", "track"):
        if not isinstance(row[field], str) or not row[field]:
            raise InputError(f"{location}: {field} must be a nonempty string")
    if not isinstance(row["split"], str) or row["split"] not in {"dev", "original", "new"}:
        raise InputError(f"{location}: invalid split")
    for field in ("reference_trusted", "parakeet_accepted", "probe_error"):
        if type(row[field]) is not bool:
            raise InputError(f"{location}: {field} must be boolean")
    if type(row.get("private_classroom", False)) is not bool:
        raise InputError(f"{location}: private_classroom must be boolean")
    kind = row.get("reference_kind")
    if kind is not None and (
        not isinstance(kind, str) or not re.fullmatch(r"[a-z][a-z0-9_]{0,63}", kind)
    ):
        raise InputError(f"{location}: invalid reference_kind metadata code")
    if type(row["index"]) is not int:
        raise InputError(f"{location}: index must be an integer")
    if type(row["pk_word_count"]) is not int or row["pk_word_count"] < 0:
        raise InputError(f"{location}: pk_word_count must be a nonnegative integer")
    for field in ("start_s", "end_s", "pk_words_per_second", "probe_seconds"):
        if not _number(row[field]) or row[field] < 0:
            raise InputError(f"{location}: {field} must be finite and nonnegative")
    if row["end_s"] < row["start_s"]:
        raise InputError(f"{location}: end_s precedes start_s")
    for field in (
        "pk_mean_probability", "pk_min_probability", "nl_probability",
        "probe_label_probability", "probe_english_probability",
    ):
        value = row[field]
        if not _number(value, nullable=True) or (value is not None and not 0 <= value <= 1):
            raise InputError(f"{location}: {field} must be a probability or null")
    for field in ("reference_language", "nl_language", "probe_language"):
        value = row[field]
        if value is not None and (
            not isinstance(value, str) or not LANGUAGE_PATTERN.fullmatch(value)
        ):
            raise InputError(f"{location}: invalid {field} metadata code")
    if "schema" in row and (type(row["schema"]) is not int or row["schema"] != 1):
        raise InputError(f"{location}: schema must be integer 1")
    if "boundary_reason" in row and (
        not isinstance(row["boundary_reason"], str) or row["boundary_reason"] not in BOUNDARY_REASONS
    ):
        raise InputError(f"{location}: invalid boundary_reason enum")
    if "quality_reason" in row and row["quality_reason"] is not None and (
        not isinstance(row["quality_reason"], str) or row["quality_reason"] not in QUALITY_REASONS
    ):
        raise InputError(f"{location}: invalid quality_reason enum")
    for field in ("parakeet_error", "english_gate_accepted"):
        if field in row and type(row[field]) is not bool:
            raise InputError(f"{location}: {field} must be boolean")
    for field in ("pk_emitted_tokens", "pk_char_count"):
        if field in row and (type(row[field]) is not int or row[field] < 0):
            raise InputError(f"{location}: {field} must be a nonnegative integer count")
    if "parakeet_seconds" in row and (
        not _number(row["parakeet_seconds"]) or row["parakeet_seconds"] < 0
    ):
        raise InputError(f"{location}: parakeet_seconds must be finite and nonnegative")
    for field in ("pk_mean_log_probability", "pk_min_log_probability"):
        if field in row and (
            not _number(row[field], nullable=True) or (row[field] is not None and row[field] > 0)
        ):
            raise InputError(f"{location}: {field} must be finite, nonpositive, or null")
    if "nl_english_probability" in row and (
        not _number(row["nl_english_probability"], nullable=True)
        or (row["nl_english_probability"] is not None and not 0 <= row["nl_english_probability"] <= 1)
    ):
        raise InputError(f"{location}: nl_english_probability must be a probability or null")
    if "slice_audio_sha256" in row and (
        not isinstance(row["slice_audio_sha256"], str)
        or not re.fullmatch(r"[a-fA-F0-9]{64}", row["slice_audio_sha256"])
    ):
        raise InputError(f"{location}: slice_audio_sha256 must be hexadecimal SHA-256")
    if "floor_interp_waveform_cosine" in row and (
        not _number(row["floor_interp_waveform_cosine"])
        or not -1 <= row["floor_interp_waveform_cosine"] <= 1
    ):
        raise InputError(f"{location}: floor_interp_waveform_cosine must be finite within [-1,1]")


def _stream_key(row: Mapping[str, Any]) -> tuple[str, str, str]:
    # Split is an additional barrier; dev state must never leak into validation.
    return row["dataset"], row["split"], row["track"]


def _check_rows(rows: Iterable[Mapping[str, Any]]) -> list[Mapping[str, Any]]:
    materialized = list(rows)
    previous: dict[tuple[str, str, str], int] = {}
    for position, row in enumerate(materialized, 1):
        _check_row(row, f"row {position}")
        key = _stream_key(row)
        if key in previous and row["index"] <= previous[key]:
            raise InputError(f"row {position}: indices must increase within each stream")
        previous[key] = row["index"]
    return materialized


def clopper_pearson_upper(k: int, n: int, confidence: float = 0.95) -> float | None:
    """Exact one-sided binomial upper bound, with no scipy dependency.

    For k=0, this is 1 - (1-confidence)**(1/n). Otherwise invert
    P[Binomial(n, p) <= k] = 1-confidence by bisection. The CDF uses a
    log-PMF and decreasing tail recurrence, avoiding factorial overflow.
    n=0 has no bound, rather than being reported as a zero-risk result.
    """
    if type(k) is not int or type(n) is not int or not 0 <= k <= n:
        raise InputError("binomial counts must be integers with 0 <= k <= n")
    if not _number(confidence) or not 0 < confidence < 1:
        raise InputError("confidence must be between zero and one")
    if n == 0:
        return None
    alpha = 1 - confidence
    if k == 0:
        return -math.expm1(math.log(alpha) / n)
    if k == n:
        return 1.0

    def cdf(p: float) -> float:
        if p >= 1:
            return 0.0
        log_pmf = (
            math.lgamma(n + 1) - math.lgamma(k + 1) - math.lgamma(n - k + 1)
            + k * math.log(p) + (n - k) * math.log1p(-p)
        )
        total = term = 1.0
        for i in range(k, 0, -1):
            term *= (i / (n - i + 1)) * ((1 - p) / p)
            total += term
            if term <= total * 1e-16:
                break
        return min(1.0, math.exp(log_pmf + math.log(total)))

    low, high = k / n, 1.0
    for _ in range(80):
        middle = (low + high) / 2
        if middle == low or middle == high:
            break
        if cdf(middle) > alpha:
            low = middle
        else:
            high = middle
    return high


def _language_and_script(code: str, parameters: Parameters) -> tuple[str, bool]:
    parts = code.lower().split("-")
    scripts = [part for part in parts[1:] if len(part) == 4 and part.isalpha()]
    is_latin = scripts[0] == "latn" if scripts else parts[0] in parameters.latin_languages
    return parts[0], is_latin


class Decision(NamedTuple):
    selected: bool
    base_eligible: bool
    followup: bool
    qualified_language: str | None
    language: str | None
    reason: str


def _check_probe_failure_mode(mode: Any) -> str:
    if not isinstance(mode, str) or mode not in PROBE_FAILURE_MODES:
        raise InputError("probe_failure_mode must be no_switch or worst_case")
    return mode


def _decisions(
    rows: list[Mapping[str, Any]], parameters: Parameters, probe_failure_mode: str = "no_switch",
) -> Iterable[Decision]:
    _check_probe_failure_mode(probe_failure_mode)
    worst = probe_failure_mode == "worst_case"
    previous: dict[tuple[str, str, str], tuple[int, str | None]] = {}
    for row in rows:
        key = _stream_key(row)
        last_index, last_language = previous.get(key, (row["index"] - 2, None))
        adjacent = last_index + 1 == row["index"]
        prior = last_language if adjacent else None
        mean, minimum = row["pk_mean_probability"], row["pk_min_probability"]
        low_confidence = (
            (mean is not None and mean < parameters.few_mean_threshold)
            or (minimum is not None and minimum < parameters.few_min_threshold)
        )
        base = (
            parameters.policy == "P1" or not row["parakeet_accepted"]
            or (parameters.policy == "few" and low_confidence)
        )
        followup = parameters.policy == "few" and prior is not None
        selected = base or followup
        qualified = language = None
        reason = "not_selected"
        if selected:
            if row["probe_error"] and worst:
                # Pessimistic bound only: an unknown-language switch that also
                # acts as a wildcard for the next segment's confirmation.
                qualified = language = WORST_CASE_SWITCH
                reason = "probe_failed_worst_case_switch"
            elif row["probe_error"]:
                reason = "probe_failed"
            elif row["probe_language"] is None:
                reason = "probe_language_none"
            else:
                candidate, is_latin = _language_and_script(row["probe_language"], parameters)
                label, english = row["probe_label_probability"], row["probe_english_probability"]
                if candidate == "en":
                    reason = "probe_english"
                elif label is None:
                    reason = "probe_label_probability_none"
                elif english is None:
                    reason = "probe_english_probability_none"
                elif label < (parameters.latin_threshold if is_latin else parameters.nonlatin_threshold):
                    reason = "below_language_threshold"
                elif english > (parameters.latin_english_max if is_latin else parameters.nonlatin_english_max):
                    reason = "above_english_probability_limit"
                else:
                    qualified = candidate
                    consensus = parameters.latin_consensus if is_latin else parameters.nonlatin_consensus
                    if consensus and prior != candidate and not (worst and prior == WORST_CASE_SWITCH):
                        reason = "pending_consensus"
                    else:
                        language = candidate
                        reason = "confirmed"
        # All rows advance state, including missing/untrusted reference labels.
        # English, failures, unqualified probes, skips, and gaps break a chain.
        previous[key] = (row["index"], qualified)
        yield Decision(selected, base, followup, qualified, language, reason)


def _hard_label(row: Mapping[str, Any]) -> str | None:
    if row["reference_trusted"] and row.get("reference_kind") != "model_proxy":
        code = _reference_code(row)
        return code if code in LANGUAGES else None
    return None


def _reference_code(row: Mapping[str, Any]) -> str | None:
    value = row["reference_language"]
    return value.lower().split("-")[0] if value is not None else None


def _classroom_proxy(row: Mapping[str, Any]) -> bool:
    return row.get("private_classroom", False) and row.get("reference_kind") == "model_proxy"


class _Totals:
    def __init__(self, *, proxy: bool = False) -> None:
        self.proxy = proxy
        self.counts: Counter[str] = Counter()
        self.quality: Counter[str] = Counter()
        self.outcomes: Counter[str] = Counter()
        self.reference_counts: Counter[str] = Counter()
        self.covered: Counter[str] = Counter()
        self.switches: Counter[str] = Counter()
        self.probe_seconds = 0.0
        self.extra_seconds = 0.0
        self.baseline_seconds = 0.0

    def add(self, row: Mapping[str, Any], decision: Decision) -> None:
        self.counts["rows"] += 1
        self.outcomes[decision.reason] += 1
        for field in (
            "reference_language", "pk_mean_probability", "pk_min_probability",
            "nl_language", "nl_probability", "probe_language",
            "probe_label_probability", "probe_english_probability",
        ):
            self.quality[field + "_none"] += row[field] is None
        self.quality["probe_errors_in_input"] += row["probe_error"]
        self.quality["reference_untrusted"] += not row["reference_trusted"]
        self.quality["reference_outside_hard_language_set"] += (
            row["reference_language"] is not None and _reference_code(row) not in LANGUAGES
        )
        self.quality["parakeet_errors_in_input"] += row.get("parakeet_error", False)
        self.quality["model_proxy_marked_trusted"] += (
            row.get("reference_kind") == "model_proxy" and row["reference_trusted"]
        )
        self.counts["private_classroom_rows"] += row.get("private_classroom", False)
        if not row["parakeet_accepted"]:
            self.counts["baseline_probes"] += 1
            self.baseline_seconds += row["probe_seconds"]
        if decision.selected:
            self.counts["probes"] += 1
            self.probe_seconds += row["probe_seconds"]
            self.counts["selected_probe_errors"] += row["probe_error"]
            for field in ("probe_language", "probe_label_probability", "probe_english_probability"):
                self.counts["selected_" + field + "_none"] += row[field] is None
            self.counts["base_policy_probes"] += decision.base_eligible
            self.counts["followup_probes"] += decision.followup
            self.counts["followup_only_probes"] += decision.followup and not decision.base_eligible
            if row["parakeet_accepted"]:
                self.counts["extra_probes"] += 1
                self.extra_seconds += row["probe_seconds"]
        self.counts["probability_qualified"] += decision.qualified_language is not None
        self.counts["switches"] += decision.language is not None
        if decision.language:
            self.switches[decision.language] += 1
        label = _reference_code(row) if self.proxy else _hard_label(row)
        if label is None:
            self.counts["unlabeled_for_metrics"] += 1
            self.counts["unlabeled_switches"] += decision.language is not None
            return
        self.counts["labeled_for_metrics"] += 1
        self.reference_counts[label] += 1
        if label == "en":
            self.counts["english_switches"] += decision.language is not None
            self.counts["english_probability_qualified"] += decision.qualified_language is not None
        elif decision.language == label:
            self.covered[label] += 1
        elif decision.language is not None and decision.language != WORST_CASE_SWITCH:
            # A worst-case failed probe on a non-English segment is a miss.
            self.counts["wrong_nonenglish_switches"] += 1

    def report(self) -> dict[str, Any]:
        n, k = self.reference_counts["en"], self.counts["english_switches"]
        codes = NON_ENGLISH + tuple(sorted(set(self.reference_counts) - set(LANGUAGES))) if self.proxy else NON_ENGLISH
        coverage = {
            code: {
                "numerator": self.covered[code], "denominator": self.reference_counts[code],
                "coverage": self.covered[code] / self.reference_counts[code]
                if self.reference_counts[code] else None,
            }
            for code in codes
        }
        present = [code for code in codes if self.reference_counts[code]]
        return {
            "row_count": self.counts["rows"],
            "labeled_for_metrics": self.counts["labeled_for_metrics"],
            "unlabeled_for_metrics": self.counts["unlabeled_for_metrics"],
            "private_classroom_rows": self.counts["private_classroom_rows"],
            "english": {
                "numerator": k, "denominator": n, "rate": k / n if n else None,
                "one_sided_95_upper": None if self.proxy else clopper_pearson_upper(k, n),
                "probability_qualified_candidates": self.counts["english_probability_qualified"],
            },
            "languages": coverage,
            "reference_language_denominators": {
                code: self.reference_counts[code]
                for code in LANGUAGES + tuple(sorted(set(self.reference_counts) - set(LANGUAGES)))
            },
            "macro_coverage_languages": present,
            "macro_coverage": sum(coverage[code]["coverage"] for code in present) / len(present)
            if present else None,
            "probe_count": self.counts["probes"], "probe_seconds": self.probe_seconds,
            "baseline": {
                "policy": "P0", "probe_count": self.counts["baseline_probes"],
                "probe_seconds": self.baseline_seconds,
            },
            "extra_pk_accepted": {
                "probe_count": self.counts["extra_probes"], "probe_seconds": self.extra_seconds,
            },
            "base_policy_probe_count": self.counts["base_policy_probes"],
            "followup_probe_count": self.counts["followup_probes"],
            "followup_only_probe_count": self.counts["followup_only_probes"],
            "probability_qualified_count": self.counts["probability_qualified"],
            "switch_count": self.counts["switches"],
            "switches_by_language": dict(sorted(self.switches.items())),
            "wrong_nonenglish_switch_count": self.counts["wrong_nonenglish_switches"],
            "unlabeled_switch_count": self.counts["unlabeled_switches"],
            "selected_probe_failures": self.counts["selected_probe_errors"],
            "selected_probe_language_none": self.counts["selected_probe_language_none"],
            "selected_probe_label_probability_none": self.counts["selected_probe_label_probability_none"],
            "selected_probe_english_probability_none": self.counts["selected_probe_english_probability_none"],
            "input_quality": dict(sorted(self.quality.items())),
            "decision_outcomes": dict(sorted(self.outcomes.items())),
        }


def _union_seconds(intervals: list[tuple[float, float]]) -> float:
    total = 0.0
    last_start = last_end = None
    for start, end in sorted(intervals):
        if last_end is None or start > last_end:
            if last_end is not None:
                total += last_end - last_start
            last_start, last_end = start, end
        else:
            last_end = max(last_end, end)
    return total + (last_end - last_start if last_end is not None else 0.0)


def simulate(
    rows: Iterable[Mapping[str, Any]], parameters: Parameters | Mapping[str, Any] = Parameters(),
    *, probe_failure_mode: str = "no_switch",
) -> dict[str, Any]:
    """Evaluate all rows without mutating or serializing the input rows.

    Per-track time denominators are the union of supplied segment intervals,
    excluding unobserved gaps. A switch is an emitted non-English decision on
    this segment; this does not simulate a persistent decoder-language latch.
    Candidate metadata is bounded and is always suppressed for private rows.
    """
    parameters = _parameters(parameters)
    mode = _check_probe_failure_mode(probe_failure_mode)
    data = _check_rows(rows)
    totals, proxy, proxy_p0 = _Totals(), _Totals(proxy=True), _Totals(proxy=True)
    p0 = replace(parameters, policy="P0", latin_consensus=False, nonlatin_consensus=False)
    decisions_p0 = iter(_decisions(data, p0, mode))
    tracks: dict[tuple[str, str, str], dict[str, Any]] = {}
    failures: list[dict[str, Any]] = []
    failure_count = private_suppressed = truncated = 0
    for row, decision in zip(data, _decisions(data, parameters, mode)):
        baseline_decision = next(decisions_p0)
        totals.add(row, decision)
        if _classroom_proxy(row):
            proxy.add(row, decision)
            proxy_p0.add(row, baseline_decision)
        key = _stream_key(row)
        if key not in tracks:
            tracks[key] = {"totals": _Totals(), "intervals": [], "private": False}
        track = tracks[key]
        track["totals"].add(row, decision)
        track["intervals"].append((row["start_s"], row["end_s"]))
        track["private"] |= row.get("private_classroom", False)
        label = _hard_label(row)
        failure = None
        if label == "en" and decision.language:
            failure = "english_false_switch"
        elif label in NON_ENGLISH and decision.language != label:
            failure = ("missed_coverage" if decision.language in (None, WORST_CASE_SWITCH)
                       else "wrong_language_switch")
        elif label is None and decision.language:
            failure = "unlabeled_switch"
        if failure is None:
            continue
        failure_count += 1
        if row.get("private_classroom", False):
            private_suppressed += 1
        elif len(failures) >= parameters.failure_metadata_limit:
            truncated += 1
        else:
            failures.append({
                "dataset": row["dataset"], "split": row["split"], "track": row["track"],
                "index": row["index"], "start_s": row["start_s"], "end_s": row["end_s"],
                "reference_language": row["reference_language"],
                "reference_trusted": row["reference_trusted"],
                "reference_kind": row.get("reference_kind"), "failure": failure,
                "selected": decision.selected, "reason": decision.reason,
                "qualified_language": decision.qualified_language, "switch_language": decision.language,
                "probe_language": row["probe_language"],
                "probe_label_probability": row["probe_label_probability"],
                "probe_english_probability": row["probe_english_probability"],
            })
    result = totals.report()
    per_track = []
    for (dataset, split, name), track in sorted(tracks.items()):
        track_totals = track["totals"].report()
        seconds = _union_seconds(track["intervals"])
        hours = seconds / 3600
        extra = track_totals["extra_pk_accepted"]
        per_track.append({
            "dataset": dataset, "split": split, "track": name,
            "private_classroom": track["private"], "row_count": track_totals["row_count"],
            "audio_seconds": seconds, "audio_hours": hours,
            "probe_count": track_totals["probe_count"], "probe_seconds": track_totals["probe_seconds"],
            "baseline": track_totals["baseline"], "extra_pk_accepted": extra,
            "extra_probe_count_per_audio_hour": extra["probe_count"] / hours if hours else None,
            "extra_probe_seconds_per_audio_hour": extra["probe_seconds"] / hours if hours else None,
        })
    audio_hours = sum(item["audio_hours"] for item in per_track)
    proxy_report, proxy_baseline = proxy.report(), proxy_p0.report()
    zh, zh_p0 = proxy.switches["zh"], proxy_p0.switches["zh"]
    proxy_report.update({
        "label_evidence": "untrusted classroom model_proxy; descriptive only, excluded from selection",
        "p0_baseline": proxy_baseline,
        "p0_baseline_parameters": asdict(p0),
        "chinese_switches": {"simulated": zh, "p0": zh_p0, "net_increase_over_p0": zh - zh_p0},
        "chinese_proxy_coverage_net_increase_over_p0": proxy.covered["zh"] - proxy_p0.covered["zh"],
    })
    result.update({
        "parameter_version": PARAMETER_VERSION, "parameters": asdict(parameters),
        "probe_failure_mode": mode,
        "duration_basis": "union of supplied segment intervals per dataset/split/track; gaps excluded",
        "audio_hours": audio_hours, "per_track": per_track,
        "extra_probe_count_per_audio_hour": result["extra_pk_accepted"]["probe_count"] / audio_hours
        if audio_hours else None,
        "extra_probe_seconds_per_audio_hour": result["extra_pk_accepted"]["probe_seconds"] / audio_hours
        if audio_hours else None,
        "failure_candidate_count": failure_count, "failure_candidates": failures,
        "private_candidate_metadata_suppressed": private_suppressed,
        "failure_candidate_metadata_truncated": truncated,
        "classroom_proxy": proxy_report,
        "reconstruction_notes": dict(RECONSTRUCTION_NOTES),
    })
    return result


def _hard_metrics(result: Mapping[str, Any]) -> dict[str, Any]:
    english = result["english"]
    return {
        "english": {key: english[key] for key in ("numerator", "denominator", "rate", "one_sided_95_upper")},
        "languages": {code: dict(value) for code, value in result["languages"].items()},
        "macro_coverage_languages": list(result["macro_coverage_languages"]),
        "macro_coverage": result["macro_coverage"],
    }


def probe_failure_sensitivity(
    rows: Iterable[Mapping[str, Any]], parameters: Parameters | Mapping[str, Any],
) -> dict[str, Any]:
    """Hard-English risk and trusted coverage under (a) no_switch and (b) worst_case."""
    parameters = _parameters(parameters)
    data = _check_rows(rows)
    no_switch = simulate(data, parameters)
    worst = simulate(data, parameters, probe_failure_mode="worst_case")
    by_reference: Counter[str] = Counter()
    for row, decision in zip(data, _decisions(data, parameters)):
        if decision.selected and row["probe_error"]:
            label = _hard_label(row)
            by_reference["english" if label == "en" else "non_english" if label in NON_ENGLISH else "unlabeled"] += 1
    n = no_switch["english"]["denominator"]
    # Worst case can only add switches; max() keeps the bound monotone regardless.
    k = max(no_switch["english"]["numerator"], worst["english"]["numerator"])
    languages = {}
    for code, metrics in no_switch["languages"].items():
        numerator = min(metrics["numerator"], worst["languages"][code]["numerator"])
        denominator = metrics["denominator"]
        languages[code] = {"numerator": numerator, "denominator": denominator,
                           "coverage": numerator / denominator if denominator else None}
    present = list(no_switch["macro_coverage_languages"])
    return {
        "definition": PROBE_FAILURE_SENSITIVITY_DEFINITION,
        "parameters": asdict(parameters),
        "probe_failures_in_input": sum(row["probe_error"] for row in data),
        "selected_probe_failures": no_switch["selected_probe_failures"],
        "selected_probe_failures_by_reference": {
            key: by_reference[key] for key in ("english", "non_english", "unlabeled")
        },
        "no_switch": _hard_metrics(no_switch),
        "worst_case": {
            "english": {"numerator": k, "denominator": n, "rate": k / n if n else None,
                        "one_sided_95_upper": clopper_pearson_upper(k, n)},
            "languages": languages,
            "macro_coverage_languages": present,
            "macro_coverage": sum(languages[code]["coverage"] for code in present) / len(present)
            if present else None,
        },
    }


def collection_failure_gate(
    files: Iterable[Mapping[str, Any]], *, track_limit: float = TRACK_PROBE_FAILURE_LIMIT,
    corpus_limit: float = CORPUS_PROBE_FAILURE_LIMIT,
) -> dict[str, Any]:
    """Fail closed on Parakeet failures and on probe-failure rates above the limits.

    Rates use exact fractions: 8/800 is exactly 1% and passes; 9/800 stops.
    Raises InputError with fixed codes; never echoes row contents.
    """
    from fractions import Fraction

    for limit in (track_limit, corpus_limit):
        if not _number(limit) or not 0 <= limit <= 1:
            raise InputError("probe failure limits must be probabilities")
    track_cap, corpus_cap = Fraction(str(track_limit)), Fraction(str(corpus_limit))
    per_track, segments_total, failures_total = [], 0, 0
    for item in files:
        if not isinstance(item, Mapping):
            raise InputError("collection_failure_counts_invalid")
        segments, probe, parakeet = (item.get(key) for key in ("segments", "probe_failures", "parakeet_failures"))
        if any(type(value) is not int for value in (segments, probe, parakeet)) or (
            segments <= 0 or not 0 <= probe <= segments or parakeet < 0
        ):
            raise InputError("collection_failure_counts_invalid")
        if parakeet:
            raise InputError("parakeet_failures_present")
        if Fraction(probe, segments) > track_cap:
            raise InputError("track_probe_failure_rate_exceeds_limit")
        per_track.append({"dataset": item.get("dataset"), "track": item.get("track"), "segments": segments,
                          "probe_failures": probe, "probe_failure_rate": probe / segments})
        segments_total += segments
        failures_total += probe
    if not per_track:
        raise InputError("collection_has_no_files")
    if Fraction(failures_total, segments_total) > corpus_cap:
        raise InputError("corpus_probe_failure_rate_exceeds_limit")
    return {"segments": segments_total, "probe_failures": failures_total,
            "probe_failure_rate": failures_total / segments_total,
            "track_limit": track_limit, "corpus_limit": corpus_limit, "per_track": per_track}


def check_probe_failure_classification(
    rows: Iterable[Mapping[str, Any]], classification: Mapping[str, Any], *, split: str,
) -> dict[str, Any]:
    """Accept only deterministic, known-class probe failures on byte-identical slices."""
    data = _check_rows(rows)
    if not isinstance(classification, Mapping) or classification.get("schema") != 1 or classification.get("split") != split:
        raise InputError("probe_failure_classification_identity_mismatch")
    failed = {(row["dataset"], row["track"], row["index"]): row for row in data if row["probe_error"]}
    entries = classification.get("failures")
    if not isinstance(entries, list) or any(not isinstance(entry, Mapping) for entry in entries):
        raise InputError("probe_failure_classification_invalid")
    keys = [(entry.get("dataset"), entry.get("track"), entry.get("index")) for entry in entries]
    if len(set(keys)) != len(keys) or set(keys) != set(failed):
        raise InputError("probe_failure_classification_does_not_cover_failures")
    by_class: Counter[str] = Counter()
    by_track: dict[tuple[str, str], Counter[str]] = {}
    for key, entry in zip(keys, entries):
        row = failed[key]
        if (entry.get("same_slice_as_collection") is not True or
                entry.get("slice_audio_sha256") != row.get("slice_audio_sha256")):
            raise InputError("probe_failure_slice_changed")
        error_class = entry.get("error_class")
        if error_class not in PROBE_ERROR_CLASSES:
            raise InputError("probe_failure_class_not_accepted")
        attempts = entry.get("attempts")
        if (entry.get("deterministic") is not True or not isinstance(attempts, list) or len(attempts) < 2
                or any(attempt != error_class for attempt in attempts)):
            raise InputError("probe_failure_not_deterministic")
        by_class[error_class] += 1
        by_track.setdefault(key[:2], Counter())[error_class] += 1
    return {"split": split, "probe_failures": len(entries), "by_class": dict(sorted(by_class.items())),
            "by_track": [{"dataset": dataset, "track": track, "by_class": dict(sorted(counts.items()))}
                         for (dataset, track), counts in sorted(by_track.items())]}


def read_jsonl(
    paths: Iterable[str | Path], *, allowed_splits: set[str],
) -> tuple[list[Mapping[str, Any]], list[dict[str, Any]]]:
    """Read metadata-only files; reject mixed/held-out inputs during dev work."""
    rows: list[Mapping[str, Any]] = []
    evidence = []
    seen_paths: set[Path] = set()
    for supplied in paths:
        path = Path(supplied).resolve(strict=True)
        if path in seen_paths:
            raise InputError("duplicate input file")
        seen_paths.add(path)
        before = path.stat()
        digest = hashlib.sha256()
        count = 0
        with path.open("rb") as handle:
            for line_number, raw in enumerate(handle, 1):
                digest.update(raw)
                if not raw.strip():
                    continue
                try:
                    row = json.loads(raw)
                except (json.JSONDecodeError, UnicodeDecodeError) as exc:
                    raise InputError(f"{path}: line {line_number}: invalid JSON metadata") from exc
                _check_row(row, f"{path}: line {line_number}")
                if row["split"] not in allowed_splits:
                    raise InputError(f"{path}: line {line_number}: input contains a disallowed split")
                rows.append(row)
                count += 1
        after = path.stat()
        if (before.st_ino, before.st_size, before.st_mtime_ns) != (
            after.st_ino, after.st_size, after.st_mtime_ns,
        ):
            raise InputError(f"{path}: metadata file changed during reading")
        evidence.append({"path": str(path), "sha256": digest.hexdigest(), "bytes": after.st_size, "row_count": count})
    if not evidence:
        raise InputError("at least one input file is required")
    return _check_rows(rows), evidence


def recommend_configuration(results: list[dict[str, Any]], tolerance: float = 0.05) -> dict[str, Any]:
    """Maximize coverage among stable configurations with zero English switches.

    Stability requires the immediately lower sampled threshold, in the same
    non-Latin-consensus series, to also have zero English switches and an
    absolute macro-coverage difference strictly below tolerance. When individual
    language coverage is supplied, each language must also stay below that
    difference. The 0.50 boundary cannot qualify without a lower neighbor.
    """
    if not _number(tolerance) or not 0 < tolerance <= 1:
        raise InputError("stability tolerance must be positive and at most one")
    eligible = [
        item for item in results if item["parameters"]["policy"] == "few"
        and item["english"]["denominator"] > 0 and item["english"]["numerator"] == 0
        and item["macro_coverage"] is not None
    ]
    no_safe = {"status": "no_safe_plateau", "stability_tolerance": tolerance}
    if not eligible:
        return {**no_safe, "reason": "no zero-switch few configuration with trusted English and coverage labels"}
    optimum = max(item["macro_coverage"] for item in eligible)
    stable = []
    for item in eligible:
        parameters = item["parameters"]
        lower = [
            other for other in results
            if other["parameters"]["policy"] == "few"
            and all(other["parameters"][key] == value for key, value in parameters.items() if key != "latin_threshold")
            and other["parameters"]["latin_threshold"] < parameters["latin_threshold"]
        ]
        if not lower:
            continue
        neighbor = max(lower, key=lambda other: other["parameters"]["latin_threshold"])
        difference = abs(item["macro_coverage"] - neighbor["macro_coverage"]) if neighbor["macro_coverage"] is not None else math.inf
        language_differences = {}
        for code, metrics in item.get("languages", {}).items():
            a, b = metrics["coverage"], neighbor.get("languages", {}).get(code, {}).get("coverage")
            if a is not None and b is not None:
                language_differences[code] = abs(a - b)
        largest_difference = max([difference, *language_differences.values()])
        strictly_stable = largest_difference < tolerance and not math.isclose(largest_difference, tolerance, rel_tol=0, abs_tol=1e-12)
        if neighbor["english"]["denominator"] > 0 and neighbor["english"]["numerator"] == 0 and strictly_stable:
            stable.append((item, neighbor, difference, language_differences))
    if not stable:
        return {**no_safe, "reason": "no safe configuration has a stable immediately lower neighbor", "maximum_safe_macro_coverage": optimum}
    winner, neighbor, difference, language_differences = max(
        stable, key=lambda entry: (entry[0]["macro_coverage"], entry[0]["parameters"]["latin_threshold"], entry[0]["parameters"]["nonlatin_consensus"]),
    )
    return {
        "status": "recommended", "parameters": winner["parameters"],
        "macro_coverage": winner["macro_coverage"], "stability_tolerance": tolerance,
        "maximum_safe_macro_coverage": optimum,
        "coverage_loss_for_stability": optimum - winner["macro_coverage"],
        "lower_neighbor_threshold": neighbor["parameters"]["latin_threshold"],
        "lower_neighbor_macro_coverage": neighbor["macro_coverage"],
        "neighbor_coverage_difference": difference,
        "neighbor_language_coverage_differences": language_differences,
        "english": winner["english"],
        "rule": "zero confirmed English switches; stable lower neighbor for macro and each language; maximum stable trusted macro coverage; highest threshold",
    }


def scan_probe_failure_sensitivity(
    rows: Iterable[Mapping[str, Any]], results: list[dict[str, Any]], tolerance: float = 0.05,
) -> dict[str, Any]:
    """Re-run the recommendation rule with every few configuration in worst case."""
    data = _check_rows(rows)
    worst_results, bounds = [], {}
    for item in results:
        if item["parameters"]["policy"] != "few":
            continue
        bound = probe_failure_sensitivity(data, item["parameters"])
        worst_results.append({"parameters": item["parameters"], **bound["worst_case"],
                              "selected_probe_failures": bound["selected_probe_failures"],
                              "selected_probe_failures_by_reference": bound["selected_probe_failures_by_reference"]})
        bounds[json.dumps(item["parameters"], sort_keys=True)] = bound
    no_switch = recommend_configuration(results, tolerance)
    worst = recommend_configuration(worst_results, tolerance)
    changed = (no_switch["status"], no_switch.get("parameters")) != (worst["status"], worst.get("parameters"))
    selected = (bounds.get(json.dumps(no_switch["parameters"], sort_keys=True))
                if no_switch["status"] == "recommended" else None)
    return {
        "definition": PROBE_FAILURE_SENSITIVITY_DEFINITION,
        "probe_failures_in_input": sum(row["probe_error"] for row in data),
        "no_switch_recommendation_status": no_switch["status"],
        "worst_case_recommendation": worst,
        "recommendation_changes_under_worst_case": changed,
        "recommended_configuration_bound": selected,
        "worst_case_results": worst_results,
    }


def scan(
    rows: Iterable[Mapping[str, Any]], *, base: Parameters = Parameters(),
    policies: Iterable[str] = ("P0", "P1", "few"),
    nonlatin_consensus: Iterable[bool] = (False, True),
    baseline_consensus: bool = False, stability_tolerance: float = 0.05,
) -> dict[str, Any]:
    data = _check_rows(rows)
    if any(row["split"] != "dev" for row in data):
        raise InputError("scan accepts dev metadata only; mixed inputs are rejected")
    policies = tuple(dict.fromkeys(policies))
    settings = tuple(dict.fromkeys(nonlatin_consensus))
    if not policies or any(policy not in {"P0", "P1", "few"} for policy in policies):
        raise InputError("scan policies must be P0, P1, or few")
    if not settings or any(type(setting) is not bool for setting in settings):
        raise InputError("nonlatin_consensus scan settings must be booleans")
    # Scan specification fixes these risk gates and the non-Latin threshold.
    if (base.latin_english_max, base.nonlatin_threshold, base.nonlatin_english_max) != (0.01, 0.90, 0.05):
        raise InputError("scan risk gates must be Latin pen<=.01 and non-Latin p>=.90, pen<=.05")
    results = []
    for policy in policies:
        for setting in settings if policy == "few" or baseline_consensus else (False,):
            for threshold in LATIN_THRESHOLDS:
                parameters = replace(
                    base, policy=policy, latin_threshold=threshold,
                    latin_consensus=policy == "few" or baseline_consensus,
                    nonlatin_consensus=setting,
                )
                results.append(simulate(data, parameters))
    return {
        "report_version": REPORT_VERSION, "parameter_version": PARAMETER_VERSION,
        "scope": "dev_only", "created_at_utc": _utc_now(),
        "latin_thresholds": list(LATIN_THRESHOLDS), "results": results,
        "recommendation": recommend_configuration(results, stability_tolerance),
        "probe_failure_sensitivity": scan_probe_failure_sensitivity(data, results, stability_tolerance),
        "reconstruction_notes": dict(RECONSTRUCTION_NOTES),
    }


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _json_text(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n"


def _write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    # Also protect scan/validation artifacts from accidental overwrites.
    with path.open("x", encoding="utf-8") as handle:
        handle.write(_json_text(value))


def _flat_result(result: dict[str, Any]) -> dict[str, Any]:
    p, english, extra, proxy = result["parameters"], result["english"], result["extra_pk_accepted"], result["classroom_proxy"]
    flat = {
        "policy": p["policy"], "latin_threshold": p["latin_threshold"],
        "latin_consensus": p["latin_consensus"], "nonlatin_consensus": p["nonlatin_consensus"],
        "english_numerator": english["numerator"], "english_denominator": english["denominator"],
        "english_rate": english["rate"], "english_one_sided_95_upper": english["one_sided_95_upper"],
        "macro_coverage": result["macro_coverage"], "probe_count": result["probe_count"],
        "probe_seconds": result["probe_seconds"], "baseline_probe_count": result["baseline"]["probe_count"],
        "baseline_probe_seconds": result["baseline"]["probe_seconds"],
        "extra_pk_accepted_count": extra["probe_count"], "extra_pk_accepted_seconds": extra["probe_seconds"],
        "extra_probe_count_per_audio_hour": result["extra_probe_count_per_audio_hour"],
        "extra_probe_seconds_per_audio_hour": result["extra_probe_seconds_per_audio_hour"],
        "unlabeled_for_metrics": result["unlabeled_for_metrics"],
        "selected_probe_failures": result["selected_probe_failures"],
        "classroom_proxy_rows": proxy["row_count"], "classroom_proxy_english_numerator": proxy["english"]["numerator"],
        "classroom_proxy_english_denominator": proxy["english"]["denominator"],
        "classroom_proxy_probe_count": proxy["probe_count"], "classroom_proxy_probe_seconds": proxy["probe_seconds"],
        "classroom_proxy_chinese_switch_net_over_p0": proxy["chinese_switches"]["net_increase_over_p0"],
    }
    for prefix, metrics in (("", result), ("classroom_proxy_", proxy)):
        for code in metrics["languages"]:
            for field in ("numerator", "denominator", "coverage"):
                flat[f"{prefix}{code}_{field}"] = metrics["languages"][code][field]
    return flat


def _write_csv(path: Path, results: list[dict[str, Any]]) -> None:
    records = [_flat_result(result) for result in results]
    with path.open("x", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(dict.fromkeys(key for record in records for key in record)))
        writer.writeheader()
        writer.writerows(records)


def plot_scan(results: list[dict[str, Any]], path: Path) -> None:
    """Write a headless matplotlib PNG containing coverage, risk, and cost."""
    from matplotlib.backends.backend_agg import FigureCanvasAgg
    from matplotlib.figure import Figure
    from matplotlib.ticker import PercentFormatter

    figure = Figure(figsize=(15, 13), constrained_layout=True)
    FigureCanvasAgg(figure)
    axes = figure.subplots(4, 3).flatten()
    groups: dict[tuple[str, bool, bool], list[dict[str, Any]]] = {}
    for result in results:
        p = result["parameters"]
        groups.setdefault((p["policy"], p["latin_consensus"], p["nonlatin_consensus"]), []).append(result)
    for (policy, latin, nonlatin), series in sorted(groups.items()):
        series.sort(key=lambda item: item["parameters"]["latin_threshold"])
        x = [item["parameters"]["latin_threshold"] for item in series]
        label = f"{policy}: Latin={int(latin)}, nonLatin={int(nonlatin)}"
        def values(function: Any) -> list[float]:
            return [float("nan") if (value := function(item)) is None else value for item in series]
        for axis, code in zip(axes[:5], NON_ENGLISH):
            axis.plot(x, values(lambda item: item["languages"][code]["coverage"]), marker=".", label=label)
            axis.set_title(f"Trusted {code} coverage")
        axes[5].plot(x, values(lambda item: item["english"]["rate"]), marker=".", label=label)
        axes[6].plot(x, values(lambda item: item["english"]["one_sided_95_upper"]), marker=".", label=label)
        axes[7].plot(x, values(lambda item: item["extra_pk_accepted"]["probe_seconds"]), marker=".", label=label)
        axes[8].plot(x, values(lambda item: item["extra_probe_seconds_per_audio_hour"]), marker=".", label=label)
        axes[9].plot(x, values(lambda item: item["macro_coverage"]), marker=".", label=label)
        axes[10].plot(x, values(lambda item: item["extra_pk_accepted"]["probe_count"]), marker=".", label=label)
        axes[11].plot(x, values(lambda item: item["extra_probe_count_per_audio_hour"]), marker=".", label=label)
    titles = ("Trusted English false-switch rate", "English one-sided 95% upper bound", "Extra pk-accepted probe seconds", "Extra probe seconds / observed track hour")
    for axis, title in zip(axes[5:9], titles):
        axis.set_title(title)
    axes[9].set_title("Trusted non-English macro coverage")
    axes[10].set_title("Extra pk-accepted probe count")
    axes[11].set_title("Extra probe count / observed track hour")
    for i, axis in enumerate(axes):
        axis.set_xlabel("Latin probability threshold")
        axis.grid(alpha=0.25)
        if i < 5 or i == 9:
            axis.set_ylim(-0.02, 1.02)
            axis.yaxis.set_major_formatter(PercentFormatter(xmax=1))
        elif i in (5, 6):
            finite = [float(value) for line in axis.lines for value in line.get_ydata()
                      if math.isfinite(value)]
            maximum = max(finite, default=0.)
            axis.set_ylim(0, maximum * 1.15 if maximum > 0 else .001)
            axis.yaxis.set_major_formatter(PercentFormatter(xmax=1))
        elif i in (7, 8):
            axis.set_ylabel("seconds")
        else:
            axis.set_ylabel("probes")
    axes[0].legend(fontsize="small")
    figure.suptitle("Dev-only causal trigger sweep; proxy labels excluded from selection")
    with path.open("xb") as handle:
        figure.savefig(handle, format="png", dpi=140)


def _select_frozen_parameters(
    report: dict[str, Any], threshold: float | None, nonlatin: bool | None,
) -> tuple[Parameters, str]:
    if report.get("scope") != "dev_only" or report.get("parameter_version") != PARAMETER_VERSION or report.get("report_version") != REPORT_VERSION:
        raise InputError("freeze requires a compatible dev-only scan report")
    results = report.get("results")
    if not isinstance(results, list) or not results:
        raise InputError("scan report has no configurations")
    # Recompute the recommendation instead of accepting a hand-edited winner.
    tolerance = report.get("recommendation", {}).get("stability_tolerance", 0.05)
    recommendation = recommend_configuration(results, tolerance)
    explicit = threshold is not None or nonlatin is not None
    if threshold is None:
        if recommendation["status"] != "recommended":
            raise InputError("no_safe_plateau: supply an explicit reviewed --freeze-threshold")
        threshold = recommendation["parameters"]["latin_threshold"]
    if nonlatin is None:
        nonlatin = recommendation["parameters"]["nonlatin_consensus"] if recommendation["status"] == "recommended" else True
    matches = [
        item for item in results if item["parameters"]["policy"] == "few"
        and item["parameters"]["latin_threshold"] == threshold
        and item["parameters"]["nonlatin_consensus"] == nonlatin
    ]
    if len(matches) != 1:
        raise InputError("explicit freeze selection must match exactly one scanned few configuration")
    return _parameters(matches[0]["parameters"]), "explicit_reviewed_selection" if explicit else "dev_safe_plateau_rule"


def freeze(
    dev_paths: Iterable[str | Path], report: dict[str, Any], output: str | Path,
    *, threshold: float | None = None, nonlatin_consensus: bool | None = None,
    scan_report_sha256: str | None = None,
) -> dict[str, Any]:
    """Freeze exclusively after checking the exact dev evidence and selection."""
    parameters, selection = _select_frozen_parameters(report, threshold, nonlatin_consensus)
    data, inputs = read_jsonl(dev_paths, allowed_splits={"dev"})
    # Matching SHA/size/count binds this freeze to the data actually swept.
    if inputs != report.get("development_inputs"):
        raise InputError("dev inputs differ from the scan evidence; rescan before freezing")
    selected_result = simulate(data, parameters)
    matching = next(item for item in report["results"] if item["parameters"] == asdict(parameters) or _parameters(item["parameters"]) == parameters)
    if _flat_result(selected_result) != _flat_result(matching):
        raise InputError("selected dev results disagree with scan report")
    frozen = {
        "freeze_version": REPORT_VERSION, "parameter_version": PARAMETER_VERSION,
        "created_at_utc": _utc_now(), "parameters": asdict(parameters),
        "development_inputs": inputs, "selection": selection,
        "selection_metrics": {
            "english": selected_result["english"], "macro_coverage": selected_result["macro_coverage"],
            "macro_coverage_languages": selected_result["macro_coverage_languages"],
        },
        "scan_report_sha256": scan_report_sha256,
        "reconstruction_notes": dict(RECONSTRUCTION_NOTES),
    }
    _write_json(Path(output), frozen)
    return frozen


def _read_json(path: Path) -> tuple[dict[str, Any], str]:
    raw = path.read_bytes()
    try:
        value = json.loads(raw)
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise InputError("invalid JSON report/parameters file") from exc
    if not isinstance(value, dict):
        raise InputError("expected a JSON report/parameters object")
    return value, hashlib.sha256(raw).hexdigest()


def validate(
    rows: Iterable[Mapping[str, Any]], frozen: Mapping[str, Any],
) -> dict[str, Any]:
    """Apply frozen parameters to both holdout splits, without any selection."""
    if frozen.get("freeze_version") != REPORT_VERSION or frozen.get("parameter_version") != PARAMETER_VERSION:
        raise InputError("incompatible frozen parameter version")
    parameters = _parameters(frozen.get("parameters"))
    data = _check_rows(rows)
    if any(row["split"] not in {"original", "new"} for row in data):
        raise InputError("validation accepts only original/new splits")
    return {
        "report_version": REPORT_VERSION, "parameter_version": PARAMETER_VERSION,
        "scope": "holdout_validation_only", "created_at_utc": _utc_now(),
        "parameters": asdict(parameters),
        "splits": {
            split: {
                "status": "evaluated" if (subset := [row for row in data if row["split"] == split]) else "no_rows",
                "summary": simulate(subset, parameters),
                "probe_failure_sensitivity": probe_failure_sensitivity(subset, parameters),
            }
            for split in ("original", "new")
        },
        "reconstruction_notes": dict(RECONSTRUCTION_NOTES),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    sweep = commands.add_parser("scan", help="dev-only JSON/CSV/PNG sweep")
    sweep.add_argument("--input", nargs="+", required=True, type=Path)
    sweep.add_argument("--output-dir", required=True, type=Path)
    sweep.add_argument("--policies", nargs="+", choices=("P0", "P1", "few"), default=("P0", "P1", "few"))
    sweep.add_argument("--nonlatin-consensus", nargs="+", choices=("off", "on"), default=("off", "on"))
    sweep.add_argument("--baseline-consensus", action="store_true", help="enable Latin confirmation in P0/P1 (default disabled)")
    sweep.add_argument("--few-mean-threshold", type=float, default=0.90)
    sweep.add_argument("--few-min-threshold", type=float, default=0.05)
    sweep.add_argument("--stability-tolerance", type=float, default=0.05)
    sweep.add_argument("--candidate-limit", type=int, default=100)
    lock = commands.add_parser("freeze", help="create immutable-by-convention parameters with exclusive write")
    lock.add_argument("--input", nargs="+", required=True, type=Path, help="exact dev inputs used for scan")
    lock.add_argument("--scan-report", required=True, type=Path)
    lock.add_argument("--output", required=True, type=Path)
    lock.add_argument("--freeze-threshold", type=float)
    lock.add_argument("--freeze-nonlatin-consensus", choices=("off", "on"))
    check = commands.add_parser("validate", help="evaluate original/new with frozen parameters")
    check.add_argument("--input", nargs="+", required=True, type=Path)
    check.add_argument("--parameters", required=True, type=Path)
    check.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args(argv)
    try:
        if arguments.command == "scan":
            rows, evidence = read_jsonl(arguments.input, allowed_splits={"dev"})
            report = scan(
                rows, base=Parameters(
                    few_mean_threshold=arguments.few_mean_threshold, few_min_threshold=arguments.few_min_threshold,
                    failure_metadata_limit=arguments.candidate_limit,
                ), policies=arguments.policies,
                nonlatin_consensus=(value == "on" for value in arguments.nonlatin_consensus),
                baseline_consensus=arguments.baseline_consensus, stability_tolerance=arguments.stability_tolerance,
            )
            report["development_inputs"] = evidence
            directory = arguments.output_dir
            directory.mkdir(parents=True, exist_ok=True)
            for name in ("scan.json", "scan.csv", "curves.png"):
                if (directory / name).exists() or (directory / name).is_symlink():
                    raise InputError("scan output already exists; use a fresh output directory")
            # Plot first: a missing matplotlib does not leave a 'completed' report.
            plot_scan(report["results"], directory / "curves.png")
            _write_csv(directory / "scan.csv", report["results"])
            _write_json(directory / "scan.json", report)
            sensitivity = report["probe_failure_sensitivity"]
            print(_json_text({"scope": "dev_only", "configuration_count": len(report["results"]), "recommendation": report["recommendation"],
                              "probe_failures_in_input": sensitivity["probe_failures_in_input"],
                              "recommendation_changes_under_worst_case": sensitivity["recommendation_changes_under_worst_case"],
                              "output_dir": str(directory)}), end="")
        elif arguments.command == "freeze":
            report, digest = _read_json(arguments.scan_report)
            frozen = freeze(
                arguments.input, report, arguments.output, threshold=arguments.freeze_threshold,
                nonlatin_consensus=None if arguments.freeze_nonlatin_consensus is None else arguments.freeze_nonlatin_consensus == "on",
                scan_report_sha256=digest,
            )
            print(_json_text({"frozen_parameters": str(arguments.output), "parameters": frozen["parameters"], "selection": frozen["selection"]}), end="")
        else:
            frozen, digest = _read_json(arguments.parameters)
            rows, evidence = read_jsonl(arguments.input, allowed_splits={"original", "new"})
            report = validate(rows, frozen)
            report["validation_inputs"] = evidence
            report["frozen_parameters_sha256"] = digest
            _write_json(arguments.output, report)
            print(_json_text({"scope": report["scope"], "output": str(arguments.output), "splits": {key: {"status": value["status"], "row_count": value["summary"]["row_count"]} for key, value in report["splits"].items()}}), end="")
    except (InputError, OSError, ImportError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
