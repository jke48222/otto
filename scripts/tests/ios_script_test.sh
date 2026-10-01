#!/usr/bin/env bash
#
# ios_script_test.sh: tests for scripts/ios.sh's arguments.
#
# Only the argument handling runs: every case either prints help or stops on a bad argument before XcodeGen or
# Xcode is touched, so this runs anywhere bash does.
#
# Usage: bash scripts/tests/ios_script_test.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IOS="$ROOT/scripts/ios.sh"

failures=0
output=""
status=0
pass() { echo "ok   $1"; }
fail() {
  echo "FAIL $1" >&2
  printf '%s\n' "$output" | sed 's/^/    | /' >&2
  failures=$((failures + 1))
}
check() {
  if eval "$2"; then pass "$1"; else fail "$1"; fi
}
run() {
  output="$(bash "$IOS" "$@" 2>&1)"
  status=$?
}

run --help
check "help exits 0" '[[ $status -eq 0 ]]'
check "help shows the usage line" '[[ "$output" == *"scripts/ios.sh [build|test]"* ]]'
check "help names the snapshot option" '[[ "$output" == *"--snapshots"* ]]'
check "help has no comment markers" '[[ "$output" != *"# "* ]]'
check "help stops before the code" '[[ "$output" != *"set -euo"* ]]'

run --bogus
check "an unknown argument exits 64" '[[ $status -eq 64 ]]'
check "an unknown argument is named" '[[ "$output" == *"unknown argument: --bogus"* ]]'

run test --snapshots
check "--snapshots without a directory fails" '[[ $status -ne 0 ]]'
check "--snapshots without a directory says why" '[[ "$output" == *"--snapshots needs a directory"* ]]'

run build --simulator
check "--simulator without a UDID fails" '[[ $status -ne 0 ]]'
check "--simulator without a UDID says why" '[[ "$output" == *"--simulator needs a UDID"* ]]'

if [[ $failures -gt 0 ]]; then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "All ios.sh checks passed."
