"""Short synthetic source-unit cases; no model, network or disk writes."""
from __future__ import annotations

import copy
import importlib.util
import json
from pathlib import Path
import re
import sys
import unittest
from unittest.mock import patch

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

    def test_english_source_units_keep_frozen_bytes(self):
        units = self.units(0, [("en", ["Ice is cold."]), ("zh", ["冰很冷。"])])
        expected = ('{"en0s0":{"id":"en0s0","index":0,"language":"en","text":"Ice is cold."},'
                    '"zh0s0":{"id":"zh0s0","index":0,"language":"zh","text":"冰很冷。"}}').encode("utf-8")
        for marker in ({}, {"sourceLanguage": "en"}):
            evidence = [{"english": "  Ice is cold.\n", "chinese": "\t冰很冷。  ", **marker}]
            original = copy.deepcopy(evidence)
            with self.subTest(marker=marker), patch.object(scorer, "render_pass_through") as normalizer:
                actual = scorer.verify_units(units, evidence)
                self.assertEqual(json.dumps(actual, ensure_ascii=False, separators=(",", ":")).encode("utf-8"), expected)
                normalizer.assert_not_called()
                self.assertEqual(evidence, original)

    def test_chinese_prefers_usable_target_caption(self):
        evidence = [{"english": "冰很冷。", "chinese": "另一段译文。", "sourceLanguage": "zh"}]
        units = self.units(0, [("zh", ["另一段译文。"])])
        with patch.object(scorer, "render_pass_through") as normalizer:
            self.assertEqual(list(scorer.verify_units(units, evidence)), ["zh0s0"])
            normalizer.assert_not_called()

    def test_traditional_source_uses_frozen_simplified_target(self):
        evidence = [{"english": "這片葉子長大了。", "chinese": "这片叶子长大了。",
                     "sourceLanguage": "zh", "translationState": "completed"}]
        original = copy.deepcopy(evidence)
        units = self.units(0, [("zh", ["这片叶子长大了。"])])
        self.assertEqual(list(scorer.verify_units(units, evidence)), ["zh0s0"])
        with self.assertRaisesRegex(ValueError, "source-unit-body-or-order"):
            scorer.verify_units(self.units(0, [("zh", ["這片葉子長大了。"])]), evidence)
        self.assertEqual(evidence, original)

    @unittest.skipUnless(sys.platform == "darwin", "requires the same system transform as Swift")
    def test_chinese_without_usable_target_normalizes_source(self):
        for stored in ({}, {"chinese": ""}, {"chinese": " \t\n"},
                       {"chinese": "旧译文。", "translationState": "pending"},
                       {"chinese": "旧译文。", "translationState": "translating"},
                       {"chinese": "旧译文。", "translationState": "failed"},
                       {"chinese": "[翻译失败：测试诊断]"}):
            with self.subTest(stored=stored):
                evidence = [{"english": "這個實驗需要兩個容器。", "sourceLanguage": "zh", **stored}]
                original = copy.deepcopy(evidence)
                units = self.units(0, [("zh", ["这个实验需要两个容器。"])])
                self.assertEqual(list(scorer.verify_units(units, evidence)), ["zh0s0"])
                self.assertEqual(evidence, original)

    @unittest.skipUnless(sys.platform == "darwin", "requires the same system transform as Swift")
    def test_system_normalizer_preserves_other_scalars_and_nul(self):
        self.assertEqual(scorer.render_pass_through("\t這片葉子長大了。 Fe³⁺ 🧪 e\u0301\x00\n"),
                         "\t这片叶子长大了。 Fe³⁺ 🧪 e\u0301\x00\n")

    def test_unavailable_normalizer_withholds_integrity_credit(self):
        evidence = [{"english": "這片葉子長大了。", "chinese": "", "sourceLanguage": "zh"}]
        units = self.units(0, [("zh", ["这片叶子长大了。"])])
        with patch.object(scorer.sys, "platform", "unavailable"), \
                self.assertRaisesRegex(ValueError, "pass-through-normalizer-unavailable"):
            scorer.verify_units(units, evidence)

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

    def test_unknown_and_explicit_english_markers_never_infer_chinese(self):
        for language in ("xx", "zxx", "zh-Hans", "ZH", "", "en"):
            with self.subTest(language=language):
                evidence = [{"english": "冰很冷。", "chinese": "冰很冷。", "sourceLanguage": language}]
                units = self.units(0, [("en", ["冰很冷。"]), ("zh", ["冰很冷。"])])
                self.assertIsNone(scorer.source_language(evidence[0]))
                self.assertEqual(list(scorer.verify_units(units, evidence)), ["en0s0", "zh0s0"])
                with self.assertRaisesRegex(ValueError, "missing-source-language"):
                    scorer.verify_units(self.units(0, [("zh", ["冰很冷。"])]), evidence)

    def test_every_supported_non_english_language_uses_one_target_group(self):
        for language in sorted(scorer.SPOKEN_LANGUAGE_CODES - {"en"}):
            with self.subTest(language=language):
                evidence = [{"english": "Source.", "chinese": "目标句。", "sourceLanguage": language}]
                self.assertEqual(list(scorer.verify_units(self.units(0, [("zh", ["目标句。"])]), evidence)), ["zh0s0"])

    def test_legacy_inference_requires_completed_identical_usable_text(self):
        for state in (None, "completed"):
            source = {"english": "冰很冷。", "chinese": "冰很冷。", "translationState": state}
            self.assertEqual(scorer.source_language(source), "zh")
        for state in ("pending", "translating", "failed"):
            source = {"english": "冰很冷。", "chinese": "冰很冷。", "translationState": state}
            self.assertIsNone(scorer.source_language(source))
        self.assertIsNone(scorer.source_language({"english": "冰很冷。", "chinese": "水很冷。"}))
        self.assertIsNone(scorer.source_language({"english": "[翻译失败：测试]", "chinese": "[翻译失败：测试]"}))

    def test_legacy_inference_keeps_minimum_and_ratio_boundaries(self):
        for text, expected in (("冰aaaaa", "zh"), ("冰aaaaaa", None),
                               ("冰冰aaaaa", "zh"), ("冰冰aaaaaa", None),
                               ("冰冰冰aaaaaaaa", "zh"), ("冰冰冰aaaaaaaaa", None),
                               ("冰ĀĀĀĀĀĀ", None), ("冰ɐɐɐɐɐɐ", "zh"),
                               ("123。", None), ("...", None), ("", None)):
            with self.subTest(text=text):
                self.assertEqual(scorer.source_language({"english": text, "chinese": text}), expected)

    def test_legacy_inference_keeps_swift_scalar_boundaries(self):
        for scalar in (0x3400, 0x4DBF, 0x4E00, 0x9FFF, 0xF900, 0xFAFF):
            text = chr(scalar)
            with self.subTest(scalar=scalar):
                self.assertEqual(scorer.source_language({"english": text, "chinese": text}), "zh")
        for scalar in (0x33FF, 0x4DC0, 0xA000, 0xF8FF, 0xFB00, 0x20000, 0x30000):
            text = chr(scalar)
            with self.subTest(scalar=scalar):
                self.assertIsNone(scorer.source_language({"english": text, "chinese": text}))
        for scalar in (0x0041, 0x005A, 0x0061, 0x007A, 0x00C0, 0x024F, 0x1E00, 0x1EFF):
            text = "冰" + chr(scalar) * 6
            with self.subTest(latin_scalar=scalar):
                self.assertIsNone(scorer.source_language({"english": text, "chinese": text}))

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


class SwiftSourcePolicyParityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        sources = Path(__file__).resolve().parent.parent / "LiveLingo" / "Sources"
        cls.languages = (sources / "SpokenLanguage.swift").read_text()
        cls.runtime = (sources / "QwenRuntime.swift").read_text()
        cls.segment = (sources / "TranscriptSegment.swift").read_text()
        cls.app_model = (sources / "AppModel.swift").read_text()

    def test_supported_codes_match_swift_whitelist(self):
        codes = re.findall(r'\.init\(code:\s*"([^"]+)"', self.languages)
        self.assertEqual(len(codes), 30)
        self.assertEqual(scorer.SPOKEN_LANGUAGE_CODES, frozenset(codes))
        self.assertRegex(self.languages, r'guard let language = find\(code\), language\.code != "en"')

    def test_caption_target_and_pass_through_match_swift(self):
        target = self.runtime.split("enum CaptionTranslationTarget:", 1)[1].split("struct ", 1)[0]
        current = re.search(r"static let current = Self\.(\w+)", target).group(1)
        locale = re.search(r'case ' + re.escape(current) + r' = "([^"]+)"', target).group(1)
        policy = target.split("func keepsSourceAsCaption", 1)[1].split("func renderPassThrough", 1)[0]
        self.assertEqual(scorer.CAPTION_TRANSLATION_TARGET, locale)
        self.assertEqual(scorer.CAPTION_PASS_THROUGH_LANGUAGE_CODES,
                         frozenset(re.findall(r'language == "([^"]+)"', policy)))
        transform = re.search(r'traditionalToSimplified = StringTransform\("([^"]+)"\)', self.app_model).group(1)
        self.assertEqual(scorer.CAPTION_PASS_THROUGH_TRANSFORM, transform)

    def test_legacy_inference_ranges_and_thresholds_match_swift(self):
        gate = self.runtime.split("enum EnglishTranscriptGate", 1)[1].split("struct AuxiliaryTranscriptObservation", 1)[0]
        ranges = {}
        for values, count in re.findall(r"case\s+([0-9xA-Fa-f.,\s]+):\s*(latinCount|cjkCount)\s*\+=\s*1", gate):
            ranges[count] = tuple((int(start, 16), int(end, 16))
                                  for start, end in re.findall(r"(0x[0-9A-Fa-f]+)\.\.\.(0x[0-9A-Fa-f]+)", values))
        self.assertEqual(scorer.LEGACY_HAN_RANGES, ranges["cjkCount"])
        self.assertEqual(scorer.LEGACY_LATIN_RANGES, ranges["latinCount"])
        minimum, ratio = re.search(r"latinCount >= max\((\d+), cjkCount \* (\d+)\)", gate).groups()
        self.assertEqual((scorer.LEGACY_MIN_LATIN_COUNT, scorer.LEGACY_LATIN_PER_HAN), (int(minimum), int(ratio)))
        self.assertRegex(self.segment, r"if storedLanguage == nil,\s*translationState == \.completed,\s*english == chinese,\s*"
                                      r"EnglishTranscriptGate\.verdict\(english\) == \.hanDominant")


if __name__ == "__main__":
    unittest.main()
