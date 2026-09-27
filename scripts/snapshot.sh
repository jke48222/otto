#!/usr/bin/env bash
#
# snapshot.sh — build Otto and render UI snapshots (PNG, 2×) into docs/snapshots.
#
#   scripts/snapshot.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="$ROOT/build/Build/Products/Debug/Otto.app/Contents/MacOS/Otto"
OUTPUT="$ROOT/docs/snapshots"

"$ROOT/scripts/build.sh"

mkdir -p "$OUTPUT"
echo "==> Rendering snapshots into $OUTPUT"
# Runs the binary directly (not via `open`) so output and the exit status reach this shell.
"$BINARY" --snapshot "$OUTPUT"
echo "==> Snapshots written to $OUTPUT"
