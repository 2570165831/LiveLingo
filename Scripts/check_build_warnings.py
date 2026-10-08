#!/usr/bin/env python3
"""List compiler warnings in an xcodebuild log and fail if any are present.

Xcode prints a warning only when it compiles the file. A no-op or incremental
build therefore cannot prove "zero warnings". With --require-compiled-targets
the log must also show a SwiftCompile step for every Swift source of each named
target (read from the project file); otherwise the check fails.
"""

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
COMPILE = re.compile(r"^SwiftCompile normal \S+ (.*) \(in target '([^']+)' from project '[^']+'\)\s*$")
TOKEN = re.compile(r"(?:\\.|\S)+")
PROJECT = Path(__file__).resolve().parent.parent / "LiveLingo.xcodeproj"
OBJECT = re.compile(r"^\t\t([0-9A-Fa-f]{24})(?: /\*.*?\*/)? = \{\n(.*?)^\t\t\};$", re.M | re.S)


def check(lines):
    """Return numbered warning lines, excluding App Intents and destination notices."""
    return [
        (number, line.rstrip())
        for number, line in enumerate(lines, 1)
        if WARNING.search(line) and not APP_INTENTS.search(line) and not DESTINATION.search(line)
    ]


def target_sources(pbxproj, targets):
    """Map each named native target to the Swift file names in its Sources phase."""
    objects = {identifier: body for identifier, body in OBJECT.findall(pbxproj)}
    result = {}
    for body in objects.values():
        if "isa = PBXNativeTarget;" not in body:
            continue
        name = re.search(r'^\t\t\tname = "?([^";]+)"?;$', body, re.M)
        phases = re.search(r"^\t\t\tbuildPhases = \((.*?)\);$", body, re.M | re.S)
        if not name or name[1] not in targets or not phases:
            continue
        files = set()
        for phase in re.findall(r"([0-9A-Fa-f]{24})", phases[1]):
            phase_body = objects.get(phase, "")
            if "isa = PBXSourcesBuildPhase;" in phase_body:
                files |= {item for item in re.findall(r"/\* (.+?) in Sources \*/", phase_body)
                          if item.endswith(".swift")}
        result[name[1]] = files
    return result


def compiled_sources(lines):
    """Return the Swift file names this log actually compiled, per target."""
    compiled = {}
    for line in lines:
        match = COMPILE.match(line)
        if not match:
            continue
        for token in TOKEN.findall(match[1]):
            path = re.sub(r"\\(.)", r"\1", token)
            if path.startswith("/") and path.endswith(".swift"):
                compiled.setdefault(match[2], set()).add(Path(path).name)
    return compiled


def missing_compiles(lines, pbxproj, targets):
    """Return errors unless every Swift source of every target was compiled."""
    expected = target_sources(pbxproj, targets)
    compiled = compiled_sources(lines)
    errors = []
    for target in targets:
        sources = expected.get(target)
        if not sources:
            errors.append(f"target {target}: no Swift sources found in the project file")
            continue
        missing = sorted(sources - compiled.get(target, set()))
        if missing:
            errors.append(f"target {target}: {len(missing)} of {len(sources)} Swift sources were not "
                          f"compiled in this log (first: {missing[0]})")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path, help="complete xcodebuild log (stdout and stderr)")
    parser.add_argument("--require-compiled-targets", nargs="+", metavar="TARGET", default=[],
                        help="fail unless the log compiled every Swift source of these targets")
    parser.add_argument("--project", type=Path, default=PROJECT,
                        help="Xcode project that defines the targets (default: this repository's)")
    args = parser.parse_args()
    try:
        with args.log.open(encoding="utf-8", errors="replace") as stream:
            lines = stream.readlines()
        pbxproj = ((args.project / "project.pbxproj").read_text(encoding="utf-8")
                   if args.require_compiled_targets else "")
    except OSError as error:
        parser.error(str(error))
    warnings = check(lines)
    incomplete = missing_compiles(lines, pbxproj, args.require_compiled_targets) \
        if args.require_compiled_targets else []
    if incomplete:
        print("FAIL: this log does not contain a full compile, so it cannot show every warning",
              file=sys.stderr)
        for error in incomplete:
            print(error, file=sys.stderr)
    if warnings:
        print(f"FAIL: {len(warnings)} compiler warning(s)", file=sys.stderr)
        for number, line in warnings:
            print(f"line {number}: {line}", file=sys.stderr)
    if incomplete or warnings:
        return 1
    scope = f" (full compile of {', '.join(args.require_compiled_targets)})" \
        if args.require_compiled_targets else ""
    print(f"PASS: 0 compiler warnings{scope}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
