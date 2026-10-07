#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="${1:?Usage: build-learning-quality-cli.sh NEW_OUTPUT_DIRECTORY [SOURCE_ROOT]}"
source_root="${2:-$root}"
module_cache="${LIVELINGO_QUALITY_MODULE_CACHE:-$output/ModuleCache}"
if [[ "$module_cache" != /* || "$module_cache" == / || -L "$module_cache" ]]; then
 printf 'Module cache must be an absolute directory without symlinks.\n' >&2; exit 1
fi
if [[ -e "$output" ]]; then printf 'Output already exists.\n' >&2; exit 1; fi
if [[ ! -d "$source_root/LiveLingo/Sources" ]]; then printf 'Source root is invalid.\n' >&2; exit 1; fi
mkdir -p "$output" "$module_cache"
sources=()
for source in "$source_root"/LiveLingo/Sources/*.swift; do
 case "$(basename "$source")" in LiveLingoApp.swift|ContentView.swift|FloatingSubtitleView.swift|SavedProcessingView.swift) ;; *) sources+=("$source");; esac
done
xcrun swiftc -D LIVELINGO_CLI -D LIVELINGO_CLI_LIFECYCLE_TESTS -swift-version 6 -parse-as-library -O \
 -target arm64-apple-macos14.0 -module-cache-path "$module_cache" \
 "${sources[@]}" "$root/Scripts/livelingo-cli.swift" "$root/Scripts/learning-quality-cli.swift" -o "$output/learning-quality-cli"
printf 'Built %s/learning-quality-cli\n' "$output"
