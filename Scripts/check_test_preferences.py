#!/usr/bin/env python3
"""Read an xcodebuild test log and verify its UUID preference suites are gone."""

import argparse
from collections import Counter
import os
from pathlib import Path
import pwd
import re
import sys


EVENT = re.compile(r"\bTEST_PREFERENCE_(CREATED|CLEANED)\s+suite=(\S+)")
SUITE = re.compile(
    r"[A-Za-z][A-Za-z0-9-]*-"
    r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\Z"
)


def check(lines, preferences, allow_no_events=False):
    """Return event counts and errors without modifying any preference file.

    allow_no_events is only for focused runs whose tests create no suite; the
    successful completion marker and every per-suite rule still apply.
    """
    created, cleaned = Counter(), Counter()
    errors = []
    succeeded = False
    for number, line in enumerate(lines, 1):
        succeeded |= "** TEST SUCCEEDED **" in line
        for match in EVENT.finditer(line):
            event, suite = match.groups()
            if not SUITE.fullmatch(suite):
                errors.append(f"line {number}: invalid UUID suite {suite!r}")
                continue
            if event == "CREATED":
                created[suite] += 1
            else:
                if not created[suite]:
                    errors.append(f"line {number}: CLEANED before CREATED for {suite}")
                cleaned[suite] += 1

    if not succeeded:
        errors.append("log has no successful xcodebuild test completion")
    if not created and not allow_no_events:
        errors.append("log has no TEST_PREFERENCE_CREATED events")
    for suite in sorted(created.keys() | cleaned.keys()):
        if created[suite] != 1 or cleaned[suite] != 1:
            errors.append(
                f"{suite}: CREATED={created[suite]} CLEANED={cleaned[suite]} (expected 1 each)"
            )
        try:
            (preferences / (suite + ".plist")).lstat()
        except FileNotFoundError:
            pass
        except OSError as error:
            errors.append(f"{suite}: could not verify plist absence: {error}")
        else:
            errors.append(f"{suite}: plist still exists (including links or directories)")
    return sum(created.values()), sum(cleaned.values()), errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path, help="complete xcodebuild test log")
    parser.add_argument("--allow-no-events", action="store_true",
                        help="focused runs only: pass when the tests created no preference suite")
    args = parser.parse_args()
    # Match TestPreferenceCleanup's account home; HOME/CFFIXED_USER_HOME may
    # point somewhere else while cfprefsd still uses the real user's home.
    preferences = Path(pwd.getpwuid(os.getuid()).pw_dir) / "Library" / "Preferences"
    try:
        with args.log.open(encoding="utf-8", errors="replace") as lines:
            created, cleaned, errors = check(lines, preferences, args.allow_no_events)
    except OSError as error:
        parser.error(str(error))
    if errors:
        print(f"FAIL: CREATED={created} CLEANED={cleaned}", file=sys.stderr)
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    print(f"PASS: CREATED={created} CLEANED={cleaned}; all corresponding plists absent")
    return 0


if __name__ == "__main__":
    sys.exit(main())
