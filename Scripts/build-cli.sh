#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="${1:?Usage: build-cli.sh NEW_OUTPUT_DIRECTORY}"
if [[ -e "$output" ]]; then echo 'Output directory already exists; refusing to overwrite.' >&2; exit 1; fi
mkdir -p "$output"
sources=()
for source in "$root"/LiveLingo/Sources/*.swift; do
 case "$(basename "$source")" in LiveLingoApp.swift|ContentView.swift|FloatingSubtitleView.swift) ;; *) sources+=("$source");; esac
done
xcrun swiftc -D LIVELINGO_CLI -swift-version 6 -parse-as-library -O -target arm64-apple-macos14.0 "${sources[@]}" "$root/Scripts/livelingo-cli.swift" -o "$output/livelingo-cli"
xcrun swiftc "$root/Scripts/virtual-audio-player.swift" -o "$output/livelingo-virtual-player"
printf 'Built %s/livelingo-cli\n' "$output"
