"""Synthetic V2b reference regressions; no model or network is used."""
from __future__ import annotations

import copy
import json
import os
from pathlib import Path
import tempfile
import unittest

import test_learning_quality as legacy

scorer = legacy.scorer
RULE = ("quoteIDs 和 candidateQuoteIDs 引用 priorEvidence 的旧原文或 evidence 的当前原文。"
        "h 编号只作历史上下文，不能用于当前正文 sourceIDs；旧引文不作为本批新知识重复整理。")


class PendingReferenceTests(unittest.TestCase):
    def setUp(self):
        self.target = "old:0"
        self.references = {
            self.target: {"referenceState": "awaitingContext", "needsContext": "容器属于哪个样品？",
                          "sources": [{"index": 0, "quote": "容器已经密封。"}]},
            "candidate:0": {"clarifies": self.target, "sources": [
                {"index": 0, "quote": "Sample A is sealed."},
                {"index": 0, "quote": "样品甲已经密封。"}]},
            "other:0": {"clarifies": "another:0", "sources": [
                {"index": 0, "quote": "无关的旧原文。"}]},
        }
        self.batches = {self.target: {"evidence": [
            {"english": "The container is sealed.", "chinese": "容器已经密封。"}]}}
        evidence = [{"english": "Sample A is sealed.", "chinese": "样品甲已经密封。"}] * 2
        units = [{"id": f"{language}{index}s0", "index": index, "language": language,
                  "text": source[field]}
                 for index, source in enumerate(evidence)
                 for language, field in (("en", "english"), ("zh", "chinese"))]
        self.units = scorer.verify_units(units, evidence)
        self.prepared = {
            "evidence": units, "pendingEvidenceRule": RULE,
            "priorEvidence": [{"id": "h0", "scope": "prior", "text": "容器已经密封。"},
                              {"id": "h1", "scope": "prior", "text": "样品甲已经密封。"}],
            "pendingPoints": [{"id": "q0", "question": "当前原文是否补充了同一对象的关系？",
                               "quotes": [], "candidateQuotes": [], "quoteIDs": ["h0"],
                               "candidateQuoteIDs": ["en0s0", "h1"], "referenceCheck": False}],
        }

    def verify(self, prepared=None):
        scorer.verify_pending_points(self.prepared if prepared is None else prepared,
                                     [self.target], self.references, self.batches, self.units)

    def reject(self, prepared, reason):
        with self.assertRaisesRegex(scorer.IntegrityError, reason):
            self.verify(prepared)

    def test_historical_and_current_ids_resolve_without_changing_input(self):
        original = copy.deepcopy(self.prepared)
        self.verify()
        self.assertEqual(self.prepared, original)

    def test_fixed_rule_matches_production_wire_literal(self):
        source = (legacy.HERE.parent / "LiveLingo/Sources/LearningNotes.swift").read_text()
        self.assertIn(f'let pendingEvidenceRule = "{RULE}"', source)
        self.assertEqual(scorer.PENDING_EVIDENCE_RULE, RULE)

    def test_current_candidate_expansion_keeps_every_id_and_two_texts(self):
        self.prepared["pendingPoints"][0]["candidateQuoteIDs"] = list(self.units)
        self.verify()

    def test_current_quote_id_still_has_to_bind_to_old_target(self):
        self.references[self.target]["sources"][0]["quote"] = "Sample A is sealed."
        self.prepared["pendingPoints"][0]["quoteIDs"] = ["en0s0"]
        self.verify()
        self.references[self.target]["sources"][0]["quote"] = "容器已经密封。"
        self.reject(self.prepared, "pending-quotes-not-bound-to-target")

    def test_each_historical_and_current_id_must_exist(self):
        for field in ("quoteIDs", "candidateQuoteIDs"):
            for invalid in ("h9", "zh9s0", "en9s0", None, 0, {}):
                with self.subTest(field=field, invalid=invalid):
                    prepared = copy.deepcopy(self.prepared)
                    prepared["pendingPoints"][0][field].append(invalid)
                    self.reject(prepared, f"pending-{field}-unknown-or-invalid")

    def test_resolved_text_cannot_come_from_another_target(self):
        for field, reason in (("quoteIDs", "pending-quotes-not-bound-to-target"),
                              ("candidateQuoteIDs", "pending-candidate-quotes-not-bound")):
            with self.subTest(field=field):
                prepared = copy.deepcopy(self.prepared)
                prepared["priorEvidence"].append(
                    {"id": "h2", "scope": "prior", "text": "无关的旧原文。"})
                prepared["pendingPoints"][0][field] = ["h2"]
                self.reject(prepared, reason)

    def test_historical_quote_prefix_remains_supported(self):
        self.prepared["priorEvidence"][0]["text"] = "容器已经"
        self.verify()

    def test_prior_catalog_requires_unique_historical_ids_and_text(self):
        for invalid, reason in ((None, "priorEvidence:object-array-required"),
                                ({}, "priorEvidence:object-array-required"), ([{}], "prior-evidence-shape")):
            prepared = copy.deepcopy(self.prepared)
            prepared["priorEvidence"] = invalid
            self.reject(prepared, reason)
        prepared = copy.deepcopy(self.prepared)
        del prepared["priorEvidence"]
        self.reject(prepared, "priorEvidence:object-array-required")
        for field, invalid in (("id", "en0s0"), ("id", "h01"), ("id", None),
                               ("scope", "current"), ("text", ""), ("text", " \n"), ("text", 1)):
            with self.subTest(field=field, invalid=invalid):
                prepared = copy.deepcopy(self.prepared)
                prepared["priorEvidence"][0][field] = invalid
                self.reject(prepared, "prior-evidence-shape")
        prepared = copy.deepcopy(self.prepared)
        prepared["priorEvidence"].append(copy.deepcopy(prepared["priorEvidence"][0]))
        self.reject(prepared, "prior-evidence-ID:duplicate")

    def test_rule_cannot_be_missing_or_changed(self):
        for invalid in (None, "", RULE + " "):
            with self.subTest(invalid=invalid):
                prepared = copy.deepcopy(self.prepared)
                prepared["pendingEvidenceRule"] = invalid
                self.reject(prepared, "pending-evidence-rule")
        prepared = copy.deepcopy(self.prepared)
        del prepared["pendingEvidenceRule"]
        self.reject(prepared, "pending-evidence-rule")

    def test_both_id_arrays_are_required_and_cannot_shadow_inline_quotes(self):
        for field in ("quoteIDs", "candidateQuoteIDs"):
            for invalid in (None, "h0"):
                with self.subTest(field=field, invalid=invalid):
                    prepared = copy.deepcopy(self.prepared)
                    prepared["pendingPoints"][0][field] = invalid
                    self.reject(prepared, f"pending-{field}-unknown-or-invalid")
            prepared = copy.deepcopy(self.prepared)
            del prepared["pendingPoints"][0][field]
            self.reject(prepared, f"pending-{field}-unknown-or-invalid")
        for field in ("quotes", "candidateQuotes"):
            prepared = copy.deepcopy(self.prepared)
            prepared["pendingPoints"][0][field] = ["容器已经密封。"]
            self.reject(prepared, "indexed-pending-inline-quotes")

    def test_empty_quote_and_nonboolean_reference_check_still_fail(self):
        prepared = copy.deepcopy(self.prepared)
        prepared["pendingPoints"][0]["quoteIDs"] = []
        self.reject(prepared, "pending-quotes-not-bound-to-target")
        prepared = copy.deepcopy(self.prepared)
        prepared["pendingPoints"][0]["referenceCheck"] = 0
        self.reject(prepared, "pending-referenceCheck-type")

    def test_duplicate_reference_ids_fail(self):
        for field in ("quoteIDs", "candidateQuoteIDs"):
            prepared = copy.deepcopy(self.prepared)
            prepared["pendingPoints"][0][field] *= 2
            self.reject(prepared, f"pending-{field}:duplicate")

    def test_three_distinct_bound_texts_still_exceed_quote_limits(self):
        references = copy.deepcopy(self.references)
        for field, reason in (("quoteIDs", "pending-quotes-not-bound-to-target"),
                              ("candidateQuoteIDs", "pending-candidate-quotes-not-bound")):
            with self.subTest(field=field):
                self.references = copy.deepcopy(references)
                prepared = copy.deepcopy(self.prepared)
                texts = ["原文甲。", "原文乙。", "原文丙。"]
                prepared["priorEvidence"] += [
                    {"id": f"h{index + 2}", "scope": "prior", "text": text}
                    for index, text in enumerate(texts)]
                prepared["pendingPoints"][0][field] = ["h2", "h3", "h4"]
                owner = self.target if field == "quoteIDs" else "candidate:0"
                self.references[owner]["sources"] = [{"index": 0, "quote": text} for text in texts]
                self.reject(prepared, reason)

    def test_multilingual_history_fallback_binds_to_chinese_field(self):
        for language, original in (("es", "El recipiente está sellado."), ("yue", "個容器密封咗。")):
            with self.subTest(language=language):
                self.references[self.target]["sources"] = []
                self.batches[self.target]["evidence"][0] = {
                    "english": original, "chinese": "容器已经密封。", "sourceLanguage": language}
                self.verify()
                prepared = copy.deepcopy(self.prepared)
                prepared["priorEvidence"][0]["text"] = original
                self.reject(prepared, "pending-quotes-not-bound-to-target")

    def test_legacy_quotes_keep_original_binding_and_limits(self):
        prepared = {"pendingPoints": [{"id": "q0", "quotes": ["容器已经密封。"],
                                      "candidateQuotes": ["Sample A is sealed."], "referenceCheck": False}]}
        self.verify(prepared)
        for field, reason in (("quotes", "pending-quotes-not-bound-to-target"),
                              ("candidateQuotes", "pending-candidate-quotes-not-bound")):
            for invalid in (["无关的旧原文。"], prepared["pendingPoints"][0][field] * 3, None):
                with self.subTest(field=field, invalid=invalid):
                    changed = copy.deepcopy(prepared)
                    changed["pendingPoints"][0][field] = invalid
                    self.reject(changed, reason)

    def test_legacy_fallback_keeps_original_source_field_preference(self):
        self.references[self.target]["sources"] = []
        self.batches[self.target]["evidence"][0]["sourceLanguage"] = "es"
        prepared = {"pendingPoints": [{"id": "q0", "quotes": ["The container is sealed."],
                                      "candidateQuotes": [], "referenceCheck": False}]}
        self.verify(prepared)
        prepared["pendingPoints"][0]["quotes"] = ["容器已经密封。"]
        self.reject(prepared, "pending-quotes-not-bound-to-target")


class V2bProbeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        location = os.environ.get("LIVELINGO_QUALITY_TEST_DIRECTORY")
        if not location or not Path(location).is_absolute():
            raise RuntimeError("Set LIVELINGO_QUALITY_TEST_DIRECTORY to an absolute isolated evidence directory")
        cls.root = Path(location)
        cls.root.mkdir(parents=True, exist_ok=True)

    def setUp(self):
        self.directory = Path(tempfile.mkdtemp(prefix="v2b-" + self._testMethodName + ".", dir=self.root)) / "probe"
        first = [{"kind": "待确认", "text": "原文中的对象归属待确认。", "sourceIDs": ["zh0s0"],
                  "needsContext": "原文说的是哪个对象？", "clarifies": None}]
        self.case, self.gold, self.result = legacy.make_probe(
            self.directory, custom_points={0: first}, pending={1: [(0, 0)]})
        self.request = self.result["requests"][1]
        self.prepared = self.read_artifact("input")
        quote = self.prepared["pendingPoints"][0]["quotes"][0]
        self.prepared["priorEvidence"] = [{"id": "h0", "scope": "prior", "text": quote}]
        self.prepared["pendingEvidenceRule"] = RULE
        self.prepared["pendingPoints"][0].update(
            quotes=[], candidateQuotes=[], quoteIDs=["h0"], candidateQuoteIDs=[])
        self.write_artifact("input", self.prepared)

    def read_artifact(self, kind):
        return json.loads((self.directory / self.request[kind + "File"]).read_bytes())

    def write_artifact(self, kind, value):
        data = legacy.encode(value)
        (self.directory / self.request[kind + "File"]).write_bytes(data)
        self.request[kind + "SHA256"] = legacy.sha(data)

    def assess(self):
        return scorer.evaluate_case(self.gold, self.case, self.result, directory=self.directory,
                                    fixture_sha=self.result["fixtureSHA256"], allow_synthetic=True)

    def reject(self, reason):
        report = self.assess()
        self.assertEqual(report["integrityStatus"], "failed", report)
        self.assertIn(reason, report["error"])
        self.assertFalse(any(f["coverageSignal"] for f in report["facts"]))

    def install_followups(self):
        target = self.request["pendingTargets"][0]
        raw = self.read_artifact("response")
        raw["followUps"] = {"q0": {"state": "缺信息", "sourceIDs": [], "detail": "当前原文未澄清归属。"}}
        self.write_artifact("response", raw)
        record = {"alias": "q0", "target": target, "state": "缺信息", "sourceIDs": None,
                  "detail": "当前原文未澄清归属。"}
        self.request["normalizedNote"]["followUps"] = [copy.deepcopy(record)]
        batch = self.result["stages"][1]["batches"][1]
        batch["followUps"] = [{**record, "evidenceIDs": [s["id"] for s in batch["evidence"]],
                               "notebookRevision": 1}]
        self.assertEqual(self.assess()["integrityStatus"], "pass")

    def test_complete_v2b_probe_passes_integrity_but_needs_semantic_readback(self):
        report = self.assess()
        self.assertEqual(report["integrityStatus"], "pass", report)
        self.assertEqual(report["semanticCorrectness"], scorer.PENDING)

    def test_valid_artifact_hash_does_not_hide_unknown_quote_id(self):
        self.prepared["pendingPoints"][0]["quoteIDs"] = ["h8"]
        self.write_artifact("input", self.prepared)
        self.reject("pending-quoteIDs-unknown-or-invalid")

    def test_valid_artifact_hash_does_not_hide_changed_rule(self):
        self.prepared["pendingEvidenceRule"] = "允许历史来源进入正文。"
        self.write_artifact("input", self.prepared)
        self.reject("pending-evidence-rule")

    def test_historical_ids_cannot_appear_in_raw_points(self):
        raw = self.read_artifact("response")
        raw["points"][0]["sourceIDs"] = ["h0"]
        self.write_artifact("response", raw)
        self.reject("raw-point-source-ID-mismatch")

    def test_historical_ids_cannot_appear_in_normalized_points(self):
        self.request["normalizedNote"]["points"][0]["sourceIDs"] = ["h0"]
        self.reject("raw-point-source-ID-mismatch")

    def test_historical_ids_cannot_appear_in_committed_points(self):
        self.result["stages"][1]["batches"][1]["note"]["points"][0]["sourceIDs"] = ["h0"]
        self.reject("point-source-ID-invalid")

    def test_historical_ids_cannot_appear_in_raw_followups(self):
        self.install_followups()
        raw = self.read_artifact("response")
        raw["followUps"]["q0"]["sourceIDs"] = ["h0"]
        self.write_artifact("response", raw)
        self.reject("model-followup-sources")

    def test_historical_ids_cannot_appear_in_normalized_followups(self):
        self.install_followups()
        self.request["normalizedNote"]["followUps"][0]["sourceIDs"] = ["h0"]
        self.reject("historical-followup-source-ID")

    def test_historical_ids_cannot_hide_in_unresolved_committed_followups(self):
        self.install_followups()
        self.result["stages"][1]["batches"][1]["followUps"][0]["sourceIDs"] = ["h0"]
        self.reject("historical-followup-source-ID")


if __name__ == "__main__":
    unittest.main()
