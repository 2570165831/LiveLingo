#!/bin/bash
set -euo pipefail
task_source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_gate_root="${1:?Usage: run-privacy-tools-tests.sh ABSOLUTE_PRIVATE_OUTPUT_ROOT}"
if [[ $# != 1 || "$task_gate_root" != /* || "$task_gate_root" == / || -L "$task_gate_root" ]]; then
    printf 'Supply one absolute, private output directory without symlinks.\n' >&2; exit 1
fi
python3 -B - "$task_source_root" "$task_gate_root" <<'PY'
from pathlib import Path
import sys
source, output = map(Path, sys.argv[1:])
if output.resolve() != output or output.is_relative_to(source) or '..' in output.parts:
    raise SystemExit('Test output must be outside the checkout and must not use symlinks or parent traversal.')
output.mkdir(mode=0o700, parents=True, exist_ok=True)
PY
mkdir -p "$task_gate_root/tmp" "$task_gate_root/cli-module-cache" "$task_gate_root/offline-clis" "$task_gate_root/python-quality"
export TMPDIR="$task_gate_root/tmp/" PYTHONDONTWRITEBYTECODE=1
export LIVELINGO_TARGET_EVAL_OUTPUT_ROOT="$task_gate_root"
export LIVELINGO_QUALITY_TEST_DIRECTORY="$task_gate_root/python-quality"
export LIVELINGO_ASR_TEST_IN_PROCESS=1
export LIVELINGO_IDLE_TEST_OUTPUT="$task_gate_root/idle-tests"
export LIVELINGO_CLI_TEST_OUTPUT_ROOT="$task_gate_root"
export PYTHONPATH="$task_source_root/Scripts:$task_source_root/Scripts/mlx_runtime:/Applications/LiveLingo.app/Contents/Resources/LanguageRuntime/python/lib/python3.13/site-packages:/Applications/LiveLingo.app/Contents/Resources/ASRRuntime/python/lib/python3.13/site-packages"
cd "$task_source_root"
task_sources=()
for task_source in "$task_source_root"/LiveLingo/Sources/*.swift; do
    case "$(basename "$task_source")" in
        LiveLingoApp.swift|ContentView.swift|FloatingSubtitleView.swift|SavedProcessingView.swift) ;;
        *) task_sources+=("$task_source");;
    esac
done
build_entry() {
    local task_name="$1"
    shift
    printf 'Building %s\n' "$task_name"
    xcrun swiftc -D LIVELINGO_CLI -swift-version 6 -parse-as-library -O \
        -target arm64-apple-macos14.0 -module-cache-path "$task_gate_root/cli-module-cache" \
        -file-prefix-map "$task_source_root=." -file-prefix-map "$task_gate_root=./validation" \
        "${task_sources[@]}" "$task_source_root/Scripts/livelingo-cli.swift" "$@" \
        -o "$task_gate_root/offline-clis/$task_name" > "$task_gate_root/build-$task_name.log" 2>&1
}
build_entry livelingo-cli
build_entry target-acceptance-cli -D LIVELINGO_CLI_LIFECYCLE_TESTS Scripts/target-acceptance-cli.swift
build_entry learning-quality-cli -D LIVELINGO_CLI_LIFECYCLE_TESTS Scripts/learning-quality-cli.swift
build_entry learning-quality-cli-tests -D LIVELINGO_CLI_LIFECYCLE_TESTS -D QUALITY_PROBE_TESTS Scripts/learning-quality-cli.swift Scripts/test_learning_quality_cli.swift
build_entry learning-quality-target-cli-tests -D LIVELINGO_CLI_LIFECYCLE_TESTS -D QUALITY_PROBE_TESTS Scripts/learning-quality-cli.swift Scripts/test_learning_quality_target_cli.swift
build_entry livelingo-cli-lifecycle-tests -D LIVELINGO_CLI_LIFECYCLE_TESTS Scripts/test-cli-lifecycle.swift
build_entry livelingo-cli-multilingual-tests -D LIVELINGO_CLI_LIFECYCLE_TESTS Scripts/test-cli-multilingual.swift
build_entry livelingo-cli-target-review-tests -D LIVELINGO_CLI_LIFECYCLE_TESTS Scripts/test-cli-target-review.swift
build_entry livelingo-cli-translation-failure-tests -D LIVELINGO_CLI_LIFECYCLE_TESTS LiveLingoTests/TestPreferenceCleanup.swift Scripts/test-cli-translation-failures.swift
"$task_gate_root/offline-clis/learning-quality-cli-tests" "$task_gate_root/quality-cli-tests" Scripts/Fixtures/learning-quality-v1
"$task_gate_root/offline-clis/learning-quality-target-cli-tests" "$task_gate_root/quality-target-cli-tests"
"$task_gate_root/offline-clis/livelingo-cli-lifecycle-tests" "$task_gate_root/cli-lifecycle-tests"
"$task_gate_root/offline-clis/livelingo-cli-multilingual-tests" "$task_gate_root/offline-clis/livelingo-cli" "$task_gate_root/cli-multilingual-tests"
"$task_gate_root/offline-clis/livelingo-cli-target-review-tests" "$task_gate_root/cli-target-review-tests"
"$task_gate_root/offline-clis/livelingo-cli-translation-failure-tests" "$task_gate_root/cli-translation-failure-tests"
/opt/homebrew/bin/python3.13 -B Scripts/test-cli-process.py "$task_gate_root/offline-clis/livelingo-cli" "$task_gate_root/cli-process-tests" "$task_gate_root/cli-lifecycle-tests"
"$task_gate_root/offline-clis/livelingo-cli" --help > "$task_gate_root/cli-help.txt"
"$task_gate_root/offline-clis/learning-quality-cli" --input Scripts/Fixtures/learning-quality-v1/constant-acceleration.json --output "$task_gate_root/quality-cli-dry-run" --dry-run
# Match run-python-gates.sh's full discovery environment and skipped optional
# integration class, then exercise that class against this freshly built CLI.
unset LIVELINGO_TARGET_ACCEPTANCE_CLI
/opt/homebrew/bin/python3.13 -B -m unittest
LIVELINGO_TARGET_ACCEPTANCE_CLI="$task_gate_root/offline-clis/target-acceptance-cli" \
    /opt/homebrew/bin/python3.13 -B -m unittest Scripts.test_target_acceptance_cli
/opt/homebrew/bin/python3.13 -B Scripts/test-release-flow.py
printf 'Privacy tool gates passed.\n'
