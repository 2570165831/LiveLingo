#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="${1:?Usage: build-cli.sh NEW_OUTPUT_DIRECTORY [--lifecycle-tests]}"
if [[ $# -gt 2 || ( $# -eq 2 && "${2:-}" != --lifecycle-tests ) ]]; then echo 'Unknown build option.' >&2; exit 1; fi
if [[ -e "$output" || -L "$output" ]]; then echo 'Output directory already exists; refusing to overwrite.' >&2; exit 1; fi
mkdir -p "$output"
sources=()
for source in "$root"/LiveLingo/Sources/*.swift; do
 case "$(basename "$source")" in LiveLingoApp.swift|ContentView.swift|FloatingSubtitleView.swift|SavedProcessingView.swift) ;; *) sources+=("$source");; esac
done
if [[ "${2:-}" == --lifecycle-tests ]]; then
 xcrun swiftc -D LIVELINGO_CLI -D LIVELINGO_CLI_LIFECYCLE_TESTS -swift-version 6 -parse-as-library -O -target arm64-apple-macos14.0 -module-cache-path "$output/ModuleCache" "${sources[@]}" "$root/Scripts/livelingo-cli.swift" "$root/Scripts/test-cli-lifecycle.swift" -o "$output/livelingo-cli-lifecycle-tests"
 printf 'Built %s/livelingo-cli-lifecycle-tests\n' "$output"
else
 xcrun swiftc -D LIVELINGO_CLI -swift-version 6 -parse-as-library -O -target arm64-apple-macos14.0 -module-cache-path "$output/ModuleCache" "${sources[@]}" "$root/Scripts/livelingo-cli.swift" -o "$output/livelingo-cli"
 xcrun swiftc -target arm64-apple-macos14.0 -module-cache-path "$output/ModuleCache" "$root/Scripts/virtual-audio-player.swift" -o "$output/livelingo-virtual-player"
 printf 'Built %s/livelingo-cli\n' "$output"
fi
