"""Turn/reference resampling for correlated calibration comparisons.

Five sources reuse one target reference. Resample complete turn clusters, never
individual comparisons. Independence between turns is an assumption; additional
dependence within meetings is not estimated by this small corpus.
"""
from __future__ import annotations

from collections import Counter
import math
import random
from typing import Sequence

from .metrics import _percentile

DEFAULT_RESAMPLES = 10000
DEFAULT_SEED = 0
KINDS = ("good", "echo", "wrong")


def validate_settings(resamples: int, seed: int) -> None:
    if type(resamples) is not int or resamples <= 0:
        raise ValueError("bootstrap resamples must be a positive integer")
    if type(seed) is not int:
        raise ValueError("bootstrap seed must be an integer")


def _mean_interval(values: Sequence[float], *, resamples: int, seed: int) -> dict:
    count = len(values)
    if not count:
        return {"mean_turn_rate": None, "turn_count": 0, "bootstrap_95_ci": None}
    mean = math.fsum(values) / count
    if min(values) == max(values):
        low = high = values[0]
    else:
        generator = random.Random(seed)
        sampled = sorted(math.fsum(values[generator.randrange(count)] for _ in range(count))
                         / count for _ in range(resamples))
        low, high = _percentile(sampled, .025), _percentile(sampled, .975)
    return {"mean_turn_rate": mean, "turn_count": count,
            "bootstrap_95_ci": {"low": low, "high": high}}


def summarize_clusters(records: Sequence[dict], *, resamples: int = DEFAULT_RESAMPLES,
                       seed: int = DEFAULT_SEED) -> dict:
    validate_settings(resamples, seed)
    targets = {row["targetLocale"] for row in records}
    if len(targets) > 1:
        raise ValueError("turn/reference clusters require exactly one target locale")
    grouped = {}
    for row in records:
        if (not isinstance(row["turn_id"], str) or not row["turn_id"].strip()
                or row["case_kind"] not in KINDS or type(row["accepted"]) is not bool):
            raise ValueError("invalid turn/reference cluster row")
        grouped.setdefault(row["turn_id"], []).append(row)
    per_turn, values = [], {kind: [] for kind in KINDS}
    affected = []
    for identity, rows in sorted(grouped.items()):
        counts = Counter(row["case_kind"] for row in rows)
        rejected = Counter(row["case_kind"] for row in rows if not row["accepted"])
        per_turn.append({"turn_id": identity,
                         "case_counts": {kind: counts[kind] for kind in KINDS},
                         "rejected_counts": {kind: rejected[kind] for kind in KINDS}})
        for kind in KINDS:
            if counts[kind]:
                values[kind].append(rejected[kind] / counts[kind])
        if counts["good"]:
            affected.append(float(rejected["good"] > 0))
    metrics = {name: _mean_interval(values[kind], resamples=resamples, seed=seed)
               for name, kind in (("false_rejection", "good"), ("echo_interception", "echo"),
                                  ("wrong_language_interception", "wrong"))}
    any_failure = _mean_interval(affected, resamples=resamples, seed=seed)
    any_failure.update({"numerator": int(sum(affected)), "denominator": len(affected)})
    return {
        "cluster_unit": "turn_id within one target locale; shared human reference",
        "turn_reference_count": len(grouped), "comparison_rows_are_independent": False,
        "weighting": "equal weight per turn; mean of within-turn comparison fractions",
        "bootstrap": {
            "method": "percentile bootstrap of whole turn/reference clusters with replacement",
            "resamples": resamples, "seed": seed, "confidence_level": .95,
            "order": "lexicographically sorted turn IDs; local Python random.Random(seed)",
            "quantile_method": "linear interpolation at (n - 1) * q",
            "limitations": "Conditional on observed turns, with fixed in-sample policy. All-equal outcomes give a degenerate interval, not a population guarantee. Between-turn independence is assumed; within-meeting correlation is unmodeled.",
        },
        **metrics, "any_false_rejection": any_failure,
        "best_case_zero_failures": {
            "turn_count": len(affected), "confidence_level_one_sided": .95,
            "upper_rate": -math.expm1(math.log(.05) / len(affected)) if affected else None,
            "formula": "1 - 0.05 ** (1 / number_of_turn_references)",
            "interpretation": "Hypothetical zero-failure exact binomial upper bound under IID turns; not an interval for observed nonzero failures or an in-sample accuracy guarantee.",
        },
        "per_turn": per_turn,
    }
