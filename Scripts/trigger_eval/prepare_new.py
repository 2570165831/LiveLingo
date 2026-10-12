"""Bind independent official UN downloads to the same frozen collection recipe.

This does not read predictions, thresholds, or validation outputs. It verifies
the download receipt and derives time windows using prepare.energy_windows.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys

if __package__:
    from .prepare import energy_windows, save_new, sha256
else:
    from prepare import energy_windows, save_new, sha256

EXCLUDED = {10142, 10153, 10168, 10192}


def receipt_path(root, receipt):
    candidate = (root / receipt["path"]).resolve(strict=True)
    if not candidate.is_relative_to(root.resolve(strict=True)) or not candidate.is_file():
        raise ValueError("receipt_path_outside_audio_root")
    if sha256(candidate) != receipt["sha256"]:
        raise ValueError("download_receipt_hash_mismatch")
    return candidate


def prepare_new(manifest_path, audio_root, output):
    manifest_path, audio_root, output = Path(manifest_path), Path(audio_root), Path(output)
    receipt = json.loads(manifest_path.read_bytes())
    if receipt.get("status") != "completed":
        # Accept the explicit verified receipt status used by the downloader.
        if receipt.get("status") not in ("downloaded_and_verified", "collector_inputs_prepared_and_verified", "passed", "complete", "verified"):
            raise ValueError("download_receipt_not_complete")
    tracks = []
    for meeting in receipt["meetings"]:
        number = meeting["meeting_number"]
        if number in EXCLUDED:
            raise ValueError("new_validation_overlaps_old_meetings")
        parsed = receipt_path(audio_root, meeting["english_record_turns"])
        document = json.loads(parsed.read_bytes())
        turns = document["en"]["turns"]
        if not turns or not all(isinstance(t.get("header"), str) and isinstance(t.get("text"), str) for t in turns):
            raise ValueError("official_turns_incomplete")
        # Collector accepts the generic turns[] schema. Public source texts only.
        normalized = output.parent / "alignment-input" / f"UN{number}.official-turns.json"
        save_new(normalized, {"id": meeting["id"], "source_sha256": sha256(parsed), "turns": turns})
        roles = {t["role"] for t in meeting["audio_tracks"]}
        if roles != {"floor", "interp-en"}:
            raise ValueError("both_public_audio_tracks_required")
        for audio in meeting["audio_tracks"]:
            source = receipt_path(audio_root, audio)
            tracks.append({"dataset": f"UN{number}", "split": "new", "track": audio["role"],
                "audio": str(source), "source_sha256": audio["sha256"], "private_classroom": False,
                "official_turns": str(normalized.resolve()), "windows": energy_windows(source),
                "meeting_date": meeting["date"], "source_url": meeting["url"]})
    if not 2 <= len(receipt["meetings"]) <= 3:
        raise ValueError("independent_meeting_count_not_two_or_three")
    save_new(output, {"schema": 1, "split": "new", "source_manifest_sha256": sha256(manifest_path),
        "selection_used_predictions": False,
        "segmentation": {"method": "reconstructed_energy_proxy", "minimum_s": 6, "maximum_s": 8,
                         "frame_s": .25, "quiet_tail_s": .5, "quiet_dbfs": -35}, "tracks": tracks})
    return {"tracks": len(tracks), "segments": sum(len(t["windows"]) for t in tracks),
            "audio_hours": sum(sum(w["end_s"] - w["start_s"] for w in t["windows"]) for t in tracks) / 3600}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("manifest", "audio-root", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--site-packages", type=Path)
    args = parser.parse_args()
    if args.site_packages:
        sys.path.insert(0, str(args.site_packages.resolve(strict=True)))
    os.environ["TMPDIR"] = str((args.output.parent / "tmp").resolve())
    try:
        print(json.dumps({"event": "new_manifest_completed", **prepare_new(args.manifest, args.audio_root, args.output)}))
    except Exception as error:
        parser.exit(1, f"new_corpus_preparation_failed ({type(error).__name__}); raw diagnostics omitted\n")


if __name__ == "__main__":
    main()
