#!/usr/bin/env bash
# count-lines.sh — prints how many lines of code are in the project (all .lua under src/).
# Usage:  ./count-lines.sh        (total + per-file, sorted biggest first)
#         bash count-lines.sh

set -euo pipefail
cd "$(dirname "$0")"

echo "=== Lines of code (src/**.lua) ==="
echo

# Per-file, largest first.
find src -name '*.lua' -type f -print0 \
  | xargs -0 wc -l \
  | grep -v ' total$' \
  | sort -rn

echo
files=$(find src -name '*.lua' -type f | wc -l | tr -d ' ')
total=$(find src -name '*.lua' -type f -print0 | xargs -0 cat | wc -l | tr -d ' ')
echo "-------------------------------------"
printf "Files: %s\n" "$files"
printf "Total lines: %s\n" "$total"
