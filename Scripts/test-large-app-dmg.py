#!/usr/bin/env python3
"""Local >4 GiB sparse-file/ditto/UDZO experiment, using only new temp fixtures."""
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import time


def run(*command):
    result = subprocess.run(command, capture_output=True)
    if result.returncode:
        raise RuntimeError("%s failed (%s): %s" %
                           (command[0], result.returncode, result.stderr.decode(errors="replace")))
    return result


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    scratch = Path(tempfile.mkdtemp(prefix="livelingo-large-dmg-", dir="/private/tmp"))
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
        run("/usr/bin/ditto", "--rsrc", "--extattr", str(original.parents[2]), str(payload / "LiveLingo.app"))
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
            "-format", "UDZO", "-imagekey", "zlib-level=6", str(image))
        result["imageBytes"] = image.stat().st_size
        run("/usr/bin/hdiutil", "verify", str(image))
        mount = scratch / "mount"
        mount.mkdir()
        attached = run("/usr/bin/hdiutil", "attach", "-plist", "-readonly", "-nobrowse",
                       "-mountpoint", str(mount), str(image))
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
                detached = subprocess.run(["/usr/bin/hdiutil", "detach", device], capture_output=True)
                if detached.returncode == 0:
                    device = None
                    break
                time.sleep(attempt + 1)
            if device:
                raise RuntimeError("Cannot detach experiment device " + device + "; fixture retained at " + str(scratch))
        # Delete only the exact newly-created, non-symlink temp fixture after detach.
        assert scratch.parent == Path("/private/tmp") and not scratch.is_symlink()
        shutil.rmtree(scratch)
    result["fixtureRemoved"] = not scratch.exists()
    result["elapsedSeconds"] = round(time.monotonic() - started, 2)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
