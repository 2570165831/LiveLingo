"""Prepare local, content-free corpus manifests; source media stays read-only.

Segmentation is an explicitly reconstructed acoustic proxy, not live App
chunking: 250 ms energy frames, 6 s pause search, 8 s maximum, 500 ms quiet tail.
The original experiment's segmentation program was lost. Classroom windows
instead use its surviving census boundaries exactly.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys


def sha256(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def save_new(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2, allow_nan=False)
        stream.write("\n")


def m4s_offset(path):
    """Identify the first ISO BMFF ftyp box without altering the source."""
    with Path(path).open("rb") as stream:
        head = stream.read(4096)
    offset = head.find(b"ftyp") - 4
    if offset < 0 or offset + 8 > len(head):
        raise ValueError("media_header_unrecognized")
    size = int.from_bytes(head[offset:offset + 4], "big")
    if not 8 <= size <= len(head) - offset:
        raise ValueError("media_header_unrecognized")
    return offset


def convert_audio(source, destination, *, ffmpeg="ffmpeg", ffprobe="ffprobe"):
    source, destination = Path(source).resolve(strict=True), Path(destination)
    offset = m4s_offset(source) if source.suffix == ".m4s" else 0
    prefix = ["-f", "mov", "-skip_initial_bytes", str(offset)] if source.suffix == ".m4s" else []
    checked = subprocess.run([ffprobe, "-v", "error", *prefix, "-show_streams",
                              "-show_format", "-of", "json", str(source)],
                             capture_output=True, check=True)
    info = json.loads(checked.stdout)
    streams = info["streams"]
    if len(streams) != 1 or streams[0]["codec_type"] != "audio":
        raise ValueError("source_is_not_one_audio_track")
    duration = float(info["format"]["duration"])
    if not math.isfinite(duration) or duration <= 0:
        raise ValueError("invalid_source_duration")
    if not destination.exists():
        destination.parent.mkdir(parents=True, exist_ok=True)
        result = subprocess.run([ffmpeg, "-v", "error", "-nostdin", "-n", *prefix,
                                 "-i", str(source), "-map", "0:a:0", "-ac", "1",
                                 "-ar", "16000", "-c:a", "pcm_s16le", str(destination)],
                                capture_output=True)
        if result.returncode:
            raise ValueError("audio_conversion_failed")
    return {"source": str(source), "source_bytes": source.stat().st_size,
            "source_sha256": sha256(source), "padding_bytes_skipped": offset,
            "source_duration_s": duration, "audio": str(destination.resolve()),
            "audio_sha256": sha256(destination)}


def energy_windows(audio, *, minimum=6., maximum=8., frame_seconds=.25,
                   quiet_seconds=.5, quiet_dbfs=-35.):
    import numpy as np
    import soundfile as sf
    with sf.SoundFile(str(audio)) as stream:
        rate, total = stream.samplerate, len(stream)
        if stream.channels != 1 or rate != 16000 or not total:
            raise ValueError("audio_must_be_16k_mono")
        step = round(frame_seconds * rate)
        start = cursor = 0
        quiet = 0
        windows = []
        while cursor < total:
            samples = stream.read(min(step, total - cursor), dtype="float32")
            cursor += len(samples)
            rms = float(np.sqrt(np.mean(samples.astype(np.float64) ** 2)))
            quiet = quiet + len(samples) if rms < 10 ** (quiet_dbfs / 20) else 0
            elapsed = (cursor - start) / rate
            if elapsed >= maximum or (elapsed >= minimum and quiet / rate >= quiet_seconds):
                windows.append({"index": len(windows), "start_s": start / rate,
                                "end_s": cursor / rate,
                                "boundary_reason": "maximum" if elapsed >= maximum else "quiet_tail"})
                start, quiet = cursor, 0
        if start < total:
            windows.append({"index": len(windows), "start_s": start / rate,
                            "end_s": total / rate, "boundary_reason": "end_of_input"})
    return windows


def prepare(args):
    import soundfile as sf
    tracks = []
    for n in (10192, 10142, 10153, 10168):
        directory = args.un_root / f"S_PV.{n}"
        for track in ("floor", "interp-en"):
            source = directory / f"{track}.flac"
            tracks.append({"dataset": f"UN{n}", "split": "dev" if n == 10192 else "original",
                           "track": track, "audio": str(source.resolve(strict=True)),
                           "source_sha256": sha256(source), "private_classroom": False,
                           "official_turns": str((directory / "turns.json").resolve(strict=True)),
                           "windows": energy_windows(source)})
    source = args.cs50_clip.resolve(strict=True)
    tracks.append({"dataset": "CS50-dev", "split": "dev", "track": "english",
                   "audio": str(source), "source_sha256": sha256(source),
                   "reference_kind": "public_english_lecture", "reference_language": "en",
                   "private_classroom": False, "windows": energy_windows(source)})
    census = json.loads(args.classroom_census.read_bytes())["records"]
    source = args.classroom_audio.resolve(strict=True)
    info = sf.info(source)
    windows = []
    for r in sorted(census, key=lambda r: r["record_ordinal"]):
        start, end = r["start_s"], r["start_s"] + r["duration_s"]
        if not 0 <= start < end <= info.duration + .01:
            raise ValueError("classroom_interval_out_of_audio")
        # Strict numeric aggregate projection: no ASR strings or durable payload.
        language = {"English": "en", "Chinese": "zh", "Cantonese": "yue", "Dutch": "nl"}.get(
            r["qwen_auto_raw"]["language_label"])
        windows.append({"index": r["record_ordinal"], "start_s": start, "end_s": end,
                        "reference_language": language, "reference_kind": "model_proxy",
                        "reference_trusted": False, "boundary_reason": "surviving_census"})
    tracks.append({"dataset": "classroom-0928", "split": "dev", "track": "original",
                   "audio": str(source), "source_sha256": sha256(source),
                   "private_classroom": True, "windows": windows})
    ids = [("35118190344", "Week0"), ("35121466047", "Week1"),
           ("35128739843", "Week2"), ("35132343540", "Week4"),
           ("35132672903", "Week5"), ("35135686814", "Week6"),
           ("35136668377", "Week7"), ("35137259792", "Week8"),
           ("35138175222", "Week10"), ("35136407473", "AI")]
    for folder, name in ids:
        sources = sorted((args.cs50_root / folder).glob("*-30280.m4s"))
        if len(sources) != 1:
            raise ValueError("cs50_audio_track_not_unique")
        audio = args.output.parent / "tmp" / "corpus" / f"CS50-{name}.wav"
        details = convert_audio(sources[0], audio, ffmpeg=args.ffmpeg, ffprobe=args.ffprobe)
        tracks.append({"dataset": f"CS50-{name}", "split": "original", "track": "english",
                       **details, "private_classroom": False, "reference_language": "en",
                       "reference_kind": "public_english_lecture", "windows": energy_windows(audio)})
        print(json.dumps({"event": "prepared", "dataset": f"CS50-{name}",
                          "segments": len(tracks[-1]["windows"])}), flush=True)
    manifest = {"schema": 1, "segmentation": {"method": "reconstructed_energy_proxy",
                "minimum_s": 6, "maximum_s": 8, "frame_s": .25, "quiet_tail_s": .5,
                "quiet_dbfs": -35, "app_chunking_equivalence_verified": False},
                "excluded_cs50": ["Week3 (whole overlapping lecture)"], "tracks": tracks}
    save_new(args.output, manifest)
    print(json.dumps({"event": "manifest_completed", "tracks": len(tracks),
                      "segments": sum(len(t["windows"]) for t in tracks)}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("un-root", "cs50-root", "cs50-clip", "classroom-census", "classroom-audio", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--ffprobe", default="ffprobe")
    parser.add_argument("--site-packages", type=Path)
    args = parser.parse_args()
    if args.site_packages:
        sys.path.insert(0, str(args.site_packages.resolve(strict=True)))
    os.environ["TMPDIR"] = str((args.output.parent / "tmp").resolve())
    try:
        prepare(args)
    except Exception:
        parser.exit(1, "corpus_preparation_failed; raw diagnostics omitted\n")


if __name__ == "__main__":
    main()
