#!/usr/bin/env bash
#
# release.sh
# Otto
#
# Builds, signs, notarizes and packages the paid or Setapp build of Otto (SPEC-v2 §14.12.1).
#
#   scripts/release.sh --flavor paid|setapp [--smoke-test] [--plain-dmg] [--skip-build] [--no-notarize]
#                      [--preflight-only]
#
#   --flavor paid      the trial and paid download: OttoPaid.xcodeproj (Sparkle, licensing), packaged as a DMG
#   --flavor setapp    the Setapp build: OttoSetapp.xcodeproj, packaged as a zip for the Setapp developer account
#   --smoke-test       paid: mount the finished DMG, check the app inside and launch it with --demo for 5 s
#   --plain-dmg        paid: skip the Finder window layout (no background, default icon positions)
#   --skip-build       repackage the last Release build of this flavor instead of building again
#   --no-notarize      skip notarization; every output name ends in -UNNOTARIZED and publish.sh refuses it
#   --preflight-only   run the three preflight stages, then stop (exit 0 or 1)
#
# Preflight, before anything is built:
#   1. Local checks, all reported at once: tools, the Developer ID identity, OTTO_NOTARY_PROFILE, the commercial
#      configuration (scripts/check_commercial_config.sh), the versions in project.yml; paid also: the build number
#      against the committed appcast and site/commerce.json against Config/Commercial.xcconfig.
#   2. Paid, network and Keychain: the Polar API version probe, the Polar canary key (J20) and, with Gumroad on,
#      the Gumroad canary key (J21), each validated with the exact IDs this build ships.
#   3. Paid: Swift package resolution, then the Sparkle public key of this Mac's login Keychain must equal
#      OTTO_SPARKLE_PUBLIC_ED_KEY.
#
# Outputs (dist/ is ignored by git; never commit a build or attach one to a GitHub release):
#   dist/paid/Otto-<v>.dmg, dist/paid/Otto-<v>.dSYM.zip, dist/paid/SHA256SUMS.txt
#   dist/setapp/Otto-<v>-setapp.zip, dist/setapp/Otto-<v>-setapp.dSYM.zip, dist/setapp/SHA256SUMS.txt
#
# Environment:
#   OTTO_SIGN_IDENTITY   signing identity: a SHA-1 hash or part of a name. Default: the first "Developer ID
#                        Application" identity in your keychains
#   OTTO_TEAM_ID         team ID. Default: read from the identity's name ("… (ABCDE12345)")
#   OTTO_NOTARY_PROFILE  notarytool keychain profile (J7); required unless --no-notarize
#   OTTO_SITE_DIR        where commerce.json and appcast.xml are read (default: site)
#   SPARKLE_BIN          directory with Sparkle's tools, instead of the paid build's Swift packages (tests)
#
# Exit: 0 done (or preflight passed), 1 a failed check, 2 a usage error.
# Needs Xcode, XcodeGen, Node and the macOS built-ins. See docs/RELEASING.md for the whole release checklist.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=lib/sparkle_tools.sh
. "$ROOT/scripts/lib/sparkle_tools.sh"

usage() {
  sed -n '6,42p' "$0" | sed 's/^# \{0,1\}//'
}

usage_error() {
  printf 'error: %s\n' "$*" >&2
  echo "usage: scripts/release.sh --flavor paid|setapp [--smoke-test] [--plain-dmg] [--skip-build] [--no-notarize] [--preflight-only]" >&2
  exit 2
}

FLAVOR=""
SMOKE_TEST=0
PLAIN_DMG=0
SKIP_BUILD=0
NO_NOTARIZE=0
PREFLIGHT_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --flavor)
      [[ $# -ge 2 ]] || usage_error "--flavor needs a value (paid or setapp)"
      FLAVOR="$2"
      shift 2
      ;;
    --flavor=*) FLAVOR="${1#--flavor=}"; shift ;;
    --smoke-test) SMOKE_TEST=1; shift ;;
    --plain-dmg) PLAIN_DMG=1; shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --no-notarize) NO_NOTARIZE=1; shift ;;
    --preflight-only) PREFLIGHT_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage_error "unknown option $1" ;;
  esac
done

case "$FLAVOR" in
  paid|setapp) ;;
  "") usage_error "--flavor is required: paid or setapp (there is no source-flavor release)" ;;
  *) usage_error "unknown flavor $FLAVOR (paid or setapp)" ;;
esac
if [[ "$FLAVOR" == setapp && ( $SMOKE_TEST == 1 || $PLAIN_DMG == 1 ) ]]; then
  usage_error "--smoke-test and --plain-dmg apply to the paid DMG; the Setapp build is a zip"
fi

step() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

PROBLEMS=0
# problem MESSAGE: reports one preflight failure and keeps going, so each stage lists every problem at once.
problem() {
  printf 'error: %s\n' "$*" >&2
  PROBLEMS=$((PROBLEMS + 1))
}

# end_stage NAME: stops the release after a stage that reported problems.
end_stage() {
  if [[ $PROBLEMS -gt 0 ]]; then
    printf '\nPreflight %s found %d problem(s), listed above. Nothing was built.\n' "$1" "$PROBLEMS" >&2
    exit 1
  fi
  note "$1 passed"
}

SITE_DIR="${OTTO_SITE_DIR:-site}"
[[ "$SITE_DIR" == /* ]] || SITE_DIR="$ROOT/$SITE_DIR"
COMMERCIAL_XCCONFIG="Config/Commercial.xcconfig"
POLAR_HOST="api.polar.sh"
GUMROAD_VERIFY_URL="https://api.gumroad.com/v2/licenses/verify"
NETWORK_TMP=""

# xcconfig_value KEY: the Release value of KEY in Config/Commercial.xcconfig, read the way
# check_commercial_config.sh reads it (the [config=Release] line wins, // starts a comment, $() is removed).
xcconfig_value() {
  awk -v key="$1" -v conf="Release" '
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      if (line ~ /^#/) next
      cut = index(line, "//")
      if (cut > 0) line = substr(line, 1, cut - 1)
      eq = index(line, "=")
      if (eq == 0) next
      lhs = substr(line, 1, eq - 1)
      rhs = substr(line, eq + 1)
      gsub(/[ \t]+$/, "", lhs)
      gsub(/^[ \t]+|[ \t]+$/, "", rhs)
      gsub(/\$\(\)/, "", rhs)
      if (lhs == key) { plain = rhs; has_plain = 1 }
      else if (lhs == key "[config=" conf "]") { conditional = rhs; has_conditional = 1 }
    }
    END {
      if (has_conditional) print conditional
      else if (has_plain) print plain
    }' "$COMMERCIAL_XCCONFIG"
}

# json_fields SOURCE FIELD…: one line per dotted FIELD of the JSON in SOURCE (a file, or - for stdin); a missing or
# null field prints an empty line. Exit 1 when SOURCE isn't JSON.
json_fields() {
  node -e '
    const fs = require("fs");
    const [source, ...fields] = process.argv.slice(1);
    let data;
    try { data = JSON.parse(fs.readFileSync(source === "-" ? 0 : source, "utf8")); } catch { process.exit(1); }
    for (const field of fields) {
      let value = field.split(".").reduce((object, key) => (object === null || object === undefined ? undefined : object[key]), data);
      if (value === null || value === undefined) value = "";
      if (typeof value === "object") value = JSON.stringify(value);
      process.stdout.write(String(value).replace(/[\r\n]+/g, " ") + "\n");
    }
  ' "$@"
}

# percent_encode STRING: application/x-www-form-urlencoded encoding of one value.
percent_encode() {
  local LC_ALL=C string="$1" encoded="" character hex index
  for (( index = 0; index < ${#string}; index++ )); do
    character="${string:index:1}"
    case "$character" in
      [A-Za-z0-9._~-]) encoded+="$character" ;;
      *) printf -v hex '%%%02X' "'$character"; encoded+="$hex" ;;
    esac
  done
  printf '%s' "$encoded"
}

# http_status HEADERS_FILE: the status code of the last response in a curl -D header dump.
http_status() {
  awk '{ sub(/\r$/, "") } toupper($1) ~ /^HTTP\// { status = $2 } END { print status }' "$1"
}

# MARK: - Versions and paths

VERSION="$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' project.yml | head -n 1)"
BUILD_NUMBER="$(sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' project.yml | head -n 1)"

if [[ "$FLAVOR" == paid ]]; then
  PROJECT_SPEC="project-paid.yml"
  PROJECT="OttoPaid.xcodeproj"
  BASE_NAME="Otto-$VERSION"
else
  PROJECT_SPEC="project-setapp.yml"
  PROJECT="OttoSetapp.xcodeproj"
  BASE_NAME="Otto-$VERSION-setapp"
fi
WORK="$ROOT/build/release/$FLAVOR"
DERIVED="$WORK/DerivedData"
DIST="$ROOT/dist/$FLAVOR"
APP_NAME="Otto"
VOLUME_NAME="Otto"
SUFFIX=""
[[ $NO_NOTARIZE == 1 ]] && SUFFIX="-UNNOTARIZED"
DMG="$DIST/$BASE_NAME$SUFFIX.dmg"
SETAPP_ZIP="$DIST/$BASE_NAME$SUFFIX.zip"
DSYM_ZIP="$DIST/$BASE_NAME$SUFFIX.dSYM.zip"
CHECKSUMS="$DIST/SHA256SUMS$SUFFIX.txt"

echo "Otto ${VERSION:-?} (${BUILD_NUMBER:-?}), $FLAVOR build"

# MARK: - Preflight, stage 1: local checks

step "Preflight 1 of 3: local checks"

TOOLS=(xcodegen xcodebuild xcrun codesign security plutil lipo ditto shasum otool strings nm)
if [[ "$FLAVOR" == paid ]]; then
  TOOLS+=(node curl uuidgen hdiutil osascript tiffutil swift perl)
fi
for tool in "${TOOLS[@]}"; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    case "$tool" in
      xcodegen) problem "xcodegen not found. Install it with: brew install xcodegen" ;;
      node) problem "node not found. Install Node (brew install node); the preflight reads commerce.json and Polar's answers with it." ;;
      *) problem "$tool not found. Install Xcode and its command line tools (xcode-select --install)." ;;
    esac
  fi
done

# The signing identity, resolved to its SHA-1 hash: the same certificate often shows up in more than one keychain,
# and a hash is never ambiguous.
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if [[ -n "${OTTO_SIGN_IDENTITY:-}" ]]; then
  IDENTITY_LINE="$(grep -F -- "$OTTO_SIGN_IDENTITY" <<<"$IDENTITIES" | head -n 1 || true)"
else
  IDENTITY_LINE="$(grep -F '"Developer ID Application' <<<"$IDENTITIES" | head -n 1 || true)"
fi
IDENTITY_HASH=""
IDENTITY_NAME=""
TEAM_ID=""
if [[ -z "$IDENTITY_LINE" ]]; then
  problem "no Developer ID Application identity in your keychains (security find-identity -v -p codesigning; J7). See docs/RELEASING.md, One-time setup."
else
  IDENTITY_HASH="$(awk '{print $2}' <<<"$IDENTITY_LINE")"
  IDENTITY_NAME="$(sed -n 's/.*"\(.*\)".*/\1/p' <<<"$IDENTITY_LINE")"
  TEAM_ID="${OTTO_TEAM_ID:-$(sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p' <<<"$IDENTITY_NAME")}"
  [[ -n "$TEAM_ID" ]] || problem "couldn't read the team ID from \"$IDENTITY_NAME\"; set OTTO_TEAM_ID."
  [[ "$IDENTITY_NAME" == "Developer ID Application"* ]] \
    || problem "\"$IDENTITY_NAME\" isn't a Developer ID Application identity, so Gatekeeper would refuse the build on other Macs."
fi

NOTARY_PROFILE="${OTTO_NOTARY_PROFILE:-}"
if [[ $NO_NOTARIZE == 0 && -z "$NOTARY_PROFILE" ]]; then
  problem "OTTO_NOTARY_PROFILE is not set (J7). Save a notary profile (docs/RELEASING.md) and export OTTO_NOTARY_PROFILE=otto-notary, or pass --no-notarize for a local test build."
fi

CONFIG_OUTPUT=""
if ! CONFIG_OUTPUT="$(bash "$ROOT/scripts/check_commercial_config.sh" --flavor "$FLAVOR" --configuration Release \
  --xcconfig "$COMMERCIAL_XCCONFIG" 2>&1)"; then
  printf '%s\n' "$CONFIG_OUTPUT" >&2
  PROBLEMS=$((PROBLEMS + 1))
elif [[ -n "$CONFIG_OUTPUT" ]]; then
  printf '%s\n' "$CONFIG_OUTPUT" | sed 's/^/    /'
fi

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || problem "project.yml: MARKETING_VERSION \"$VERSION\" isn't MAJOR.MINOR.PATCH."
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] \
  || problem "project.yml: CURRENT_PROJECT_VERSION \"$BUILD_NUMBER\" isn't a positive whole number."

SITE_HOST=""
SUPPORT_EMAIL=""
ORGANIZATION_ID=""
BENEFIT_ID=""
GUMROAD_PRODUCT_ID=""
SPARKLE_PUBLIC_KEY=""
if [[ "$FLAVOR" == paid ]]; then
  SITE_HOST="$(xcconfig_value OTTO_SITE_HOST)"
  SUPPORT_EMAIL="$(xcconfig_value OTTO_SUPPORT_EMAIL)"
  ORGANIZATION_ID="$(xcconfig_value OTTO_POLAR_ORGANIZATION_ID)"
  BENEFIT_ID="$(xcconfig_value OTTO_POLAR_BENEFIT_ID)"
  GUMROAD_PRODUCT_ID="$(xcconfig_value OTTO_GUMROAD_PRODUCT_ID)"
  SPARKLE_PUBLIC_KEY="$(xcconfig_value OTTO_SPARKLE_PUBLIC_ED_KEY)"

  # Sparkle offers an update only when its build number is higher than the running copy's, so this release must
  # outnumber every item already in the feed. A missing appcast.xml has no items: the first release starts it.
  APPCAST="$SITE_DIR/appcast.xml"
  if [[ ! -f "$APPCAST" ]]; then
    note "no appcast.xml in $SITE_DIR: this release starts the feed"
  elif [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    FEED_BUILDS="$( { grep -oE '<sparkle:version>[^<]*</sparkle:version>' "$APPCAST" | sed -E 's/<[^>]*>//g'
                      grep -oE 'sparkle:version="[^"]*"' "$APPCAST" | sed -E 's/.*="([^"]*)"/\1/'; } || true)"
    HIGHEST=0
    while IFS= read -r feed_build; do
      [[ -z "$feed_build" ]] && continue
      if [[ ! "$feed_build" =~ ^[0-9]+$ ]]; then
        problem "$APPCAST has an item with sparkle:version \"$feed_build\", which isn't a whole number."
        continue
      fi
      if (( feed_build > HIGHEST )); then HIGHEST=$feed_build; fi
    done <<<"$FEED_BUILDS"
    if (( BUILD_NUMBER <= HIGHEST )); then
      problem "project.yml: CURRENT_PROJECT_VERSION is $BUILD_NUMBER, but $APPCAST already has build $HIGHEST. Raise it above $HIGHEST (docs/RELEASING.md, Release prep), or Sparkle never offers this update."
    else
      note "build $BUILD_NUMBER is newer than every item in appcast.xml (highest: $HIGHEST)"
    fi
  fi

  # site/commerce.json must name the same site and support address as the build, or the app would send buyers and
  # update checks somewhere the site doesn't serve.
  COMMERCE="$SITE_DIR/commerce.json"
  if [[ ! -f "$COMMERCE" ]]; then
    problem "$COMMERCE is missing. The paid release reads the site host and the support address from it (J8, J11)."
  elif command -v node >/dev/null 2>&1; then
    if COMMERCE_FIELDS="$(json_fields "$COMMERCE" siteHost seller.supportEmail)"; then
      COMMERCE_SITE_HOST="$(sed -n 1p <<<"$COMMERCE_FIELDS")"
      COMMERCE_SUPPORT_EMAIL="$(sed -n 2p <<<"$COMMERCE_FIELDS")"
      if [[ "$COMMERCE_SITE_HOST" == *JALEN_MUST_SET* ]]; then
        problem "$COMMERCE: siteHost is still a placeholder (J8)."
      elif [[ "$SITE_HOST" != *JALEN_MUST_SET* && "$COMMERCE_SITE_HOST" != "$SITE_HOST" ]]; then
        problem "$COMMERCE: siteHost is \"$COMMERCE_SITE_HOST\", but $COMMERCIAL_XCCONFIG sets OTTO_SITE_HOST = $SITE_HOST (J8)."
      fi
      if [[ "$COMMERCE_SUPPORT_EMAIL" == *JALEN_MUST_SET* ]]; then
        problem "$COMMERCE: seller.supportEmail is still a placeholder (J11)."
      elif [[ "$SUPPORT_EMAIL" != *JALEN_MUST_SET* && "$COMMERCE_SUPPORT_EMAIL" != "$SUPPORT_EMAIL" ]]; then
        problem "$COMMERCE: seller.supportEmail is \"$COMMERCE_SUPPORT_EMAIL\", but $COMMERCIAL_XCCONFIG sets OTTO_SUPPORT_EMAIL = $SUPPORT_EMAIL (J11)."
      fi
    else
      problem "$COMMERCE is not valid JSON."
    fi
  fi
fi

end_stage "stage 1"

if [[ "$FLAVOR" == paid ]]; then
  # MARK: - Preflight, stage 2: Polar and Gumroad (paid)

  step "Preflight 2 of 3: Polar version probe and license canaries"
  mkdir -p "$WORK"
  NETWORK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/otto-release.XXXXXX")"
  trap 'rm -rf "$NETWORK_TMP"' EXIT

  POLAR_API_VERSION="$(sed -n 's/^[[:space:]]*static let apiVersion = "\([0-9]\{4\}-[0-9]\{2\}\)".*/\1/p' \
    "$ROOT/Otto/Licensing/LicenseContracts.swift" 2>/dev/null | head -n 1)"
  [[ -n "$POLAR_API_VERSION" ]] \
    || problem "couldn't read PolarConfiguration.apiVersion from Otto/Licensing/LicenseContracts.swift."
  POLAR_HEADERS=(-H "Content-Type: application/json" -H "Accept: application/json" -H "Accept-Language: en"
                 -H "Polar-Version: ${POLAR_API_VERSION:-unknown}" -H "User-Agent: Otto/$VERSION")
  POLAR_VALIDATE_URL="https://$POLAR_HOST/v1/customer-portal/license-keys/validate"

  # The version probe: a random key must get Polar's versioned "not found" answer. Anything else means Polar stopped
  # serving the pinned version, and shipped copies would read every answer through the unpinned retry.
  if [[ -n "$POLAR_API_VERSION" ]]; then
    PROBE_KEY="OTTO-$(uuidgen | tr '[:lower:]' '[:upper:]')"
    CURL_STATUS=0
    printf '{"benefit_id":"%s","key":"%s","organization_id":"%s"}' "$BENEFIT_ID" "$PROBE_KEY" "$ORGANIZATION_ID" \
      | curl -sS --max-time 30 -X POST "${POLAR_HEADERS[@]}" -D "$NETWORK_TMP/probe.headers" \
          -o "$NETWORK_TMP/probe.body" --data-binary @- "$POLAR_VALIDATE_URL" 2>"$NETWORK_TMP/probe.err" \
      || CURL_STATUS=$?
    if [[ $CURL_STATUS -ne 0 ]]; then
      problem "couldn't reach $POLAR_HOST for the version probe (curl exit $CURL_STATUS). Stage 2 needs the network."
    else
      STATUS="$(http_status "$NETWORK_TMP/probe.headers")"
      ECHOED="$(awk -F': *' 'tolower($1) == "polar-version" { gsub(/\r/, "", $2); print $2 }' "$NETWORK_TMP/probe.headers" | tail -n 1)"
      if [[ "$STATUS" == 404 && "$ECHOED" == "$POLAR_API_VERSION" ]] \
        && grep -Eq '"error"[[:space:]]*:[[:space:]]*"ResourceNotFound"' "$NETWORK_TMP/probe.body"; then
        note "Polar serves API version $POLAR_API_VERSION"
      else
        problem "Polar no longer serves API version $POLAR_API_VERSION (HTTP ${STATUS:-none}, polar-version: ${ECHOED:-absent}). Read Polar's changelog, bump PolarConfiguration.apiVersion and re-run the Polar fixtures."
      fi
    fi
  fi

  # The Polar canary (J20): a production key from a 100%-discount order, never activated. It must validate with the
  # exact organization and benefit this build ships, so a wrong or drifted ID stops the release here. The key goes
  # to curl on stdin, never on a command line.
  KEYCHAIN_STATUS=0
  POLAR_CANARY="$(security find-generic-password -s otto-release -a polar-canary -w 2>/dev/null)" || KEYCHAIN_STATUS=$?
  if [[ $KEYCHAIN_STATUS -ne 0 || -z "$POLAR_CANARY" ]]; then
    problem "no Polar canary key in the login Keychain (J20; security exit $KEYCHAIN_STATUS). Save it with: security add-generic-password -s otto-release -a polar-canary -w '<key>'"
  else
    CURL_STATUS=0
    printf '{"benefit_id":"%s","key":"%s","organization_id":"%s"}' "$BENEFIT_ID" "$POLAR_CANARY" "$ORGANIZATION_ID" \
      | curl -sS --max-time 30 -X POST "${POLAR_HEADERS[@]}" -D "$NETWORK_TMP/canary.headers" \
          -o "$NETWORK_TMP/canary.body" --data-binary @- "$POLAR_VALIDATE_URL" 2>"$NETWORK_TMP/canary.err" \
      || CURL_STATUS=$?
    if [[ $CURL_STATUS -ne 0 ]]; then
      problem "couldn't reach $POLAR_HOST to validate the Polar canary (J20; curl exit $CURL_STATUS)."
    else
      STATUS="$(http_status "$NETWORK_TMP/canary.headers")"
      if [[ "$STATUS" != 200 ]]; then
        problem "the Polar canary didn't validate with organization $ORGANIZATION_ID and benefit $BENEFIT_ID (J20): HTTP ${STATUS:-none}. Check both IDs in $COMMERCIAL_XCCONFIG, and that the canary order wasn't refunded or revoked."
      elif ! CANARY_FIELDS="$(json_fields "$NETWORK_TMP/canary.body" status benefit_id limit_activations)"; then
        problem "Polar answered the canary validation with something that isn't JSON (J20)."
      else
        CANARY_KEY_STATUS="$(sed -n 1p <<<"$CANARY_FIELDS")"
        CANARY_BENEFIT="$(sed -n 2p <<<"$CANARY_FIELDS")"
        CANARY_LIMIT="$(sed -n 3p <<<"$CANARY_FIELDS")"
        if [[ "$CANARY_KEY_STATUS" != granted ]]; then
          problem "the Polar canary's status is \"$CANARY_KEY_STATUS\", not granted (J20). Use a key that was never refunded or revoked."
        elif [[ "$CANARY_BENEFIT" != "$BENEFIT_ID" ]]; then
          problem "the Polar canary belongs to benefit $CANARY_BENEFIT, not OTTO_POLAR_BENEFIT_ID $BENEFIT_ID (J20)."
        elif [[ "$CANARY_LIMIT" != 3 ]]; then
          problem "the Polar canary's benefit allows ${CANARY_LIMIT:-unlimited} activations, not 3 (J20, J2). Set the License Keys benefit's activation limit to 3."
        else
          note "the Polar canary validates with this build's organization and benefit (3 activations)"
        fi
      fi
    fi
  fi

  # The Gumroad canary (J21), only in a release that accepts Gumroad keys. increment_uses_count=false keeps its count.
  if [[ -n "$GUMROAD_PRODUCT_ID" && "$GUMROAD_PRODUCT_ID" != none ]]; then
    KEYCHAIN_STATUS=0
    GUMROAD_CANARY="$(security find-generic-password -s otto-release -a gumroad-canary -w 2>/dev/null)" || KEYCHAIN_STATUS=$?
    if [[ $KEYCHAIN_STATUS -ne 0 || -z "$GUMROAD_CANARY" ]]; then
      problem "no Gumroad canary key in the login Keychain (J21; security exit $KEYCHAIN_STATUS). This release accepts Gumroad keys, so it needs one: security add-generic-password -s otto-release -a gumroad-canary -w '<key>'"
    else
      CURL_STATUS=0
      printf 'increment_uses_count=false&license_key=%s&product_id=%s' \
        "$(percent_encode "$GUMROAD_CANARY")" "$(percent_encode "$GUMROAD_PRODUCT_ID")" \
        | curl -sS --max-time 30 -X POST -H "Content-Type: application/x-www-form-urlencoded" \
            -H "Accept: application/json" -H "Accept-Language: en" -H "User-Agent: Otto/$VERSION" \
            -D "$NETWORK_TMP/gumroad.headers" -o "$NETWORK_TMP/gumroad.body" --data-binary @- \
            "$GUMROAD_VERIFY_URL" 2>"$NETWORK_TMP/gumroad.err" \
        || CURL_STATUS=$?
      if [[ $CURL_STATUS -ne 0 ]]; then
        problem "couldn't reach api.gumroad.com to verify the Gumroad canary (J21; curl exit $CURL_STATUS)."
      else
        STATUS="$(http_status "$NETWORK_TMP/gumroad.headers")"
        if [[ "$STATUS" != 200 ]]; then
          problem "the Gumroad canary didn't verify with product $GUMROAD_PRODUCT_ID (J21, J13): HTTP ${STATUS:-none}."
        elif ! GUMROAD_FIELDS="$(json_fields "$NETWORK_TMP/gumroad.body" success purchase.refunded \
          purchase.chargebacked purchase.disputed purchase.dispute_won)"; then
          problem "Gumroad answered the canary verification with something that isn't JSON (J21)."
        else
          G_SUCCESS="$(sed -n 1p <<<"$GUMROAD_FIELDS")"
          G_REFUNDED="$(sed -n 2p <<<"$GUMROAD_FIELDS")"
          G_CHARGEBACKED="$(sed -n 3p <<<"$GUMROAD_FIELDS")"
          G_DISPUTED="$(sed -n 4p <<<"$GUMROAD_FIELDS")"
          G_DISPUTE_WON="$(sed -n 5p <<<"$GUMROAD_FIELDS")"
          if [[ "$G_SUCCESS" != true ]]; then
            problem "the Gumroad canary answered success: ${G_SUCCESS:-absent} (J21)."
          elif [[ "$G_REFUNDED" == true || "$G_CHARGEBACKED" == true || ( "$G_DISPUTED" == true && "$G_DISPUTE_WON" != true ) ]]; then
            problem "the Gumroad canary's purchase is refunded, charged back or disputed (J21). Buy a new canary with a 100% offer code."
          else
            note "the Gumroad canary verifies with this build's product id"
          fi
        fi
      fi
    fi
  fi

  end_stage "stage 2"

  # MARK: - Preflight, stage 3: packages and the Sparkle key (paid)

  step "Preflight 3 of 3: Swift packages and the Sparkle signing key"
  if ! xcodegen generate --quiet --spec "$ROOT/$PROJECT_SPEC" >"$WORK/xcodegen.log" 2>&1; then
    cat "$WORK/xcodegen.log" >&2
    problem "xcodegen couldn't generate $PROJECT from $PROJECT_SPEC."
  elif ! xcodebuild -resolvePackageDependencies -project "$PROJECT" -scheme Otto -derivedDataPath "$DERIVED" \
    >"$WORK/resolve.log" 2>&1; then
    tail -n 20 "$WORK/resolve.log" >&2
    problem "Swift package resolution failed for $PROJECT (full log: $WORK/resolve.log)."
  elif GENERATE_KEYS="$(sparkle_tool generate_keys "$ROOT")"; then
    KEYCHAIN_PUBLIC_KEY="$("$GENERATE_KEYS" -p 2>"$WORK/generate_keys.err" | tr -d '[:space:]')" || KEYCHAIN_PUBLIC_KEY=""
    if [[ -z "$KEYCHAIN_PUBLIC_KEY" ]]; then
      problem "generate_keys -p found no Sparkle key in this Mac's login Keychain (J6). Import the backup with generate_keys -f <file>; never make a new key for a shipped app."
    elif [[ "$KEYCHAIN_PUBLIC_KEY" != "$SPARKLE_PUBLIC_KEY" ]]; then
      problem "the Sparkle key in this Mac's login Keychain (public key $KEYCHAIN_PUBLIC_KEY) isn't OTTO_SPARKLE_PUBLIC_ED_KEY ($SPARKLE_PUBLIC_KEY) (J6). Every shipped copy would refuse an update signed with it."
    else
      note "the login Keychain's Sparkle key matches OTTO_SPARKLE_PUBLIC_ED_KEY"
    fi
  else
    PROBLEMS=$((PROBLEMS + 1))
  fi
  end_stage "stage 3"
else
  note "stages 2 and 3 are paid only: the Setapp build has no license canary or Sparkle key"
fi

if [[ $PREFLIGHT_ONLY == 1 ]]; then
  echo
  echo "Preflight passed (--preflight-only). Nothing was built."
  exit 0
fi

echo
echo "  identity:     $IDENTITY_NAME [$IDENTITY_HASH]"
echo "  team:         $TEAM_ID"
if [[ $NO_NOTARIZE == 0 ]]; then
  echo "  notarization: keychain profile \"$NOTARY_PROFILE\""
else
  echo "  notarization: SKIPPED (--no-notarize); every output is named -UNNOTARIZED"
fi

# MARK: - Build helpers

# Finder window layout (points). Must match scripts/make_dmg_background.swift.
WINDOW_WIDTH=660
WINDOW_HEIGHT=420
TITLE_BAR_HEIGHT=28
ICON_SIZE=128
APP_POSITION="170, 196"
APPLICATIONS_POSITION="490, 196"

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
  if [[ -n "$NETWORK_TMP" ]]; then rm -rf "$NETWORK_TMP"; fi
  return 0
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

# plist_value APP KEY: a top-level Info.plist value of APP, or nothing.
plist_value() {
  plutil -extract "$2" raw -o - "$1/Contents/Info.plist" 2>/dev/null || true
}

# verify_paid_info APP: the Info.plist values the app ships with are the ones the preflight checked, so a
# Config/Local.xcconfig override can't slip another ID, host or key past the canaries.
verify_paid_info() {
  local app="$1" pair key expected actual
  for pair in "SUFeedURL|https://$SITE_HOST/appcast.xml" "SUPublicEDKey|$SPARKLE_PUBLIC_KEY" \
    "OttoSiteHost|$SITE_HOST" "OttoSupportEmail|$SUPPORT_EMAIL" "OttoPolarAPIHost|$POLAR_HOST" \
    "OttoPolarOrganizationID|$ORGANIZATION_ID" "OttoPolarBenefitID|$BENEFIT_ID" \
    "OttoGumroadProductID|$GUMROAD_PRODUCT_ID"; do
    key="${pair%%|*}"
    expected="${pair#*|}"
    actual="$(plist_value "$app" "$key")"
    [[ "$actual" == "$expected" ]] \
      || fail "$app: Info.plist $key is \"$actual\", not \"$expected\" from $COMMERCIAL_XCCONFIG. Check Config/Local.xcconfig for an override."
  done
  note "Info.plist carries the feed, key, hosts and IDs the preflight checked"
}

# MARK: - Build

APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
DSYM="$DERIVED/Build/Products/Release/$APP_NAME.app.dSYM"
BUILD_LOG="$WORK/xcodebuild.log"
mkdir -p "$WORK" "$DIST"

if [[ $SKIP_BUILD == 1 ]]; then
  step "Reusing the last $FLAVOR Release build (--skip-build)"
  [[ -d "$APP" ]] || fail "no previous Release build at $APP; run without --skip-build"
else
  step "Generating $PROJECT from $PROJECT_SPEC"
  xcodegen generate --quiet --spec "$ROOT/$PROJECT_SPEC"

  step "Building Otto $VERSION, $FLAVOR (Release, Developer ID, hardened runtime)"
  rm -rf "$WORK/dmg-staging" "$WORK/background" "$WORK/$APP_NAME-rw.dmg" "$WORK/$APP_NAME-$VERSION-app.zip"
  # Command-line settings override Config/Signing.xcconfig and Config/Local.xcconfig, so nothing signing-related is
  # committed. CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO keeps get-task-allow out (the notary service rejects it). The
  # compile conditions and commercial values come from the flavor's project spec and Config/Commercial.xcconfig
  # alone: this script never passes SWIFT_ACTIVE_COMPILATION_CONDITIONS or -xcconfig.
  if ! xcodebuild \
    -project "$PROJECT" \
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

BUILT_VERSION="$(plist_value "$APP" CFBundleShortVersionString)"
BUILT_BUILD="$(plist_value "$APP" CFBundleVersion)"
[[ "$BUILT_VERSION" == "$VERSION" ]] || fail "built app reports version $BUILT_VERSION, expected $VERSION"
[[ "$BUILT_BUILD" == "$BUILD_NUMBER" ]] || fail "built app reports build $BUILT_BUILD, expected $BUILD_NUMBER"

# MARK: - Sparkle: remove the XPC services, then sign from the inside out (paid)

if [[ "$FLAVOR" == paid ]]; then
  step "Removing Sparkle's XPC services and re-signing Sparkle and the app"
  FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
  ENTITLEMENTS="$ROOT/build/flavors/paid/Otto.entitlements"
  [[ -d "$FRAMEWORK/Versions/B" ]] || fail "$FRAMEWORK/Versions/B is missing; check the Sparkle version in project-paid.yml"
  [[ -f "$ENTITLEMENTS" ]] || fail "$ENTITLEMENTS is missing; xcodegen generate --spec project-paid.yml writes it"
  # Otto isn't sandboxed, so Sparkle never uses its XPC services (Sparkle's sandboxing guide, "Removing XPC
  # Services"). Removing them before signing keeps unused helper bundles out of the notarized app.
  rm -rf "$FRAMEWORK/Versions/B/XPCServices"
  rm -f "$FRAMEWORK/XPCServices"
  # Sparkle's documented order for Developer ID, no --deep: the helpers, the framework, then the app.
  for nested in "$FRAMEWORK/Versions/B/Autoupdate" "$FRAMEWORK/Versions/B/Updater.app" "$FRAMEWORK"; do
    [[ -e "$nested" ]] || fail "$nested is missing"
    codesign -f -s "$IDENTITY_HASH" -o runtime --timestamp "$nested"
    note "signed ${nested#"$APP"/}"
  done
  codesign -f -s "$IDENTITY_HASH" --entitlements "$ENTITLEMENTS" -o runtime --timestamp "$APP"
  note "signed Otto.app with build/flavors/paid/Otto.entitlements"
fi

# MARK: - Verify

step "Verifying the app"
verify_app "$APP"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"
[[ " $ARCHS " == *" arm64 "* && " $ARCHS " == *" x86_64 "* ]] \
  || fail "Otto isn't universal (lipo -archs: $ARCHS); Setapp and Intel Macs need arm64 and x86_64"
note "universal: $ARCHS"
if ! AUDIT_OUTPUT="$(bash "$ROOT/scripts/audit_flavor.sh" --flavor "$FLAVOR" --expect-wired --distribution "$APP" 2>&1)"; then
  printf '%s\n' "$AUDIT_OUTPUT" | sed 's/^/    /' >&2
  fail "the flavor audit failed (scripts/audit_flavor.sh --flavor $FLAVOR --expect-wired --distribution)"
fi
printf '%s\n' "$AUDIT_OUTPUT" | sed 's/^/    /'
if plutil -p "$APP/Contents/Info.plist" | grep -qF '$('; then
  plutil -p "$APP/Contents/Info.plist" | grep -F '$(' >&2
  fail "Info.plist has unexpanded build settings"
fi
note "Info.plist values are expanded"
if [[ "$FLAVOR" == paid ]]; then verify_paid_info "$APP"; fi

# MARK: - Notarize the app

if [[ $NO_NOTARIZE == 0 ]]; then
  step "Notarizing Otto.app"
  APP_ZIP="$WORK/$APP_NAME-$VERSION-app.zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$APP_ZIP"
  notarize "$APP_ZIP"
  xcrun stapler staple "$APP" | sed 's/^/    /'
  xcrun stapler validate "$APP" | sed 's/^/    /'
fi

rm -f "$DMG" "$SETAPP_ZIP" "$DSYM_ZIP" "$CHECKSUMS"
if [[ -d "$DSYM" ]]; then
  ditto -c -k --sequesterRsrc --keepParent "$DSYM" "$DSYM_ZIP"
fi

if [[ "$FLAVOR" == setapp ]]; then
  # MARK: - Setapp: a zip of the stapled app

  step "Packaging the Setapp zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$SETAPP_ZIP"
  note "wrote $SETAPP_ZIP"
  PACKAGE="$SETAPP_ZIP"
else
  # MARK: - Paid: the disk image

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
    # Finder is addressed by the mount point's path (not the volume name), so another mounted "Otto" volume can't
    # be picked up by mistake. `perl alarm` bounds a hung Apple Event.
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

  # Volume icon: .VolumeIcon.icns plus the kHasCustomIcon Finder flag on the volume root. Added last: an icon file
  # that is already on the volume during the Finder layout pass goes missing from the image.
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

  hdiutil convert "$RW_DMG" -quiet -format UDZO -imagekey zlib-level=9 -o "$DMG"
  rm -f "$RW_DMG"

  step "Signing the disk image"
  codesign --force --sign "$IDENTITY_HASH" --timestamp "$DMG"
  codesign --verify --strict --verbose=2 "$DMG" 2>&1 | sed 's/^/    /'
  hdiutil verify -quiet "$DMG"
  note "checksum verified"

  if [[ $NO_NOTARIZE == 0 ]]; then
    step "Notarizing $(basename "$DMG")"
    notarize "$DMG"
    xcrun stapler staple "$DMG" | sed 's/^/    /'
    xcrun stapler validate "$DMG" | sed 's/^/    /'
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" 2>&1 | sed 's/^/    /'
  fi
  PACKAGE="$DMG"
fi

# MARK: - Checksums

(
  cd "$DIST"
  checksum_files=("$(basename "$PACKAGE")")
  [[ -f "$DSYM_ZIP" ]] && checksum_files+=("$(basename "$DSYM_ZIP")")
  shasum -a 256 "${checksum_files[@]}" >"$(basename "$CHECKSUMS")"
)

# MARK: - Smoke test (paid, optional)

if [[ $SMOKE_TEST == 1 ]]; then
  step "Smoke test: mounting $(basename "$DMG") and launching Otto --demo from it"
  IFS=$'\t' read -r SMOKE_DEVICE SMOKE_MOUNT < <(attach "$DMG" -readonly -nobrowse)
  [[ -n "$SMOKE_DEVICE" && -d "$SMOKE_MOUNT" ]] || fail "could not mount $DMG"
  MOUNTED_DEVICES+=("$SMOKE_DEVICE")
  note "mounted at $SMOKE_MOUNT: $(ls -A "$SMOKE_MOUNT" | tr '\n' ' ')"
  [[ -L "$SMOKE_MOUNT/Applications" ]] || fail "the Applications shortcut is missing"
  SMOKE_APP="$SMOKE_MOUNT/$APP_NAME.app"
  verify_app "$SMOKE_APP"
  [[ "$(plist_value "$SMOKE_APP" CFBundleIdentifier)" == com.jalenedusei.otto ]] \
    || fail "the app on the disk image isn't com.jalenedusei.otto"
  [[ "$(plist_value "$SMOKE_APP" CFBundleShortVersionString)" == "$VERSION" ]] \
    || fail "the app on the disk image isn't version $VERSION"
  verify_paid_info "$SMOKE_APP"
  "$SMOKE_APP/Contents/MacOS/$APP_NAME" --demo >"$WORK/smoke.log" 2>&1 &
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
sed 's/^/    /' "$CHECKSUMS"
echo
if [[ $NO_NOTARIZE == 1 ]]; then
  echo "    Not notarized (--no-notarize). Don't publish these files; publish.sh refuses them."
elif [[ "$FLAVOR" == paid ]]; then
  echo "    Next: scripts/publish.sh --version $VERSION (docs/RELEASING.md, Publishing a paid release)."
else
  echo "    Next: upload $(basename "$SETAPP_ZIP") in the Setapp developer account (docs/RELEASING.md, Setapp)."
fi
