#!/usr/bin/env python3
"""Opt-in local >4 GiB sparse-file/ditto/UDZO experiment with new temp fixtures.

Run it with --run-experiment --temporary-directory "$TMPDIR". Without a mode the
script exits non-zero, so a bare invocation can never look like verification.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time


def run(*command, environment):
    result = subprocess.run(command, capture_output=True, env=environment)
    if result.returncode:
        raise RuntimeError("%s failed (%s): %s" %
                           (command[0], result.returncode, result.stderr.decode(errors="replace")))
    return result


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def prerequisite_reason():
    if sys.platform != "darwin":
        return "requires macOS disk-image tools"
    if not hasattr(hashlib, "file_digest"):
        return "requires Python 3.11+ standard-library file_digest"
    for tool in ("/usr/bin/ditto", "/usr/bin/hdiutil"):
        if not Path(tool).is_file() or not os.access(tool, os.X_OK):
            return "required tool unavailable: " + Path(tool).name
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--run-experiment", action="store_true",
                      help="explicitly run the heavy sparse-file and disk-image experiment")
    mode.add_argument("--check-prerequisites", action="store_true",
                      help="check only platform/tool availability; create no fixture or disk image")
    parser.add_argument("--temporary-directory", type=Path,
                        help="explicit scratch parent matching the harness-controlled TMPDIR")
    arguments = parser.parse_args()
    if not arguments.run_experiment and not arguments.check_prerequisites:
        parser.error("no mode selected; nothing was verified. Run the experiment with "
                     "--run-experiment --temporary-directory \"$TMPDIR\", or check tools only "
                     "with --check-prerequisites")
    reason = prerequisite_reason()
    if reason is not None:
        # An explicitly requested experiment or check that cannot run fails.
        mode = "experiment" if arguments.run_experiment else "prerequisite check"
        raise SystemExit("FAIL large-app-dmg " + mode + ": " + reason + "; experiment not run")
    if arguments.check_prerequisites:
        print("PASS large-app-dmg prerequisites only; experiment not run, nothing verified")
        return
    if arguments.temporary_directory is None:
        parser.error("--run-experiment requires --temporary-directory matching controlled TMPDIR")
    temporary_parent = arguments.temporary_directory
    if not temporary_parent.is_absolute() or temporary_parent.is_symlink():
        parser.error("temporary directory must be absolute and must not be a symlink")
    temporary_parent = temporary_parent.resolve(strict=True)
    if not temporary_parent.is_dir() or Path(tempfile.gettempdir()).resolve() != temporary_parent:
        parser.error("temporary directory must match the existing harness-controlled TMPDIR")
    child_environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": str(temporary_parent)}
    scratch = Path(tempfile.mkdtemp(prefix="livelingo-large-dmg-", dir=temporary_parent))
    device = None
    result = {"bytes": 5_136_696_107, "format": "UDZO"}
    started = time.monotonic()
    print("Experiment fixture: " + str(scratch), flush=True)
    try:
        original = scratch / "input" / "LiveLingo.app" / "Contents" / "Resources" / "model.bin"
        original.parent.mkdir(parents=True)
        with original.open("wb") as stream:
            stream.truncate(result["bytes"])
            for offset in (0, 2**32 - 8, 2**32 + 123, result["bytes"] - 32):
                stream.seek(offset)
                stream.write(b"LIVELINGO-SPARSE-CHECK")
        result["sparseAllocatedBytes"] = original.stat().st_blocks * 512
        expected = sha256(original)
        payload = scratch / "app-only"
        payload.mkdir()
        run("/usr/bin/ditto", "--rsrc", "--extattr", str(original.parents[2]), str(payload / "LiveLingo.app"),
            environment=child_environment)
        copied = payload / "LiveLingo.app/Contents/Resources/model.bin"
        result["copiedAllocatedBytes"] = copied.stat().st_blocks * 512
        assert copied.stat().st_size == result["bytes"] and sha256(copied) == expected
        image = scratch / "app-container.dmg"
        spec = importlib.util.spec_from_file_location("release_state", Path(__file__).with_name("release-state.py"))
        state = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(state)
        capacity = state.image_size(payload)
        result["imageCapacityBytes"] = capacity
        run("/usr/bin/hdiutil", "create", "-size", str(capacity) + "b", "-srcfolder", str(payload), "-volname", "LiveLingoSparseTest",
            "-format", "UDZO", "-imagekey", "zlib-level=6", str(image), environment=child_environment)
        result["imageBytes"] = image.stat().st_size
        run("/usr/bin/hdiutil", "verify", str(image), environment=child_environment)
        mount = scratch / "mount"
        mount.mkdir()
        attached = run("/usr/bin/hdiutil", "attach", "-plist", "-readonly", "-nobrowse",
                       "-mountpoint", str(mount), str(image), environment=child_environment)
        entities = plistlib.loads(attached.stdout)["system-entities"]
        device = next(e["dev-entry"] for e in entities if re.fullmatch(r"/dev/disk[0-9]+", e.get("dev-entry", "")))
        readback = mount / "LiveLingo.app/Contents/Resources/model.bin"
        result["mountedBytes"] = readback.stat().st_size
        result["sha256"] = sha256(readback)
        assert sorted(p.name for p in mount.iterdir() if not p.name.startswith(".")) == ["LiveLingo.app"]
        assert result["mountedBytes"] == result["bytes"] and result["sha256"] == expected
        result["passed"] = True
    finally:
        if device:
            for attempt in range(3):
                detached = subprocess.run(["/usr/bin/hdiutil", "detach", device], capture_output=True,
                                          env=child_environment)
                if detached.returncode == 0:
                    device = None
                    break
                time.sleep(attempt + 1)
            if device:
                raise RuntimeError("Cannot detach experiment device " + device + "; fixture retained at " + str(scratch))
        # Delete only the exact newly-created, non-symlink temp fixture after detach.
        assert (scratch.parent == temporary_parent and scratch.name.startswith("livelingo-large-dmg-")
                and not scratch.is_symlink())
        shutil.rmtree(scratch)
    result["fixtureRemoved"] = not scratch.exists()
    result["elapsedSeconds"] = round(time.monotonic() - started, 2)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
