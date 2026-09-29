#!/usr/bin/env bash
#
# snapshot.sh — build Otto and render UI snapshots (PNG, 2×) into docs/snapshots.
#
#   scripts/snapshot.sh              the source build's scenes (SPEC-v2 §10.3) into docs/snapshots
#   scripts/snapshot.sh --licensing  the licensing scenes (§14.17.4) into docs/snapshots/licensing, from the
#                                    licensing-check build (Otto.xcodeproj with OTTO_LICENSING, build/licensing)
#   scripts/snapshot.sh --paid       the paid build's Updates scene into docs/snapshots/paid, from
#                                    OttoPaid.xcodeproj (build/paid)
#
# Every run renders into a temporary folder and copies into docs/snapshots only after the renderer exits 0,
# reports no scene errors and wrote at least one PNG, so a failed run never leaves the folder half updated.
# A flavor option copies only its own folder, so the §10.3 pictures always come from the source build.
#
# The renderer drives real SwiftUI hosting views; on a loaded machine it can crash inside the framework or hit
# its own 240 s watchdog. Those two failures (death by a signal, or the watchdog's message) are retried in a
# fresh process, up to OTTO_SNAPSHOT_ATTEMPTS runs in all (default 3). A scene that reports a setup error is
# not retried: that is a bug, and running again would draw the same thing.
#
# Environment:
#   OTTO_ADHOC_SIGNING=1       force an ad hoc signature
#   OTTO_SNAPSHOT_ATTEMPTS=N   renderer runs before giving up (default 3)
#   OTTO_SNAPSHOT_BINARY=path  render with this already built Debug binary and skip the build
#   OTTO_SNAPSHOT_OUTPUT=dir   copy into this folder instead of docs/snapshots
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${OTTO_SNAPSHOT_OUTPUT:-$ROOT/docs/snapshots}"
ATTEMPTS="${OTTO_SNAPSHOT_ATTEMPTS:-3}"
BINARY="${OTTO_SNAPSHOT_BINARY:-}"
# What AppDelegate's watchdog writes to standard error before it exits 1.
TIMEOUT_MESSAGE="Snapshot rendering timed out."
# What SnapshotRenderer writes to standard error for a scene it could not set up or draw (it still exits 0).
SCENE_ERROR_PREFIX="snapshot error:"

usage() {
  echo "usage: scripts/snapshot.sh [--licensing | --paid]" >&2
  exit 2
}

flavor="source"
case "$#" in
  0) ;;
  1)
    case "$1" in
      --licensing) flavor="licensing" ;;
      --paid) flavor="paid" ;;
      *) usage ;;
    esac
    ;;
  *) usage ;;
esac

if ! [[ "$ATTEMPTS" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: OTTO_SNAPSHOT_ATTEMPTS must be a whole number of at least 1 (got '$ATTEMPTS')" >&2
  exit 2
fi

# MARK: - Build

if [[ -n "$BINARY" ]]; then
  echo "==> Using $BINARY (OTTO_SNAPSHOT_BINARY; not building)"
elif [[ "$flavor" == "source" ]]; then
  "$ROOT/scripts/build.sh"
  BINARY="$ROOT/build/Build/Products/Debug/Otto.app/Contents/MacOS/Otto"
else
  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen is not installed. Install it with: brew install xcodegen" >&2
    exit 1
  fi

  signing_overrides=()
  if [[ "${OTTO_ADHOC_SIGNING:-0}" == "1" ]]; then
    echo "==> Signing ad hoc (OTTO_ADHOC_SIGNING=1)"
    signing_overrides=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=)
  fi

  cd "$ROOT"
  case "$flavor" in
    licensing)
      echo "==> Generating Otto.xcodeproj"
      xcodegen generate --quiet --spec "$ROOT/project.yml"
      echo "==> Building the licensing-check build (Debug, OTTO_LICENSING)"
      xcodebuild -project Otto.xcodeproj -scheme Otto -configuration Debug -derivedDataPath build/licensing -quiet \
        ${signing_overrides[@]+"${signing_overrides[@]}"} \
        'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG OTTO_LICENSING' build
      BINARY="$ROOT/build/licensing/Build/Products/Debug/Otto.app/Contents/MacOS/Otto"
      ;;
    paid)
      echo "==> Generating OttoPaid.xcodeproj"
      xcodegen generate --quiet --spec "$ROOT/project-paid.yml"
      echo "==> Building the paid build (Debug)"
      xcodebuild -project OttoPaid.xcodeproj -scheme Otto -configuration Debug -derivedDataPath build/paid -quiet \
        ${signing_overrides[@]+"${signing_overrides[@]}"} build
      BINARY="$ROOT/build/paid/Build/Products/Debug/Otto.app/Contents/MacOS/Otto"
      ;;
  esac
fi

if [[ ! -x "$BINARY" ]]; then
  echo "error: $BINARY is missing or not executable" >&2
  exit 1
fi

# MARK: - Render

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/otto-snapshots.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
RENDERED="$SCRATCH/rendered"

# Runs the renderer into $RENDERED until one run succeeds, retrying only crashes and watchdog timeouts.
# Runs the binary directly (not via `open`) so its output and exit status reach this shell.
render_scenes() {
  local attempt=1 status log signal
  while :; do
    rm -rf "$RENDERED"
    mkdir -p "$RENDERED"
    log="$SCRATCH/render-$attempt.log"
    echo "==> Rendering snapshots (run $attempt of $ATTEMPTS)"
    status=0
    "$BINARY" --snapshot "$RENDERED" 2>"$log" || status=$?
    # The renderer's standard error (scene errors, AppKit noise) still reaches the terminal, after the run.
    cat "$log" >&2

    if grep -qF -- "$SCENE_ERROR_PREFIX" "$log"; then
      echo "error: the renderer reported scene errors (above); nothing was copied" >&2
      return 1
    fi

    if [[ "$status" -eq 0 ]]; then
      return 0
    fi

    if [[ "$status" -gt 128 ]]; then
      signal="$(kill -l $((status - 128)) 2>/dev/null || echo "signal $((status - 128))")"
      echo "warning: the renderer died on SIG$signal (exit $status) partway through the scenes." >&2
      echo "         Its crash report, if macOS wrote one, is the newest" \
        "~/Library/Logs/DiagnosticReports/Otto-*.ips" >&2
    elif grep -qF -- "$TIMEOUT_MESSAGE" "$log"; then
      echo "warning: the renderer's watchdog stopped it (exit $status); the machine may be busy." >&2
    else
      echo "error: the renderer exited $status; nothing was copied" >&2
      return 1
    fi

    if [[ "$attempt" -ge "$ATTEMPTS" ]]; then
      echo "error: no clean run in $ATTEMPTS tries; nothing was copied" >&2
      return 1
    fi
    attempt=$((attempt + 1))
  done
}

render_scenes

# MARK: - Copy

if [[ "$flavor" == "source" ]]; then
  source_dir="$RENDERED"
  dest="$OUTPUT"
  scenes="scenes"
else
  source_dir="$RENDERED/$flavor"
  dest="$OUTPUT/$flavor"
  scenes="scenes into $flavor/"
fi

if ! compgen -G "$source_dir/*.png" >/dev/null; then
  echo "error: the $flavor build rendered no $scenes; nothing was copied" >&2
  exit 1
fi

mkdir -p "$dest"
cp "$source_dir"/*.png "$dest/"

# A PNG in the destination that this run did not draw belongs to a scene that no longer exists.
stale=()
for existing in "$dest"/*.png; do
  [[ -e "$existing" ]] || continue
  [[ -e "$source_dir/$(basename "$existing")" ]] || stale+=("$(basename "$existing")")
done
if [[ ${#stale[@]} -gt 0 ]]; then
  echo "warning: these PNGs in $dest were not drawn by this run (a removed or renamed scene?):" >&2
  printf '         %s\n' "${stale[@]}" >&2
fi

echo "==> Snapshots written to $dest"
