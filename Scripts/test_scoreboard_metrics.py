"""Offline synthetic tests; no models, processes, network or system temp files."""

import base64
from contextlib import redirect_stderr, redirect_stdout
import hashlib
import io
import json
import math
import os
from pathlib import Path
import re
import sys
import unittest
import uuid

import scoreboard_metrics as m


ROOT = Path(__file__).resolve().parent.parent
WORK = ROOT / "work/metrics-tests"
SENTINEL = "PRIVATE_SENTINEL_never_emit_机密原文"
SESSION_ID = "11111111-1111-4111-8111-111111111111"
ID1 = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
ID2 = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
# Optional local evidence: the frozen CS50 benchmark lives outside the repository.
LL4 = Path(os.environ["LIVELINGO_CS50_REFERENCE_DIR"]) if os.environ.get("LIVELINGO_CS50_REFERENCE_DIR") else None


def envelope(data):
    payload = json.dumps(data, ensure_ascii=False, sort_keys=True).encode("utf-8")
    return {"payload": base64.b64encode(payload).decode("ascii"), "sha256": hashlib.sha256(payload).hexdigest()}


def segment(identity=ID1, start=0, end=4, english="alpha beta", chinese="中文", state="completed"):
    return {"id": identity, "startTime": start, "endTime": end, "english": english,
            "chinese": chinese, "translationState": state}


def cue(identity=1, start=0, end=4, text="alpha beta"):
    return {"cue_id": identity, "start_rel": start, "end_rel": end, "text": text}


def event(name, wall, identity=ID1, elapsed=0, **extra):
    return {"kind": "caption", "category": "TranslationLatency", "event": name,
            "id": identity, "timestamp": wall, "elapsed_ms": elapsed, **extra}


def clock(wall=100):
    return {"kind": "replay", "category": "ReplayClock", "event": "start", "timestamp": wall}


def record(name="a", status="completed", **extra):
    return {"id": str(uuid.uuid5(uuid.NAMESPACE_DNS, name)), "sessionID": SESSION_ID,
            "start": 0, "end": 2, "status": status, "automaticRetryCount": 0,
            "manualRetryCount": 0, "appleEvidence": "", **extra}


class TokenTests(unittest.TestCase):
    def test_raw_matches_original_regex_exactly(self):
        text = "Can't DON’T 1.n printf 617, Uh C++ naïve ＯＫ."
        self.assertEqual(m.tokens_raw(text), re.findall(r"[a-z0-9]+(?:'[a-z]+)?", text.lower()))

    def test_equivalent_phone_numbers(self):
        for text in ("617", "six one seven", "six hundred seventeen", "six hundred and seventeen"):
            with self.subTest(text=text):
                self.assertEqual(m.normalize_v1(text), list("617"))

    def test_scales_and_articles(self):
        for text, number in (("a hundred", "100"), ("an hundred", "100"), ("one thousand", "1000"),
                             ("two million three hundred thousand five hundred and six", "2300506"),
                             ("one billion", "1000000000")):
            with self.subTest(text=text):
                self.assertEqual(m.normalize_v1(text), list(number))
        self.assertEqual(m.normalize_v1("a cat an apple"), ["a", "cat", "an", "apple"])

    def test_adjacent_numbers_are_not_illegally_added(self):
        self.assertEqual(m.normalize_v1("twenty twenty five"), list("2025"))
        self.assertEqual(m.normalize_v1("one two three"), list("123"))
        self.assertEqual(m.normalize_v1("one thousand and five"), list("1000") + ["and", "5"])

    def test_fillers_equivalents_unicode(self):
        self.assertEqual(m.normalize_v1("Uh um uhm er erm ah hmm mm mhm ＯＫＡＹ alright"), ["ok", "all", "right"])
        self.assertEqual(m.normalize_v1("６１７"), list("617"))

    def test_nt_expands_before_scoring(self):
        for text in ("can't", "cannot", "can not", "can’t", "CANʼT"):
            self.assertEqual(m.normalize_v1(text), ["can", "not"])
        for left, right in (("won't", "will not"), ("shan't", "shall not"), ("wouldn't", "would not"),
                            ("isn't", "is not"), ("needn't", "need not"), ("oughtn't", "ought not")):
            self.assertEqual(m.normalize_v1(left), m.normalize_v1(right))

    def test_ordinals_1_to_31(self):
        for left, right in (("1st", "first"), ("2nd", "second"), ("3rd", "third"), ("21st", "twenty first"),
                            ("22nd", "twenty-second"), ("30th", "thirtieth"), ("31st", "thirty first")):
            self.assertEqual(m.normalize_v1(left), m.normalize_v1(right))
        self.assertEqual(m.normalize_v1("32nd"), ["32nd"])

    def test_normalizer_fixture_is_the_canonical_runtime_rules(self):
        rules = json.loads((ROOT / "Fixtures/scoreboard-v1/normalizer-v1.json").read_text())
        self.assertEqual(rules["version"], "norm_v1")
        self.assertEqual(rules, m._RULES)
        self.assertEqual(m.normalize_v1(" ".join(rules["filler_words"])), [])
        for spelling, expanded in rules["equivalents"].items():
            self.assertEqual(m.normalize_v1(spelling), m.normalize_v1(" ".join(expanded)))
        for code_word in rules["code"]:
            ref = m.normalize_v1(code_word)
            result = m.critical_counts(m.align(ref, ["unlistedtoken"])["ops"], ref, ["unlistedtoken"])
            self.assertEqual(result["code"], 1)
        for negation in rules["negation"]:
            ref = m.normalize_v1(negation)
            self.assertEqual(m.critical_counts(m.align(ref, [])["ops"], ref, [])["negation"], 1)


class ParsingTests(unittest.TestCase):
    def test_bare_and_both_envelope_line_shapes(self):
        wrapped = {"recv_wall": 12.5, "recv_mono": 3.2, "line": {"event": "state", "segments": 2}}
        serialized_line = {**wrapped, "line": json.dumps(wrapped["line"])}
        data = "\n".join(map(json.dumps, [{"event": "capture"}, wrapped, serialized_line]))
        parsed = m.parse_ndjson(data.encode())
        self.assertEqual(parsed[0], {"event": "capture"})
        self.assertEqual(parsed[1], {"event": "state", "segments": 2, "recv_wall": 12.5, "recv_mono": 3.2})
        self.assertEqual(parsed[1], parsed[2])
        self.assertEqual(wrapped["line"], {"event": "state", "segments": 2})

    def test_empty_and_object_input(self):
        self.assertEqual(m.parse_ndjson(" \n\n"), [])
        self.assertEqual(m.parse_ndjson({"event": "state"}), [{"event": "state"}])

    def test_malformed_and_nonfinite_inputs_have_safe_errors(self):
        values = (SENTINEL, '["' + SENTINEL + '"]', b"\xff", '{"a":1,"a":2}', '{"a":NaN}',
                  [{"recv_wall": SENTINEL, "line": {}}], [{"recv_wall": 1, "line": []}])
        for value in values:
            with self.subTest(index=values.index(value)):
                with self.assertRaises(ValueError) as caught:
                    m.parse_ndjson(value)
                self.assertNotIn(SENTINEL, str(caught.exception))

    def test_oslog_numeric_and_fixed_enums_only(self):
        raw = {"timestamp": "2026-10-07 12:00:00.250+0800", "category": "TranslationLatency",
               "eventMessage": f"caption event=complete id={ID1} elapsed_ms=1200 has_diagnostic=true text={SENTINEL}",
               "processImagePath": SENTINEL, "unused": SENTINEL}
        row = m.parse_oslog_numeric(json.dumps(raw))[0]
        self.assertIsInstance(row["timestamp"], (int, float))
        self.assertEqual(row["event"], "complete")
        self.assertEqual(row["id"], ID1)
        self.assertEqual(row["elapsed_ms"], 1200)
        self.assertEqual(row["has_diagnostic"], 1)
        self.assertNotIn(SENTINEL, json.dumps(row))
        self.assertNotIn("eventMessage", row)

    def test_oslog_unknown_strings_fold_and_invalid_id_disappears(self):
        raw = {"timestamp": 100, "category": SENTINEL, "kind": SENTINEL, "event": SENTINEL,
               "backend": SENTINEL, "reason": SENTINEL, "stage": SENTINEL, "id": SENTINEL,
               "elapsed_ms": SENTINEL, "text": SENTINEL}
        row = m.parse_oslog_numeric([raw])[0]
        for key in ("category", "kind", "event", "backend", "reason", "stage"):
            self.assertEqual(row[key], "unknown")
        self.assertNotIn("id", row)
        self.assertNotIn("elapsed_ms", row)
        self.assertNotIn(SENTINEL, json.dumps(row))

    def test_oslog_hash_accepted_and_bad_time_dropped(self):
        self.assertEqual(m.parse_oslog_numeric([{"timestamp": 100, "id": "a" * 64}])[0]["id"], "a" * 64)
        self.assertEqual(m.parse_oslog_numeric([{"timestamp": "2026-10-07T12:00:00"}]), [])
        self.assertEqual(m.parse_oslog_numeric([{"timestamp": "invalid"}]), [])
        self.assertEqual(m.parse_oslog_numeric([{"timestamp": float("inf")}]), [])

    def test_production_retry_enum_allowlist(self):
        for name in ("retry_standard", "retry_repairContent", "retry_expandedBudget"):
            self.assertEqual(m.parse_oslog_numeric([event(name, 100)])[0]["event"], name)


class DurableTests(unittest.TestCase):
    def setUp(self):
        # Explicit task-owned directories; leave small synthetic evidence in place.
        WORK.mkdir(parents=True, exist_ok=True)
        self.session = WORK / "synthetic" / uuid.uuid4().hex
        self.directory = self.session / "durable-transcription"
        self.directory.mkdir(parents=True)

    def write(self, records=(), checkpoint=0, changes=()):
        state = {"version": 1, "sessionID": SESSION_ID, "sequence": checkpoint, "records": list(records)}
        (self.directory / "snapshot.json").write_text(json.dumps(envelope(state)), encoding="utf-8")
        if changes:
            (self.directory / "work.jsonl").write_text("".join(json.dumps(envelope(change)) + "\n" for change in changes), encoding="utf-8")

    def change(self, sequence, value=None):
        return {"version": 1, "sessionID": SESSION_ID, "sequence": sequence, "record": value}

    def test_all_statuses_candidates_retry_and_seconds(self):
        records = [record("pending", "pending"), record("active", "active"),
                   record("retry", "retryWaiting", automaticRetryCount=1), record("manual", "manualPending"),
                   record("done", "completed", automaticRetryCount=2), record("silent", "silent"),
                   record("failed", "failed", failureReason="emptyOutput"),
                   record("other", "failed", extendedStatus="otherLanguage"),
                   record("done-candidate", "completed", candidateText=SENTINEL, automaticRetryCount=1),
                   record("other-candidate", "failed", extendedStatus="otherLanguage", candidateText="")]
        self.write(records)
        result = m.durable_census(self.session)
        self.assertEqual(result["chunks"], 10)
        self.assertEqual(result["pending"], 4)
        self.assertEqual(result["unresolved"], 4)
        self.assertEqual(result["other_language"], 1)
        self.assertEqual(result["failed"], 1)
        self.assertEqual(result["completed_with_unresolved"], 1)
        self.assertEqual(result["recovered_by_retry"], 2)
        self.assertEqual(result["automatic_retry_attempts"], 4)
        self.assertEqual(result["not_captioned_speech_seconds"], 8)
        self.assertEqual(result["by_status"]["completed"], 2)
        self.assertEqual(sum(result["seconds_by_status"].values()), 20)
        self.assertNotIn(SENTINEL, json.dumps(result))

    def test_last_mutation_wins_after_snapshot(self):
        original = record("same", "pending")
        active = {**original, "status": "active"}
        done = {**original, "status": "completed", "candidateText": SENTINEL}
        self.write([active], 2, [self.change(1, original), self.change(2, active), self.change(3, done)])
        result = m.durable_census(self.session)
        self.assertEqual(result["chunks"], 1)
        self.assertEqual(result["by_status"]["completed"], 1)
        self.assertEqual(result["pending"], 0)
        self.assertEqual(result["completed_with_unresolved"], 1)
        self.assertEqual(result["journal_sequence"], 3)

    def test_unknown_extended_status_uses_legacy(self):
        self.write([record(status="failed", extendedStatus=SENTINEL, failureReason=SENTINEL)])
        result = m.durable_census(self.session)
        self.assertEqual(result["failed"], 1)
        self.assertEqual(result["failure_reasons"]["unknown"], 1)
        self.assertNotIn(SENTINEL, json.dumps(result))

    def test_apple_evidence_is_presence_only(self):
        values = [record("present", appleEvidence=SENTINEL), record("empty", appleEvidence=""),
                  record("absent", appleEvidence=None)]
        self.write(values)
        result = m.durable_census(self.session)
        self.assertEqual(result["apple_evidence"], {"empty": 1, "present": 1, "unknown": 1})
        self.assertEqual(result["apple_evidence_present"], 1)
        self.assertEqual(result["apple_evidence_present_seconds"], 2)
        self.assertNotIn(SENTINEL, json.dumps(result))

    def test_unknown_issue_is_fixed_unknown_not_raw_key(self):
        self.write([record()])
        (self.session / "transcription-issues.jsonl").write_text(json.dumps({"event": SENTINEL, "detail": SENTINEL, "candidate": SENTINEL}) + "\n")
        result = m.durable_census(self.session)
        self.assertEqual(result["issue_events"]["unknown"], 1)
        self.assertNotIn(SENTINEL, json.dumps(result))

    def test_work_without_snapshot_is_valid(self):
        (self.directory / "work.jsonl").write_text(json.dumps(envelope(self.change(1, record()))) + "\n")
        self.assertEqual(m.durable_census(self.session)["chunks"], 1)

    def test_missing_both_is_unavailable(self):
        with self.assertRaises(ValueError):
            m.durable_census(self.session)

    def test_journal_required_for_nonzero_checkpoint(self):
        self.write([record()], 1)
        with self.assertRaises(ValueError):
            m.durable_census(self.session)

    def test_physical_sequence_never_sorted(self):
        self.write([], 0, [self.change(2, record()), self.change(1, record())])
        with self.assertRaises(ValueError):
            m.durable_census(self.session)

    def test_duplicate_or_gap_sequence_rejected(self):
        for sequence in (1, 3):
            self.write([], 0, [self.change(1, record()), self.change(sequence, record())])
            with self.assertRaises(ValueError):
                m.durable_census(self.session)

    def test_covered_journal_envelopes_still_checked(self):
        value = record()
        self.write([value], 1, [self.change(1, value)])
        path = self.directory / "work.jsonl"
        row = json.loads(path.read_text())
        row["sha256"] = "0" * 64
        path.write_text(json.dumps(row) + "\n")
        with self.assertRaises(ValueError):
            m.durable_census(self.session)

    def test_bad_sha_base64_json_or_records_safe_errors(self):
        self.write([record()])
        path = self.directory / "snapshot.json"
        bad = ({"payload": SENTINEL, "sha256": "0" * 64},
               {**envelope({"records": []}), "sha256": SENTINEL},
               envelope({"version": 1, "sequence": 0, "records": [record(status=SENTINEL)]}),
               envelope({"version": 1, "sequence": 0, "records": [record(), record()]}))
        for index, row in enumerate(bad):
            with self.subTest(index=index):
                path.write_text(json.dumps(row))
                with self.assertRaises(ValueError) as caught:
                    m.durable_census(self.session)
                self.assertNotIn(SENTINEL, str(caught.exception))

    def test_truncated_journal_is_not_repaired(self):
        self.write([], 0, [self.change(1, record())])
        path = self.directory / "work.jsonl"
        raw = path.read_bytes() + b'{"payload":"truncated'
        path.write_bytes(raw)
        with self.assertRaises(ValueError):
            m.durable_census(self.session)
        self.assertEqual(path.read_bytes(), raw)

    def test_session_mismatch_rejected(self):
        self.write([], 0, [{**self.change(1, record()), "sessionID": ID1}])
        with self.assertRaises(ValueError):
            m.durable_census(self.session)


class ASRTests(unittest.TestCase):
    def test_edit_operations_and_no_text_output(self):
        for ref, hyp, expected in ((["a", "b"], ["a", "c"], (1, 0, 0)),
                                   (["a", "b"], ["a"], (0, 1, 0)),
                                   (["a"], ["a", "b"], (0, 0, 1))):
            result = m.align(ref, hyp)
            self.assertEqual(tuple(result[k] for k in ("S", "D", "I")), expected)
            self.assertEqual(set(result["ops"][0]), {"op", "ref_index", "hyp_index"})
        self.assertIsNone(m.align([], ["word"])["rate"])

    def test_time_window_inclusive_and_remote_words_never_match(self):
        allowed = m.align(["echo"], ["echo"], reference_times=[(0, 1)], hypothesis_times=[(4, 5)])
        forbidden = m.align(["echo"], ["echo"], reference_times=[(0, 1)], hypothesis_times=[(4.001, 5)])
        self.assertEqual(allowed["rate"], 0)
        self.assertEqual((forbidden["D"], forbidden["I"], forbidden["S"]), (1, 1, 0))

    def test_remote_repeated_word_does_not_cover_earlier_cue(self):
        result = m.score_asr([cue(1, 0, 1, "echo"), cue(2, 20, 21, "echo")],
                             [segment(start=20, end=21, english="echo")], known_errors=[1])
        self.assertEqual(result["norm_v1"]["D"], 1)
        self.assertEqual(result["ops_on_known_reference_errors"], 1)
        result = m.score_asr([cue(1, 0, 1, "echo")], [segment(start=20, end=21, english="echo")])
        self.assertEqual(result["norm_v1"]["rate"], 2)

    def test_contractions_differ_raw_but_equal_normalized(self):
        result = m.score_asr([cue(text="cannot")], [segment(english="can't")])
        self.assertEqual(result["raw"]["S"], 1)
        self.assertEqual(result["norm_v1"]["rate"], 0)
        self.assertEqual(result["norm_v1"]["ref_tokens"], 2)

    def test_critical_and_known_reference_errors(self):
        result = m.score_asr([cue(700, text="cannot use int 2")], [segment(english="can use char 3")], known_errors=[{"cue_id": 700}])
        self.assertEqual(result["critical"], {"negation": 1, "number": 1, "code": 1})
        self.assertEqual(result["ops_on_known_reference_errors"], 3)
        self.assertEqual(result["norm_v1"]["D"], 1)
        self.assertNotIn("text", json.dumps(result))

    def test_known_cue_insertions_count_without_changing_denominator(self):
        result = m.score_asr([cue(700, text="alpha")], [segment(english="alpha extra")], [700])
        self.assertEqual(result["ops_on_known_reference_errors"], 1)
        self.assertEqual(result["norm_v1"]["I"], 1)
        self.assertEqual(result["norm_v1"]["ref_tokens"], 1)

    def test_caption_duration_fraction_and_empty_hypothesis(self):
        result = m.score_asr([cue(end=10)], [segment(end=5)])
        self.assertEqual(result["captioned_fraction"], 0.5)
        self.assertEqual(m.score_asr([cue()], [])["norm_v1"]["D"], 2)
        self.assertIsNone(m.score_asr([], [])["captioned_fraction"])

    def test_public_result_never_contains_input_text_or_id(self):
        result = m.score_asr([cue(text=SENTINEL)], [segment(english=SENTINEL)])
        encoded = json.dumps(result)
        self.assertNotIn(SENTINEL, encoded)
        self.assertNotIn(ID1, encoded)

    def test_ll4_raw_parakeet_129_of_2010_and_qwen_135(self):
        if LL4 is None:
            self.skipTest("set LIVELINGO_CS50_REFERENCE_DIR to the frozen CS50 benchmark")
        paths = [LL4 / "benchmark.json", LL4 / "benchmark-results.json"]
        if not all(path.is_file() for path in paths):
            self.skipTest("LL4 frozen benchmark unavailable")
        case, outputs = [json.loads(path.read_text(encoding="utf-8")) for path in paths]
        reference = m.tokens_raw(case["reference"])
        for name, expected in (("parakeet", 129), ("qwen-asr", 135)):
            with self.subTest(model=name):
                hypothesis = m.tokens_raw(" ".join(row["text"] for row in outputs if row["model"] == name))
                result = m.align(reference, hypothesis)
                self.assertEqual(result["ref_tokens"], 2010)
                self.assertEqual(sum(result[k] for k in ("S", "D", "I")), expected)
                if name == "parakeet":
                    self.assertEqual((result["S"], result["D"], result["I"]), (60, 28, 41))


class LatencyTests(unittest.TestCase):
    def test_statistics_are_per_reference_cue_not_app_segment(self):
        reference = [cue(1, 0, 2, "alpha beta"), cue(2, 2, 4, "gamma delta")]
        events = [clock(), event("request", 105, elapsed=1000), event("first_text", 106),
                  event("current_preview", 105.5), event("complete", 108)]
        result = m.latency_join([segment(english="alpha beta gamma delta")], events, reference, 120)
        self.assertEqual(result["cues"], 2)
        self.assertEqual(result["en_commit"]["all"]["count"], 2)
        self.assertEqual(result["en_commit"]["all"]["median_seconds"], 1)
        self.assertEqual(result["zh_first"]["all"]["median_seconds"], 2.5)
        self.assertEqual(result["zh_final"]["all"]["median_seconds"], 5)
        self.assertEqual(result["first_result_latency_from_t0_s"], 5.5)
        self.assertEqual(result["log_coverage"], 1)
        self.assertEqual(result["rows"][0]["sequence"], 1)
        self.assertEqual(result["rows"][1]["audio_end_wall"], 104)
        self.assertEqual(result["rows"][1]["en_commit_wall"], 104)

    def test_split_cue_first_min_commit_and_final_max(self):
        segments = [segment(end=2, english="alpha"), segment(ID2, 2, 4, "beta")]
        events = [clock(), event("request", 105, elapsed=1000), event("complete", 107),
                  event("request", 108, ID2), event("first_text", 109, ID2), event("complete", 110, ID2)]
        result = m.latency_join(segments, events, [cue()], 120)
        self.assertEqual(result["rows"][0]["matched_captions"], 2)
        self.assertEqual(result["rows"][0]["first_wall"], 107)
        self.assertEqual(result["rows"][0]["en_commit_wall"], 108)
        self.assertEqual(result["rows"][0]["final_wall"], 110)
        self.assertEqual(result["zh_final"]["all"]["median_seconds"], 6)

    def test_split_cue_any_unfinished_caption_censors_the_whole_cue(self):
        segments = [segment(end=2, english="alpha"), segment(ID2, 2, 4, "beta", "", "pending")]
        events = [clock(), event("request", 105), event("complete", 107), event("request", 108, ID2)]
        result = m.latency_join(segments, events, [cue()], 120)
        self.assertEqual(result["rows"][0]["match_fraction"], 1)
        self.assertEqual(result["rows"][0]["first_wall"], 107)
        self.assertIsNone(result["rows"][0]["final_wall"])
        self.assertEqual(result["censored"]["zh_final"], 1)
        self.assertEqual(result["unmeasured"]["zh_final"], 0)
        self.assertIsNone(result["zh_final"]["all"]["p95_seconds"])

    def test_split_cue_missing_log_of_known_final_is_unmeasured(self):
        segments = [segment(end=2, english="alpha"), segment(ID2, 2, 4, "beta")]
        result = m.latency_join(segments, [clock(), event("request", 105), event("complete", 107),
                                            event("request", 108, ID2)], [cue()], 120)
        self.assertEqual(result["censored"]["zh_final"], 0)
        self.assertEqual(result["unmeasured"]["zh_final"], 1)

    def test_partial_word_match_does_not_claim_complete_cue(self):
        result = m.latency_join([segment(english="the")], [clock(), event("request", 105), event("complete", 106)],
                                [cue(text="the complete algorithm")], 120)
        self.assertEqual(result["partially_matched_cues"], 1)
        self.assertEqual(result["fully_matched_cues"], 0)
        self.assertEqual(result["rows"][0]["match_fraction"], 1 / 3)
        self.assertEqual(result["censored"]["en_commit"], 1)
        self.assertEqual(result["censored"]["zh_final"], 1)
        self.assertEqual(result["missing_reasons"]["zh_final"]["partial_content_match"], 1)
        self.assertIsNone(result["rows"][0]["final_wall"])

    def test_no_matching_content_or_remote_content_is_censored(self):
        for seg in (segment(english="different wording"), segment(start=20, end=24)):
            result = m.latency_join([seg], [clock(), event("request", 125), event("complete", 126)], [cue()], 130)
            self.assertEqual(result["unmatched_cues"], 1)
            self.assertEqual(result["censored"]["zh_final"], 1)
            self.assertEqual(result["unmeasured"]["zh_final"], 0)
            self.assertEqual(result["rows"][0]["zh_final_censored"], 1)

    def test_unfinished_and_missing_complete_log_are_distinct(self):
        pending = m.latency_join([segment(chinese="", state="pending")], [clock(), event("request", 105)], [cue()], 120)
        completed = m.latency_join([segment()], [clock(), event("request", 105)], [cue()], 120)
        self.assertEqual(pending["censored"]["zh_first"], 1)
        self.assertEqual(pending["censored"]["zh_final"], 1)
        self.assertEqual(pending["unmeasured"]["zh_final"], 0)
        self.assertEqual(completed["censored"]["zh_final"], 0)
        self.assertEqual(completed["unmeasured"]["zh_final"], 1)
        self.assertEqual(completed["missing_reasons"]["zh_final"]["missing_log"], 1)
        self.assertEqual(pending["zh_final"]["all"]["censor_lower_bounds"]["median_seconds"], 16)

    def test_observed_quantiles_are_explicitly_censored(self):
        reference = [cue(), cue(2, 60, 64, "never delivered")]
        result = m.latency_join([segment()], [clock(), event("request", 105), event("complete", 106)], reference, 180)
        self.assertEqual(result["zh_final"]["all"]["median_seconds"], 2)
        self.assertEqual(result["zh_final"]["all"]["population"], "observed_censored")
        self.assertFalse(result["zh_final"]["all"]["full_population_quantiles"])
        self.assertEqual(result["zh_final"]["steady"]["censored"], 1)
        self.assertIsNone(result["zh_final"]["steady"]["p95_seconds"])

    def test_missing_request_log_and_request_elapsed(self):
        result = m.latency_join([segment()], [clock(), event("complete", 106)], [cue()], 120)
        self.assertEqual(result["unmeasured"]["en_commit"], 1)
        self.assertEqual(result["censored"]["en_commit"], 0)
        self.assertEqual(result["log_coverage"], 0)
        self.assertTrue(result["latency_incomplete"])
        missing_elapsed = event("request", 105)
        del missing_elapsed["elapsed_ms"]
        result = m.latency_join([segment()], [clock(), missing_elapsed], [cue()], 120)
        self.assertEqual(result["unmeasured"]["en_commit"], 1)

    def test_split_cue_log_coverage_requires_every_associated_caption_request(self):
        segments = [segment(end=2, english="alpha"), segment(ID2, 2, 4, "beta")]
        result = m.latency_join(segments, [clock(), event("request", 105), event("complete", 107),
                                            event("complete", 110, ID2)], [cue()], 120)
        self.assertEqual(result["log_coverage"], 0)
        self.assertEqual(result["caption_log_coverage"], 0.5)
        self.assertEqual(result["unmeasured"]["en_commit"], 1)

    def test_missing_t0_never_uses_preview_backend_guess(self):
        result = m.latency_join([segment()], [{"kind": "preview", "event": "backend", "timestamp": 90}, event("complete", 106)], [cue()], 120)
        self.assertIsNone(result["t0"])
        self.assertEqual(result["t0_anchor"], "missing_replay_clock")
        self.assertEqual(result["unmeasured"]["zh_final"], 1)
        self.assertIsNone(result["first_result_latency_from_t0_s"])

    def test_first_result_not_first_final_and_complete_fallback(self):
        result = m.latency_join([segment()], [clock(), event("request", 105), event("first_text", 105.1), event("complete", 109)], [cue()], 120)
        self.assertAlmostEqual(result["first_result_latency_from_t0_s"], 5.1)
        self.assertEqual(result["first_final_latency_from_t0_s"], 9)
        result = m.latency_join([segment()], [clock(), event("request", 105), event("complete_after_retry", 108)], [cue()], 120)
        self.assertEqual(result["first_result_latency_from_t0_s"], 8)

    def test_nonaccepted_complete_is_not_a_result(self):
        result = m.latency_join([segment(chinese="", state="failed")],
                                [clock(), event("request", 105), event("complete", 106, accepted=0)], [cue()], 120)
        self.assertIsNone(result["first_result_latency_from_t0_s"])
        self.assertEqual(result["censored"]["zh_final"], 1)

    def test_negative_delay_invalidates_observed_numbers(self):
        result = m.latency_join([segment()], [clock(), event("request", 100, elapsed=500), event("complete", 106)], [cue()], 120)
        self.assertGreater(result["negative_delays"], 0)
        self.assertFalse(result["latency_valid"])
        self.assertIsNone(result["zh_final"]["all"]["median_seconds"])
        self.assertIsNone(result["first_result_latency_from_t0_s"])

    def test_private_basis_and_numeric_rows_have_no_ids(self):
        result = m.latency_join([segment(english=SENTINEL, chinese=SENTINEL)],
                                [clock(), event("request", 105), event("complete", 106)], None, 120)
        self.assertEqual(result["basis"], "actual_bilingual_cues_no_gold")
        self.assertEqual(result["cues"], 1)
        for row in result["rows"]:
            self.assertTrue(all(value is None or isinstance(value, (int, float)) for value in row.values()))
        text = json.dumps(result)
        self.assertNotIn(SENTINEL, text)
        self.assertNotIn(ID1, text)

    def test_steady_subset_and_preview_ms(self):
        segments = [segment(), segment(ID2, 60, 64, "gamma")]
        events = [clock(), event("request", 105), event("complete", 106),
                  event("request", 165, ID2), event("complete", 167, ID2),
                  {"kind": "preview", "event": "result", "timestamp": 110, "captured_since_range_end_ms": 1234},
                  {"event": "state", "pendingTranscription": 5}, {"event": "processing_finished", "stopSeconds": 2}]
        result = m.latency_join(segments, events, None, 180)
        self.assertEqual(result["zh_final"]["all"]["count"], 2)
        self.assertEqual(result["zh_final"]["steady"]["count"], 1)
        self.assertEqual(result["zh_final"]["steady"]["median_seconds"], 3)
        self.assertEqual(result["preview_result_lag_ms"]["median_ms"], 1234)
        self.assertEqual(result["max_pending_transcription"], 5)
        self.assertEqual(result["tail_seconds"], 2)

    def test_repair_does_not_replace_first_completion(self):
        result = m.latency_join([segment()], [clock(), event("request", 105), event("complete", 106),
                                             event("complete", 110), event("adjacent_repair", 111), event("adjacent_repair_kept", 112)], [cue()], 120)
        self.assertEqual(result["rows"][0]["final_wall"], 106)
        self.assertEqual(result["repair_count"], 2)

    def test_unmeasured_censor_horizon_is_not_invented(self):
        result = m.latency_join([segment(chinese="", state="failed")], [clock(), event("request", 105)], [cue()])
        self.assertEqual(result["zh_final"]["all"]["censor_horizon_unmeasured"], 1)
        self.assertIsNone(result["zh_final"]["all"]["censor_lower_bounds"]["median_seconds"])


class TranslationAndTimingTests(unittest.TestCase):
    def test_t1_multiple_candidates_nfkc_and_spaces(self):
        cases = [{"id": "a", "cat": "否定", "must": [["不", "非"], ["4d"]]},
                 {"id": "b", "cat": "术语", "must": [["算法"]]}]
        result = m.translation_t1(cases, ["非 ４ｄ", "缺少术语"])
        self.assertEqual(result["sentences"], 2)
        self.assertEqual(result["pass"], 1)
        self.assertEqual(result["groups_hit"], 2)
        self.assertEqual(result["groups_total"], 3)
        self.assertEqual(result["by_category"]["否定"]["pass_rate"], 1)

    def test_t1_missing_error_and_unknown_category(self):
        cases = [{"id": "a", "category": SENTINEL, "must": [["中文"]]},
                 {"id": "b", "must": [["中文"]]}]
        result = m.translation_t1(cases, {"a": {"output": "中文", "error": SENTINEL}})
        self.assertEqual(result["errors"], 2)
        self.assertEqual(result["pass"], 0)
        self.assertEqual(result["by_category"]["unknown"]["sentences"], 2)
        self.assertNotIn(SENTINEL, json.dumps(result))

    def test_authored_fixture_schema_and_actual_denominators(self):
        path = ROOT / "Fixtures/scoreboard-v1/translation-authored-80.json"
        if not path.is_file():
            self.skipTest("Authored fixture unavailable")
        cases = json.loads(path.read_text())
        outputs = [" ".join(group[0] for group in case["must"]) for case in cases]
        result = m.translation_t1(cases, outputs)
        self.assertEqual((result["sentences"], result["groups_total"]), (80, 268))
        self.assertEqual((result["pass"], result["groups_hit"]), (80, 268))
        self.assertEqual(len(result["by_category"]), 9)

    def test_t2_glossary_uses_word_boundaries_and_counts_once_per_entry(self):
        glossary = {"entries": [{"english": ["array"], "chinese": ["数组"]},
                                 {"english": ["binary search"], "chinese": ["二分搜索", "二分查找"]}]}
        segments = [segment(english="array array binary search", chinese="数组，二分搜索"),
                    segment(ID2, english="arrayish research", chinese="数组")]
        result = m.translation_t2(segments, glossary=glossary)
        self.assertEqual(result["glossary"]["occurrences"], 2)
        self.assertEqual(result["glossary"]["hits"], 2)
        self.assertEqual(result["glossary"]["rate"], 1)

    def test_glossary_fixture_terms_and_translations_are_used_consistently(self):
        glossary = json.loads((ROOT / "Fixtures/scoreboard-v1/cs50-glossary-v1.json").read_text())
        self.assertEqual(glossary["version"], "cs50-glossary-v1")
        self.assertEqual(glossary["review_status"], "draft_requires_human_review")
        entries = glossary["entries"]
        for entry in entries:
            for term in entry["english"]:
                for translation in entry["chinese"]:
                    result = m.translation_t2([segment(english=term, chinese=translation)], glossary={"entries": [entry]})
                    self.assertEqual(result["glossary"]["occurrences"], 1)
                    self.assertEqual(result["glossary"]["hits"], 1)

    def test_t2_leak_untranslated_and_completion(self):
        glossary = {"entries": [{"english": "algorithm", "chinese": ["算法"]}]}
        segments = [segment(english="three English words", chinese="int NASA algorithm rogue Cat ab", state="failed"),
                    segment(ID2, english="one two three", chinese="中文")]
        events = [{"event": "processing_finished", "segments": 2, "translated": 1},
                  {"event": "saved_verified", "missingTranslations": 1}, event("retry_repairContent", 110), event("rejected", 109)]
        result = m.translation_t2(segments, events, glossary)
        self.assertEqual(result["completion"], 0.5)
        self.assertEqual(result["completion_source"], "processing_finished")
        self.assertEqual(result["untranslated_segments"], 1)
        self.assertEqual(result["latin_leak_words"], 2)
        self.assertAlmostEqual(result["latin_leak_per_100w"], 100 / 3)
        self.assertEqual(result["log_events_per_100_segments"]["retry"], 50)

    def test_t2_absent_logs_and_glossary_are_unknown_not_zero(self):
        result = m.translation_t2([segment(english=SENTINEL, chinese=SENTINEL, state=SENTINEL)])
        self.assertIsNone(result["glossary"]["rate"])
        self.assertIsNone(result["glossary"]["occurrences"])
        self.assertIsNone(result["log_event_counts"])
        self.assertEqual(result["translation_state"]["unknown"], 1)
        self.assertNotIn(SENTINEL, json.dumps(result))

    def test_model_request_elapsed_is_never_pure_model_time(self):
        result = m.model_times([event("request", 105, elapsed=5000), event("complete", 110, elapsed=10000),
                                {"kind": "preview", "event": "delivered", "execute_ms": 500}])
        self.assertEqual(result["measured_events"], 0)
        for stage in result["by_stage"].values():
            self.assertIsNone(stage["total_seconds"])
            self.assertIsNone(stage["coverage"]["fraction"])
            self.assertEqual(stage["source"], "unmeasured")

    def test_explicit_numeric_model_stage_only(self):
        result = m.model_times([{"event": "model_timing", "stage": "asr_inference", "duration_ms": 2000},
                                {"event": "model_timing", "stage": SENTINEL, "duration_ms": 1000}],
                               [{"kind": "model", "event": "timing", "stage": "translation_load", "duration_s": 3}])
        self.assertEqual(result["measured_events"], 2)
        self.assertEqual(result["by_stage"]["asr_inference"]["total_seconds"], 2)
        self.assertEqual(result["by_stage"]["translation_load"]["source"], "stderr_numeric")
        self.assertNotIn(SENTINEL, json.dumps(result))


class StatsAndPrivacyTests(unittest.TestCase):
    def test_nearest_rank_p95_median_and_outliers(self):
        result = m.distribution(range(1, 21))
        self.assertEqual(result["p95_seconds"], 19)
        self.assertEqual(result["median_seconds"], 10.5)
        self.assertEqual(m.distribution([1, 2, 999])["max_seconds"], 999)
        self.assertIsNone(m.distribution([])["median_seconds"])

    def test_repeat_summary_missing_and_sample_sd(self):
        result = m.summarize_repeats([1, 2, 3, None])
        self.assertEqual((result["n"], result["n_unmeasured"]), (3, 1))
        self.assertEqual(result["mean"], 2)
        self.assertEqual(result["sd"], 1)
        self.assertIsNone(m.summarize_repeats([1])["sd"])
        self.assertIsNone(m.summarize_repeats([])["mean"])

    def test_paired_t_ci_and_small_n(self):
        result = m.paired_ci([1, 2, 3])
        self.assertAlmostEqual(result["t_critical"], 4.302652729749, places=9)
        self.assertAlmostEqual(result["ci95"][0], 2 - 4.302652729749 / math.sqrt(3), places=9)
        self.assertIsNone(m.paired_ci([1, 2])["ci95"])
        self.assertEqual(m.paired_ci([(10, 11), (20, 22), (30, 33)])["mean_delta"], 2)
        self.assertEqual(m.paired_ci([2, 2, 2])["ci95"], [2, 2])

    def test_nonfinite_stats_rejected(self):
        for value in (float("nan"), float("inf"), True, SENTINEL):
            with self.assertRaises(ValueError) as caught:
                m.summarize_repeats([value])
            self.assertNotIn(SENTINEL, str(caught.exception))

    def test_privacy_sentinel_absent_from_results_and_stdout_stderr(self):
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            results = {"latency": m.latency_join([segment(english=SENTINEL, chinese=SENTINEL)],
                                                [clock(), event("request", 105), event("complete", 106)], None, 120),
                       "translation": m.translation_t2([segment(english=SENTINEL, chinese=SENTINEL)]),
                       "asr": m.score_asr([cue(text=SENTINEL)], [segment(english=SENTINEL)]),
                       "oslog": m.parse_oslog_numeric([{"timestamp": 100, "event": SENTINEL, "id": SENTINEL}])}
            text = json.dumps(results, ensure_ascii=False)
            markdown = "```json\n" + text + "\n```"
        for output in (text, markdown, stdout.getvalue(), stderr.getvalue()):
            self.assertNotIn(SENTINEL, output)
            self.assertNotIn(ID1, output)
        self.assertEqual(stdout.getvalue(), "")
        self.assertEqual(stderr.getvalue(), "")


if __name__ == "__main__":
    unittest.main()
