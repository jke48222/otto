#!/usr/bin/env bash
#
# build_site.sh: assemble the Otto website into _site/.
#
# Vercel runs this through vercel.json. The page lives in site/, and its images and video live in
# docs/media/, which the README uses too. Both are copied into one folder, so git keeps one copy of the
# media.
#
# Usage:
#   scripts/build_site.sh                               # local build for localhost.
#   SITE_URL=https://example.com scripts/build_site.sh  # absolute URLs on that domain.
#   python3 -m http.server 8000 --directory _site       # preview the result.
#
# Absolute URLs (canonical, og:url, og:image) come from SITE_URL, else from Vercel's
# VERCEL_PROJECT_PRODUCTION_URL (the project's production domain, set in every Vercel build), else
# http://localhost:8000.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/_site"

site_url="${SITE_URL:-}"
if [[ -z "$site_url" && -n "${VERCEL_PROJECT_PRODUCTION_URL:-}" ]]; then
  site_url="https://${VERCEL_PROJECT_PRODUCTION_URL}"
fi
site_url="${site_url:-http://localhost:8000}"
site_url="${site_url%/}"

rm -rf "$OUT"
mkdir -p "$OUT/media"
cp -R "$ROOT/site/." "$OUT/"
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

[[ $missing -eq 0 ]] || exit 1
echo "Built $OUT for $site_url ($(du -sh "$OUT" | cut -f1))"
