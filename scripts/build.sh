#!/usr/bin/env bash
#
# build.sh — generate Otto.xcodeproj with XcodeGen and build the Debug app into ./build.
#
#   scripts/build.sh
#
# Output: build/Build/Products/Debug/Otto.app
# Signing comes from Config/Signing.xcconfig (ad hoc by default; add Config/Local.xcconfig to use your
# own identity). Set OTTO_ADHOC_SIGNING=1 to force an ad hoc signature.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen is not installed. Install it with: brew install xcodegen" >&2
  exit 1
fi
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild not found. Install Xcode and run: sudo xcode-select -s /Applications/Xcode.app" >&2
  exit 1
fi

echo "==> Generating Otto.xcodeproj"
xcodegen generate --quiet --spec "$ROOT/project.yml"

signing_overrides=()
if [[ "${OTTO_ADHOC_SIGNING:-0}" == "1" ]]; then
  echo "==> Signing ad hoc (OTTO_ADHOC_SIGNING=1)"
  signing_overrides=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=)
fi

echo "==> Building Otto (Debug)"
# -quiet prints only warnings and errors; pipefail/errexit make a failed build fail this script.
xcodebuild \
  -project Otto.xcodeproj \
  -scheme Otto \
  -configuration Debug \
  -derivedDataPath build \
  -quiet \
  ${signing_overrides[@]+"${signing_overrides[@]}"} \
  build

APP="$ROOT/build/Build/Products/Debug/Otto.app"
if [[ ! -d "$APP" ]]; then
  echo "error: build finished but $APP is missing" >&2
  exit 1
fi
echo "==> Built $APP"
