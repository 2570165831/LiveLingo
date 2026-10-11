"""Synthetic CPU tests only. Temporary artifacts honor the caller's TMPDIR.

Run: python3 -m unittest discover -s Scripts/trigger_eval -p test_simulate.py -v
No real classroom files, live services, or evaluation datasets are accessed.
"""

from __future__ import annotations

import copy
import csv
import hashlib
import io
import json
import math
import struct
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from dataclasses import asdict, replace
from pathlib import Path

import simulate as evaluator
from simulate import InputError, Parameters, clopper_pearson_upper, simulate


def row(index: int = 0, **changes):
    result = {
        "dataset": "synthetic", "split": "dev", "track": "track_a", "index": index,
        "start_s": index * 8.0, "end_s": (index + 1) * 8.0,
        "reference_language": "fr", "reference_trusted": True,
        "parakeet_accepted": False, "pk_mean_probability": 0.99,
        "pk_min_probability": 0.20, "pk_word_count": 8, "pk_words_per_second": 1.0,
        "nl_language": "fr", "nl_probability": 0.98,
        "probe_language": "fr", "probe_label_probability": 0.99,
        "probe_english_probability": 0.001, "probe_seconds": 0.25, "probe_error": False,
    }
    result.update(changes)
    return result


def baseline(policy="P1", **changes):
    return Parameters(policy=policy, latin_consensus=False, nonlatin_consensus=False, **changes)


def dev_rows():
    return [
        row(0, track="english", reference_language="en", probe_language="en", parakeet_accepted=True),
        row(1, track="english", reference_language="en", probe_language="en", parakeet_accepted=True),
        row(0, track="french", probe_label_probability=0.95),
        row(1, track="french", probe_label_probability=0.95, parakeet_accepted=True),
    ]


def write_rows(path, rows):
    path.write_text("".join(json.dumps(item) + "\n" for item in rows), encoding="utf-8")


class CausalSimulationTests(unittest.TestCase):
    def test_pending_first_segment_drives_followup_without_backfill(self):
        data = [
            row(0, probe_seconds=1),
            row(1, parakeet_accepted=True, probe_seconds=2),
            row(2, parakeet_accepted=True, probe_seconds=3),
            row(3, parakeet_accepted=True, probe_seconds=4, reference_language="en", probe_language="en"),
            row(4, parakeet_accepted=True, reference_language="zh", probe_language="zh"),
        ]
        before = copy.deepcopy(data)
        result = simulate(iter(data), Parameters())
        self.assertEqual(data, before)
        self.assertEqual(result["languages"]["fr"], {"numerator": 2, "denominator": 3, "coverage": 2 / 3})
        self.assertEqual(result["probe_count"], 4)
        self.assertEqual(result["probe_seconds"], 10)
        self.assertEqual(result["baseline"]["probe_count"], 1)
        self.assertEqual(result["baseline"]["probe_seconds"], 1)
        self.assertEqual(result["extra_pk_accepted"], {"probe_count": 3, "probe_seconds": 9})
        self.assertEqual(result["followup_only_probe_count"], 3)
        self.assertEqual(result["english"]["numerator"], 0)
        failures = {item["index"]: item for item in result["failure_candidates"]}
        self.assertEqual(failures[0]["reason"], "pending_consensus")
        self.assertEqual(failures[4]["reason"], "not_selected")

    def test_language_change_restarts_confirmation_but_continues_followup(self):
        result = simulate([
            row(0), row(1, reference_language="es", probe_language="es", parakeet_accepted=True),
            row(2, reference_language="es", probe_language="es", parakeet_accepted=True),
        ], Parameters())
        self.assertEqual(result["languages"]["fr"]["numerator"], 0)
        self.assertEqual(result["languages"]["es"]["numerator"], 1)
        self.assertEqual(result["followup_only_probe_count"], 2)

    def test_breaks_on_gap_dataset_channel_and_split(self):
        changes = ({"index": 2}, {"dataset": "other"}, {"track": "other"}, {"split": "new"})
        for change in changes:
            with self.subTest(change=change):
                second = row(1, parakeet_accepted=True)
                second.update(change)
                result = simulate([row(0), second], Parameters())
                self.assertEqual(result["probe_count"], 1)
                self.assertEqual(result["switch_count"], 0)

    def test_interleaved_channels_keep_independent_causal_context(self):
        result = simulate([
            row(0, track="a"), row(0, track="b", probe_language="es", reference_language="es"),
            row(1, track="a", parakeet_accepted=True),
            row(1, track="b", parakeet_accepted=True, probe_language="es", reference_language="es"),
        ], Parameters())
        self.assertEqual(result["languages"]["fr"]["numerator"], 1)
        self.assertEqual(result["languages"]["es"]["numerator"], 1)
        self.assertEqual(result["followup_only_probe_count"], 2)

    def test_english_failure_and_probability_gate_break_followup(self):
        for change in (
            {"probe_language": "en"}, {"probe_error": True}, {"probe_language": None},
            {"probe_label_probability": None}, {"probe_english_probability": None},
            {"probe_label_probability": 0.899}, {"probe_english_probability": 0.011},
        ):
            with self.subTest(change=change):
                result = simulate([
                    row(0), row(1, parakeet_accepted=True, **change),
                    row(2, parakeet_accepted=True),
                ], Parameters())
                self.assertEqual(result["probe_count"], 2)
                self.assertEqual(result["switch_count"], 0)
                self.assertEqual(result["decision_outcomes"]["not_selected"], 1)

    def test_failed_middle_segment_cannot_confirm_a_new_base_probe(self):
        result = simulate([row(0), row(1, probe_error=True), row(2)], Parameters())
        self.assertEqual(result["switch_count"], 0)
        self.assertEqual(result["selected_probe_failures"], 1)
        self.assertEqual(result["decision_outcomes"]["pending_consensus"], 2)

    def test_few_confidence_defaults_are_strict_or_with_missing_probabilities(self):
        data = [
            row(0, track="a", parakeet_accepted=True, pk_mean_probability=0.90, pk_min_probability=0.05),
            row(0, track="b", parakeet_accepted=True, pk_mean_probability=0.899999, pk_min_probability=0.20),
            row(0, track="c", parakeet_accepted=True, pk_mean_probability=None, pk_min_probability=0.049999),
            row(0, track="d", parakeet_accepted=True, pk_mean_probability=None, pk_min_probability=None),
            row(0, track="e", parakeet_accepted=True, pk_mean_probability=0.90, pk_min_probability=None),
            row(0, track="f", parakeet_accepted=True, pk_mean_probability=0.99, pk_min_probability=0.049999),
            row(0, track="g", parakeet_accepted=False),
        ]
        result = simulate(data, Parameters())
        self.assertEqual(result["probe_count"], 4)
        self.assertEqual(result["extra_pk_accepted"]["probe_count"], 3)
        self.assertEqual(result["input_quality"]["pk_mean_probability_none"], 2)
        self.assertEqual(result["input_quality"]["pk_min_probability_none"], 2)
        relaxed = simulate(data, Parameters(few_mean_threshold=0.95))
        self.assertEqual(relaxed["probe_count"], 6)

    def test_p0_and_p1_disable_consensus_independently_of_few(self):
        data = [row(0), row(1, parakeet_accepted=True), row(2, parakeet_accepted=True)]
        p0, p1, few = (simulate(data, p) for p in (baseline("P0"), baseline(), Parameters()))
        self.assertEqual(p0["switch_count"], 1)
        self.assertEqual(p0["probe_count"], 1)
        self.assertEqual(p1["switch_count"], 3)
        self.assertEqual(p1["extra_pk_accepted"]["probe_count"], 2)
        self.assertEqual(few["switch_count"], 2)
        with self.assertRaises(InputError):
            Parameters(latin_consensus=False)

    def test_nonlatin_confirmation_switch_and_probability_boundaries(self):
        for language in ("zh", "ar", "ru"):
            with self.subTest(language=language):
                data = [row(i, reference_language=language, probe_language=language,
                            probe_label_probability=0.90, probe_english_probability=0.05)
                        for i in range(2)]
                on = simulate(data, Parameters(nonlatin_consensus=True))
                off = simulate(data, Parameters(nonlatin_consensus=False))
                self.assertEqual(on["languages"][language]["numerator"], 1)
                self.assertEqual(off["languages"][language]["numerator"], 2)
                for change in ({"probe_label_probability": 0.899999}, {"probe_english_probability": 0.050001}):
                    blocked = simulate([row(0, reference_language=language, probe_language=language, **change)], Parameters(nonlatin_consensus=False))
                    self.assertEqual(blocked["switch_count"], 0)

    def test_latin_code_lookup_and_explicit_script_subtags(self):
        for language in ("fr", "es", "de", "pt", "az-Latn"):
            with self.subTest(language=language):
                result = simulate([row(0, probe_language=language, probe_label_probability=0.8),
                                   row(1, probe_language=language, probe_label_probability=0.8)],
                                  Parameters(latin_threshold=0.8))
                self.assertEqual(result["switch_count"], 1)
        for language in ("zh", "fr-Cyrl"):
            with self.subTest(language=language):
                result = simulate([row(0, probe_language=language, probe_label_probability=0.8)],
                                  Parameters(latin_threshold=0.8, nonlatin_consensus=False))
                self.assertEqual(result["switch_count"], 0)

    def test_nl_diagnostics_do_not_invent_an_additional_gate(self):
        result = simulate([row(0, nl_language=None, nl_probability=None),
                           row(1, nl_language="en", nl_probability=0.1)], Parameters())
        self.assertEqual(result["languages"]["fr"]["numerator"], 1)
        self.assertEqual(result["input_quality"]["nl_language_none"], 1)


class MetricAndPrivacyTests(unittest.TestCase):
    def test_only_trusted_non_null_labels_enter_denominators(self):
        data = [
            row(0, reference_language="en", probe_language="en"),
            row(1, reference_language=None, probe_language="zh"),
            row(2, reference_language="en", reference_trusted=False, probe_language="zh"),
            row(3, reference_language="fr"),
            row(4, reference_language="zh", reference_trusted=False, probe_language="zh"),
        ]
        result = simulate(data, baseline())
        self.assertEqual(result["english"]["numerator"], 0)
        self.assertEqual(result["english"]["denominator"], 1)
        self.assertAlmostEqual(result["english"]["one_sided_95_upper"], 0.95)
        self.assertEqual(result["languages"]["fr"]["numerator"], 1)
        self.assertEqual(result["languages"]["zh"]["denominator"], 0)
        self.assertEqual(result["unlabeled_for_metrics"], 3)
        self.assertEqual(result["input_quality"]["reference_language_none"], 1)
        self.assertEqual(result["unlabeled_switch_count"], 3)

    def test_null_reference_rows_maintain_causal_context(self):
        result = simulate([
            row(0, reference_language=None, reference_trusted=False),
            row(1, parakeet_accepted=True),
        ], Parameters())
        self.assertEqual(result["languages"]["fr"]["denominator"], 1)
        self.assertEqual(result["languages"]["fr"]["numerator"], 1)
        self.assertEqual(result["classroom_proxy"]["row_count"], 0)

    def test_pending_english_candidate_is_not_a_retroactive_false_switch(self):
        result = simulate([row(0, reference_language="en"), row(1, reference_language="en")], Parameters())
        self.assertEqual(result["english"]["numerator"], 1)
        self.assertEqual(result["english"]["denominator"], 2)
        self.assertEqual(result["english"]["probability_qualified_candidates"], 2)
        self.assertEqual(result["failure_candidates"][0]["index"], 1)

    def test_none_and_failed_probes_are_separate_from_english(self):
        data = [
            row(0, probe_error=True), row(1, probe_language=None),
            row(2, probe_label_probability=None), row(3, probe_english_probability=None),
            row(4, probe_language="en", reference_language="en"),
        ]
        result = simulate(data, baseline())
        self.assertEqual(result["selected_probe_failures"], 1)
        self.assertEqual(result["selected_probe_language_none"], 1)
        self.assertEqual(result["selected_probe_label_probability_none"], 1)
        self.assertEqual(result["selected_probe_english_probability_none"], 1)
        self.assertEqual(result["decision_outcomes"]["probe_english"], 1)
        self.assertEqual(result["english"]["denominator"], 1)
        self.assertEqual(result["switch_count"], 0)

    def test_track_hour_cost_uses_interval_union_and_no_unobserved_gaps(self):
        data = [
            row(0, start_s=0, end_s=10, probe_seconds=2),
            row(1, start_s=5, end_s=15, probe_seconds=3, parakeet_accepted=True),
            row(4, start_s=100, end_s=110, probe_seconds=1, parakeet_accepted=True),
        ]
        result = simulate(data, baseline())
        track = result["per_track"][0]
        self.assertEqual(track["audio_seconds"], 25)
        self.assertEqual(result["probe_count"], 3)
        self.assertEqual(result["probe_seconds"], 6)
        self.assertEqual(result["baseline"]["probe_seconds"], 2)
        self.assertEqual(result["extra_pk_accepted"], {"probe_count": 2, "probe_seconds": 4})
        self.assertAlmostEqual(track["extra_probe_count_per_audio_hour"], 288)
        self.assertAlmostEqual(track["extra_probe_seconds_per_audio_hour"], 576)

    def test_zero_duration_and_no_english_samples_do_not_report_zero_risk(self):
        result = simulate([row(0, start_s=0, end_s=0)], baseline())
        self.assertIsNone(result["extra_probe_seconds_per_audio_hour"])
        self.assertIsNone(result["english"]["rate"])
        self.assertIsNone(result["english"]["one_sided_95_upper"])
        empty = simulate([], Parameters())
        self.assertEqual(empty["row_count"], 0)
        self.assertIsNone(empty["macro_coverage"])

    def test_private_candidates_suppressed_and_public_candidates_bounded(self):
        data = [row(0, track="private", private_classroom=True),
                row(0, track="public_a"), row(0, track="public_b")]
        result = simulate(data, Parameters(failure_metadata_limit=1))
        self.assertEqual(result["failure_candidate_count"], 3)
        self.assertEqual(result["private_candidate_metadata_suppressed"], 1)
        self.assertEqual(result["failure_candidate_metadata_truncated"], 1)
        self.assertEqual(len(result["failure_candidates"]), 1)
        self.assertEqual(result["failure_candidates"][0]["track"], "public_a")
        self.assertEqual(result["languages"]["fr"]["denominator"], 3)

    def test_classroom_proxy_is_separate_and_chinese_net_is_measured_against_p0(self):
        data = [row(i, reference_language="zh" if i < 3 else ("en" if i == 3 else None),
                    reference_trusted=False, reference_kind="model_proxy", private_classroom=True,
                    probe_language="zh", parakeet_accepted=i > 0) for i in range(5)]
        result = simulate(data, Parameters(nonlatin_consensus=False))
        proxy = result["classroom_proxy"]
        self.assertEqual(result["english"]["denominator"], 0)
        self.assertIsNone(result["macro_coverage"])
        self.assertEqual(proxy["row_count"], 5)
        self.assertEqual(proxy["languages"]["zh"], {"numerator": 3, "denominator": 3, "coverage": 1.0})
        self.assertEqual(proxy["english"]["numerator"], 1)
        self.assertEqual(proxy["english"]["denominator"], 1)
        self.assertEqual(proxy["unlabeled_for_metrics"], 1)
        self.assertEqual(proxy["probe_count"], 5)
        self.assertEqual(proxy["probe_seconds"], 1.25)
        self.assertEqual(proxy["p0_baseline"]["probe_count"], 1)
        self.assertEqual(proxy["chinese_switches"], {"simulated": 5, "p0": 1, "net_increase_over_p0": 4})
        self.assertEqual(proxy["chinese_proxy_coverage_net_increase_over_p0"], 2)
        self.assertEqual(result["failure_candidates"], [])
        self.assertEqual(result["private_candidate_metadata_suppressed"], 5)
        report = evaluator.scan(data, policies=("few",))
        self.assertEqual(report["recommendation"]["status"], "no_safe_plateau")

    def test_model_proxy_cannot_enter_hard_metrics_even_if_mistagged_trusted(self):
        result = simulate([row(0, reference_language="en", reference_kind="model_proxy",
                               reference_trusted=True, private_classroom=True)], baseline())
        self.assertEqual(result["english"]["denominator"], 0)
        self.assertEqual(result["classroom_proxy"]["english"]["numerator"], 1)
        self.assertEqual(result["input_quality"]["model_proxy_marked_trusted"], 1)

    def test_proxy_chinese_p0_comparison_disables_baseline_consensus(self):
        data = [row(0, reference_language="zh", probe_language="zh", private_classroom=True,
                    reference_kind="model_proxy", reference_trusted=False),
                row(1, reference_language="zh", probe_language="zh", private_classroom=True,
                    reference_kind="model_proxy", reference_trusted=False, parakeet_accepted=True)]
        proxy = simulate(data, Parameters())["classroom_proxy"]
        self.assertEqual(proxy["chinese_switches"], {"simulated": 1, "p0": 1, "net_increase_over_p0": 0})
        self.assertFalse(proxy["p0_baseline_parameters"]["nonlatin_consensus"])


class BinomialBoundTests(unittest.TestCase):
    def test_zero_error_closed_form(self):
        for n in (1, 2, 10, 1000, 1000000000):
            with self.subTest(n=n):
                self.assertAlmostEqual(clopper_pearson_upper(0, n), 1 - 0.05 ** (1 / n), places=14)

    def test_nonzero_upper_bound_inverts_binomial_cdf(self):
        for k, n in ((1, 2), (1, 10), (3, 20), (25, 50), (80, 100), (98, 100)):
            with self.subTest(k=k, n=n):
                p = clopper_pearson_upper(k, n)
                cdf = sum(math.comb(n, i) * p ** i * (1 - p) ** (n - i) for i in range(k + 1))
                self.assertAlmostEqual(cdf, 0.05, places=11)
                self.assertGreater(p, k / n)

    def test_endpoints_and_monotonicity(self):
        self.assertIsNone(clopper_pearson_upper(0, 0))
        self.assertEqual(clopper_pearson_upper(10, 10), 1.0)
        bounds = [clopper_pearson_upper(k, 100) for k in range(101)]
        self.assertEqual(sorted(bounds), bounds)
        self.assertGreater(clopper_pearson_upper(1, 100000), clopper_pearson_upper(0, 100000))
        self.assertLess(clopper_pearson_upper(20, 100000), 0.001)

    def test_invalid_counts_and_confidence(self):
        for args in ((-1, 10), (11, 10), (0, -1), (True, 10), (0, 1.5), (0, 1, 1), (0, 1, 0)):
            with self.subTest(args=args), self.assertRaises(InputError):
                clopper_pearson_upper(*args)


def recommendation_point(threshold, macro, errors=0, n=100, nonlatin=True):
    return {"parameters": asdict(Parameters(latin_threshold=threshold, nonlatin_consensus=nonlatin)),
            "english": {"numerator": errors, "denominator": n}, "macro_coverage": macro}


class SweepRecommendationTests(unittest.TestCase):
    def test_fixed_scan_grid_and_baseline_consensus(self):
        report = evaluator.scan(dev_rows())
        self.assertEqual(report["latin_thresholds"], [0.5, 0.55, 0.6, 0.65, 0.7, 0.75, 0.8, 0.85, 0.9, 0.95, 0.97])
        self.assertEqual(len(report["results"]), 44)
        for result in report["results"]:
            p = result["parameters"]
            self.assertEqual(p["latin_english_max"], 0.01)
            self.assertEqual(p["nonlatin_threshold"], 0.90)
            self.assertEqual(p["nonlatin_english_max"], 0.05)
            self.assertEqual(p["few_mean_threshold"], 0.90)
            self.assertEqual(p["few_min_threshold"], 0.05)
            self.assertEqual(p["latin_consensus"], p["policy"] == "few")
        self.assertEqual(report["recommendation"]["parameters"]["latin_threshold"], 0.95)

    def test_highest_threshold_on_stable_maximum(self):
        points = [recommendation_point(t, 0.8) for t in (0.5, 0.55, 0.9, 0.95, 0.97)]
        recommendation = evaluator.recommend_configuration(points)
        self.assertEqual(recommendation["status"], "recommended")
        self.assertEqual(recommendation["parameters"]["latin_threshold"], 0.97)
        self.assertEqual(recommendation["lower_neighbor_threshold"], 0.95)

    def test_no_invented_recommendation_for_boundary_or_isolated_optimum(self):
        cases = (
            [recommendation_point(0.5, 0.9)],
            [recommendation_point(0.5, 0.9), recommendation_point(0.55, 0.84)],
            [recommendation_point(0.85, 0.8, errors=1), recommendation_point(0.9, 0.8)],
            [recommendation_point(0.85, 0.8), recommendation_point(0.9, 0.85)],
            [recommendation_point(0.85, 0.8, n=0), recommendation_point(0.9, 0.8, n=0)],
        )
        for points in cases:
            with self.subTest(points=points):
                self.assertEqual(evaluator.recommend_configuration(points)["status"], "no_safe_plateau")

    def test_coverage_is_maximized_within_stable_safe_set(self):
        points = [recommendation_point(0.5, 0.95, nonlatin=False),
                  recommendation_point(0.55, 0.8, nonlatin=False),
                  recommendation_point(0.9, 0.9), recommendation_point(0.95, 0.9)]
        recommendation = evaluator.recommend_configuration(points)
        self.assertEqual(recommendation["status"], "recommended")
        self.assertEqual(recommendation["parameters"]["latin_threshold"], .95)
        self.assertAlmostEqual(recommendation["coverage_loss_for_stability"], .05)

    def test_near_boundary_coverage_can_be_safely_traded_for_stability(self):
        points = [recommendation_point(.50, .90), recommendation_point(.55, .89)]
        recommendation = evaluator.recommend_configuration(points)
        self.assertEqual(recommendation["parameters"]["latin_threshold"], .55)
        self.assertAlmostEqual(recommendation["coverage_loss_for_stability"], .01)

    def test_single_language_cliff_is_not_hidden_by_macro_average(self):
        points = [recommendation_point(.50, .80), recommendation_point(.55, .79)]
        points[0]["languages"] = {"fr": {"coverage": .9}}
        points[1]["languages"] = {"fr": {"coverage": .8}}
        self.assertEqual(evaluator.recommend_configuration(points)["status"], "no_safe_plateau")

    def test_consensus_on_wins_only_when_coverage_and_threshold_tie(self):
        points = [recommendation_point(t, 0.8, nonlatin=setting)
                  for setting in (False, True) for t in (0.90, 0.95)]
        self.assertTrue(evaluator.recommend_configuration(points)["parameters"]["nonlatin_consensus"])

    def test_scan_rejects_holdouts_and_changed_fixed_risk_gates(self):
        for split in ("original", "new"):
            with self.subTest(split=split), self.assertRaises(InputError):
                evaluator.scan([row(0), row(1, split=split)])
        with self.assertRaises(InputError):
            evaluator.scan(dev_rows(), base=Parameters(nonlatin_threshold=0.8))


class SchemaTests(unittest.TestCase):
    def test_duplicate_or_decreasing_indices_rejected_instead_of_sorted(self):
        for data in ([row(0), row(0)], [row(1), row(0)]):
            with self.assertRaises(InputError):
                simulate(data, Parameters())

    def test_invalid_schema_and_text_fields_are_rejected_without_payload_echo(self):
        for change in (
            {"probe_label_probability": float("nan")}, {"probe_seconds": -1},
            {"reference_trusted": 1}, {"pk_word_count": True}, {"split": []},
            {"end_s": -1}, {"reference_language": "not a code"}, {"probe_language": "not a code"},
            {"private_classroom": "true"}, {"transcript": "synthetic_payload_trap"},
        ):
            with self.subTest(fields=list(change)), self.assertRaises(InputError) as caught:
                simulate([row(0, **change)], Parameters())
            self.assertNotIn("synthetic_payload_trap", str(caught.exception))

    def test_parameter_mapping_and_no_unknown_fields(self):
        self.assertEqual(simulate([row(0)], asdict(baseline()))["switch_count"], 1)
        for parameters in ({"policy": "unknown"}, {"anything": True}, {"latin_threshold": float("inf")}, {"policy": []}):
            with self.subTest(parameters=parameters), self.assertRaises(InputError):
                simulate([], parameters)

    def test_all_collector_optional_fields_and_long_reference_kinds(self):
        fields = {
            "schema": 1, "boundary_reason": "quiet_tail", "parakeet_seconds": 0.5,
            "parakeet_error": False, "pk_emitted_tokens": 12, "pk_mean_log_probability": -0.1,
            "pk_min_log_probability": None, "pk_char_count": 24, "english_gate_accepted": True,
            "quality_reason": None, "nl_english_probability": 0.001,
            "slice_audio_sha256": "aB" * 32, "floor_interp_waveform_cosine": -1.0,
        }
        for kind in ("english_interpretation_track_assumption", "official_nonenglish_waveform_passthrough",
                     "bracketed_official_word_anchors", "a" * 64):
            with self.subTest(kind=kind):
                result = simulate([row(0, reference_kind=kind, **fields)], baseline())
                self.assertEqual(result["switch_count"], 1)
        for reason in (*evaluator.QUALITY_REASONS, None):
            simulate([row(0, quality_reason=reason)], baseline())
        for reason in evaluator.BOUNDARY_REASONS:
            simulate([row(0, boundary_reason=reason)], baseline())

    def test_collector_optional_types_and_bounds_are_not_silently_coerced(self):
        changes = (
            {"schema": True}, {"schema": 2}, {"boundary_reason": "anything"},
            {"quality_reason": "synthetic_payload_trap"}, {"quality_reason": []},
            {"parakeet_seconds": -0.1}, {"parakeet_error": 0}, {"pk_emitted_tokens": "tokens"},
            {"pk_char_count": -1}, {"english_gate_accepted": None},
            {"pk_mean_log_probability": 0.1}, {"pk_min_log_probability": float("-inf")},
            {"nl_english_probability": 1.01}, {"slice_audio_sha256": "f" * 63},
            {"floor_interp_waveform_cosine": 1.01}, {"reference_kind": "a" * 65},
            {"tokens": "synthetic_payload_trap"}, {"text": "synthetic_payload_trap"},
        )
        for change in changes:
            with self.subTest(fields=list(change)), self.assertRaises(InputError) as caught:
                simulate([row(0, **change)], baseline())
            self.assertNotIn("synthetic_payload_trap", str(caught.exception))

    def test_proxy_language_coverage_is_dynamic_but_hard_metrics_remain_six(self):
        data = [row(0, reference_language="yue", probe_language="yue", private_classroom=True,
                    reference_kind="model_proxy", reference_trusted=False),
                row(1, reference_language="yue-Hant", probe_language="yue-Hant", private_classroom=True,
                    reference_kind="model_proxy", reference_trusted=False, parakeet_accepted=True),
                row(0, track="other", reference_language="de", probe_language="de", reference_trusted=True)]
        result = simulate(data, Parameters(nonlatin_consensus=False))
        self.assertEqual(result["classroom_proxy"]["languages"]["yue"], {"numerator": 2, "denominator": 2, "coverage": 1.0})
        self.assertEqual(result["classroom_proxy"]["reference_language_denominators"]["yue"], 2)
        self.assertEqual(set(result["reference_language_denominators"]), set(evaluator.LANGUAGES))
        self.assertIsNone(result["macro_coverage"])
        self.assertEqual(result["input_quality"]["reference_outside_hard_language_set"], 3)
        flat = evaluator._flat_result(result)
        self.assertEqual(flat["classroom_proxy_yue_denominator"], 2)
        self.assertEqual(flat["classroom_proxy_yue_coverage"], 1.0)

    def test_segmentation_difference_matches_collector_reconstruction(self):
        note = simulate([], Parameters())["reconstruction_notes"]["segmentation"]
        self.assertEqual(note, "6s开始静音尾搜索，8s最大，250ms能量帧，500ms静音，-35dBFS；不等同App preview")


class FileAndCliTests(unittest.TestCase):
    def setUp(self):
        self.sandbox = tempfile.TemporaryDirectory(prefix="trigger-eval-test-")
        self.addCleanup(self.sandbox.cleanup)
        self.directory = Path(self.sandbox.name)
        self.dev_path = self.directory / "dev.jsonl"
        write_rows(self.dev_path, dev_rows())

    def scan_report(self, rows=None):
        if rows is not None:
            write_rows(self.dev_path, rows)
        data, evidence = evaluator.read_jsonl([self.dev_path], allowed_splits={"dev"})
        report = evaluator.scan(data, policies=("few",))
        report["development_inputs"] = evidence
        return report

    def invoke(self, arguments):
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            status = evaluator.main([str(item) for item in arguments])
        return status, stdout.getvalue(), stderr.getvalue()

    def test_input_evidence_hashes_exact_bytes_and_checks_splits(self):
        data, evidence = evaluator.read_jsonl([self.dev_path], allowed_splits={"dev"})
        self.assertEqual(len(data), 4)
        self.assertEqual(evidence[0]["sha256"], hashlib.sha256(self.dev_path.read_bytes()).hexdigest())
        self.assertEqual(evidence[0]["row_count"], 4)
        with self.assertRaises(InputError):
            evaluator.read_jsonl([self.dev_path, self.dev_path], allowed_splits={"dev"})
        holdout = self.directory / "holdout.jsonl"
        write_rows(holdout, [row(0, split="original")])
        with self.assertRaises(InputError):
            evaluator.read_jsonl([self.dev_path, holdout], allowed_splits={"dev"})

    def test_freeze_exclusive_and_binds_dev_evidence(self):
        report = self.scan_report()
        path = self.directory / "parameters.json"
        frozen = evaluator.freeze([self.dev_path], report, path)
        self.assertEqual(frozen["parameters"]["latin_threshold"], 0.95)
        self.assertEqual(frozen["parameter_version"], evaluator.PARAMETER_VERSION)
        self.assertTrue(frozen["created_at_utc"].endswith("Z"))
        self.assertEqual(frozen["development_inputs"], report["development_inputs"])
        content = path.read_bytes()
        with self.assertRaises(FileExistsError):
            evaluator.freeze([self.dev_path], report, path)
        self.assertEqual(path.read_bytes(), content)
        self.dev_path.write_bytes(self.dev_path.read_bytes() + b"\n")
        with self.assertRaises(InputError):
            evaluator.freeze([self.dev_path], report, self.directory / "other.json")

    def test_explicit_freeze_allowed_when_rule_honestly_returns_no_safe_plateau(self):
        report = self.scan_report([row(0)])
        path = self.directory / "parameters.json"
        self.assertEqual(report["recommendation"]["status"], "no_safe_plateau")
        with self.assertRaises(InputError):
            evaluator.freeze([self.dev_path], report, path)
        self.assertFalse(path.exists())
        frozen = evaluator.freeze([self.dev_path], report, path, threshold=0.90, nonlatin_consensus=False)
        self.assertEqual(frozen["selection"], "explicit_reviewed_selection")
        self.assertFalse(frozen["parameters"]["nonlatin_consensus"])
        with self.assertRaises(InputError):
            evaluator.freeze([self.dev_path], report, self.directory / "bad.json", threshold=0.92)

    def test_changed_report_metrics_are_not_freezable(self):
        report = self.scan_report()
        for result in report["results"]:
            result["probe_count"] += 1
        with self.assertRaises(InputError):
            evaluator.freeze([self.dev_path], report, self.directory / "parameters.json")

    def test_validation_split_contexts_are_isolated_and_absent_split_is_explicit(self):
        frozen = evaluator.freeze([self.dev_path], self.scan_report(), self.directory / "parameters.json")
        result = evaluator.validate([row(0, split="original"), row(1, split="new")], frozen)
        for split in ("original", "new"):
            self.assertEqual(result["splits"][split]["summary"]["switch_count"], 0)
        missing = evaluator.validate([row(0, split="original")], frozen)
        self.assertEqual(missing["splits"]["new"]["status"], "no_rows")
        self.assertIsNone(missing["splits"]["new"]["summary"]["english"]["one_sided_95_upper"])
        with self.assertRaises(InputError):
            evaluator.validate([row(0)], frozen)
        with self.assertRaises(InputError):
            evaluator.validate([], {**frozen, "parameter_version": "old"})

    def test_full_cli_writes_json_csv_png_and_validation_cannot_modify_freeze(self):
        output_dir = self.directory / "sweep"
        status, _, errors = self.invoke(["scan", "--input", self.dev_path, "--output-dir", output_dir])
        self.assertEqual(status, 0, errors)
        report = json.loads((output_dir / "scan.json").read_text())
        self.assertEqual(report["scope"], "dev_only")
        with (output_dir / "scan.csv").open(newline="") as handle:
            csv_rows = list(csv.DictReader(handle))
        self.assertEqual(len(csv_rows), 44)
        self.assertIn("classroom_proxy_zh_coverage", csv_rows[0])
        png = (output_dir / "curves.png").read_bytes()
        self.assertEqual(png[:8], b"\x89PNG\r\n\x1a\n")
        width, height = struct.unpack(">II", png[16:24])
        self.assertGreater(width, 1000)
        self.assertGreater(height, 1000)
        frozen_path = self.directory / "parameters.json"
        status, _, errors = self.invoke(["freeze", "--input", self.dev_path, "--scan-report", output_dir / "scan.json", "--output", frozen_path,
                                         "--freeze-threshold", "0.90", "--freeze-nonlatin-consensus", "on"])
        self.assertEqual(status, 0, errors)
        before = frozen_path.read_bytes()
        frozen = json.loads(before)
        self.assertEqual(frozen["scan_report_sha256"], hashlib.sha256((output_dir / "scan.json").read_bytes()).hexdigest())
        holdout = self.directory / "holdouts.jsonl"
        write_rows(holdout, [row(0, split="original"), row(1, split="original"),
                             row(0, split="new", reference_language="en"), row(1, split="new", reference_language="en")])
        validation = self.directory / "validation.json"
        status, stdout, errors = self.invoke(["validate", "--input", holdout, "--parameters", frozen_path, "--output", validation])
        self.assertEqual(status, 0, errors)
        self.assertEqual(frozen_path.read_bytes(), before)
        result = json.loads(validation.read_text())
        self.assertEqual(result["splits"]["original"]["summary"]["languages"]["fr"]["numerator"], 1)
        self.assertEqual(result["splits"]["new"]["summary"]["english"]["numerator"], 1)
        self.assertNotIn("recommendation", result)
        self.assertEqual(result["parameters"], frozen["parameters"])
        self.assertEqual(json.loads(stdout)["scope"], "holdout_validation_only")

    def test_cli_rejects_mixed_dev_file_without_creating_output(self):
        write_rows(self.dev_path, [row(0), row(1, split="new")])
        output_dir = self.directory / "bad-sweep"
        status, _, errors = self.invoke(["scan", "--input", self.dev_path, "--output-dir", output_dir])
        self.assertEqual(status, 2)
        self.assertIn("disallowed split", errors)
        self.assertFalse(output_dir.exists())

    def test_json_errors_never_echo_payload_and_outputs_are_not_overwritten(self):
        self.dev_path.write_text('{"synthetic_payload_trap": invalid}\n')
        status, stdout, errors = self.invoke(["scan", "--input", self.dev_path, "--output-dir", self.directory / "bad"])
        self.assertEqual(status, 2)
        self.assertEqual(stdout, "")
        self.assertNotIn("synthetic_payload_trap", errors)
        report = self.scan_report(dev_rows())
        frozen = self.directory / "parameters.json"
        evaluator.freeze([self.dev_path], report, frozen)
        write_rows(self.dev_path, [row(0, split="original")])
        status, _, errors = self.invoke(["validate", "--input", self.dev_path, "--parameters", frozen, "--output", frozen])
        self.assertEqual(status, 2)
        self.assertEqual(json.loads(frozen.read_text())["parameter_version"], evaluator.PARAMETER_VERSION)


FAILED_PROBE = {"probe_error": True, "probe_language": None,
                "probe_label_probability": None, "probe_english_probability": None}


def receipt_file(segments, probe=0, parakeet=0, track="t"):
    return {"dataset": "d", "track": track, "segments": segments,
            "probe_failures": probe, "parakeet_failures": parakeet}


class ProbeFailureAcceptanceTests(unittest.TestCase):
    """2026-10-09 rule: deterministic probe failures are counted as no switch."""

    def test_gate_allows_counted_failures_up_to_exactly_one_percent_per_track(self):
        gate = evaluator.collection_failure_gate([receipt_file(800, 8), receipt_file(1272, 0, track="u")])
        self.assertEqual((gate["probe_failures"], gate["segments"]), (8, 2072))
        with self.assertRaisesRegex(InputError, "track_probe_failure_rate_exceeds_limit"):
            evaluator.collection_failure_gate([receipt_file(800, 9), receipt_file(5000, 0, track="u")])

    def test_gate_stops_on_any_parakeet_failure(self):
        with self.assertRaisesRegex(InputError, "parakeet_failures_present"):
            evaluator.collection_failure_gate([receipt_file(800, 0, parakeet=1)])

    def test_gate_corpus_limit_is_checked_separately(self):
        evaluator.collection_failure_gate([receipt_file(100, 2)], track_limit=1.0)
        evaluator.collection_failure_gate([receipt_file(100, 2), receipt_file(100, 1, track="u")], track_limit=1.0)
        with self.assertRaisesRegex(InputError, "corpus_probe_failure_rate_exceeds_limit"):
            evaluator.collection_failure_gate([receipt_file(100, 3), receipt_file(100, 2, track="u")], track_limit=1.0)

    def test_gate_rejects_malformed_or_empty_receipts(self):
        for files in ([], [receipt_file(0)], [receipt_file(10, 11)], [receipt_file(10, True)],
                      [{"segments": 10, "probe_failures": 0}], [receipt_file(10, -1)]):
            with self.assertRaises(InputError):
                evaluator.collection_failure_gate(files)

    def test_selected_failed_english_probe_is_no_switch_but_counts_in_worst_case(self):
        rows = [row(0, reference_language="en", **FAILED_PROBE)]
        self.assertEqual(simulate(rows)["english"]["numerator"], 0)
        bound = evaluator.probe_failure_sensitivity(rows, Parameters())
        self.assertEqual(bound["no_switch"]["english"]["numerator"], 0)
        self.assertEqual(bound["worst_case"]["english"]["numerator"], 1)
        self.assertEqual(bound["selected_probe_failures_by_reference"], {"english": 1, "non_english": 0, "unlabeled": 0})

    def test_unselected_failed_probe_cannot_affect_either_bound(self):
        rows = [row(0, reference_language="en", parakeet_accepted=True, **FAILED_PROBE)]
        bound = evaluator.probe_failure_sensitivity(rows, Parameters())
        self.assertEqual(bound["selected_probe_failures"], 0)
        self.assertEqual(bound["worst_case"]["english"]["numerator"], 0)

    def test_worst_case_failure_acts_as_wildcard_for_followup_confirmation(self):
        rows = [row(0, reference_language="en", **FAILED_PROBE),
                row(1, reference_language="en", parakeet_accepted=True)]
        self.assertEqual(simulate(rows)["english"]["numerator"], 0)
        worst = simulate(rows, probe_failure_mode="worst_case")
        self.assertEqual(worst["english"]["numerator"], 2)
        self.assertEqual(worst["decision_outcomes"]["probe_failed_worst_case_switch"], 1)
        self.assertEqual(evaluator.probe_failure_sensitivity(rows, Parameters())["worst_case"]["english"]["numerator"], 2)

    def test_worst_case_never_credits_coverage_and_counts_failed_non_english_as_miss(self):
        rows = [row(0, **FAILED_PROBE), row(1, parakeet_accepted=True)]
        worst = simulate(rows, probe_failure_mode="worst_case")
        self.assertEqual(worst["languages"]["fr"]["numerator"], 1)  # wildcard confirmation
        self.assertEqual(worst["wrong_nonenglish_switch_count"], 0)
        self.assertEqual(worst["failure_candidates"][0]["failure"], "missed_coverage")
        bound = evaluator.probe_failure_sensitivity(rows, Parameters())
        self.assertEqual(bound["no_switch"]["languages"]["fr"]["numerator"], 0)
        self.assertEqual(bound["worst_case"]["languages"]["fr"]["numerator"], 0)

    def test_worst_case_bound_is_never_below_no_switch(self):
        rows = [row(i, reference_language="en" if i % 3 else "fr", **(FAILED_PROBE if i % 4 == 1 else {}))
                for i in range(12)]
        for policy in ("P0", "P1", "few"):
            parameters = Parameters(policy=policy) if policy == "few" else baseline(policy)
            bound = evaluator.probe_failure_sensitivity(rows, parameters)
            self.assertGreaterEqual(bound["worst_case"]["english"]["numerator"], bound["no_switch"]["english"]["numerator"])
            for code, metrics in bound["worst_case"]["languages"].items():
                self.assertLessEqual(metrics["numerator"], bound["no_switch"]["languages"][code]["numerator"])

    def test_invalid_probe_failure_mode_is_rejected(self):
        with self.assertRaises(InputError):
            simulate([row(0)], probe_failure_mode="ignore")

    def test_scan_says_when_worst_case_changes_the_recommendation(self):
        english_failure = dev_rows() + [row(2, track="english", reference_language="en", **FAILED_PROBE)]
        report = evaluator.scan(english_failure, policies=("few",))
        sensitivity = report["probe_failure_sensitivity"]
        self.assertEqual(report["recommendation"]["status"], "recommended")
        self.assertEqual(sensitivity["worst_case_recommendation"]["status"], "no_safe_plateau")
        self.assertTrue(sensitivity["recommendation_changes_under_worst_case"])
        self.assertEqual(sensitivity["recommended_configuration_bound"]["worst_case"]["english"]["numerator"], 1)
        french_failure = dev_rows() + [row(2, track="french", **FAILED_PROBE)]
        sensitivity = evaluator.scan(french_failure, policies=("few",))["probe_failure_sensitivity"]
        self.assertFalse(sensitivity["recommendation_changes_under_worst_case"])
        self.assertEqual(sensitivity["probe_failures_in_input"], 1)

    def test_validation_reports_sensitivity_for_each_holdout(self):
        data = [row(0, split="original", reference_language="en", **FAILED_PROBE), row(0, split="new")]
        frozen = {"freeze_version": evaluator.REPORT_VERSION, "parameter_version": evaluator.PARAMETER_VERSION,
                  "parameters": asdict(Parameters())}
        result = evaluator.validate(data, frozen)
        original = result["splits"]["original"]["probe_failure_sensitivity"]
        self.assertEqual(original, evaluator.probe_failure_sensitivity(data[:1], Parameters()))
        self.assertEqual(original["worst_case"]["english"]["numerator"], 1)
        self.assertEqual(result["splits"]["new"]["probe_failure_sensitivity"]["probe_failures_in_input"], 0)

    def classification(self, rows, **changes):
        entries = [{"dataset": r["dataset"], "track": r["track"], "index": r["index"],
                    "slice_audio_sha256": r["slice_audio_sha256"], "same_slice_as_collection": True,
                    "error_class": "Unparsed language head",
                    "attempts": ["Unparsed language head", "Unparsed language head"], "deterministic": True}
                   for r in rows if r["probe_error"]]
        for entry in entries:
            entry.update(changes)
        return {"schema": 1, "split": "dev", "failures": entries}

    def test_classification_accepts_only_deterministic_known_failures_on_same_slice(self):
        rows = [row(i, slice_audio_sha256=f"{i:064x}", **(FAILED_PROBE if i in (1, 3) else {})) for i in range(5)]
        summary = evaluator.check_probe_failure_classification(rows, self.classification(rows), split="dev")
        self.assertEqual(summary["by_class"], {"Unparsed language head": 2})
        bad = [
            ({"attempts": ["Unparsed language head", "succeeded"]}, "not_deterministic"),
            ({"attempts": ["Unparsed language head"]}, "not_deterministic"),
            ({"deterministic": False}, "not_deterministic"),
            ({"error_class": "RuntimeError:message_omitted",
              "attempts": ["RuntimeError:message_omitted"] * 2}, "class_not_accepted"),
            ({"slice_audio_sha256": "f" * 64}, "slice_changed"),
            ({"same_slice_as_collection": False}, "slice_changed"),
        ]
        for changes, code in bad:
            with self.assertRaisesRegex(InputError, code):
                evaluator.check_probe_failure_classification(rows, self.classification(rows, **changes), split="dev")
        missing = self.classification(rows)
        missing["failures"].pop()
        extra = self.classification(rows)
        extra["failures"].append(dict(extra["failures"][0], index=0))
        for value in (missing, extra):
            with self.assertRaisesRegex(InputError, "does_not_cover_failures"):
                evaluator.check_probe_failure_classification(rows, value, split="dev")
        with self.assertRaisesRegex(InputError, "identity_mismatch"):
            evaluator.check_probe_failure_classification(rows, self.classification(rows), split="new")


if __name__ == "__main__":
    unittest.main()
