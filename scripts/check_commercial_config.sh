#!/bin/bash
#
# check_commercial_config.sh
# Otto
#
# Checks the commercial configuration of the paid and Setapp builds (SPEC-v2 §14.3). Every value Jalen still has to
# supply is a named placeholder: in a Release build it is an error that stops the build before anything compiles; in
# a Debug build it is a warning. The lines use Xcode's "error:" / "warning:" format, so they land in the issue
# navigator, and each names its open item (§14.20) and where the value comes from.
#
#   check_commercial_config.sh --flavor paid|setapp [--configuration Debug|Release]
#                              (--from-build-env | --xcconfig FILE) [--report]
#
#   --from-build-env  the pre-build phase of both flavor targets: reads CONFIGURATION, PRODUCT_BUNDLE_IDENTIFIER,
#                     SRCROOT and the OTTO_* settings from the environment Xcode gives run-script phases
#   --xcconfig FILE   release.sh preflight, CI and tests: reads KEY = value and KEY[config=<C>] = value lines of FILE
#                     (the [config=] line wins for its configuration), strips // comments, then removes $()
#   --report          also prints "ok <KEY>" for every setting that passes
#
# Exit: 0 valid (Debug may have warnings), 1 any problem in Release (or a wrong Setapp bundle id), 2 usage error.
#
# The rules match LicenseConfiguration.load (Otto/Licensing/LicenseConfiguration+Load.swift), which re-validates the
# Info.plist values at runtime.

set -u

readonly SETAPP_BUNDLE_ID="com.jalenedusei.otto-setapp"
readonly HOST_PATTERN='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$'
readonly EMAIL_PATTERN='^[^@ ]+@[^@ ]+\.[^@ ]+$'
readonly UUID_V4_PATTERN='^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
readonly SLUG_PATTERN='^[a-z0-9][a-z0-9-]{1,63}$'
readonly GUMROAD_PATTERN='^[A-Za-z0-9_=+/-]{10,64}$'
readonly BASE64_PATTERN='^[A-Za-z0-9+/]+={0,2}$'

# usage [STATUS]: prints the usage (to stdout for --help, stderr otherwise) and exits with STATUS (2).
usage() {
    local status=${1:-2}
    if [ "$status" -eq 0 ]; then exec 3>&1; else exec 3>&2; fi
    cat >&3 <<'EOF'
usage: check_commercial_config.sh --flavor paid|setapp [--configuration Debug|Release]
                                  (--from-build-env | --xcconfig FILE) [--report]
EOF
    exit "$status"
}

fail_usage() {
    echo "check_commercial_config.sh: $1" >&2
    usage
}

flavor=""
configuration=""
mode=""
xcconfig=""
report=0

while [ $# -gt 0 ]; do
    case "$1" in
        --flavor)
            [ $# -ge 2 ] || fail_usage "--flavor needs a value"
            flavor=$2
            shift 2
            ;;
        --configuration)
            [ $# -ge 2 ] || fail_usage "--configuration needs a value"
            configuration=$2
            shift 2
            ;;
        --from-build-env)
            [ -z "$mode" ] || fail_usage "use either --from-build-env or --xcconfig, not both"
            mode="env"
            shift
            ;;
        --xcconfig)
            [ -z "$mode" ] || fail_usage "use either --from-build-env or --xcconfig, not both"
            [ $# -ge 2 ] || fail_usage "--xcconfig needs a file"
            mode="file"
            xcconfig=$2
            shift 2
            ;;
        --report)
            report=1
            shift
            ;;
        -h | --help)
            usage 0
            ;;
        *)
            fail_usage "unknown option $1"
            ;;
    esac
done

case "$flavor" in
    paid | setapp) ;;
    "") fail_usage "--flavor is required" ;;
    *) fail_usage "unknown flavor $flavor (paid or setapp)" ;;
esac
[ -n "$mode" ] || fail_usage "one of --from-build-env or --xcconfig is required"

if [ "$mode" = "env" ]; then
    [ -n "$configuration" ] || configuration=${CONFIGURATION:-}
    [ -n "${SRCROOT:-}" ] || fail_usage "--from-build-env needs SRCROOT (run it from an Xcode build phase)"
    root=$SRCROOT
    label="Config/Commercial.xcconfig"
else
    [ -n "$configuration" ] || configuration="Release"
    [ -f "$xcconfig" ] || fail_usage "no such file: $xcconfig"
    root=$(cd "$(dirname "$0")/.." && pwd)
    label=$xcconfig
fi
case "$configuration" in
    Debug | Release) ;;
    "") fail_usage "no configuration (pass --configuration, or run it from an Xcode build phase)" ;;
    *) fail_usage "unknown configuration $configuration (Debug or Release)" ;;
esac

if [ "$configuration" = "Release" ]; then severity="error"; else severity="warning"; fi
problems=0
errors=0

# The value of a setting for this configuration; exit status 3 when the setting isn't defined at all.
setting() {
    local key=$1
    if [ "$mode" = "env" ]; then
        printenv "$key" || return 3
        return 0
    fi
    awk -v key="$key" -v conf="$configuration" '
        {
            line = $0
            sub(/^[ \t]+/, "", line)
            if (line ~ /^#/) next                      # #include and #include?
            cut = index(line, "//")                    # xcconfig reads // anywhere as a comment
            if (cut > 0) line = substr(line, 1, cut - 1)
            eq = index(line, "=")
            if (eq == 0) next
            lhs = substr(line, 1, eq - 1)
            rhs = substr(line, eq + 1)
            gsub(/[ \t]+$/, "", lhs)
            gsub(/^[ \t]+|[ \t]+$/, "", rhs)
            gsub(/\$\(\)/, "", rhs)                    # /$()/ is how a value spells //
            if (lhs == key) { plain = rhs; has_plain = 1 }
            else if (lhs == key "[config=" conf "]") { conditional = rhs; has_conditional = 1 }
        }
        END {
            if (has_conditional) print conditional
            else if (has_plain) print plain
            else exit 3
        }' "$xcconfig"
}

# report_problem SEVERITY WHERE KEY PROBLEM ITEM HINT
report_problem() {
    local line="$1: $2: $3 $4"
    if [ -n "$5" ]; then
        line="$line ($5). $6 See SPEC-v2 §14.20."
    else
        line="$line. $6 See SPEC-v2 §14.3."
    fi
    echo "$line"
    problems=$((problems + 1))
    [ "$1" = "error" ] && errors=$((errors + 1))
    return 0
}

ok() {
    [ "$report" -eq 1 ] && echo "ok $1"
    return 0
}

# check KEY ITEM HINT VALIDATOR: reads the setting, reports a missing value or a placeholder, then asks VALIDATOR
# (a function printing a problem phrase, or nothing when the value is valid).
check() {
    local key=$1 item=$2 hint=$3 validator=$4 value status phrase
    value=$(setting "$key")
    status=$?
    value=$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    if [ $status -ne 0 ] || [ -z "$value" ]; then
        report_problem "$severity" "$label" "$key" "is not set" "$item" "$hint"
    elif [[ "$value" == *JALEN_MUST_SET* ]]; then
        report_problem "$severity" "$label" "$key" "is still a placeholder" "$item" "$hint"
    else
        phrase=$("$validator" "$value")
        if [ -n "$phrase" ]; then
            report_problem "$severity" "$label" "$key" "$phrase" "$item" "$hint"
        else
            ok "$key"
        fi
    fi
}

valid_site_host() {
    if ! [[ $1 =~ $HOST_PATTERN ]]; then
        echo "is not a lowercase host name (no https:// and no path)"
    elif [[ $1 == *-projects.vercel.app ]]; then
        echo "is a *-projects.vercel.app address, which sends visitors to the Vercel login"
    fi
}

valid_support_email() {
    if ! [[ $1 =~ $EMAIL_PATTERN ]]; then
        echo "is not an email address"
    elif [[ $1 == *@example.* ]]; then
        echo "is an example address"
    fi
}

valid_polar_host() {
    if [ "$configuration" = "Release" ]; then
        [ "$1" = "api.polar.sh" ] || echo "must be api.polar.sh in a Release build (it is $1)"
    else
        [ "$1" = "api.polar.sh" ] || [ "$1" = "sandbox-api.polar.sh" ] ||
            echo "must be api.polar.sh or sandbox-api.polar.sh (it is $1)"
    fi
}

valid_uuid() {
    local digits rest
    if ! [[ $1 =~ $UUID_V4_PATTERN ]]; then
        echo "is not a lowercase UUID v4"
        return
    fi
    # All zeros apart from the version and variant digits a v4 UUID must carry.
    digits=${1//-/}
    rest="${digits:0:12}${digits:13:3}${digits:17}"
    [[ $rest =~ ^0+$ ]] && echo "is all zeros"
}

valid_slug() {
    [[ $1 =~ $SLUG_PATTERN ]] || echo "is not a Polar organization slug"
}

valid_gumroad() {
    [ "$1" = "none" ] || [[ $1 =~ $GUMROAD_PATTERN ]] || echo "is neither none nor a Gumroad product id"
}

valid_sparkle_key() {
    local length
    if [[ $1 =~ $BASE64_PATTERN ]] && [ $((${#1} % 4)) -eq 0 ]; then
        length=$(printf '%s' "$1" | base64 --decode 2>/dev/null | wc -c | tr -d ' ')
        [ "$length" = "32" ] && return
    fi
    echo "is not a base64 key of 32 bytes (a key that contains // must be written with /\$()/ in its place, because xcconfig reads // as a comment)"
}

check_setapp_key() {
    local pem="$root/Config/Setapp/setappPublicKey.pem"
    local where="Config/Setapp/setappPublicKey.pem"
    local hint="Setapp developer account → Apps → Add new version → Download public key, then commit it (it is public)."
    local problem=""
    if [ ! -f "$pem" ]; then
        problem="is missing"
    elif ! grep -q -- '-----BEGIN PUBLIC KEY-----' "$pem"; then
        problem="has no -----BEGIN PUBLIC KEY----- block"
    elif ! openssl pkey -pubin -in "$pem" -noout >/dev/null 2>&1; then
        problem="is not a public key openssl can read"
    fi
    if [ -n "$problem" ]; then
        report_problem "$severity" "$where" "setappPublicKey.pem" "$problem" "J14" "$hint"
    else
        ok "setappPublicKey.pem"
    fi
}

check_setapp_bundle_id() {
    # Only Xcode provides the bundle id, so only the build phase checks it; it is an error in every configuration.
    [ "$mode" = "env" ] || return 0
    local bundle_id=${PRODUCT_BUNDLE_IDENTIFIER:-}
    if [ "$bundle_id" = "$SETAPP_BUNDLE_ID" ]; then
        ok "PRODUCT_BUNDLE_IDENTIFIER"
    else
        echo "error: project-setapp.yml: PRODUCT_BUNDLE_IDENTIFIER is \"$bundle_id\", not $SETAPP_BUNDLE_ID. Build the Setapp flavor from project-setapp.yml only. See SPEC-v2 §14.2.2."
        problems=$((problems + 1))
        errors=$((errors + 1))
    fi
}

if [ "$flavor" = "paid" ]; then
    if [ "$configuration" = "Release" ]; then
        organization_item="J1"
        organization_hint="Polar dashboard → Settings → Organization → ID."
        benefit_item="J2"
        benefit_hint="Polar dashboard → Products → Otto for Mac → License Keys benefit → ID."
    else
        organization_item="J3"
        organization_hint="Polar sandbox dashboard (sandbox.polar.sh) → Settings → Organization → ID."
        benefit_item="J3"
        benefit_hint="Polar sandbox dashboard (sandbox.polar.sh) → Products → Otto for Mac → License Keys benefit → ID."
    fi
    check OTTO_SITE_HOST "J8" "The site's permanent host, from Vercel → otto → Settings → Domains." valid_site_host
    check OTTO_SUPPORT_EMAIL "J11" "The public address buyers write to for support." valid_support_email
    check OTTO_POLAR_API_HOST "" "Leave the committed values: api.polar.sh, and sandbox-api.polar.sh for Debug." valid_polar_host
    check OTTO_POLAR_ORGANIZATION_ID "$organization_item" "$organization_hint" valid_uuid
    check OTTO_POLAR_BENEFIT_ID "$benefit_item" "$benefit_hint" valid_uuid
    check OTTO_POLAR_PORTAL_SLUG "J1" "Polar dashboard → Settings → Organization → Slug." valid_slug
    check OTTO_GUMROAD_PRODUCT_ID "J13" "Write none to refuse Gumroad keys, or the product id from Gumroad → Products → Otto." valid_gumroad
    check OTTO_SPARKLE_PUBLIC_ED_KEY "J6" "Run Sparkle's generate_keys on Jalen's Mac and paste the public key it prints." valid_sparkle_key
else
    check_setapp_key
    check_setapp_bundle_id
fi

if [ "$errors" -gt 0 ]; then
    exit 1
fi
exit 0
