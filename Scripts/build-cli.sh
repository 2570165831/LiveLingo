#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="${1:?Usage: build-cli.sh NEW_OUTPUT_DIRECTORY [--lifecycle-tests] [--module-cache EXISTING_ABSOLUTE_DIRECTORY]}"
shift
lifecycle_tests=0
module_cache=""
while [[ $# -gt 0 ]]; do
 case "$1" in
 --lifecycle-tests)
  if [[ "$lifecycle_tests" == 1 ]]; then echo 'Duplicate build option.' >&2; exit 1; fi
  lifecycle_tests=1; shift ;;
 --module-cache)
  if [[ $# -lt 2 || -n "$module_cache" || "$2" != /* || "$2" == / || ! -d "$2" || -L "$2" ]]; then
   echo 'Module cache must be an existing absolute directory, supplied once.' >&2; exit 1
  fi
  module_cache="$2"; shift 2 ;;
 *) echo 'Unknown build option.' >&2; exit 1 ;;
 esac
done
if [[ -e "$output" || -L "$output" ]]; then echo 'Output directory already exists; refusing to overwrite.' >&2; exit 1; fi
mkdir -p "$output"
module_cache="${module_cache:-$output/ModuleCache}"
sources=()
for source in "$root"/LiveLingo/Sources/*.swift; do
 case "$(basename "$source")" in LiveLingoApp.swift|ContentView.swift|FloatingSubtitleView.swift|SavedProcessingView.swift) ;; *) sources+=("$source");; esac
done
if [[ "$lifecycle_tests" == 1 ]]; then
 xcrun swiftc -D LIVELINGO_CLI -D LIVELINGO_CLI_LIFECYCLE_TESTS -swift-version 6 -parse-as-library -O -target arm64-apple-macos14.0 -module-cache-path "$module_cache" "${sources[@]}" "$root/Scripts/livelingo-cli.swift" "$root/Scripts/test-cli-lifecycle.swift" -o "$output/livelingo-cli-lifecycle-tests"
 printf 'Built %s/livelingo-cli-lifecycle-tests\n' "$output"
else
 xcrun swiftc -D LIVELINGO_CLI -swift-version 6 -parse-as-library -O -target arm64-apple-macos14.0 -module-cache-path "$module_cache" "${sources[@]}" "$root/Scripts/livelingo-cli.swift" -o "$output/livelingo-cli"
 xcrun swiftc -target arm64-apple-macos14.0 -module-cache-path "$module_cache" "$root/Scripts/virtual-audio-player.swift" -o "$output/livelingo-virtual-player"
 printf 'Built %s/livelingo-cli\n' "$output"
fi
