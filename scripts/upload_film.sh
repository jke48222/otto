#!/usr/bin/env bash
#
# upload_film.sh: puts the promo film and its two web cuts in the downloads Blob store, never in git.
#
#   scripts/upload_film.sh <version>        e.g. 1.1.0, or 1.1.0-launch for a re-cut of the same release
#
# Reads docs/media/otto-promo.mp4, otto-promo-web.mp4 and otto-promo-web-720.mp4 (written by
# scripts/make_video.sh and ignored by git), checks each against its budget, checks that the web cuts
# have no audio track, and uploads them to film/<version>/ in the store named by site/commerce.json's
# downloadsHost. A version's files are never overwritten: cut a new version instead. The README and
# site/index.html link to film/<version>/, so update those links when the version changes.
#
# Needs the Vercel CLI (npx vercel@latest), the store's token (BLOB_READ_WRITE_TOKEN, or .env.local from
# vercel link and vercel env pull), and ffprobe.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MEDIA="$ROOT/docs/media"
VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-z0-9]+)?$ ]] || { echo "usage: scripts/upload_film.sh <version, e.g. 1.1.0 or 1.1.0-launch>" >&2; exit 2; }

HOST="$(node "$ROOT/scripts/release_tools.mjs" hosts "$ROOT/site/commerce.json" | awk '$1 == "downloadsHost" {print $2}')"
[[ -n "$HOST" ]] || { echo "error: site/commerce.json has no downloadsHost (J9)" >&2; exit 1; }
# The store's read-write token: from the environment, or from the .env.local that `vercel env pull` writes
# for the linked project (git-ignored). It is passed to the CLI and never printed.
if [[ -z "${BLOB_READ_WRITE_TOKEN:-}" && -f "$ROOT/.env.local" ]]; then
  BLOB_READ_WRITE_TOKEN="$(sed -nE 's/^BLOB_READ_WRITE_TOKEN="?([^"]*)"?$/\1/p' "$ROOT/.env.local")"
fi
[[ -n "${BLOB_READ_WRITE_TOKEN:-}" ]] || { echo "error: no BLOB_READ_WRITE_TOKEN; run vercel link and vercel env pull .env.local (J9)" >&2; exit 1; }

# name budget-in-bytes must-be-silent
FILES=(
  "otto-promo.mp4 25000000 no"
  "otto-promo-web.mp4 8000000 yes"
  "otto-promo-web-720.mp4 3500000 yes"
)

for entry in "${FILES[@]}"; do
  read -r name budget silent <<< "$entry"
  file="$MEDIA/$name"
  [[ -f "$file" ]] || { echo "error: missing $file; run scripts/make_video.sh first" >&2; exit 1; }
  size=$(stat -f %z "$file")
  (( size <= budget )) || { echo "error: $name is $size bytes, over its $budget-byte budget" >&2; exit 1; }
  if [[ "$silent" == "yes" && -n "$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$file")" ]]; then
    echo "error: $name has an audio track; the site's cuts must be silent" >&2
    exit 1
  fi
done

for entry in "${FILES[@]}"; do
  read -r name _ _ <<< "$entry"
  url="https://$HOST/film/$VERSION/$name"
  if [[ "$(curl -s -o /dev/null -w '%{http_code}' --head "$url")" == "200" ]]; then
    echo "==> $name is already uploaded for $VERSION; leaving it as it is"
    continue
  fi
  echo "==> Uploading $name"
  npx -y vercel@latest blob put "$MEDIA/$name" --rw-token "$BLOB_READ_WRITE_TOKEN" --pathname "film/$VERSION/$name" --access public \
    --content-type video/mp4 --cache-control-max-age 31536000 > /dev/null
done

for entry in "${FILES[@]}"; do
  read -r name _ _ <<< "$entry"
  url="https://$HOST/film/$VERSION/$name"
  remote=$(curl -sI "$url" | awk 'tolower($1) == "content-length:" {gsub("\r", ""); print $2}')
  local_size=$(stat -f %z "$MEDIA/$name")
  [[ "$remote" == "$local_size" ]] || { echo "error: $url serves $remote bytes, expected $local_size" >&2; exit 1; }
  echo "ok   $url ($local_size bytes)"
done
