"""Synthetic CPU tests for the post-hoc comparison; no real datasets or models.

Run: python3 -m unittest discover -s Scripts/trigger_eval -p test_posthoc.py -v
Temporary files honor the caller's TMPDIR.
"""

from __future__ import annotations

import io
import json
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from dataclasses import asdict, replace
from pathlib import Path

import posthoc
import simulate
from simulate import InputError, Parameters

FROZEN = Parameters(latin_threshold=0.55, nonlatin_consensus=False)
CASE_KEYS = {
    "failure", "split", "dataset", "track", "index", "start_s", "end_s",
    "reference_language", "reference_trusted", "reference_kind", "boundary_reason",
    "floor_interp_waveform_cosine", "parakeet_accepted", "quality_reason", "pk_mean_probability",
    "pk_min_probability", "nl_language", "nl_probability", "probe_language",
    "probe_label_probability", "probe_english_probability", "switch_language", "reason",
    "trigger", "gate", "confirmation", "previous_segment",
}


def row(index: int = 0, **changes):
    result = {
        "dataset": "synthetic", "split": "dev", "track": "english", "index": index,
        "start_s": index * 8.0, "end_s": (index + 1) * 8.0,
        "reference_language": "en", "reference_trusted": True,
        "parakeet_accepted": True, "pk_mean_probability": 0.99,
        "pk_min_probability": 0.20, "pk_word_count": 8, "pk_words_per_second": 1.0,
        "nl_language": "en", "nl_probability": 0.98,
        "probe_language": "en", "probe_label_probability": 0.99,
        "probe_english_probability": 0.99, "probe_seconds": 0.25, "probe_error": False,
    }
    result.update(changes)
    return result


def latin_false_switch_rows(split="dev"):
    # Low confidence triggers a probe; a qualified French head requests a follow-up,
    # whose second qualified French head confirms a (false) switch on English audio.
    french = {"probe_language": "fr", "probe_label_probability": 0.80, "probe_english_probability": 0.001}
    return [
        row(0, split=split, pk_mean_probability=0.50, **french),
        row(1, split=split, **french),
        row(2, split=split),
    ]


class ConfigurationTests(unittest.TestCase):
    def test_threshold_series_changes_only_latin_threshold(self):
        configs = posthoc.configurations(asdict(FROZEN), (0.55, 0.90))
        self.assertEqual([config["name"] for config in configs], ["latin_0.55", "latin_0.90"])
        self.assertIn("frozen", configs[0]["origin"])
        self.assertIn("post hoc", configs[1]["origin"])
        self.assertEqual(configs[0]["parameters"], asdict(FROZEN))
        self.assertEqual(configs[1]["parameters"], asdict(replace(FROZEN, latin_threshold=0.90)))

    def test_named_variant_applies_typed_overrides(self):
        variant = posthoc.parse_variant("old_0.90:latin_threshold=0.90,nonlatin_consensus=on:older recommendation")
        self.assertEqual(variant, ("old_0.90", {"latin_threshold": 0.90, "nonlatin_consensus": True},
                                   "older recommendation"))
        configs = posthoc.configurations(asdict(FROZEN), (0.55,), [variant])
        self.assertEqual(configs[1]["parameters"],
                         asdict(replace(FROZEN, latin_threshold=0.90, nonlatin_consensus=True)))
        with self.assertRaises(InputError):
            posthoc.configurations(asdict(FROZEN), (0.55,), [("latin_0.55", {}, "duplicate")])

    def test_override_parser_rejects_unknown_or_malformed_fields(self):
        for text in ("latin_languages=en", "latin_threshold", "latin_threshold=x",
                     "nonlatin_consensus=maybe", "latin_threshold=.5,latin_threshold=.6"):
            with self.subTest(text=text), self.assertRaises(InputError):
                posthoc.parse_overrides(text)
        with self.assertRaises(InputError):
            posthoc.parse_variant("missing-separator")


class CaseExplanationTests(unittest.TestCase):
    def test_latin_false_switch_names_trigger_gate_and_confirming_segment(self):
        result = posthoc.explain_cases(latin_false_switch_rows(), FROZEN)
        self.assertEqual(result["private_cases_suppressed"], 0)
        [case] = result["cases"]
        self.assertEqual(set(case), CASE_KEYS)
        self.assertEqual((case["failure"], case["index"], case["switch_language"], case["reason"]),
                         ("english_false_switch", 1, "fr", "confirmed"))
        self.assertEqual(case["trigger"], ["followup_after_previous_qualified_segment"])
        self.assertEqual(case["gate"], {"script": "latin", "label_threshold": 0.55, "english_max": 0.01})
        self.assertEqual(case["confirmation"], "previous_adjacent_segment_qualified_same_language")
        previous = case["previous_segment"]
        self.assertEqual((previous["index"], previous["reason"], previous["qualified_language"]),
                         (0, "pending_consensus", "fr"))
        self.assertEqual(previous["trigger"], ["low_confidence_mean"])

    def test_higher_latin_threshold_blocks_the_same_case(self):
        self.assertEqual(posthoc.explain_cases(latin_false_switch_rows(), replace(FROZEN, latin_threshold=0.90))["cases"], [])

    def test_nonlatin_single_segment_and_wrong_language_cases(self):
        rows = [
            row(0, parakeet_accepted=False, probe_language="zh", probe_label_probability=0.97,
                probe_english_probability=0.001),
            row(0, track="floor", reference_language="zh", parakeet_accepted=False,
                probe_language="es", probe_label_probability=0.99, probe_english_probability=0.0),
            row(1, track="floor", reference_language="zh", probe_language="es",
                probe_label_probability=0.99, probe_english_probability=0.0),
        ]
        cases = posthoc.explain_cases(rows, FROZEN)["cases"]
        self.assertEqual([(case["failure"], case["track"], case["index"]) for case in cases],
                         [("english_false_switch", "english", 0), ("wrong_language_switch", "floor", 1)])
        self.assertEqual(cases[0]["trigger"], ["parakeet_rejected"])
        self.assertEqual(cases[0]["confirmation"], "single_segment_no_consensus_required")
        self.assertIsNone(cases[0]["previous_segment"])
        self.assertEqual(cases[0]["gate"]["script"], "non_latin")
        # Turning on non-Latin consensus removes the single-segment Chinese switch.
        consensus = posthoc.explain_cases(rows, replace(FROZEN, nonlatin_consensus=True))["cases"]
        self.assertEqual([case["failure"] for case in consensus], ["wrong_language_switch"])

    def test_private_rows_are_counted_never_described(self):
        rows = [dict(item, private_classroom=True, reference_kind="manual") for item in latin_false_switch_rows()]
        result = posthoc.explain_cases(rows, FROZEN)
        self.assertEqual(result["cases"], [])
        self.assertEqual(result["private_cases_suppressed"], 1)

    def test_compare_totals_match_simulate_per_split(self):
        rows = latin_false_switch_rows("dev") + latin_false_switch_rows("new")
        configs = posthoc.configurations(asdict(FROZEN), (0.55, 0.90))
        report = posthoc.compare(rows, configs)
        self.assertEqual(report["scope"], posthoc.SCOPE)
        self.assertEqual(report["splits"], {"dev": 3, "new": 3})
        by_key = {(item["configuration"], item["split"]): item for item in report["results"]}
        self.assertEqual(by_key[("latin_0.55", "new")]["english"]["numerator"], 1)
        self.assertEqual(by_key[("latin_0.90", "new")]["english"]["numerator"], 0)
        expected = simulate.simulate([item for item in rows if item["split"] == "dev"], FROZEN)
        self.assertEqual(by_key[("latin_0.55", "dev")]["english"]["one_sided_95_upper"],
                         expected["english"]["one_sided_95_upper"])
        self.assertEqual(by_key[("latin_0.55", "dev")]["extra_probe_count_per_audio_hour"],
                         expected["extra_probe_count_per_audio_hour"])
        cases = {(item["configuration"], item["split"]): len(item["cases"]) for item in report["cases"]}
        self.assertEqual(cases, {("latin_0.55", "dev"): 1, ("latin_0.55", "new"): 1,
                                 ("latin_0.90", "dev"): 0, ("latin_0.90", "new"): 0})


class CommandLineTests(unittest.TestCase):
    def test_cli_writes_labelled_report_once(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            features, frozen, output = root / "rows.jsonl", root / "parameters.json", root / "posthoc.json"
            features.write_text("".join(json.dumps(item) + "\n" for item in latin_false_switch_rows()), encoding="utf-8")
            frozen.write_text(json.dumps({"parameters": asdict(FROZEN)}), encoding="utf-8")
            argv = ["--input", str(features), "--parameters", str(frozen), "--output", str(output),
                    "--latin-thresholds", "0.55", "0.90",
                    "--variant", "old:latin_threshold=0.90,nonlatin_consensus=on:older recommendation"]
            with redirect_stdout(io.StringIO()):
                self.assertEqual(posthoc.main(argv), 0)
            report = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(report["scope"], "post_hoc_comparison_not_preregistered")
            self.assertIn("not a selection procedure", report["warning"])
            self.assertEqual([config["name"] for config in report["configurations"]], ["latin_0.55", "latin_0.90", "old"])
            self.assertEqual(len(report["frozen_parameters_sha256"]), 64)
            with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                self.assertEqual(posthoc.main(argv), 2)


if __name__ == "__main__":
    unittest.main()
