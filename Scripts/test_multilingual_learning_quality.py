"""Short synthetic source-unit cases; no model, network or disk writes."""
from __future__ import annotations

import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "multilingual_learning_scorer", Path(__file__).with_name("evaluate-learning-quality.py"))
scorer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scorer)


class MultilingualSourceUnitTests(unittest.TestCase):
    @staticmethod
    def units(index, texts):
        return [{"id": f"{language}{index}s{number}", "index": index,
                 "language": language, "text": text}
                for language, parts in texts for number, text in enumerate(parts)]

    def test_english_still_requires_both_complete_groups(self):
        evidence = [{"english": "Ice is cold.", "chinese": "冰很冷。"}]
        units = self.units(0, [("en", ["Ice is cold."]), ("zh", ["冰很冷。"])])
        self.assertEqual(list(scorer.verify_units(units, evidence)), ["en0s0", "zh0s0"])
        for missing in ("en", "zh"):
            with self.subTest(missing=missing), self.assertRaisesRegex(ValueError, "missing-source-language"):
                scorer.verify_units([x for x in units if x["language"] != missing], evidence)

    def test_chinese_uses_original_only(self):
        evidence = [{"english": "冰很冷。", "chinese": "另一段译文。", "sourceLanguage": "zh"}]
        units = self.units(0, [("zh", ["冰很冷。"])])
        self.assertEqual(list(scorer.verify_units(units, evidence)), ["zh0s0"])

    def test_spanish_and_cantonese_use_translation_only(self):
        for language, original in [("es", "El agua fluye."), ("yue", "水會流㗎。")]:
            with self.subTest(language=language):
                evidence = [{"english": original, "chinese": "水会流动。", "sourceLanguage": language}]
                units = self.units(0, [("zh", ["水会流动。"])])
                self.assertEqual(list(scorer.verify_units(units, evidence)), ["zh0s0"])

    def test_legacy_chinese_marker_absence_is_supported(self):
        evidence = [{"english": "冰很冷。", "chinese": "冰很冷。"}]
        units = self.units(0, [("zh", ["冰很冷。"])])
        self.assertEqual(list(scorer.verify_units(units, evidence)), ["zh0s0"])

    def test_identical_english_or_latin_dominant_text_is_not_chinese_inference(self):
        for text in ["Ice is cold.", "This is a lengthy English sentence with 冰."]:
            with self.subTest(text=text), self.assertRaisesRegex(ValueError, "missing-source-language"):
                scorer.verify_units(self.units(0, [("zh", [text])]), [{"english": text, "chinese": text}])

    def test_mixed_units_keep_order_and_cover_every_target_character(self):
        evidence = [{"english": "Ice is cold.", "chinese": "冰很冷。"},
                    {"english": "冰很冷。水会流动。", "chinese": "冰很冷。水会流动。", "sourceLanguage": "zh"},
                    {"english": "El agua fluye.", "chinese": "水会流动。", "sourceLanguage": "es"}]
        units = self.units(0, [("en", ["Ice is cold."]), ("zh", ["冰很冷。"])]) \
            + self.units(1, [("zh", ["冰很冷。", "水会流动。"])]) \
            + self.units(2, [("zh", ["水会流动。"])])
        self.assertEqual(list(scorer.verify_units(units, evidence)), [x["id"] for x in units])
        for mutation in ("drop", "body", "order", "extra-source"):
            changed = copy.deepcopy(units)
            if mutation == "drop": changed.pop(3)
            elif mutation == "body": changed[2]["text"] = "另一句话。"
            elif mutation == "order": changed.reverse()
            else: changed += self.units(2, [("en", ["El agua fluye."])])
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                scorer.verify_units(changed, evidence)


if __name__ == "__main__":
    unittest.main()
