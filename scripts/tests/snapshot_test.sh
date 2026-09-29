#!/usr/bin/env bash
#
# snapshot_test.sh: tests for scripts/snapshot.sh.
#
# Every case renders with a stand-in renderer (OTTO_SNAPSHOT_BINARY, a small bash script that writes PNG-named
# files, crashes, times out or reports a scene error on cue) into a temporary OTTO_SNAPSHOT_OUTPUT that already
# holds "old" pictures. Nothing builds or runs Otto, and docs/snapshots is never touched.
#
# Usage: bash scripts/tests/snapshot_test.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SNAPSHOT="$ROOT/scripts/snapshot.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/snapshot-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/tmp"

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

# A stand-in renderer. Each run appends a line to $WORK/<name>.runs; `plan` lists one behavior per run (the last
# one repeats): ok, crash (dies on SIGSEGV after writing some PNGs), timeout (the watchdog's message, exit 1),
# fail (exit 1, no message), scene-error (a scene error line, exit 0), empty (exit 0, no PNGs).
make_renderer() {
  local name="$1"; shift
  local path="$WORK/$name"
  {
    echo '#!/usr/bin/env bash'
    echo "plan=($*)"
    echo "runs=\"$WORK/$name.runs\""
    cat <<'EOF'
[[ "$1" == "--snapshot" && -n "${2:-}" ]] || { echo "bad args: $*" >&2; exit 64; }
dir="$2"
echo run >>"$runs"
n=$(wc -l <"$runs" | tr -d ' ')
index=$((n - 1))
(( index < ${#plan[@]} )) || index=$((${#plan[@]} - 1))
mkdir -p "$dir"
case "${plan[$index]}" in
  ok)
    echo "new $n" >"$dir/closed.png"
    echo "new $n" >"$dir/open-window-chip.png"
    mkdir -p "$dir/licensing"
    echo "new $n" >"$dir/licensing/gate.png"
    ;;
  crash)
    echo "partial" >"$dir/closed.png"
    kill -SEGV $$
    ;;
  timeout)
    echo "partial" >"$dir/closed.png"
    echo "Snapshot rendering timed out." >&2
    exit 1
    ;;
  fail)
    exit 1
    ;;
  scene-error)
    echo "new" >"$dir/closed.png"
    echo "snapshot error: Couldn't set up open-window-chip.png: The window chip wasn't offered." >&2
    ;;
  empty)
    ;;
esac
exit 0
EOF
  } >"$path"
  chmod +x "$path"
  echo "$path"
}

# A fresh output folder holding the pictures of an earlier run.
make_output() {
  local out="$WORK/$1-out"
  rm -rf "$out"
  mkdir -p "$out/licensing"
  echo old >"$out/closed.png"
  echo old >"$out/open-window-chip.png"
  echo old >"$out/removed-scene.png"
  echo old >"$out/licensing/gate.png"
  echo "$out"
}

run_snapshot() {
  local renderer="$1" out="$2"; shift 2
  output=$(TMPDIR="$WORK/tmp" OTTO_SNAPSHOT_BINARY="$renderer" OTTO_SNAPSHOT_OUTPUT="$out" \
    bash "$SNAPSHOT" "$@" 2>&1)
  status=$?
}

runs_of() { if [[ -f "$WORK/$1.runs" ]]; then wc -l <"$WORK/$1.runs" | tr -d ' '; else echo 0; fi; }
content() { cat "$1" 2>/dev/null; }
untouched() {
  [[ "$(content "$1/closed.png")" == old && "$(content "$1/open-window-chip.png")" == old \
    && "$(content "$1/licensing/gate.png")" == old && "$(content "$1/removed-scene.png")" == old ]] \
    && [[ $(find "$1" -type f | wc -l | tr -d ' ') -eq 4 ]]
}

# MARK: - Syntax and usage

check "bash -n snapshot.sh" 'bash -n "$SNAPSHOT"'

renderer=$(make_renderer usage ok)
out=$(make_output usage)
run_snapshot "$renderer" "$out" --free
check "an unknown option exits 2" '[[ $status -eq 2 ]]'
run_snapshot "$renderer" "$out" --paid --licensing
check "two options exit 2" '[[ $status -eq 2 ]]'
output=$(OTTO_SNAPSHOT_ATTEMPTS=0 OTTO_SNAPSHOT_BINARY="$renderer" OTTO_SNAPSHOT_OUTPUT="$out" bash "$SNAPSHOT" 2>&1)
status=$?
check "OTTO_SNAPSHOT_ATTEMPTS=0 exits 2" '[[ $status -eq 2 ]]'
check "usage errors run nothing and copy nothing" '[[ $(runs_of usage) -eq 0 ]] && untouched "$out"'

out=$(make_output missing)
run_snapshot "$WORK/no-such-renderer" "$out"
check "a missing renderer exits 1 and copies nothing" '[[ $status -eq 1 ]] && untouched "$out"'

# MARK: - A clean run

renderer=$(make_renderer clean ok)
out=$(make_output clean)
run_snapshot "$renderer" "$out"
check "a clean run exits 0" '[[ $status -eq 0 ]]'
check "a clean run renders once" '[[ $(runs_of clean) -eq 1 ]]'
check "a clean run replaces the source pictures" \
  '[[ "$(content "$out/closed.png")" == "new 1" && "$(content "$out/open-window-chip.png")" == "new 1" ]]'
check "a source run leaves the flavor folders alone" '[[ "$(content "$out/licensing/gate.png")" == old ]]'
check "a picture no scene drew is kept and named" \
  '[[ -f "$out/removed-scene.png" ]] && printf "%s\n" "$output" | grep -q "removed-scene.png"'
check "the temporary folder is removed" '[[ -z "$(ls -A "$WORK/tmp")" ]]'

renderer=$(make_renderer flavor ok)
out=$(make_output flavor)
run_snapshot "$renderer" "$out" --licensing
check "--licensing exits 0" '[[ $status -eq 0 ]]'
check "--licensing copies only its own folder" \
  '[[ "$(content "$out/licensing/gate.png")" == "new 1" && "$(content "$out/closed.png")" == old ]]'

# MARK: - Crashes and timeouts are retried in a fresh process

renderer=$(make_renderer crash-once crash ok)
out=$(make_output crash-once)
run_snapshot "$renderer" "$out"
check "a crash followed by a clean run exits 0" '[[ $status -eq 0 ]]'
check "a crash is retried once" '[[ $(runs_of crash-once) -eq 2 ]]'
check "the crash is named" 'printf "%s\n" "$output" | grep -q "SIGSEGV (exit 139)"'
check "the retried run's pictures are copied" \
  '[[ "$(content "$out/closed.png")" == "new 2" && "$(content "$out/open-window-chip.png")" == "new 2" ]]'

renderer=$(make_renderer timeout-once timeout ok)
out=$(make_output timeout-once)
run_snapshot "$renderer" "$out"
check "a watchdog timeout followed by a clean run exits 0" '[[ $status -eq 0 && $(runs_of timeout-once) -eq 2 ]]'
check "the timeout is named" 'printf "%s\n" "$output" | grep -q "watchdog"'

renderer=$(make_renderer always-crash crash)
out=$(make_output always-crash)
run_snapshot "$renderer" "$out"
check "a renderer that always crashes fails" '[[ $status -ne 0 ]]'
check "it is tried OTTO_SNAPSHOT_ATTEMPTS times (default 3)" '[[ $(runs_of always-crash) -eq 3 ]]'
check "a crashed run copies nothing, not even its partial pictures" 'untouched "$out"'

renderer=$(make_renderer attempts crash)
out=$(make_output attempts)
output=$(OTTO_SNAPSHOT_ATTEMPTS=1 OTTO_SNAPSHOT_BINARY="$renderer" OTTO_SNAPSHOT_OUTPUT="$out" bash "$SNAPSHOT" 2>&1)
status=$?
check "OTTO_SNAPSHOT_ATTEMPTS=1 renders once" '[[ $status -ne 0 && $(runs_of attempts) -eq 1 ]] && untouched "$out"'

# MARK: - Other failures are not retried and copy nothing

renderer=$(make_renderer scene-error scene-error ok)
out=$(make_output scene-error)
run_snapshot "$renderer" "$out"
check "a scene error fails even though the renderer exits 0" '[[ $status -ne 0 ]]'
check "a scene error is not retried" '[[ $(runs_of scene-error) -eq 1 ]]'
check "a scene error copies nothing" 'untouched "$out"'
check "the scene error reaches the terminal" 'printf "%s\n" "$output" | grep -q "snapshot error: Couldn.t set up"'

renderer=$(make_renderer plain-fail fail ok)
out=$(make_output plain-fail)
run_snapshot "$renderer" "$out"
check "exit 1 without the watchdog message fails without a retry" \
  '[[ $status -ne 0 && $(runs_of plain-fail) -eq 1 ]] && untouched "$out"'

renderer=$(make_renderer empty empty)
out=$(make_output empty)
run_snapshot "$renderer" "$out"
check "a run that draws nothing fails and copies nothing" '[[ $status -ne 0 ]] && untouched "$out"'

renderer=$(make_renderer paid-missing ok)
out=$(make_output paid-missing)
run_snapshot "$renderer" "$out" --paid
check "--paid without a paid/ folder fails and copies nothing" \
  '[[ $status -ne 0 ]] && untouched "$out" && printf "%s\n" "$output" | grep -q "no scenes into paid/"'

if [[ $failures -gt 0 ]]; then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all snapshot.sh checks passed"
