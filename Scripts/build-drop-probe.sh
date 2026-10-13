#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="${1:?NEW_OUTPUT_DIRECTORY}"
cache="${2:?EXISTING_MODULE_CACHE}"
[[ ! -e "$output" && ! -L "$output" && -d "$cache" ]] || exit 1
mkdir -p "$output"
sources=()
for source in "$root"/LiveLingo/Sources/*.swift; do
 case "$(basename "$source")" in LiveLingoApp.swift|ContentView.swift|FloatingSubtitleView.swift|SavedProcessingView.swift) ;; *) sources+=("$source");; esac
done
xcrun swiftc -D LIVELINGO_CLI -D LIVELINGO_DROP_PROBE -swift-version 6 -parse-as-library -O -whole-module-optimization \
 -target arm64-apple-macos14.0 -module-cache-path "$cache" "${sources[@]}" \
 "$root/Scripts/livelingo-cli.swift" "$root/Scripts/drop-probe-metrics.swift" "$root/Scripts/drop-probe.swift" \
 -D LIVELINGO_CLI_LIFECYCLE_TESTS -o "$output/drop-probe"
