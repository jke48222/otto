#!/usr/bin/env bash
#
# publish.sh
# Otto
#
# Publishes a notarized paid release: uploads the DMG, writes the signed appcast and release.json, and renders the
# Homebrew cask (SPEC-v2 §14.12.2). Paid flavor only; the Setapp zip and Gumroad's file are uploaded by hand.
#
#   scripts/publish.sh --version <v> [--tap-dir <path>] [--no-tap] [--dry-run]
#
#   --version <v>      the release to publish; dist/paid/Otto-<v>.dmg must exist, notarized and stapled
#   --tap-dir <path>   a clean checkout of jke48222/homebrew-tap (default: ../homebrew-tap)
#   --no-tap           don't render the cask (the first publish, at gate HM3: the tap repo comes at HM5)
#   --dry-run          everything except the upload; outputs go to build/publish/<v>/, never site/ or the tap
#
# Steps:
#   1. CHANGELOG.md's section for <v> → build/publish/<v>/archives/Otto-<v>.html (the embedded release notes)
#   2. stage the DMG next to it; start from the committed appcast (a missing one is the first release, 0 items)
#   3. generate_appcast signs the new item and the feed with the EdDSA key in the login Keychain (account ed25519)
#   4. xmllint checks the new item and that every older item is still there
#   5. vercel blob put releases/Otto-<v>.dmg (never overwrites), then a HEAD and a full download are checked
#   6. site/appcast.xml (a byte copy) and site/release.json
#   7. Casks/otto.rb in the tap, checked with brew style when Homebrew is installed
#   8. prints the commits to make, and the GitHub release command once https://<siteHost>/buy answers 200
#
# Environment:
#   OTTO_SITE_DIR   where commerce.json, appcast.xml and release.json live (default: site)
#   SPARKLE_BIN     directory with Sparkle's tools, instead of the paid build's Swift packages (tests)
#
# Exit: 0 done, 1 a failed check, 2 a usage error. See docs/RELEASING.md, "Publishing a paid release".
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=lib/sparkle_tools.sh
. "$ROOT/scripts/lib/sparkle_tools.sh"

usage() {
  sed -n '6,31p' "$0" | sed 's/^# \{0,1\}//'
}

usage_error() {
  printf 'error: %s\n' "$*" >&2
  echo "usage: scripts/publish.sh --version <v> [--tap-dir <path>] [--no-tap] [--dry-run]" >&2
  exit 2
}

VERSION=""
TAP_DIR=""
NO_TAP=0
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || usage_error "--version needs a value"
      VERSION="$2"
      shift 2
      ;;
    --version=*) VERSION="${1#--version=}"; shift ;;
    --tap-dir)
      [[ $# -ge 2 ]] || usage_error "--tap-dir needs a path"
      TAP_DIR="$2"
      shift 2
      ;;
    --tap-dir=*) TAP_DIR="${1#--tap-dir=}"; shift ;;
    --no-tap) NO_TAP=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage_error "unknown option $1" ;;
  esac
done
[[ -n "$VERSION" ]] || usage_error "--version is required"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage_error "the version \"$VERSION\" isn't MAJOR.MINOR.PATCH"
if [[ $NO_TAP == 1 && -n "$TAP_DIR" ]]; then usage_error "--tap-dir and --no-tap don't go together"; fi

step() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

PROBLEMS=0
problem() {
  printf 'error: %s\n' "$*" >&2
  PROBLEMS=$((PROBLEMS + 1))
}

SITE_DIR="${OTTO_SITE_DIR:-site}"
[[ "$SITE_DIR" == /* ]] || SITE_DIR="$ROOT/$SITE_DIR"
[[ -n "$TAP_DIR" ]] || TAP_DIR="$ROOT/../homebrew-tap"
[[ "$TAP_DIR" == /* ]] || TAP_DIR="$ROOT/$TAP_DIR"
DIST="$ROOT/dist/paid"
DMG="$DIST/Otto-$VERSION.dmg"
CHECKSUMS="$DIST/SHA256SUMS.txt"
WORK="$ROOT/build/publish/$VERSION"
ARCHIVES="$WORK/archives"
STAGED_APPCAST="$WORK/appcast.xml"
BUILD_NUMBER="$(sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' project.yml | head -n 1)"

if [[ $DRY_RUN == 1 ]]; then
  OUT_APPCAST="$WORK/site/appcast.xml"
  OUT_RELEASE_JSON="$WORK/site/release.json"
  OUT_CASK="$WORK/tap/Casks/otto.rb"
else
  OUT_APPCAST="$SITE_DIR/appcast.xml"
  OUT_RELEASE_JSON="$SITE_DIR/release.json"
  OUT_CASK="$TAP_DIR/Casks/otto.rb"
fi

MOUNT_DEVICE=""
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/otto-publish.XXXXXX")"
cleanup() {
  if [[ -n "$MOUNT_DEVICE" ]]; then
    hdiutil detach "$MOUNT_DEVICE" -quiet 2>/dev/null || hdiutil detach "$MOUNT_DEVICE" -force -quiet 2>/dev/null || true
  fi
  rm -rf "$SCRATCH"
  return 0
}
trap cleanup EXIT

if [[ $DRY_RUN == 1 ]]; then
  echo "Publishing Otto $VERSION (dry run: no upload; outputs under build/publish/$VERSION)"
else
  echo "Publishing Otto $VERSION"
fi

# MARK: - Preflight

step "Preflight"

for tool in node xmllint curl shasum hdiutil plutil xcrun spctl vercel git; do
  command -v "$tool" >/dev/null 2>&1 || problem "$tool not found (it comes with Xcode, Node, git or the Vercel CLI: npm i -g vercel)."
done
[[ $PROBLEMS -eq 0 ]] || fail "install the missing tools above, then run publish.sh again"

[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || problem "project.yml: CURRENT_PROJECT_VERSION \"$BUILD_NUMBER\" isn't a positive whole number."

APP_VERSION=""
APP_BUILD=""
if [[ ! -f "$DMG" ]]; then
  if [[ -f "$DIST/Otto-$VERSION-UNNOTARIZED.dmg" ]]; then
    problem "only dist/paid/Otto-$VERSION-UNNOTARIZED.dmg exists. Unnotarized builds are never published: run scripts/release.sh --flavor paid with OTTO_NOTARY_PROFILE set."
  else
    problem "dist/paid/Otto-$VERSION.dmg doesn't exist. Build it with scripts/release.sh --flavor paid."
  fi
else
  if xcrun stapler validate "$DMG" >"$SCRATCH/stapler.log" 2>&1; then
    note "the DMG carries a stapled notarization ticket"
  else
    problem "xcrun stapler validate refused dist/paid/Otto-$VERSION.dmg: $(tr '\n' ' ' <"$SCRATCH/stapler.log")"
  fi
  if spctl --assess --type open --context context:primary-signature "$DMG" >/dev/null 2>&1; then
    note "Gatekeeper accepts the DMG"
  else
    problem "Gatekeeper (spctl --assess --type open --context context:primary-signature) refuses dist/paid/Otto-$VERSION.dmg."
  fi
  if ATTACHED="$(hdiutil attach "$DMG" -readonly -nobrowse -noautoopen -noverify -plist 2>/dev/null)"; then
    MOUNT_POINT=""
    for index in 0 1 2 3 4 5 6 7; do
      MOUNT_POINT="$(plutil -extract "system-entities.$index.mount-point" raw -o - - <<<"$ATTACHED" 2>/dev/null || true)"
      if [[ -n "$MOUNT_POINT" ]]; then
        DEVICE="$(plutil -extract "system-entities.$index.dev-entry" raw -o - - <<<"$ATTACHED")"
        MOUNT_DEVICE="${DEVICE%s[0-9]*}"
        break
      fi
    done
    if [[ -n "$MOUNT_POINT" ]]; then
      APP_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$MOUNT_POINT/Otto.app/Contents/Info.plist" 2>/dev/null || true)"
      APP_BUILD="$(plutil -extract CFBundleVersion raw -o - "$MOUNT_POINT/Otto.app/Contents/Info.plist" 2>/dev/null || true)"
    fi
    hdiutil detach "$MOUNT_DEVICE" -quiet 2>/dev/null || hdiutil detach "$MOUNT_DEVICE" -force -quiet 2>/dev/null || true
    MOUNT_DEVICE=""
    if [[ "$APP_VERSION" != "$VERSION" ]]; then
      problem "the app in dist/paid/Otto-$VERSION.dmg is version \"$APP_VERSION\", not $VERSION."
    elif [[ "$APP_BUILD" != "$BUILD_NUMBER" ]]; then
      problem "the app in the DMG is build \"$APP_BUILD\", but project.yml's CURRENT_PROJECT_VERSION is $BUILD_NUMBER."
    else
      note "the app inside is Otto $APP_VERSION ($APP_BUILD)"
    fi
  else
    problem "couldn't mount dist/paid/Otto-$VERSION.dmg to read the app's version."
  fi
  if [[ ! -f "$CHECKSUMS" ]] || ! grep -q " Otto-$VERSION.dmg\$" "$CHECKSUMS"; then
    problem "dist/paid/SHA256SUMS.txt has no line for Otto-$VERSION.dmg (release.sh writes it)."
  fi
fi

if vercel whoami >/dev/null 2>&1; then
  note "the Vercel CLI is logged in"
  if vercel blob list --limit 1 >/dev/null 2>&1; then
    note "the Blob store answers"
  else
    problem "vercel blob list --limit 1 failed: the public Blob store otto-downloads isn't reachable from this project (J9)."
  fi
else
  problem "vercel whoami failed: log in with vercel login (J9)."
fi

SITE_HOST=""
DOWNLOADS_HOST=""
if HOSTS="$(node "$ROOT/scripts/release_tools.mjs" hosts "$SITE_DIR/commerce.json" 2>&1)"; then
  SITE_HOST="$(awk '$1 == "siteHost" { print $2 }' <<<"$HOSTS")"
  DOWNLOADS_HOST="$(awk '$1 == "downloadsHost" { print $2 }' <<<"$HOSTS")"
  note "site https://$SITE_HOST, downloads https://$DOWNLOADS_HOST"
else
  printf '%s\n' "$HOSTS" >&2
  PROBLEMS=$((PROBLEMS + 1))
fi

GENERATE_APPCAST=""
if GENERATE_APPCAST="$(sparkle_tool generate_appcast "$ROOT")"; then
  note "generate_appcast: $GENERATE_APPCAST"
else
  PROBLEMS=$((PROBLEMS + 1))
fi

if [[ $NO_TAP == 0 ]]; then
  if ! git -C "$TAP_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    problem "$TAP_DIR isn't a checkout of jke48222/homebrew-tap (J15). Clone it there, pass --tap-dir, or --no-tap for the first publish."
  else
    TAP_REMOTE="$(git -C "$TAP_DIR" remote get-url origin 2>/dev/null || true)"
    [[ "$TAP_REMOTE" =~ jke48222/homebrew-tap(\.git)?$ ]] \
      || problem "$TAP_DIR's origin is \"$TAP_REMOTE\", not jke48222/homebrew-tap."
    [[ -z "$(git -C "$TAP_DIR" status --porcelain)" ]] \
      || problem "$TAP_DIR has uncommitted changes; commit or discard them first."
  fi
fi

if [[ $PROBLEMS -gt 0 ]]; then
  printf '\nPreflight found %d problem(s), listed above. Nothing was published.\n' "$PROBLEMS" >&2
  exit 1
fi

DMG_BYTES="$(stat -f %z "$DMG")"
DMG_SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"
EXPECTED_SHA256="$(awk -v name="Otto-$VERSION.dmg" '$2 == name || $2 == "*" name { print $1 }' "$CHECKSUMS")"
[[ "$DMG_SHA256" == "$EXPECTED_SHA256" ]] \
  || fail "dist/paid/Otto-$VERSION.dmg doesn't match its line in SHA256SUMS.txt; build it again with release.sh"
DMG_URL="https://$DOWNLOADS_HOST/releases/Otto-$VERSION.dmg"

# MARK: - 1. Release notes

step "1. Release notes from CHANGELOG.md"
rm -rf "$WORK"
mkdir -p "$ARCHIVES"
node "$ROOT/scripts/release_tools.mjs" changelog-html --version "$VERSION" "$ROOT/CHANGELOG.md" >"$ARCHIVES/Otto-$VERSION.html"
note "wrote build/publish/$VERSION/archives/Otto-$VERSION.html"

# MARK: - 2. Stage the archive and the current feed

step "2. Staging the DMG and the current appcast"
cp -c "$DMG" "$ARCHIVES/" 2>/dev/null || cp "$DMG" "$ARCHIVES/"
# The count of <item> elements in an appcast: xmllint with local names, so the sparkle: namespace doesn't matter.
item_count() {
  xmllint --xpath "count(//*[local-name()='item'])" "$1"
}
if [[ -f "$SITE_DIR/appcast.xml" ]]; then
  cp "$SITE_DIR/appcast.xml" "$STAGED_APPCAST"
  PREVIOUS_COUNT="$(item_count "$STAGED_APPCAST")" || fail "$SITE_DIR/appcast.xml isn't valid XML"
  note "updating the committed feed ($PREVIOUS_COUNT item(s))"
else
  PREVIOUS_COUNT=0
  note "no appcast.xml yet: this release starts the feed"
fi

# MARK: - 3. generate_appcast

step "3. Signing the update and the feed (generate_appcast)"
# --maximum-versions 0 keeps every older item: generate_appcast otherwise keeps only the newest 3, and a copy that
# is several versions behind still has to find its update. Step 4 stops if an item goes missing anyway.
"$GENERATE_APPCAST" \
  --download-url-prefix "https://$DOWNLOADS_HOST/releases/" \
  --link "https://$SITE_HOST/" \
  --embed-release-notes \
  --maximum-deltas 0 \
  --maximum-versions 0 \
  -o "$STAGED_APPCAST" \
  "$ARCHIVES" 2>&1 | sed 's/^/    /'
[[ -f "$STAGED_APPCAST" ]] || fail "generate_appcast didn't write $STAGED_APPCAST"

# MARK: - 4. Verify the feed

step "4. Checking the new appcast item"
xpath() {
  xmllint --xpath "$1" "$STAGED_APPCAST" 2>/dev/null || true
}
ITEM="//*[local-name()='item'][*[local-name()='version']='$BUILD_NUMBER' or *[local-name()='enclosure']/@*[local-name()='version']='$BUILD_NUMBER']"
[[ "$(xpath "count($ITEM)")" == 1 ]] || fail "the feed has no single item with sparkle:version $BUILD_NUMBER"
SHORT_VERSION="$(xpath "string($ITEM/*[local-name()='shortVersionString'])")"
[[ -n "$SHORT_VERSION" ]] || SHORT_VERSION="$(xpath "string($ITEM/*[local-name()='enclosure']/@*[local-name()='shortVersionString'])")"
[[ "$SHORT_VERSION" == "$VERSION" ]] || fail "the new item's sparkle:shortVersionString is \"$SHORT_VERSION\", not $VERSION"
MINIMUM_SYSTEM="$(xpath "string($ITEM/*[local-name()='minimumSystemVersion'])")"
[[ "$MINIMUM_SYSTEM" == 14.0 ]] || fail "the new item's sparkle:minimumSystemVersion is \"$MINIMUM_SYSTEM\", not 14.0"
ENCLOSURE_URL="$(xpath "string($ITEM/*[local-name()='enclosure']/@url)")"
[[ "$ENCLOSURE_URL" == "$DMG_URL" ]] || fail "the new item's enclosure URL is \"$ENCLOSURE_URL\", not $DMG_URL"
ENCLOSURE_LENGTH="$(xpath "string($ITEM/*[local-name()='enclosure']/@length)")"
[[ "$ENCLOSURE_LENGTH" == "$DMG_BYTES" ]] || fail "the new item's enclosure length is \"$ENCLOSURE_LENGTH\", not the DMG's $DMG_BYTES bytes"
ED_SIGNATURE="$(xpath "string($ITEM/*[local-name()='enclosure']/@*[local-name()='edSignature'])")"
[[ -n "$ED_SIGNATURE" ]] || fail "the new item has no sparkle:edSignature (is the EdDSA key in the login Keychain? J6)"
grep -q '<!-- sparkle-signatures:' "$STAGED_APPCAST" \
  || fail "the feed has no trailing sparkle-signatures comment, so apps that require a signed feed would refuse it"
NEW_COUNT="$(item_count "$STAGED_APPCAST")"
EXPECTED_COUNT=$(( PREVIOUS_COUNT + 1 ))
[[ "$NEW_COUNT" == "$EXPECTED_COUNT" ]] \
  || fail "the feed has $NEW_COUNT item(s), expected $EXPECTED_COUNT ($PREVIOUS_COUNT before plus this release). generate_appcast dropped or duplicated an item; nothing was uploaded."
note "item $BUILD_NUMBER ($VERSION): $DMG_URL, $DMG_BYTES bytes, EdDSA-signed; $NEW_COUNT item(s) in a signed feed"

# MARK: - 5. Upload

if [[ $DRY_RUN == 1 ]]; then
  step "5. Upload skipped (--dry-run)"
  note "would run: vercel blob put dist/paid/Otto-$VERSION.dmg --access public --pathname releases/Otto-$VERSION.dmg --cache-control-max-age 31536000"
else
  step "5. Uploading Otto-$VERSION.dmg to the Blob store"
  # Never --allow-overwrite: publishing a version twice must fail loudly, because shipped copies and the cask
  # already trust the first file's signature and checksum.
  vercel blob put "$DMG" --access public --pathname "releases/Otto-$VERSION.dmg" --cache-control-max-age 31536000 \
    | sed 's/^/    /'
  HEAD_OUTPUT="$(curl -sfI "$DMG_URL")" || fail "curl -sfI $DMG_URL failed after the upload"
  HEAD_STATUS="$(awk '{ sub(/\r$/, "") } toupper($1) ~ /^HTTP\// { status = $2 } END { print status }' <<<"$HEAD_OUTPUT")"
  HEAD_LENGTH="$(awk -F': *' 'tolower($1) == "content-length" { gsub(/\r/, "", $2); print $2 }' <<<"$HEAD_OUTPUT" | tail -n 1)"
  [[ "$HEAD_STATUS" == 200 && "$HEAD_LENGTH" == "$DMG_BYTES" ]] \
    || fail "$DMG_URL answers HTTP $HEAD_STATUS with content-length $HEAD_LENGTH, expected 200 and $DMG_BYTES"
  DOWNLOADED="$SCRATCH/Otto-$VERSION.dmg"
  curl -sfL -o "$DOWNLOADED" "$DMG_URL" || fail "couldn't download $DMG_URL"
  DOWNLOADED_SHA256="$(shasum -a 256 "$DOWNLOADED" | awk '{print $1}')"
  rm -f "$DOWNLOADED"
  [[ "$DOWNLOADED_SHA256" == "$EXPECTED_SHA256" ]] \
    || fail "the downloaded DMG's SHA-256 is $DOWNLOADED_SHA256, not $EXPECTED_SHA256 from SHA256SUMS.txt"
  note "$DMG_URL: 200, $DMG_BYTES bytes, SHA-256 matches SHA256SUMS.txt"
fi

# MARK: - 6. Site files

step "6. Writing appcast.xml and release.json"
mkdir -p "$(dirname "$OUT_APPCAST")"
# A byte copy: the feed's signature covers its exact bytes.
if [[ "$STAGED_APPCAST" != "$OUT_APPCAST" ]]; then cp "$STAGED_APPCAST" "$OUT_APPCAST"; fi
cmp -s "$STAGED_APPCAST" "$OUT_APPCAST" || fail "$OUT_APPCAST isn't a byte copy of the signed feed"
node "$ROOT/scripts/release_tools.mjs" release-json --version "$VERSION" --build "$BUILD_NUMBER" --dmg "$DMG" \
  --downloads-host "$DOWNLOADS_HOST" >"$OUT_RELEASE_JSON"
note "wrote ${OUT_APPCAST#"$ROOT"/} and ${OUT_RELEASE_JSON#"$ROOT"/}"

# MARK: - 7. Homebrew cask

if [[ $NO_TAP == 1 ]]; then
  step "7. Cask skipped (--no-tap)"
else
  step "7. Rendering Casks/otto.rb"
  mkdir -p "$(dirname "$OUT_CASK")"
  node "$ROOT/scripts/release_tools.mjs" cask "$OUT_RELEASE_JSON" "$SITE_DIR/commerce.json" >"$OUT_CASK"
  note "wrote $OUT_CASK"
  if command -v brew >/dev/null 2>&1; then
    # HOMEBREW_DEVELOPER for this one command, so brew style doesn't switch developer mode on for good.
    HOMEBREW_DEVELOPER=1 HOMEBREW_NO_AUTO_UPDATE=1 brew style --cask "$OUT_CASK" | sed 's/^/    /' \
      || fail "brew style --cask found problems in $OUT_CASK"
  else
    note "Homebrew isn't installed, so brew style was skipped; the tap's CI runs it on push"
  fi
fi

# MARK: - 8. Next steps

step "8. Next"
NOTES="$WORK/github-release-notes.md"
{
  awk -v version="$VERSION" '
    index($0, "## [" version "]") == 1 || index($0, "## " version) == 1 { found = 1; next }
    found && /^## / { exit }
    found { print }
  ' "$ROOT/CHANGELOG.md"
  echo
  echo "Get the signed app at https://$SITE_HOST/buy."
} >"$NOTES"

if [[ $DRY_RUN == 1 ]]; then
  echo "    Dry run: nothing was uploaded, and site/ and the tap are unchanged. A real run would then print:"
fi
echo "    git add ${OUT_APPCAST#"$ROOT"/} ${OUT_RELEASE_JSON#"$ROOT"/} && git commit -m \"Publish Otto $VERSION\" && git push"
echo "        (Vercel deploys on push; /appcast.xml is served as soon as it's committed)"
if [[ $NO_TAP == 0 ]]; then
  echo "    git -C $TAP_DIR add Casks/otto.rb && git -C $TAP_DIR commit -m \"Update Otto to $VERSION\" && git -C $TAP_DIR push"
fi
BUY_STATUS=""
if BUY_HEADERS="$(curl -sfI "https://$SITE_HOST/buy" 2>/dev/null)"; then
  BUY_STATUS="$(awk '{ sub(/\r$/, "") } toupper($1) ~ /^HTTP\// { status = $2 } END { print status }' <<<"$BUY_HEADERS")"
fi
if [[ "$BUY_STATUS" == 200 ]]; then
  echo "    gh release create v$VERSION --title \"Otto $VERSION\" --notes-file ${NOTES#"$ROOT"/}"
  echo "        (notes only; the last line says: Get the signed app at https://$SITE_HOST/buy.)"
else
  echo "    Create the GitHub release after SITE_COMMERCIAL=1 is live (docs/RELEASING.md, gate HM3 step 6)."
fi
