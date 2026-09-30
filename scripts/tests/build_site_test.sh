#!/usr/bin/env bash
#
# build_site_test.sh: tests for scripts/build_site.sh (SPEC-v2 §14.13.1, §14.17.2).
#
# Every build writes to a temporary SITE_OUT; fixture site folders are temporary SITE_DIRs built from
# site/ and scripts/tests/fixtures/site/. No network and no Vercel. The flag-0 builds run with a PATH
# that has no node on it.
#
# Usage: bash scripts/tests/build_site_test.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURES="$ROOT/scripts/tests/fixtures/site"
GOLDEN="$FIXTURES/index.noncommercial.golden.html"
BUILD="$ROOT/scripts/build_site.sh"
DENY='purchase|sold|paid app|price|\$[0-9]|polar|gumroad|checkout|trial|/download|/thanks|appcast|license key'
DURING_LAUNCH="2026-10-15T12:00:00Z"
AFTER_LAUNCH="2026-10-20T07:00:00Z"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/build-site-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { echo "ok   $1"; }
fail() {
  echo "FAIL $1" >&2
  failures=$((failures + 1))
}
check() {
  local name="$1"
  shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}

# A PATH with the tools build_site.sh uses and without node.
NO_NODE_BIN="$WORK/no-node-bin"
mkdir -p "$NO_NODE_BIN"
for tool in awk cat cp cut dirname du find grep mkdir rm sed sort; do
  tool_path="$(command -v "$tool")" || {
    echo "error: $tool is not installed" >&2
    exit 1
  }
  ln -s "$tool_path" "$NO_NODE_BIN/$tool"
done
if PATH="$NO_NODE_BIN" command -v node >/dev/null 2>&1; then
  echo "error: the node-free PATH still finds node" >&2
  exit 1
fi

# build OUT [NAME=value ...]: runs build_site.sh into OUT with SITE_URL=http://localhost:8000 and no
# Vercel variables; the assignments after OUT override anything else. Output goes to OUT.log.
build() {
  local out="$1"
  shift
  env -u VERCEL_PROJECT_PRODUCTION_URL -u SITE_NOW -u SITE_DIR -u SITE_COMMERCIAL -u SITE_SPONSORS \
    SITE_URL=http://localhost:8000 SITE_OUT="$out" "$@" "$BASH" "$BUILD" > "$out.log" 2>&1
}

# fixture_site DIR [commerce file]: a site folder with today's pages, the fixture release.json and
# appcast.xml, a stray draft, and the given commerce.json (the complete fixture by default).
fixture_site() {
  local dir="$1" commerce="${2:-$FIXTURES/commerce.complete.json}"
  mkdir -p "$dir"
  cp "$ROOT"/site/*.html "$ROOT/site/styles.css" "$ROOT/site/script.js" "$dir/"
  cp "$commerce" "$dir/commerce.json"
  cp "$FIXTURES/release.json" "$FIXTURES/appcast.xml" "$dir/"
  printf '<p>draft</p>\n' > "$dir/draft.html"
  printf 'notes\n' > "$dir/notes.txt"
}

# Lists OUT's files outside media/, one per line, sorted.
top_files() { (cd "$1" && find . -type f ! -path './media/*' | sed 's#^\./##' | sort); }

same_media() { diff -r -x '*.mp4' "$ROOT/docs/media" "$1/media" > /dev/null && [[ -z "$(find "$1/media" -name '*.mp4')" ]]; }
no_markers() { ! grep -qE '<!-- [a-z]+:(begin|end) -->' "$1"/*.html; }
deny_grep_empty() { [[ -z "$(grep -rIiE "$DENY" "$1"/*.html "$1"/*.css "$1"/*.js)" ]]; }
log_has() { grep -qF -- "$2" "$1.log"; }
no_page_links_appcast() { ! grep -qi 'appcast' "$1"/*.html; }
no_tokens_left() { ! grep -q '{{' "$1"/*.html; }
every_page_has_legal_footer() {
  local page
  for page in "$1"/*.html; do
    grep -q 'not affiliated with' "$page" || return 1
  done
}

# Prints the lines inside the sponsors blocks of site/index.html, as the build would render them.
sponsor_lines() {
  awk '
    { line = $0; sub(/^[ \t]+/, "", line); sub(/[ \t\r]+$/, "", line) }
    line == "<!-- sponsors:begin -->" { inside = 1; next }
    line == "<!-- sponsors:end -->" { inside = 0; next }
    inside { print }
  ' "$ROOT/site/index.html" | sed 's#__SITE_URL__#http://localhost:8000#g'
}

# SITE_SPONSORS=1 adds exactly the sponsors blocks' lines to the golden page and changes nothing else.
sponsors_only_add_sponsor_lines() {
  local diff_out
  diff_out="$(diff "$GOLDEN" "$1/index.html")"
  [[ -n "$diff_out" ]] || return 1
  ! grep -qE '^(<|---|[0-9]+(,[0-9]+)?[cd])' <<< "$diff_out" || return 1
  [[ "$(grep '^> ' <<< "$diff_out" | sed 's/^> //')" == "$(sponsor_lines)" ]]
}

echo "== SITE_COMMERCIAL=0 SITE_SPONSORS=0, no node on PATH"
out="$WORK/flag0"
check "flag-0 build succeeds without node" build "$out" SITE_COMMERCIAL=0 SITE_SPONSORS=0 PATH="$NO_NODE_BIN"
check "flag-0 output holds exactly index.html, styles.css, script.js" \
  test "$(top_files "$out")" == "$(printf 'index.html\nscript.js\nstyles.css')"
check "flag-0 media/ is docs/media/" same_media "$out"
check "flag-0 index.html is byte-identical to the golden file" cmp -s "$GOLDEN" "$out/index.html"
check "flag-0 pages keep no block markers" no_markers "$out"
check "flag-0 deny grep over html, css and js is empty" deny_grep_empty "$out"
check "flag-0 styles.css and script.js are copied unchanged" \
  eval 'cmp -s "$ROOT/site/styles.css" "$out/styles.css" && cmp -s "$ROOT/site/script.js" "$out/script.js"'

# The promo video never autoplays from markup (script.js starts it once on screen), preloads nothing,
# and offers a lighter source to narrow screens.
video_tag() { tr '\n' ' ' < "$1/index.html" | grep -oE '<video[^>]*>'; }
video_waits_for_script() {
  local tag
  tag="$(video_tag "$1")" || return 1
  ! grep -qE '[[:space:]]autoplay([[:space:]=>]|$)' <<< "$tag" && grep -qF 'preload="none"' <<< "$tag"
}
video_has_narrow_source() { grep -qE '<source src="https://[a-z0-9]+\.public\.blob\.vercel-storage\.com/film/[^"]+\.mp4" type="video/mp4" media="\(max-width: [0-9]+px\)">' "$1/index.html"; }
# Every video the page plays comes from the downloads Blob store under film/<version>/, and none from media/.
# Their size and silence are checked before upload (scripts/upload_film.sh), since the files aren't in git.
page_videos_hosted() {
  local refs
  refs="$(grep -oE '<source src="[^"]+\.(mp4|webm)"' "$1/index.html" | sed -E 's/<source src="([^"]+)"/\1/' | sort -u)"
  [[ -n "$refs" ]] || return 1
  ! grep -qE 'src="media/[^"]+\.(mp4|webm)"' "$1/index.html" || return 1
  while IFS= read -r ref; do
    [[ "$ref" =~ ^https://[a-z0-9]+\.public\.blob\.vercel-storage\.com/film/[0-9]+\.[0-9]+\.[0-9]+(-[a-z0-9]+)?/[a-z0-9-]+\.mp4$ ]] ||
      { echo "$ref is not a hosted film URL" >&2; return 1; }
  done <<< "$refs"
}
check "the promo video waits for script.js and preloads nothing" video_waits_for_script "$out"
check "the promo video offers narrow screens a lighter source" video_has_narrow_source "$out"
check "every video the page plays comes from the downloads store" page_videos_hosted "$out"

echo "== defaults"
out="$WORK/defaults"
check "no flags set builds the flag-0 page" build "$out" PATH="$NO_NODE_BIN"
check "the default build equals the golden file" cmp -s "$GOLDEN" "$out/index.html"

echo "== SITE_SPONSORS=1"
out="$WORK/sponsors"
check "sponsors build succeeds without node" build "$out" SITE_COMMERCIAL=0 SITE_SPONSORS=1 PATH="$NO_NODE_BIN"
check "sponsors page differs from the golden only by the sponsors blocks" sponsors_only_add_sponsor_lines "$out"
check "sponsors deny grep is empty" deny_grep_empty "$out"

echo "== fixture site folder with an appcast (the rollback case)"
site="$WORK/site-rollback"
fixture_site "$site"
out="$WORK/rollback"
check "rollback build succeeds without node" build "$out" SITE_DIR="$site" SITE_COMMERCIAL=0 PATH="$NO_NODE_BIN"
check "appcast.xml is copied byte for byte" cmp -s "$FIXTURES/appcast.xml" "$out/appcast.xml"
check "no page links to the appcast" no_page_links_appcast "$out"
check "rollback output holds only the explicit list" \
  test "$(top_files "$out")" == "$(printf 'appcast.xml\nindex.html\nscript.js\nstyles.css')"
check "commerce.json, release.json, drafts and commercial pages never ship" \
  eval '[[ ! -e "$out/commerce.json" && ! -e "$out/release.json" && ! -e "$out/draft.html" && ! -e "$out/notes.txt" && ! -e "$out/buy.html" ]]'
check "rollback deny grep is empty" deny_grep_empty "$out"
check "rollback index.html equals the golden file" cmp -s "$GOLDEN" "$out/index.html"

echo "== SITE_COMMERCIAL=1 with placeholder values"
# A fixed all-placeholder commerce.json, so the check doesn't depend on which real values are committed.
fixture_site "$WORK/site-placeholders" "$FIXTURES/commerce.placeholders.json"
out="$WORK/placeholders"
if build "$out" SITE_COMMERCIAL=1 SITE_DIR="$WORK/site-placeholders"; then
  fail "placeholder commerce.json fails the build"
else
  pass "placeholder commerce.json fails the build"
fi
for field in siteHost downloadsHost seller.legalName seller.supportEmail seller.governingLaw polar.checkoutURL \
  polar.portalURL launch.startsAt launch.endsAt launch.timeZone launch.checkoutURL legal.approved legal.effectiveDate; do
  check "the failure names $field" log_has "$out" "commerce.json: $field: "
done

echo "== SITE_COMMERCIAL=1 with complete fixtures, during launch week"
site="$WORK/site-commercial"
fixture_site "$site"
out="$WORK/launch"
check "commercial build succeeds" build "$out" SITE_DIR="$site" SITE_COMMERCIAL=1 SITE_NOW="$DURING_LAUNCH"
check "commercial output holds index, the six pages, css, js and the appcast" test "$(top_files "$out")" == \
  "$(printf 'appcast.xml\nbuy.html\ndownload.html\nindex.html\nprivacy.html\nrefunds.html\nscript.js\nstyles.css\nterms.html\nthanks.html')"
check "no {{ is left in any page" no_tokens_left "$out"
check "no block marker is left in any page" no_markers "$out"
check "the appcast is unchanged" cmp -s "$FIXTURES/appcast.xml" "$out/appcast.xml"
check "every page carries the shared legal footer" every_page_has_legal_footer "$out"
check "the launch line renders in the fixture's time zone" \
  grep -qF 'Launch price: $14 until Oct 19, 11:59 pm PDT.' "$out/buy.html"
check "the buy button shows the launch label" grep -qF '<span class="btn__label">Buy Otto, $14</span>' "$out/buy.html"
check "the buy button points at the launch checkout" \
  grep -qF 'href="https://buy.polar.sh/polar_cl_fixtureLaunch" data-ends-at="2026-10-20T06:59:00.000Z"' "$out/buy.html"
check "the tax line sits on the buy page" \
  grep -qF 'In the US, Canada and India, sales tax is added at checkout. Elsewhere the price includes VAT or GST.' "$out/buy.html"
check "draft files never ship" eval '[[ ! -e "$out/draft.html" && ! -e "$out/notes.txt" && ! -e "$out/commerce.json" ]]'

echo "== SITE_COMMERCIAL=1 after launch week"
out="$WORK/regular"
check "commercial build after the launch succeeds" build "$out" SITE_DIR="$site" SITE_COMMERCIAL=1 SITE_NOW="$AFTER_LAUNCH"
check "no launch pricing after endsAt" eval '! grep -qE "Launch price|data-ends-at|\\\$14" "$out"/*.html'
check "the buy button shows the regular label" grep -qF '<span class="btn__label">Buy Otto, $19</span>' "$out/buy.html"
check "the buy button points at the regular checkout" \
  grep -qF '<a class="btn btn--primary" href="https://buy.polar.sh/polar_cl_fixtureRegular">' "$out/buy.html"
check "every page after the launch carries the shared legal footer" every_page_has_legal_footer "$out"

echo "== SITE_COMMERCIAL=1 without node"
out="$WORK/commercial-no-node"
if build "$out" SITE_DIR="$site" SITE_COMMERCIAL=1 PATH="$NO_NODE_BIN"; then
  fail "a commercial build without node fails"
else
  check "a commercial build without node fails and says why" log_has "$out" "needs node"
fi

echo "== flag values"
for assignment in SITE_COMMERCIAL=2 SITE_COMMERCIAL=yes SITE_COMMERCIAL=true SITE_SPONSORS=2 SITE_SPONSORS=on; do
  out="$WORK/flag-${assignment//=/-}"
  if build "$out" "$assignment" PATH="$NO_NODE_BIN"; then
    fail "$assignment fails the build"
  else
    check "$assignment fails the build and names the flag" log_has "$out" "${assignment%%=*} must be 0 or 1"
  fi
done

echo "== guards"
site="$WORK/site-unclosed"
fixture_site "$site"
printf '<!-- commercial:begin -->\n<p>left open</p>\n' >> "$site/index.html"
out="$WORK/unclosed"
if build "$out" SITE_DIR="$site" PATH="$NO_NODE_BIN"; then
  fail "an unclosed block fails the flag-0 build"
else
  check "an unclosed block fails the flag-0 build" log_has "$out" "commercial block is never closed"
fi

site="$WORK/site-dmg"
fixture_site "$site"
: > "$site/Otto-1.1.0.dmg"
out="$WORK/dmg"
if build "$out" SITE_DIR="$site" PATH="$NO_NODE_BIN"; then
  fail "a .dmg in the site folder fails the build"
else
  check "a .dmg in the site folder fails the build" log_has "$out" "contains a .dmg"
fi
check "no .dmg is committed under site/" test -z "$(find "$ROOT/site" -name '*.dmg')"
check "bash -n scripts/build_site.sh" bash -n "$BUILD"

echo
if [[ $failures -eq 0 ]]; then
  echo "build_site_test.sh: all checks passed"
else
  echo "build_site_test.sh: $failures check(s) failed" >&2
  exit 1
fi
