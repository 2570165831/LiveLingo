#!/usr/bin/env python3
"""List compiler warnings in an xcodebuild log and fail if any are present."""

import argparse
from pathlib import Path
import re
import sys


# Match primary diagnostics, not the repeated warning under a Swift source caret
# or timestamped runtime output. Compiler-driver warnings may lack a location.
WARNING = re.compile(r"^(?:.+:\s+)?warning:\s", re.IGNORECASE)
APP_INTENTS = re.compile(
    r"^(?:\S*/)?appintentsmetadataprocessor(?:\[\d+(?::\d+)?\])?:?\s+warning:",
    re.IGNORECASE,
)
# xcodebuild's own note when `-destination 'platform=macOS'` matches several
# run destinations; it is not a compiler diagnostic.
DESTINATION = re.compile(r"^--- xcodebuild: WARNING: Using the first of multiple matching destinations")


def check(lines):
    """Return numbered warning lines, excluding App Intents and destination notices."""
    return [
        (number, line.rstrip())
        for number, line in enumerate(lines, 1)
        if WARNING.search(line) and not APP_INTENTS.search(line) and not DESTINATION.search(line)
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path, help="complete xcodebuild log (stdout and stderr)")
    args = parser.parse_args()
    try:
        with args.log.open(encoding="utf-8", errors="replace") as lines:
            warnings = check(lines)
    except OSError as error:
        parser.error(str(error))
    if warnings:
        print(f"FAIL: {len(warnings)} compiler warning(s)", file=sys.stderr)
        for number, line in warnings:
            print(f"line {number}: {line}", file=sys.stderr)
        return 1
    print("PASS: 0 compiler warnings")
    return 0


if __name__ == "__main__":
    sys.exit(main())
