#!/usr/bin/env python3
"""Copy unsigned distribution inputs or check a package without changing it.

Recovery originals, run records and diagnostics stay in the source tree. Only a
new copy may receive a public runtime manifest. Signed/stapled inputs use check,
never in-place cleanup. This is a packaging boundary, not a claim that arbitrary
binaries or renamed classroom text can be identified by a content scanner.
"""
import argparse
import copy
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys


class PrivacyError(ValueError):
    """A fixed reason code; never include file contents or local paths."""


EXCLUDED_NAMES = frozenset({
    ".git", ".hg", ".svn", ".cache", ".ds_store", ".cli-runtime", ".translation-content",
    "__pycache__", "test", "tests", "migration-recovery.json", "run.json", "release-state.json",
    "tool-paths.txt", "receipt.json", "reviewdiagnostics", "transcriptiondiagnostics",
    "checkpoints", "durable-transcription", "transcription-issues.jsonl",
})
SYSTEM_LINKS = ("/System/", "/usr/lib/", "/usr/libexec/", "/Library/Apple/")
PUBLIC_MANIFEST_KEYS = (
    "components", "missingLicenseFiles", "chempyScope", "python", "workerHashes",
    "nativeTransitiveNoticeAudit",
)
CONTENT_KEYS = frozenset({
    "rawtext", "originaltext", "translatedtext", "sourcetext", "transcript",
    "transcriptsegments", "learningnotes", "reviewinput", "reviewoutput",
    "preservedsourcedirectory", "sessiondirectory",
})
CONTENT_NAMES = frozenset({
    "session.json", "snapshot.json", "work.jsonl", "notes.md", "transcript.txt",
    "transcript.json", "transcript.md", "recording.wav", "learning-review-queue.json",
})
CONTENT_SUFFIXES = (".srt", ".vtt", ".wav", ".m4a", ".mp3", ".aiff", ".flac", ".jsonl")
JSON_LIMIT = 64 * 1024 * 1024
APP_RESOURCES = frozenset({
    "LanguageRuntime", "ASRRuntime", "Models", "LICENSE", "THIRD_PARTY_NOTICES.md",
    "Assets.car", "AppIcon.icns", "AppIcon.icon", "InfoPlist.strings",
})
# URL provenance is allowed. Local absolute paths (including file URLs and
# Windows paths) in structured metadata are not distribution provenance.
URL = re.compile(r"https?://[^\s\"<>]+")
LOCAL_PATH = re.compile(r"(?<![\w:/.])/(?:[^/\s\"<>]+/)[^\s\"<>]*|file://|~[/\\]|[A-Za-z]:\\")


def excluded(name):
    name = name.lower()
    return (name in EXCLUDED_NAMES or name.startswith((".migration-source", "._"))
            or name.startswith(("classroom-metrics", "classroom_metrics"))
            or name.endswith((".log", ".pyc", ".pyo", ".bak", ".tmp")))


def validate_metadata(value, field=None):
    if isinstance(value, dict):
        for key, item in value.items():
            if re.sub(r"[_-]", "", key.lower()) in CONTENT_KEYS:
                raise PrivacyError("classroom-content-metadata")
            validate_metadata(key)
            validate_metadata(item, key)
    elif isinstance(value, list):
        for item in value:
            validate_metadata(item)
    elif isinstance(value, str):
        if field in ("url", "download_url", "sourceURL", "sourceUrl") and re.fullmatch(
                r"//[A-Za-z0-9.-]+\.[A-Za-z0-9.-]+(?::[0-9]+)?(?:/[^\s]*)?", value):
            value = "https:" + value  # Validate an upstream network-path URL; do not rewrite it.
        if value.startswith("/") or LOCAL_PATH.search(URL.sub("", value)):
            raise PrivacyError("local-path-metadata")


def distribution_manifest(manifest):
    if not isinstance(manifest, dict) or not isinstance(manifest.get("components"), list):
        raise PrivacyError("invalid-runtime-manifest")
    public = {key: copy.deepcopy(manifest[key]) for key in PUBLIC_MANIFEST_KEYS if key in manifest}
    public["python"] = "python"
    validate_metadata(public)
    return public


def read_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (UnicodeError, ValueError):
        raise PrivacyError("invalid-package-json") from None


def validate_json_metadata(value, filename):
    if filename in ("vocab.json", "added_tokens.json") and isinstance(value, dict):
        if all(isinstance(token_id, int) for token_id in value.values()):
            return  # A token-to-ID vocabulary; token spellings are required data.
    if filename in ("tokenizer.json", "tokenizer_config.json", "special_tokens_map.json") and isinstance(value, dict):
        # Vocabulary spellings can themselves be paths or words such as
        # 'transcript'. They are required model data, not session metadata.
        # Still inspect all fields outside the documented vocabulary locations.
        value = dict(value)
        model = value.get("model")
        if isinstance(model, dict):
            model = dict(model)
            model.pop("vocab", None)
            model.pop("merges", None)
            value["model"] = model
        added = value.get("added_tokens")
        if isinstance(added, list):
            value["added_tokens"] = [{k: v for k, v in token.items() if k != "content"}
                                     if isinstance(token, dict) else token for token in added]
        decoder = value.get("added_tokens_decoder")
        if isinstance(decoder, dict):
            value["added_tokens_decoder"] = {
                key: {k: v for k, v in token.items() if k != "content"}
                if isinstance(token, dict) else token for key, token in decoder.items()
            }
        for key in ("bos_token", "eos_token", "unk_token", "pad_token", "sep_token", "cls_token",
                    "mask_token", "additional_special_tokens"):
            value.pop(key, None)
    validate_metadata(value)


def validate_link(path, root, allow_applications=False):
    target = os.readlink(path)
    if allow_applications and path == root / "Applications" and target == "/Applications":
        return
    if os.path.isabs(target) and os.path.realpath(target).startswith(SYSTEM_LINKS):
        return
    # Absolute source-internal links would retain the source location after copy.
    if os.path.isabs(target):
        raise PrivacyError("external-or-absolute-symlink")
    try:
        resolved = path.resolve(strict=True)
        relative = resolved.relative_to(root.resolve())
    except (OSError, ValueError, RuntimeError):
        raise PrivacyError("external-broken-or-cyclic-symlink") from None
    if any(excluded(part) for part in relative.parts):
        raise PrivacyError("symlink-to-private-record")


def inspect_tree(root, *, omit_private=False, public_copy=False, layout="tree"):
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise PrivacyError("package-root-not-real-directory")
    if layout in ("app-only", "dmg"):
        expected = {"LiveLingo.app"} if layout == "app-only" else {"LiveLingo.app", "Applications", "使用说明.txt"}
        if {p.name for p in root.iterdir()} != expected:
            raise PrivacyError("unexpected-package-top-level")
        if not (root / "LiveLingo.app").is_dir() or (root / "LiveLingo.app").is_symlink():
            raise PrivacyError("package-app-not-real-directory")
        if layout == "dmg" and (not (root / "Applications").is_symlink()
                                or os.readlink(root / "Applications") != "/Applications"
                                or not (root / "使用说明.txt").is_file()
                                or (root / "使用说明.txt").is_symlink()):
            raise PrivacyError("invalid-dmg-install-entries")
    counts = {"files": 0, "excluded": 0, "manifests": 0}

    def walk(directory):
        for path in sorted(directory.iterdir()):
            if excluded(path.name):
                if not omit_private:
                    raise PrivacyError("private-or-unrelated-package-entry")
                counts["excluded"] += 1
                continue  # Never descend into recovery copies or read their contents.
            if directory.name == "Resources" and directory.parent.name == "Contents":
                if path.name not in APP_RESOURCES and not path.name.endswith(".lproj"):
                    raise PrivacyError("unexpected-app-resource")
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                if path.suffix.lower() == ".json":
                    raise PrivacyError("structured-metadata-symlink")
                validate_link(path, root, layout == "dmg")
            elif stat.S_ISDIR(mode):
                walk(path)
            elif stat.S_ISREG(mode):
                counts["files"] += 1
                if path.name.lower() in CONTENT_NAMES or path.name.lower().endswith(CONTENT_SUFFIXES):
                    raise PrivacyError("classroom-content-file")
                if path.suffix.lower() == ".json":
                    if path.stat().st_size > JSON_LIMIT:
                        raise PrivacyError("unreviewed-large-json")
                    value = read_json(path)
                    if path.name == "runtime-manifest.json":
                        public = distribution_manifest(value)
                        if not public_copy and value != public:
                            raise PrivacyError("nonpublic-runtime-manifest")
                        counts["manifests"] += 1
                    else:
                        validate_json_metadata(value, path.name)
            else:
                raise PrivacyError("special-package-entry")

    walk(root)
    return counts


def copy_distribution_tree(source, destination, *, clone_files=False):
    """Only write a new disjoint tree; inputs and signed packages stay untouched."""
    source, destination = Path(source), Path(destination)
    if destination.exists() or destination.is_symlink():
        raise PrivacyError("destination-already-exists")
    source_real, destination_real = source.resolve(), destination.resolve()
    if source_real == destination_real or source_real in destination_real.parents or destination_real in source_real.parents:
        raise PrivacyError("overlapping-package-trees")
    # Reject destination symlink ancestors before creating anything.
    if any(p.is_symlink() for p in [destination.parent, *destination.parent.parents]):
        raise PrivacyError("symlink-destination-parent")
    counts = inspect_tree(source, omit_private=True, public_copy=True)

    def copy_file(src, dst):
        src, dst = Path(src), Path(dst)
        if src.name == "runtime-manifest.json":
            dst.write_text(json.dumps(distribution_manifest(read_json(src)), ensure_ascii=False, indent=2) + "\n")
            shutil.copystat(src, dst)
        elif clone_files and src.stat().st_size >= 1024 * 1024:
            result = subprocess.run(["/bin/cp", "-c", str(src), str(dst)], capture_output=True)
            if result.returncode:
                raise PrivacyError("package-clone-failed")
        else:
            shutil.copy2(src, dst)
        return str(dst)

    shutil.copytree(source, destination, symlinks=True, copy_function=copy_file,
                    ignore=lambda directory, names: [name for name in names if excluded(name)])
    inspect_tree(destination)
    return counts


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    check = sub.add_parser("check", help="read-only; rejects signed-package residues without editing them")
    check.add_argument("--root", type=Path, required=True)
    check.add_argument("--layout", choices=("tree", "app-only", "dmg"), default="tree")
    stage = sub.add_parser("copy", help="create a new unsigned distribution copy; preserve all sources")
    stage.add_argument("--source", type=Path, required=True)
    stage.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        counts = (inspect_tree(args.root, layout=args.layout) if args.command == "check"
                  else copy_distribution_tree(args.source, args.output))
    except PrivacyError as error:
        print("privacy-package: " + error.args[0] + "; rebuild an unsigned copy", file=sys.stderr)
        return 1
    except (OSError, shutil.Error):
        # Do not echo arbitrary source names, paths, contents or exception text.
        print("privacy-package: rejected; inspect the local input and rebuild an unsigned copy", file=sys.stderr)
        return 1
    print(json.dumps({"privacyPackage": "passed", "operation": args.command, **counts}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
