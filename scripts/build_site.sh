#!/usr/bin/env bash
#
# build_site.sh: assemble the Otto website into _site/.
#
# Vercel runs this through vercel.json. The page lives in site/, and its images and video live in
# docs/media/, which the README uses too. Only an explicit list of files is copied: index.html,
# styles.css, script.js, docs/media/** (as media/), site/appcast.xml whenever it exists, and, with
# SITE_COMMERCIAL=1, the six commercial pages. Anything else under site/ (commerce.json, release.json,
# a stray draft) never ships.
#
# Usage:
#   scripts/build_site.sh                               # local build for localhost.
#   SITE_URL=https://example.com scripts/build_site.sh  # absolute URLs on that domain.
#   python3 -m http.server 8000 --directory _site       # preview the result.
#
# Flags (Vercel project environment variables; each is 0, the default, or 1; anything else fails):
#   SITE_COMMERCIAL  1 renders the commercial blocks and pages with scripts/site_render.mjs, which
#                    needs node and a complete site/commerce.json, site/release.json and
#                    site/appcast.xml. 0 keeps the noncommercial blocks, strips the rest with awk and
#                    needs no node.
#   SITE_SPONSORS    1 keeps the sponsors blocks.
#
# Test overrides: SITE_DIR (default site/) and SITE_OUT (default _site/).
#
# Absolute URLs (canonical, og:url, og:image) come from SITE_URL, else from Vercel's
# VERCEL_PROJECT_PRODUCTION_URL (the project's production domain, set in every Vercel build), else
# http://localhost:8000.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITE_DIR="${SITE_DIR:-$ROOT/site}"
OUT="${SITE_OUT:-$ROOT/_site}"

commercial="${SITE_COMMERCIAL:-0}"
sponsors="${SITE_SPONSORS:-0}"
flag_error=0
for flag in "SITE_COMMERCIAL=$commercial" "SITE_SPONSORS=$sponsors"; do
  case "${flag#*=}" in
    0 | 1) ;;
    *)
      echo "error: ${flag%%=*} must be 0 or 1, not '${flag#*=}'" >&2
      flag_error=1
      ;;
  esac
done
[[ $flag_error -eq 0 ]] || exit 1

if [[ ! -f "$SITE_DIR/index.html" ]]; then
  echo "error: $SITE_DIR/index.html does not exist" >&2
  exit 1
fi

# Release disk images live in dist/ and Vercel Blob, never in the repository.
if [[ -n "$(find "$SITE_DIR" -name '*.dmg' -print)" ]]; then
  echo "error: $SITE_DIR contains a .dmg; release downloads belong in Vercel Blob, not the site" >&2
  exit 1
fi

site_url="${SITE_URL:-}"
if [[ -z "$site_url" && -n "${VERCEL_PROJECT_PRODUCTION_URL:-}" ]]; then
  site_url="https://${VERCEL_PROJECT_PRODUCTION_URL}"
fi
site_url="${site_url:-http://localhost:8000}"
site_url="${site_url%/}"

# Keeps the noncommercial blocks (and the sponsors blocks with SITE_SPONSORS=1) and drops every
# commercial block. Each marker sits on a line of its own, and that whole line is removed, so the page
# otherwise stays byte for byte what site/index.html holds.
strip_to_noncommercial() {
  awk -v sponsors="$sponsors" '
    function fail(message) {
      printf "error: %s:%d: %s\n", FILENAME, FNR, message > "/dev/stderr"
      failed = 1
      exit 1
    }
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      sub(/[ \t\r]+$/, "", line)
      if (line ~ /^<!-- [a-z]+:(begin|end) -->$/) {
        name = line
        sub(/^<!-- /, "", name)
        sub(/:.*$/, "", name)
        if (line ~ /:begin -->$/) {
          depth++
          stack[depth] = name
          if (skip == 0) {
            if (name == "commercial") {
              skip = depth
            } else if (name == "sponsors") {
              if (sponsors != 1) skip = depth
            } else if (name != "noncommercial") {
              fail("a " name " block must sit inside a commercial block")
            }
          }
        } else {
          if (depth == 0 || stack[depth] != name) fail("unexpected " name ":end")
          if (skip == depth) skip = 0
          depth--
        }
        next
      }
      if (skip == 0) print
    }
    END {
      if (failed) exit 1
      if (depth != 0) {
        printf "error: %s: the %s block is never closed\n", FILENAME, stack[depth] > "/dev/stderr"
        exit 1
      }
    }
  ' "$1"
}

rm -rf "$OUT"
mkdir -p "$OUT/media"
cp "$SITE_DIR/styles.css" "$SITE_DIR/script.js" "$OUT/"

if [[ "$commercial" == 1 ]]; then
  if ! command -v node >/dev/null 2>&1; then
    echo "error: SITE_COMMERCIAL=1 needs node to render the commercial pages" >&2
    exit 1
  fi
  node "$ROOT/scripts/site_render.mjs" --render --site "$SITE_DIR" --out "$OUT" --sponsors "$sponsors"
else
  strip_to_noncommercial "$SITE_DIR/index.html" > "$OUT/index.html"
fi

# The update feed ships whenever it exists, whatever the flag: copies already sold keep getting updates
# even if the site stops selling. It is copied byte for byte because its signature covers the bytes.
if [[ -f "$SITE_DIR/appcast.xml" ]]; then
  cp "$SITE_DIR/appcast.xml" "$OUT/appcast.xml"
fi

cp -R "$ROOT/docs/media/." "$OUT/media/"
find "$OUT" -name .DS_Store -delete

# Fill in the absolute URLs. sed -i.bak works with both BSD (macOS) and GNU (Vercel) sed.
for page in "$OUT"/*.html; do
  sed -i.bak "s#__SITE_URL__#${site_url}#g" "$page"
  rm -f "$page.bak"
done

# Every media file the page references must exist, or the build fails.
missing=0
while IFS= read -r ref; do
  [[ -f "$OUT/$ref" ]] || {
    echo "error: the site references $ref, but docs/${ref} does not exist" >&2
    missing=1
  }
done < <(grep -hoE 'media/[A-Za-z0-9_./-]+\.(png|jpg|jpeg|gif|mp4|webm|svg|webp)' "$OUT"/*.html "$OUT"/*.css | sort -u)

if grep -q '__SITE_URL__' "$OUT"/*.html; then
  echo "error: __SITE_URL__ was not replaced" >&2
  missing=1
fi

if grep -lE '<!-- [a-z]+:(begin|end) -->' "$OUT"/*.html >&2; then
  echo "error: the pages above still carry block markers" >&2
  missing=1
fi

[[ $missing -eq 0 ]] || exit 1
echo "Built $OUT for $site_url ($(du -sh "$OUT" | cut -f1))"
