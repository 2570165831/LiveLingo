"""Synthetic regressions for M1–M10; expectations come from explicit hand counts."""
from contextlib import redirect_stderr, redirect_stdout
from copy import deepcopy
from fractions import Fraction
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from Scripts.target_eval import corpora as c
from Scripts.target_eval import metrics as m

class MetricReviewTests(unittest.TestCase):
    def example(self, identity="one", target="fr", hypothesis="aa", reference="aa"):
        return {"id": identity, "source": "An invented example.", "reference": reference,
                "hypothesis": hypothesis, "source_locale": "en", "target_locale": target}

    def test_reference_absent_character_and_word_orders_zero_hypothesis_counts(self):
        self.assertEqual(m.chrf_statistics("abcd", "a"),
                         ((4, 1, 1),) + ((0, 0, 0),) * 5)
        self.assertEqual(m.chrf_statistics("a b c", "a", char_order=1, word_order=2),
                         ((3, 1, 1), (3, 1, 1), (0, 0, 0)))
        self.assertEqual(m.chrf_statistics("abcdef", "", word_order=2), ((0, 0, 0),) * 8)

    def test_effective_order_sentence_and_corpus_hand_expectations(self):
        # aa/ab: char P=R=(1/2+0)/2=1/4. a,b/a,c: pooled 1/2.
        self.assertEqual(m.chrf("aa", "ab"), 25)
        self.assertEqual(m.corpus_chrf(["a", "b"], ["a", "c"]), 50)

    def test_short_reference_corpus_matches_hand_pooled_counts(self):
        # H/R/M by character order: (14,10,10), (12,8,8),
        # (6,6,6), (5,5,5), (4,4,4), (3,3,3).
        # P=113/126, R=1, F2=565/578. No hypothesis counts from the
        # short Chinese reference enter orders 3–6.
        score = m.corpus_chrf(["abcdefgh", "好的没问题啊"], ["abcdefgh", "好的"])
        self.assertAlmostEqual(score, 100 * float(Fraction(565, 578)))

    def test_chinese_chrfpp_with_spaced_latin_matches_hand_counts(self):
        # Char H/R/M: 14/13/12, 12/11/9, 10/9/6, 8/7/5, 6/5/4,
        # 3/3/3. Word H/R/M: 6/4/3, 2/2/2. P=5039/6720,
        # R=400733/480480, F2=2019293587/2475496128.
        score = m.corpus_chrfpp(["这是 DNA 分子。", "他说 OK 了。"],
                                ["这是 DNA 分子。", "他说好了。"])
        self.assertAlmostEqual(score, 100 * float(Fraction(2019293587, 2475496128)))

    def test_punctuation_detaches_single_edge_trailing_first(self):
        self.assertEqual(m._words('"yes." (yes [yes] can\'t x ,'),
                         ['"yes.', '"', '(', 'yes', '[yes', ']', "can't", 'x', ','])
        for hypothesis in ("(can't),", "(can't)"):
            with self.subTest(hypothesis=hypothesis):
                self.assertEqual(m.chrf_statistics(hypothesis, "can't", char_order=1, word_order=2)[1:],
                                 ((2, 1, 0), (0, 0, 0)))

    def test_two_ended_punctuation_chrfpp_matches_hand_counts(self):
        # Character matches 12/12,9/11,8/10,7/9,6/8,5/7;
        # word matches 2/4 and 1/3. P=R=78913/110880.
        self.assertAlmostEqual(m.chrfpp('He said "yes."', 'He said "yes".'),
                               100 * float(Fraction(78913, 110880)))

    def test_short_reference_bootstrap_uses_corrected_corpus_statistics(self):
        # Seed 0 draws [1,1],[0,1],[1,1],[1,1]. Delta for [0,1] is
        # 100*(1-565/578); for [1,1] it is 100*(1-20/31).
        low, high = Fraction(1300, 578), Fraction(1100, 31)
        result = m.paired_bootstrap_chrf(["abcdefgh", "好的没问题啊"],
                                         ["abcdefgh", "好的"], ["abcdefgh", "好的"],
                                         word_order=0, iterations=4, seed=0)
        self.assertAlmostEqual(result["delta"], float(low))
        self.assertAlmostEqual(result["ci_low"], float(low + (high - low) * Fraction(3, 40)))
        self.assertAlmostEqual(result["ci_high"], float(high))
        self.assertEqual(result["chrf_settings"]["reference_absent_hypothesis_count"], "zero")

    def test_scientific_and_ordinal_symbols_are_allowed_and_reported(self):
        for text, locale in (("波长 λ 为 500 nm", "zh-Hans"), ("Δv equals a times t", "en"),
                             ("el 1.º de mayo y la 2.ª", "es"), ("Ω µ", "fr")):
            with self.subTest(text=text, locale=locale):
                result = m.text_purity(text, locale)
                self.assertEqual(result["script_purity"], 1)
                self.assertEqual(result["forbidden_letter_count"], 0)
                self.assertGreater(result["script_counts"]["scientific_symbol"], 0)
        result = m.text_purity("λµºª", "en")
        self.assertEqual(result["letter_count"], 4)
        self.assertEqual(result["script_counts"]["scientific_symbol"], 4)

    def test_japanese_iteration_mark_is_han_and_other_scripts_remain_forbidden(self):
        self.assertEqual(m.text_purity("時々", "ja")["script_purity"], 1)
        self.assertEqual(m.text_purity("時々", "ja")["script_counts"]["han"], 2)
        self.assertEqual(m.text_purity("々", "en")["forbidden_letter_count"], 1)
        result = m.text_purity("λ漢か한Жاก", "en")
        self.assertEqual(result["forbidden_letter_count"], 6)
        self.assertEqual(result["script_counts"]["other"], 1)

    def test_evaluate_separates_target_locales_without_a_mixed_corpus_score(self):
        french = [self.example("fr-1", reference="ab"), self.example("fr-2", hypothesis="b", reference="c")]
        spanish = [self.example("es-1", target="es"), self.example("es-2", target="es")]
        original = deepcopy(french + spanish)
        report = m.evaluate(french + spanish)
        self.assertEqual(report["sample_count"], 4)
        self.assertNotIn("chrf", report)
        self.assertNotIn("chrfpp", report)
        self.assertEqual(report["by_target_locale"]["fr"], m.evaluate(french)["by_target_locale"]["fr"])
        self.assertEqual(report["by_target_locale"]["es"], m.evaluate(spanish)["by_target_locale"]["es"])
        self.assertEqual(report["by_target_locale"]["es"]["chrfpp"], 100)
        self.assertEqual(french + spanish, original)

    def test_compare_resamples_each_target_independently_and_keeps_id_pairing(self):
        baseline = [self.example("fr-1", reference="ab"), self.example("es-1", target="es"),
                    self.example("fr-2", hypothesis="b", reference="c"),
                    self.example("es-2", target="es")]
        candidate = [dict(row, hypothesis=row["reference"]) for row in reversed(baseline)]
        report = m.compare(baseline, candidate, iterations=40, seed=7)
        for field in ("delta", "ci_low", "ci_high"):
            self.assertNotIn(field, report)
        for locale in ("es", "fr"):
            a = [row for row in baseline if row["target_locale"] == locale]
            b = [row for row in candidate if row["target_locale"] == locale]
            solo = m.compare(a, b, iterations=40, seed=7)
            self.assertEqual(report["by_target_locale"][locale], solo["by_target_locale"][locale])
            self.assertEqual(report["by_target_locale"][locale]["sample_count"], 2)
        self.assertEqual(report["by_target_locale"]["es"]["delta"], 0)
        self.assertGreater(report["by_target_locale"]["fr"]["delta"], 0)

    def test_terms_require_a_list_in_both_public_reports(self):
        row = self.example()
        for terms in (None, 1, True, "aa", {"aa": True}, ("aa",)):
            bad = dict(row, terms=terms)
            with self.subTest(terms=terms):
                with self.assertRaisesRegex(ValueError, "terms must be a list"):
                    m.evaluate([bad])
                with self.assertRaisesRegex(ValueError, "terms must be a list"):
                    m.compare([row], [bad], iterations=1)
        self.assertIsNone(m.evaluate([dict(row, terms=[])])["examples"][0]["terminology"]["rate"])
        self.assertEqual(m.evaluate([dict(row, terms=["aa"])])["examples"][0]["terminology"]["rate"], 1)

    def test_terminology_public_api_rejects_noniterables_as_value_errors(self):
        for terms in (None, 1, True):
            with self.subTest(terms=terms), self.assertRaises(ValueError):
                m.terminology_hit_rate("aa", terms)


class CorpusReviewTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="synthetic-review-")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name).resolve()
        self.enterContext(patch.dict(os.environ, {c.OUTPUT_ROOT_ENV: str(self.root)}))

    def write(self, name, text):
        path = self.root / name
        path.write_text(text, encoding="utf-8", newline="")
        return path

    def meeting(self):
        texts = {"ar": "هذا مثال.", "zh": "这是例子。", "en": "An invented example.",
                 "fr": "Un exemple inventé.", "ru": "Это пример.", "es": "Un ejemplo inventado."}
        return {"schema_version": 1, "id": "S/PV.synthetic", "turn_count": 3,
                "turns": [{"index": i, "texts": dict(texts),
                           "text_status": dict.fromkeys(c.UN_LOCALES, "extracted"),
                           "original_language": "en", "original_languages": ["en"]}
                          for i in (1, 2, 3)],
                "language_note_conflicts": [{"index": 2, "language": "es",
                                             "header": "Invented conflicting note.",
                                             "header_language": "fr", "english_record_languages": ["en"],
                                             "resolution": "Keep both synthetic claims."}],
                "mapping_corrections": [{"language": "ru", "affected_english_indices": [1, 2],
                                         "raw_header_count": 2, "mapped_count": 3,
                                         "reason": "Invented split for a fixture.",
                                         "visual_evidence": "synthetic-evidence.png", "failed_alternatives": []}]}

    def test_output_configuration_is_independent_of_checkout_placement(self):
        for checkout in (self.root / "source", self.root / "nested" / "source"):
            with self.subTest(checkout=checkout), patch.object(c, "repository_root", return_value=checkout):
                self.assertEqual(c.output_root(), self.root)

    def test_output_configuration_rejects_empty_relative_and_repository_roots(self):
        for root in ("", "work/target-eval", str(c.repository_root()),
                     str(c.repository_root() / "Scripts" / "target_eval")):
            with self.subTest(root=root), patch.dict(os.environ, {c.OUTPUT_ROOT_ENV: root}), \
                    self.assertRaises(ValueError), patch.object(Path, "mkdir") as mkdir:
                c.output_root()
            mkdir.assert_not_called()

    def test_unset_output_root_rejects_both_writers_without_creation(self):
        with patch.dict(os.environ):
            os.environ.pop(c.OUTPUT_ROOT_ENV, None)
            for writer, value in ((c.write_json, {}), (c.write_jsonl, [])):
                with self.subTest(writer=writer.__name__), patch.object(Path, "mkdir") as mkdir, \
                        self.assertRaisesRegex(ValueError, f"{c.OUTPUT_ROOT_ENV} is required"):
                    writer(value, self.root / "unset" / "out.json")
                mkdir.assert_not_called()
        self.assertFalse((self.root / "unset").exists())

    def test_existing_external_output_root_can_be_configured(self):
        alternate = self.root / "alternate-output"
        alternate.mkdir()
        with patch.dict(os.environ, {c.OUTPUT_ROOT_ENV: str(alternate)}):
            self.assertEqual(c.output_root(), alternate)
            output = c.write_json({"synthetic": True}, alternate / "out.json")
        self.assertEqual(json.loads(output.read_text()), {"synthetic": True})

    def test_missing_output_root_is_rejected_without_creation(self):
        missing = self.root / "missing-output-root"
        with patch.dict(os.environ, {c.OUTPUT_ROOT_ENV: str(missing)}), patch.object(Path, "mkdir") as mkdir, \
                self.assertRaisesRegex(ValueError, "must already exist"):
            c.write_json({}, missing / "out.json")
        mkdir.assert_not_called()
        self.assertFalse(missing.exists())

    def test_file_cannot_be_configured_as_output_root(self):
        existing_file = self.write("not-a-directory", "Keep this synthetic file.")
        with patch.dict(os.environ, {c.OUTPUT_ROOT_ENV: str(existing_file)}), \
                self.assertRaisesRegex(ValueError, "directory must already exist"):
            c.output_root()
        self.assertEqual(existing_file.read_text(), "Keep this synthetic file.")

    def test_output_is_rejected_when_configured_root_lies_inside_relocated_checkout(self):
        with patch.object(c, "repository_root", return_value=self.root.parent), \
                patch.object(Path, "mkdir") as mkdir, self.assertRaisesRegex(ValueError, "repository"):
            c.write_json({}, self.root / "forbidden.json")
        mkdir.assert_not_called()

    def test_unset_root_cli_errors_precede_input_reads(self):
        output = self.root / "unset" / "report.json"
        commands = ((c.main, ["un", "--input", "must-not-be-read", "--output", str(output)],
                     c, "read_un"),
                    (m.main, ["score", "must-not-be-read", "--output", str(output)],
                     m, "read_examples"))
        with patch.dict(os.environ):
            os.environ.pop(c.OUTPUT_ROOT_ENV, None)
            for main, arguments, module, reader_name in commands:
                stderr = io.StringIO()
                with self.subTest(module=module.__name__), redirect_stderr(stderr), \
                        patch.object(module, reader_name) as reader, patch.object(Path, "mkdir") as mkdir, \
                        self.assertRaises(SystemExit) as error:
                    main(arguments)
                self.assertEqual(error.exception.code, 2)
                self.assertIn(f"{c.OUTPUT_ROOT_ENV} is required", stderr.getvalue())
                self.assertNotIn("Traceback", stderr.getvalue())
                reader.assert_not_called()
                mkdir.assert_not_called()
        self.assertFalse(output.parent.exists())

    def test_flores_accepts_lf_crlf_and_optional_single_final_newline(self):
        for ending in ("\n", "\r\n"):
            for trailing in ("", ending):
                with self.subTest(ending=ending, trailing=trailing):
                    en = self.write("en.txt", "One." + ending + "Two." + trailing)
                    fr = self.write("fr.txt", "Un." + ending + "Deux." + trailing)
                    before = en.read_bytes(), fr.read_bytes()
                    units = c.read_flores_plus({"en": en, "fr": fr})
                    self.assertEqual(len(units), 2)
                    self.assertEqual(units[1].texts, {"en": "Two.", "fr": "Deux."})
                    self.assertEqual((en.read_bytes(), fr.read_bytes()), before)

    def test_flores_rejects_other_line_separators_instead_of_realigning(self):
        for separator in ("\r", "\x0b", "\x0c", "\x1c", "\x1d", "\x1e", "\x85", "\u2028", "\u2029"):
            with self.subTest(separator=repr(separator)):
                # Equal splitlines() counts, separators at different indices.
                en = self.write("en.txt", f"One.{separator}Extra.\nTwo.\n")
                fr = self.write("fr.txt", f"Un.\nDeux.{separator}Extra.\n")
                with self.assertRaisesRegex(ValueError, "line separator"):
                    c.read_flores_plus({"en": en, "fr": fr})

    def test_flores_keeps_rejecting_multiple_trailing_or_internal_blank_lines(self):
        en = self.write("en.txt", "One.\nTwo.\n")
        for text in ("Un.\nDeux.\n\n", "Un.\n\nDeux.\n", "", "\n"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                c.read_flores_plus({"en": en, "fr": self.write("fr.txt", text)})

    def test_srt_tolerates_multiple_empty_or_whitespace_blank_lines(self):
        first = "1\n00:00:00,000 --> 00:00:01,000\nInvented\nfirst cue."
        second = "2\n00:00:01,000 --> 00:00:02,000\nInvented second cue."
        for gap in ("\n\n", "\n\n\n", "\n \n\t\n\n"):
            for ending in ("\n", "\r\n"):
                with self.subTest(gap=gap, ending=ending):
                    path = self.write("cues.srt", (first + gap + second + "\n\n").replace("\n", ending))
                    cues = c.read_srt(path)
                    self.assertEqual(cues, (c.Cue("1", 0, 1000, "Invented\nfirst cue."),
                                            c.Cue("2", 1000, 2000, "Invented second cue.")))

    def test_un_retains_matching_conflicts_and_multi_turn_corrections(self):
        data = self.meeting()
        path = self.write("turns.json", json.dumps(data, ensure_ascii=False))
        before = path.read_bytes()
        units = c.read_un_meeting(path).units
        self.assertEqual(units[0].metadata["language_note_conflicts"], [])
        self.assertEqual(units[1].metadata["language_note_conflicts"], data["language_note_conflicts"])
        for unit in units[:2]:
            self.assertEqual(unit.metadata["mapping_corrections"], data["mapping_corrections"])
        self.assertEqual(units[2].metadata["mapping_corrections"], [])
        output = self.root / "export.jsonl"
        c.write_jsonl(units, output)
        rows = [json.loads(line) for line in output.read_text().splitlines()]
        self.assertEqual(rows[1]["metadata"]["language_note_conflicts"], data["language_note_conflicts"])
        self.assertEqual(rows[0]["metadata"]["mapping_corrections"], data["mapping_corrections"])
        self.assertEqual(path.read_bytes(), before)

    def test_un_excluded_partial_turn_retains_diagnostics_and_explicit_inclusion(self):
        data = self.meeting()
        data["turns"][1]["text_status"]["ru"] = "synthetic_partial"
        path = self.write("turns.json", json.dumps(data))
        result = c.read_un_meeting(path)
        self.assertEqual(len(result.units), 2)
        self.assertEqual(result.excluded[0]["language_note_conflicts"], data["language_note_conflicts"])
        self.assertEqual(result.excluded[0]["mapping_corrections"], data["mapping_corrections"])
        result = c.read_un_meeting(path, include_partial=True)
        self.assertTrue(result.excluded[0]["included_by_request"])
        self.assertEqual(result.units[1].metadata["language_note_conflicts"], data["language_note_conflicts"])

    def test_un_rejects_bad_diagnostic_types_and_unknown_turn_selectors(self):
        variants = []
        for field in ("language_note_conflicts", "mapping_corrections"):
            for value in (None, {}, [None]):
                data = self.meeting(); data[field] = value; variants.append(data)
        for index in (None, True, 0, 4):
            data = self.meeting(); data["language_note_conflicts"][0]["index"] = index; variants.append(data)
        for indices in (None, [], "1", [True], [4]):
            data = self.meeting(); data["mapping_corrections"][0]["affected_english_indices"] = indices
            variants.append(data)
        for i, data in enumerate(variants):
            with self.subTest(i=i), self.assertRaises(ValueError):
                c.read_un_meeting(self.write("bad.json", json.dumps(data)))

    def test_cli_reports_bad_terms_without_tracebacks_or_output_creation(self):
        row = MetricReviewTests().example()
        for terms in (None, 1, True, "aa", {"aa": True}):
            with self.subTest(terms=terms):
                source = self.write("input.jsonl", json.dumps(dict(row, terms=terms)) + "\n")
                output = self.root / "report.json"
                stderr = io.StringIO()
                with redirect_stderr(stderr), self.assertRaises(SystemExit) as error:
                    m.main(["score", str(source), "--output", str(output)])
                self.assertEqual(error.exception.code, 2)
                self.assertIn("terms must be a list", stderr.getvalue())
                self.assertNotIn("Traceback", stderr.getvalue())
                self.assertFalse(output.exists())

    def test_cli_preserves_per_target_score_and_bootstrap_groups(self):
        rows = [MetricReviewTests().example("fr"), MetricReviewTests().example("es", target="es")]
        source = self.write("input.jsonl", "".join(json.dumps(row) + "\n" for row in rows))
        score, comparison = self.root / "score.json", self.root / "comparison.json"
        self.assertEqual(m.main(["score", str(source), "--output", str(score)]), 0)
        self.assertEqual(m.main(["compare", str(source), str(source), "--iterations", "4",
                                 "--output", str(comparison)]), 0)
        for report in (json.loads(score.read_text()), json.loads(comparison.read_text())):
            self.assertEqual(set(report["by_target_locale"]), {"es", "fr"})
            self.assertNotIn("chrfpp", report)
            self.assertNotIn("delta", report)

    def test_un_cli_exports_conflict_and_correction_fields(self):
        data = self.meeting()
        meeting_dir = self.root / "S_PV.synthetic"
        meeting_dir.mkdir()
        (meeting_dir / "turns.json").write_text(json.dumps(data), encoding="utf-8")
        output = self.root / "un.jsonl"
        with redirect_stdout(io.StringIO()):
            self.assertEqual(c.main(["un", "--input", str(self.root), "--output", str(output)]), 0)
        rows = [json.loads(line) for line in output.read_text().splitlines()]
        self.assertEqual(rows[1]["metadata"]["language_note_conflicts"], data["language_note_conflicts"])
        self.assertEqual(rows[1]["metadata"]["mapping_corrections"], data["mapping_corrections"])
