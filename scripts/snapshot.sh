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
# A flavor option renders every scene into a temporary folder and copies only its own folder, so the §10.3
# pictures always come from the source build. Set OTTO_ADHOC_SIGNING=1 to force an ad hoc signature.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="$ROOT/docs/snapshots"

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

if [[ "$flavor" == "source" ]]; then
  "$ROOT/scripts/build.sh"
  BINARY="$ROOT/build/Build/Products/Debug/Otto.app/Contents/MacOS/Otto"
  mkdir -p "$OUTPUT"
  echo "==> Rendering snapshots into $OUTPUT"
  # Runs the binary directly (not via `open`) so output and the exit status reach this shell.
  "$BINARY" --snapshot "$OUTPUT"
  echo "==> Snapshots written to $OUTPUT"
  exit 0
fi

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

if [[ ! -x "$BINARY" ]]; then
  echo "error: build finished but $BINARY is missing" >&2
  exit 1
fi

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/otto-snapshots.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

echo "==> Rendering snapshots into $SCRATCH"
"$BINARY" --snapshot "$SCRATCH"

if ! compgen -G "$SCRATCH/$flavor/*.png" >/dev/null; then
  echo "error: the $flavor build rendered no scenes into $flavor/" >&2
  exit 1
fi
mkdir -p "$OUTPUT/$flavor"
cp "$SCRATCH/$flavor"/*.png "$OUTPUT/$flavor/"
echo "==> Snapshots written to $OUTPUT/$flavor"
