#!/bin/bash
#
# audit_flavor.sh
# Otto
#
# Checks that a built Otto.app contains exactly what its flavor may contain (SPEC-v2 §14.2.4). The table and its
# regexes live only here: agents, integrators, CI and release.sh call this script instead of retyping them.
#
#   audit_flavor.sh --flavor source|paid|setapp [--configuration Release|Debug] [--expect-wired] [--distribution]
#                   <path/to/Otto.app>
#
#   --configuration Debug  also reads Contents/MacOS/Otto.debug.dylib (Xcode's Debug products keep the app code
#                          there) and skips the lipo row and the Setapp public key row
#   --expect-wired         also checks the "present" cells (paid: Sparkle linked and embedded, both license API hosts,
#                          the three symbols; setapp: SetappManager). Before the license engine is wired, dead-code
#                          stripping may drop them, so only the WMc integrator and release.sh pass it
#   --distribution         also requires no .xpc anywhere in the app (release.sh removes Sparkle's XPC services)
#
# Exit: 0 when every checked row holds, 1 with one FAIL line per failed row, 2 for usage errors or a missing bundle.

set -u

# usage [STATUS]: prints the usage (to stdout for --help, stderr otherwise) and exits with STATUS (2).
usage() {
    local status=${1:-2}
    if [ "$status" -eq 0 ]; then exec 3>&1; else exec 3>&2; fi
    cat >&3 <<'EOF'
usage: audit_flavor.sh --flavor source|paid|setapp [--configuration Release|Debug] [--expect-wired] [--distribution]
                       <path/to/Otto.app>
EOF
    exit "$status"
}

fail_usage() {
    echo "audit_flavor.sh: $1" >&2
    usage
}

flavor=""
configuration="Release"
expect_wired=0
distribution=0
app=""

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
        --expect-wired)
            expect_wired=1
            shift
            ;;
        --distribution)
            distribution=1
            shift
            ;;
        -h | --help)
            usage 0
            ;;
        -*)
            fail_usage "unknown option $1"
            ;;
        *)
            [ -z "$app" ] || fail_usage "only one app bundle, please"
            app=$1
            shift
            ;;
    esac
done

case "$flavor" in
    source | paid | setapp) ;;
    "") fail_usage "--flavor is required" ;;
    *) fail_usage "unknown flavor $flavor (source, paid or setapp)" ;;
esac
case "$configuration" in
    Release | Debug) ;;
    *) fail_usage "unknown configuration $configuration (Release or Debug)" ;;
esac
[ -n "$app" ] || fail_usage "the path to Otto.app is required"
app=${app%/}
executable="$app/Contents/MacOS/Otto"
info_plist="$app/Contents/Info.plist"
if [ ! -d "$app" ] || [ ! -f "$executable" ] || [ ! -f "$info_plist" ]; then
    echo "audit_flavor.sh: $app is not an app bundle with Contents/MacOS/Otto and Contents/Info.plist" >&2
    exit 2
fi
for tool in otool strings nm plutil lipo xcrun; do
    command -v "$tool" >/dev/null 2>&1 || { echo "audit_flavor.sh: $tool is not available" >&2; exit 2; }
done

# The binaries whose union the binary rows read.
binaries=("$executable")
if [ "$configuration" = "Debug" ] && [ -f "$app/Contents/MacOS/Otto.debug.dylib" ]; then
    binaries+=("$app/Contents/MacOS/Otto.debug.dylib")
fi

failures=0
pass() { echo "ok   $1"; }
fail() {
    echo "FAIL $1"
    failures=$((failures + 1))
}

linked=$(for binary in "${binaries[@]}"; do otool -L "$binary"; done)
text=$(for binary in "${binaries[@]}"; do strings -a "$binary"; done)
symbols=$(for binary in "${binaries[@]}"; do nm -m "$binary" 2>/dev/null; done | xcrun swift-demangle)
info=$(plutil -p "$info_plist")

# Prints the distinct matches of an extended regex in the given text.
matches() {
    printf '%s\n' "$2" | grep -oE "$1" | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# Row: otool -L …/Otto
case "$flavor" in
    source)
        found=$(matches 'Sparkle|Setapp' "$linked")
        [ -z "$found" ] && pass "otool -L links no Sparkle and no Setapp" || fail "otool -L links $found"
        ;;
    paid)
        if [ "$expect_wired" -eq 1 ]; then
            printf '%s\n' "$linked" | grep -q '@rpath/Sparkle.framework/' &&
                pass "otool -L links @rpath/Sparkle.framework" || fail "otool -L doesn't link @rpath/Sparkle.framework"
        fi
        ;;
    setapp)
        found=$(matches 'Sparkle' "$linked")
        [ -z "$found" ] && pass "otool -L links no Sparkle" || fail "otool -L links $found"
        ;;
esac

# Row: Contents/Frameworks
frameworks_dir="$app/Contents/Frameworks"
case "$flavor" in
    source | setapp)
        [ ! -e "$frameworks_dir" ] && pass "Contents/Frameworks is absent" ||
            fail "Contents/Frameworks exists: $(ls "$frameworks_dir" | tr '\n' ' ')"
        ;;
    paid)
        others=""
        if [ -d "$frameworks_dir" ]; then
            others=$(ls "$frameworks_dir" | grep -vx 'Sparkle.framework' | tr '\n' ' ')
        fi
        if [ -n "$others" ]; then
            fail "Contents/Frameworks holds more than Sparkle.framework: $others"
        elif [ "$expect_wired" -eq 1 ] && [ ! -d "$frameworks_dir/Sparkle.framework" ]; then
            fail "Contents/Frameworks has no Sparkle.framework"
        else
            pass "Contents/Frameworks holds Sparkle.framework only"
        fi
        ;;
esac

# Row: strings -a …/Otto | grep -E 'api\.polar\.sh|api\.gumroad\.com'
hosts=$(matches 'api\.polar\.sh|api\.gumroad\.com' "$text")
case "$flavor" in
    source | setapp)
        [ -z "$hosts" ] && pass "strings name no license API host" || fail "strings name $hosts"
        ;;
    paid)
        if [ "$expect_wired" -eq 1 ]; then
            [ "$hosts" = "api.gumroad.com api.polar.sh" ] && pass "strings name api.polar.sh and api.gumroad.com" ||
                fail "strings name '${hosts}', not both api.polar.sh and api.gumroad.com"
        fi
        ;;
esac

# Row: nm -m …/Otto | swift demangle | grep -E 'LicenseController|PolarLicenseBackend|SPUStandardUpdaterController|SetappManager'
found=$(matches 'LicenseController|PolarLicenseBackend|SPUStandardUpdaterController|SetappManager' "$symbols")
case "$flavor" in
    source)
        [ -z "$found" ] && pass "no license, Sparkle or Setapp symbols" || fail "symbols include $found"
        ;;
    paid)
        unexpected=$(matches 'SetappManager' "$found")
        if [ -n "$unexpected" ]; then
            fail "symbols include $unexpected"
        elif [ "$expect_wired" -eq 1 ] && [ "$found" != "LicenseController PolarLicenseBackend SPUStandardUpdaterController" ]; then
            fail "symbols are '${found}', not LicenseController, PolarLicenseBackend and SPUStandardUpdaterController"
        else
            pass "no Setapp symbols${found:+ (found: $found)}"
        fi
        ;;
    setapp)
        unexpected=$(matches 'LicenseController|PolarLicenseBackend|SPUStandardUpdaterController' "$found")
        if [ -n "$unexpected" ]; then
            fail "symbols include $unexpected"
        elif [ "$expect_wired" -eq 1 ] && [ "$found" != "SetappManager" ]; then
            fail "symbols don't include SetappManager"
        else
            pass "no license or Sparkle symbols${found:+ (found: $found)}"
        fi
        ;;
esac

# Row: plutil -p …/Info.plist | grep -E 'SUFeedURL|SUPublicEDKey|OttoPolar'
keys=$(printf '%s\n' "$info" | grep -E 'SUFeedURL|SUPublicEDKey|OttoPolar')
case "$flavor" in
    source | setapp)
        [ -z "$keys" ] && pass "Info.plist has no Sparkle or Polar keys" ||
            fail "Info.plist has $(matches 'SUFeedURL|SUPublicEDKey|OttoPolar[A-Za-z]*' "$keys")"
        ;;
    paid)
        missing=""
        for key in SUFeedURL SUPublicEDKey OttoPolarAPIHost OttoPolarOrganizationID OttoPolarBenefitID OttoPolarPortalSlug; do
            printf '%s\n' "$keys" | grep -q "\"$key\"" || missing="$missing $key"
        done
        if [ -n "$missing" ]; then
            fail "Info.plist lacks$missing"
        elif printf '%s\n' "$keys" | grep -q '\$('; then
            fail "Info.plist has unexpanded values: $(printf '%s\n' "$keys" | grep '\$(' | tr -s ' ' | tr '\n' ';')"
        else
            pass "Info.plist has SUFeedURL, SUPublicEDKey and the OttoPolar keys, expanded"
        fi
        ;;
esac

# Row: plutil -extract CFBundleIdentifier raw …/Info.plist
bundle_id=$(plutil -extract CFBundleIdentifier raw "$info_plist" 2>/dev/null)
case "$flavor" in
    source | paid) expected_id="com.jalenedusei.otto" ;;
    setapp) expected_id="com.jalenedusei.otto-setapp" ;;
esac
[ "$bundle_id" = "$expected_id" ] && pass "CFBundleIdentifier is $expected_id" ||
    fail "CFBundleIdentifier is '${bundle_id}', not $expected_id"

# Row: …/Contents/Resources/setappPublicKey.pem (a Debug Setapp build has none until J14)
pem="$app/Contents/Resources/setappPublicKey.pem"
case "$flavor" in
    source | paid)
        [ ! -e "$pem" ] && pass "no setappPublicKey.pem" || fail "Contents/Resources/setappPublicKey.pem exists"
        ;;
    setapp)
        if [ "$configuration" = "Release" ]; then
            [ -f "$pem" ] && pass "Contents/Resources/setappPublicKey.pem is present" ||
                fail "Contents/Resources/setappPublicKey.pem is missing"
        fi
        ;;
esac

# Row: find …/Otto.app -name '*.xpc' (only with --distribution)
if [ "$distribution" -eq 1 ]; then
    xpc=$(find "$app" -name '*.xpc' | sed "s#^$app/##" | tr '\n' ' ')
    [ -z "$xpc" ] && pass "no .xpc in the app" || fail "the app still carries $xpc"
fi

# Row: lipo -archs …/Otto (Release only)
if [ "$configuration" = "Release" ]; then
    archs=$(lipo -archs "$executable" 2>/dev/null | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')
    [ "$archs" = "arm64 x86_64" ] && pass "lipo -archs: x86_64 arm64" || fail "lipo -archs is '${archs}', not x86_64 arm64"
fi

if [ "$failures" -gt 0 ]; then
    echo "audit_flavor.sh: $failures row(s) failed for the $flavor flavor ($configuration): $app"
    exit 1
fi
echo "audit_flavor.sh: every checked row holds for the $flavor flavor ($configuration)"
exit 0
