#!/bin/bash
set -euo pipefail
task_source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_output="${1:?Usage: build-target-eval-cli.sh NEW_DIRECTORY_UNDER_CONFIGURED_OUTPUT_ROOT}"
if [[ $# != 1 ]]; then printf 'Expected one output directory.\n' >&2; exit 1; fi
task_lab_root="$(dirname "$task_source_root")"
task_derived_root="${LIVELINGO_TARGET_EVAL_DERIVED_ROOT:-$task_lab_root/work/dd-latin/target-acceptance-cli}"
task_derived="$task_derived_root/$(basename "$task_output")"
task_cache="$task_derived/ModuleCache.noindex"
task_temp="$task_derived/tmp"
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 - "$task_source_root" "$task_lab_root" "$task_output" "$task_derived_root" <<'PY'
from pathlib import Path
import sys
source, lab, destination, derived_root = map(Path, sys.argv[1:])
sys.path.insert(0, str(source))
from Scripts.target_eval.corpora import validate_output_path
if not destination.is_absolute():
    raise SystemExit('Output must be an absolute path inside LIVELINGO_TARGET_EVAL_OUTPUT_ROOT.')
try:
    destination = validate_output_path(destination)
except ValueError as error:
    raise SystemExit(str(error)) from None
if destination.exists() or destination.is_symlink():
    raise SystemExit('Output exists; refusing to overwrite.')
if not derived_root.is_absolute() or derived_root.resolve() != derived_root or '..' in derived_root.parts:
    raise SystemExit('Derived root must be an absolute directory without symlinks or parent traversal.')
# An override uses the same explicitly configured external output boundary.
import os
if os.environ.get('LIVELINGO_TARGET_EVAL_DERIVED_ROOT'):
    derived_root = validate_output_path(derived_root)
derived = derived_root / destination.name
for path in (derived, derived / 'ModuleCache.noindex', derived / 'tmp'):
    if path.resolve() != path or path.is_symlink():
        raise SystemExit('DerivedData paths must not use symlinks.')
# Reserve the leaf exclusively: two builds must not both pass the preflight
# and write the same binary. Parent directories are already constrained above.
destination.parent.mkdir(parents=True, exist_ok=True)
validate_output_path(destination)
destination.mkdir(exist_ok=False)
for path in (derived / 'ModuleCache.noindex', derived / 'tmp'):
    path.mkdir(parents=True, exist_ok=True)
    if path.resolve() != path:
        raise SystemExit('DerivedData path changed or uses a symlink.')
PY
task_sources=()
for task_source in "$task_source_root"/LiveLingo/Sources/*.swift; do
    case "$(basename "$task_source")" in
        LiveLingoApp.swift|ContentView.swift|FloatingSubtitleView.swift|SavedProcessingView.swift) ;;
        *) task_sources+=("$task_source");;
    esac
done
TMPDIR="$task_temp" xcrun swiftc -D LIVELINGO_CLI -D LIVELINGO_CLI_LIFECYCLE_TESTS -swift-version 6 -parse-as-library -O \
    -target arm64-apple-macos14.0 -module-cache-path "$task_cache" \
    -file-prefix-map "$task_source_root=." \
    "${task_sources[@]}" "$task_source_root/Scripts/livelingo-cli.swift" "$task_source_root/Scripts/target-acceptance-cli.swift" \
    -o "$task_output/target-acceptance-cli"
printf 'Built %s/target-acceptance-cli\n' "$task_output"
