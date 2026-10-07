#!/usr/bin/env python3
"""Frozen, offline CLI measurements. Reports never contain subtitle text.

Raw CLI sessions are private local evidence, kept separately from the numeric
reports. Reports stay in this checkout's ignored work/; the persistent session
lock lives in the Git common directory, shared by all worktrees. No sudo,
installation, network fetch, shared ASR endpoint, branch change or cleanup is
performed.
"""
import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import importlib.util
import io
import json
import math
import os
from pathlib import Path
import queue
import re
import shlex
import shutil
import signal
import stat
import struct
import subprocess
import sys
import tarfile
import threading
import time
import uuid

sys.dont_write_bytecode = True
import scoreboard_metrics as metrics
import scoreboard_energy as energy

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / "work"
DEFAULT = WORK / "scoreboard"
RULES = ROOT / "Fixtures" / "scoreboard-v1"
DERIVED = ROOT.parent / "work" / "dd-scoreboard"
SCHEMA = "livelingo-scoreboard/1"
CLIP_IDS = {"cs50-w3-search", "cs50-w3-structures", "cs50-w3-anchor2",
            "private-0928-30m", "private-0928-full"}
FAILURES = {"isolationFailed", "processingIncomplete", "noCaptions", "cleanupIncomplete",
            "outputExists", "unownedASR", "cancelled", "model_runtime", "invalid_saved_data",
            "session_archive", "operation_failed", "invalidArguments", "unsafeOutput"}
EVENTS = {"prepare", "state", "capture", "capture_ready", "processing_finished", "progress",
          "run_verified", "saved_verified", "runtime_cleanup", "cli_failed", "cli_isolated",
          "runtime_cleanup_start",
          "asr_owned", "translation_failure", "review_start", "review_done", "review_skipped",
          "save_failed", "exported", "opened", "resumed"}
NUMBER_FIELDS = {"elapsedSeconds", "segments", "translated", "summarized", "pendingTranscription",
                 "unresolvedTranscription", "otherLanguageTranscription", "jobs", "bytes", "revision",
                 "batches", "chineseCaptions", "otherLanguageCaptions", "languageProbes", "seconds",
                 "stopSeconds", "missingTranslations", "audioSeconds", "pid", "port", "code",
                 "translationFailureCount"}
BOOL_FIELDS = {"confirmed", "summaryRunning", "concurrency", "paused", "capture", "wholeRunVerified"}
FAILURE_REASONS = {"processExited", "requestTimedOut", "outputLimitReached", "translationRejected",
                   "runtimeUnavailable", "invalidResponse", "generationInterrupted", "requestFailed",
                   "dependencyCancelled", "unknown", "cancelled", "interrupted"}
ENUM_FIELDS = {"kind": {"silent-pcm-replay", "file-import", "system-audio"},
               "scope": {"export_integrity"}, "reason": FAILURES,
               "translationFailureReason": FAILURE_REASONS,
               "captionState": {"present", "no_captions"}}


class Rejected(Exception):
    def __init__(self, reason, code=2):
        self.reason, self.code = reason, code


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for part in iter(lambda: stream.read(1 << 20), b""):
            digest.update(part)
    return digest.hexdigest()


def read_json(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise Rejected("invalid_json", 3) from None


def read_lines(path):
    try:
        return [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]
    except (OSError, ValueError):
        raise Rejected("invalid_jsonl", 4) from None


def numeric(value):
    return type(value) in (int, float) and math.isfinite(value)


def writable(path, *, derived=False):
    """Reject symlinks, including symlink parents, before creating anything."""
    path = Path(os.path.abspath(path))
    boundary = DERIVED if derived else WORK
    if not path.is_relative_to(boundary) or path == boundary:
        raise Rejected("output_outside_owned_work")
    for component in [path, *path.parents]:
        if component.is_symlink():
            raise Rejected("symlink_output")
        if component == ROOT.parent:
            break
    if not path.resolve().is_relative_to(boundary.resolve()):
        raise Rejected("output_outside_owned_work")
    return path


def new_directory(path):
    path = writable(path)
    if path.exists():
        raise Rejected("output_exists")
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.mkdir(mode=0o700)
    return path


def exclusive(path, binary=False):
    path = writable(path)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags, 0o600)
    except OSError:
        raise Rejected("output_exists_or_unwritable") from None
    return os.fdopen(fd, "wb" if binary else "w", **({} if binary else {"encoding": "utf-8"}))


def write_json(path, value):
    with exclusive(path) as stream:
        json.dump(value, stream, ensure_ascii=True, indent=2, sort_keys=True, allow_nan=False)
        stream.write("\n")


def write_jsonl(path, rows):
    with exclusive(path) as stream:
        for row in rows:
            stream.write(json.dumps(row, ensure_ascii=True, sort_keys=True, allow_nan=False) + "\n")


def default_machine_lock_directory():
    """Return the shared lock directory without creating it.

    Anchor Git discovery to this script's checkout, never the caller's cwd or
    output directory. Ignore inherited Git routing overrides so every worktree
    of this repository selects the same untracked Git metadata directory.
    """
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    common = Path(command(["git", "-C", str(ROOT), "rev-parse", "--path-format=absolute",
                           "--git-common-dir"], cwd=ROOT, env=env).decode().strip())
    if not common.is_absolute() or not common.is_dir():
        raise Rejected("invalid_lock")
    return common.resolve() / "work" / "scoreboard"


@contextlib.contextmanager
def session_lock(directory=None):
    """Hold the cross-worktree lock for the whole session, including idle time.

    Production callers use session_lock() with no output-path argument.
    Explicit directories retain the checkout work/ boundary for local tests.
    """
    if directory is None:
        directory = default_machine_lock_directory()
        path = directory / ".lock"
        for component in (path, directory, directory.parent):
            if component.is_symlink():
                raise Rejected("symlink_output")
    else:
        path = writable(Path(directory) / ".lock")
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(path, os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise Rejected("invalid_lock")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Rejected("scoreboard_busy") from None
        # The persistent lock is never unlinked, avoiding inode-replacement races.
        yield
    finally:
        os.close(fd)


def command(arguments, *, cwd=ROOT, timeout=120, env=None):
    try:
        result = subprocess.run(arguments, cwd=cwd, env=env, capture_output=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        raise Rejected("command_unavailable_or_timed_out") from None
    if result.returncode:
        raise Rejected("command_failed")
    return result.stdout


def git(*arguments):
    return command(["git", *arguments]).decode().strip()


def safe_event(row):
    if not isinstance(row, dict) or row.get("event") not in EVENTS:
        return None
    result = {"event": row["event"]}
    for key in NUMBER_FIELDS:
        if key in row and numeric(row[key]):
            result[key] = row[key]
    for key in BOOL_FIELDS:
        if type(row.get(key)) is bool:
            result[key] = row[key]
    for key, allowed in ENUM_FIELDS.items():
        if isinstance(row.get(key), str) and row[key] in allowed:
            result[key] = row[key]
    # Paths, session UUIDs and arbitrary strings are deliberately omitted.
    return result


def wav_info(path):
    """RIFF PCM/IEEE-float parser; wave in Python 3.11 cannot read f32 WAV."""
    with Path(path).open("rb") as stream:
        header = stream.read(12)
        if len(header) != 12 or header[:4] != b"RIFF" or header[8:] != b"WAVE":
            raise Rejected("invalid_wave", 3)
        fmt, data_bytes = None, None
        while chunk := stream.read(8):
            if len(chunk) != 8:
                raise Rejected("truncated_wave", 3)
            tag, size = struct.unpack("<4sI", chunk)
            offset = stream.tell()
            if tag == b"fmt ":
                data = stream.read(min(size, 40))
                if len(data) < 16:
                    raise Rejected("invalid_wave_format", 3)
                encoding, channels, rate, _, block, bits = struct.unpack("<HHIIHH", data[:16])
                if encoding == 65534 and len(data) >= 40:
                    encoding = struct.unpack("<H", data[24:26])[0]
                if encoding not in (1, 3) or not channels or not rate or block != channels * bits // 8:
                    raise Rejected("unsupported_wave", 3)
                fmt = dict(encoding=encoding, channels=channels, sample_rate=rate, block_align=block, bits=bits)
            elif tag == b"data":
                if offset + size > Path(path).stat().st_size:
                    raise Rejected("truncated_wave_data", 3)
                data_bytes = size
            stream.seek(offset + size + (size & 1))
        if fmt is None or not data_bytes or data_bytes % fmt["block_align"]:
            raise Rejected("invalid_wave_data", 3)
    frames = data_bytes // fmt["block_align"]
    return dict(fmt, frames=frames, seconds=frames / fmt["sample_rate"])


def parse_srt(text):
    cues = []
    for block in re.split(r"\n\s*\n", text.replace("\r\n", "\n").strip()):
        lines = block.splitlines()
        if len(lines) < 3 or not lines[0].isdigit():
            raise Rejected("invalid_srt", 3)
        times = re.fullmatch(r"(\d+):(\d+):(\d+)[,.](\d{3}) --> (\d+):(\d+):(\d+)[,.](\d{3})", lines[1])
        if not times:
            raise Rejected("invalid_srt_time", 3)
        a = list(map(int, times.groups()))
        seconds = lambda x: x[0] * 3600 + x[1] * 60 + x[2] + x[3] / 1000
        start, end = seconds(a[:4]), seconds(a[4:])
        if end <= start or (cues and int(lines[0]) <= cues[-1]["cue_id"]):
            raise Rejected("invalid_srt_order", 3)
        cues.append(dict(cue_id=int(lines[0]), start_rel=start, end_rel=end,
                         text=re.sub(r"<[^>]*>", "", " ".join(lines[2:]))))
    return cues


def checked_source(config, key, expected=None):
    item = config.get(key, {})
    path, fingerprint = item.get("path"), item.get("sha256")
    if not path or not Path(path).is_absolute() or not Path(path).is_file():
        raise Rejected("source_missing", 3)
    if not isinstance(fingerprint, str) or not re.fullmatch(r"[0-9a-f]{64}", fingerprint):
        raise Rejected("source_hash_required", 3)
    if (expected and fingerprint != expected) or sha256(path) != fingerprint:
        raise Rejected("source_hash_mismatch", 3)
    return Path(path)


def prepare(args):
    ruler = read_json(RULES / "ruler.json")
    config = read_json(args.sources)
    public = checked_source(config, "public_audio", ruler["public_source_sha256"])
    subtitle = checked_source(config, "official_srt", ruler["official_srt_sha256"])
    private = checked_source(config, "private_audio")
    private_info = wav_info(private)
    if (private_info["encoding"], private_info["sample_rate"], private_info["channels"], private_info["bits"]) != (3, 32000, 1, 32):
        raise Rejected("private_source_format_mismatch", 3)
    cues = parse_srt(subtitle.read_text(encoding="utf-8-sig"))
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise Rejected("ffmpeg_unavailable")
    out = new_directory(args.out)
    reusable = verify_fixtures(args.reuse) if args.reuse else None
    (out / "references").mkdir(mode=0o700)
    (out / "rules").mkdir(mode=0o700)
    files, clips = {}, []
    for name in ("ruler.json", "normalizer-v1.json", "cs50-glossary-v1.json", "translation-authored-80.json"):
        target = out / "rules" / name
        with exclusive(target, True) as stream:
            stream.write((RULES / name).read_bytes())
        files[str(target.relative_to(out))] = sha256(target)
    if files["rules/translation-authored-80.json"] != ruler["authored80_sha256"]:
        raise Rejected("authored_set_hash_mismatch", 3)
    for definition in ruler["clips"]:
        clip = dict(definition)
        start, end = clip["start"], clip["end"]
        if end is None:
            end = private_info["seconds"]
        rate, channels = clip["sample_rate"], clip["channels"]
        target = out / (clip["id"] + ".wav")
        source = public if clip["privacy"] == "public" else private
        input_path = "subfile,,start,9,end,0,,:" + str(source) if clip["privacy"] == "public" else str(source)
        # AAC packet timestamps can shift time-based atrim by whole samples.
        # Freeze the decoded sample clock for both sources, without resampling
        # private audio. The public source's verified format is 48 kHz stereo.
        trim = f"atrim=start_sample={round(start * rate)}:end_sample={round(end * rate)}"
        arguments = [ffmpeg, "-nostdin", "-n", "-v", "error", "-threads", "1", "-i", input_path,
                     "-vn", "-af", trim + ",asetpts=PTS-STARTPTS", "-c:a", "pcm_f32le"]
        if clip["privacy"] == "public":
            arguments += ["-ar", str(rate), "-ac", str(channels)]
        previous = next((item for item in reusable["clips"] if item["id"] == clip["id"] and item.get("start") == start
                         and item.get("end") == end), None) if reusable else None
        if previous and reusable.get("sources_sha256", {}).get("public_audio" if clip["privacy"] == "public" else "private_audio") == config["public_audio" if clip["privacy"] == "public" else "private_audio"]["sha256"]:
            # Reuse only a hash-verified frozen input. A hard link avoids another
            # media copy; neither side is ever modified by this script.
            os.link(fixture_path(args.reuse, previous["audio"]), target)
        else:
            command([*arguments, str(target)], timeout=300)
        info = wav_info(target)
        if abs(info["frames"] - round((end - start) * rate)) > 1 or info["channels"] != channels or info["sample_rate"] != rate:
            raise Rejected("fixture_frame_mismatch", 3)
        clip.update(audio=target.name, audio_seconds=info["seconds"], frames=info["frames"], end=end)
        files[target.name] = sha256(target)
        if clip["privacy"] == "public":
            selected = [dict(cue, start_rel=round(cue["start_rel"] - start, 6), end_rel=round(cue["end_rel"] - start, 6))
                        for cue in cues if clip["cue_first"] <= cue["cue_id"] <= clip["cue_last"]]
            if (len(selected) != clip["cue_last"] - clip["cue_first"] + 1 or
                    abs(selected[0]["start_rel"]) > 0.0011 or
                    abs(selected[-1]["end_rel"] - (end - start)) > 0.0011 or
                    any(c["start_rel"] < -0.0011 or c["end_rel"] > end - start + 0.0011 for c in selected)):
                raise Rejected("reference_window_mismatch", 3)
            expected = config.get("reference_checks", {}).get(clip["id"])
            if expected:
                previous = read_json(expected)
                if metrics.tokens_raw(" ".join(c["text"] for c in selected)) != metrics.tokens_raw(previous["reference"]):
                    raise Rejected("reference_word_mismatch", 3)
                clip["reference_checked"] = True
            else:
                clip["reference_checked"] = False
            reference = out / "references" / (clip["id"] + ".json")
            write_json(reference, selected)
            clip["reference"] = str(reference.relative_to(out))
            files[clip["reference"]] = sha256(reference)
        clips.append(clip)
        print(json.dumps({"event": "fixture_prepared", "clip": clip["id"], "frames": info["frames"]}), flush=True)
    manifest = dict(schema="livelingo-fixtures/1", id=ruler["id"], files=files, clips=clips,
                    sources_sha256={key: config[key]["sha256"] for key in ("public_audio", "official_srt", "private_audio")},
                    ffmpeg_sha256=sha256(ffmpeg), ffmpeg_version_sha256=hashlib.sha256(command([ffmpeg, "-version"])).hexdigest())
    write_json(out / "fixtures-manifest.json", manifest)
    return 0


def fixture_path(root, relative):
    if not isinstance(relative, str) or Path(relative).is_absolute() or ".." in Path(relative).parts:
        raise Rejected("fixture_path_escape", 3)
    path = Path(root) / relative
    if not path.resolve().is_relative_to(Path(root).resolve()) or path.is_symlink() or not path.is_file():
        raise Rejected("fixture_path_escape_or_missing", 3)
    return path


def verify_fixtures(root):
    root = Path(root).resolve()
    manifest = read_json(root / "fixtures-manifest.json")
    if manifest.get("schema") != "livelingo-fixtures/1":
        raise Rejected("invalid_fixture_schema", 3)
    files = manifest.get("files", {})
    for name, fingerprint in files.items():
        if sha256(fixture_path(root, name)) != fingerprint:
            raise Rejected("fixture_hash_mismatch", 3)
    for clip in manifest.get("clips", []):
        if clip.get("id") not in CLIP_IDS or clip.get("privacy") not in ("public", "private"):
            raise Rejected("invalid_clip_id", 3)
        if clip.get("audio") not in files or (clip.get("reference") and clip["reference"] not in files):
            raise Rejected("unfrozen_fixture", 3)
        if (clip["privacy"] == "public") != bool(clip.get("reference")):
            raise Rejected("reference_privacy_mismatch", 3)
        if not numeric(clip.get("audio_seconds")) or clip["audio_seconds"] <= 0:
            raise Rejected("invalid_fixture_duration", 3)
        info = wav_info(fixture_path(root, clip["audio"]))
        if abs(info["seconds"] - clip["audio_seconds"]) > 1 / info["sample_rate"]:
            raise Rejected("fixture_duration_mismatch", 3)
        if clip.get("frames") != info["frames"]:
            raise Rejected("fixture_frame_mismatch", 3)
    for required in ("ruler.json", "normalizer-v1.json", "cs50-glossary-v1.json", "translation-authored-80.json"):
        if "rules/" + required not in files:
            raise Rejected("unfrozen_rules", 3)
        if files["rules/" + required] != sha256(RULES / required):
            raise Rejected("scorer_rule_version_mismatch", 3)
    return manifest


def runtime_config(path):
    data = read_json(path)
    for key in ("python", "asr_site_packages", "language_site_packages", "models"):
        value = data.get(key)
        if not value or not Path(value).is_absolute() or not Path(value).exists():
            raise Rejected("runtime_path_missing")
        resolved = Path(value).resolve()
        if resolved.is_relative_to(Path("/Applications")):
            raise Rejected("installed_runtime_refused")
        if key != "python" and not resolved.is_dir():
            raise Rejected("invalid_runtime_directory")
    return data


def tree_manifest(root):
    """Hash every dependency file, never follow directory symlinks."""
    root = Path(root).resolve()
    digest, count = hashlib.sha256(), 0
    for directory, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = sorted(d for d in dirs if d != "__pycache__")
        for name in sorted(files):
            path = Path(directory) / name
            if name.endswith(".pyc"):
                continue
            if not path.is_file():
                raise Rejected("runtime_unreadable")
            digest.update(str(path.relative_to(root)).encode() + b"\0" + sha256(path).encode() + b"\n")
            count += 1
    return {"sha256": digest.hexdigest(), "files": count}


def shell_host(path, python, packages):
    with exclusive(path) as stream:
        stream.write("#!/bin/sh\nexport PYTHONDONTWRITEBYTECODE=1\nexport PYTHONNOUSERSITE=1\n")
        stream.write("export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1\n")
        stream.write("export PYTHONPATH=" + shlex.quote(packages) + "\n")
        stream.write("exec " + shlex.quote(python) + ' -B "$@"\n')
    path.chmod(0o700)


def build(args):
    config = runtime_config(args.runtime)
    commit = git("rev-parse", "--verify", args.commit + "^{commit}")
    dirty = bool(git("status", "--porcelain", "--untracked-files=normal")) if args.commit == "HEAD" else False
    out = new_directory(args.out)
    source = out / "source"
    source.mkdir(mode=0o700)
    source_hash = hashlib.sha256()
    if dirty:
        names = command(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"]).split(b"\0")
        for raw in sorted(set(names)):
            if not raw:
                continue
            relative = Path(os.fsdecode(raw))
            original = ROOT / relative
            if not original.exists():
                source_hash.update(raw + b"\0deleted\n")
                continue
            if original.is_symlink() or not original.is_file():
                raise Rejected("source_symlink_refused")
            data = original.read_bytes()
            source_hash.update(raw + b"\0" + hashlib.sha256(data).digest())
            target = source / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            with exclusive(target, True) as stream:
                stream.write(data)
    else:
        blob = command(["git", "archive", commit])
        with tarfile.open(fileobj=io.BytesIO(blob)) as archive:
            for entry in archive.getmembers():
                target = source / entry.name
                if entry.issym() or entry.islnk() or not target.resolve().is_relative_to(source.resolve()):
                    raise Rejected("unsafe_source_archive")
                if entry.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                elif entry.isfile():
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with exclusive(target, True) as stream:
                        stream.write(archive.extractfile(entry).read())
                else:
                    raise Rejected("unsafe_source_archive")
    cache = DERIVED / "ModuleCache"
    writable(cache, derived=True).mkdir(parents=True, exist_ok=True)
    compile_out = out / "compiled"
    env = os.environ.copy()
    env.update(TMPDIR=str(WORK / "tmp"), CLANG_MODULE_CACHE_PATH=str(cache), SWIFT_MODULECACHE_PATH=str(cache))
    (WORK / "tmp").mkdir(parents=True, exist_ok=True)
    with exclusive(out / "build.log", True) as log:
        result = subprocess.run(["bash", str(source / "Scripts/build-cli.sh"), str(compile_out),
                                 "--module-cache", str(cache)], cwd=source, env=env, stdout=log, stderr=log)
    if result.returncode:
        raise Rejected("build_failed")
    for name in ("livelingo-cli", "livelingo-virtual-player"):
        shutil.copy2(compile_out / name, out / name)
    (out / "ASRRuntime/python/bin").mkdir(parents=True)
    shell_host(out / "ASRRuntime/python/bin/python3", config["python"], config["asr_site_packages"])
    shell_host(out / "language-python-host", config["python"], config["language_site_packages"])
    shutil.copytree(source / "Scripts/mlx_runtime", out / "mlx_runtime", ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    shutil.copy2(source / "Scripts/qwen_asr_service.py", out / "ASRRuntime/qwen_asr_service.py")
    timing = source / "Scripts/scoreboard_timing.py"
    if timing.is_file():
        shutil.copy2(timing, out / "ASRRuntime/scoreboard_timing.py")
        shutil.copy2(timing, out / "mlx_runtime/scoreboard_timing.py")
    (out / "Models").symlink_to(Path(config["models"]).resolve(), target_is_directory=True)
    provenance = dict(commit=commit, dirty=dirty, source_tree_sha256=source_hash.hexdigest() if dirty else None,
                      cli_sha256=sha256(out / "livelingo-cli"), asr_service_sha256=sha256(out / "ASRRuntime/qwen_asr_service.py"),
                      asr_host_sha256=sha256(out / "ASRRuntime/python/bin/python3"),
                      language_host_sha256=sha256(out / "language-python-host"),
                      asr_timing_sha256=sha256(out / "ASRRuntime/scoreboard_timing.py") if timing.is_file() else None,
                      external_python_sha256=sha256(config["python"]),
                      runtime_sources={key: str(Path(config[key])) for key in
                                       ("python", "asr_site_packages", "language_site_packages", "models")},
                      mlx_runtime_tree=tree_manifest(out / "mlx_runtime"),
                      models_manifest=tree_manifest(config["models"]),
                      asr_packages_manifest=tree_manifest(config["asr_site_packages"]),
                      language_packages_manifest=tree_manifest(config["language_site_packages"]),
                      swift_version_sha256=hashlib.sha256(command(["xcrun", "swiftc", "--version"])).hexdigest())
    write_json(out / "build-provenance.json", provenance)
    print(json.dumps({"event": "build_complete", "cli_sha256": provenance["cli_sha256"]}), flush=True)
    return out


_classroom_spec = importlib.util.spec_from_file_location("scoreboard_classroom", ROOT / "Scripts/classroom-metrics.py")
classroom = importlib.util.module_from_spec(_classroom_spec)
_classroom_spec.loader.exec_module(classroom)


def read_processes():
    # Keep executable/start-time identities unchanged for owned-process checks.
    # comm= alone cannot distinguish an independent Python translation worker.
    rows = classroom.read_processes()
    commands = subprocess.check_output(["/bin/ps", "-ww", "-axo", "pid=,args="], text=True)
    for line in commands.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2:
            raise Rejected("invalid_process_table")
        pid = int(fields[0])
        if pid in rows:
            rows[pid]["command"] = fields[1]
    return rows


def standalone_worker(row):
    command_line = row.get("command", row["executable"])
    try:
        executable = shlex.split(row["executable"])[0]
    except (ValueError, IndexError):
        executable = ""
    python = any(re.fullmatch(r"python(?:\d+(?:\.\d+)*)?", name, re.IGNORECASE)
                 for name in (Path(row["executable"]).name, Path(executable).name))
    return bool(python and
                re.search(r"(?:^|[/\s\"'])(?:mlx_runtime|LanguageRuntime)/worker\.py(?=$|[\s\"'])", command_line) and
                re.search(r"(?:^|\s)--model(?:=|\s)", command_line) and
                re.search(r"(?:^|\s)--state-directory(?:=|\s)", command_line))


def busy_processes(rows, *, owned_pids=()):
    """Return busy PIDs, excluding only the caller's explicitly owned children."""
    owned = set(owned_pids)
    return [row["pid"] for row in rows.values() if row["pid"] not in owned and
            not row["state"].startswith("Z") and
            (Path(row["executable"]).name == "livelingo-cli" or
             "LiveLingo.app/Contents/MacOS/" in row["executable"] or standalone_worker(row))]


def preflight_processes(provider=read_processes, *, owned_pids=()):
    if busy_processes(provider(), owned_pids=owned_pids):
        raise Rejected("another_livelingo_run_active")


def safe_build_provenance(provenance):
    """Only fixed booleans, file counts and validated hashes enter reports.

    Absolute dependency paths belong only to the local build record. External
    builds may have unrelated/free-form fields; none are measurement labels.
    """
    hex_value = lambda value, sizes: isinstance(value, str) and len(value) in sizes and re.fullmatch(r"[0-9a-f]+", value)
    result = {"commit": provenance.get("commit") if hex_value(provenance.get("commit"), (40, 64)) else None,
              "dirty": provenance.get("dirty") if type(provenance.get("dirty")) is bool else None,
              "runtime_hashes_verified": provenance.get("runtime_hashes_verified") is True,
              "external_dependency_hashes_verified": provenance.get("external_dependency_hashes_verified") is True}
    for key in ("cli_sha256", "source_tree_sha256", "asr_service_sha256", "asr_host_sha256",
                "language_host_sha256", "asr_timing_sha256", "external_python_sha256", "swift_version_sha256"):
        if hex_value(provenance.get(key), (64,)):
            result[key] = provenance[key]
    for key in ("mlx_runtime_tree", "models_manifest", "asr_packages_manifest", "language_packages_manifest"):
        item = provenance.get(key)
        if isinstance(item, dict) and hex_value(item.get("sha256"), (64,)) and type(item.get("files")) is int and item["files"] >= 0:
            result[key] = {"sha256": item["sha256"], "files": item["files"]}
    return result


def build_info(path):
    path = Path(path).resolve()
    cli = path / "livelingo-cli" if path.is_dir() else path
    if not cli.is_file() or not os.access(cli, os.X_OK):
        raise Rejected("cli_unavailable")
    for dependency in (cli, cli.parent / "Models", cli.parent / "ASRRuntime", cli.parent / "language-python-host"):
        if dependency.resolve().is_relative_to(Path("/Applications")):
            raise Rejected("installed_runtime_refused")
    provenance_path = cli.parent / "build-provenance.json"
    provenance = read_json(provenance_path) if provenance_path.is_file() else {"commit": None, "dirty": None}
    fingerprint = sha256(cli)
    if provenance.get("cli_sha256", fingerprint) != fingerprint:
        raise Rejected("build_hash_mismatch", 3)
    provenance["cli_sha256"] = fingerprint
    copied_files = {"asr_service_sha256": "ASRRuntime/qwen_asr_service.py",
                    "asr_host_sha256": "ASRRuntime/python/bin/python3",
                    "language_host_sha256": "language-python-host",
                    "asr_timing_sha256": "ASRRuntime/scoreboard_timing.py"}
    for key, relative in copied_files.items():
        if key not in provenance:
            continue
        file = cli.parent / relative
        expected = provenance[key]
        if expected is None and key == "asr_timing_sha256" and not file.exists():
            continue
        if not file.is_file() or sha256(file) != expected:
            raise Rejected("build_runtime_hash_mismatch", 3)
    for key, relative in (("mlx_runtime_tree", "mlx_runtime"), ("models_manifest", "Models")):
        if key in provenance:
            directory = cli.parent / relative
            if not directory.is_dir() or tree_manifest(directory) != provenance[key]:
                raise Rejected("build_runtime_hash_mismatch", 3)
    sources = provenance.get("runtime_sources")
    external_verified = False
    if sources is not None:
        if not isinstance(sources, dict):
            raise Rejected("build_runtime_sources_invalid", 3)
        for key, manifest_key in (("python", "external_python_sha256"),
                                  ("asr_site_packages", "asr_packages_manifest"),
                                  ("language_site_packages", "language_packages_manifest"),
                                  ("models", "models_manifest")):
            value = sources.get(key)
            if not isinstance(value, str) or not Path(value).is_absolute():
                raise Rejected("build_runtime_sources_invalid", 3)
            dependency = Path(value).resolve()
            if dependency.is_relative_to(Path("/Applications")):
                raise Rejected("installed_runtime_refused")
            if manifest_key not in provenance or not dependency.exists():
                raise Rejected("build_runtime_hash_mismatch", 3)
            if key == "python":
                matches = dependency.is_file() and sha256(dependency) == provenance[manifest_key]
            elif key == "models":
                # This tree was just hashed through the build's model link.
                matches = dependency.is_dir() and dependency == (cli.parent / "Models").resolve()
            else:
                matches = dependency.is_dir() and tree_manifest(dependency) == provenance[manifest_key]
            if not matches:
                raise Rejected("build_runtime_hash_mismatch", 3)
        external_verified = True
    provenance["external_dependency_hashes_verified"] = external_verified
    provenance["runtime_hashes_verified"] = (external_verified and
        all(key in provenance for key in (*copied_files, "mlx_runtime_tree", "models_manifest")))
    return cli, safe_build_provenance(provenance)


def run_order(builds, repeats, order=None):
    if builds == 1:
        if order:
            raise Rejected("order_requires_two_builds")
        return ["A"] * repeats
    if builds != 2:
        raise Rejected("one_or_two_builds_required")
    if order is None:
        order = "ABBA" if repeats == 2 else "ABBAAB" if repeats == 3 else "AB" * repeats
    if any(letter not in "AB" for letter in order) or order.count("A") != repeats or order.count("B") != repeats:
        raise Rejected("invalid_interleaved_order")
    return list(order)


def runtime_environment(cli, run_dir):
    env = os.environ.copy()
    for key in ("LIVELINGO_ASR_ENDPOINT", "LIVELINGO_ASR_TOKEN", "PYTHONHOME", "PYTHONPATH",
                "LIVELINGO_MLX_PYTHON", "LIVELINGO_MLX_WORKER", "LIVELINGO_MLX_MODELS",
                "LIVELINGO_SCOREBOARD_TIMINGS"):
        env.pop(key, None)
    env.update(PYTHONDONTWRITEBYTECODE="1", PYTHONNOUSERSITE="1", HF_HUB_OFFLINE="1",
               TRANSFORMERS_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1", TOKENIZERS_PARALLELISM="false",
               TMPDIR=str(run_dir / "tmp"), XDG_CACHE_HOME=str(run_dir / "cache"),
               HF_HOME=str(run_dir / "cache/huggingface"))
    (run_dir / "tmp").mkdir(mode=0o700)
    (run_dir / "cache").mkdir(mode=0o700)
    for key, name in (("LIVELINGO_MLX_PYTHON", "language-python-host"),
                      ("LIVELINGO_MLX_WORKER", "mlx_runtime/worker.py"), ("LIVELINGO_MLX_MODELS", "Models")):
        path = cli.parent / name
        if path.exists():
            env[key] = str(path)
    timing = run_dir / "model-times.jsonl"
    with exclusive(timing):
        pass
    env["LIVELINGO_SCOREBOARD_TIMINGS"] = str(timing)
    return env


def signal_owned(process, root_identity, provider, sig):
    """Popen ownership plus a fresh PID/UID/start/executable check, never pkill."""
    if process.poll() is not None:
        return False
    row = provider().get(process.pid)
    if root_identity is None or row is None or classroom.identity(row) != root_identity:
        return False
    process.send_signal(sig)
    return True


def execute_cli(cli, arguments, run_dir, timeout, provider=read_processes, capture_required=True,
                capture_timeout=300, translate=False):
    env = runtime_environment(cli, run_dir)
    received = queue.Queue()
    start_wall, start_mono = time.time(), time.monotonic()
    process = subprocess.Popen([str(cli), *arguments], cwd=run_dir, env=env,
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    row = provider().get(process.pid)
    root_identity = classroom.identity(row) if row and row["uid"] == os.getuid() else None
    if root_identity and row["executable"] != str(cli.resolve()):
        # Script substitutes in unit tests are interpreted by Python. Real CLI
        # identity is still fixed at spawn and rechecked before any signal.
        if cli.read_bytes()[:2] != b"#!":
            root_identity = None
    known, rss_rows, peak = {}, [], None

    def reader(stream, kind):
        for raw in iter(stream.readline, b""):
            received.put((time.monotonic(), time.time(), kind, raw))
        stream.close()
        received.put((time.monotonic(), time.time(), kind, None))

    threads = [threading.Thread(target=reader, args=(stream, kind), daemon=True)
               for stream, kind in ((process.stdout, "stdout"), (process.stderr, "stderr"))]
    for thread in threads:
        thread.start()
    closed, events, text_output = set(), [], []
    capture_seen, timed_out, uncertain = False, False, root_identity is None
    next_rss = start_mono
    deadline = start_mono + timeout
    stop_phase, exit_observed = 0, None
    with exclusive(run_dir / "events.ndjson") as event_stream, exclusive(run_dir / "stderr-numeric.jsonl") as error_stream:
        while process.poll() is None or len(closed) < 2 or not received.empty():
            now = time.monotonic()
            if process.poll() is not None:
                exit_observed = exit_observed or now
                if now - exit_observed > 5 and len(closed) < 2:
                    uncertain = True
                    break
            if process.poll() is None and (now > deadline or (capture_required and not capture_seen and now - start_mono > capture_timeout)):
                timed_out = True
                if stop_phase == 0:
                    uncertain |= not signal_owned(process, root_identity, provider, signal.SIGINT)
                    stop_phase, deadline = 1, now + 30
                elif stop_phase == 1:
                    uncertain |= not signal_owned(process, root_identity, provider, signal.SIGTERM)
                    stop_phase, deadline = 2, now + 30
                else:
                    # Preserve evidence and refuse to launch any further workload.
                    raise Rejected("owned_process_did_not_stop", 4)
            if now >= next_rss and root_identity:
                rows = provider()
                owned = classroom.owned_processes(rows, root_identity, known)
                total = sum(item["rss_bytes"] for item in owned.values())
                peak = max(peak or 0, total)
                rss_rows.append(dict(uptime=now, rss_bytes=total, owned_processes=len(owned)))
                next_rss = now + 1
            try:
                mono, wall, kind, raw = received.get(timeout=0.05)
            except queue.Empty:
                continue
            if raw is None:
                closed.add(kind)
                continue
            try:
                parsed = json.loads(raw)
            except (ValueError, UnicodeError):
                # Text only exists in memory for the authored public text test.
                if translate and kind == "stdout":
                    text_output.append(raw.decode("utf-8", errors="replace"))
                continue
            safe = safe_event(parsed)
            if safe:
                envelope = dict(recv_mono=mono, recv_wall=wall, line=safe)
                events.append(envelope)
                stream = event_stream if kind == "stdout" else error_stream
                stream.write(json.dumps(envelope, sort_keys=True) + "\n")
                stream.flush()
                capture_seen |= safe["event"] in ("capture", "capture_ready")
                if safe["event"] in ("asr_owned", "runtime_cleanup_start") and root_identity:
                    # Observe short-lived workers at their ownership events,
                    # rather than relying on the next one-second RSS poll.
                    classroom.owned_processes(provider(), root_identity, known)
        for thread in threads:
            thread.join(timeout=1)
    exit_wall, exit_mono = time.time(), time.monotonic()
    remaining = classroom.owned_processes(provider(), root_identity, known) if root_identity else {}
    remaining.pop(process.pid, None)
    write_jsonl(run_dir / "rss.jsonl", rss_rows)
    result = dict(exit_code=process.returncode, spawn_wall=start_wall, spawn_mono=start_mono,
                  exit_wall=exit_wall, exit_mono=exit_mono, pid=process.pid, timeout=timed_out,
                  identity_verified=root_identity is not None, ownership_uncertain=uncertain,
                  residual_owned_processes=len(remaining), peak_owned_rss_bytes=peak,
                  clock_offset_start=start_wall - start_mono, clock_offset_end=exit_wall - exit_mono)
    write_json(run_dir / "execution.json", result)
    return result, "".join(text_output)


def translation_outputs(text):
    """Parse CLI OUTPUT[n] markers in memory; model labels are not translations."""
    outputs, current, lines = {}, None, []
    for line in text.splitlines():
        match = re.match(r"^OUTPUT\[(\d+)\]=(.*)$", line)
        if match:
            if current is not None:
                outputs[current] = "\n".join(lines)
            current, lines = int(match[1]), [match[2]]
        elif current is not None:
            lines.append(line)
    if current is not None:
        outputs[current] = "\n".join(lines)
    return outputs


def translation_file_outputs(path):
    """Read private JSONL translations; content never goes through argv/stdout."""
    if not path.exists():
        return {}
    if path.is_symlink() or not path.is_file():
        raise Rejected("invalid_translation_output", 4)
    outputs = {}
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            row = json.loads(line)
            if (not isinstance(row, dict) or set(row) != {"index", "text"}
                    or type(row["index"]) is not int or row["index"] != len(outputs)
                    or not isinstance(row["text"], str)):
                raise ValueError("invalid translation record")
            outputs[row["index"]] = row["text"]
    except (OSError, ValueError, UnicodeError):
        raise Rejected("invalid_translation_output", 4) from None
    return outputs


def collect_oslog(execution, run_dir):
    start = dt.datetime.fromtimestamp(execution["spawn_wall"] - 5).astimezone().strftime("%Y-%m-%d %H:%M:%S%z")
    end = dt.datetime.fromtimestamp(execution["exit_wall"] + 5).astimezone().strftime("%Y-%m-%d %H:%M:%S%z")
    predicate = f'subsystem == "com.jianhongli.LiveLingo" AND processIdentifier == {execution["pid"]}'
    try:
        output = command(["/usr/bin/log", "show", "--style", "ndjson", "--start", start, "--end", end,
                          "--predicate", predicate], timeout=60)
        rows = metrics.parse_oslog_numeric(output.decode(errors="replace"))
        status = "collected"
    except (Rejected, ValueError):
        rows, status = [], "unavailable"
    write_jsonl(run_dir / "oslog-numeric.jsonl", rows)
    return status


def last_event(events, name):
    return next((row["line"] for row in reversed(events) if row["line"]["event"] == name), {})


def validity(events, execution, census, count):
    finished, saved = last_event(events, "processing_finished"), last_event(events, "saved_verified")
    verified = bool(last_event(events, "run_verified"))
    cleanup = last_event(events, "runtime_cleanup").get("confirmed") is True
    unresolved = census.get("unresolved")
    mismatches = []
    if finished:
        for field, measured in (("unresolvedTranscription", unresolved),
                                ("otherLanguageTranscription", census.get("other_language")), ("segments", count)):
            if measured is not None and finished.get(field) != measured:
                mismatches.append(field)
    else:
        mismatches.append("processing_finished_missing")
    state = last_event(events, "state")
    if not state:
        mismatches.append("state_missing")
    elif state.get("pendingTranscription") != 0:
        mismatches.append("pendingTranscription")
    reason = last_event(events, "cli_failed").get("reason")
    complete = execution["exit_code"] == 0 and verified and cleanup
    if finished and unresolved:
        outcome = "completed_with_unresolved"
    elif complete:
        outcome = "completed"
    elif reason == "processingIncomplete" or finished:
        outcome = "processing_incomplete"
    else:
        outcome = "failed"
    return dict(exit_code=execution["exit_code"], cli_failed_reason=reason, run_verified=verified,
                cleanup_confirmed=cleanup, saved_verified=bool(saved), success=complete,
                outcome=outcome, timeout=execution["timeout"],
                consistency={"ok": not mismatches, "mismatches": mismatches},
                missingTranslations=saved.get("missingTranslations"))


def numeric_model_times(path):
    allowed = {"asr_load", "asr_inference", "language_load", "translation_step", "notes_step", "review_step", "text_step"}
    result = {}
    for stage in sorted(allowed):
        result[stage] = dict(samples=0, wall_seconds=None, process_cpu_seconds=None, failed_samples=0)
    rows = read_lines(path) if Path(path).exists() else []
    for row in rows:
        stage = row.get("stage")
        if stage not in allowed or not numeric(row.get("wall_seconds")) or row["wall_seconds"] < 0:
            raise Rejected("invalid_model_timing", 4)
        item = result[stage]
        item["samples"] += 1
        item["wall_seconds"] = (item["wall_seconds"] or 0) + row["wall_seconds"]
        if numeric(row.get("process_cpu_seconds")):
            item["process_cpu_seconds"] = (item["process_cpu_seconds"] or 0) + row["process_cpu_seconds"]
        item["failed_samples"] += row.get("completed") is False
    return dict(stages=result, available=bool(rows),
                scope="instrumented_model_call_wall_and_process_cpu_excludes_lock_wait_not_gpu_busy_time")


def phase_energy(measured, samples, execution, events, latency, audio_seconds):
    names = ("startup", "audio", "tail", "cleanup")
    result = dict(phase_boundaries_valid=False, phases_gross_j=dict.fromkeys(names),
                  phases_net_j=dict.fromkeys(names), phases_rails_net_j={name: dict.fromkeys(energy.RAILS) for name in names})
    if not measured or not latency.get("monotonic_export_valid") or latency.get("t0") is None:
        return result
    finished = next((row.get("recv_mono") for row in reversed(events)
                     if row["line"]["event"] == "processing_finished"), None)
    if finished is None:
        return result
    t0 = latency["t0"] - execution["clock_offset_start"]
    boundaries = [execution["spawn_mono"], t0, t0 + audio_seconds, finished, execution["exit_mono"]]
    if any(right < left for left, right in zip(boundaries, boundaries[1:])):
        return result
    result["phase_boundaries_valid"] = True
    for name, a, b in zip(names, boundaries, boundaries[1:]):
        if b == a:
            result["phases_gross_j"][name] = result["phases_net_j"][name] = 0.
            result["phases_rails_net_j"][name] = dict.fromkeys(energy.RAILS, 0.)
            continue
        window = energy.window_energy(samples, a, b)
        result["phases_gross_j"][name] = window["gross_j"]
        rails = {rail: window["rails_j"][rail] - measured["rails_idle_w"][rail]["used"] * (b - a)
                 if window["rails_j"][rail] is not None and measured["rails_idle_w"][rail]["used"] is not None else None
                 for rail in energy.RAILS}
        result["phases_rails_net_j"][name] = rails
        result["phases_net_j"][name] = sum(rails.values()) if all(numeric(value) for value in rails.values()) else None
    return result


def score_clip(clip, fixture_root, run_dir, execution, energy_result=None, samples=()):
    session = run_dir / "session"
    segments_path = session / "bilingual.jsonl"
    segments = read_lines(segments_path) if segments_path.is_file() else []
    events = read_lines(run_dir / "events.ndjson") + read_lines(run_dir / "stderr-numeric.jsonl")
    oslogs = read_lines(run_dir / "oslog-numeric.jsonl")
    missing = []
    try:
        census = metrics.durable_census(session)
    except (ValueError, OSError):
        census = {"unresolved": None, "other_language": None, "pending": None, "failed": None, "available": False}
        missing.append("durable_census_unavailable")
    reference = read_json(fixture_path(fixture_root, clip["reference"])) if clip.get("reference") else None
    ruler = read_json(fixture_path(fixture_root, "rules/ruler.json"))
    asr = metrics.score_asr(reference, segments, known_errors=ruler.get("known_reference_errors", [])) if reference is not None else None
    latency = metrics.latency_join(segments, oslogs, reference=reference, run_end_wall=execution["exit_wall"])
    offset_drift = abs(execution["clock_offset_end"] - execution["clock_offset_start"])
    latency["wall_monotonic_drift_seconds"] = offset_drift
    latency["monotonic_export_valid"] = offset_drift < 0.02
    latency["observed_values_seconds"] = {}
    for name, field in (("en_commit", "en_commit_wall"), ("zh_first", "first_wall"),
                        ("zh_final", "final_wall"), ("zh_final_from_start", "final_wall")):
        latency["observed_values_seconds"][name] = {subset: [row[field] - row["audio_start_wall" if name == "zh_final_from_start" else "audio_end_wall"]
            for row in latency.get("rows", []) if row.get(field) is not None and row.get("audio_end_wall") is not None
            and not row.get(name + "_censored") and not row.get(name + "_unmeasured")
            and (subset == "all" or row["steady"])] if latency["latency_valid"] else [] for subset in ("all", "steady")}
    if energy_result:
        energy_result.update(phase_energy(energy_result, samples, execution, events, latency, clip["audio_seconds"]))
    glossary = read_json(fixture_path(fixture_root, "rules/cs50-glossary-v1.json")) if reference is not None else None
    translation = metrics.translation_t2(segments, events=oslogs + metrics.parse_ndjson(events), glossary=glossary)
    finished = last_event(events, "processing_finished")
    translated, total = finished.get("translated"), finished.get("segments")
    translation["cli_completion"] = translated / total if numeric(translated) and numeric(total) and total > 0 else None
    translation["cli_translated"] = finished.get("translated")
    latency["tail_seconds"] = finished.get("stopSeconds")
    pending = [row["line"]["pendingTranscription"] for row in events if "pendingTranscription" in row["line"]]
    latency["max_pending_transcription"] = max(pending) if pending else None
    valid = validity(events, execution, census, len(segments))
    backends = [row.get("backend") for row in oslogs if row.get("event") == "backend" and row.get("kind") == "preview"]
    valid["preview_backend"] = backends[0] if backends else None
    valid["t0_anchor"] = latency.get("t0_anchor")
    if not segments_path.is_file():
        missing.append("bilingual_export_missing")
    if not oslogs:
        missing.append("latency_logs_missing")
    result = dict(validity=valid, asr=asr, latency=latency, translation=translation,
                  transcription=census, model_times=numeric_model_times(run_dir / "model-times.jsonl"),
                  energy=energy_result or {"mode": "disabled", "comparable": False},
                  resources={"wall_seconds": execution["exit_mono"] - execution["spawn_mono"],
                             "peak_owned_rss_bytes": execution.get("peak_owned_rss_bytes"),
                             "residual_owned_processes": execution.get("residual_owned_processes")},
                  unavailable_metrics=missing)
    return result


def save_metrics(directory, result, execution):
    rows = result["latency"].pop("rows", [])
    if result["latency"]["monotonic_export_valid"]:
        offset = execution["clock_offset_start"]
        converted = []
        for row in rows:
            item = {"segment_id": str(row["sequence"]), "sequence": row["sequence"],
                    "clock": "host_monotonic_seconds", "steady": row["steady"],
                    "final_censored": row["zh_final_censored"], "final_unmeasured": row["zh_final_unmeasured"]}
            for source, target in (("audio_start_wall", "audio_start_uptime"), ("audio_end_wall", "audio_end_uptime"),
                                   ("en_commit_wall", "english_commit_uptime"), ("first_wall", "first_translation_uptime"),
                                   ("final_wall", "final_translation_uptime")):
                if row.get(source) is not None:
                    item[target] = row[source] - offset
            converted.append(item)
        write_jsonl(directory / "latency.jsonl", converted)
    else:
        write_jsonl(directory / "latency.jsonl", [])
    write_json(directory / "metrics.json", result)


def headline(clips):
    runs = [run for item in clips.values() for run in item["runs"]]
    public = [run for item in clips.values() if item["privacy"] == "public" for run in item["runs"]]
    private = [run for item in clips.values() if item["privacy"] == "private" for run in item["runs"]]
    ref = sum(run["asr"]["norm_v1"]["ref_tokens"] for run in public if run.get("asr"))
    edits = sum(sum(run["asr"]["norm_v1"][k] for k in ("S", "D", "I")) for run in public if run.get("asr"))
    outcomes = {key: sum(run["validity"]["outcome"] == key for run in runs)
                for key in ("completed", "completed_with_unresolved", "processing_incomplete", "failed")}
    energies = [run["energy"] for run in runs]
    audio = sum(item["audio_seconds"] * len(item["runs"]) for item in clips.values())
    net = [item.get("net_j") for item in energies]
    def census_sum(selected, key):
        values = [run["transcription"].get(key) for run in selected]
        return sum(values) if all(numeric(value) for value in values) else None
    pooled_latency = {}
    any_censored = any(any(run["latency"]["censored"].values()) for run in runs)
    any_unmeasured = any(any(run["latency"]["unmeasured"].values()) for run in runs)
    for name in ("en_commit", "zh_first", "zh_final", "zh_final_from_start"):
        values = [value for run in runs for value in run["latency"].get("observed_values_seconds", {}).get(name, {}).get("steady", [])]
        censored = sum(run["latency"][name]["steady"]["censored"] for run in runs)
        unmeasured = sum(run["latency"][name]["steady"]["unmeasured"] for run in runs)
        pooled_latency[name] = metrics.distribution(values, censored=censored, unmeasured=unmeasured,
                                                  invalid=any(not run["latency"]["latency_valid"] for run in runs))
        if any_censored:
            pooled_latency[name]["population"] = "observed_censored"
        pooled_latency[name]["full_population_quantiles"] &= bool(values) and not (any_censored or any_unmeasured)
    critical = {kind: sum(run["asr"]["critical"][kind] for run in public if run.get("asr")) for kind in ("negation", "number", "code")}
    untranslated = [run["translation"]["untranslated_segments"] for run in runs]
    glossary = [run["translation"]["glossary"] for run in public]
    occurrences = sum(item["occurrences"] or 0 for item in glossary)
    result = dict(asr_norm_rate_cs50_pooled=edits / ref if ref else None,
                asr_ref_tokens_cs50=ref, asr_edits_cs50=edits if public else None,
                asr_critical_cs50_pooled=sum(critical.values()) if public else None,
                asr_negation_errors_cs50=critical["negation"] if public else None,
                asr_number_errors_cs50=critical["number"] if public else None,
                asr_code_errors_cs50=critical["code"] if public else None,
                untranslated_segments_all=sum(untranslated),
                glossary_hit_rate_cs50=sum(item["hits"] or 0 for item in glossary) / occurrences if occurrences else None,
                zh_final_steady_p50_s=pooled_latency["zh_final"]["p50_seconds"],
                zh_final_steady_p95_s=pooled_latency["zh_final"]["p95_seconds"],
                en_commit_steady_p95_s=pooled_latency["en_commit"]["p95_seconds"],
                runs_total=len(runs), runs_verified=sum(run["validity"]["success"] for run in runs), outcomes=outcomes,
                private_other_language=census_sum(private, "other_language") if private else None,
                private_failed=census_sum(private, "failed") if private else None,
                private_unresolved=census_sum(private, "unresolved") if private else None,
                cs50_other_language_false_positive=census_sum(public, "other_language") if public else None,
                energy_comparable=bool(energies) and all(e.get("comparable") is True for e in energies),
                net_j_per_audio_min_pooled=sum(net) / (audio / 60) if net and all(numeric(n) for n in net) and audio else None)
    result["latency_population"] = "observed_censored" if any_censored else "observed"
    result["latency_full_population_quantiles"] = all(d["full_population_quantiles"] for d in pooled_latency.values())
    result["latency_pooled_steady"] = pooled_latency
    return result


def display(value):
    return "unknown" if value is None else f"{value:.4f}" if isinstance(value, float) else str(value)


def markdown(report):
    lines = ["LiveLingo scoreboard · " + report["ruler"]["id"], "",
             "| clip | repeat | profile | ASR norm/raw | translation completion | outcome | wall s | net J/audio min |",
             "|---|---:|---|---|---|---|---:|---:|"]
    for clip_id, clip in report["clips"].items():
        for run in clip["runs"]:
            asr = run.get("asr")
            rate = "/".join(display(asr[key]["rate"]) for key in ("norm_v1", "raw")) if asr else "no_gold"
            translation = run["translation"].get("completion", run["translation"].get("completion_rate"))
            lines.append(f"| {clip_id} | {run['repeat']} | {run['profile']} | {rate} | {display(translation)} | "
                         f"{run['validity']['outcome']} | {display(run['resources']['wall_seconds'])} | "
                         f"{display(run['energy'].get('net_j_per_audio_min'))} |")
    lines += ["", "Official caption difference is not human-gold WER. Translation scores are proxies.",
              "Latency is measured per reference cue (private: exported caption cue), with a ±3 s matching window.",
              "Quantiles of observed completions are marked when there are right-censored or unmeasured samples.",
              "T0 is before the first audio write; first-result latency starts at T0.",
              "Energy covers whole-machine CPU/GPU/ANE estimates, including background tasks, excluding the screen.",
              "A proxy contains busy time and wall time only; it is never reported as joules."]
    lines += ["", "| clip/profile/repeat | final P50/P95 s | steady P50/P95 s | censored/unmeasured cues | first result from T0 s |",
              "|---|---:|---:|---:|---:|"]
    for clip_id, clip in report["clips"].items():
        for run in clip["runs"]:
            latency = run["latency"]
            def quantiles(subset):
                dist = latency["zh_final"][subset]
                label = " censored" if not dist["full_population_quantiles"] else ""
                return display(dist["p50_seconds"]) + "/" + display(dist["p95_seconds"]) + label
            lines.append(f"| {clip_id}/{run['profile']}/{run['repeat']} | {quantiles('all')} | {quantiles('steady')} | "
                         f"{latency['censored']['zh_final']}/{latency['unmeasured']['zh_final']} | "
                         f"{display(latency.get('first_result_latency_from_t0_s'))} |")
    lines += ["", "| clip/profile/repeat | ASR load/inference s | language load s | text/notes/review steps s | energy comparable |",
              "|---|---:|---:|---:|---|"]
    for clip_id, clip in report["clips"].items():
        for run in clip["runs"]:
            stages = run["model_times"]["stages"]
            value = lambda key: display(stages[key]["wall_seconds"])
            lines.append(f"| {clip_id}/{run['profile']}/{run['repeat']} | {value('asr_load')}/{value('asr_inference')} | "
                         f"{value('language_load')} | {value('text_step')}/{value('notes_step')}/{value('review_step')} | "
                         f"{str(run['energy'].get('comparable') is True).lower()} |")
    for item in report.get("translate_authored80", []):
        data = item["metrics"]
        lines += ["", "authored-80 " + item["build"] + "/" + item["profile"] + ": " +
                  json.dumps(data, ensure_ascii=True, sort_keys=True)]
    for key, comparison in report.get("comparison", {}).items():
        lines += ["", key + " comparison: " + comparison["outcome"],
                  "| metric | delta | conclusion |", "|---|---:|---|"]
        for name, item in comparison["metrics"].items():
            lines.append(f"| {name} | {display(item['delta'])} | {item['conclusion']} |")
    return "\n".join(lines) + "\n"


def aggregate(records, manifest, fixtures, builds, tier, repeats):
    clips = {}
    for record in records:
        clip = record["clip"]
        entry = clips.setdefault(clip["id"], {"privacy": clip["privacy"], "audio_seconds": clip["audio_seconds"],
                                             "fixture_sha256": manifest["files"][clip["audio"]], "runs": []})
        entry["runs"].append(dict(record["metrics"], repeat=record["repeat"], profile=record["profile"], build=record["build"]))
    report = dict(schema=SCHEMA, ruler={"id": manifest["id"], "fixtures_manifest_sha256": sha256(fixtures / "fixtures-manifest.json"),
                  "normalizer": "norm_v1", "normalizer_sha256": manifest["files"]["rules/normalizer-v1.json"],
                  "glossary_sha256": manifest["files"]["rules/cs50-glossary-v1.json"]},
                  scorer={"sha256": sha256(Path(__file__)), "metrics_sha256": sha256(ROOT / "Scripts/scoreboard_metrics.py"),
                          "energy_sha256": sha256(ROOT / "Scripts/scoreboard_energy.py"), "python": sys.version.split()[0]},
                  builds={key: safe_build_provenance(value) for key, value in builds.items()},
                  session={"tier": tier, "repeats": repeats}, clips=clips,
                  notices=["whole_machine_energy_not_process_attributed", "official_captions_not_gold",
                           "private_no_accuracy_gold", "observed_quantiles_with_censoring_labels"])
    report["headline"] = headline(clips)
    report["groups"] = {}
    for label, profile in sorted({(r["build"], r["profile"]) for r in records}):
        grouped = {key: dict(clip, runs=[run for run in clip["runs"] if run["build"] == label and run["profile"] == profile])
                   for key, clip in clips.items()}
        grouped = {key: clip for key, clip in grouped.items() if clip["runs"]}
        per_repeat = []
        for repeat in sorted({r["repeat"] for r in records if r["build"] == label and r["profile"] == profile}):
            sample = {key: dict(clip, runs=[run for run in clip["runs"] if run["repeat"] == repeat]) for key, clip in grouped.items()}
            sample = {key: clip for key, clip in sample.items() if clip["runs"]}
            per_repeat.append(dict(repeat=repeat, headline=headline(sample)))
        group = dict(profile=profile, build=label, headline=headline(grouped), repeat_headlines=per_repeat,
                     preview_backends={key: sorted({run["validity"]["preview_backend"] or "unknown" for run in clip["runs"]})
                                       for key, clip in grouped.items()})
        group["summary"] = {key: metrics.summarize_repeats([sample["headline"].get(key) for sample in per_repeat])
                            for key, value in group["headline"].items() if numeric(value) or value is None}
        report["groups"][label + "/" + profile] = group
    if len(report["groups"]) > 1:
        # Each build/profile is scored independently. A global pool would mix
        # the A/B measurements that the user is trying to compare.
        report["headline"] = {"groups_scored": len(report["groups"]), "runs_total": len(records)}
    return report


def write_report(out, report, history=True):
    write_json(out / "scoreboard.json", report)
    with exclusive(out / "scoreboard.md") as stream:
        stream.write(markdown(report))
    if history:
        path = writable(DEFAULT / "history.jsonl")
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                raise Rejected("invalid_history_file")
            row = dict(report_id=hashlib.sha256(str(out.relative_to(WORK)).encode()).hexdigest(),
                       sha256=sha256(out / "scoreboard.json"), headline=report["headline"])
            os.write(fd, (json.dumps(row, sort_keys=True) + "\n").encode())
        finally:
            os.close(fd)


def pause_window(seconds):
    start = time.monotonic()
    while time.monotonic() - start < seconds:
        time.sleep(min(30, seconds - (time.monotonic() - start)))
        if seconds >= 30:
            print(json.dumps({"event": "idle_sampling", "elapsed_seconds": time.monotonic() - start}), flush=True)
    return [start, time.monotonic()]


def run(args, provider=read_processes, log_collector=collect_oslog):
    manifest = verify_fixtures(args.fixtures)
    preflight_processes(provider)
    repeats = args.repeats
    if repeats < 1 or repeats > 20:
        raise Rejected("invalid_repeat_count")
    builds_requested = args.builds.split(",") if args.builds else [args.build]
    order = run_order(len(builds_requested), repeats, args.order)
    selected = [clip for clip in manifest["clips"] if args.tier in clip["tiers"]]
    if not selected:
        raise Rejected("no_clips_for_tier", 3)
    if not all(numeric(x) and x >= 0 for x in (args.idle_seconds, args.settle_seconds, args.timeout_slack)):
        raise Rejected("invalid_timing_bounds")
    profiles = ["9b", "4b"] if args.profile == "both" else [args.profile]
    with session_lock():
        out = new_directory(args.out)
        (out / "clips").mkdir(mode=0o700)
        (out / "power").mkdir(mode=0o700)
        build_paths, provenances = {}, {}
        for label, value in zip("AB", builds_requested):
            if value == "auto":
                build_args = argparse.Namespace(runtime=args.runtime, commit="HEAD", out=DEFAULT / "builds" / uuid.uuid4().hex)
                value = build(build_args)
            cli, provenance = build_info(value)
            build_paths[label], provenances[label] = cli, provenance
        sampler = None if args.no_energy else energy.PowerSampler(helper_path=args.energy_helper, interval=args.sample_interval)
        if sampler:
            sampler.start()
        caffeinate = None
        if Path("/usr/bin/caffeinate").exists():
            caffeinate = subprocess.Popen(["/usr/bin/caffeinate", "-i", "-w", str(os.getpid())],
                                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        records, schedule, translated = [], [], []
        try:
            for profile in profiles:
                counts = {"A": 0, "B": 0}
                pre = pause_window(args.idle_seconds) if sampler else None
                for label in order:
                    counts[label] += 1
                    for clip in selected:
                        preflight_processes(provider)
                        run_id = f"{clip['id']}-{label}-{profile}-r{counts[label]}"
                        directory = out / "clips" / run_id
                        directory.mkdir(mode=0o700)
                        cli = build_paths[label]
                        arguments = ["--replay", str(fixture_path(args.fixtures, clip["audio"])),
                                     "--output", str(directory / "session")]
                        if profile == "9b":
                            arguments.append("--high-quality")
                        print(json.dumps({"event": "run_started", "clip": clip["id"], "repeat": counts[label], "profile": profile, "build": label}), flush=True)
                        execution, _ = execute_cli(cli, arguments, directory, clip["audio_seconds"] + args.timeout_slack, provider)
                        log_status = log_collector(execution, directory)
                        if (directory / "session").is_dir() and clip["privacy"] == "private":
                            with exclusive(directory / "session/PRIVATE-CLASSROOM-DATA.txt") as stream:
                                stream.write("Private local classroom evidence. Reports contain only numeric metadata.\n")
                        if execution["residual_owned_processes"] or execution["ownership_uncertain"]:
                            raise Rejected("runtime_ownership_or_cleanup_unconfirmed", 4)
                        if sampler:
                            time.sleep(args.settle_seconds)
                            post = pause_window(args.idle_seconds)
                        else:
                            post = None
                        record = dict(clip=clip, repeat=counts[label], profile=profile, build=label,
                                      directory=str(directory.relative_to(out)), execution=execution,
                                      pre=pre, post=post, log_status=log_status)
                        records.append(record)
                        schedule.append(run_id)
                        pre = post
                if args.tier != "smoke" and not args.skip_authored:
                    cases = read_json(fixture_path(args.fixtures, "rules/translation-authored-80.json"))
                    for label, cli in build_paths.items():
                        outputs, cursor, attempts = [None] * len(cases), 0, 0
                        text_start = time.monotonic()
                        text_pre = pre
                        while cursor < len(cases):
                            preflight_processes(provider)
                            directory = out / f"translate-{label}-{profile}-{attempts:03d}"
                            directory.mkdir(mode=0o700)
                            remaining = "||".join(case["text"] for case in cases[cursor:])
                            content_directory = directory / ".translation-content"
                            content_directory.mkdir(mode=0o700)
                            input_file = content_directory / "input.txt"
                            output_file = content_directory / "translations.jsonl"
                            with exclusive(input_file) as stream:
                                stream.write(remaining)
                            arguments = ["--translate-file", str(input_file), "--translation-output", str(output_file),
                                         "--output", str(directory / "session")]
                            if profile == "9b":
                                arguments.append("--high-quality")
                            execution, _ = execute_cli(cli, arguments, directory, max(600, args.timeout_slack), provider,
                                                       capture_required=False)
                            if execution["residual_owned_processes"] or execution["ownership_uncertain"]:
                                raise Rejected("runtime_ownership_or_cleanup_unconfirmed", 4)
                            parsed = translation_file_outputs(output_file)
                            contiguous = 0
                            while contiguous in parsed and cursor + contiguous < len(cases):
                                outputs[cursor + contiguous] = parsed[contiguous]
                                contiguous += 1
                            cursor += contiguous
                            if cursor < len(cases):
                                # The first unfinished sentence is a measured error;
                                # resume the remaining batch with a fresh CLI output.
                                cursor += 1
                            attempts += 1
                        text_end = time.monotonic()
                        if sampler:
                            time.sleep(args.settle_seconds)
                            post = pause_window(args.idle_seconds)
                            pre = post
                        else:
                            post = None
                        translated.append(dict(profile=profile, build=label, metrics=metrics.translation_t1(cases, outputs),
                                               window=[text_start, text_end], pre=text_pre, post=post))
                        # Only aggregate numeric metrics are persisted, never the translation text.
        finally:
            if sampler:
                sampler.stop()
            if caffeinate and caffeinate.poll() is None:
                caffeinate.terminate()
                try:
                    caffeinate.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    pass
        samples = sampler.samples if sampler else []
        write_jsonl(out / "power/samples.jsonl", samples)
        if sampler:
            write_json(out / "power/sampler.json", {"metadata": sampler.metadata, "errors": sampler.errors})
        for text_run in translated:
            measured = energy.idle_net(samples, text_run["window"], text_run["pre"], text_run["post"],
                                       text_run["window"][1] - text_run["window"][0]) if sampler else None
            text_run["metrics"]["net_j_per_sentence"] = measured["net_j"] / 80 if measured and measured.get("net_j") is not None else None
            text_run["energy"] = measured or {"mode": "disabled", "comparable": False}
        for record in records:
            execution = record["execution"]
            energy_result = energy.idle_net(samples, [execution["spawn_mono"], execution["exit_mono"]],
                                           record["pre"], record["post"], record["clip"]["audio_seconds"]) if sampler else None
            directory = out / record["directory"]
            record["metrics"] = score_clip(record["clip"], Path(args.fixtures), directory, execution, energy_result, samples)
            save_metrics(directory, record["metrics"], execution)
        local = dict(schema="livelingo-run/1", fixtures=str(Path(args.fixtures).resolve()),
                     fixtures_sha256=sha256(Path(args.fixtures) / "fixtures-manifest.json"),
                     records=records, builds=provenances, tier=args.tier, repeats=repeats,
                     order=schedule, translate_authored80=translated, energy_enabled=sampler is not None)
        write_json(out / "run-manifest.json", local)
        report = aggregate(records, manifest, Path(args.fixtures), provenances, args.tier, repeats)
        report["translate_authored80"] = translated
        authored_headlines(report, translated)
        if args.baseline:
            report["comparison"] = compare_reports(read_json(args.baseline), report)
        write_report(out, report)
        print(json.dumps({"event": "scoreboard_complete", **report["headline"]}, sort_keys=True), flush=True)
        return 4 if any(record["metrics"]["unavailable_metrics"] for record in records) else 0


def score(args):
    root = Path(args.run_dir).resolve()
    local = read_json(root / "run-manifest.json")
    if local.get("schema") != "livelingo-run/1":
        raise Rejected("invalid_run_schema", 3)
    fixtures = Path(local["fixtures"])
    if sha256(fixtures / "fixtures-manifest.json") != local["fixtures_sha256"]:
        raise Rejected("fixture_manifest_changed", 3)
    manifest = verify_fixtures(fixtures)
    samples = read_lines(root / "power/samples.jsonl")
    out = new_directory(args.out)
    for record in local["records"]:
        directory = Path(record["directory"])
        if directory.is_absolute() or ".." in directory.parts or not (root / directory).resolve().is_relative_to(root):
            raise Rejected("run_path_escape", 3)
        execution = record["execution"]
        measured = energy.idle_net(samples, [execution["spawn_mono"], execution["exit_mono"]], record["pre"], record["post"],
                                   record["clip"]["audio_seconds"]) if local.get("energy_enabled") else None
        record["metrics"] = score_clip(record["clip"], fixtures, root / directory, execution, measured, samples)
        new_detail = out / directory
        new_detail.mkdir(parents=True, mode=0o700)
        save_metrics(new_detail, record["metrics"], execution)
    report = aggregate(local["records"], manifest, fixtures, local["builds"], local["tier"], local["repeats"])
    report["translate_authored80"] = local.get("translate_authored80", [])
    authored_headlines(report, report["translate_authored80"])
    write_report(out, report)
    print(json.dumps({"event": "scoreboard_rescored", **report["headline"]}, sort_keys=True), flush=True)
    return 4 if any(r["metrics"]["unavailable_metrics"] for r in local["records"]) else 0


def compare_reports(a, b, noise=None):
    same_ruler = a.get("ruler") == b.get("ruler")
    result = {}
    for key in sorted(set(a.get("groups", {})) & set(b.get("groups", {}))):
        ga, gb = a["groups"][key], b["groups"][key]
        floors = (noise or {}).get("profiles", {}).get(ga["profile"], {}) if noise and noise.get("ruler") == a.get("ruler") == b.get("ruler") else {}
        result[key] = compare_groups(ga, gb, same_ruler, floors)
    return result


def compare_groups(a, b, same_ruler=True, noise=None):
    higher_better = {"t80_pass_rate", "glossary_hit_rate_cs50", "runs_verified"}
    guardrails = {"asr_critical_cs50_pooled", "t80_pass_rate", "private_unresolved"}
    comparable_metrics = {"asr_norm_rate_cs50_pooled", "asr_edits_cs50", "asr_critical_cs50_pooled",
                          "asr_negation_errors_cs50", "asr_number_errors_cs50", "asr_code_errors_cs50",
                          "t80_pass_rate", "glossary_hit_rate_cs50", "untranslated_segments_all",
                          "private_other_language", "private_failed", "private_unresolved",
                          "cs50_other_language_false_positive", "zh_final_steady_p50_s", "zh_final_steady_p95_s",
                          "en_commit_steady_p95_s", "net_j_per_audio_min_pooled", "runs_verified"}
    result, tradeoff = {}, False
    backends_known = all("unknown" not in values for group in (a, b) for values in group["preview_backends"].values())
    comparable = same_ruler and a["profile"] == b["profile"] and a["preview_backends"] == b["preview_backends"] and backends_known
    for key in sorted(comparable_metrics):
        pairs = [(x["headline"].get(key), y["headline"].get(key)) for x, y in zip(a["repeat_headlines"], b["repeat_headlines"])]
        if key == "t80_pass_rate":
            pairs = [(a["headline"].get(key), b["headline"].get(key))]
        measured = metrics.paired_ci(pairs)
        allowed = comparable
        if "_j_" in key:
            allowed &= a["headline"].get("energy_comparable", False) and b["headline"].get("energy_comparable", False)
        if "steady_" in key:
            allowed &= a["headline"].get("latency_full_population_quantiles", False) and b["headline"].get("latency_full_population_quantiles", False)
        floor = (noise or {}).get(key, {}).get("threshold")
        delta = measured["mean_delta"]
        direction, conclusion = None, "not_comparable"
        if allowed and delta is not None:
            conclusion = "single_run_reference_only" if measured["n"] == 1 else "uncalibrated"
            if numeric(floor):
                ci = measured["ci95"]
                significant = abs(delta) > floor * (3 if measured["n"] == 1 else 1)
                if measured["n"] >= 3:
                    significant &= ci[0] > 0 or ci[1] < 0
                if significant:
                    direction = "better" if ((delta > 0) == (key in higher_better)) else "worse"
                    conclusion = direction if measured["n"] > 1 else "single_run_direction_only"
                else:
                    conclusion = "within_noise"
        if key in guardrails and direction == "worse":
            tradeoff = True
        result[key] = dict(delta=delta if allowed else None, conclusion=conclusion, direction=direction,
                           paired=measured, noise_floor=floor)
    return dict(metrics=result, outcome="tradeoff" if tradeoff else "per_metric_no_weighted_total")


def authored_headlines(report, text_runs):
    for item in text_runs:
        group = report["groups"].get(item["build"] + "/" + item["profile"])
        if group:
            value = item["metrics"].get("sentence_pass_rate", item["metrics"].get("pass_rate"))
            group["headline"]["t80_pass_rate"] = value
            group["summary"]["t80_pass_rate"] = metrics.summarize_repeats([value])
    for profile in ("9b", "4b"):
        if "A/" + profile in report["groups"] and "B/" + profile in report["groups"]:
            report.setdefault("ab_comparison", {})[profile] = compare_groups(report["groups"]["A/" + profile],
                                                                              report["groups"]["B/" + profile])
    if len(report["groups"]) == 1:
        report["headline"] = next(iter(report["groups"].values()))["headline"]


def compare(args):
    result = compare_reports(read_json(args.a), read_json(args.b), read_json(args.noise) if args.noise else None)
    print(json.dumps(result, sort_keys=True, allow_nan=False))
    return 0


def calibrate(args):
    if args.repeats < 3:
        raise Rejected("calibration_requires_three_repeats")
    if args.builds:
        raise Rejected("calibration_requires_one_build")
    code = run(args)
    report = read_json(Path(args.out) / "scoreboard.json")
    noise = {}
    for group in report["groups"].values():
        floors = {}
        for key, summary in group["summary"].items():
            if summary["n"] < 3:
                continue
            absolute = .1 if "steady_" in key else .05 * abs(summary["mean"]) if "_j_" in key else 3 if key == "asr_edits_cs50" else 0.
            if key == "asr_norm_rate_cs50_pooled":
                ref = group["summary"]["asr_ref_tokens_cs50"]["mean"]
                absolute = 3 / ref if ref else 0.
            floors[key] = dict(summary, absolute_floor=absolute, threshold=max(2 * summary["sd"], absolute))
        noise[group["profile"]] = floors
    write_json(Path(args.out) / "noise-floor.json", {"schema": "livelingo-noise/1", "ruler": report["ruler"],
               "profiles": noise, "status": "measured_aa_noise_floor"})
    return code


def parser():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="operation", required=True)
    prep = sub.add_parser("prepare", help="freeze local sources without playing audio")
    prep.add_argument("--sources", type=Path, default=DEFAULT / "sources.json")
    prep.add_argument("--out", type=Path, default=DEFAULT / "fixtures/ruler-1")
    prep.add_argument("--reuse", type=Path, help="reuse hash-verified audio from an existing fixture manifest")
    build_p = sub.add_parser("build", help="build an isolated CLI and freeze its runtime")
    build_p.add_argument("--commit", default="HEAD")
    build_p.add_argument("--runtime", type=Path, default=DEFAULT / "runtime.json")
    build_p.add_argument("--out", type=Path, default=DEFAULT / "builds" / uuid.uuid4().hex)
    for name in ("run", "calibrate"):
        r = sub.add_parser(name)
        r.add_argument("--fixtures", type=Path, default=DEFAULT / "fixtures/ruler-1")
        r.add_argument("--build", default="auto")
        r.add_argument("--builds")
        r.add_argument("--runtime", type=Path, default=DEFAULT / "runtime.json")
        r.add_argument("--tier", choices=("smoke", "standard", "full"), default="standard")
        r.add_argument("--profile", choices=("9b", "4b", "both"), default="9b")
        r.add_argument("--repeats", type=int, default=3 if name == "calibrate" else 1)
        r.add_argument("--order")
        r.add_argument("--no-energy", action="store_true")
        r.add_argument("--energy-helper", type=Path)
        r.add_argument("--sample-interval", type=float, default=1.)
        r.add_argument("--idle-seconds", type=float, default=120.)
        r.add_argument("--settle-seconds", type=float, default=10.)
        r.add_argument("--timeout-slack", type=float, default=600.)
        r.add_argument("--skip-authored", action="store_true")
        r.add_argument("--baseline", type=Path)
        r.add_argument("--out", type=Path, default=DEFAULT / "runs" / (dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:12]))
    s = sub.add_parser("score", help="rescore saved local evidence; never start a model")
    s.add_argument("--run-dir", type=Path, required=True)
    s.add_argument("--out", type=Path, required=True)
    c = sub.add_parser("compare")
    c.add_argument("a", type=Path)
    c.add_argument("b", type=Path)
    c.add_argument("--noise", type=Path)
    return p


def main():
    args = parser().parse_args()
    try:
        result = {"prepare": prepare, "build": build, "run": run, "score": score,
                  "compare": compare, "calibrate": calibrate}[args.operation](args)
        return result if isinstance(result, int) else 0
    except Rejected as error:
        print(json.dumps({"event": "scoreboard_rejected", "reason": error.reason, "code": error.code}), file=sys.stderr)
        return error.code
    except (ValueError, OSError, KeyError, TypeError):
        # Never expose free-form exception messages containing private input.
        print('{"event":"scoreboard_failed","reason":"invalid_or_unavailable_evidence","code":4}', file=sys.stderr)
        return 4


if __name__ == "__main__":
    sys.exit(main())
