"""A5/A6 regressions: invented references only, no real-corpus fixture reads."""
from contextlib import redirect_stdout
from dataclasses import replace
import hashlib
import io
import json
from pathlib import Path
import random
import subprocess
import unittest
from unittest.mock import patch

from Scripts.target_eval import calibrate as a
from Scripts.target_eval import clusters
from Scripts.target_eval import corpora as c
from Scripts.target_eval import reference_annotations as annotations
from Scripts.target_eval import test_calibrate as fixtures


def invented_annotation(text, *, offset=None):
    return annotations.ReferenceAnnotation(
        id="synthetic-tau-note", meeting="S/PV.synthetic", turn_index=1, locale="en",
        original_text_sha256=hashlib.sha256(text.encode()).hexdigest(),
        unicode_scalar_offset=text.index("\u03a4") if offset is None else offset,
        original="\u03a4", replacement="T",
        provenance={"kind": "invented test provenance", "record_text": "synthetic/record-en.txt"})


def cluster_row(turn, accepted, kind="good", target="en"):
    return {"turn_id": turn, "targetLocale": target, "case_kind": kind, "accepted": accepted}


class ClusterTests(unittest.TestCase):
    def test_five_reused_references_form_one_failure_cluster(self):
        rows = [cluster_row("invented:1", False) for _ in range(5)]
        rows += [cluster_row("invented:2", True) for _ in range(5)]
        result = clusters.summarize_clusters(rows)
        self.assertEqual(result["turn_reference_count"], 2)
        self.assertFalse(result["comparison_rows_are_independent"])
        self.assertEqual(result["any_false_rejection"]["numerator"], 1)
        self.assertEqual(result["any_false_rejection"]["denominator"], 2)
        self.assertEqual(result["false_rejection"]["mean_turn_rate"], .5)
        self.assertEqual(result["false_rejection"]["bootstrap_95_ci"], {"low": 0, "high": 1})
        self.assertEqual(result["per_turn"][0]["rejected_counts"]["good"], 5)

    def test_cluster_weight_is_equal_even_with_different_comparison_counts(self):
        rows = [cluster_row("invented:1", False) for _ in range(5)]
        rows += [cluster_row("invented:2", True)]
        result = clusters.summarize_clusters(rows, resamples=100)
        self.assertEqual(result["false_rejection"]["mean_turn_rate"], .5)
        self.assertNotEqual(result["false_rejection"]["mean_turn_rate"], 5 / 6)

    def test_seed_and_sorted_cluster_order_are_reproducible_without_global_rng_changes(self):
        rows = [cluster_row(f"invented:{index}", index > 0) for index in range(4)]
        random.seed(715)
        state = random.getstate()
        first = clusters.summarize_clusters(rows, resamples=17, seed=5)
        self.assertEqual(random.getstate(), state)
        self.assertEqual(first, clusters.summarize_clusters(list(reversed(rows)), resamples=17, seed=5))
        self.assertNotEqual(first["false_rejection"]["bootstrap_95_ci"],
                            clusters.summarize_clusters(rows, resamples=17, seed=9)
                            ["false_rejection"]["bootstrap_95_ci"])

    def test_zero_bootstrap_interval_cannot_supply_one_percent_population_proof(self):
        rows = [cluster_row(f"invented:{index}", True) for index in range(85)
                for _ in range(5)]
        result = clusters.summarize_clusters(rows)
        self.assertEqual(result["false_rejection"]["bootstrap_95_ci"], {"low": 0, "high": 0})
        best = result["best_case_zero_failures"]
        self.assertEqual(best["turn_count"], 85)
        self.assertGreater(best["upper_rate"], .01)
        self.assertAlmostEqual((1 - best["upper_rate"]) ** 85, .05)

    def test_empty_outcomes_and_invalid_resampling_inputs_are_explicit(self):
        result = clusters.summarize_clusters([])
        self.assertIsNone(result["false_rejection"]["bootstrap_95_ci"])
        self.assertIsNone(result["best_case_zero_failures"]["upper_rate"])
        for kwargs in ({"resamples": 0}, {"resamples": True}, {"seed": True}, {"seed": 1.2}):
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError):
                clusters.summarize_clusters([], **kwargs)
        with self.assertRaises(ValueError):
            clusters.summarize_clusters([cluster_row("invented:1", True),
                                        cluster_row("invented:1", True, target="fr")])


class AnnotationAndReportTests(fixtures.ScratchTests):
    def annotated_fixture(self):
        path, _ = self.un_fixture()
        data = json.loads(path.read_text())
        invented = "Invented seedlings. \u03a4iny robots inspect them. \u03a4 stays unlisted."
        data["turns"][0]["texts"]["en"] = invented
        path.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        return path, invented, invented_annotation(invented)

    def test_annotation_is_hash_bound_and_reported_without_changing_raw_or_other_texts(self):
        path, invented, annotation = self.annotated_fixture()
        raw = path.read_bytes()
        raw_data = json.loads(raw)
        with patch.object(annotations, "ANNOTATIONS", (annotation,)):
            corpus, metadata = a.load_un(path.parent.parent)
        unit = corpus.units[0]
        self.assertEqual(unit.texts["en"], invented.replace("\u03a4", "T", 1))
        self.assertEqual(unit.texts["en"].count("\u03a4"), 1)
        for locale in set(c.UN_LOCALES) - {"en"}:
            self.assertEqual(unit.texts[locale], raw_data["turns"][0]["texts"][locale])
        self.assertEqual(path.read_bytes(), raw)
        self.assertEqual(metadata["reference_annotation_count"], 1)
        note = metadata["reference_annotations"][0]
        self.assertEqual(note["turn_id"], unit.id)
        self.assertEqual(note["original_codepoints"], ["U+03A4"])
        self.assertEqual(note["replacement_codepoints"], ["U+0054"])
        self.assertEqual(note["original_text_sha256"], hashlib.sha256(invented.encode()).hexdigest())
        self.assertEqual(note["annotated_text_sha256"], hashlib.sha256(unit.texts["en"].encode()).hexdigest())

    def test_changed_reference_or_offset_fails_and_unlisted_tau_is_not_folded(self):
        path, invented, annotation = self.annotated_fixture()
        with patch.object(annotations, "ANNOTATIONS", (annotation,)):
            for text in (invented + " Added synthetic word.", invented.replace("\u03a4", "T", 1)):
                with self.subTest(text=text), self.assertRaisesRegex(ValueError, "no longer matches"):
                    annotations.apply_reference_annotations("S/PV.synthetic", 1, {"en": text})
            for meeting, index in (("S/PV.other", 1), ("S/PV.synthetic", 2)):
                texts, applied = annotations.apply_reference_annotations(meeting, index, {"en": invented})
                self.assertEqual(texts["en"], invented)
                self.assertEqual(applied, [])
        with patch.object(annotations, "ANNOTATIONS", (replace(annotation, unicode_scalar_offset=0),)), \
                self.assertRaisesRegex(ValueError, "no longer matches"):
            c.read_un(path.parent.parent)
        self.assertEqual(c.read_un(path.parent.parent).units[0].texts["en"], invented)

    def test_full_report_keeps_annotation_and_cluster_limits_but_no_machine_paths(self):
        path, _, annotation = self.annotated_fixture()
        raw = path.read_bytes()
        with patch.object(annotations, "ANNOTATIONS", (annotation,)):
            units = c.read_un(path.parent.parent).units
            cases = a.make_cases(units)
            cli = self.transport_cli(cases)
            output = self.root / "sidecar-report.json"
            runner = subprocess.run

            def diagnostic_runner(*args, **kwargs):
                process = runner(*args, **kwargs)
                return subprocess.CompletedProcess(process.args, process.returncode, process.stdout,
                                                   "invented diagnostic at " + str(self.root))

            with patch.object(a.subprocess, "run", side_effect=diagnostic_runner):
                report = a.calibrate(cli=cli, un_root=path.parent.parent, output=output,
                                     bootstrap_resamples=53, bootstrap_seed=19)
        self.assertEqual(path.read_bytes(), raw)
        self.assertEqual(report["schema_version"], 2)
        self.assertEqual(report["tools"]["swift_cli"], {
            "basename": cli.name, "sha256": hashlib.sha256(cli.read_bytes()).hexdigest(),
            "subcommand": "judge"})
        self.assertNotIn(str(self.root), output.read_text())
        self.assertNotIn("stderr_tail", output.read_text())
        self.assertEqual(report["corpus"]["reference_annotation_count"], 1)
        self.assertFalse(report["methods"]["holdout"]["present"])
        self.assertFalse(report["methods"]["one_percent_gate"]["established"])
        self.assertIsNone(report["methods"]["maximum_length_ratio_override"])
        self.assertEqual(set(report["tools"]["additional_python_file_sha256"]),
                         {"clusters.py", "reference_annotations.py"})
        for target in a.TARGET_LOCALES:
            result = report["targets"][target]
            self.assertEqual(result["false_rejection"]["denominator"], 5)
            cluster = result["clustered_by_turn_reference"]
            self.assertEqual(cluster["turn_reference_count"], 1)
            self.assertEqual(cluster["bootstrap"]["resamples"], 53)
            self.assertEqual(cluster["bootstrap"]["seed"], 19)

    def test_compact_stdout_uses_relative_output_path_and_cluster_summary(self):
        path, units = self.un_fixture()
        cli = self.transport_cli(a.make_cases(units[:1], targets=("en",)))
        output = self.root / "compact.json"
        with redirect_stdout(io.StringIO()) as stdout:
            a.main(["--cli", str(cli), "--un-root", str(path.parent.parent),
                    "--output", str(output), "--targets", "en", "--bootstrap-resamples", "23"])
        summary = json.loads(stdout.getvalue())
        self.assertFalse(Path(summary["output"]).is_absolute())
        self.assertNotIn(str(self.root), stdout.getvalue())
        self.assertEqual(summary["targets"]["en"]["clustered_by_turn_reference"]
                         ["turn_reference_count"], 1)

    def test_policy_provenance_discrepancy_is_reported_without_changing_ratio(self):
        case = a.CalibrationCase("invented-length:1", "good", "fr", {
            "id": "invented-length:1", "source": "r" * 1000, "candidate": "f" * 1189,
            "sourceLanguage": "ru", "targetLocale": "fr"})
        row = {**fixtures.canned_verdict(case), "turn_id": case.turn_id, "case_kind": "good",
               "source_language": "ru", "candidate_language": "fr",
               "configuredMaximumLengthRatio": 1.20, "minimumSourceLetters": 24,
               "absoluteLetterAllowance": 12, "maximumOutputLetters": 1212}
        a._validate_verdict(row, case)
        guard = a._summarize([row])["observed_letter_guard"]
        self.assertEqual(guard["sample_p99.5_ceiling_to_0.01"], 1.19)
        self.assertFalse(guard["configured_matches_sample_p99.5_ceiling"])
        self.assertEqual(row["configuredMaximumLengthRatio"], 1.20)
        self.assertNotIn("maximumLengthRatio", case.request)

    def test_invalid_bootstrap_settings_do_not_launch_cli_or_create_report(self):
        with patch.object(a, "load_un") as reader, patch.object(a.subprocess, "run") as runner, \
                self.assertRaises(ValueError):
            a.calibrate(cli=self.root / "unused", un_root=self.root,
                        output=self.root / "uncreated.json", bootstrap_resamples=0)
        reader.assert_not_called()
        runner.assert_not_called()
        self.assertFalse((self.root / "uncreated.json").exists())


if __name__ == "__main__":
    unittest.main()
