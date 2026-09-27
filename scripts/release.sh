#!/usr/bin/env bash
#
# release.sh — build a signed, installable Otto release.
#
#   scripts/release.sh                 # build, sign, package, (notarize), checksum
#   scripts/release.sh --smoke-test    # …then mount the DMG and launch Otto from it in --demo mode
#   scripts/release.sh --plain-dmg     # skip the Finder window layout (no background, default icons)
#   scripts/release.sh --skip-build    # repackage the last Release build instead of rebuilding
#
# Steps:
#   1. Builds the Release configuration, signed with your "Developer ID Application" identity,
#      hardened runtime and a secure timestamp. Verifies the signature (codesign --deep --strict).
#   2. Notarizes and staples the app, if OTTO_NOTARY_PROFILE is set.
#   3. Packages Otto.app into a drag-to-install disk image: volume "Otto", the app next to an
#      Applications shortcut, a custom background and volume icon. Signs the DMG.
#   4. Notarizes and staples the DMG, if OTTO_NOTARY_PROFILE is set.
#   5. Writes dist/Otto-<version>.dmg, dist/Otto.dmg (stable name for the "latest" download link),
#      dist/Otto-<version>.dSYM.zip and dist/SHA256SUMS.txt.
#
# Environment:
#   OTTO_SIGN_IDENTITY   Signing identity: a SHA-1 hash or a (partial) name. Default: the first
#                        "Developer ID Application" identity in your keychains.
#   OTTO_TEAM_ID         Team ID. Default: read from the identity's name ("… (ABCDE12345)").
#   OTTO_NOTARY_PROFILE  notarytool keychain profile (see docs/RELEASING.md). Unset = skip notarization.
#
# Needs Xcode, XcodeGen and the macOS built-ins (hdiutil, codesign, osascript, tiffutil). No other
# dependencies. See docs/RELEASING.md for the whole release checklist.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SMOKE_TEST=0
PLAIN_DMG=0
SKIP_BUILD=0
for argument in "$@"; do
  case "$argument" in
    --smoke-test) SMOKE_TEST=1 ;;
    --plain-dmg) PLAIN_DMG=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    -h|--help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown option $argument (see --help)" >&2; exit 2 ;;
  esac
done

step() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

# MARK: - Preflight

for tool in xcodegen xcodebuild hdiutil codesign osascript tiffutil ditto shasum swift; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool not found (install Xcode and XcodeGen: brew install xcodegen)"
done

VERSION="$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' project.yml | head -n 1)"
BUILD_NUMBER="$(sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' project.yml | head -n 1)"
[[ -n "$VERSION" ]] || fail "could not read MARKETING_VERSION from project.yml"

WORK="$ROOT/build/release"
DERIVED="$WORK/DerivedData"
DIST="$ROOT/dist"
APP_NAME="Otto"
VOLUME_NAME="Otto"
DMG_VERSIONED="$DIST/$APP_NAME-$VERSION.dmg"
DMG_STABLE="$DIST/$APP_NAME.dmg"

# Finder window layout (points). Must match scripts/make_dmg_background.swift.
WINDOW_WIDTH=660
WINDOW_HEIGHT=420
TITLE_BAR_HEIGHT=28
ICON_SIZE=128
APP_POSITION="170, 196"
APPLICATIONS_POSITION="490, 196"

# Resolve the signing identity to its SHA-1 hash: the same certificate often shows up in more than
# one keychain, and a hash is never ambiguous.
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if [[ -n "${OTTO_SIGN_IDENTITY:-}" ]]; then
  IDENTITY_LINE="$(grep -F -- "$OTTO_SIGN_IDENTITY" <<<"$IDENTITIES" | head -n 1 || true)"
else
  IDENTITY_LINE="$(grep -F '"Developer ID Application' <<<"$IDENTITIES" | head -n 1 || true)"
fi
[[ -n "$IDENTITY_LINE" ]] || fail "no Developer ID Application identity found in your keychains (security find-identity -v -p codesigning). See docs/RELEASING.md."
IDENTITY_HASH="$(awk '{print $2}' <<<"$IDENTITY_LINE")"
IDENTITY_NAME="$(sed -n 's/.*"\(.*\)".*/\1/p' <<<"$IDENTITY_LINE")"
TEAM_ID="${OTTO_TEAM_ID:-$(sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p' <<<"$IDENTITY_NAME")}"
[[ -n "$TEAM_ID" ]] || fail "could not read the team ID from \"$IDENTITY_NAME\"; set OTTO_TEAM_ID"
[[ "$IDENTITY_NAME" == "Developer ID Application"* ]] \
  || echo "warning: \"$IDENTITY_NAME\" is not a Developer ID identity; Gatekeeper will reject this build on other Macs." >&2

NOTARY_PROFILE="${OTTO_NOTARY_PROFILE:-}"

echo "Otto $VERSION ($BUILD_NUMBER)"
echo "  identity:     $IDENTITY_NAME [$IDENTITY_HASH]"
echo "  team:         $TEAM_ID"
if [[ -n "$NOTARY_PROFILE" ]]; then
  echo "  notarization: keychain profile \"$NOTARY_PROFILE\""
else
  echo "  notarization: SKIPPED (OTTO_NOTARY_PROFILE is not set)"
fi

# MARK: - Cleanup

MOUNTED_DEVICES=()
SMOKE_PID=""
cleanup() {
  if [[ -n "$SMOKE_PID" ]] && kill -0 "$SMOKE_PID" 2>/dev/null; then
    kill "$SMOKE_PID" 2>/dev/null || true
    sleep 0.5
    kill -9 "$SMOKE_PID" 2>/dev/null || true
  fi
  for device in ${MOUNTED_DEVICES[@]+"${MOUNTED_DEVICES[@]}"}; do
    hdiutil detach "$device" -quiet 2>/dev/null || hdiutil detach "$device" -force -quiet 2>/dev/null || true
  done
}
trap cleanup EXIT

detach() {
  local device="$1" attempt
  for attempt in 1 2 3 4 5; do
    if hdiutil detach "$device" -quiet 2>/dev/null; then break; fi
    if [[ $attempt == 5 ]]; then hdiutil detach "$device" -force -quiet; fi
    sleep 1
  done
  local remaining=()
  for mounted in ${MOUNTED_DEVICES[@]+"${MOUNTED_DEVICES[@]}"}; do
    [[ "$mounted" == "$device" ]] || remaining+=("$mounted")
  done
  MOUNTED_DEVICES=(${remaining[@]+"${remaining[@]}"})
}

# Attaches a disk image and prints "<device>\t<mount point>".
attach() {
  local image="$1"; shift
  local plist index device mount_point
  local errors="$WORK/hdiutil-attach.err"
  if ! plist="$(hdiutil attach "$image" -noverify -noautoopen -plist "$@" 2>"$errors")"; then
    cat "$errors" >&2
    return 1
  fi
  for index in 0 1 2 3 4 5 6 7; do
    mount_point="$(plutil -extract "system-entities.$index.mount-point" raw -o - - <<<"$plist" 2>/dev/null || true)"
    if [[ -n "$mount_point" ]]; then
      device="$(plutil -extract "system-entities.$index.dev-entry" raw -o - - <<<"$plist")"
      # Detach the whole image (the parent disk), not just the mounted slice.
      printf '%s\t%s\n' "${device%s[0-9]*}" "$mount_point"
      return 0
    fi
  done
  return 1
}

# Submits a file to the notary service and waits; fails with the notary log if it is not accepted.
notarize() {
  local file="$1" output submission_id
  note "submitting $(basename "$file") to Apple's notary service (this usually takes a few minutes)…"
  output="$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist)" \
    || fail "notarytool submit failed: $output"
  submission_id="$(plutil -extract id raw -o - - <<<"$output" 2>/dev/null || true)"
  if [[ "$(plutil -extract status raw -o - - <<<"$output" 2>/dev/null || true)" != "Accepted" ]]; then
    echo "$output" >&2
    [[ -n "$submission_id" ]] && xcrun notarytool log "$submission_id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    fail "notarization of $(basename "$file") was not accepted (submission $submission_id)"
  fi
  note "accepted (submission $submission_id)"
}

# MARK: - 1. Build

APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
DSYM="$DERIVED/Build/Products/Release/$APP_NAME.app.dSYM"
BUILD_LOG="$WORK/xcodebuild.log"

if [[ $SKIP_BUILD == 1 ]]; then
  step "Reusing the last Release build (--skip-build)"
  [[ -d "$APP" ]] || fail "no previous Release build at $APP; run without --skip-build"
  mkdir -p "$DIST"
else
  step "Generating Otto.xcodeproj"
  xcodegen generate --quiet --spec "$ROOT/project.yml"

  step "Building Otto $VERSION (Release, Developer ID, hardened runtime)"
  rm -rf "$WORK"
  mkdir -p "$WORK" "$DIST"
  # Command-line settings override Config/Signing.xcconfig and Config/Local.xcconfig, so nothing
  # signing-related is committed. CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO keeps get-task-allow out
  # (the notary service rejects it).
  if ! xcodebuild \
    -project Otto.xcodeproj \
    -scheme Otto \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$IDENTITY_HASH" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    ENABLE_HARDENED_RUNTIME=YES \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    clean build >"$BUILD_LOG" 2>&1; then
    grep -E 'error:|\*\* BUILD FAILED' "$BUILD_LOG" | head -n 40 >&2 || tail -n 40 "$BUILD_LOG" >&2
    fail "Release build failed (full log: $BUILD_LOG)"
  fi
  grep -E 'warning:' "$BUILD_LOG" | sort -u | head -n 20 || true
fi

[[ -d "$APP" ]] || fail "build finished but $APP is missing"
note "built $APP"

BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$BUILT_VERSION" == "$VERSION" ]] || fail "built app reports version $BUILT_VERSION, expected $VERSION"

verify_app() {
  local app="$1" details entitlements
  codesign --verify --deep --strict --verbose=2 "$app" 2>&1 | sed 's/^/    /'
  details="$(codesign --display --verbose=4 "$app" 2>&1)"
  grep -q "^Authority=$IDENTITY_NAME\$" <<<"$details" || fail "$app is not signed by $IDENTITY_NAME"
  grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]*\(.*runtime.*\)' <<<"$details" || fail "$app does not have the hardened runtime flag"
  grep -q '^Timestamp=' <<<"$details" || fail "$app has no secure timestamp"
  entitlements="$(codesign --display --entitlements - --xml "$app" 2>/dev/null || true)"
  if grep -q 'get-task-allow' <<<"$entitlements"; then fail "$app carries com.apple.security.get-task-allow"; fi
  grep '^Authority=' <<<"$details" | sed 's/^/    /'
  grep -E '^(CodeDirectory|Timestamp|TeamIdentifier)' <<<"$details" | sed 's/^/    /'
}

step "Verifying the app signature"
verify_app "$APP"

# MARK: - 2. Notarize the app (optional)

if [[ -n "$NOTARY_PROFILE" ]]; then
  step "Notarizing Otto.app"
  APP_ZIP="$WORK/$APP_NAME-$VERSION-app.zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$APP_ZIP"
  notarize "$APP_ZIP"
  xcrun stapler staple "$APP" | sed 's/^/    /'
  xcrun stapler validate "$APP" | sed 's/^/    /'
fi

if [[ -d "$DSYM" ]]; then
  ditto -c -k --sequesterRsrc --keepParent "$DSYM" "$DIST/$APP_NAME-$VERSION.dSYM.zip"
fi

# MARK: - 3. Disk image

step "Packaging the disk image"
STAGING="$WORK/dmg-staging"
RW_DMG="$WORK/$APP_NAME-rw.dmg"
rm -rf "$STAGING" "$RW_DMG" "$WORK/background"
mkdir -p "$STAGING/.background"
ditto "$APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"

HAS_BACKGROUND=0
if [[ $PLAIN_DMG == 0 ]]; then
  if swift "$ROOT/scripts/make_dmg_background.swift" "$WORK/background" >"$WORK/background.log" 2>&1 \
    && tiffutil -cathidpicheck "$WORK/background/background.png" "$WORK/background/background@2x.png" \
         -out "$STAGING/.background/background.tiff" >/dev/null 2>&1; then
    HAS_BACKGROUND=1
    note "rendered the background (660×420 @1x/@2x)"
  else
    echo "warning: could not render the DMG background (see $WORK/background.log); using a plain layout" >&2
  fi
fi
[[ $HAS_BACKGROUND == 1 ]] || rmdir "$STAGING/.background"

SIZE_MB=$(( $(du -sm "$STAGING" | awk '{print $1}') + 24 ))
hdiutil create -quiet -volname "$VOLUME_NAME" -srcfolder "$STAGING" -fs HFS+ \
  -format UDRW -size "${SIZE_MB}m" -ov "$RW_DMG"

IFS=$'\t' read -r RW_DEVICE RW_MOUNT < <(attach "$RW_DMG" -readwrite)
[[ -n "$RW_DEVICE" && -d "$RW_MOUNT" ]] || fail "could not mount $RW_DMG"
MOUNTED_DEVICES+=("$RW_DEVICE")
note "mounted the writable image at $RW_MOUNT"

LAYOUT_DONE=0
if [[ $HAS_BACKGROUND == 1 ]]; then
  note "arranging the Finder window"
  WINDOW_LEFT=200
  WINDOW_TOP=120
  WINDOW_RIGHT=$(( WINDOW_LEFT + WINDOW_WIDTH ))
  WINDOW_BOTTOM=$(( WINDOW_TOP + WINDOW_HEIGHT + TITLE_BAR_HEIGHT ))
  # Finder is addressed by the mount point's path (not the volume name), so another mounted
  # "Otto" volume can't be picked up by mistake. `perl alarm` bounds a hung Apple Event.
  if perl -e 'alarm 90; exec @ARGV' osascript - "$RW_MOUNT" >"$WORK/finder.log" 2>&1 <<APPLESCRIPT
on run argv
  set mountPath to item 1 of argv
  tell application "Finder"
    set theDisk to item ((POSIX file mountPath) as alias)
    open theDisk
    delay 1
    set theWindow to container window of theDisk
    set current view of theWindow to icon view
    set toolbar visible of theWindow to false
    set statusbar visible of theWindow to false
    set sidebar width of theWindow to 0
    set bounds of theWindow to {$WINDOW_LEFT, $WINDOW_TOP, $WINDOW_RIGHT, $WINDOW_BOTTOM}
    set viewOptions to icon view options of theWindow
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to $ICON_SIZE
    set text size of viewOptions to 13
    set label position of viewOptions to bottom
    set shows item info of viewOptions to false
    set shows icon preview of viewOptions to false
    set background picture of viewOptions to file ".background:background.tiff" of theDisk
    set position of item "$APP_NAME.app" of theDisk to {$APP_POSITION}
    set position of item "Applications" of theDisk to {$APPLICATIONS_POSITION}
    close theWindow
    open theDisk
    update theDisk without registering applications
    delay 2
    set appPosition to position of item "$APP_NAME.app" of theDisk
    set applicationsPosition to position of item "Applications" of theDisk
    set windowBounds to bounds of container window of theDisk
    log "window bounds: " & (item 1 of windowBounds) & "," & (item 2 of windowBounds) & "," & (item 3 of windowBounds) & "," & (item 4 of windowBounds)
    log "app icon at: " & (item 1 of appPosition) & "," & (item 2 of appPosition) & "; Applications at: " & (item 1 of applicationsPosition) & "," & (item 2 of applicationsPosition)
    close container window of theDisk
  end tell
end run
APPLESCRIPT
  then
    # Finder writes .DS_Store lazily; wait for it.
    for _ in $(seq 1 20); do
      [[ -f "$RW_MOUNT/.DS_Store" ]] && break
      sleep 0.5
    done
    if [[ -f "$RW_MOUNT/.DS_Store" ]]; then
      LAYOUT_DONE=1
      note "window layout saved"
    fi
  fi
  if [[ $LAYOUT_DONE == 0 ]]; then
    echo "warning: Finder could not lay out the window (Automation permission for Finder? see $WORK/finder.log)." >&2
    echo "         Falling back to a plain disk image: app + Applications shortcut, default Finder view." >&2
    rm -rf "$RW_MOUNT/.background" "$RW_MOUNT/.DS_Store"
  fi
fi

# Volume icon: .VolumeIcon.icns plus the kHasCustomIcon Finder flag on the volume root. Added last:
# an icon file that is already on the volume during the Finder layout pass goes missing from the image.
if [[ -f "$APP/Contents/Resources/AppIcon.icns" ]]; then
  cp "$APP/Contents/Resources/AppIcon.icns" "$RW_MOUNT/.VolumeIcon.icns"
  if SETFILE="$(xcrun -f SetFile 2>/dev/null)"; then
    "$SETFILE" -a C "$RW_MOUNT" || echo "warning: could not set the volume icon flag" >&2
  else
    echo "warning: SetFile not found; the volume keeps the generic disk icon" >&2
  fi
fi

rm -rf "$RW_MOUNT/.fseventsd" "$RW_MOUNT/.Trashes" 2>/dev/null || true
chmod -Rf go-w "$RW_MOUNT" 2>/dev/null || true
sync
detach "$RW_DEVICE"

rm -f "$DMG_VERSIONED" "$DMG_STABLE"
hdiutil convert "$RW_DMG" -quiet -format UDZO -imagekey zlib-level=9 -o "$DMG_VERSIONED"
rm -f "$RW_DMG"

step "Signing the disk image"
codesign --force --sign "$IDENTITY_HASH" --timestamp "$DMG_VERSIONED"
codesign --verify --strict --verbose=2 "$DMG_VERSIONED" 2>&1 | sed 's/^/    /'
hdiutil verify -quiet "$DMG_VERSIONED"
note "checksum verified"

# MARK: - 4. Notarize the DMG (optional)

if [[ -n "$NOTARY_PROFILE" ]]; then
  step "Notarizing $(basename "$DMG_VERSIONED")"
  notarize "$DMG_VERSIONED"
  xcrun stapler staple "$DMG_VERSIONED" | sed 's/^/    /'
  xcrun stapler validate "$DMG_VERSIONED" | sed 's/^/    /'
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_VERSIONED" 2>&1 | sed 's/^/    /'
else
  step "Skipping notarization (OTTO_NOTARY_PROFILE is not set)"
  note "This build is signed but NOT notarized: Gatekeeper on other Macs will refuse to open it."
  note "Set up a notary profile (docs/RELEASING.md) before publishing a release."
fi

# MARK: - 5. Outputs

cp -c "$DMG_VERSIONED" "$DMG_STABLE" 2>/dev/null || cp "$DMG_VERSIONED" "$DMG_STABLE"
(
  cd "$DIST"
  checksum_files=("$(basename "$DMG_VERSIONED")" "$(basename "$DMG_STABLE")")
  [[ -f "$APP_NAME-$VERSION.dSYM.zip" ]] && checksum_files+=("$APP_NAME-$VERSION.dSYM.zip")
  shasum -a 256 "${checksum_files[@]}" >SHA256SUMS.txt
)

# MARK: - Smoke test (optional)

if [[ $SMOKE_TEST == 1 ]]; then
  step "Smoke test: mounting $(basename "$DMG_STABLE") and launching Otto --demo from it"
  IFS=$'\t' read -r SMOKE_DEVICE SMOKE_MOUNT < <(attach "$DMG_STABLE" -readonly -nobrowse)
  [[ -n "$SMOKE_DEVICE" && -d "$SMOKE_MOUNT" ]] || fail "could not mount $DMG_STABLE"
  MOUNTED_DEVICES+=("$SMOKE_DEVICE")
  note "mounted at $SMOKE_MOUNT: $(ls -A "$SMOKE_MOUNT" | tr '\n' ' ')"
  [[ -L "$SMOKE_MOUNT/Applications" ]] || fail "the Applications shortcut is missing"
  verify_app "$SMOKE_MOUNT/$APP_NAME.app"
  "$SMOKE_MOUNT/$APP_NAME.app/Contents/MacOS/$APP_NAME" --demo >"$WORK/smoke.log" 2>&1 &
  SMOKE_PID=$!
  sleep 5
  if ! kill -0 "$SMOKE_PID" 2>/dev/null; then
    wait "$SMOKE_PID" || true
    cat "$WORK/smoke.log" >&2
    fail "Otto exited within 5 s of launching from the disk image"
  fi
  note "Otto (pid $SMOKE_PID) is running from the disk image; stopping it"
  kill "$SMOKE_PID" 2>/dev/null || true
  for _ in $(seq 1 30); do kill -0 "$SMOKE_PID" 2>/dev/null || break; sleep 0.1; done
  kill -9 "$SMOKE_PID" 2>/dev/null || true
  wait "$SMOKE_PID" 2>/dev/null || true
  SMOKE_PID=""
  detach "$SMOKE_DEVICE"
  note "passed"
fi

step "Done"
ls -lh "$DIST" | sed 's/^/    /'
echo
sed 's/^/    /' "$DIST/SHA256SUMS.txt"
if [[ -z "$NOTARY_PROFILE" ]]; then
  echo
  echo "    Not notarized. Don't publish this DMG; see docs/RELEASING.md."
fi
