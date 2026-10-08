"""Synthetic public formats, document isolation and exact confidence bounds."""
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timezone
import gzip
import io
import json
import math
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from . import calibrate as a
from . import corpora as c
from . import test_calibrate as fixtures


class PublicCorpusTests(unittest.TestCase):
    def setUp(self):
        self.temp = self.enterContext(tempfile.TemporaryDirectory())
        self.root = Path(self.temp)

    def opus(self, *, missing=False, duplicate=False, missing_sentence=False, mismatch=False):
        raw_codes = {"zh": "zh_cn", **{locale: locale for locale in c.UN_LOCALES if locale != "zh"}}
        paths, specs = {}, []
        for locale, code in raw_codes.items():
            path = self.root / (locale + ".zip")
            text = f'<text><s id="1">{locale} one.</s><p><s id="2.1">{locale} two</s><s id="2.2">end.</s></p></text>'
            if missing_sentence and locale == "es":
                text = '<text><s id="unused">missing.</s></text>'
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr(f"TED2020/raw/{code}/ted2020-synthetic.xml", text)
            paths[locale] = path
        for locale in set(c.UN_LOCALES) - {"en"}:
            source, target = ("ar", "en") if locale == "ar" else ("en", raw_codes[locale])
            path = self.root / (locale + ".xml.gz")
            document = "other" if mismatch and locale == "es" else "synthetic"
            links = '<link xtargets="1;1"/><link xtargets="2.1 2.2;2.1 2.2"/>'
            if duplicate and locale == "es":
                links += '<link xtargets="1;2.1"/>'
            content = (f'<cesAlign><linkGrp fromDoc="{source}/ted2020-synthetic.xml.gz" '
                       f'toDoc="{target}/ted2020-{document}.xml.gz">{links}</linkGrp></cesAlign>')
            if missing and locale == "es":
                content = '<cesAlign/>'
            with gzip.open(path, "wt") as handle:
                handle.write(content)
            specs.append({"source": source, "target": target, "locale": locale, "path": path})
        return paths, specs

    def test_opus_exact_pivot_many_to_many_and_reverse_arabic_orientation(self):
        result = c.read_ted_opus(*self.opus())
        self.assertEqual(len(result.units), 1)
        unit = result.units[0]
        self.assertEqual(set(unit.texts), set(c.UN_LOCALES))
        self.assertEqual(unit.metadata["eligible_anchor_count"], 2)
        self.assertEqual(unit.metadata["split_group"], "ted2020:ted2020-synthetic")
        self.assertEqual(unit.metadata["sentence_ids"]["ar"], unit.metadata["sentence_ids"]["en"])
        self.assertIn(unit.texts["es"], ["es one.", "es two end."])

    def test_missing_parallel_document_is_explicitly_excluded(self):
        result = c.read_ted_opus(*self.opus(missing=True))
        self.assertEqual(result.units, ())
        self.assertEqual(result.excluded[0]["reason"], "missing_parallel_talk")

    def test_duplicate_anchor_cannot_silently_replace_translation(self):
        with self.assertRaisesRegex(ValueError, "ambiguous"):
            c.read_ted_opus(*self.opus(duplicate=True))

    def test_alignment_cannot_reference_missing_sentence_or_another_talk(self):
        with self.assertRaisesRegex(ValueError, "missing raw sentence"):
            c.read_ted_opus(*self.opus(missing_sentence=True))
        # Recreate the fixtures in the same isolated scratch directory.
        with self.assertRaisesRegex(ValueError, "different talks"):
            c.read_ted_opus(*self.opus(mismatch=True))

    def flores_manifest(self, rows):
        files = {}
        for locale in ("en", "es"):
            path = self.root / (locale + ".jsonl")
            path.write_text("".join(json.dumps({**row, "text": locale + row["text"]}) + "\n"
                                    for row in rows), encoding="utf-8")
            files[locale] = path.name
        path = self.root / "manifest.json"
        path.write_text(json.dumps({"schema_version": 1, "corpora": [
            {"format": "flores-plus-jsonl", "files": files}]}))
        return path

    def test_flores_article_group_survives_different_official_splits(self):
        path = self.flores_manifest([
            {"split": "dev", "id": 1, "url": "https://example.invalid/article", "text": "one"},
            {"split": "devtest", "id": 2, "url": "https://example.invalid/article", "text": "two"}])
        observed = []
        result, files = c.read_public_manifest(path, on_input=observed.append)
        self.assertEqual(len(files), 3)
        self.assertEqual(set(files), set(observed))
        self.assertEqual(result.units[0].metadata["split_group"], result.units[1].metadata["split_group"])
        partitions = a.partition_public_units(result.units)
        self.assertEqual(sum(len(partitions[key]) for key in ("training", "holdout")), 1)

    def test_flores_requires_article_identity_not_sentence_random_split(self):
        path = self.flores_manifest([{"split": "dev", "id": 1, "url": "", "text": "one"}])
        with self.assertRaisesRegex(ValueError, "article URL"):
            c.read_public_manifest(path)

    def test_flores_duplicate_and_misaligned_keys_fail(self):
        row = {"split": "dev", "id": 1, "url": "https://example.invalid/article", "text": "one"}
        with self.assertRaisesRegex(ValueError, "duplicate"):
            c.read_public_manifest(self.flores_manifest([row, row]))
        path = self.flores_manifest([row])
        target = json.loads((self.root / "es.jsonl").read_text())
        target["id"] = 2
        (self.root / "es.jsonl").write_text(json.dumps(target) + "\n")
        with self.assertRaisesRegex(ValueError, "identical split/ID"):
            c.read_public_manifest(path)


def unit(index, *, status="community-human", group=None):
    original = fixtures.synthetic_unit(f"synthetic:{index}")
    return c.ParallelUnit(original.id, "synthetic",
        {locale: text + f" marker{index}" for locale, text in original.texts.items()},
        {"split_group": group or f"synthetic:document:{index}", "reference_status": status})


def record(index, *, source="en", target="es", kind="good", rejected=False,
           source_letters=100, target_letters=160):
    return {"group_id": f"synthetic:document:{index}", "targetLocale": target,
            "source_language": source, "source_stratum": a.SOURCE_STRATA[source],
            "case_kind": kind, "candidate_language": target if kind == "good" else source,
            "accepted": not rejected, "lengthAccepted": not rejected,
            "rejection": "disproportionateLength" if rejected else None,
            "sourceLetters": source_letters, "candidateLetters": target_letters,
            "lengthRatio": target_letters / source_letters,
            "minimumSourceLetters": 24, "absoluteLetterAllowance": 12}


class PublicCalibrationTests(unittest.TestCase):
    def test_clopper_pearson_zero_nonzero_all_and_empty(self):
        self.assertAlmostEqual(a.binomial_upper95(0, 600), 1 - .05 ** (1 / 600), places=14)
        self.assertAlmostEqual(a.binomial_upper95(1, 2), math.sqrt(.95), places=14)
        self.assertEqual(a.binomial_upper95(2, 2), 1)
        self.assertIsNone(a.binomial_upper95(0, 0))
        for failures, count in ((-1, 3), (4, 3), (True, 2), (0, -1)):
            with self.assertRaises(ValueError):
                a.binomial_upper95(failures, count)

    def test_binomial_bound_is_monotonic_and_does_not_degenerate_at_zero(self):
        bounds = [a.binomial_upper95(failures, 600) for failures in range(4)]
        self.assertEqual(bounds, sorted(bounds))
        self.assertGreater(bounds[0], 0)

    def test_documents_remain_isolated_and_unknown_authorship_is_auxiliary(self):
        units = [unit(index) for index in range(30)] + [unit(99, status="unknown")]
        units.append(unit(100, group=units[0].metadata["split_group"]))
        result = a.partition_public_units(units)
        training = {u.metadata["split_group"] for u in result["training"]}
        holdout = {u.metadata["split_group"] for u in result["holdout"]}
        self.assertFalse(training & holdout)
        self.assertEqual(len(training) + len(holdout), 30)
        self.assertEqual([u.id for u in result["auxiliary"]], ["synthetic:99"])
        shuffled = a.partition_public_units(list(reversed(units)))
        self.assertEqual(result, shuffled)

    def test_repeated_reference_text_does_not_inflate_document_count(self):
        original = unit(1)
        duplicate = c.ParallelUnit("synthetic:duplicate", "synthetic", original.texts,
            {"split_group": "synthetic:other-document", "reference_status": "human"})
        result = a.partition_public_units([original, duplicate])
        self.assertEqual(len(result["training"]) + len(result["holdout"]), 1)
        self.assertEqual(result["duplicate_candidates_skipped"], 1)

    def test_fit_accounts_for_production_floor_allowance_and_minimum_documents(self):
        rows = [record(i, source_letters=10, target_letters=36) for i in range(599)]
        fit = a.fit_public_ratios(rows)["es"]["en"]
        self.assertEqual(fit["proposed_ratio"], 1.0)  # (36 - 12) / max(10, 24)
        self.assertIsNone(fit["candidate_ratio"])
        rows.append(record(599, source_letters=10, target_letters=36))
        fit = a.fit_public_ratios(rows)["es"]["en"]
        self.assertTrue(fit["sample_sufficient"])
        self.assertEqual(fit["candidate_ratio"], 1.0)
        self.assertEqual(fit["raw_letter_ratio"]["p99.5"], 3.6)

    def test_fit_rejects_reused_direction_or_changing_cli_allowance(self):
        with self.assertRaisesRegex(ValueError, "one reference"):
            a.fit_public_ratios([record(1), record(1)])
        changed = record(2)
        changed["absoluteLetterAllowance"] = 99
        with self.assertRaisesRegex(ValueError, "allowance changed"):
            a.fit_public_ratios([record(1), changed])

    def test_partial_locales_no_same_target_echo_and_frozen_direction_override(self):
        original = unit(1)
        pair = c.ParallelUnit(original.id, "synthetic", {k: original.texts[k] for k in ("en", "es")},
                              original.metadata)
        cases = a.make_public_cases([pair], ratios={"es": {"en": 1.48}})
        self.assertEqual(len(cases), 4)
        self.assertTrue(all(case.request["sourceLanguage"] != case.request["targetLocale"] for case in cases))
        self.assertTrue(all(case.request["maximumLengthRatio"] == 1.48 for case in cases
                            if case.request["targetLocale"] == "es"))
        self.assertTrue(all("maximumLengthRatio" not in case.request for case in cases
                            if case.request["targetLocale"] == "en"))

    def test_stratum_confidence_counts_documents_not_reused_latin_comparisons(self):
        rows = [record(1, rejected=True), record(1, source="fr"), record(2), record(2, source="fr")]
        metric = a.summarize_public(rows, ("es",))["es"]["by_stratum"]["latin"]["reference_false_rejection"]
        self.assertEqual((metric["numerator"], metric["denominator"]), (1, 4))
        self.assertEqual((metric["documents_with_any_rejection"], metric["documents"]), (1, 2))
        self.assertAlmostEqual(metric["upper95"], math.sqrt(.95), places=14)

    def test_negative_bounds_measure_misses_and_report_ambiguous_labels(self):
        rows = [record(1, kind="echo", rejected=True), record(2, kind="echo")]
        rows[1]["label_ambiguous"] = True
        metric = a.summarize_public(rows, ("es",))["es"]["echo_interception"]
        self.assertEqual(metric["interception_rate"], .5)
        self.assertEqual(metric["ambiguous_label_count"], 1)
        self.assertAlmostEqual(metric["miss_upper95"], math.sqrt(.95), places=14)

    def test_public_mode_refuses_repository_output_before_reading_inputs(self):
        with patch.object(c, "read_public_manifest") as reader, self.assertRaises(ValueError):
            a.calibrate_public(cli="unused", manifest="unused", output=c.repository_root() / "forbidden.json")
        reader.assert_not_called()

    def test_public_cli_does_not_load_default_un_data(self):
        report = {"partitions": {"training": [1], "holdout": [2], "auxiliary": []}, "fits": {}}
        with patch.object(a, "calibrate_public", return_value=report) as public, \
                patch.object(a, "calibrate") as legacy, redirect_stdout(io.StringIO()):
            self.assertEqual(a.main(["--cli", "synthetic", "--public-manifest", "synthetic-manifest",
                                     "--output", "synthetic-report"]), 0)
        legacy.assert_not_called()
        self.assertEqual(public.call_args.kwargs["minimum_samples"], 600)

    def test_public_pipeline_freezes_fit_binds_inputs_and_preserves_existing_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            files = {}
            for locale in c.UN_LOCALES:
                path = root / (locale + ".jsonl")
                path.write_text("".join(json.dumps({"split": "dev", "id": index,
                    "url": f"https://example.invalid/article-{index}",
                    "text": unit(index).texts[locale]}) + "\n" for index in range(30)))
                files[locale] = path.name
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps({"schema_version": 1, "corpora": [
                {"format": "flores-plus-jsonl", "files": files}]}))
            cli = root / "synthetic-cli"
            cli.write_text("synthetic fixture, never executed")
            cli.chmod(0o700)
            phases = []

            def canned_judge(executable, cases, **kwargs):
                phases.append(cases)
                rows = []
                for case in cases:
                    row = fixtures.canned_verdict(case)
                    ratio = case.request.get("maximumLengthRatio", 2.0)
                    limit = max(24, row["sourceLetters"]) * ratio + 12
                    row.update({"configuredMaximumLengthRatio": ratio, "minimumSourceLetters": 24,
                                "absoluteLetterAllowance": 12, "maximumOutputLetters": limit,
                                "lengthAccepted": row["candidateLetters"] <= limit})
                    if case.kind == "good" and not row["lengthAccepted"]:
                        row.update(accepted=False, rejection="disproportionateLength")
                    a._validate_verdict(row, case)
                    rows.append({**row, "turn_id": case.turn_id, "case_kind": case.kind,
                                 "source_language": case.request["sourceLanguage"],
                                 "candidate_language": case.candidate_language})
                return rows, []

            destination = root / "outputs" / "report.json"
            clock = unittest.mock.Mock(wraps=a.datetime)
            clock.now.return_value = datetime(2001, 1, 2, tzinfo=timezone.utc)
            with patch.dict(os.environ, {c.OUTPUT_ROOT_ENV: str(root)}), \
                    patch.object(a, "datetime", clock), \
                    patch.object(a, "judge_cases", side_effect=canned_judge), redirect_stderr(io.StringIO()):
                report = a.calibrate_public(cli=cli, manifest=manifest, output=destination, minimum_samples=2)
                before = destination.read_bytes()
                with self.assertRaises(FileExistsError):
                    a.calibrate_public(cli=cli, manifest=manifest, output=destination)
                self.assertEqual(before, destination.read_bytes())
            self.assertEqual(report["created_at_utc"], "2001-01-02T00:00:00+00:00")
            self.assertEqual(len(report["input_files"]), 7)
            self.assertTrue(all(case.kind == "good" for case in phases[0]))
            self.assertTrue(all("maximumLengthRatio" not in case.request for case in phases[1]))
            for case in phases[2]:
                self.assertEqual(case.request["maximumLengthRatio"], report["fits"]
                    [case.request["targetLocale"]][case.request["sourceLanguage"]]["candidate_ratio"])
            for receipt in report["verdict_files"]:
                path = destination.parent / receipt["file"]
                self.assertEqual(a.sha256_file(path), receipt["sha256"])
                self.assertEqual(len(path.read_text().splitlines()), receipt["case_count"])


if __name__ == "__main__":
    unittest.main()
