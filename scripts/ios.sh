#!/usr/bin/env bash
#
# ios.sh — generate OttoiOS.xcodeproj and build or test Otto for iPhone on a simulator.
#
#   scripts/ios.sh [build|test] [--simulator UDID] [--snapshots DIR]
#
#   build        builds the app and its widget extension (the default)
#   test         builds, then runs the iPhone tests
#   --simulator  the simulator to use; default: the newest iPhone runtime, preferring a Pro model
#   --snapshots  with test, also writes a PNG of every screen into DIR
#
# Output: build/ios/Build/Products/Debug-iphonesimulator/Otto.app, and for test build/iOSTestResults.xcresult.
# Simulator builds need no signing. To run on your own iPhone, open OttoiOS.xcodeproj in Xcode after setting
# DEVELOPMENT_TEAM in Config/Local.xcconfig (see Config/Signing-iOS.xcconfig).
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

action=build
simulator="${OTTO_SIMULATOR_UDID:-}"
snapshots=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    build|test) action="$1" ;;
    --simulator) simulator="${2:?--simulator needs a UDID}"; shift ;;
    --snapshots) snapshots="${2:?--snapshots needs a directory}"; shift ;;
    -h|--help) sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 64 ;;
  esac
  shift
done

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen is not installed. Install it with: brew install xcodegen" >&2
  exit 1
fi
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild not found. Install Xcode and run: sudo xcode-select -s /Applications/Xcode.app" >&2
  exit 1
fi

echo "==> Generating OttoiOS.xcodeproj"
xcodegen generate --quiet --spec "$ROOT/project-ios.yml"

if [[ -z "$simulator" ]]; then
  simulator=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
best = None
for runtime, devices in json.load(sys.stdin)["devices"].items():
    if ".iOS-" not in runtime:
        continue
    version = tuple(int(part) for part in runtime.rsplit(".iOS-", 1)[1].split("-"))
    for device in devices:
        if device.get("isAvailable") and device["name"].startswith("iPhone"):
            key = (version, "Pro" in device["name"], device["name"])
            if best is None or key > best[0]:
                best = (key, device["udid"])
print(best[1] if best else "")
')
fi
if [[ -z "$simulator" ]]; then
  echo "error: no iPhone simulator is available. Add one in Xcode → Settings → Components." >&2
  exit 1
fi
echo "==> Using simulator $(xcrun simctl list devices | grep "$simulator" | sed 's/^ *//')"

arguments=(
  -project OttoiOS.xcodeproj
  -scheme OttoiOS
  -configuration Debug
  -destination "id=$simulator"
  -derivedDataPath build/ios
  # Keep compiling after the first error, so one run reports every file that fails.
  -IDEBuildingContinueBuildingAfterErrors=YES
  CODE_SIGNING_ALLOWED=NO
)

if [[ "$action" == "test" ]]; then
  rm -rf build/iOSTestResults.xcresult
  if [[ -n "$snapshots" ]]; then
    mkdir -p "$snapshots"
    export TEST_RUNNER_OTTO_SNAPSHOT_DIR
    TEST_RUNNER_OTTO_SNAPSHOT_DIR="$(cd "$snapshots" && pwd)"
    echo "==> Writing snapshots to $TEST_RUNNER_OTTO_SNAPSHOT_DIR"
  fi
  echo "==> Testing Otto for iPhone"
  # A test that hangs fails by name after two minutes instead of holding the run until the job times out.
  xcodebuild "${arguments[@]}" -resultBundlePath build/iOSTestResults.xcresult \
    -test-timeouts-enabled YES -default-test-execution-time-allowance 120 test
else
  echo "==> Building Otto for iPhone (Debug)"
  xcodebuild "${arguments[@]}" build
fi
