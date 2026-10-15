#!/usr/bin/env python3
"""Build the signed App's model inventory from the final, packaged data.

This reads data only; it never imports a model or starts a bundled runtime.
Run after assembling Models and before sealing/signing the App.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat

if __package__:
    from .model_files import REQUIRED_MODEL_FILES, check_app_models
else:
    from model_files import REQUIRED_MODEL_FILES, check_app_models

FULL_LIMIT = 1 << 20
SAMPLE_BYTES = 64 << 10
MANIFEST_NAME = "model-storage-manifest.json"


def sample_offsets(size):
    return (0, (size - SAMPLE_BYTES) // 2, size - SAMPLE_BYTES)


def file_record(path, relative):
    """Full build-time SHA-256 plus the bounded preclone check's digest."""
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        raise ValueError("model contains a non-regular or hard-linked file")
    digest = hashlib.sha256()
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
    with os.fdopen(os.open(path, flags), "rb") as stream:
        opened = os.fstat(stream.fileno())
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise ValueError("model changed during inventory")
        while block := stream.read(FULL_LIMIT):
            digest.update(block)
        if before.st_size <= FULL_LIMIT:
            sample = digest.hexdigest()
        else:
            sampled = hashlib.sha256()
            for offset in sample_offsets(before.st_size):
                stream.seek(offset)
                block = stream.read(SAMPLE_BYTES)
                if len(block) != SAMPLE_BYTES:
                    raise ValueError("model changed during inventory")
                sampled.update(block)
            sample = sampled.hexdigest()
        after = os.fstat(stream.fileno())
    identity = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
    if identity(before) != identity(after):
        raise ValueError("model changed during inventory")
    return {"path": relative, "size": before.st_size,
            "sha256": digest.hexdigest(), "sampleSHA256": sample}


def safe_component(value):
    return bool(re.fullmatch(r"[A-Za-z0-9._-]{1,180}", value)) and value not in (".", "..")


def build_manifest(models_root, relatives=None):
    models_root = Path(models_root)
    if models_root.is_symlink() or not models_root.is_dir():
        raise ValueError("model root must be a real directory")
    models = []
    for source in sorted(REQUIRED_MODEL_FILES if relatives is None else relatives):
        if not all(safe_component(part) for part in source.split("/")):
            raise ValueError("unsafe model source")
        directory = models_root
        for part in source.split("/"):
            directory = directory / part
            if directory.is_symlink() or not directory.is_dir():
                raise ValueError("model source must contain only real directories")
        files = []
        for parent, dirs, names in os.walk(directory, followlinks=False):
            for name in sorted(dirs + names):
                item = Path(parent) / name
                if (not safe_component(name) or item.is_symlink()
                        or item.relative_to(directory).parts[0] == "preclone-state.json"):
                    raise ValueError("unsafe model member")
            for name in sorted(names):
                path = Path(parent) / name
                files.append(file_record(path, path.relative_to(directory).as_posix()))
        files.sort(key=lambda row: row["path"])
        if not files:
            raise ValueError("empty model")
        model = {"name": source.rsplit("/", 1)[-1], "sourceRelativePath": source, "files": files}
        canonical = json.dumps(model, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()
        model["version"] = "sha256-" + hashlib.sha256(canonical).hexdigest()
        models.append(model)
    if len({model["name"] for model in models}) != len(models):
        raise ValueError("model names collide")
    return {"schemaVersion": 1, "sampleAlgorithm": "first-middle-last-64KiB-v1",
            "fullHashMaxBytes": FULL_LIMIT, "models": models}


def write_app_manifest(app):
    app = Path(app)
    problems = check_app_models(app)
    if problems:
        raise ValueError("incomplete packaged models: " + "; ".join(problems))
    resources = app / "Contents/Resources"
    destination = resources / MANIFEST_NAME
    value = build_manifest(resources / "Models")
    # A candidate is freshly assembled; an old inventory must never be reused.
    with destination.open("x", encoding="utf-8") as output:
        json.dump(value, output, sort_keys=True, indent=2)
        output.write("\n")
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    args = parser.parse_args()
    write_app_manifest(args.app)
    print(json.dumps({"modelStorageManifest": "generated", "models": len(REQUIRED_MODEL_FILES)}))


if __name__ == "__main__":
    main()
