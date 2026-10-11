#!/usr/bin/env python3
"""Write the quality-build-manifest.json that evaluate-learning-quality.py requires.

Called by build-learning-quality-cli.sh. Arguments after the subcommand options
are KEY PATH pairs: KEY is the repo-relative name recorded in sourceHashes and
PATH is the file to hash. The manifest holds only hashes, relative keys, the
compiler exit code and the probe purpose; no absolute paths or content.

  snapshot KEY PATH ...                      print {KEY: sha256} as JSON
  write --executable FILE --exit-code N KEY PATH ...
                                             read the snapshot JSON on stdin,
                                             re-hash, and write the manifest
                                             next to FILE (0600, never replaced)
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import sys

MANIFEST_NAME = "quality-build-manifest.json"
PURPOSE = "production-quality-probe"


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def hashes(pairs: list[str]) -> dict[str, str]:
    if not pairs or len(pairs) % 2:
        raise SystemExit("Expected KEY PATH pairs.")
    result: dict[str, str] = {}
    for key, path in zip(pairs[::2], pairs[1::2]):
        parts = PurePosixPath(key).parts
        if not key or PurePosixPath(key).is_absolute() or ".." in parts or key in result:
            raise SystemExit("Source keys must be unique repo-relative paths.")
        result[key] = digest(Path(path))
    return result


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    snapshot = commands.add_parser("snapshot")
    snapshot.add_argument("pairs", nargs="+")
    write = commands.add_parser("write")
    write.add_argument("--executable", required=True)
    write.add_argument("--exit-code", type=int, required=True)
    write.add_argument("pairs", nargs="+")
    args = parser.parse_args(argv)

    if args.command == "snapshot":
        print(json.dumps(hashes(args.pairs), sort_keys=True))
        return 0

    if args.exit_code != 0:
        print("Build failed; no build manifest was written.", file=sys.stderr)
        return 1
    before = json.loads(sys.stdin.read())
    after = hashes(args.pairs)
    if before != after:
        print("Sources changed during build; rebuild.", file=sys.stderr)
        return 3
    executable = Path(args.executable)
    if executable.is_symlink() or not executable.is_file():
        print("Built executable is missing.", file=sys.stderr)
        return 1
    manifest = {
        "manifestVersion": 1,
        "executableSHA256": digest(executable),
        "exitCode": args.exit_code,
        "sourcesUnchangedDuringBuild": True,
        "purpose": PURPOSE,
        "sourceHashes": after,
    }
    data = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
    descriptor = os.open(executable.parent / MANIFEST_NAME,
                         os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(data)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
