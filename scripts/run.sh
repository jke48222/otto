#!/usr/bin/env bash
#
# run.sh — build Otto, quit any running copy, and launch the fresh build.
# Extra arguments are passed to the app, e.g.:
#
#   scripts/run.sh --demo          # canned replies, no API key needed
#   scripts/run.sh --demo --open   # …and open the notch right away
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Build/Products/Debug/Otto.app"

"$ROOT/scripts/build.sh"

# `open` would just re-activate an already running Otto (ignoring --args), so stop it first.
# (A signal rather than an Apple Event, so no Automation permission prompt appears.)
USER_ID="$(id -u)"
if pgrep -x -U "$USER_ID" Otto >/dev/null 2>&1; then
  echo "==> Stopping the running Otto"
  pkill -x -U "$USER_ID" Otto || true
  for _ in $(seq 1 50); do
    pgrep -x -U "$USER_ID" Otto >/dev/null 2>&1 || break
    sleep 0.1
  done
  if pgrep -x -U "$USER_ID" Otto >/dev/null 2>&1; then
    pkill -9 -x -U "$USER_ID" Otto || true
    sleep 0.3
  fi
fi

echo "==> Launching $APP $*"
if [[ $# -gt 0 ]]; then
  open "$APP" --args "$@"
else
  open "$APP"
fi
