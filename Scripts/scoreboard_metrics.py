"""Offline scoreboard metrics. Standard library only; no processes or writes.

Metric results contain counts, numbers and fixed enums, never input text/IDs.
parse_ndjson is deliberately a lossless input reader, NOT a privacy sanitizer.
parse_oslog_numeric is the allowlist sanitizer for persisted OSLog records.
See work/metrics-tests/API.md for input shapes and missing/censored semantics.
"""

import base64
import hashlib
import json
import math
from datetime import datetime
from pathlib import Path
import re
import statistics
import unicodedata


__all__ = ["tokens_raw", "normalize_v1", "align", "critical_counts",
           "parse_ndjson", "parse_oslog_numeric", "durable_census", "score_asr",
           "distribution", "latency_join", "model_times", "translation_t1",
           "translation_t2", "summarize_repeats", "paired_ci"]

_RULES_PATH = Path(__file__).resolve().parent.parent / "Fixtures/scoreboard-v1/normalizer-v1.json"
try:
    _RULES = json.loads(_RULES_PATH.read_text(encoding="utf-8"))
except (OSError, ValueError):
    raise ValueError("Normalizer rules unavailable") from None
_FILLERS = frozenset(_RULES["filler_words"])
_EQUIVALENTS = _RULES["equivalents"]
_NEGATION = frozenset(_RULES["negation"])
_CODE = frozenset(_RULES["code"])
_RAW_RE = re.compile(r"[a-z0-9]+(?:'[a-z]+)?")
_UUID_RE = re.compile(r"[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\Z")
_HASH_RE = re.compile(r"(?:[0-9a-fA-F]{32}|[0-9a-fA-F]{40}|[0-9a-fA-F]{64})\Z")
_SMALL = dict(zip(("zero one two three four five six seven eight nine ten eleven twelve "
                   "thirteen fourteen fifteen sixteen seventeen eighteen nineteen").split(), range(20)))
_TENS = dict(zip("twenty thirty forty fifty sixty seventy eighty ninety".split(), range(20, 100, 10)))
_SCALES = {"thousand": 1000, "million": 10**6, "billion": 10**9}
_ORDINALS = ("first second third fourth fifth sixth seventh eighth ninth tenth eleventh twelfth "
             "thirteenth fourteenth fifteenth sixteenth seventeenth eighteenth nineteenth twentieth "
             "twenty-first twenty-second twenty-third twenty-fourth twenty-fifth twenty-sixth "
             "twenty-seventh twenty-eighth twenty-ninth thirtieth thirty-first").split()
_STATUSES = ("pending", "active", "retryWaiting", "manualPending", "completed", "silent", "failed", "otherLanguage")
_PENDING = frozenset(("pending", "active", "retryWaiting", "manualPending"))
_FAILURES = ("englishGateHanDominant", "englishGateNoLatin", "emptyOutput", "invalidText",
             "repeatedLoop", "runawayText", "error", "interrupted")
_ISSUES = ("transcription_missing", "transcription_non_english", "transcription_retry",
           "capture_gap", "recording_diagnostic_write_failed")
_TRANSLATION_STATES = ("pending", "translating", "completed", "failed", "unknown")
_TRANSLATION_FAILURES = ("processExited", "requestTimedOut", "outputLimitReached", "translationRejected",
                         "cancelled", "interrupted", "runtimeUnavailable", "invalidResponse",
                         "generationInterrupted", "requestFailed", "dependencyCancelled", "unknown")
_COMPLETE = frozenset(("complete", "complete_adjacent", "complete_after_retry"))
_FIRST = _COMPLETE | {"first_text", "current_preview"}
_MODEL_STAGES = ("asr_load", "asr_inference", "translation_load", "translation_inference",
                 "preview_load", "preview_inference")
_STOP_STAGES = ("capture_closed", "audio_and_initial_state_saved")
_CATEGORIES = frozenset(("ReplayClock", "TranslationLatency", "PreviewLatency", "RecordingDiagnostics",
                         "ASRLatency", "ModelLatency", "ModelTiming", "unknown"))
_KINDS = frozenset(("caption", "preview", "replay", "stop", "asr", "model", "caption_failure", "unknown"))
_EVENTS = frozenset(("start", "end", "backend", "first_result", "result", "request", "first_text",
                     "current_preview", "complete", "complete_adjacent", "complete_after_retry",
                     "rejected", "failed", "adjacent_repair", "adjacent_repair_kept",
                     "retry_ordinary", "retry_content", "retry_outputLimit", "retry_transport",
                     "retry_standard", "retry_repairContent", "retry_expandedBudget",
                     "delivered", "main_hop", "released", "timing", "unknown") + _ISSUES)
_NUMERIC_FIELDS = frozenset(("elapsed_ms", "duration_ms", "duration_s", "sample_rate", "frames",
                            "fed_seconds", "captured_since_range_end_ms", "since_first_audio_ms",
                            "queue_ms", "scheduler_delay_ms", "execute_ms", "first_source_to_result_ms",
                            "chars", "suppressed", "has_diagnostic", "accepted", "count", "failures",
                            "backoff_ms", "window_ms", "events", "worst_ms", "last_ms", "code",
                            "has_interval", "samples_total"))
_T1_CATEGORIES = frozenset(("negation", "terminology", "terms", "paragraph", "paragraphs", "multi_sentence",
                           "instruction_like", "instructions", "spoken_numbers", "spoken_quantities",
                           "spoken_formulas", "classroom_admin", "classroom", "number_units", "numbers_units",
                           "colloquial", "oral", "unknown"))
_T1_CATEGORIES |= {"像指令的句子", "口语", "口述公式", "口述数字", "否定", "多句段落", "数字单位", "术语", "课堂事务"}


def _number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError("Invalid numeric metric input") from None
    try:
        finite = math.isfinite(value)
    except (OverflowError, ValueError):
        finite = False
    if not finite:
        raise ValueError("Invalid numeric metric input") from None
    return value


def _maybe_number(value):
    try:
        return _number(value)
    except ValueError:
        return None


def _integer(value):
    number = _number(value)
    if number < 0 or int(number) != number:
        raise ValueError("Invalid integer metric input") from None
    return int(number)


def _text(value):
    if not isinstance(value, str):
        raise ValueError("Invalid text metric input") from None
    return value


def tokens_raw(text):
    """LL4's original ASCII tokenization, exactly (no Unicode normalization)."""
    return _RAW_RE.findall(_text(text).lower())


def _small_number(tokens, offset):
    token = tokens[offset]
    if token in _TENS:
        value, end = _TENS[token], offset + 1
        if end < len(tokens) and tokens[end] in _SMALL and 0 < _SMALL[tokens[end]] < 10:
            value += _SMALL[tokens[end]]
            end += 1
        return value, end
    if token in _SMALL:
        return _SMALL[token], offset + 1
    if token in ("a", "an") and offset + 1 < len(tokens) and tokens[offset + 1] in ({"hundred"} | _SCALES.keys()):
        return 1, offset + 1
    return None, offset


def _number_group(tokens, offset):
    value, end = _small_number(tokens, offset)
    if value is None:
        if tokens[offset] == "hundred":
            return 100, offset + 1
        return None, offset
    if 0 < value < 100 and end < len(tokens) and tokens[end] == "hundred":
        value *= 100
        end += 1
        after = end
        if after < len(tokens) and tokens[after] == "and":
            after += 1
        if after < len(tokens) and tokens[after] in (_SMALL.keys() | _TENS.keys()):
            extra, extra_end = _small_number(tokens, after)
            value += extra
            end = extra_end
    return value, end


def _english_integer(tokens, offset):
    total, cursor, last_scale = 0, offset, math.inf
    while cursor < len(tokens):
        value, end = _number_group(tokens, cursor)
        if value is None:
            break
        if end < len(tokens) and tokens[end] in _SCALES and _SCALES[tokens[end]] < last_scale and value > 0:
            last_scale = _SCALES[tokens[end]]
            total += value * last_scale
            cursor = end + 1
            continue
        total += value
        cursor = end
        break
    return (total, cursor) if cursor > offset else (None, offset)


def normalize_v1(text):
    """Frozen norm_v1; integers become digits, n't forms expand before scoring."""
    normalized = unicodedata.normalize("NFKC", _text(text)).translate(str.maketrans({"’": "'", "‘": "'", "ʼ": "'"}))
    expanded = []
    for token in tokens_raw(normalized):
        if token in _FILLERS:
            continue
        if token in _EQUIVALENTS:
            expanded.extend(_EQUIVALENTS[token])
        elif token.endswith("n't"):
            expanded.extend((token[:-3], "not"))
        else:
            expanded.append(token)
    result, index = [], 0
    while index < len(expanded):
        token = expanded[index]
        ordinal = re.fullmatch(r"([0-9]+)(st|nd|rd|th)", token)
        if ordinal and 1 <= int(ordinal[1]) <= 31:
            result.extend(_ORDINALS[int(ordinal[1]) - 1].split("-"))
            index += 1
        elif token in ("twenty", "thirty") and index + 1 < len(expanded) and (
                expanded[index + 1] in _ORDINALS[:9] if token == "twenty" else expanded[index + 1] == "first"):
            result.extend(expanded[index:index + 2])
            index += 2
        elif token.isascii() and token.isdigit():
            result.extend(token)
            index += 1
        else:
            value, end = _english_integer(expanded, index)
            if value is None:
                result.append(token)
                index += 1
            else:
                result.extend(str(value))
                index = end
    return result


def distribution(values, *, censored=0, unmeasured=0, invalid=False):
    """Observed-only distribution: median and nearest-rank P95, no trimming."""
    samples = sorted(_number(value) for value in values)
    censored, unmeasured = _integer(censored), _integer(unmeasured)
    measured = bool(samples) and not invalid
    return {"count": len(samples), "mean_seconds": statistics.mean(samples) if measured else None,
            "median_seconds": statistics.median(samples) if measured else None,
            "p50_seconds": statistics.median(samples) if measured else None,
            "p95_seconds": samples[math.ceil(0.95 * len(samples)) - 1] if measured else None,
            "max_seconds": samples[-1] if measured else None,
            "p95_method": "nearest_rank", "population": "observed_censored" if censored else "observed",
            "censored": censored, "unmeasured": unmeasured,
            "full_population_quantiles": not (censored or unmeasured or invalid), "valid": not invalid}


def _events(data):
    rows = parse_ndjson(data)
    result = []
    for row in rows:
        if "eventMessage" in row:
            result.extend(parse_oslog_numeric([row]))
        else:
            result.append(row)
    return result


def _event_kind(row):
    kind = row.get("kind")
    if isinstance(kind, str) and kind in _KINDS:
        return kind
    category = row.get("category")
    return {"ReplayClock": "replay", "TranslationLatency": "caption", "PreviewLatency": "preview",
            "ModelLatency": "model", "ModelTiming": "model"}.get(category, "unknown") if isinstance(category, str) else "unknown"


def _wall(row):
    return _timestamp(row.get("timestamp", row.get("recv_wall")))


def _accepted(row):
    return row.get("accepted", 1) not in (False, 0)


def latency_join(segments, events, reference=None, run_end_wall=None):
    """Cue-level event latency, using content + +/-3s association for gold cues.

    Missing replay=start makes time differences unmeasured; no guessed fallback.
    Unmatched or unfinished cues are right-censored. Known results without their
    logs are unmeasured. Censored bounds require a measured run-end wall time.
    No complete-population quantiles or text/ID rows are returned.
    """
    segments, events = list(segments), _events(events)
    for segment in segments:
        _span(segment)
    starts = [_wall(row) for row in events if ((_event_kind(row) == "replay" and row.get("event") == "start")
                                               or row.get("event") == "replay_start") and _wall(row) is not None]
    t0 = min(starts) if starts else None
    if run_end_wall is not None:
        run_end_wall = _number(run_end_wall)
    else:
        ends = [_wall(row) for row in events if row.get("event") == "processing_finished" and _wall(row) is not None]
        run_end_wall = max(ends) if ends else None
    if t0 is not None and run_end_wall is not None and run_end_wall < t0:
        raise ValueError("Invalid run clock interval") from None
    caption_events = {}
    for row in events:
        if _event_kind(row) != "caption" or _wall(row) is None or not isinstance(row.get("id"), str):
            continue
        caption_events.setdefault(row["id"].lower(), []).append(row)
    for rows in caption_events.values():
        rows.sort(key=_wall)
    timings = []
    for segment in segments:
        identity = segment.get("id")
        rows = caption_events.get(identity.lower(), []) if isinstance(identity, str) else []
        requests = [row for row in rows if row.get("event") == "request"]
        request = requests[0] if requests else None
        elapsed = _maybe_number(request.get("elapsed_ms")) if request is not None else None
        en_time = _wall(request) - elapsed / 1000 if elapsed is not None and elapsed >= 0 else None
        first = [_wall(row) for row in rows if row.get("event") in _FIRST and _accepted(row)]
        final = [_wall(row) for row in rows if row.get("event") in _COMPLETE and _accepted(row)]
        chinese = segment.get("chinese", "")
        if not isinstance(chinese, str):
            raise ValueError("Invalid subtitle translation") from None
        state = segment.get("translationState")
        completed = (state == "completed" or (state is None and bool(chinese.strip()))) and bool(chinese.strip())
        timings.append({"en_commit": en_time, "zh_first": min(first) if first else None,
                        "zh_final": min(final) if final else None, "request": request is not None,
                        "first_known": bool(chinese.strip()), "final_known": completed})
    if reference is None:
        cues = [{"start_rel": _span(segment)[0], "end_rel": _span(segment)[1]} for segment in segments]
        associated = [{index} for index in range(len(segments))]
        ref_counts, match_counts = None, None
        basis = "actual_bilingual_cues_no_gold"
    else:
        cues = list(reference)
        ref_tokens, ref_times, ref_owners = _timed_tokens(cues, normalize_v1, True)
        hyp_tokens, hyp_times, hyp_owners = _timed_tokens(segments, normalize_v1)
        alignment = align(ref_tokens, hyp_tokens, reference_times=ref_times, hypothesis_times=hyp_times)
        associated = [set() for unused in cues]
        ref_counts = [0] * len(cues)
        match_counts = [0] * len(cues)
        for owner in ref_owners:
            ref_counts[owner] += 1
        for operation in alignment["ops"]:
            if operation["op"] == "equal":
                owner = ref_owners[operation["ref_index"]]
                associated[owner].add(hyp_owners[operation["hyp_index"]])
                match_counts[owner] += 1
        basis = "reference_cues_content_and_time"
    metric_names = ("en_commit", "zh_first", "zh_final", "zh_final_from_start")
    samples = {name: [] for name in metric_names}
    reasons = {name: dict.fromkeys(("unmatched", "partial_content_match", "not_finalized", "no_first_result", "missing_log", "missing_t0"), 0)
               for name in metric_names}
    covered, cue_rows = 0, []
    for sequence, (cue, matched) in enumerate(zip(cues, associated), 1):
        start, end = _span(cue, True)
        steady = end >= 60
        relevant = [timings[index] for index in matched]
        reference_count = ref_counts[sequence - 1] if ref_counts is not None else None
        matched_count = match_counts[sequence - 1] if match_counts is not None else None
        match_fraction = matched_count / reference_count if reference_count else None
        content_complete = reference is None or (bool(reference_count) and matched_count == reference_count)
        covered += int(bool(relevant) and all(timing["request"] for timing in relevant))
        cue_row = {"sequence": sequence, "audio_start_wall": t0 + start if t0 is not None else None,
                   "audio_end_wall": t0 + end if t0 is not None else None, "matched_captions": len(matched),
                   "reference_tokens": reference_count, "matched_tokens": matched_count,
                   "match_fraction": match_fraction, "content_complete": int(content_complete), "steady": int(steady)}
        for name in metric_names:
            key = "zh_final" if name == "zh_final_from_start" else name
            observed = [timing[key] for timing in relevant if timing[key] is not None]
            value, bound, reason = None, None, None
            if t0 is None:
                status, reason = "unmeasured", "missing_t0"
            elif not matched:
                status, reason = "censored", "unmatched"
            elif key != "zh_first" and not content_complete:
                status, reason = "censored", "partial_content_match"
            elif observed and (key == "zh_first" or len(observed) == len(relevant)):
                whole_time = min(observed) if key == "zh_first" else max(observed)
                value = whole_time - (t0 + (start if name == "zh_final_from_start" else end))
                status = "observed"
            elif key == "en_commit" or (key == "zh_first" and any(timing["first_known"] for timing in relevant)) or (
                    key == "zh_final" and all(timing[key] is not None or timing["final_known"] for timing in relevant)):
                status, reason = "unmeasured", "missing_log"
            else:
                status, reason = "censored", "no_first_result" if key == "zh_first" else "not_finalized"
            if status == "censored" and run_end_wall is not None:
                bound = max(0, run_end_wall - (t0 + (start if name == "zh_final_from_start" else end)))
            if reason is not None:
                reasons[name][reason] += 1
            samples[name].append({"status": status, "value": value, "bound": bound, "steady": steady})
            wall_key = {"en_commit": "en_commit_wall", "zh_first": "first_wall", "zh_final": "final_wall"}.get(name)
            if wall_key is not None:
                cue_row[wall_key] = ((min(observed) if key == "zh_first" else max(observed))
                                     if observed and (key == "zh_first" or (content_complete and len(observed) == len(relevant))) else None)
            cue_row[name + "_censored"] = int(status == "censored")
            cue_row[name + "_unmeasured"] = int(status == "unmeasured")
        cue_rows.append(cue_row)
    negative = sum(sample["value"] < -0.1 for rows in samples.values() for sample in rows if sample["value"] is not None)
    censored = {name: sum(sample["status"] == "censored" for sample in rows) for name, rows in samples.items()}
    unmeasured = {name: sum(sample["status"] == "unmeasured" for sample in rows) for name, rows in samples.items()}
    any_censored = any(censored.values())
    result = {"basis": basis, "cues": len(cues), "caption_segments": len(segments),
              "matched_cues": sum(bool(matched) for matched in associated),
              "unmatched_cues": sum(not matched for matched in associated),
              "fully_matched_cues": sum(row["content_complete"] for row in cue_rows),
              "partially_matched_cues": sum(bool(row["matched_captions"]) and not row["content_complete"] for row in cue_rows),
              "reference_token_match_fraction": sum(match_counts) / sum(ref_counts) if ref_counts is not None and sum(ref_counts) else None,
              "matching_window_seconds": 3.0, "steady_from_audio_s": 60.0,
              "t0": t0, "t0_anchor": "replay_clock" if t0 is not None else "missing_replay_clock",
              "run_end_wall": run_end_wall, "rows": cue_rows, "censored": censored, "unmeasured": unmeasured,
              "missing_reasons": reasons, "negative_delays": negative,
              "latency_valid": t0 is not None and not negative,
              "log_coverage": covered / len(cues) if cues else None,
              "caption_log_coverage": sum(timing["request"] for timing in timings) / len(segments) if segments else None,
              "latency_incomplete": t0 is None or bool(any(unmeasured.values())) or (bool(cues) and covered / len(cues) < 0.98),
              "repair_count": sum(row.get("event") in ("adjacent_repair", "adjacent_repair_kept")
                                  for rows in caption_events.values() for row in rows)}
    for name, rows in samples.items():
        result[name] = {}
        for subset in ("all", "steady"):
            selected = [sample for sample in rows if subset == "all" or sample["steady"]]
            c_count = sum(sample["status"] == "censored" for sample in selected)
            u_count = sum(sample["status"] == "unmeasured" for sample in selected)
            dist = distribution([sample["value"] for sample in selected if sample["status"] == "observed"],
                                censored=c_count, unmeasured=u_count, invalid=bool(negative) or t0 is None)
            if any_censored:
                dist["population"] = "observed_censored"
                dist["full_population_quantiles"] = False
            dist["censor_lower_bounds"] = distribution([sample["bound"] for sample in selected if sample["bound"] is not None])
            dist["censor_horizon_unmeasured"] = sum(sample["status"] == "censored" and sample["bound"] is None for sample in selected)
            result[name][subset] = dist
    first_results = [_wall(row) for rows in caption_events.values() for row in rows
                     if row.get("event") in _FIRST and _accepted(row)]
    first_finals = [_wall(row) for rows in caption_events.values() for row in rows
                    if row.get("event") in _COMPLETE and _accepted(row)]
    result["first_result_latency_from_t0_s"] = min(first_results) - t0 if first_results and t0 is not None and not negative else None
    result["cold_start_first_zh_s"] = result["first_result_latency_from_t0_s"]
    result["first_final_latency_from_t0_s"] = min(first_finals) - t0 if first_finals and t0 is not None and not negative else None
    lags = [_maybe_number(row.get("captured_since_range_end_ms")) for row in events
            if _event_kind(row) == "preview" and row.get("event") in ("result", "first_result")]
    # These samples are milliseconds, so keys explicitly carry the correct unit.
    lag_distribution = distribution([lag / 1000 for lag in lags if lag is not None])
    result["preview_result_lag_ms"] = {key.replace("_seconds", "_ms"): (value * 1000 if key.endswith("_seconds") and value is not None else value)
                                       for key, value in lag_distribution.items()}
    finished = [row for row in events if row.get("event") == "processing_finished"]
    result["tail_seconds"] = _maybe_number(finished[-1].get("stopSeconds")) if finished else None
    pending = [_maybe_number(row.get("pendingTranscription")) for row in events if row.get("event") == "state"]
    result["max_pending_transcription"] = max((value for value in pending if value is not None), default=None)
    return result


def model_times(events, stderr_numeric=None):
    """Only explicit independent model timings; queue/end-to-end times excluded.

    Eligible contract: kind=model/event=timing (or event=model_timing), a fixed
    stage, duration_ms/duration_s. Existing ASR child's stdout isn't CLI output;
    absent observations remain null, with no invented coverage denominator.
    """
    measured = {stage: [] for stage in _MODEL_STAGES}
    sources = {stage: set() for stage in _MODEL_STAGES}
    for source, rows in (("events", _events(events)),
                         ("stderr_numeric", _events(stderr_numeric) if stderr_numeric is not None else [])):
        for row in rows:
            if not ((_event_kind(row) == "model" and row.get("event") == "timing") or row.get("event") == "model_timing"):
                continue
            stage = row.get("stage")
            if not isinstance(stage, str) or stage not in measured:
                continue
            seconds = _maybe_number(row.get("duration_s"))
            if seconds is None:
                milliseconds = _maybe_number(row.get("duration_ms"))
                seconds = milliseconds / 1000 if milliseconds is not None else None
            if seconds is not None and seconds >= 0:
                measured[stage].append(seconds)
                sources[stage].add(source)
    by_stage = {}
    for stage, values in measured.items():
        by_stage[stage] = {"measured": len(values), "total_seconds": sum(values) if values else None,
                           "distribution": distribution(values) if values else None,
                           "coverage": {"measured": len(values), "eligible": None, "fraction": None},
                           "source": "mixed" if len(sources[stage]) > 1 else next(iter(sources[stage]), "unmeasured")}
    return {"by_stage": by_stage, "measured_events": sum(map(len, measured.values())),
            "unmeasured_stages": sum(not values for values in measured.values()),
            "timing_policy": "independent_duration_only", "request_elapsed_policy": "queue_time_excluded"}


def _compact(text):
    return "".join(unicodedata.normalize("NFKC", _text(text)).split())


def _output_text(output):
    if isinstance(output, str):
        return output, False
    if not isinstance(output, dict):
        return "", True
    error = bool(output.get("error")) or output.get("ok") is False or output.get("success") is False or output.get("exit_code", 0) != 0
    for key in ("output", "translation", "chinese", "text"):
        if isinstance(output.get(key), str):
            return output[key], error
    return "", True


def translation_t1(cases, outputs):
    """Authored must-groups proxy; actual denominator, no case/output text."""
    cases = list(cases["cases"] if isinstance(cases, dict) else cases)
    if isinstance(outputs, dict):
        by_id = outputs
        ordered = None
    else:
        ordered = list(outputs)
        by_id = {row.get("id", row.get("case_id")): row for row in ordered if isinstance(row, dict) and ("id" in row or "case_id" in row)}
    result = {"sentences": len(cases), "pass": 0, "groups_hit": 0, "groups_total": 0,
              "errors": 0, "by_category": {}, "metric": "authored_must_group_proxy"}
    for index, case in enumerate(cases):
        if not isinstance(case, dict) or not isinstance(case.get("must"), list) or not case["must"]:
            raise ValueError("Invalid authored translation case") from None
        identity = case.get("id", index)
        output = by_id.get(identity)
        if output is None and ordered is not None and not by_id and index < len(ordered):
            output = ordered[index]
        text, error = _output_text(output)
        compact = _compact(text)
        hits = 0
        for group in case["must"]:
            candidates = [group] if isinstance(group, str) else group
            if not isinstance(candidates, (list, tuple)) or not candidates or any(not isinstance(term, str) or not _compact(term) for term in candidates):
                raise ValueError("Invalid authored must group") from None
            hits += int(not error and any(_compact(term) in compact for term in candidates))
        passed = not error and hits == len(case["must"])
        category = case.get("category", case.get("cat", "unknown"))
        category = category if isinstance(category, str) and category in _T1_CATEGORIES else "unknown"
        subtotal = result["by_category"].setdefault(category, {"sentences": 0, "pass": 0, "groups_hit": 0, "groups_total": 0})
        for target in (result, subtotal):
            if target is subtotal:
                target["sentences"] += 1
            target["pass"] += int(passed)
            target["groups_hit"] += hits
            target["groups_total"] += len(case["must"])
        result["errors"] += int(error)
    for target in [result] + list(result["by_category"].values()):
        target["sentence_pass_rate"] = target["pass"] / target["sentences"] if target["sentences"] else None
        target["pass_rate"] = target["sentence_pass_rate"]
        target["group_hit_rate"] = target["groups_hit"] / target["groups_total"] if target["groups_total"] else None
    return result


def _glossary(glossary):
    if glossary is None:
        return []
    entries = glossary.get("entries", []) if isinstance(glossary, dict) else glossary
    result = []
    for entry in entries:
        if not isinstance(entry, dict):
            raise ValueError("Invalid glossary entry") from None
        english, chinese = entry.get("english"), entry.get("chinese")
        english = [english] if isinstance(english, str) else english
        chinese = [chinese] if isinstance(chinese, str) else chinese
        if not isinstance(english, list) or not isinstance(chinese, list) or not english or not chinese:
            raise ValueError("Invalid glossary entry") from None
        terms = [normalize_v1(term) for term in english]
        targets = [_compact(term) for term in chinese]
        if any(not term for term in terms) or any(not term for term in targets):
            raise ValueError("Invalid glossary entry") from None
        result.append((terms, targets))
    return result


def translation_t2(segments, events=None, glossary=None):
    """Replay translation proxies. glossary=None disables CS50 term scoring."""
    segments = list(segments)
    rows = _events(events) if events is not None else None
    entries = _glossary(glossary)
    exempt = _CODE | {word for terms, unused in entries for term in terms for word in term}
    states = dict.fromkeys(_TRANSLATION_STATES, 0)
    english_words = untranslated = leaks = occurrences = hits = persisted_translated = 0
    for segment in segments:
        english, chinese = _text(segment.get("english", "")), _text(segment.get("chinese", ""))
        raw = tokens_raw(english)
        normalized = normalize_v1(english)
        compact = _compact(chinese)
        state = segment.get("translationState")
        if state is None:
            state = "completed" if chinese.strip() else "pending"
        state = state if isinstance(state, str) and state in states else "unknown"
        states[state] += 1
        persisted_translated += int(state == "completed" and bool(chinese.strip()))
        english_words += len(raw)
        han_count = sum("\u3400" <= char <= "\u4dbf" or "\u4e00" <= char <= "\u9fff" or "\U00020000" <= char <= "\U0002fa1f" for char in chinese)
        untranslated += int(len(raw) >= 3 and han_count < 2)
        leaks += sum(len(word) >= 3 and not word.isupper() and word.lower() not in exempt for word in re.findall(r"[A-Za-z]+", chinese))
        for terms, accepted in entries:
            present = any(any(normalized[index:index + len(term)] == term for index in range(len(normalized) - len(term) + 1)) for term in terms)
            if present:
                occurrences += 1
                hits += int(any(term in compact for term in accepted))
    finished = [row for row in (rows or []) if row.get("event") == "processing_finished"]
    final = finished[-1] if finished else {}
    total = _maybe_number(final.get("segments"))
    translated = _maybe_number(final.get("translated"))
    if total is not None and translated is not None:
        total, translated = _integer(total), _integer(translated)
        if translated > total:
            raise ValueError("Invalid translation completion counts") from None
        source = "processing_finished"
    else:
        total, translated, source = len(segments), persisted_translated, "persisted_translation_state"
    saved = [row for row in (rows or []) if row.get("event") == "saved_verified"]
    missing = _maybe_number(saved[-1].get("missingTranslations")) if saved else None
    missing = _integer(missing) if missing is not None else total - translated
    names = ("rejected", "failed", "retry", "complete_after_retry", "adjacent_repair", "adjacent_repair_kept")
    counts = dict.fromkeys(names, 0)
    for row in rows or []:
        if _event_kind(row) != "caption":
            continue
        event = row.get("event")
        if isinstance(event, str) and event.startswith("retry_") and event in _EVENTS:
            counts["retry"] += 1
        elif event in counts:
            counts[event] += 1
    return {"segments": total, "persisted_segments": len(segments), "translated": translated,
            "completion": translated / total if total else None, "completion_source": source,
            "translation_state": states, "missingTranslations": missing,
            "untranslated_segments": untranslated, "english_words": english_words, "latin_leak_words": leaks,
            "latin_leak_per_100w": leaks * 100 / english_words if english_words else None,
            "glossary": {"occurrences": occurrences if glossary is not None else None,
                         "hits": hits if glossary is not None else None,
                         "rate": hits / occurrences if occurrences else None,
                         "enabled": glossary is not None},
            "log_event_counts": counts if rows is not None else None,
            "log_events_per_100_segments": {name: count * 100 / total if rows is not None and total else None for name, count in counts.items()},
            "metric": "translation_proxy"}


def summarize_repeats(values):
    """Sample SD; None measurements excluded and explicitly counted."""
    values = list(values)
    samples = [_number(value) for value in values if value is not None]
    return {"n": len(samples), "n_unmeasured": len(values) - len(samples),
            "mean": statistics.mean(samples) if samples else None,
            "sd": statistics.stdev(samples) if len(samples) >= 2 else None,
            "min": min(samples) if samples else None, "max": max(samples) if samples else None}


def _beta_fraction(a, b, x):
    tiny, c = 1e-300, 1.0
    d = 1 - (a + b) * x / (a + 1)
    d = 1 / (d if abs(d) > tiny else tiny)
    h = d
    for m in range(1, 201):
        for numerator in (m * (b - m) * x / ((a + 2 * m - 1) * (a + 2 * m)),
                          -(a + m) * (a + b + m) * x / ((a + 2 * m) * (a + 2 * m + 1))):
            d = 1 + numerator * d
            d = d if abs(d) > tiny else tiny
            c = 1 + numerator / c
            c = c if abs(c) > tiny else tiny
            d = 1 / d
            delta = d * c
            h *= delta
        if abs(delta - 1) < 1e-14:
            return h
    raise ValueError("Student t computation did not converge") from None


def _regularized_beta(x, a, b):
    if x <= 0:
        return 0.0
    if x >= 1:
        return 1.0
    factor = math.exp(math.lgamma(a + b) - math.lgamma(a) - math.lgamma(b) + a * math.log(x) + b * math.log1p(-x))
    if x < (a + 1) / (a + b + 2):
        return factor * _beta_fraction(a, b, x) / a
    return 1 - factor * _beta_fraction(b, a, 1 - x) / b


def _t_critical(df):
    low, high = 0.0, 1.0

    def tail(value):
        return 0.5 * _regularized_beta(df / (df + value * value), df / 2, 0.5)

    while tail(high) > 0.025:
        high *= 2
    for unused in range(80):
        mid = (low + high) / 2
        if tail(mid) > 0.025:
            low = mid
        else:
            high = mid
    return (low + high) / 2


def paired_ci(values):
    """95% paired Student-t CI for n>=3. Deltas or (A,B) pairs (delta=B-A)."""
    deltas = []
    for value in values:
        if isinstance(value, (tuple, list)):
            if len(value) != 2:
                raise ValueError("Invalid paired metric input") from None
            deltas.append(None if None in value else _number(value[1]) - _number(value[0]))
        else:
            deltas.append(value)
    result = summarize_repeats(deltas)
    df = result["n"] - 1 if result["n"] else None
    critical = _t_critical(df) if result["n"] >= 3 else None
    margin = critical * result["sd"] / math.sqrt(result["n"]) if critical is not None else None
    result.update({"mean_delta": result["mean"], "df": df, "t_critical": critical,
                   "ci95": [result["mean"] - margin, result["mean"] + margin] if margin is not None else None,
                   "method": "paired_student_t", "delta_direction": "B_minus_A"})
    return result


def _object_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON field")
        result[key] = value
    return result


def _json(data):
    try:
        return json.loads(data, object_pairs_hook=_object_pairs,
                          parse_constant=lambda unused: (_ for _ in ()).throw(ValueError("Invalid JSON number")))
    except (ValueError, TypeError, UnicodeError, RecursionError):
        raise ValueError("Invalid JSON record") from None


def parse_ndjson(data):
    """Read bare JSON objects or flatten {recv_wall,recv_mono,line} envelopes.

    Accept UTF-8 str/bytes or an iterable of objects/JSON lines. Does not redact.
    Errors have fixed messages and never include the offending input.
    """
    if isinstance(data, bytes):
        try:
            data = data.decode("utf-8")
        except UnicodeError:
            raise ValueError("Invalid NDJSON encoding") from None
    rows = data.splitlines() if isinstance(data, str) else ([data] if isinstance(data, dict) else data)
    try:
        rows = iter(rows)
    except TypeError:
        raise ValueError("Invalid NDJSON input") from None
    result = []
    for row in rows:
        if isinstance(row, (str, bytes)) and not row.strip():
            continue
        obj = dict(row) if isinstance(row, dict) else _json(row)
        if not isinstance(obj, dict):
            raise ValueError("Invalid NDJSON object") from None
        if "line" in obj and ("recv_wall" in obj or "recv_mono" in obj):
            line = obj["line"]
            obj_inner = dict(line) if isinstance(line, dict) else _json(line)
            if not isinstance(obj_inner, dict):
                raise ValueError("Invalid NDJSON envelope") from None
            for key in ("recv_wall", "recv_mono"):
                if key in obj:
                    obj_inner[key] = _number(obj[key])
            obj = obj_inner
        result.append(obj)
    return result


def _timestamp(value):
    number = _maybe_number(value)
    if number is not None:
        return number
    if not isinstance(value, str):
        return None
    try:
        stamp = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return stamp.timestamp() if stamp.tzinfo is not None else None
    except (ValueError, OverflowError, OSError):
        return None


def parse_oslog_numeric(data):
    """Sanitize OSLog NDJSON or already numeric rows using fixed allowlists."""
    result = []
    for source in parse_ndjson(data):
        message = source.get("eventMessage")
        fields = dict(source)
        if isinstance(message, str):
            fields = dict(re.findall(r"\b([A-Za-z][A-Za-z0-9_]*)=([^\s]+)", message))
            leading = message.split(None, 1)[0] if message.strip() else "unknown"
            fields["kind"] = leading if leading in _KINDS else "unknown"
        category = source.get("category", "unknown")
        category = category if isinstance(category, str) and category in _CATEGORIES else "unknown"
        kind = fields.get("kind")
        if not isinstance(kind, str) or kind not in _KINDS:
            kind = {"ReplayClock": "replay", "TranslationLatency": "caption", "PreviewLatency": "preview",
                    "ModelLatency": "model", "ModelTiming": "model", "ASRLatency": "asr"}.get(category, "unknown")
        event = fields.get("event", "unknown")
        event = event if isinstance(event, str) and event in _EVENTS else "unknown"
        stamp = _timestamp(source.get("timestamp"))
        if stamp is None:
            continue
        row = {"timestamp": stamp, "category": category, "kind": kind, "event": event}
        identity = fields.get("id")
        if isinstance(identity, str) and (_UUID_RE.fullmatch(identity) or _HASH_RE.fullmatch(identity)):
            row["id"] = identity.lower()
        for key in _NUMERIC_FIELDS:
            value = fields.get(key)
            if isinstance(value, str):
                if value in ("true", "false"):
                    value = int(value == "true")
                elif re.fullmatch(r"[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?", value):
                    try:
                        value = float(value) if any(c in value for c in ".eE") else int(value)
                    except ValueError:
                        value = None
                else:
                    value = None
            if isinstance(value, bool):
                value = int(value)
            number = _maybe_number(value)
            if number is not None:
                row[key] = number
        for key, allowed in (("backend", ("modern", "legacy", "none")),
                             ("stage", _MODEL_STAGES + _STOP_STAGES),
                             ("reason", _FAILURES + _TRANSLATION_FAILURES + ("none",))):
            if key in fields:
                value = fields[key]
                row[key] = value if isinstance(value, str) and value in allowed else "unknown"
        result.append(row)
    return result


def _span(row, reference=False):
    if not isinstance(row, dict):
        raise ValueError("Invalid cue input") from None
    start_key, end_key = ("start_rel", "end_rel") if reference else ("startTime", "endTime")
    start, end = _number(row.get(start_key)), _number(row.get(end_key))
    if start < 0 or end < start:
        raise ValueError("Invalid cue interval") from None
    return start, end


def _timed_tokens(rows, tokenizer, reference=False):
    tokens, times, owners = [], [], []
    ordered = sorted(enumerate(rows), key=lambda pair: (_span(pair[1], reference)[0], pair[0]))
    for index, row in ordered:
        span = _span(row, reference)
        words = tokenizer(_text(row.get("text" if reference else "english", "")))
        tokens.extend(words)
        times.extend([span] * len(words))
        owners.extend([index] * len(words))
    return tokens, times, owners


def align(reference, hypothesis, *, reference_times=None, hypothesis_times=None, window_seconds=3.0):
    """Levenshtein with index-only operations. Time constraints forbid remote pairs.

    A diagonal match/substitution is legal iff the intervals overlap within the
    tolerance. Equal words outside that window cost a deletion plus insertion.
    Ties prefer diagonal, then deletion, then insertion, as in the LL4 scorer.
    """
    reference, hypothesis = list(reference), list(hypothesis)
    tolerance = _number(window_seconds)
    if tolerance < 0:
        raise ValueError("Invalid alignment window") from None
    timed = reference_times is not None or hypothesis_times is not None
    if timed and (reference_times is None or hypothesis_times is None
                  or len(reference_times) != len(reference) or len(hypothesis_times) != len(hypothesis)):
        raise ValueError("Invalid alignment intervals") from None
    if timed:
        for start, end in list(reference_times) + list(hypothesis_times):
            if _number(start) > _number(end):
                raise ValueError("Invalid alignment intervals") from None
    width = len(hypothesis) + 1
    back = [bytearray([3] * width)]
    previous = list(range(width))
    for i, ref in enumerate(reference, 1):
        row, trace = [i] + [0] * len(hypothesis), bytearray(width)
        trace[0] = 2
        for j, hyp in enumerate(hypothesis, 1):
            compatible = (not timed or (reference_times[i - 1][0] <= hypothesis_times[j - 1][1] + tolerance
                                         and hypothesis_times[j - 1][0] <= reference_times[i - 1][1] + tolerance))
            diagonal = previous[j - 1] + (ref != hyp) if compatible else math.inf
            delete, insert = previous[j] + 1, row[j - 1] + 1
            cost = min(diagonal, delete, insert)
            row[j] = cost
            trace[j] = (0 if ref == hyp else 1) if diagonal == cost else (2 if delete == cost else 3)
        back.append(trace)
        previous = row
    i, j, ops = len(reference), len(hypothesis), []
    counts = {"S": 0, "D": 0, "I": 0}
    while i or j:
        operation = back[i][j]
        if i and j and operation in (0, 1):
            ops.append({"op": "equal" if operation == 0 else "S", "ref_index": i - 1, "hyp_index": j - 1})
            counts["S"] += operation
            i, j = i - 1, j - 1
        elif i and (not j or operation == 2):
            ops.append({"op": "D", "ref_index": i - 1, "hyp_index": None})
            counts["D"] += 1
            i -= 1
        else:
            ops.append({"op": "I", "ref_index": None, "hyp_index": j - 1})
            counts["I"] += 1
            j -= 1
    ops.reverse()
    return {**counts, "ref_tokens": len(reference), "hyp_tokens": len(hypothesis),
            "rate": sum(counts.values()) / len(reference) if reference else None, "ops": ops}


def critical_counts(ops, reference_tokens, hypothesis_tokens):
    result = {"negation": 0, "number": 0, "code": 0}
    for operation in ops:
        if operation["op"] == "equal":
            continue
        words = []
        if operation["ref_index"] is not None:
            words.append(reference_tokens[operation["ref_index"]])
        if operation["hyp_index"] is not None:
            words.append(hypothesis_tokens[operation["hyp_index"]])
        result["negation"] += int(any(w in _NEGATION or w.endswith("n't") for w in words))
        result["number"] += int(any(w.isascii() and w.isdigit() for w in words))
        result["code"] += int(any(w in _CODE for w in words))
    return result


def score_asr(reference, segments, known_errors=()):
    """Time-constrained official-subtitle difference rate; no transcript output."""
    reference, segments = list(reference), list(segments)
    known = [item.get("cue_id") if isinstance(item, dict) else item for item in known_errors]
    result = {}
    for name, tokenizer in (("raw", tokens_raw), ("norm_v1", normalize_v1)):
        ref, ref_times, ref_owners = _timed_tokens(reference, tokenizer, True)
        hyp, hyp_times, unused = _timed_tokens(segments, tokenizer)
        aligned = align(ref, hyp, reference_times=ref_times, hypothesis_times=hyp_times)
        result[name] = {key: value for key, value in aligned.items() if key != "ops"}
        if name == "norm_v1":
            result["critical"] = critical_counts(aligned["ops"], ref, hyp)
            # Insertions have no reference word; attribute to the following cue,
            # or the previous cue at EOF, only when that cue overlaps in time.
            next_ref = [None] * len(aligned["ops"])
            following = None
            for index in range(len(aligned["ops"]) - 1, -1, -1):
                if aligned["ops"][index]["ref_index"] is not None:
                    following = aligned["ops"][index]["ref_index"]
                next_ref[index] = following
            edits, previous_ref = 0, None
            for index, operation in enumerate(aligned["ops"]):
                ref_index = operation["ref_index"]
                if ref_index is not None:
                    previous_ref = ref_index
                else:
                    ref_index = next_ref[index] if next_ref[index] is not None else previous_ref
                    if ref_index is not None:
                        hs, he = hyp_times[operation["hyp_index"]]
                        rs, re_ = ref_times[ref_index]
                        if hs > re_ + 3 or rs > he + 3:
                            ref_index = None
                if operation["op"] != "equal" and ref_index is not None:
                    edits += int(reference[ref_owners[ref_index]].get("cue_id") in known)
            result["ops_on_known_reference_errors"] = edits
    duration = max((_span(row, True)[1] for row in reference), default=0)
    captioned = sum(end - start for start, end in (_span(row) for row in segments))
    result.update({"captioned_fraction": captioned / duration if duration else None,
                   "captioned_seconds": captioned, "reference_audio_seconds": duration,
                   "matching_window_seconds": 3.0, "metric": "official_subtitle_difference_rate"})
    return result


def _envelope(row):
    if not isinstance(row, dict) or not isinstance(row.get("payload"), str) or not isinstance(row.get("sha256"), str):
        raise ValueError("Invalid durable envelope") from None
    try:
        payload = base64.b64decode(row["payload"], validate=True)
    except (ValueError, UnicodeError):
        raise ValueError("Invalid durable envelope") from None
    if hashlib.sha256(payload).hexdigest() != row["sha256"]:
        raise ValueError("Durable checksum mismatch") from None
    decoded = _json(payload)
    if not isinstance(decoded, dict) or decoded.get("version", 1) != 1:
        raise ValueError("Invalid durable schema") from None
    return decoded


def _read_regular(path):
    try:
        if path.is_symlink() or not path.is_file():
            raise ValueError("Durable input unavailable")
        return path.read_bytes()
    except OSError:
        raise ValueError("Durable input unavailable") from None


def durable_census(session_directory):
    """Read checksummed snapshot + disk-ordered work, never return text/IDs.

    No mutation or recovery of damaged/truncated files. All envelopes, even rows
    already covered by a snapshot, must verify. Invalid input raises ValueError.
    """
    directory = Path(session_directory) / "durable-transcription"
    snapshot_path, work_path = directory / "snapshot.json", directory / "work.jsonl"
    if not snapshot_path.exists() and not work_path.exists():
        raise ValueError("Durable transcription data unavailable") from None
    state = _envelope(_json(_read_regular(snapshot_path))) if snapshot_path.exists() else {"sequence": 0, "records": []}
    checkpoint = _integer(state.get("sequence", 0))
    records = state.get("records")
    if not isinstance(records, list):
        raise ValueError("Invalid durable records") from None
    session_id = state.get("sessionID")
    latest = {}

    def validate_record(record):
        if not isinstance(record, dict) or not isinstance(record.get("id"), str) or not record["id"]:
            raise ValueError("Invalid durable record") from None
        if session_id is not None and record.get("sessionID") != session_id:
            raise ValueError("Durable session mismatch") from None
        start, end = _number(record.get("start")), _number(record.get("end"))
        if start < 0 or end < start:
            raise ValueError("Invalid durable interval") from None
        if record.get("status") not in _STATUSES:
            raise ValueError("Invalid durable status") from None
        _integer(record.get("automaticRetryCount", 0))
        _integer(record.get("manualRetryCount", 0))

    for record in records:
        validate_record(record)
        if record["id"] in latest:
            raise ValueError("Duplicate durable record") from None
        latest[record["id"]] = record
    changes = [_envelope(row) for row in parse_ndjson(_read_regular(work_path))] if work_path.exists() else []
    for change in changes:
        _integer(change.get("sequence"))
    previous_sequence = 0
    for change in changes:
        if change["sequence"] != previous_sequence + 1:
            raise ValueError("Invalid durable sequence") from None
        previous_sequence = change["sequence"]
        if session_id is None:
            session_id = change.get("sessionID")
        if session_id is not None and change.get("sessionID") != session_id:
            raise ValueError("Durable session mismatch") from None
        record = change.get("record")
        if record is not None:
            validate_record(record)
            if change["sequence"] > checkpoint:
                latest[record["id"]] = record
    if previous_sequence < checkpoint:
        raise ValueError("Durable journal shorter than snapshot") from None
    result = {"available": True, "chunks": len(latest), "by_status": dict.fromkeys(_STATUSES, 0),
              "seconds_by_status": dict.fromkeys(_STATUSES, 0.0), "other_language": 0,
              "failed": 0, "unresolved": 0, "pending": 0, "completed_with_unresolved": 0,
              "failure_reasons": dict.fromkeys(_FAILURES + ("unknown",), 0),
              "automatic_retry_attempts": 0, "recovered_by_retry": 0,
              "issue_events": dict.fromkeys(_ISSUES + ("unknown",), 0),
              "apple_evidence": dict.fromkeys(("empty", "present", "unknown"), 0),
              "apple_evidence_present": 0, "apple_evidence_present_seconds": 0.0,
              "not_captioned_speech_seconds": 0.0, "snapshot_sequence": checkpoint,
              "journal_sequence": previous_sequence, "journal_mutations": len(changes)}
    for record in latest.values():
        extended = record.get("extendedStatus")
        status = extended if isinstance(extended, str) and extended in _STATUSES else record["status"]
        seconds = record["end"] - record["start"]
        candidate = record.get("candidateText") is not None
        retries = _integer(record.get("automaticRetryCount", 0))
        result["by_status"][status] += 1
        result["seconds_by_status"][status] += seconds
        result["other_language"] += int(status == "otherLanguage" and not candidate)
        result["failed"] += int(status == "failed")
        result["unresolved"] += int(status in ("failed", "retryWaiting") or candidate)
        result["pending"] += int(status in _PENDING)
        result["completed_with_unresolved"] += int(status == "completed" and candidate)
        result["automatic_retry_attempts"] += retries
        result["recovered_by_retry"] += int(status == "completed" and retries > 0)
        reason = record.get("failureReason")
        if reason is not None:
            reason = reason if isinstance(reason, str) and reason in _FAILURES else "unknown"
            result["failure_reasons"][reason] += 1
        evidence = record.get("appleEvidence")
        evidence_class = ("present" if evidence else "empty") if isinstance(evidence, str) else "unknown"
        result["apple_evidence"][evidence_class] += 1
        if evidence_class == "present":
            result["apple_evidence_present"] += 1
            result["apple_evidence_present_seconds"] += seconds
        if status in ("failed", "otherLanguage", "retryWaiting"):
            result["not_captioned_speech_seconds"] += seconds
    issues_path = Path(session_directory) / "transcription-issues.jsonl"
    if issues_path.exists():
        for issue in parse_ndjson(_read_regular(issues_path)):
            event = issue.get("event")
            event = event if isinstance(event, str) and event in _ISSUES else "unknown"
            result["issue_events"][event] += 1
    return result
