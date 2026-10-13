#!/usr/bin/env python3
"""Compile the real App sources into an isolated, ad-hoc signed sandbox App."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import pwd
import re
import subprocess
import sys
import uuid

REPO = Path(__file__).resolve().parent.parent
PREFIX = "com.jianhongli.LiveLingo.sandboxprobe."
USER_HOME = Path(pwd.getpwuid(os.getuid()).pw_dir)
CASES = (
    "open_existing", "missing_without_create", "create_private_components",
    "checkpoint_python_existing", "checkpoint_python_create", "checkpoint_python_missing_read", "checkpoint_python_symlink",
    "reject_leaf_symlink", "reject_ancestor_symlink", "reject_missing_below_symlink",
    "reject_non_directory", "atomic_write_read", "atomic_replace_permissions",
    "append_read", "reject_file_symlink", "assert_path_identity", "move_remove_directory",
    "recovery_scan", "temporary_session_cleanup", "pending_cleanup_retry",
    "recording_recovery_index", "recording_recovery_bookmark",
    "session_store_roundtrip", "temporary_session_copy", "temporary_session_promote",
    "review_queue_journal", "export_subfolder", "model_preclone_verify",
)
EXPECTED = {"sandbox_identity", "container_parent_tracking"} | {f"{root}.{case}" for root in ("tmp", "support") for case in CASES}


def validate_result(value, returncode, bundle_id):
    """Fail closed on missing, duplicate, malformed or unsigned-host results."""
    if not isinstance(value, dict) or type(value.get("version")) is not int or value["version"] != 1 \
            or value.get("bundle_id") != bundle_id:
        raise ValueError("invalid probe identity or schema")
    checks = value.get("checks")
    if not isinstance(checks, list) or any(
        not isinstance(row, dict) or not isinstance(row.get("name"), str)
        or type(row.get("passed")) is not bool for row in checks
    ):
        raise ValueError("invalid probe checks")
    names = [row["name"] for row in checks]
    if len(names) != len(set(names)) or set(names) != EXPECTED:
        raise ValueError("incomplete or duplicate probe checks")
    passed = all(row["passed"] for row in checks)
    if type(value.get("passed")) is not bool or value["passed"] != passed:
        raise ValueError("inconsistent probe summary")
    if returncode != (0 if passed else 1):
        raise ValueError("probe exit code does not match its results")
    if not next(row["passed"] for row in checks if row["name"] == "sandbox_identity"):
        raise ValueError("probe did not establish a real isolated sandbox")
    return passed


APP_ENTRY = "LiveLingoApp.swift"


def storage_sources(output):
    """Compile every App source verbatim, without mocks or rewritten methods.

    The probe supplies the process entry point, so exactly one line of
    LiveLingoApp.swift changes: its standalone `@main` attribute becomes an
    empty line. Any other entry-point shape fails closed before output.
    """
    app_sources = sorted((REPO / "LiveLingo/Sources").glob("*.swift"))
    entry_source = REPO / "LiveLingo/Sources" / APP_ENTRY
    text = entry_source.read_text() if entry_source in app_sources else ""
    lines = text.split("\n")
    if text.count("@main") != 1 or lines.count("@main") != 1:
        raise ValueError("App entry point changed; refusing to guess the probe entry")
    entry = output / APP_ENTRY
    entry.write_text("\n".join("" if line == "@main" else line for line in lines))
    probe = REPO / "Scripts/sandbox-probe.swift"
    paths = [path for path in app_sources if path != entry_source] + [entry, probe]
    return paths, {
        "whole_sources": {str(path.relative_to(REPO)): hashlib.sha256(path.read_bytes()).hexdigest()
                          for path in app_sources + [probe]},
        "entry_source_sha256": hashlib.sha256(entry.read_bytes()).hexdigest(),
        "checkpoint_sequence_source_sha256": hashlib.sha256((REPO / "Scripts/mlx_runtime/checkpoints.py").read_bytes()).hexdigest(),
        "removed_entry_attribute": f"LiveLingo/Sources/{APP_ENTRY}: @main",
    }


def run(command, timeout=120):
    # swiftc/codesign/probe output has no process-environment diagnostic dump.
    return subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          text=True, timeout=timeout, check=False)


def archive_container(bundle_id, output):
    if not re.fullmatch(re.escape(PREFIX) + r"[0-9a-f]{32}", bundle_id):
        raise ValueError("refusing non-probe container")
    parent = USER_HOME / "Library/Containers"
    container = parent / bundle_id
    if not container.exists():
        return "absent"
    if container.is_symlink() or container.resolve() != container or not container.is_dir():
        raise ValueError("unexpected probe container path")
    if container.stat().st_uid != os.getuid() or container.stat().st_dev != output.stat().st_dev:
        raise ValueError("probe container owner or volume mismatch")
    destination = output / "superseded" / bundle_id
    destination.parent.mkdir(mode=0o700, exist_ok=True)
    if destination.parent.is_symlink() or destination.parent.resolve() != destination.parent:
        raise ValueError("unexpected probe container archive path")
    if destination.exists() or destination.is_symlink():
        raise ValueError("probe container archive already exists")
    container.rename(destination)
    if container.exists() or not destination.is_dir():
        raise ValueError("probe container archive verification failed")
    return str(destination.relative_to(output))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--name", required=True)
    args = parser.parse_args()
    root = args.output_root
    if not root.is_absolute() or root.resolve() != root or root in (Path("/"), USER_HOME) \
            or root.is_relative_to(REPO) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", args.name):
        parser.error("supply a dedicated absolute output root outside the checkout and a simple name")
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    output = root / args.name
    output.mkdir(mode=0o700)  # Never overwrite previous evidence.
    bundle_id = PREFIX + uuid.uuid4().hex
    app = output / "SandboxProbe.app"
    executable = app / "Contents/MacOS/SandboxProbe"
    executable.parent.mkdir(parents=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": bundle_id, "CFBundleExecutable": "SandboxProbe",
        "CFBundleName": "Storage Sandbox Probe", "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1", "LSMinimumSystemVersion": "14.0", "LSUIElement": True,
    }))
    formal = plistlib.loads((REPO / "LiveLingo/Resources/LiveLingo.entitlements").read_bytes())
    entitlements = {key: value for key, value in formal.items()
                    if key == "com.apple.security.app-sandbox" or key.startswith("com.apple.security.files.")}
    if entitlements.get("com.apple.security.app-sandbox") is not True:
        raise ValueError("production sandbox entitlement is missing")
    entitlement_path = output / "probe.entitlements"
    entitlement_path.write_bytes(plistlib.dumps(entitlements))
    sources, manifest = storage_sources(output)
    report = {"version": 1, "bundle_id": bundle_id, "source_manifest": manifest, "entitlements": entitlements}
    success = False
    try:
        built = run(["xcrun", "swiftc", "-D", "DEBUG", "-swift-version", "6", "-parse-as-library", "-warnings-as-errors",
                     "-target", "arm64-apple-macos14.0", "-module-cache-path", str(root / "module-cache"),
                     "-file-prefix-map", f"{REPO}=.", "-file-prefix-map", f"{root}=./validation",
                     *map(str, sources), "-o", str(executable)], timeout=900)
        (output / "build.log").write_text(built.stdout + built.stderr)
        if built.returncode:
            raise RuntimeError("probe compile failed; see build.log")
        signed = run(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", str(entitlement_path), str(app)])
        if signed.returncode:
            raise RuntimeError("probe ad-hoc signing failed")
        verified = run(["/usr/bin/codesign", "--verify", "--strict", str(app)])
        shown = run(["/usr/bin/codesign", "--display", "--entitlements", ":-", str(app)])
        if verified.returncode or shown.returncode or plistlib.loads(shown.stdout.encode()) != entitlements:
            raise RuntimeError("probe signature or entitlement verification failed")
        report["signature_verified"] = True
        report["recovery_seed_exit_codes"] = {}
        for location in ("tmp", "support"):
            seeded = run([str(executable), "--seed-recovery", location], timeout=30)
            report["recovery_seed_exit_codes"][location] = seeded.returncode
        probe = run([str(executable)], timeout=120)
        value = json.loads(probe.stdout)
        report["probe"] = value
        report["exit_code"] = probe.returncode
        success = validate_result(value, probe.returncode, bundle_id)
        if success and set(report["recovery_seed_exit_codes"].values()) != {73}:
            raise ValueError("registered interrupted-write fixture did not exit at the intended hook")
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        report["error"] = str(error)
        success = False
    finally:
        try:
            report["container_archive"] = archive_container(bundle_id, root)
        except (OSError, ValueError) as error:
            report["cleanup_error"] = str(error)
            success = False
        report["passed"] = success
        (output / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"passed": success, "result": str(output / "result.json"),
                      "checks": len(report.get("probe", {}).get("checks", [])),
                      "failed": [row["name"] for row in report.get("probe", {}).get("checks", []) if not row["passed"]]}))
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
