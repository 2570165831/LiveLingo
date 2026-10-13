#!/opt/homebrew/bin/python3.13
"""Local numeric-only diagnostics; never transcribes, uploads, edits, or deletes.

Usage: python3.13 -I nsfilter-private-stats.py COURSE [--tool VERIFIED_PROBE]
The probe reads whole audio files. Sentence scores use intersecting 1.5-second
windows, unlike the product's fresh SNAudioFileAnalyzer on each sealed chunk.
No-window, error, nonfinite, and <1.5-second spans conservatively pass.
Only Python stdlib is imported. Subprocess output and errors are captured.
"""
import base64
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import uuid

THRESHOLDS = (0.05, 0.1, 0.2, 0.3)
SCHEMA = "nsfilter-private-statistics-v1"


def numeric(x):
    if isinstance(x, bool) or not isinstance(x, (int, float)) or not math.isfinite(x):
        raise ValueError()
    return x


def safe_file(root, relative):
    p = Path(relative)
    if p.is_absolute() or not p.parts or any(v in ("..", ".") for v in p.parts):
        raise ValueError()
    candidate = root
    for part in p.parts:
        candidate = candidate / part
        if candidate.is_symlink():
            raise ValueError()
    if not stat.S_ISREG(candidate.stat().st_mode):
        raise ValueError()
    return candidate


def decoded_envelope(row, checksum_key):
    data = base64.b64decode(row["payload"], validate=True)
    if hashlib.sha256(data).hexdigest() != row[checksum_key]:
        raise ValueError()
    result = json.loads(data)
    if not isinstance(result, dict):
        raise ValueError()
    return result


def load_session(root, counters):
    snapshot_path = root / "session-snapshot.json"
    state = None
    if snapshot_path.is_file():
        envelope = json.loads(safe_file(root, "session-snapshot.json").read_bytes())
        state = decoded_envelope(envelope, "checksum")
        if state.get("schemaVersion") != 1:
            raise ValueError()
        counters["snapshot_sessions"] += 1
    journal = root / "session-journal.jsonl"
    if journal.is_file():
        if state is None:
            raise ValueError()
        raw = safe_file(root, "session-journal.jsonl").read_bytes()
        if raw and not raw.endswith(b"\n"):
            counters["incomplete_tails"] += 1
            raw = raw[:raw.rfind(b"\n") + 1]
        sequence = 0
        previous = "0" * 64
        segments = {s["id"]: s for s in state.get("segments", [])}
        checkpoint = state.get("lastJournalSequence", 0)
        checkpoint_digest = state.get("lastJournalDigest", "0" * 64)
        for line in raw.splitlines():
            row = json.loads(line)
            payload = base64.b64decode(row["payload"], validate=True)
            version = row["schemaVersion"]
            if version not in (1, 2, 3):
                raise ValueError()
            sequence += 1
            prefix = (f"LiveLingo-journal-{version}\n{sequence}\n{row['sessionID']}\n"
                      f"{row['baseStorageRevision']}\n{previous}\n").encode()
            digest = hashlib.sha256(prefix + payload).hexdigest()
            if (row["sequence"] != sequence or row["previousDigest"] != previous
                    or row["checksum"] != digest or row["sessionID"] != state["sessionID"]):
                raise ValueError()
            previous = digest
            if sequence == checkpoint and previous != checkpoint_digest:
                raise ValueError()
            if sequence <= checkpoint:
                continue
            if row["baseStorageRevision"] != state["storageRevision"]:
                raise ValueError()
            event = json.loads(payload)
            if "upsertSegment" in event:
                segment = event["upsertSegment"]["_0"]
                segments[segment["id"]] = segment
            if "inputRevision" in event:
                segment = event["inputRevision"]["_0"]["replacementSegment"]
                segments[segment["id"]] = segment
            state["storageRevision"] += 1
        if sequence < checkpoint:
            raise ValueError()
        state["segments"] = list(segments.values())
        counters["journal_sessions"] += 1
    if state is None:
        export_relative = "bilingual.jsonl"
        store = root / ".exports"
        if store.exists():
            if store.is_symlink() or not store.is_dir():
                raise ValueError()
            pointer = store / "current.json"
            if pointer.exists():
                index = json.loads(safe_file(root, ".exports/current.json").read_bytes())
                if index.get("version") != 1:
                    raise ValueError()
                generation = index["generation"]
                uuid.UUID(generation)
                if "/" in generation or "\\" in generation:
                    raise ValueError()
                export_relative = ".exports/versions/" + generation + "/bilingual.jsonl"
            elif (store / "current").is_symlink():
                # This one app-defined pointer may resolve only to versions/<UUID>.
                target = os.readlink(store / "current")
                parts = target.split("/")
                if len(parts) != 2 or parts[0] != "versions":
                    raise ValueError()
                uuid.UUID(parts[1])
                export_relative = ".exports/" + target + "/bilingual.jsonl"
            if export_relative != "bilingual.jsonl":
                generation_root = Path(export_relative).parent
                index = json.loads(safe_file(root, str(generation_root / "export-index.json")).read_bytes())
                if index.get("version") != 1:
                    raise ValueError()
                expected = index["members"]["bilingual.jsonl"]
                actual = hashlib.sha256(safe_file(root, export_relative).read_bytes()).hexdigest()
                if actual != expected:
                    raise ValueError()
        legacy = root / export_relative
        if legacy.is_file():
            raw = safe_file(root, export_relative).read_bytes()
            if raw and not raw.endswith(b"\n"):
                counters["incomplete_tails"] += 1
                raw = raw[:raw.rfind(b"\n") + 1]
            state = {"segments": [json.loads(v) for v in raw.splitlines()],
                     "audioFiles": [{"relativePath": "recording.wav"}]}
            counters["legacy_sessions"] += 1
    return state


def work_records(root, counters):
    folder = root / "durable-transcription"
    if folder.is_symlink():
        raise ValueError()
    records, sequence = {}, 0
    snapshot = folder / "snapshot.json"
    state = None
    if snapshot.is_file():
        state = decoded_envelope(json.loads(safe_file(root, "durable-transcription/snapshot.json").read_bytes()), "sha256")
        if state.get("version") != 1:
            raise ValueError()
        sequence = state["sequence"]
        records = {r["id"]: r for r in state["records"]}
    journal = folder / "work.jsonl"
    if journal.is_file():
        raw = safe_file(root, "durable-transcription/work.jsonl").read_bytes()
        if raw and not raw.endswith(b"\n"):
            counters["incomplete_tails"] += 1
            raw = raw[:raw.rfind(b"\n") + 1]
        seq = 0
        identity = state.get("sessionID") if state else None
        for line in raw.splitlines():
            row = decoded_envelope(json.loads(line), "sha256")
            seq += 1
            if row.get("version") != 1 or row["sequence"] != seq:
                raise ValueError()
            if identity is None:
                identity = row["sessionID"]
            if row["sessionID"] != identity:
                raise ValueError()
            if seq > sequence and row.get("record") is not None:
                record = row["record"]
                records[record["id"]] = record
        if seq < sequence:
            raise ValueError()
    elif sequence:
        raise ValueError()
    if records:
        counters["durable_sessions"] += 1
    return list(records.values())


def source_text(row):
    # Never use translated chinese, notes, prompts, failures or candidateText.
    text = row.get("english", row.get("text", ""))
    if not isinstance(text, str):
        raise ValueError()
    return text


def units(text):
    # Latin/digit words; each Han character counts as a unit (not linguistic words).
    return len(re.findall(r"[\w]+(?:['’][\w]+)*|[\u3400-\u9fff]", re.sub(r"([\u3400-\u9fff])", r" \1 ", text)))


def sentence_units(text):
    return len(sentence_word_counts(text))


def sentence_word_counts(text):
    # Sentence units inherit their enclosing span's gate result; no invented
    # word/sentence audio timestamps. Retain numeric counts, never the body.
    return [units(part) for part in re.split(r"[.!?。！？]+", text) if re.search(r"\w", part)]


def spans_for_session(root, counters):
    state = load_session(root, counters)
    records = work_records(root, counters)
    spans = []
    if state is not None and state.get("segments"):
        metadata = {a["relativePath"]: a for a in state.get("audioFiles", [])}
        ranges = {a["segmentID"]: a for a in state.get("audioRanges", [])}
        for s in state["segments"]:
            text = source_text(s)
            if not text.strip():
                counters["empty_text_spans"] += 1
                continue
            start, end = numeric(s["startTime"]), numeric(s["endTime"])
            a = ranges.get(s.get("id"))
            relative = "recording.wav"
            if a:
                relative = a["filePath"]
                rate = numeric(metadata.get(relative, {}).get("sampleRate"))
                if rate <= 0:
                    raise ValueError()
                start = numeric(a["startFrame"]) / rate
                end = start + numeric(a["frameCount"]) / rate
            sentence_words = sentence_word_counts(text)
            spans.append((safe_file(root, relative), start, end, units(text), len(sentence_words), sentence_words))
        return spans
    for record in records:
        text = source_text(record)
        if not text.strip():
            counters["empty_text_spans"] += 1
            continue
        rate = numeric(record["sampleRate"])
        if rate <= 0:
            raise ValueError()
        try:
            audio = safe_file(root, "durable-transcription/" + record["audioFile"])
            start = 0
            end = (numeric(record["endFrame"]) - numeric(record["startFrame"])) / rate
        except (OSError, ValueError):
            audio = safe_file(root, record.get("recordingFile") or "recording.wav")
            start = numeric(record["startFrame"]) / rate
            end = numeric(record["endFrame"]) / rate
        sentence_words = sentence_word_counts(text)
        spans.append((audio, start, end, units(text), len(sentence_words), sentence_words))
    return spans


def union_length(intervals):
    total, end = 0.0, -math.inf
    for left, right in sorted(intervals):
        total += max(0, right - max(left, end))
        end = max(end, right)
    return total


def score_span(result, start, end):
    start, end = numeric(start), numeric(end)
    if start < 0 or end <= start:
        raise ValueError()
    if end - start < 1.5:
        return None, 0.0, "short"
    if result.get("error") or result.get("nonfinite") or not result.get("completed"):
        return None, 0.0, "analysis_error"
    windows = result["windows"]
    relevant, ranges = [], []
    for w in windows:
        try:
            left = numeric(w["start"])
            right = left + numeric(w["duration"])
            confidence = numeric(w["speech"])
        except (ValueError, KeyError, TypeError):
            return None, 0.0, "analysis_error"
        if not 0 <= confidence <= 1 or right <= left:
            raise ValueError()
        if left < end and right > start:
            relevant.append(confidence)
            ranges.append((max(start, left), min(end, right)))
    covered = union_length(ranges)
    if not relevant:
        return None, covered, "no_windows"
    if covered < end - start - 1e-6:
        return None, covered, "insufficient_coverage"
    return max(relevant), covered, "scored"


def distribution(values):
    return {"zero": sum(v == 0 for v in values), "one": sum(v == 1 for v in values),
            "two_three": sum(2 <= v <= 3 for v in values), "four_ten": sum(4 <= v <= 10 for v in values),
            "eleven_thirty": sum(11 <= v <= 30 for v in values), "over_thirty": sum(v > 30 for v in values)}


def verified_probe(tool):
    tool = Path(tool).absolute()
    if tool.name != "nsfilter-probe":
        raise ValueError()
    resolved = tool.resolve(strict=True)
    parts = [p.lower() for p in (*tool.parts, *resolved.parts)]
    if tool.name != "nsfilter-probe" or tool.is_symlink() or any(
            p.endswith(".app") or p in ("languageruntime", "asrruntime")
            or "candidate" in p or p.startswith("python3") for p in parts):
        raise ValueError()
    # Reject symlinked ancestors as well; do not execute through a runtime alias.
    parent = tool.parent
    while parent != parent.parent:
        if parent.is_symlink():
            raise ValueError()
        parent = parent.parent
    if not stat.S_ISREG(tool.stat().st_mode):
        raise ValueError()
    p = subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(tool)],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    if p.returncode:
        raise ValueError()
    return tool


def analyze_files(tool, files):
    request = "".join(json.dumps({"path": str(p), "mode": "windows"}) + "\n" for p in files)
    p = subprocess.run([str(tool)], input=request, text=True, capture_output=True, timeout=3600)
    if p.returncode:
        raise ValueError()
    rows = [json.loads(v) for v in p.stdout.splitlines()]
    if len(rows) != len(files) or any(r.get("schema") != "nsfilter-probe-v1" for r in rows):
        raise ValueError()
    return dict(zip(files, rows))


def aggregate(spans, results, counters):
    scored, reason_counts = [], {k: 0 for k in ("short", "analysis_error", "no_windows", "insufficient_coverage", "scored")}
    covered_seconds = total_seconds = 0.0
    partial = 0
    for audio, start, end, words, sentences, sentence_words in spans:
        if sentences != len(sentence_words):
            raise ValueError()
        confidence, covered, reason = score_span(results[audio], start, end)
        reason_counts[reason] += 1
        total_seconds += end - start
        covered_seconds += covered
        partial += covered > 0 and covered < end - start - 1e-6
        scored.append((confidence, words, sentences, sentence_words))
    out = {"schema": SCHEMA, "method": "whole-file-intersecting-window-max-v1",
           "word_units": "latin-digit-tokens-han-characters-v1", "sentence_units": "punctuation-separated-source-v1",
           "status": "numeric-statistics-v1", "counters": counters, "spans": len(spans),
           "sentence_count": sum(s for _, _, s, _ in scored), "word_count": sum(w for _, w, _, _ in scored),
           "span_word_distribution": distribution([w for _, w, _, _ in scored]),
           "sentence_word_distribution": distribution([n for _, _, _, counts in scored for n in counts]),
           "distribution_granularity": "span-and-punctuation-sentence-v1",
           "window_reasons": reason_counts, "partial_window_coverage_spans": partial,
           "summed_span_seconds": total_seconds, "summed_covered_span_seconds": covered_seconds,
           "cpu_seconds_probe": sum(numeric(r.get("cpu_seconds", 0)) for r in results.values()),
           "thresholds": []}
    for threshold in THRESHOLDS:
        blocked = [(w, s, counts) for c, w, s, counts in scored if c is not None and c < threshold]
        out["thresholds"].append({"threshold": threshold, "blocked_spans": len(blocked),
            "blocked_sentence_count": sum(s for _, s, _ in blocked), "blocked_word_count": sum(w for w, _, _ in blocked),
            "blocked_span_word_distribution": distribution([w for w, _, _ in blocked]),
            "blocked_sentence_word_distribution": distribution([n for _, _, counts in blocked for n in counts])})
    return out


def run(root, tool):
    root = Path(root).absolute()
    if not root.is_dir() or root.is_symlink():
        raise ValueError()
    counters = {k: 0 for k in ("snapshot_sessions", "journal_sessions", "durable_sessions", "legacy_sessions",
                              "incomplete_tails", "empty_text_spans", "sessions_rejected", "sessions_found")}
    # Explicit folder or its immediate session children only; no unrelated recursion.
    candidates = [root] if any((root / n).exists() for n in
        ("session-snapshot.json", "session-journal.jsonl", "bilingual.jsonl", "durable-transcription", ".exports")) else [
            p for p in root.iterdir() if p.is_dir() and not p.is_symlink()]
    spans = []
    for folder in candidates:
        counters["sessions_found"] += 1
        try:
            spans.extend(spans_for_session(folder, counters))
        except (OSError, ValueError, KeyError, TypeError):
            counters["sessions_rejected"] += 1
    tool = verified_probe(tool)
    files = list(dict.fromkeys(v[0] for v in spans))
    results = analyze_files(tool, files) if files else {}
    return aggregate(spans, results, counters)


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    try:
        if len(argv) == 1:
            argv.extend(["--tool", str(Path(__file__).with_name("nsfilter-probe"))])
        if len(argv) != 3 or argv[1] != "--tool":
            raise ValueError()
        result = run(argv[0], argv[2])
        code = 0
    except BaseException:
        result = {"schema": SCHEMA, "status": "numeric-error-v1", "errors": 1}
        code = 1
    print(json.dumps(result, ensure_ascii=True, sort_keys=True, allow_nan=False))
    return code


if __name__ == "__main__":
    sys.exit(main())
