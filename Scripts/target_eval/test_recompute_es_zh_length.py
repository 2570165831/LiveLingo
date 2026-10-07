"""Synthetic arithmetic and file-boundary tests; never read the UN corpus."""
from fractions import Fraction
import json
from pathlib import Path
import tempfile
import unittest

from Scripts.target_eval import recompute_es_zh_length as r


class LengthRecomputationTests(unittest.TestCase):
    def test_nfc_letters_include_mixed_scripts_without_marks_or_digits(self):
        self.assertEqual(r.letter_count("中e\u0301Ж2!\u0301"), 3)
        self.assertEqual(r.letter_count("中文AB"), 4)
        with self.assertRaises(ValueError):
            r.Observation("zero", "123!", "abc")

    def test_fractional_linear_interpolation_and_exact_ceiling(self):
        rows = [r.Observation(str(i), "中", "a" * i) for i in (4, 1, 2)]
        summary = r.quantile_summary(rows)
        # Position 1.99: 2 + (4-2)*.99 = 3.98, not the nearest rank 4.
        self.assertEqual(summary["p99_5"], r.exact_number(Fraction(199, 50)))
        self.assertEqual(summary["interpolation"]["zero_based_position"]["value"], 1.99)
        self.assertEqual(summary["ceil_0_01"], 3.98)
        self.assertEqual(r.ceil_hundredth(Fraction(398001, 100000)), Fraction(399, 100))
        with self.assertRaises(ValueError):
            r.quantile_summary([])

    def test_source_dedup_preserves_longest_target_and_nfc_identity(self):
        rows = [r.Observation("first", "中e\u0301", "abc"),
                r.Observation("longest", "中é", "abcdef"),
                r.Observation("punctuation", "中é!", "a")]
        retained, duplicates = r.deduplicate_source(rows)
        self.assertEqual([row.turn_id for row in retained], ["longest", "punctuation"])
        self.assertEqual(duplicates[0]["turn_ids"], ["first", "longest"])
        self.assertEqual(duplicates[0]["retained_turn_id"], "longest")

    def test_floor_boundary_and_all_observations_remain_visible(self):
        rows = [r.Observation("short", "中" * 16, "a" * 87),
                r.Observation("boundary", "文" * 24, "a" * 120)]
        report = r.build_report(rows)
        self.assertEqual(report["sample_count"], 2)
        self.assertEqual(report["quantiles"]["source_below_24_raw"]["sample_count"], 1)
        self.assertEqual(report["quantiles"]["source_at_least_24_raw"]["sample_count"], 1)
        self.assertEqual(rows[0].raw_ratio, Fraction(87, 16))
        self.assertEqual(rows[0].floor_ratio, Fraction(87, 24))
        self.assertEqual(rows[1].raw_ratio, rows[1].floor_ratio)
        self.assertEqual(len(report["observations"]), 2)
        self.assertFalse(report["holdout"]["independent_quality_gate_passed"])

    def test_exact_length_boundary_and_preservation_are_not_quantiles(self):
        rows = [r.Observation("equal", "中" * 24, "a" * 36),
                r.Observation("over", "文" * 24, "a" * 37)]
        result = r.length_only_check(rows, Fraction(1))
        self.assertEqual(result["length_rejected_count"], 1)
        self.assertEqual(result["length_rejected"][0]["turn_id"], "over")
        self.assertEqual(result["length_rejected"][0]["excess_letters"]["value"], 1)
        preservation = r.build_report(rows)["recommendation"]
        self.assertEqual(preservation["minimum_coefficient_to_preserve_this_sample"],
                         r.exact_number(Fraction(25, 24)))
        self.assertEqual(preservation["sample_preserving_ceil_0_01"], 1.05)

    def test_reader_uses_six_language_completeness_and_enforces_raw_hash(self):
        turns = []
        for i in (1, 2):
            turns.append({"index": i, "texts": {lang: "中文abc" for lang in r.LOCALES},
                          "text_status": {lang: "extracted" for lang in r.LOCALES}})
        turns[1]["text_status"]["ru"] = "partial"
        data = {"schema_version": 1, "id": "synthetic", "turn_count": 2,
                "country_header_checks_all_passed": True,
                "mapped_turn_counts": {lang: 2 for lang in r.LOCALES}, "turns": turns}
        raw = json.dumps(data).encode("utf-8")
        with tempfile.TemporaryDirectory(prefix="es-zh-reader-") as directory:
            path = Path(directory) / "turns.json"
            path.write_bytes(raw)
            rows, metadata = r.read_meeting(path, "synthetic", r.sha256(raw))
            self.assertEqual([row.turn_id for row in rows], ["synthetic:turn:1"])
            self.assertEqual(metadata["excluded"],
                             [{"turn_id": "synthetic:turn:2", "text_status": {"ru": "partial"}}])
            with self.assertRaises(ValueError):
                r.read_meeting(path, "synthetic", "0" * 64)

    def test_report_never_replaces_files_or_traverses_symlinks(self):
        with tempfile.TemporaryDirectory(prefix="es-zh-output-") as directory:
            root = Path(directory)
            output = root / "report.json"
            r.write_report({"synthetic": True}, output, root)
            self.assertEqual(json.loads(output.read_text()), {"synthetic": True})
            with self.assertRaises(FileExistsError):
                r.write_report({"synthetic": False}, output, root)
            self.assertEqual(json.loads(output.read_text()), {"synthetic": True})
            link = root / "link.json"
            link.symlink_to(output)
            with self.assertRaises(ValueError):
                r.write_report({}, link, root)
            with self.assertRaises(ValueError):
                r.write_report({}, root.parent / "outside.json", root)


if __name__ == "__main__":
    unittest.main()
