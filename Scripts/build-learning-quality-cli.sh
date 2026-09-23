#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="${1:?Usage: build-learning-quality-cli.sh NEW_OUTPUT_DIRECTORY [SOURCE_ROOT]}"
source_root="${2:-$root}"
if [[ -e "$output" ]]; then printf 'Output already exists.\n' >&2; exit 1; fi
if [[ ! -d "$source_root/LiveLingo/Sources" ]]; then printf 'Source root is invalid.\n' >&2; exit 1; fi
mkdir -p "$output"
sources=()
for source in "$source_root"/LiveLingo/Sources/*.swift; do
 case "$(basename "$source")" in LiveLingoApp.swift|ContentView.swift|FloatingSubtitleView.swift|SavedProcessingView.swift) ;; *) sources+=("$source");; esac
done
xcrun swiftc -swift-version 6 -parse-as-library -O -target arm64-apple-macos14.0 \
 "${sources[@]}" "$root/Scripts/learning-quality-cli.swift" -o "$output/learning-quality-cli"
printf 'Built %s/learning-quality-cli\n' "$output"
