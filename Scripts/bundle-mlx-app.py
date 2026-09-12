#!/usr/bin/env python3
"""Assemble the self-contained, unsigned LiveLingo candidate for offline drag-install.

Layout written into the candidate:

  LiveLingo.app/Contents/Resources/LanguageRuntime   MLX translation runtime (--runtime)
  LiveLingo.app/Contents/Resources/Models/...        two translation + two ASR models
  LiveLingo.app/Contents/Resources/ASRRuntime/python portable CPython for ASR (--asr-python)
  LiveLingo.app/Contents/Resources/ASRRuntime/qwen_asr_service.py
  LiveLingo.app/Contents/Resources/{LICENSE,THIRD_PARTY_NOTICES.md}
  LiveLingo.app/Contents/Resources/LanguageRuntime/Licenses, Models/*/LICENSE

Every input is read-only. Copies prefer APFS clones and every destination must be
new, so an existing candidate is never overwritten. There is deliberately no
silent fallback to an environment installed in $HOME: --runtime, --models,
--asr-python and --asr-models are all required, and a missing runtime aborts the
run instead of reusing an interpreter living outside the app.

This script only assembles. It never signs, never packages a DMG and never
installs anything. Sign with Scripts/sign-offline-app.py, then package with
Scripts/build-offline-dmg.sh. macOS 14 runtime acceptance stays pending until it
is tested on a real macOS 14 machine.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess

REPO_ROOT = Path(__file__).resolve().parent.parent

# In-app relative path -> Packaging/ModelNotices file holding the official license.
LANGUAGE_MODELS = (
    ("mlx-community/Qwen3.5-4B-MLX-8bit", "Qwen3.5-4B-LICENSE"),
    ("lmstudio-community/Qwen3.5-9B-MLX-4bit", "Qwen3.5-9B-LICENSE"),
)
# In-app relative path -> (license notice, model card notice).
ASR_MODELS = (
    ("mlx-community/parakeet-tdt-0.6b-v2", "CC-BY-4.0.txt", "Parakeet-tdt-0.6b-v2-original-README.md"),
    ("mlx-community/Qwen3-ASR-1.7B-4bit", "Qwen3-ASR-1.7B-LICENSE", "Qwen3-ASR-1.7B-4bit-README.md"),
)
RUNTIME_MODULES = ("worker.py", "engine.py", "schemas.py", "checks.py")

# Test artifacts that must never reach the candidate. "virtual-player" alone does
# not match "virtual-audio-player.swift", so all spellings are listed.
FORBIDDEN_NAME_PARTS = (
    "livelingo-cli",
    "livelingotests",
    "virtual-audio-player",
    "virtual-player",
    "virtualplayer",
    "test_qwen_asr_service",
    "test_qwen_streaming",
)
FORBIDDEN_SUFFIXES = (".xctest",)
FORBIDDEN_EXTRA_SUFFIXES = (".command",)  # historical installer scripts stay unpackaged

# A symlink may only stay inside the candidate or point at a system library.
SYSTEM_SYMLINK_PREFIXES = ("/System/", "/usr/lib/", "/usr/libexec/", "/Library/Apple/")


def fail(message):
    raise SystemExit("bundle-mlx-app: " + message)


def run(command):
    subprocess.run([str(part) for part in command], check=True)


def volume_device(path):
    result = subprocess.run(["/bin/df", "-P", str(path)], capture_output=True, text=True)
    lines = result.stdout.strip().splitlines()
    return lines[1].split()[0] if len(lines) > 1 else ""


def is_apfs(path):
    device = volume_device(path)
    if not device:
        return False
    result = subprocess.run(["/usr/sbin/diskutil", "info", "-plist", device], capture_output=True)
    try:
        return str(plistlib.loads(result.stdout).get("FilesystemType", "")).lower() == "apfs"
    except Exception:
        return False


def clone_tree(source, destination):
    """Copy a read-only source directory, preferring an APFS clone. Never overwrites."""
    source = Path(source)
    destination = Path(destination)
    if destination.exists() or destination.is_symlink():
        fail("refusing to overwrite an existing destination: %s" % destination)
    if not source.is_dir() or source.is_symlink():
        fail("source directory is missing or is a symlink: %s" % source)
    destination.parent.mkdir(parents=True, exist_ok=True)
    same_device = os.stat(source).st_dev == os.stat(destination.parent).st_dev
    if same_device and is_apfs(destination.parent):
        run(["/bin/cp", "-cR", source, destination])
    else:
        run(["/usr/bin/ditto", "--rsrc", "--extattr", source, destination])
    if not destination.is_dir() or destination.is_symlink():
        fail("copy did not produce a real directory: %s" % destination)


def install_file(source, target, mode=None, replace=False):
    """Copy one regular file into the new candidate. Symlink sources are refused."""
    source = Path(source)
    target = Path(target)
    if source.is_symlink() or not source.is_file():
        fail("required file is missing or not a regular file: %s" % source)
    if (target.exists() or target.is_symlink()) and not replace:
        return False
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.is_symlink():
        target.unlink()
    shutil.copy2(source, target)
    if mode is not None:
        os.chmod(target, mode)
    return True


def resolve_model_source(root, relative):
    root = Path(root)
    relative_path = Path(relative)
    candidates = (root / relative_path, root / relative_path.name)
    for candidate in candidates:
        if candidate.is_dir() and not candidate.is_symlink():
            return candidate
    fail("missing model directory, probed: %s" % ", ".join(str(candidate) for candidate in candidates))


def scan_forbidden(root, label):
    hits = []
    for directory, directories, files in os.walk(root, followlinks=False):
        for name in list(directories) + list(files):
            lowered = name.lower()
            if lowered.endswith(FORBIDDEN_SUFFIXES) or lowered.endswith(FORBIDDEN_EXTRA_SUFFIXES) \
                    or any(part in lowered for part in FORBIDDEN_NAME_PARTS):
                hits.append(str((Path(directory) / name).relative_to(root)))
    if hits:
        fail("%s contains forbidden test/installer artifacts: %s" % (label, ", ".join(sorted(hits))))


def check_symlinks(app_root):
    """No symlink may imply a dependency on content outside the app bundle."""
    app_root = Path(app_root)
    root_text = os.path.realpath(str(app_root))
    problems = []
    for directory, directories, files in os.walk(app_root, followlinks=False):
        for name in list(directories) + list(files):
            path = Path(directory) / name
            if not path.is_symlink():
                continue
            target = os.readlink(str(path))
            resolved = os.path.realpath(target if os.path.isabs(target)
                                        else os.path.join(directory, target))
            if resolved == root_text or resolved.startswith(root_text + os.sep):
                continue
            if resolved.startswith(SYSTEM_SYMLINK_PREFIXES):
                continue
            problems.append("%s -> %s" % (path.relative_to(app_root), target))
    if problems:
        fail("symlink(s) would depend on content outside the app bundle:\n  " + "\n  ".join(sorted(problems)))


def check_required_paths(app_root):
    required = [
        "Contents/Info.plist",
        "Contents/Resources/LanguageRuntime/runtime-manifest.json",
        "Contents/Resources/LanguageRuntime/worker.py",
        "Contents/Resources/ASRRuntime/python/bin/python3",
        "Contents/Resources/ASRRuntime/qwen_asr_service.py",
        "Contents/Resources/THIRD_PARTY_NOTICES.md",
        "Contents/Resources/LICENSE",
        "Contents/Resources/Models/notice-sources.json",
        "Contents/Resources/Models/asr-notice-sources.json",
    ]
    for relative in [relative for relative, _ in LANGUAGE_MODELS] + [relative for relative, _, _ in ASR_MODELS]:
        required.append("Contents/Resources/Models/%s/config.json" % relative)
    missing = [relative for relative in required if not (app_root / relative).exists()]
    if missing:
        fail("assembled candidate is incomplete: " + ", ".join(missing))


def validate_asr_python(root):
    root = Path(root)
    if not root.is_dir() or root.is_symlink():
        fail("--asr-python must be a real directory containing a complete portable CPython: %s" % root)
    if (root / "pyvenv.cfg").is_file():
        fail("--asr-python looks like a venv; a venv falls back to a base interpreter in $HOME: %s" % root)
    interpreter = root / "bin/python3"
    if not interpreter.exists():
        fail("--asr-python has no bin/python3: %s" % root)
    if not list(root.glob("lib/python3.*")):
        fail("--asr-python has no lib/python3.* standard library: %s" % root)


def install_python_licenses(source_python, destination):
    """Best-effort: collect the portable CPython's own license files at shallow depth."""
    copies = 0
    for path in sorted(Path(source_python).rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        relative = path.relative_to(source_python)
        if len(relative.parts) > 3 or "site-packages" in relative.parts:
            continue
        if any(word in path.name.lower() for word in ("license", "licence", "notice", "copying")):
            flat_name = str(relative).replace("/", "__")
            install_file(path, destination / flat_name, replace=True)
            copies += 1
    return copies


def main():
    parser = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Example:\n"
               "  Scripts/bundle-mlx-app.py --app <Release>/LiveLingo.app --runtime <MLXRuntime> \\\n"
               "      --models /absolute/path/to/models --asr-models /absolute/path/to/models \\\n"
               "      --asr-python /opt/livelingo-asr-python --output work/OfflineCandidate/LiveLingo.app",
    )
    parser.add_argument("--app", type=Path, required=True,
                        help="fresh Release LiveLingo.app, read-only (must not contain the runtime yet)")
    parser.add_argument("--runtime", type=Path, required=True,
                        help="LanguageRuntime assembled by Scripts/prepare-mlx-runtime.py, read-only")
    parser.add_argument("--models", type=Path, required=True,
                        help="root holding the two translation models (mlx-community/Qwen3.5-4B-MLX-8bit, "
                             "lmstudio-community/Qwen3.5-9B-MLX-4bit)")
    parser.add_argument("--asr-models", type=Path, required=True,
                        help="root holding the two ASR models (mlx-community/parakeet-tdt-0.6b-v2, "
                             "mlx-community/Qwen3-ASR-1.7B-4bit); no $HOME fallback")
    parser.add_argument("--asr-python", type=Path, required=True,
                        help="portable complete CPython tree for the ASR service; a venv is refused and a "
                             "missing runtime never falls back to $HOME")
    parser.add_argument("--asr-service", type=Path, default=REPO_ROOT / "Scripts/qwen_asr_service.py",
                        help="ASR service script to embed (default: Scripts/qwen_asr_service.py)")
    parser.add_argument("--output", type=Path, required=True,
                        help="new candidate path; an existing path is never overwritten")
    parser.add_argument("--bundle-id", help="use a separate identifier for isolated host/VM candidates")
    args = parser.parse_args()

    if args.output.exists() or args.output.is_symlink():
        fail("refusing to overwrite an existing candidate: %s" % args.output)
    if not (args.app / "Contents/Info.plist").is_file():
        fail("--app is not a macOS application bundle: %s" % args.app)
    if not (args.runtime / "runtime-manifest.json").is_file():
        fail("--runtime is missing runtime-manifest.json: %s" % args.runtime)
    validate_asr_python(args.asr_python)
    if not args.asr_service.is_file() or args.asr_service.is_symlink():
        fail("--asr-service is missing or is a symlink: %s" % args.asr_service)
    language_sources = [(relative, resolve_model_source(args.models, relative), notice)
                        for relative, notice in LANGUAGE_MODELS]
    asr_sources = [(relative, resolve_model_source(args.asr_models, relative), license_notice, card_notice)
                   for relative, license_notice, card_notice in ASR_MODELS]

    # The Release build must not ship test artifacts, and the source app must not
    # already carry a runtime, because destinations are never overwritten.
    scan_forbidden(args.app, "source app")
    if (args.app / "Contents/Resources/LanguageRuntime").exists():
        fail("source app already embeds LanguageRuntime; use a fresh Release build")
    if (args.app / "Contents/Resources/ASRRuntime").exists():
        fail("source app already embeds ASRRuntime; use a fresh Release build")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    clone_tree(args.app, args.output)
    resources = args.output / "Contents/Resources"

    clone_tree(args.runtime, resources / "LanguageRuntime")
    for name in RUNTIME_MODULES:
        install_file(REPO_ROOT / "Scripts/mlx_runtime" / name, resources / "LanguageRuntime" / name,
                     replace=True)

    clone_tree(args.asr_python, resources / "ASRRuntime/python")
    install_file(args.asr_service, resources / "ASRRuntime/qwen_asr_service.py", mode=0o755, replace=True)
    install_file(REPO_ROOT / "Packaging/ASRRuntime.lock.json", resources / "ASRRuntime/ASRRuntime.lock.json")
    python_licenses = install_python_licenses(args.asr_python, resources / "ASRRuntime/Licenses/CPython")

    for relative, source, notice in language_sources:
        destination = resources / "Models" / relative
        clone_tree(source, destination)
        install_file(REPO_ROOT / "Packaging/ModelNotices" / notice, destination / "LICENSE", replace=True)
        card = REPO_ROOT / "Packaging/ModelNotices/Qwen3.5-9B-MLX-4bit-README.md"
        if not (destination / "README.md").exists():
            install_file(card, destination / "README.md", replace=False)
    for relative, source, license_notice, card_notice in asr_sources:
        destination = resources / "Models" / relative
        clone_tree(source, destination)
        install_file(REPO_ROOT / "Packaging/ModelNotices" / license_notice, destination / "LICENSE",
                     replace=True)
        if not (destination / "README.md").exists():
            install_file(REPO_ROOT / "Packaging/ModelNotices" / card_notice, destination / "README.md",
                         replace=False)

    install_file(REPO_ROOT / "Packaging/ModelNotices/sources.json",
                 resources / "Models/notice-sources.json", replace=True)
    install_file(REPO_ROOT / "Packaging/ModelNotices/asr-sources.json",
                 resources / "Models/asr-notice-sources.json", replace=True)
    install_file(REPO_ROOT / "Packaging/THIRD_PARTY_NOTICES.md",
                 resources / "THIRD_PARTY_NOTICES.md", replace=True)
    install_file(REPO_ROOT / "LICENSE", resources / "LICENSE", replace=True)

    manifest_path = resources / "LanguageRuntime/runtime-manifest.json"
    manifest = json.loads(manifest_path.read_text())
    for component in manifest["components"]:
        supplement = REPO_ROOT / "Packaging/MLXLicenses" / \
            ("%s-%s-LICENSE" % (component["name"].lower(), component["version"]))
        if supplement.is_file():
            target = resources / "LanguageRuntime/Licenses" / component["name"].lower() / "LICENSE"
            install_file(supplement, target, replace=True)
            component["licenses"] = ["LICENSE"] + component["licenses"]
    manifest["missingLicenseFiles"] = [component["name"] for component in manifest["components"]
                                       if not component["licenses"]]
    manifest["workerHashes"] = {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                                for path in (resources / "LanguageRuntime").glob("*.py")}
    audit_path = REPO_ROOT / "Packaging/MLXLicenses/AUDIT.json"
    manifest["nativeTransitiveNoticeAudit"] = json.loads(audit_path.read_text()) if audit_path.is_file() \
        else {"status": "pending"}
    for source in (REPO_ROOT / "Packaging/MLXLicenses").iterdir():
        target = resources / "LanguageRuntime/Licenses" / source.name
        if source.is_dir() and not target.is_symlink():
            shutil.copytree(source, target, dirs_exist_ok=True)
        elif source.name in ("AUDIT.json", "README.md"):
            install_file(source, target, replace=True)
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2))

    asr_manifest = {
        "service": "qwen_asr_service.py",
        "serviceSHA256": hashlib.sha256((resources / "ASRRuntime/qwen_asr_service.py").read_bytes()).hexdigest(),
        "python": "python/bin/python3",
        "pythonTree": "python",
        "modelsRoot": "../Models",
        "asrModels": {"parakeet": "mlx-community/parakeet-tdt-0.6b-v2",
                      "qwen3-asr-1.7b": "mlx-community/Qwen3-ASR-1.7B-4bit"},
        "note": "Paths are relative to Contents/Resources/ASRRuntime. Set LIVELINGO_ASR_MODELS to "
                "Contents/Resources/Models; this runtime must never fall back to $HOME.",
    }
    (resources / "ASRRuntime/asr-bundle-manifest.json").write_text(
        json.dumps(asr_manifest, ensure_ascii=False, indent=2))

    if args.bundle_id:
        info_path = args.output / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["CFBundleIdentifier"] = args.bundle_id
        info_path.write_bytes(plistlib.dumps(info))

    check_required_paths(args.output)
    scan_forbidden(args.output, "assembled candidate")
    check_symlinks(args.output)

    print(json.dumps({
        "candidate": str(args.output.resolve()),
        "signed": False,
        "bundleId": args.bundle_id or "from source Info.plist",
        "languageModels": [relative for relative, _ in LANGUAGE_MODELS],
        "asrModels": [relative for relative, _, _ in ASR_MODELS],
        "asrPythonLicenses": python_licenses,
        "missingLicenseFiles": manifest["missingLicenseFiles"],
        "macOS14RuntimeTest": "pending",
        "nextStep": "Scripts/sign-offline-app.py --app %s" % args.output,
        "boundary": "No signing, no DMG, no install, no $HOME fallback.",
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
