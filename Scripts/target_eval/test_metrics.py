"""Hand-computed metrics and self-authored multilingual examples only."""
from contextlib import redirect_stderr
from fractions import Fraction
import io
import json
from pathlib import Path
import random
import tempfile
import unittest
from unittest.mock import patch

from Scripts.target_eval import corpora as c
from Scripts.target_eval import metrics as m


class MetricsTests(unittest.TestCase):
    def test_chrf_exact_mismatch_empty_and_short_effective_orders(self):
        self.assertEqual(m.chrf("例子", "例子"), 100)
        self.assertEqual(m.chrf("a", "a"), 100)
        self.assertEqual(m.chrf("a", "b"), 0)
        for hyp, ref in (("", ""), ("", "a"), ("a", ""), (" \n", "\t")):
            with self.subTest(hyp=hyp, ref=ref):
                self.assertEqual(m.chrf(hyp, ref), 0)

    def test_chrf_two_orders_agree_with_hand_count(self):
        # ab/ac: unigrams 1/2, bigrams 0/1; P=R=(1/2+0)/2=1/4.
        self.assertEqual(m.chrf_statistics("ab", "ac", char_order=2), ((2, 2, 1), (1, 1, 0)))
        self.assertEqual(m.chrf("ab", "ac", char_order=2), 25)

    def test_chrf_clipped_repetitions_and_asymmetric_beta_agree_with_hand_count(self):
        # aab/ab: P=(2/3+1/2)/2=7/12, R=(1+1)/2=1.
        # F2=5*(7/12)/(4*(7/12)+1)=7/8; F1=14/19.
        self.assertEqual(m.chrf_statistics("aab", "ab", char_order=2), ((3, 2, 2), (2, 1, 1)))
        self.assertAlmostEqual(m.chrf("aab", "ab"), 100 * float(Fraction(7, 8)))
        self.assertAlmostEqual(m.chrf("aab", "ab", beta=1), 100 * float(Fraction(14, 19)))

    def test_chrfpp_word_orders_agree_with_hand_count(self):
        # ab cd/ab ce: char P=R=3/4,2/3; word P=R=1/2,0.
        self.assertAlmostEqual(m.chrf("ab cd", "ab ce", char_order=2), 100 * float(Fraction(17, 24)))
        self.assertAlmostEqual(m.chrfpp("ab cd", "ab ce", char_order=2), 100 * float(Fraction(23, 48)))

    def test_chrfpp_edge_punctuation_is_word_tokenized_internal_apostrophe_retained(self):
        stats = m.chrf_statistics("(can't),", "can't", char_order=1, word_order=2)
        # One punctuation character is detached at each edge: (, can't), ,.
        self.assertEqual(stats[1:], ((3, 1, 0), (2, 0, 0)))
        stats = m.chrf_statistics("(can't)", "can't", char_order=1, word_order=2)
        self.assertEqual(stats[1:], ((3, 1, 1), (2, 0, 0)))

    def test_chrf_case_whitespace_and_diacritics_are_explicit(self):
        self.assertEqual(m.chrf("a b\n", "ab"), 100)
        self.assertLess(m.chrf("a b", "ab", whitespace=True), 100)
        self.assertEqual(m.chrf("É", "é", lowercase=True), 100)
        self.assertEqual(m.chrf("é", "e"), 0)
        self.assertEqual(m.chrf("A", "a"), 0)

    def test_corpus_chrf_pools_counts_instead_of_averaging_sentence_scores(self):
        # P=1/1, R=1/5, F2=5/21; sentence-score average would be 50.
        self.assertAlmostEqual(m.corpus_chrf(["a", ""], ["a", "bbbb"], char_order=1),
                               100 * float(Fraction(5, 21)))
        self.assertEqual(m.corpus_chrf([], []), 0)
        self.assertEqual(m.corpus_chrfpp(["A word."], ["A word."]), 100)
        with self.assertRaises(ValueError):
            m.corpus_chrf(["a"], [])

    def test_chrf_invalid_settings_fail(self):
        for kwargs in ({"char_order": 0}, {"char_order": True}, {"word_order": -1},
                       {"beta": 0}, {"beta": float("nan")}, {"beta": float("inf")}):
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError):
                m.chrf("a", "a", **kwargs)

    def test_terminology_counts_concepts_alternatives_and_diacritics(self):
        result = m.terminology_hit_rate("La VITESSE et l'énergie; DNA分子。",
                                        [["velocidad", "vitesse"], "énergie", "DNA", "mass"])
        self.assertEqual(result["hit_count"], 3)
        self.assertEqual(result["term_count"], 4)
        self.assertEqual(result["rate"], 0.75)
        self.assertEqual(result["missing_terms"], [["mass"]])
        self.assertEqual(m.terminology_hit_rate("學習速率。", ["速率"])["rate"], 1)
        self.assertEqual(m.terminology_hit_rate("e\u0301nergie", ["énergie"])["rate"], 1)

    def test_terminology_does_not_hit_longer_latin_words_or_erase_accents(self):
        result = m.terminology_hit_rate("motion énergíe xDNA DNA2", ["ion", "énergie", "DNA"])
        self.assertEqual(result["rate"], 0)
        self.assertIsNone(m.terminology_hit_rate("anything", [])["rate"])
        for terms in ([""], [[]], [["ok", " "]], "DNA", {"DNA": True}, [3]):
            with self.subTest(terms=terms), self.assertRaises(ValueError):
                m.terminology_hit_rate("anything", terms)

    def test_traditional_purity_counts_residue_separately_from_script(self):
        result = m.text_purity("学習かな한DNA 7.4", "zh-Hant-TW", simplified_only_chars={"学"})
        self.assertEqual(result["script_counts"], {"han": 2, "kana": 2, "hangul": 1,
                                                  "latin": 3, "cyrillic": 0, "arabic": 0, "other": 0})
        self.assertEqual(result["letter_count"], 8)
        self.assertEqual(result["forbidden_letter_count"], 3)
        self.assertEqual(result["script_purity"], 5 / 8)
        self.assertEqual(result["simplified_residue_count"], 1)
        self.assertEqual(result["simplified_residue_rate"], 0.5)

    def test_missing_simplified_inventory_is_unknown_and_shared_characters_not_assumed_wrong(self):
        self.assertIsNone(m.text_purity("皇后学习", "zh-Hant-HK")["simplified_residue_count"])
        self.assertEqual(m.text_purity("皇后學習", "zh-Hant-HK", simplified_only_chars={"学"})
                         ["simplified_residue_count"], 0)
        self.assertIsNone(m.text_purity("123", "en")["script_purity"])
        self.assertIsNone(m.text_purity("学", "zh-Hans", simplified_only_chars={"学"})
                          ["simplified_residue_count"])

    def test_latin_purity_keeps_accents_counts_nonlatin_and_ignores_combining_marks(self):
        result = m.text_purity("a\u0301漢か한", "fr")
        self.assertEqual(result["letter_count"], 4)
        self.assertEqual(result["script_purity"], 0.25)
        self.assertEqual(m.text_purity("𠀀〇ｶㄱ", "en")["script_counts"]["han"], 2)
        self.assertEqual(m.text_purity("𠀀〇ｶㄱ", "en")["script_counts"]["kana"], 1)
        self.assertEqual(m.text_purity("𠀀〇ｶㄱ", "en")["script_counts"]["hangul"], 1)
        self.assertEqual(m.text_purity("Пример DNA", "ru")["script_purity"], 1)
        self.assertEqual(m.text_purity("مثال DNA", "ar")["script_purity"], 1)
        with self.assertRaises(ValueError):
            m.text_purity("test", "unknown")
        with self.assertRaises(ValueError):
            m.text_purity("學", "zh-Hant", simplified_only_chars={"學習"})
        with self.assertRaises(ValueError):
            m.text_purity("學", "zh-Hant", simplified_only_chars=set())

    def test_lengths_report_measured_units_zero_denominators_unknown(self):
        self.assertEqual(m.length_ratio("a b", "例 子 !"),
                         {"unit": "characters", "source_count": 2, "target_count": 3, "ratio": 1.5})
        self.assertEqual(m.length_ratio("a 1!", "é b", unit="letters")["ratio"], 2)
        self.assertIsNone(m.length_ratio(" ", "text")["ratio"])
        with self.assertRaises(ValueError):
            m.length_ratio("a", "a", unit="tokens")

    def test_token_ratios_use_only_provided_integer_counts(self):
        self.assertEqual(m.token_ratio(4, 6), {"source_tokens": 4, "target_tokens": 6, "ratio": 1.5})
        self.assertIsNone(m.token_ratio(0, 0)["ratio"])
        for value in (-1, True, 1.5, float("nan"), float("inf")):
            with self.subTest(value=value), self.assertRaises(ValueError):
                m.token_ratio(value, 2)

    def test_bootstrap_is_paired_constant_offset_has_exact_interval(self):
        result = m.paired_bootstrap([0, 100, 1000], [2, 102, 1002], iterations=50, seed=11)
        self.assertEqual(result["delta"], 2)
        self.assertEqual(result["ci_low"], 2)
        self.assertEqual(result["ci_high"], 2)
        self.assertEqual(result["direction"], "candidate-minus-baseline")
        self.assertEqual(result["confidence"], 0.95)

    def test_bootstrap_fixed_seed_reproducible_without_changing_global_random_state(self):
        state = random.getstate()
        first = m.paired_bootstrap([1, 3, 7], [4, 1, 15], iterations=100, seed=7)
        self.assertEqual(first, m.paired_bootstrap([1, 3, 7], [4, 1, 15], iterations=100, seed=7))
        self.assertEqual(state, random.getstate())
        self.assertEqual(first["delta"], 3)

    def test_bootstrap_identical_routes_and_single_pair(self):
        self.assertEqual(m.paired_bootstrap([3], [1], iterations=5)["ci_high"], -2)
        result = m.paired_bootstrap([1, 2], [1, 2], iterations=5)
        self.assertEqual((result["delta"], result["ci_low"], result["ci_high"]), (0, 0, 0))

    def test_bootstrap_percentile_interval_matches_hand_interpolation(self):
        # Seed 0 draws index pairs [1,1], [0,1], [1,1], [1,1].
        # Differences [0,4] give sorted means [2,4,4,4]. At 95%,
        # lower rank=(4-1)*.025=.075, so lower=2+(4-2)*.075=2.15.
        result = m.paired_bootstrap([1, 7], [1, 11], iterations=4, seed=0)
        self.assertEqual(result["delta"], 2)
        self.assertAlmostEqual(result["ci_low"], 2.15)
        self.assertEqual(result["ci_high"], 4)

    def test_bootstrap_rejects_invalid_counts_data_confidence_and_seed(self):
        for baseline, candidate, kwargs in (([], [], {}), ([1], [1, 2], {}),
                ([float("nan")], [1], {}), ([True], [1], {}), ([1], [2], {"iterations": 0}),
                ([1], [2], {"confidence": 1}), ([1], [2], {"confidence": float("inf")}),
                ([1], [2], {"seed": True})):
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError):
                m.paired_bootstrap(baseline, candidate, **kwargs)

    def test_corpus_bootstrap_recomputes_pooled_score(self):
        result = m.paired_bootstrap_chrf(["a", ""], ["a", "bbbb"], ["a", "bbbb"],
                                         char_order=1, word_order=0, iterations=100, seed=0)
        self.assertAlmostEqual(result["delta"], 100 * float(Fraction(16, 21)))
        self.assertEqual((result["ci_low"], result["ci_high"]), (0, 100))
        self.assertEqual(result, m.paired_bootstrap_chrf(["a", ""], ["a", "bbbb"], ["a", "bbbb"],
                         char_order=1, word_order=0, iterations=100, seed=0))
        with self.assertRaises(ValueError):
            m.paired_bootstrap_chrf(["a"], ["a"], [])

    def example(self, identity="one", hypothesis="Un exemple."):
        return {"id": identity, "source": "An example.", "reference": "Un exemple.",
                "hypothesis": hypothesis, "source_locale": "en", "target_locale": "fr"}

    def test_report_uses_corpus_scores_and_keeps_unknown_token_counts(self):
        row = self.example()
        row["terms"] = ["exemple"]
        report = m.evaluate([row])
        self.assertEqual(report["sample_count"], 1)
        self.assertEqual(report["chrfpp"], 100)
        self.assertIsNone(report["examples"][0]["tokens"])
        self.assertEqual(report["examples"][0]["terminology"]["rate"], 1)
        self.assertNotIn("source", report["examples"][0])
        row["source_tokens"], row["hypothesis_tokens"] = 4, 6
        self.assertEqual(m.evaluate([row])["examples"][0]["tokens"]["ratio"], 1.5)
        del row["hypothesis_tokens"]
        with self.assertRaises(ValueError):
            m.evaluate([row])

    def test_report_rejects_empty_or_duplicate_examples_in_public_api(self):
        for examples in ([], [self.example(), self.example()], [dict(self.example(), reference=" ")]):
            with self.subTest(examples=examples), self.assertRaises(ValueError):
                m.evaluate(examples)

    def test_compare_pairs_by_id_across_order_and_rejects_unmatched_or_different_reference(self):
        rows = [self.example("one"), self.example("two", "Un autre.")]
        result = m.compare(rows, rows[::-1], iterations=10)
        self.assertEqual(result["delta"], 0)
        self.assertEqual(result["example_ids"], ["one", "two"])
        for bad in (rows[:1], [rows[0], rows[0]], [dict(rows[0], reference="Autre."), rows[1]]):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                m.compare(rows, bad, iterations=10)


class MetricCLITests(unittest.TestCase):
    def setUp(self):
        c.validate_output_path(c.output_root() / "fixture-sentinel")
        c.output_root().mkdir(parents=True, exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(prefix="synthetic-metrics-", dir=c.output_root())
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.row = {"id": "synthetic:1", "source": "One example.", "reference": "Un exemple.",
                    "hypothesis": "Un exemple.", "source_locale": "en", "target_locale": "fr"}

    def fixture(self, name, rows):
        path = self.root / name
        path.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")
        return path

    def test_score_and_compare_cli_roundtrip_on_synthetic_rows(self):
        source = self.fixture("input.jsonl", [self.row])
        original = source.read_bytes()
        report = self.root / "report.json"
        self.assertEqual(m.main(["score", str(source), "--output", str(report)]), 0)
        self.assertEqual(json.loads(report.read_text())["chrfpp"], 100)
        comparison = self.root / "comparison.json"
        self.assertEqual(m.main(["compare", str(source), str(source), "--iterations", "10",
                                 "--output", str(comparison)]), 0)
        self.assertEqual(json.loads(comparison.read_text())["delta"], 0)
        self.assertEqual(source.read_bytes(), original)

    def test_read_examples_rejects_duplicate_blank_and_missing_fields(self):
        bad_rows = [[self.row, self.row], [dict(self.row, id=None)], [{"id": "missing"}], [None], []]
        for i, rows in enumerate(bad_rows):
            with self.subTest(i=i), self.assertRaises(ValueError):
                m.read_examples(self.fixture(f"bad-{i}.jsonl", rows))
        path = self.root / "blank.jsonl"
        path.write_text("\n", encoding="utf-8")
        with self.assertRaises(ValueError):
            m.read_examples(path)

    def test_cli_output_validation_precedes_input_read_and_never_overwrites(self):
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as exit_code, \
                patch.object(m, "read_examples") as reader:
            m.main(["score", "must-not-be-read", "--output", str(c.repository_root() / "forbidden.json")])
        self.assertEqual(exit_code.exception.code, 2)
        reader.assert_not_called()
        source = self.fixture("input.jsonl", [self.row])
        report = self.root / "existing.json"
        report.write_text("keep original", encoding="utf-8")
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as exit_code:
            m.main(["score", str(source), "--output", str(report)])
        self.assertEqual(exit_code.exception.code, 2)
        self.assertEqual(report.read_text(), "keep original")


if __name__ == "__main__":
    unittest.main()
