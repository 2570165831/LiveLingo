"""Guarded, resumable local ASR feature collection with no transcript output.

Only public UN interpretation word timestamps are saved for independent
reference alignment. Classroom text is handled exclusively in memory and in a
private stdin/stdout pipe to text_stats; only numeric aggregates are persisted.
No installed service is started, called, changed, or stopped.
"""
from __future__ import annotations

import argparse
import contextlib
import csv
import datetime as dt
import hashlib
import importlib.metadata
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
from zoneinfo import ZoneInfo

if __package__:
    from . import align
    from .prepare import sha256, save_new
else:
    import align
    from prepare import sha256, save_new


def event(**fields):
    print(json.dumps({"utc": dt.datetime.now(dt.timezone.utc).isoformat(), **fields},
                     ensure_ascii=True, allow_nan=False), flush=True)


def load_script(path, name):
    path = Path(path).resolve(strict=True)
    sys.path.insert(0, str(path.parent))
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def route_finished(directory):
    """Wait for the declared earlier job, including its scheduled second model."""
    if directory is None:
        return True
    first, decision = directory / "execution-result.json", directory / "optional-4b-decision.json"
    if not first.is_file() or not decision.is_file():
        return False
    value = json.loads(decision.read_bytes())
    if value.get("started") and not (directory / "4b-execution-result.json").is_file():
        return False
    # Its CPU report phase does not use the GPU. The guard still checks workers.
    return True


@contextlib.contextmanager
def acquire_gpu(guard, args):
    wait_started = time.monotonic()
    while not route_finished(args.wait_for_route_directory):
        event(event="waiting_for_declared_route_job", gpu_models_loaded=False,
              elapsed_wait_s=time.monotonic() - wait_started)
        time.sleep(30)
    while True:
        yielded = False
        try:
            if args.allow_idle_installed_asr_service and dt.datetime.now(ZoneInfo("Asia/Shanghai")).date() >= dt.date(2026, 10, 12):
                raise ValueError("idle_allowance_authorization_expired")
            with guard.session_lock():
                allowed = guard.preflight_processes(owned_pids=(os.getpid(),),
                            allow_idle_installed_asr_service=args.allow_idle_installed_asr_service)
                event(event="gpu_lock_acquired", guard_wait_s=time.monotonic() - wait_started,
                      allow_idle_installed_asr_service=args.allow_idle_installed_asr_service,
                      allowed_processes=allowed)
                yielded = True
                yield allowed
                return
        except guard.Rejected as error:
            if yielded:
                raise
            if error.reason not in ("scoreboard_busy", "another_livelingo_run_active"):
                raise
            event(event="gpu_guard_rejected", reason=error.reason, retry_after_s=120)
            deadline = time.monotonic() + 120
            while time.monotonic() < deadline:
                time.sleep(min(30, max(0, deadline - time.monotonic())))
                event(event="gpu_guard_wait_heartbeat", retry_remaining_s=max(0, deadline - time.monotonic()))


class TextStats:
    def __init__(self, binary):
        self.process = subprocess.Popen([str(binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, text=True, bufsize=1)

    def evaluate(self, text, duration):
        self.process.stdin.write(json.dumps({"text": text, "duration": duration}) + "\n")
        self.process.stdin.flush()
        row = json.loads(self.process.stdout.readline())
        allowed = {"pk_word_count", "pk_char_count", "english_gate_accepted", "quality_reason",
                   "parakeet_accepted", "nl_language", "nl_probability", "nl_english_probability"}
        if not isinstance(row, dict) or set(row) != allowed:
            raise ValueError("invalid_text_stats_response")
        for key in ("pk_word_count", "pk_char_count"):
            if type(row[key]) is not int or row[key] < 0:
                raise ValueError("invalid_text_stats_count")
        for key in ("english_gate_accepted", "parakeet_accepted"):
            if type(row[key]) is not bool:
                raise ValueError("invalid_text_stats_boolean")
        if row["quality_reason"] not in (None, "emptyTranscript", "invalidText", "implausiblyShort", "repeatedLoop", "runawayText"):
            raise ValueError("invalid_text_stats_reason")
        language = row["nl_language"]
        if language is not None and (not isinstance(language, str) or not re.fullmatch(r"[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*", language)):
            raise ValueError("invalid_text_stats_language")
        for key in ("nl_probability", "nl_english_probability"):
            value = row[key]
            if value is not None and (type(value) not in (int, float) or not math.isfinite(value) or not 0 <= value <= 1):
                raise ValueError("invalid_text_stats_probability")
        return row

    def close(self):
        # EOF closes only this explicitly owned CPU helper; no signal is sent.
        self.process.stdin.close()
        self.process.stdout.close()
        self.process.wait(timeout=10)


class JointRecorder:
    """Observe the existing TDT joint call without changing greedy decisions."""
    def __init__(self, original, vocabulary_size, mx):
        self.original, self.vocabulary_size, self.mx = original, vocabulary_size, mx
        self.log_probabilities = []

    def __call__(self, *args, **kwargs):
        logits = self.original(*args, **kwargs)
        token_logits = logits[0, 0, :, :self.vocabulary_size + 1].reshape(-1).astype(self.mx.float32)
        selected = int(self.mx.argmax(token_logits).item())
        if selected != self.vocabulary_size:
            log_p = float((token_logits[selected] - self.mx.logsumexp(token_logits)).item())
            if not math.isfinite(log_p):
                raise ValueError("nonfinite_token_posterior")
            self.log_probabilities.append(min(0., log_p))
        return logits

    def statistics(self, expected_count):
        values = self.log_probabilities
        if len(values) != expected_count:
            raise ValueError("token_confidence_count_mismatch")
        probabilities = [math.exp(p) for p in values]
        return {"pk_emitted_tokens": len(values),
                "pk_mean_probability": sum(probabilities) / len(values) if values else None,
                "pk_min_probability": min(probabilities) if values else None,
                "pk_mean_log_probability": sum(values) / len(values) if values else None,
                "pk_min_log_probability": min(values) if values else None}


def write_rows_atomic(path, rows, suffix=".rewriting"):
    temporary = path.with_name(path.name + suffix)
    with temporary.open("x", encoding="utf-8") as output:
        for row in rows:
            output.write(json.dumps(row, ensure_ascii=True, allow_nan=False) + "\n")
    os.replace(temporary, path)


def read_rows(path, *, recover_tail=False):
    if not path.is_file():
        return []
    raw = path.read_bytes()
    lines = raw.splitlines(keepends=True)
    rows, recovered = [], False
    for index, line in enumerate(lines):
        if not line.strip():
            continue
        try:
            rows.append(json.loads(line))
        except (ValueError, UnicodeDecodeError):
            if not recover_tail or index != len(lines) - 1 or line.endswith(b"\n"):
                raise ValueError("invalid_complete_jsonl_record") from None
            # This task's incomplete tail was never a completed measurement.
            # Preserve its byte count/hash, never echo or log fragment content.
            event(event="incomplete_jsonl_tail_recovered", bytes=len(line),
                  fragment_sha256=hashlib.sha256(line).hexdigest(), completed_rows=len(rows))
            recovered = True
    if recover_tail and (recovered or (raw and not raw.endswith(b"\n"))):
        write_rows_atomic(path, rows, ".recovering")
    return rows


def verify_prefix(rows, track):
    if len(rows) > len(track["windows"]):
        raise ValueError("resume_prefix_too_long")
    for row, window in zip(rows, track["windows"]):
        if any(row.get(key) != track.get(key) for key in ("dataset", "track", "split")):
            raise ValueError("resume_stream_identity_changed")
        if (row["index"], row["start_s"], row["end_s"]) != (window["index"], window["start_s"], window["end_s"]):
            raise ValueError("resume_prefix_changed")


def model_metadata(directory):
    return [{"name": p.name, "bytes": p.stat().st_size,
             "sha256": sha256(p) if p.suffix != ".safetensors" else None,
             "mtime_ns": p.stat().st_mtime_ns}
            for p in sorted(directory.iterdir()) if p.is_file()]


def export_csv(path, rows):
    if not rows:
        return
    fields = sorted(set().union(*(row.keys() for row in rows)))
    temporary = path.with_name(path.name + ".writing")
    with temporary.open("x", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)
    os.replace(temporary, path)


def correlate_tracks(track, rows, floor_track, anchors, sf, np):
    """Correct interpretation pass-through only with waveform + official proof."""
    with sf.SoundFile(track["audio"]) as interpretation, sf.SoundFile(floor_track["audio"]) as floor:
        rate = interpretation.samplerate
        if (rate, interpretation.channels) != (floor.samplerate, floor.channels):
            return
        for row in rows:
            language, trusted, _ = align.label_window(row["start_s"], row["end_s"], anchors)
            interpretation.seek(round(row["start_s"] * rate))
            floor.seek(round(row["start_s"] * rate))
            count = round((row["end_s"] - row["start_s"]) * rate)
            a, b = interpretation.read(count, dtype="float64"), floor.read(count, dtype="float64")
            if len(a) != len(b) or not len(a):
                continue
            denominator = float(np.linalg.norm(a) * np.linalg.norm(b))
            correlation = float(np.dot(a, b) / denominator) if denominator > 0 else 0.
            row["floor_interp_waveform_cosine"] = max(-1., min(1., correlation))
            if correlation >= .999:
                if trusted:
                    row.update(reference_language=language, reference_trusted=True,
                               reference_kind="official_waveform_passthrough")
                else:
                    row.update(reference_language=None, reference_trusted=False,
                               reference_kind="unresolved_waveform_passthrough")


def run(args, guard):
    import numpy as np
    import soundfile as sf
    import mlx.core as mx
    from scipy.signal import resample_poly
    from mlx_audio.stt.utils import load_model

    manifest = json.loads(args.manifest.read_bytes())
    tracks = [t for t in manifest["tracks"] if t["split"] == args.split]
    # Interpretation first so the same pass supplies the public alignment anchors.
    tracks.sort(key=lambda t: (t["dataset"], t["track"] != "interp-en", t["track"]))
    args.output_root.mkdir(parents=True, exist_ok=True)
    features = args.output_root / "features"
    features.mkdir(exist_ok=True)
    alignment_dir = args.output_root / "alignment"
    alignment_dir.mkdir(exist_ok=True)
    source_identity = {"schema": 1, "collector_sha256": sha256(Path(__file__)),
            "aligner_sha256": sha256(Path(align.__file__)), "manifest_sha256": sha256(args.manifest),
            "guard_sha256": sha256(args.guard_script), "service_sha256": sha256(args.service_script),
            "text_stats_sha256": sha256(args.text_stats), "split": args.split,
            "models": {"parakeet": model_metadata(args.parakeet_model),
                       "qwen": model_metadata(args.qwen_model)},
            "versions": {name: importlib.metadata.version(name)
                         for name in ("mlx", "mlx-audio", "mlx-lm", "numpy", "soundfile")},
            "privacy": "All feature files contain aggregate statistics only; classroom transcript content is never persisted.",
            "timing": "Metal-synchronized wall clock, not GPU hardware busy time or energy.",
            "confidence": "Mean/min nonblank emitted TDT conditional token posterior; not calibrated transcript correctness."}
    identity_path = args.output_root / f"collection-{args.split}-identity.json"
    if identity_path.exists():
        if json.loads(identity_path.read_bytes()) != source_identity:
            raise ValueError("resume_identity_changed")
    else:
        save_new(identity_path, source_identity)
    service = load_script(args.service_script, "trigger_probe_service")
    loaded = time.monotonic()
    parakeet = load_model(str(args.parakeet_model))
    if type(parakeet).__name__ != "ParakeetTDT":
        raise ValueError("expected_parakeet_tdt")
    joint = JointRecorder(parakeet.joint, len(parakeet.vocabulary), mx)
    parakeet.joint = joint
    qwen = load_model(str(args.qwen_model))
    check = service.auto_self_check(qwen, "trigger-eval")
    if check is None:
        raise ValueError("qwen_prefill_self_check_failed")
    mx.synchronize()
    event(event="models_loaded", seconds=time.monotonic() - loaded)
    stats = TextStats(args.text_stats)
    public_anchors = {}
    completed = []
    try:
        for track in tracks:
            guard.preflight_processes(owned_pids=(os.getpid(),),
                allow_idle_installed_asr_service=args.allow_idle_installed_asr_service)
            source = Path(track["audio"]).resolve(strict=True)
            expected_sha = track.get("audio_sha256", track["source_sha256"])
            if sha256(source) != expected_sha:
                raise ValueError("input_audio_hash_changed")
            basename = track["dataset"] + "." + track["track"]
            if not all(c.isalnum() or c in ".-_" for c in basename):
                raise ValueError("invalid_dataset_identifier")
            path = features / f"{basename}.jsonl"
            rows = read_rows(path, recover_tail=True)
            verify_prefix(rows, track)
            public_path = alignment_dir / f"{basename}.public-words.jsonl"
            is_public_interp = "official_turns" in track and track["track"] == "interp-en" and not track["private_classroom"]
            public_rows = read_rows(public_path, recover_tail=True) if is_public_interp else []
            if is_public_interp and len(public_rows) == len(rows) + 1:
                if public_rows[-1]["index"] != track["windows"][len(rows)]["index"]:
                    raise ValueError("orphan_public_word_index_changed")
                orphan = public_path.with_name(public_path.name + f".orphan-{time.time_ns()}")
                save_new(orphan, public_rows[-1])
                public_rows = public_rows[:-1]
                write_rows_atomic(public_path, public_rows, ".reconciled")
                event(event="orphan_public_alignment_row_preserved", rows=1)
            if is_public_interp and len(public_rows) != len(rows):
                raise ValueError("public_word_resume_prefix_mismatch")
            with sf.SoundFile(str(source)) as audio, path.open("a", encoding="utf-8") as output, \
                    contextlib.ExitStack() as stack:
                public_output = stack.enter_context(public_path.open("a", encoding="utf-8")) if is_public_interp else None
                for window in track["windows"][len(rows):]:
                    duration = window["end_s"] - window["start_s"]
                    audio.seek(round(window["start_s"] * audio.samplerate))
                    samples = audio.read(round(duration * audio.samplerate), dtype="float32", always_2d=True).mean(axis=1)
                    if audio.samplerate != 16000:
                        gcd = math.gcd(audio.samplerate, 16000)
                        samples = resample_poly(samples, 16000 // gcd, audio.samplerate // gcd).astype(np.float32)
                    row = {"schema": 1, "dataset": track["dataset"], "split": track["split"],
                           "track": track["track"], "index": window["index"],
                           "start_s": window["start_s"], "end_s": window["end_s"],
                           "private_classroom": track["private_classroom"],
                           "reference_language": window.get("reference_language", track.get("reference_language")),
                           "reference_kind": window.get("reference_kind", track.get("reference_kind", "pending_official_alignment")),
                           "reference_trusted": window.get("reference_trusted", bool(track.get("reference_language"))),
                           "boundary_reason": window["boundary_reason"]}
                    joint.log_probabilities.clear()
                    mx.synchronize()
                    start = time.monotonic()
                    try:
                        result = parakeet.generate(mx.array(samples), verbose=False)
                        mx.synchronize()
                        row["parakeet_seconds"] = time.monotonic() - start
                        tokens = [token for sentence in result.sentences for token in sentence.tokens]
                        row.update(joint.statistics(len(tokens)))
                        row.update(stats.evaluate(result.text.strip(), duration))
                        row["pk_words_per_second"] = row["pk_word_count"] / duration
                        if is_public_interp:
                            word_row = {"index": window["index"], "words": align.timed_words(tokens, window["start_s"])}
                            public_output.write(json.dumps(word_row, ensure_ascii=True) + "\n")
                            public_output.flush()
                            public_rows.append(word_row)
                        del result, tokens
                        row["parakeet_error"] = False
                    except Exception:
                        row.update(parakeet_error=True, parakeet_accepted=False,
                                   pk_word_count=0, pk_words_per_second=0.,
                                   pk_mean_probability=None, pk_min_probability=None,
                                   nl_language=None, nl_probability=None,
                                   parakeet_seconds=time.monotonic() - start)
                        if is_public_interp:
                            word_row = {"index": window["index"], "words": []}
                            public_output.write(json.dumps(word_row) + "\n")
                            public_output.flush()
                            public_rows.append(word_row)
                    # A single task-owned slice, immediately removed after prefill.
                    # No transcript is ever placed in this temporary audio file.
                    with tempfile.NamedTemporaryFile(suffix=".wav", dir=args.tmp, delete=True) as sliced:
                        sf.write(sliced.name, samples, 16000, subtype="PCM_16")
                        row["slice_audio_sha256"] = sha256(sliced.name)
                        mx.synchronize()
                        start = time.monotonic()
                        try:
                            probe = service.probe_language(qwen, sliced.name, check)
                            mx.synchronize()
                            label = probe["detected_label"]
                            row.update(probe_language=service.LANGUAGE_CODES.get(label),
                                probe_label_probability=probe["language_probability"],
                                probe_english_probability=probe["english_probability"], probe_error=False)
                            del probe
                        except Exception:
                            row.update(probe_language=None, probe_label_probability=None,
                                       probe_english_probability=None, probe_error=True)
                        row["probe_seconds"] = time.monotonic() - start
                    output.write(json.dumps(row, ensure_ascii=True, allow_nan=False) + "\n")
                    output.flush()
                    rows.append(row)
                    if len(rows) % 25 == 0 or len(rows) == len(track["windows"]):
                        event(event="features_progress", dataset=track["dataset"], track=track["track"],
                              completed=len(rows), planned=len(track["windows"]),
                              probe_failures=sum(r["probe_error"] for r in rows),
                              parakeet_failures=sum(r["parakeet_error"] for r in rows))
                    if len(rows) % 100 == 0:
                        guard.preflight_processes(owned_pids=(os.getpid(),),
                            allow_idle_installed_asr_service=args.allow_idle_installed_asr_service)
                        mx.clear_cache()
            if is_public_interp:
                doc = json.loads(Path(track["official_turns"]).read_bytes())
                observed = [word for r in public_rows for word in r["words"]]
                anchors, summary = align.make_anchors(doc, observed)
                public_anchors[track["dataset"]] = anchors
                anchor_path = alignment_dir / f"{track['dataset']}.anchors.json"
                if not anchor_path.exists():
                    save_new(anchor_path, {"anchors": anchors, "summary": summary})
                floor_track = next(t for t in tracks if t["dataset"] == track["dataset"] and t["track"] == "floor")
                for row in rows:
                    row.update(reference_language="en", reference_trusted=True,
                               reference_kind="english_interpretation_track_assumption")
                correlate_tracks(track, rows, floor_track, anchors, sf, np)
            elif "official_turns" in track:
                anchors = public_anchors[track["dataset"]]
                for row in rows:
                    language, trusted, reason = align.label_window(row["start_s"], row["end_s"], anchors)
                    row.update(reference_language=language, reference_trusted=trusted,
                               reference_kind=reason)
            # Replace only this task's own intermediate labels, preserving all
            # measured per-segment fields. No input/source file is modified.
            write_rows_atomic(path, rows, ".relabeling")
            export_csv(path.with_suffix(".csv"), rows)
            completed.append({"dataset": track["dataset"], "track": track["track"],
                "jsonl": str(path), "csv": str(path.with_suffix(".csv")), "sha256": sha256(path),
                "segments": len(rows), "audio_seconds": sum(r["end_s"] - r["start_s"] for r in rows),
                "trusted_segments": sum(r["reference_trusted"] for r in rows),
                "probe_failures": sum(r["probe_error"] for r in rows),
                "parakeet_failures": sum(r["parakeet_error"] for r in rows)})
            index_path = args.output_root / f"collection-{args.split}-index.json"
            index_path.write_text(json.dumps({"status": "running", "files": completed}, indent=2) + "\n")
        index_path.write_text(json.dumps({"status": "completed", "files": completed}, indent=2) + "\n")
        event(event="collection_completed", split=args.split, segments=sum(r["segments"] for r in completed))
    finally:
        try:
            stats.close()
        finally:
            parakeet.joint = joint.original
            mx.synchronize()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("manifest", "output-root", "tmp", "site-packages", "parakeet-model", "qwen-model",
                 "guard-script", "service-directory", "text-stats"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--split", choices=("dev", "original", "new"), required=True)
    parser.add_argument("--wait-for-route-directory", type=Path)
    parser.add_argument("--allow-idle-installed-asr-service", action="store_true")
    args = parser.parse_args()
    # A filename argument naming the ASR service is falsely recognized as an
    # active service by older process guards, even when this process only waits.
    # Supply its source directory instead. Actual model use still holds the
    # unmodified shared lock and explicit installed-idle guard allowance.
    args.service_script = args.service_directory.resolve(strict=True) / "qwen_asr_service.py"
    args.tmp.mkdir(parents=True, exist_ok=True)
    sys.path.insert(0, str(args.site_packages.resolve(strict=True)))
    sys.dont_write_bytecode = True
    # Fixed task-owned locations; process environments are never inspected or logged.
    os.environ.update(TMPDIR=str(args.tmp.resolve()), HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1",
        TOKENIZERS_PARALLELISM="false", HF_HOME=str(args.tmp / "hf"),
        XDG_CACHE_HOME=str(args.tmp / "cache"), MPLCONFIGDIR=str(args.tmp / "matplotlib"))
    tempfile.tempdir = str(args.tmp.resolve())
    try:
        guard = load_script(args.guard_script, "trigger_machine_guard")
        with acquire_gpu(guard, args):
            run(args, guard)
        return 0
    except Exception as error:
        event(event="collection_failed", error_type=type(error).__name__, raw_diagnostics_omitted=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
