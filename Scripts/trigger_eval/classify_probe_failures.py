"""Classify collected Qwen language-probe failures without persisting any text.

For each feature row recorded with probe_error, rebuild the identical 16 kHz
slice (its SHA-256 must equal the collected slice_audio_sha256), re-run the
unchanged service probe_language several times and record only the fixed error
class. A failure is accepted downstream only when every re-run fails with the
same known class. The language head is described by shape alone (token counts,
termination, booleans, character length); a label is named only when it is an
exact entry of a fixed list of language names. No ASR transcript, decoded head
text or token id is written or logged.

Uses the shared whole-machine GPU session lock and guard through collect.py.
A split without failures writes its (empty) result without loading any model.
"""
from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import importlib.metadata
import json
import math
import os
from pathlib import Path
import sys
import tempfile
import time

if __package__:
    from . import collect
    from .prepare import sha256
    from .simulate import PROBE_ERROR_CLASSES, check_probe_failure_classification, read_jsonl
else:
    import collect
    from prepare import sha256
    from simulate import PROBE_ERROR_CLASSES, check_probe_failure_classification, read_jsonl

# Exact names only; anything else is described by shape alone.
KNOWN_LANGUAGE_NAMES = frozenset({
    "Arabic", "Bengali", "Burmese", "Cantonese", "Catalan", "Chinese", "Czech", "Danish", "Dutch",
    "English", "Filipino", "Finnish", "French", "German", "Greek", "Hakka", "Hebrew", "Hindi",
    "Hokkien", "Hungarian", "Indonesian", "Italian", "Japanese", "Kazakh", "Khmer", "Korean", "Lao",
    "Macedonian", "Malay", "Mandarin", "Minnan", "Persian", "Polish", "Portuguese", "Romanian",
    "Russian", "Shanghainese", "Sichuanese", "Spanish", "Swahili", "Swedish", "Tagalog", "Tamil",
    "Thai", "Turkish", "Ukrainian", "Urdu", "Vietnamese", "Wu", "Yue",
    # Native-script names (language names only, never transcript content).
    "中文", "汉语", "漢語", "华语", "華語", "国语", "國語", "普通话", "普通話", "粤语", "粵語", "广东话",
    "廣東話", "闽南语", "吴语", "英语", "英文", "法语", "法文", "西班牙语", "俄语", "阿拉伯语",
    "日语", "日文", "韩语", "日本語", "한국어", "Русский", "العربية", "Français", "Español",
})


def _cjk(character: str) -> bool:
    return 0x3400 <= ord(character) <= 0x9FFF or 0xF900 <= ord(character) <= 0xFAFF


def event(**fields):
    print(json.dumps({"utc": dt.datetime.now(dt.timezone.utc).isoformat(), **fields},
                     ensure_ascii=True, allow_nan=False), flush=True)


def error_class(error: BaseException) -> str:
    """Return a fixed class string; unknown exceptions never echo their message."""
    message = str(error) if isinstance(error, ValueError) else None
    return message if message in PROBE_ERROR_CLASSES else f"{type(error).__name__}:message_omitted"


def describe_head(head_tokens: list[int], terminated: bool, decode, check) -> dict:
    """Shape of the generated language head; decoded text is discarded."""
    text = decode(head_tokens) if head_tokens else ""
    label = text[1:] if text.startswith(" ") else text
    supported = check["labels"]
    shape = {
        "head_token_count": len(head_tokens),
        "terminated_by_asr_text_token": bool(terminated),
        "leading_space": text.startswith(" "),
        "label_char_count": len(label),
        "label_ascii_letters_only": bool(label) and label.isascii() and label.isalpha(),
        "label_has_internal_whitespace": any(c.isspace() for c in label.strip()),
        "label_cjk_ideographs_only": bool(label) and all(_cjk(c) for c in label),
        "label_in_supported_set": label in supported,
        "label_casefold_in_supported_set": label.casefold() in {item.casefold() for item in supported},
        "label_stripped_in_supported_set": label.strip() in supported,
        "first_token_supported_label_count": len(check["heads"].get(head_tokens[0], [])) if head_tokens else 0,
        "known_language_name": label if label in KNOWN_LANGUAGE_NAMES else None,
    }
    del text, label
    return shape


def head_shape(service, model, path, check, max_tokens=4):
    """Replicate probe_language's greedy head loop, returning shape only."""
    import mlx.core as mx
    from mlx_audio.stt.utils import load_audio

    inner = model._model
    audio = load_audio(path, sr=16000)
    features, mask, count = inner._preprocess_audio(audio)
    ids = inner._build_prompt(count, "English")
    audio_features = inner.get_audio_features(features, mask)
    embeddings = inner._build_inputs_embeds(ids, audio_features)
    cache = inner.make_cache()
    logits = inner(ids[:, :-2], input_embeddings=embeddings[:, :-2], cache=cache)[0, -1]
    head, terminated = [], False
    for _ in range(max_tokens):
        token = int(mx.argmax(logits).item())
        if token == service.ASR_TEXT_TOKEN:
            terminated = True
            break
        head.append(token)
        logits = inner(mx.array([[token]]), cache=cache)[0, -1]
    mx.synchronize()
    return describe_head(head, terminated, inner._tokenizer.decode, check)


def failed_rows(args):
    receipt = json.loads((args.output_root / f"collection-{args.split}-index.json").read_bytes())
    if receipt.get("status") != "completed":
        raise ValueError("collection_not_completed")
    paths = []
    for item in receipt["files"]:
        path = Path(item["jsonl"])
        if path.parent != args.output_root / "features" or sha256(path) != item["sha256"]:
            raise ValueError("feature_location_or_hash_changed")
        paths.append(path)
    rows, _ = read_jsonl(paths, allowed_splits={args.split})
    return rows, [row for row in rows if row["probe_error"]]


def run(args, guard, failures):
    import numpy as np
    import soundfile as sf
    import mlx.core as mx
    from scipy.signal import resample_poly
    from mlx_audio.stt.utils import load_model

    manifest = json.loads(args.manifest.read_bytes())
    tracks = {(t["dataset"], t["track"]): t for t in manifest["tracks"] if t["split"] == args.split}
    service = collect.load_script(args.service_script, "trigger_probe_service")
    qwen = load_model(str(args.qwen_model))
    check = service.auto_self_check(qwen, "trigger-eval")
    if check is None:
        raise ValueError("qwen_prefill_self_check_failed")
    mx.synchronize()
    event(event="model_loaded")
    entries, verified = [], set()
    for row in failures:
        key = (row["dataset"], row["track"])
        track = tracks[key]
        source = Path(track["audio"]).resolve(strict=True)
        if key not in verified:
            guard.preflight_processes(owned_pids=(os.getpid(),),
                                      allow_idle_installed_asr_service=args.allow_idle_installed_asr_service)
            if sha256(source) != track.get("audio_sha256", track["source_sha256"]):
                raise ValueError("input_audio_hash_changed")
            verified.add(key)
        window = next(w for w in track["windows"] if w["index"] == row["index"])
        if (window["start_s"], window["end_s"]) != (row["start_s"], row["end_s"]):
            raise ValueError("window_changed")
        duration = row["end_s"] - row["start_s"]
        with sf.SoundFile(str(source)) as audio:
            audio.seek(round(row["start_s"] * audio.samplerate))
            samples = audio.read(round(duration * audio.samplerate), dtype="float32", always_2d=True).mean(axis=1)
            if audio.samplerate != 16000:
                gcd = math.gcd(audio.samplerate, 16000)
                samples = resample_poly(samples, 16000 // gcd, audio.samplerate // gcd).astype(np.float32)
        with tempfile.NamedTemporaryFile(suffix=".wav", dir=args.tmp, delete=True) as sliced:
            sf.write(sliced.name, samples, 16000, subtype="PCM_16")
            digest = sha256(sliced.name)
            attempts = []
            for _ in range(args.attempts):
                try:
                    probe = service.probe_language(qwen, sliced.name, check)
                    mx.synchronize()
                    attempts.append("succeeded")
                    del probe
                except Exception as error:
                    attempts.append(error_class(error))
            shape = head_shape(service, qwen, sliced.name, check)
        entries.append({"dataset": row["dataset"], "track": row["track"], "index": row["index"],
                        "start_s": row["start_s"], "end_s": row["end_s"],
                        "private_classroom": row.get("private_classroom", False),
                        "reference_language": row["reference_language"],
                        "reference_trusted": row["reference_trusted"],
                        "slice_audio_sha256": digest,
                        "same_slice_as_collection": digest == row.get("slice_audio_sha256"),
                        "attempts": attempts, "error_class": attempts[0],
                        "deterministic": len(set(attempts)) == 1 and attempts[0] != "succeeded",
                        "head_shape": shape})
        event(event="classified", completed=len(entries), planned=len(failures))
    return entries, check


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("manifest", "output-root", "tmp", "site-packages", "qwen-model", "guard-script",
                 "service-directory"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--split", choices=("dev", "original", "new"), required=True)
    parser.add_argument("--attempts", type=int, default=2)
    parser.add_argument("--allow-idle-installed-asr-service", action="store_true")
    args = parser.parse_args()
    if args.attempts < 2:
        parser.error("--attempts must be at least 2")
    args.service_script = args.service_directory.resolve(strict=True) / "qwen_asr_service.py"
    args.wait_for_route_directory = None
    args.tmp.mkdir(parents=True, exist_ok=True)
    sys.path.insert(0, str(args.site_packages.resolve(strict=True)))
    sys.dont_write_bytecode = True
    os.environ.update(TMPDIR=str(args.tmp.resolve()), HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1",
                      TOKENIZERS_PARALLELISM="false", HF_HOME=str(args.tmp / "hf"),
                      XDG_CACHE_HOME=str(args.tmp / "cache"))
    tempfile.tempdir = str(args.tmp.resolve())
    output = args.output_root / f"probe-failures-{args.split}.json"
    try:
        if output.exists():
            raise ValueError("classification_output_exists")
        rows, failures = failed_rows(args)
        identity = {"classifier_sha256": sha256(Path(__file__)), "service_sha256": sha256(args.service_script),
                    "guard_sha256": sha256(args.guard_script), "manifest_sha256": sha256(args.manifest),
                    "qwen_model": collect.model_metadata(args.qwen_model)}
        value = {"schema": 1, "split": args.split, "attempts_per_failure": args.attempts,
                 "segments": len(rows), "probe_failures": len(failures), "identity": identity,
                 "privacy": "Fixed error classes and head shape only; no transcript, decoded head text or token ids.",
                 "gpu_used": bool(failures), "failures": []}
        if failures:
            guard = collect.load_script(args.guard_script, "trigger_machine_guard")
            value["identity"]["versions"] = {name: importlib.metadata.version(name)
                                             for name in ("mlx", "mlx-audio", "mlx-lm", "numpy", "soundfile")}
            started = time.monotonic()
            with collect.acquire_gpu(guard, args) as allowed:
                value["allowed_processes"] = allowed
                value["failures"], _ = run(args, guard, failures)
            value["seconds_including_guard_wait"] = time.monotonic() - started
        value["created_at_utc"] = dt.datetime.now(dt.timezone.utc).isoformat()
        with output.open("x", encoding="utf-8") as stream:
            stream.write(json.dumps(value, indent=2, ensure_ascii=True, allow_nan=False) + "\n")
        summary = check_probe_failure_classification(rows, value, split=args.split)
        event(event="classification_completed", **summary)
        return 0
    except Exception as error:
        code = str(error) if isinstance(error, ValueError) and str(error).replace("_", "").isalnum() else None
        event(event="classification_failed", error_type=type(error).__name__, code=code,
              raw_diagnostics_omitted=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
