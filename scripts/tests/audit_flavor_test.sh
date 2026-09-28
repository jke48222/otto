#!/bin/bash
#
# audit_flavor_test.sh
# Otto
#
# Tests scripts/audit_flavor.sh (SPEC-v2 §14.2.4, §14.17.2): usage errors and a missing bundle exit 2, and each row
# passes or fails on small stand-in app bundles whose executable is compiled here from a few lines of C. Nothing
# builds Otto.
#
#   bash scripts/tests/audit_flavor_test.sh

set -u

repo=$(cd "$(dirname "$0")/../.." && pwd)
audit="$repo/scripts/audit_flavor.sh"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/audit_flavor_test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

passed=0
failed=0
output=""
status=0

run() {
    output=$(bash "$audit" "$@" 2>&1)
    status=$?
}

pass() {
    passed=$((passed + 1))
}

fail() {
    failed=$((failed + 1))
    echo "FAIL: $1"
    echo "$output" | sed 's/^/    | /'
}

expect_status() {
    if [ "$status" -eq "$1" ]; then pass; else fail "$2: exit $status, expected $1"; fi
}

expect_line() {
    if printf '%s\n' "$output" | grep -qE -- "$1"; then pass; else fail "$2: no line matching /$1/"; fi
}

# MARK: - Syntax and usage

if bash -n "$audit"; then pass; else fail "bash -n audit_flavor.sh"; fi

usage_cases=(
    ""
    "--flavor"
    "--flavor free $scratch"
    "--flavor source"
    "$scratch"
    "--flavor source --configuration Beta $scratch"
    "--flavor source --expect-everything $scratch"
    "--flavor source $scratch $scratch"
)
for arguments in "${usage_cases[@]}"; do
    # shellcheck disable=SC2086 # each case is a list of words
    run $arguments
    expect_status 2 "usage error: '${arguments}'"
    expect_line '^usage: audit_flavor\.sh' "usage error prints the usage: '${arguments}'"
done

run --help
expect_status 0 "--help"

run --flavor source "$scratch/Missing.app"
expect_status 2 "a missing bundle"
expect_line 'is not an app bundle' "a missing bundle is named"

mkdir -p "$scratch/Empty.app/Contents"
run --flavor source "$scratch/Empty.app"
expect_status 2 "a bundle without an executable"

# MARK: - Stand-in bundles

if ! command -v clang >/dev/null 2>&1; then
    echo "audit_flavor_test.sh: clang is missing, so only the usage checks ran"
    echo "audit_flavor_test.sh: $passed passed, $failed failed"
    [ "$failed" -eq 0 ]
    exit
fi

# make_app NAME BUNDLE_ID ARCHS SOURCE: an app bundle whose executable is SOURCE compiled for ARCHS.
make_app() {
    local app="$scratch/$1/Otto.app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    local arch_flags=()
    for arch in $3; do arch_flags+=(-arch "$arch"); done
    # A file, not stdin: clang reads the source once per architecture.
    printf '%s\n' "$4" > "$scratch/$1/main.c"
    clang "${arch_flags[@]}" "$scratch/$1/main.c" -o "$app/Contents/MacOS/Otto" || return 1
    plutil -create xml1 "$app/Contents/Info.plist"
    plutil -insert CFBundleIdentifier -string "$2" "$app/Contents/Info.plist"
    echo "$app"
}

plain_source='int main(void) { return 0; }'
hosts_source='#include <stdio.h>
int main(void) { puts("https://api.polar.sh/v1/"); puts("https://api.gumroad.com/v2/"); return 0; }'

source_app=$(make_app source com.jalenedusei.otto "x86_64 arm64" "$plain_source") || {
    fail "clang couldn't build a universal stand-in"
    echo "audit_flavor_test.sh: $passed passed, $failed failed"
    exit 1
}

run --flavor source "$source_app"
expect_status 0 "a clean source bundle"
expect_line '^ok   lipo -archs: x86_64 arm64$' "a clean source bundle is universal"
expect_line '^ok   CFBundleIdentifier is com\.jalenedusei\.otto$' "a clean source bundle's id"

run --flavor source --distribution "$source_app/"
expect_status 0 "a clean source bundle with --distribution and a trailing slash"
expect_line '^ok   no \.xpc in the app$' "--distribution adds the .xpc row"

plutil -insert SUFeedURL -string "https://otto-fixture.test/appcast.xml" "$source_app/Contents/Info.plist"
run --flavor source "$source_app"
expect_status 1 "a source bundle with SUFeedURL"
expect_line '^FAIL Info\.plist has SUFeedURL$' "a source bundle with SUFeedURL"
plutil -remove SUFeedURL "$source_app/Contents/Info.plist"

mkdir -p "$source_app/Contents/Frameworks/Sparkle.framework"
run --flavor source "$source_app"
expect_status 1 "a source bundle that embeds a framework"
expect_line '^FAIL Contents/Frameworks exists' "a source bundle that embeds a framework"
rm -rf "$source_app/Contents/Frameworks"

hosts_app=$(make_app hosts com.jalenedusei.otto "x86_64 arm64" "$hosts_source")
run --flavor source "$hosts_app"
expect_status 1 "a source bundle that names the license hosts"
expect_line '^FAIL strings name api\.gumroad\.com api\.polar\.sh$' "a source bundle that names the license hosts"

thin_app=$(make_app thin com.jalenedusei.otto "arm64" "$plain_source")
run --flavor source "$thin_app"
expect_status 1 "a single-architecture Release bundle"
expect_line "^FAIL lipo -archs is 'arm64', not x86_64 arm64$" "a single-architecture Release bundle"
run --flavor source --configuration Debug "$thin_app"
expect_status 0 "Debug skips the lipo row"

# Setapp: its bundle id and public key.
setapp_app=$(make_app setapp com.jalenedusei.otto-setapp "x86_64 arm64" "$plain_source")
run --flavor setapp "$setapp_app"
expect_status 1 "a Setapp Release bundle without its public key"
expect_line '^FAIL Contents/Resources/setappPublicKey\.pem is missing$' "a Setapp Release bundle without its public key"
run --flavor setapp --configuration Debug "$setapp_app"
expect_status 0 "Debug skips the Setapp public key row"
cp "$repo/scripts/tests/fixtures/commercial/setappPublicKey.pem" "$setapp_app/Contents/Resources/"
run --flavor setapp "$setapp_app"
expect_status 0 "a Setapp Release bundle with its public key"
run --flavor source "$setapp_app"
expect_status 1 "the source audit of a Setapp bundle"
expect_line "^FAIL CFBundleIdentifier is 'com\.jalenedusei\.otto-setapp', not com\.jalenedusei\.otto$" \
    "the source audit of a Setapp bundle names the bundle id"
expect_line '^FAIL Contents/Resources/setappPublicKey\.pem exists$' "the source audit of a Setapp bundle names the key"

# Paid: the Info.plist keys are always checked; the "present" cells only with --expect-wired.
paid_app=$(make_app paid com.jalenedusei.otto "x86_64 arm64" "$plain_source")
run --flavor paid "$paid_app"
expect_status 1 "a paid bundle without the Sparkle and Polar keys"
expect_line '^FAIL Info\.plist lacks SUFeedURL SUPublicEDKey OttoPolarAPIHost' "a paid bundle without its keys"
plist="$paid_app/Contents/Info.plist"
plutil -insert SUFeedURL -string "https://otto-fixture.test/appcast.xml" "$plist"
plutil -insert SUPublicEDKey -string "KOMFi2KJbii7Uyn/YoVI+QwuGpI/0F20G0ZuYb+1F4I=" "$plist"
plutil -insert OttoPolarAPIHost -string "api.polar.sh" "$plist"
plutil -insert OttoPolarOrganizationID -string "3b0d8c2e-5f1a-4e6b-9c7d-2a4f6e8b0c1d" "$plist"
plutil -insert OttoPolarBenefitID -string "c4e6a8b0-2d4f-4b6d-8f0a-6c8e0a2c4e6f" "$plist"
plutil -insert OttoPolarPortalSlug -string '$(OTTO_POLAR_PORTAL_SLUG)' "$plist"
run --flavor paid "$paid_app"
expect_status 1 "a paid bundle with an unexpanded value"
expect_line '^FAIL Info\.plist has unexpanded values' "a paid bundle with an unexpanded value"
plutil -replace OttoPolarPortalSlug -string "otto-fixture" "$plist"
run --flavor paid "$paid_app"
expect_status 0 "a paid bundle before the engine is wired"
run --flavor paid --expect-wired "$paid_app"
expect_status 1 "a paid bundle that isn't wired, with --expect-wired"
expect_line "^FAIL otool -L doesn't link @rpath/Sparkle\.framework$" "--expect-wired checks Sparkle is linked"
expect_line '^FAIL Contents/Frameworks has no Sparkle\.framework$' "--expect-wired checks Sparkle is embedded"
expect_line "^FAIL strings name '', not both api\.polar\.sh and api\.gumroad\.com$" "--expect-wired checks the hosts"
expect_line '^FAIL symbols are' "--expect-wired checks the symbols"

mkdir -p "$paid_app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"
run --flavor paid --distribution "$paid_app"
expect_status 1 "a paid bundle that still carries Sparkle's XPC services"
expect_line '^FAIL the app still carries Contents/Frameworks/Sparkle\.framework/Versions/B/XPCServices/Installer\.xpc' \
    "--distribution names the .xpc"
mkdir -p "$paid_app/Contents/Frameworks/Other.framework"
run --flavor paid "$paid_app"
expect_line '^FAIL Contents/Frameworks holds more than Sparkle\.framework: Other\.framework' \
    "a paid bundle embeds only Sparkle"

echo "audit_flavor_test.sh: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
