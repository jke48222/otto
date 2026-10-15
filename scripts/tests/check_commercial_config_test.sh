#!/bin/bash
#
# check_commercial_config_test.sh
# Otto
#
# Tests scripts/check_commercial_config.sh (SPEC-v2 §14.3, §14.17.2) against the fixtures in
# scripts/tests/fixtures/commercial: the placeholder file, a valid configuration, each malformed value, the Setapp
# public key, Setapp AI's OAuth client (J22) and bundle id, and usage errors. Every run starts from an empty environment, so nothing from the
# calling shell or an Xcode build leaks in.
#
#   bash scripts/tests/check_commercial_config_test.sh

set -u

repo=$(cd "$(dirname "$0")/../.." && pwd)
checker="$repo/scripts/check_commercial_config.sh"
fixtures="$repo/scripts/tests/fixtures/commercial"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/check_commercial_config_test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

passed=0
failed=0
output=""
status=0

# run [VAR=value …] -- ARGS…: runs the checker in an empty environment (plus the given variables).
run() {
    local vars=()
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do
        vars+=("$1")
        shift
    done
    shift
    output=$(cd "$repo" && env -i PATH="$PATH" HOME="${HOME:-/}" ${vars[@]+"${vars[@]}"} bash "$checker" "$@" 2>&1)
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

expect_no_line() {
    if printf '%s\n' "$output" | grep -qE -- "$1"; then fail "$2: unexpected line matching /$1/"; else pass; fi
}

expect_line_count() {
    local count
    count=$(printf '%s\n' "$output" | grep -cE -- "$1")
    if [ "$count" -eq "$2" ]; then pass; else fail "$3: $count lines matching /$1/, expected $2"; fi
}

# MARK: - The placeholder file

run -- --flavor paid --configuration Release --xcconfig "$fixtures/placeholders.xcconfig"
expect_status 1 "placeholders, Release"
expect_line_count '^error: ' 7 "placeholders, Release: one error per setting"
for pair in OTTO_SITE_HOST:J8 OTTO_SUPPORT_EMAIL:J11 OTTO_POLAR_ORGANIZATION_ID:J1 OTTO_POLAR_BENEFIT_ID:J2 \
    OTTO_POLAR_PORTAL_SLUG:J1 OTTO_GUMROAD_PRODUCT_ID:J13 OTTO_SPARKLE_PUBLIC_ED_KEY:J6; do
    key=${pair%%:*}
    item=${pair##*:}
    expect_line "^error: .*placeholders\.xcconfig: $key is still a placeholder \($item\)\. .+ See SPEC-v2 §14\.20\.$" \
        "placeholders, Release: $key"
done
expect_no_line 'OTTO_POLAR_API_HOST' "placeholders, Release: the committed Polar host is valid"

run -- --flavor paid --configuration Debug --xcconfig "$fixtures/placeholders.xcconfig"
expect_status 0 "placeholders, Debug"
expect_line_count '^warning: ' 7 "placeholders, Debug: one warning per setting"
expect_no_line '^error: ' "placeholders, Debug: no errors"
expect_line '^warning: .*OTTO_POLAR_ORGANIZATION_ID is still a placeholder \(J3\)\. Polar sandbox' \
    "placeholders, Debug: the sandbox organization is J3"
expect_line '^warning: .*OTTO_POLAR_BENEFIT_ID is still a placeholder \(J3\)\.' "placeholders, Debug: the sandbox benefit is J3"

run -- --flavor paid --xcconfig "$fixtures/placeholders.xcconfig"
expect_status 1 "placeholders, the configuration defaults to Release"

# The committed file fails Release exactly while it still has a placeholder (until Jalen's values land at HM1).
run -- --flavor paid --configuration Release --xcconfig Config/Commercial.xcconfig
if grep -q 'JALEN_MUST_SET' "$repo/Config/Commercial.xcconfig"; then
    expect_status 1 "committed Config/Commercial.xcconfig with placeholders"
    expect_line '^error: Config/Commercial\.xcconfig: ' "committed file: errors name the file"
else
    expect_status 0 "committed Config/Commercial.xcconfig without placeholders"
fi

# MARK: - Valid values

run -- --flavor paid --configuration Release --xcconfig "$fixtures/valid.xcconfig"
expect_status 0 "valid, Release"
if [ -z "$output" ]; then pass; else fail "valid, Release: prints nothing without --report"; fi

run -- --flavor paid --configuration Release --xcconfig "$fixtures/valid.xcconfig" --report
expect_status 0 "valid, --report"
expect_line_count '^ok OTTO_' 8 "valid, --report: one ok line per setting"

run -- --flavor paid --configuration Debug --xcconfig "$fixtures/valid.xcconfig"
expect_status 0 "valid, Debug"
if [ -z "$output" ]; then pass; else fail "valid, Debug: no warnings"; fi

run -- --flavor paid --xcconfig "$fixtures/gumroad-none.xcconfig" --report
expect_status 0 "Gumroad none"
expect_line '^ok OTTO_GUMROAD_PRODUCT_ID$' "Gumroad none is an explicit, valid choice"

run -- --flavor paid --xcconfig "$fixtures/sparkle-key-escaped.xcconfig"
expect_status 0 "a Sparkle key with // written as /\$()/"

# MARK: - Malformed values

run -- --flavor paid --configuration Release --xcconfig "$fixtures/sandbox-release.xcconfig"
expect_status 1 "the sandbox host in Release"
expect_line '^error: .*OTTO_POLAR_API_HOST must be api\.polar\.sh in a Release build' "the sandbox host in Release"
expect_line_count '^error: ' 1 "the sandbox host in Release is the only problem"

run -- --flavor paid --configuration Debug --xcconfig "$fixtures/sandbox-release.xcconfig"
expect_status 0 "the sandbox host in Debug"

run -- --flavor paid --xcconfig "$fixtures/team-alias-host.xcconfig"
expect_status 1 "the team-alias host"
expect_line '^error: .*OTTO_SITE_HOST is a \*-projects\.vercel\.app address.*\(J8\)' "the team-alias host"

run -- --flavor paid --xcconfig "$fixtures/sparkle-key-truncated.xcconfig"
expect_status 1 "a Sparkle key cut short by //"
expect_line '^error: .*OTTO_SPARKLE_PUBLIC_ED_KEY is not a base64 key of 32 bytes.*/\$\(\)/.*\(J6\)' \
    "a Sparkle key cut short by // names the /\$()/ fix"

run -- --flavor paid --xcconfig "$fixtures/bad-uuid.xcconfig"
expect_status 1 "a bad UUID"
expect_line '^error: .*OTTO_POLAR_BENEFIT_ID is not a lowercase UUID v4 \(J2\)' "a bad UUID"

printf 'OTTO_SITE_HOST = otto-fixture.test\n' > "$scratch/partial.xcconfig"
run -- --flavor paid --xcconfig "$scratch/partial.xcconfig"
expect_status 1 "missing settings"
expect_line '^error: .*OTTO_SUPPORT_EMAIL is not set \(J11\)' "a missing setting is reported as not set"
expect_line_count '^error: ' 7 "every missing setting is reported"

sed 's/^OTTO_POLAR_ORGANIZATION_ID = .*/OTTO_POLAR_ORGANIZATION_ID = 00000000-0000-4000-8000-000000000000/' \
    "$fixtures/valid.xcconfig" > "$scratch/zeros.xcconfig"
run -- --flavor paid --xcconfig "$scratch/zeros.xcconfig"
expect_status 1 "an all-zero UUID"
expect_line 'OTTO_POLAR_ORGANIZATION_ID is all zeros \(J1\)' "an all-zero UUID"

sed 's/^OTTO_SUPPORT_EMAIL = .*/OTTO_SUPPORT_EMAIL = support@example.com/' "$fixtures/valid.xcconfig" > "$scratch/example.xcconfig"
run -- --flavor paid --xcconfig "$scratch/example.xcconfig"
expect_status 1 "an example support address"
expect_line 'OTTO_SUPPORT_EMAIL is an example address \(J11\)' "an example support address"

# MARK: - Build environment (the pre-build phase)

valid_env=(OTTO_SITE_HOST=otto-fixture.test OTTO_SUPPORT_EMAIL=help@otto-fixture.test OTTO_POLAR_API_HOST=api.polar.sh
    OTTO_POLAR_ORGANIZATION_ID=3b0d8c2e-5f1a-4e6b-9c7d-2a4f6e8b0c1d
    OTTO_POLAR_BENEFIT_ID=c4e6a8b0-2d4f-4b6d-8f0a-6c8e0a2c4e6f OTTO_POLAR_PORTAL_SLUG=otto-fixture
    OTTO_GUMROAD_PRODUCT_ID=none OTTO_SPARKLE_PUBLIC_ED_KEY=KOMFi2KJbii7Uyn/YoVI+QwuGpI/0F20G0ZuYb+1F4I=)

run SRCROOT="$repo" CONFIGURATION=Release PRODUCT_BUNDLE_IDENTIFIER=com.jalenedusei.otto "${valid_env[@]}" -- \
    --flavor paid --from-build-env
expect_status 0 "build environment, valid"

run SRCROOT="$repo" CONFIGURATION=Release "${valid_env[@]}" OTTO_SITE_HOST=JALEN_MUST_SET_SITE_HOST -- \
    --flavor paid --from-build-env
expect_status 1 "build environment, a placeholder in Release"
expect_line '^error: Config/Commercial\.xcconfig: OTTO_SITE_HOST is still a placeholder \(J8\)' \
    "build environment, a placeholder in Release"

run SRCROOT="$repo" CONFIGURATION=Debug "${valid_env[@]}" OTTO_SITE_HOST=JALEN_MUST_SET_SITE_HOST -- \
    --flavor paid --from-build-env
expect_status 0 "build environment, a placeholder in Debug"
expect_line '^warning: Config/Commercial\.xcconfig: OTTO_SITE_HOST is still a placeholder' \
    "build environment, a placeholder in Debug warns"

# MARK: - Setapp public key and bundle id

make_root() {
    rm -rf "$scratch/root"
    mkdir -p "$scratch/root/Config/Setapp"
    [ -n "$1" ] && cp "$1" "$scratch/root/Config/Setapp/setappPublicKey.pem"
    return 0
}

make_root ""
run SRCROOT="$scratch/root" CONFIGURATION=Release PRODUCT_BUNDLE_IDENTIFIER=com.jalenedusei.otto-setapp -- \
    --flavor setapp --from-build-env
expect_status 1 "Setapp key missing, Release"
expect_line '^error: Config/Setapp/setappPublicKey\.pem: setappPublicKey\.pem is missing \(J14\)\. Setapp developer account' \
    "Setapp key missing, Release"

run SRCROOT="$scratch/root" CONFIGURATION=Debug PRODUCT_BUNDLE_IDENTIFIER=com.jalenedusei.otto-setapp -- \
    --flavor setapp --from-build-env
expect_status 0 "Setapp key missing, Debug"
expect_line '^warning: Config/Setapp/setappPublicKey\.pem: setappPublicKey\.pem is missing \(J14\)' \
    "Setapp key missing, Debug warns"

make_root "$fixtures/setappPublicKey-garbled.pem"
run SRCROOT="$scratch/root" CONFIGURATION=Release PRODUCT_BUNDLE_IDENTIFIER=com.jalenedusei.otto-setapp -- \
    --flavor setapp --from-build-env
expect_status 1 "Setapp key garbled"
expect_line 'setappPublicKey\.pem is not a public key openssl can read \(J14\)' "Setapp key garbled"

printf 'not a PEM file\n' > "$scratch/no-block.pem"
make_root "$scratch/no-block.pem"
run SRCROOT="$scratch/root" CONFIGURATION=Release PRODUCT_BUNDLE_IDENTIFIER=com.jalenedusei.otto-setapp -- \
    --flavor setapp --from-build-env
expect_status 1 "Setapp key without a PEM block"
expect_line 'setappPublicKey\.pem has no -----BEGIN PUBLIC KEY----- block \(J14\)' "Setapp key without a PEM block"

# Setapp AI's OAuth client (J22) as a build would pass it; the secret must never reach the output.
fixture_secret="s3cr3t-fixture-value-9f2c"
setapp_ai_env=(OTTO_SETAPP_AI_CLIENT_ID=otto-fixture-setapp-ai-client "OTTO_SETAPP_AI_CLIENT_SECRET=$fixture_secret")

make_root "$fixtures/setappPublicKey.pem"
run SRCROOT="$scratch/root" CONFIGURATION=Release PRODUCT_BUNDLE_IDENTIFIER=com.jalenedusei.otto-setapp \
    "${setapp_ai_env[@]}" -- --flavor setapp --from-build-env --report
expect_status 0 "Setapp key valid"
expect_line '^ok setappPublicKey\.pem$' "Setapp key valid"
expect_line '^ok PRODUCT_BUNDLE_IDENTIFIER$' "Setapp bundle id valid"

for configuration in Debug Release; do
    run SRCROOT="$scratch/root" CONFIGURATION=$configuration PRODUCT_BUNDLE_IDENTIFIER=com.jalenedusei.otto -- \
        --flavor setapp --from-build-env
    expect_status 1 "wrong Setapp bundle id, $configuration"
    expect_line '^error: project-setapp\.yml: PRODUCT_BUNDLE_IDENTIFIER is "com\.jalenedusei\.otto", not com\.jalenedusei\.otto-setapp\.' \
        "wrong Setapp bundle id is an error in $configuration"
done

# The Setapp flavor checks its key, its Setapp AI client and its bundle id: the paid build's settings don't apply.
run SRCROOT="$scratch/root" CONFIGURATION=Release PRODUCT_BUNDLE_IDENTIFIER=com.jalenedusei.otto-setapp -- \
    --flavor setapp --from-build-env
expect_no_line 'OTTO_(SITE|SUPPORT|POLAR|GUMROAD|SPARKLE)' "Setapp ignores the paid build's settings"

# MARK: - Setapp AI's OAuth client (J22)

make_root "$fixtures/setappPublicKey.pem"
setapp_env=(SRCROOT="$scratch/root" PRODUCT_BUNDLE_IDENTIFIER=com.jalenedusei.otto-setapp)

run "${setapp_env[@]}" CONFIGURATION=Release -- --flavor setapp --from-build-env
expect_status 1 "Setapp AI client missing, Release"
expect_line '^error: Config/Local\.xcconfig: OTTO_SETAPP_AI_CLIENT_ID is not set \(J22\)\. Setapp developer account → Apps → OAuth Clients → Add new, .+ See SPEC-v2 §14\.20\.$' \
    "Setapp AI client id missing, Release"
expect_line '^error: Config/Local\.xcconfig: OTTO_SETAPP_AI_CLIENT_SECRET is not set \(J22\)\.' "Setapp AI secret missing, Release"
expect_line_count '^error: ' 2 "Setapp AI client missing, Release: the two J22 settings are the only problems"

run "${setapp_env[@]}" CONFIGURATION=Debug -- --flavor setapp --from-build-env
expect_status 0 "Setapp AI client missing, Debug"
expect_line_count '^warning: Config/Local\.xcconfig: OTTO_SETAPP_AI_CLIENT_(ID|SECRET) is not set \(J22\)\.' 2 \
    "Setapp AI client missing, Debug warns once per setting"
expect_no_line '^error: ' "Setapp AI client missing, Debug: no errors"

run "${setapp_env[@]}" CONFIGURATION=Release "${setapp_ai_env[@]}" -- --flavor setapp --from-build-env --report
expect_status 0 "Setapp AI client valid"
expect_line '^ok OTTO_SETAPP_AI_CLIENT_ID$' "Setapp AI client id valid"
expect_line '^ok OTTO_SETAPP_AI_CLIENT_SECRET$' "Setapp AI secret valid"
expect_no_line "$fixture_secret" "a valid secret is never printed"

# bad_secret VALUE PHRASE [LEAK]: the secret set to VALUE is reported with PHRASE, and LEAK (part of VALUE) never
# appears in the output.
bad_secret() {
    run "${setapp_env[@]}" CONFIGURATION=Release OTTO_SETAPP_AI_CLIENT_ID=otto-fixture-setapp-ai-client \
        "OTTO_SETAPP_AI_CLIENT_SECRET=$1" -- --flavor setapp --from-build-env
    expect_status 1 "Setapp AI secret '$1'"
    expect_line "^error: Config/Local\.xcconfig: OTTO_SETAPP_AI_CLIENT_SECRET $2 \(J22\)\." "Setapp AI secret '$1'"
    expect_line_count '^error: ' 1 "Setapp AI secret '$1' is the only problem"
    if [ -n "${3:-}" ]; then expect_no_line "$3" "Setapp AI secret '$1' is never printed"; fi
}
bad_secret "" "is not set"
bad_secret "   " "is not set"
bad_secret "JALEN_MUST_SET_SETAPP_AI_CLIENT_SECRET" "is still a placeholder" "JALEN_MUST_SET_SETAPP"
bad_secret 's3cr3t-$(OTTO_OTHER_SETTING)' "refers to another build setting; write the value itself" "OTTO_OTHER_SETTING"
bad_secret "s3cr3t fixture value" "contains spaces" "s3cr3t"
bad_secret "your-oauth-secret" "is the example value from Setapp's documentation" "your-oauth-secret"
bad_secret "YOUR_SECRET_HERE" "is the example value from Setapp's documentation" "YOUR_SECRET_HERE"

# --xcconfig mode: FILE first, then the Local.xcconfig beside it (Config/Setapp.xcconfig includes Local.xcconfig,
# through Signing.xcconfig, before Commercial.xcconfig, so a value in the commercial file wins).
mkdir -p "$scratch/xc"
grep -v '^OTTO_SETAPP_AI_' "$fixtures/valid.xcconfig" > "$scratch/xc/Commercial.xcconfig"
run -- --flavor setapp --configuration Debug --xcconfig "$scratch/xc/Commercial.xcconfig"
expect_line_count '^warning: Config/Local\.xcconfig: OTTO_SETAPP_AI_CLIENT_(ID|SECRET) is not set \(J22\)\.' 2 \
    "--xcconfig without a Local.xcconfig"

printf '%s\n' '// Local signing and secrets.' 'CODE_SIGN_IDENTITY = Apple Development' \
    'OTTO_SETAPP_AI_CLIENT_ID = otto-fixture-setapp-ai-client // the client id' \
    "OTTO_SETAPP_AI_CLIENT_SECRET = $fixture_secret" > "$scratch/xc/Local.xcconfig"
run -- --flavor setapp --configuration Debug --xcconfig "$scratch/xc/Commercial.xcconfig" --report
expect_line '^ok OTTO_SETAPP_AI_CLIENT_ID$' "--xcconfig reads the client id from Local.xcconfig"
expect_line '^ok OTTO_SETAPP_AI_CLIENT_SECRET$' "--xcconfig reads the secret from Local.xcconfig"
expect_no_line 'J22' "--xcconfig with a Local.xcconfig: no J22 problem"
expect_no_line "$fixture_secret" "--xcconfig never prints the secret"

printf '%s\n' 'OTTO_SETAPP_AI_CLIENT_ID = two words' >> "$scratch/xc/Commercial.xcconfig"
run -- --flavor setapp --configuration Debug --xcconfig "$scratch/xc/Commercial.xcconfig"
expect_line '^warning: Config/Local\.xcconfig: OTTO_SETAPP_AI_CLIENT_ID contains spaces \(J22\)\.' \
    "--xcconfig: the commercial file's value wins over Local.xcconfig"

run -- --flavor setapp --configuration Release --xcconfig "$fixtures/valid.xcconfig"
expect_no_line 'J22' "the fixture configuration carries a fixture Setapp AI client"

# --xcconfig mode reads the repository's own key.
run -- --flavor setapp --configuration Release --xcconfig "$fixtures/valid.xcconfig"
if [ -f "$repo/Config/Setapp/setappPublicKey.pem" ]; then
    expect_status 0 "Setapp, --xcconfig, with the committed key"
else
    expect_status 1 "Setapp, --xcconfig, before J14"
    expect_line '^error: Config/Setapp/setappPublicKey\.pem: setappPublicKey\.pem is missing \(J14\)' \
        "Setapp, --xcconfig, before J14"
fi

# MARK: - Usage errors

usage_cases=(
    ""
    "--flavor"
    "--flavor free --xcconfig $fixtures/valid.xcconfig"
    "--flavor paid"
    "--xcconfig $fixtures/valid.xcconfig"
    "--flavor paid --from-build-env --xcconfig $fixtures/valid.xcconfig"
    "--flavor paid --xcconfig $scratch/missing.xcconfig"
    "--flavor paid --xcconfig"
    "--flavor paid --configuration Beta --xcconfig $fixtures/valid.xcconfig"
    "--flavor paid --xcconfig $fixtures/valid.xcconfig --verbose"
    "--flavor paid --from-build-env"
)
for arguments in "${usage_cases[@]}"; do
    # shellcheck disable=SC2086 # each case is a list of words
    run -- $arguments
    expect_status 2 "usage error: '${arguments}'"
    expect_line '^usage: check_commercial_config\.sh' "usage error prints the usage: '${arguments}'"
done

run SRCROOT="$repo" -- --flavor paid --from-build-env
expect_status 2 "usage error: the build environment without CONFIGURATION"

run -- --help
expect_status 0 "--help"
expect_line '^usage: check_commercial_config\.sh' "--help prints the usage"

# MARK: - Syntax

if bash -n "$checker"; then pass; else fail "bash -n check_commercial_config.sh"; fi

echo "check_commercial_config_test.sh: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
