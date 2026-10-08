"""Numeric binding regressions using protocol-2 artifacts, without model execution."""
from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "numeric_review_scorer", Path(__file__).with_name("evaluate-learning-quality.py"))
scorer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scorer)


MISSING_TEMPERATURE = "正文里的“20°C”在本次原文里找不到；请人工确认它对应的对象、条件和来源。"
OTHER_TEMPERATURE = ("正文里的“20°C”不在所引原句里；本次原文的其他句子出现过同样的数值，"
                     "请确认是否该把那一句也列为来源。")


class NumericTargetBindingTests(unittest.TestCase):
    def probe(self, rows, *, target, state, gap=None, fragments=None):
        """Write independent expected binding; never derive it with numeric_report."""
        temporary = tempfile.TemporaryDirectory(prefix='numeric-review-')
        self.addCleanup(temporary.cleanup)
        directory = Path(temporary.name)

        def write(name, value):
            data = json.dumps(value, ensure_ascii=False).encode()
            (directory / name).write_bytes(data)
            return hashlib.sha256(data).hexdigest()

        case = {"id": "numeric-target-binding", "stages": [rows]}
        fixture_sha = write("fixture.json", case)
        evidence = scorer.frozen_sources(case, 1)
        for source, row in zip(evidence, rows):
            source["translationState"] = "completed"
            if "sourceLanguage" in row:
                source["sourceLanguage"] = row["sourceLanguage"]
        units = []
        for index, row in enumerate(rows):
            if target == "en":
                field = "english" if row.get("sourceLanguage") in (None, "en") else "chinese"
                groups = [("en", field)]
            else:
                groups = ([("en", "english"), ("zh", "chinese")]
                          if row.get("sourceLanguage") in (None, "en") else [("zh", "chinese")])
            for language, field in groups:
                parts = fragments if index == 0 and language == "en" and fragments else [row[field]]
                units.extend({"id": f"{language}{index}s{number}", "index": index,
                              "language": language, "text": text}
                             for number, text in enumerate(parts))
        source_id = "en0s0" if target == "en" or rows[0].get("sourceLanguage") in (None, "en") else "zh0s0"
        quote = next(unit["text"] for unit in units if unit["id"] == source_id)
        raw = {"sourceVersion": 2, "topic": "Temperature", "noNewKnowledge": False,
               "points": [{"kind": "核心结论", "text": "The temperature is 20 °C.",
                           "sourceIDs": [source_id], "needsContext": None}], "followUps": {}}
        normal = copy.deepcopy(raw)
        normal.pop("followUps")
        normal["points"][0].pop("needsContext")
        note = copy.deepcopy(normal)
        note["points"][0].update({"sources": [{"index": 0, "quote": quote}], "referenceState": state})
        if state == "numericDifference":
            note["points"][0]["needsContext"] = scorer.NUMERIC_CONTEXT
        if gap is not None:
            note["points"][0]["numericGap"] = gap
        batch_id = "11111111-1111-1111-1111-111111111111"
        markdown = "## Temperature\n- The temperature is 20 °C."
        (directory / "notes-stage-1.md").write_text(markdown, encoding="utf-8")
        result = {
            "probeVersion": 2, "fixtureID": case["id"], "fixtureSHA256": fixture_sha,
            "model": "synthetic-numeric-regression",
            "producer": {"targetLocale": target, "executableSHA256": "a" * 64,
                         "promptSHA256": "b" * 64, "generationOrigin": "synthetic-regression",
                         "sourceRepresentation": "revisioned", "sourcePolicy": scorer.SOURCE_POLICY,
                         "displayContract": scorer.DISPLAY_CONTRACT, "batchCharacters": 4000},
            "requestedRequests": 1, "successfulRequests": 1,
            "requests": [{"number": 1, "stage": 1, "batchID": batch_id, "evidence": evidence,
                          "sourceUnits": units, "pendingTargets": [], "outcome": "committed",
                          "inputFile": "input-1.json", "responseFile": "response-1.txt",
                          "inputSHA256": write("input-1.json", {"evidence": units, "pendingPoints": []}),
                          "responseSHA256": write("response-1.txt", raw), "normalizedNote": normal}],
            "stages": [{"number": 1, "elapsedSeconds": 0,
                        "batches": [{"id": batch_id, "evidence": evidence, "note": note}],
                        "coveredSourceIDs": [source["id"] for source in evidence],
                        "requestedRequests": 1, "successfulRequests": 1,
                        "markdown": markdown, "latestMarkdown": markdown,
                        "displayPoints": [{"reference": f"{batch_id}:0", "hasOpenQuestion": False,
                                           "fullDisposition": "body", "latestDisposition": "body",
                                           "renderedLine": "- The temperature is 20 °C."}]}]}
        write("result.json", result)
        return case, result, directory, fixture_sha

    def check(self, rows, *, target, state, gap=None, fragments=None):
        case, result, directory, fixture_sha = self.probe(
            rows, target=target, state=state, gap=gap, fragments=fragments)
        verified = scorer.verify_result(case, result, directory, fixture_sha,
                                        allow_synthetic=True, target=target)
        self.assertEqual(len(verified), 1)
        self.assertEqual(len(verified[0]["points"]), 1)
        point = verified[0]["points"][0]
        self.assertEqual(point["referenceState"], state)
        self.assertEqual(point.get("numericGap"), gap)
        self.assertEqual(point.get("needsContext"), scorer.NUMERIC_CONTEXT if state == "numericDifference" else None)
        self.assertTrue(point["eligibleBodySignal"])

    def test_english_ignores_stale_counterpart_in_own_segment(self):
        for language in (None, "en"):
            with self.subTest(sourceLanguage=language):
                self.check([{"english": "The temperature is 10 °C.", "chinese": "温度是 20 °C。",
                             "sourceLanguage": language}],
                           target="en", state="numericDifference", gap=MISSING_TEMPERATURE)

    def test_english_ignores_stale_counterpart_in_other_segment(self):
        self.check([{"english": "The temperature is 10 °C.", "chinese": "温度是 10 °C。"},
                    {"english": "The pressure is 5 Pa.", "chinese": "温度是 20 °C。"}],
                   target="en", state="numericDifference", gap=MISSING_TEMPERATURE)

    def test_english_ignores_foreign_source_in_own_segment(self):
        for language, original in (("zh", "温度是 20 °C。"), ("es", "La temperatura es 20 °C.")):
            with self.subTest(sourceLanguage=language):
                self.check([{"english": original, "chinese": "The temperature is 10 °C.",
                             "sourceLanguage": language}],
                           target="en", state="numericDifference", gap=MISSING_TEMPERATURE)

    def test_english_ignores_foreign_source_in_other_segment(self):
        self.check([{"english": "The temperature is 10 °C.", "chinese": "温度是 10 °C。"},
                    {"english": "温度是 20 °C。", "chinese": "The pressure is 5 Pa.",
                     "sourceLanguage": "zh"}],
                   target="en", state="numericDifference", gap=MISSING_TEMPERATURE)

    def test_english_keeps_selected_source_and_saved_target_support(self):
        for language, original, translation in (
                (None, "The temperature is 20 °C.", "温度是 10 °C。"),
                ("zh", "温度是 10 °C。", "The temperature is 20 °C."),
                ("es", "La temperatura es 10 °C.", "The temperature is 20 °C.")):
            with self.subTest(sourceLanguage=language):
                self.check([{"english": original, "chinese": translation, "sourceLanguage": language}],
                           target="en", state="linked")

    def test_english_keeps_other_fragment_of_selected_segment(self):
        self.check([{"english": "The pressure is 5 Pa. The temperature is 20 °C.",
                     "chinese": "温度是 10 °C。"}], target="en", state="linked",
                   fragments=["The pressure is 5 Pa.", "The temperature is 20 °C."])

    def test_english_keeps_other_selected_segment_gap(self):
        self.check([{"english": "The temperature is 10 °C.", "chinese": "温度是 10 °C。"},
                    {"english": "The temperature is 20 °C.", "chinese": "温度是 30 °C。"}],
                   target="en", state="linked", gap=OTHER_TEMPERATURE)

    def test_english_rejects_linked_state_supported_only_by_discarded_counterpart(self):
        case, result, directory, fixture_sha = self.probe(
            [{"english": "The temperature is 10 °C.", "chinese": "温度是 20 °C。"}],
            target="en", state="linked")
        with self.assertRaisesRegex(scorer.IntegrityError, "point-binding-question-or-state-mismatch"):
            scorer.verify_result(case, result, directory, fixture_sha, allow_synthetic=True, target="en")

    def test_default_keeps_both_columns_in_own_segment(self):
        for language, original, translation in (
                (None, "The temperature is 10 °C.", "温度是 20 °C。"),
                ("zh", "温度是 20 °C。", "温度是 10 °C。"),
                ("es", "La temperatura es 20 °C.", "温度是 10 °C。")):
            with self.subTest(sourceLanguage=language):
                self.check([{"english": original, "chinese": translation, "sourceLanguage": language}],
                           target="zh-Hans", state="linked")

    def test_default_keeps_both_columns_in_other_segment(self):
        self.check([{"english": "The temperature is 10 °C.", "chinese": "温度是 10 °C。"},
                    {"english": "The pressure is 5 Pa.", "chinese": "温度是 20 °C。"}],
                   target="zh-Hans", state="linked", gap=OTHER_TEMPERATURE)


class NumericReviewCLIResultTests(unittest.TestCase):
    def test_saved_cli_numeric_difference_passes_english_verification(self):
        location = os.environ.get("LIVELINGO_QUALITY_NUMERIC_REVIEW_DIRECTORY")
        if not location:
            self.skipTest("Set LIVELINGO_QUALITY_NUMERIC_REVIEW_DIRECTORY to existing CLI artifacts")
        directory = Path(location)
        case = scorer.load(directory / "fixture.json")
        result = scorer.load(directory / "result.json")
        self.assertEqual(result["producer"]["targetLocale"], "en")
        self.assertEqual(result["producer"]["generationOrigin"], "synthetic-regression")
        point = result["stages"][0]["batches"][0]["note"]["points"][0]
        self.assertEqual(point["referenceState"], "numericDifference")
        self.assertEqual(point["numericGap"], MISSING_TEMPERATURE)
        verified = scorer.verify_result(case, result, directory, scorer.digest(directory / "fixture.json"),
                                        allow_synthetic=True, target="en")
        self.assertEqual(verified[0]["points"][0]["referenceState"], "numericDifference")
        self.assertEqual(verified[0]["points"][0]["numericGap"], MISSING_TEMPERATURE)


if __name__ == "__main__":
    unittest.main()
