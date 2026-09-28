#!/bin/bash
#
# release_script_test.sh
# Otto
#
# Tests scripts/release.sh and scripts/publish.sh (SPEC-v2 §14.12, §14.17.2) with command shims only: no network, no
# Keychain, no Xcode build, no Vercel and no scripts/site_render.mjs. Each case runs in a scratch copy of the
# repository whose Config/Commercial.xcconfig, project.yml and CHANGELOG.md come from the fixtures, with
# scripts/tests/fixtures/release/shims first on PATH, SPARKLE_BIN at the Sparkle tool shims and OTTO_SITE_DIR at a
# fixture site directory. Every shim logs its calls, so a case can prove a command was never run.
#
#   bash scripts/tests/release_script_test.sh
#
# The one step that runs a real tool: brew style on the cask rendered from the golden fixtures, when Homebrew is
# installed (otherwise the case says it was skipped).

set -u

repo=$(cd "$(dirname "$0")/../.." && pwd)
fixtures="$repo/scripts/tests/fixtures/release"
commercial="$repo/scripts/tests/fixtures/commercial"
# pwd, so the path has no doubled slash: the scripts under test resolve their own root the same way.
scratch=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/release_script_test.XXXXXX")" && pwd)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/tmp"

real_brew=$(command -v brew || true)
shim_path="$fixtures/shims:$PATH"

# The fixture values the canary requests must carry (scripts/tests/fixtures/commercial/valid.xcconfig).
organization_id="3b0d8c2e-5f1a-4e6b-9c7d-2a4f6e8b0c1d"
benefit_id="c4e6a8b0-2d4f-4b6d-8f0a-6c8e0a2c4e6f"
sparkle_key="KOMFi2KJbii7Uyn/YoVI+QwuGpI/0F20G0ZuYb+1F4I="
polar_canary="OTTO-1C285B2D-6CE6-4BC7-B8BE-ADB6A7E304DA"
gumroad_canary="A1B2C3D4-E5F60718-293A4B5C-6D7E8F90"

passed=0
failed=0
output=""
status=0
log="$scratch/shim.log"

pass() {
    passed=$((passed + 1))
}

fail() {
    failed=$((failed + 1))
    echo "FAIL: $1"
    printf '%s\n' "$output" | sed 's/^/    | /'
    if [ -s "$log" ]; then
        echo "    shim log:"
        sed 's/^/    > /' "$log"
    fi
}

expect_status() {
    if [ "$status" -eq "$1" ]; then pass; else fail "$2: exit $status, expected $1"; fi
}

expect_line() {
    if printf '%s\n' "$output" | grep -qE -- "$1"; then pass; else fail "$2: no output line matching /$1/"; fi
}

expect_no_line() {
    if printf '%s\n' "$output" | grep -qE -- "$1"; then fail "$2: unexpected output line matching /$1/"; else pass; fi
}

expect_log() {
    if grep -qE -- "$1" "$log"; then pass; else fail "$2: no shim call matching /$1/"; fi
}

expect_no_log() {
    if grep -qE -- "$1" "$log"; then fail "$2: unexpected shim call matching /$1/"; else pass; fi
}

expect_log_count() {
    local count
    count=$(grep -cE -- "$1" "$log")
    if [ "$count" -eq "$2" ]; then pass; else fail "$3: $count shim calls matching /$1/, expected $2"; fi
}

expect_file() {
    if [ -f "$1" ]; then pass; else fail "$2: $1 is missing"; fi
}

# make_mirror NAME XCCONFIG: a scratch copy of the repository named NAME whose Config/Commercial.xcconfig is XCCONFIG.
make_mirror() {
    local root="$scratch/$1"
    rm -rf "$root"
    mkdir -p "$root/Config" "$root/Otto/Licensing" "$root/packaging"
    cp -R "$repo/scripts" "$root/scripts"
    cp -R "$repo/packaging/homebrew" "$root/packaging/homebrew"
    cp "$2" "$root/Config/Commercial.xcconfig"
    cp "$repo/Otto/Licensing/LicenseContracts.swift" "$root/Otto/Licensing/LicenseContracts.swift"
    cp "$fixtures/project.fixture.yml" "$root/project.yml"
    cp "$fixtures/CHANGELOG.fixture.md" "$root/CHANGELOG.md"
}

# run ROOT SCRIPT [VAR=value …] -- ARGS…: runs ROOT/scripts/SCRIPT in an empty environment with the shims first on
# PATH, plus the given variables. The shim log starts empty.
run() {
    local root=$1 script=$2
    shift 2
    local vars=()
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do
        vars+=("$1")
        shift
    done
    shift
    : >"$log"
    output=$(cd "$root" && env -i PATH="$shim_path" HOME="${HOME:-/}" TMPDIR="$scratch/tmp" SHIM_LOG="$log" \
        SPARKLE_BIN="$fixtures/sparkle-bin" ${vars[@]+"${vars[@]}"} bash "$root/scripts/$script" "$@" 2>&1)
    status=$?
}

# The environment of a Mac that has everything the paid preflight needs, in shim form.
ready=(SHIM_IDENTITY=1 "SHIM_POLAR_CANARY_KEY=$polar_canary" "SHIM_GUMROAD_CANARY_KEY=$gumroad_canary"
    "SHIM_SPARKLE_PUBLIC_KEY=$sparkle_key")

# MARK: - bash -n on every script

while IFS= read -r script; do
    if bash -n "$script" 2>"$scratch/syntax.err"; then
        pass
    else
        output=$(cat "$scratch/syntax.err")
        fail "bash -n $script"
    fi
done < <(find "$repo/scripts" -name '*.sh' -type f; find "$fixtures/shims" "$fixtures/sparkle-bin" -type f -perm -u+x)

# MARK: - release.sh usage

make_mirror placeholder "$repo/Config/Commercial.xcconfig"
placeholder="$scratch/placeholder"

run "$placeholder" release.sh --
expect_status 2 "release.sh without --flavor"
expect_line '^error: --flavor is required' "release.sh without --flavor"
expect_no_log '.' "release.sh without --flavor runs nothing"

run "$placeholder" release.sh -- --flavor source
expect_status 2 "release.sh --flavor source"

run "$placeholder" release.sh -- --flavor paid --notarize-later
expect_status 2 "release.sh with an unknown option"
expect_line '^error: unknown option --notarize-later' "release.sh with an unknown option"

run "$placeholder" release.sh -- --flavor setapp --smoke-test
expect_status 2 "release.sh --flavor setapp --smoke-test"

run "$placeholder" release.sh -- --help
expect_status 0 "release.sh --help"
expect_line '--preflight-only' "release.sh --help"

# MARK: - release.sh preflight with the placeholder configuration

run "$placeholder" release.sh "OTTO_SITE_DIR=$fixtures/site-placeholder" -- --flavor paid --preflight-only --no-notarize
expect_status 1 "placeholders"
for pair in OTTO_SITE_HOST:J8 OTTO_SUPPORT_EMAIL:J11 OTTO_POLAR_ORGANIZATION_ID:J1 OTTO_POLAR_BENEFIT_ID:J2 \
    OTTO_POLAR_PORTAL_SLUG:J1 OTTO_GUMROAD_PRODUCT_ID:J13 OTTO_SPARKLE_PUBLIC_ED_KEY:J6; do
    key=${pair%%:*}
    item=${pair##*:}
    expect_line "^error: Config/Commercial\.xcconfig: $key is still a placeholder \($item\)\." "placeholders: $key"
done
expect_line 'commerce\.json: siteHost is still a placeholder \(J8\)' "placeholders: commerce.json siteHost"
expect_line 'commerce\.json: seller\.supportEmail is still a placeholder \(J11\)' "placeholders: commerce.json supportEmail"
expect_line '^error: no Developer ID Application identity .*J7' "placeholders: no Developer ID"
expect_line '^Preflight stage 1 found [0-9]+ problem' "placeholders: stops after stage 1"
expect_no_line 'OTTO_NOTARY_PROFILE' "placeholders: --no-notarize needs no notary profile"
expect_no_log '^xcodebuild ' "placeholders: no xcodebuild call"
expect_no_log '^curl ' "placeholders: no curl call"
expect_no_log '^security find-generic-password' "placeholders: no canary read"
expect_no_log '^(xcodegen|generate_keys) ' "placeholders: stage 3 never runs"

run "$placeholder" release.sh "OTTO_SITE_DIR=$fixtures/site-placeholder" -- --flavor paid --preflight-only
expect_status 1 "placeholders without --no-notarize"
expect_line '^error: OTTO_NOTARY_PROFILE is not set \(J7\)' "placeholders without --no-notarize"

# MARK: - release.sh preflight with the valid fixture configuration

make_mirror valid "$commercial/valid.xcconfig"
valid="$scratch/valid"

run "$valid" release.sh "OTTO_SITE_DIR=$fixtures/site" "${ready[@]}" -- --flavor paid --preflight-only --no-notarize
expect_status 0 "valid fixtures"
expect_line '^Preflight passed \(--preflight-only\)\. Nothing was built\.$' "valid fixtures"
expect_line 'build 2 is newer than every item in appcast\.xml \(highest: 1\)' "valid fixtures: build number"
expect_log_count '^curl https://api\.polar\.sh/v1/customer-portal/license-keys/validate$' 2 \
    "valid fixtures: the version probe and the Polar canary"
expect_log "^curl-body \{\"benefit_id\":\"$benefit_id\",\"key\":\"$polar_canary\",\"organization_id\":\"$organization_id\"\}$" \
    "valid fixtures: the Polar canary carries exactly the fixture IDs"
expect_log "^curl-body \{\"benefit_id\":\"$benefit_id\",\"key\":\"OTTO-[0-9A-F-]{36}\",\"organization_id\":\"$organization_id\"\}$" \
    "valid fixtures: the version probe sends a random key"
expect_log_count '^curl-header Polar-Version: 2026-10$' 2 "valid fixtures: both Polar requests pin 2026-10"
expect_log_count '^curl-header Accept-Language: en$' 3 "valid fixtures: Accept-Language is pinned"
expect_log '^curl https://api\.gumroad\.com/v2/licenses/verify$' "valid fixtures: the Gumroad canary"
expect_log "^curl-body increment_uses_count=false&license_key=$gumroad_canary&product_id=OttoFixtureProduct%3D%3D$" \
    "valid fixtures: the Gumroad canary never counts a use"
expect_log '^security find-generic-password -s otto-release -a polar-canary -w$' "valid fixtures: the J20 item"
expect_log '^security find-generic-password -s otto-release -a gumroad-canary -w$' "valid fixtures: the J21 item"
expect_log '^xcodegen generate --quiet --spec .*/project-paid\.yml$' "valid fixtures: the paid project"
expect_log_count '^xcodebuild ' 1 "valid fixtures: one xcodebuild call"
expect_log '^xcodebuild -resolvePackageDependencies -project OttoPaid\.xcodeproj ' "valid fixtures: package resolution"
expect_log '^generate_keys -p$' "valid fixtures: the Sparkle key check"
first_curl=$(grep -n '^curl ' "$log" | head -n 1 | cut -d: -f1)
first_xcodebuild=$(grep -n '^xcodebuild ' "$log" | head -n 1 | cut -d: -f1)
last_curl=$(grep -n '^curl ' "$log" | tail -n 1 | cut -d: -f1)
if [ -n "$first_curl" ] && [ -n "$first_xcodebuild" ] && [ "$last_curl" -lt "$first_xcodebuild" ]; then
    pass
else
    fail "valid fixtures: stage 3 runs only after every stage 2 request"
fi
if [ "$(grep -c "$polar_canary" "$log")" -eq 1 ]; then
    pass
else
    fail "valid fixtures: the canary key appears only in the request body, never on a command line"
fi

# MARK: - release.sh stage 2 refusals

run "$valid" release.sh "OTTO_SITE_DIR=$fixtures/site" "${ready[@]}" SHIM_CANARY=404 -- \
    --flavor paid --preflight-only --no-notarize
expect_status 1 "canary 404"
expect_line "^error: the Polar canary didn't validate .*\(J20\): HTTP 404" "canary 404"
expect_no_log '^xcodebuild ' "canary 404: stage 3 never runs"

run "$valid" release.sh "OTTO_SITE_DIR=$fixtures/site" SHIM_IDENTITY=1 "SHIM_GUMROAD_CANARY_KEY=$gumroad_canary" \
    "SHIM_SPARKLE_PUBLIC_KEY=$sparkle_key" -- --flavor paid --preflight-only --no-notarize
expect_status 1 "missing canary"
expect_line '^error: no Polar canary key in the login Keychain \(J20; security exit 44\)' "missing canary"
expect_no_log '^xcodebuild ' "missing canary: stage 3 never runs"

run "$valid" release.sh "OTTO_SITE_DIR=$fixtures/site" "${ready[@]}" SHIM_CANARY=limit5 -- \
    --flavor paid --preflight-only --no-notarize
expect_status 1 "canary limit_activations 5"
expect_line "^error: the Polar canary's benefit allows 5 activations, not 3 \(J20, J2\)" "canary limit_activations 5"

run "$valid" release.sh "OTTO_SITE_DIR=$fixtures/site" "${ready[@]}" SHIM_CANARY=revoked -- \
    --flavor paid --preflight-only --no-notarize
expect_status 1 "canary revoked"
expect_line "^error: the Polar canary's status is \"revoked\", not granted \(J20\)" "canary revoked"

run "$valid" release.sh "OTTO_SITE_DIR=$fixtures/site" "${ready[@]}" SHIM_PROBE=bare404 -- \
    --flavor paid --preflight-only --no-notarize
expect_status 1 "version probe without the pinned version"
expect_line '^error: Polar no longer serves API version 2026-10 \(HTTP 404, polar-version: absent\)' \
    "version probe without the pinned version"

run "$valid" release.sh "OTTO_SITE_DIR=$fixtures/site" SHIM_IDENTITY=1 "SHIM_POLAR_CANARY_KEY=$polar_canary" \
    "SHIM_SPARKLE_PUBLIC_KEY=$sparkle_key" -- --flavor paid --preflight-only --no-notarize
expect_status 1 "missing Gumroad canary"
expect_line '^error: no Gumroad canary key in the login Keychain \(J21; security exit 44\)' "missing Gumroad canary"

run "$valid" release.sh "OTTO_SITE_DIR=$fixtures/site" "${ready[@]}" SHIM_GUMROAD=refunded -- \
    --flavor paid --preflight-only --no-notarize
expect_status 1 "refunded Gumroad canary"
expect_line "^error: the Gumroad canary's purchase is refunded, charged back or disputed \(J21\)" "refunded Gumroad canary"

make_mirror gumroad-none "$commercial/gumroad-none.xcconfig"
run "$scratch/gumroad-none" release.sh "OTTO_SITE_DIR=$fixtures/site" SHIM_IDENTITY=1 \
    "SHIM_POLAR_CANARY_KEY=$polar_canary" "SHIM_SPARKLE_PUBLIC_KEY=$sparkle_key" -- \
    --flavor paid --preflight-only --no-notarize
expect_status 0 "Gumroad none"
expect_no_log '(api\.gumroad\.com|gumroad-canary)' "Gumroad none: no Gumroad canary"

# MARK: - release.sh stage 3 refusal

run "$valid" release.sh "OTTO_SITE_DIR=$fixtures/site" SHIM_IDENTITY=1 "SHIM_POLAR_CANARY_KEY=$polar_canary" \
    "SHIM_GUMROAD_CANARY_KEY=$gumroad_canary" "SHIM_SPARKLE_PUBLIC_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" -- \
    --flavor paid --preflight-only --no-notarize
expect_status 1 "Sparkle key mismatch"
expect_line "^error: the Sparkle key in this Mac's login Keychain .* isn't OTTO_SPARKLE_PUBLIC_ED_KEY .*\(J6\)" \
    "Sparkle key mismatch"

run "$valid" release.sh "OTTO_SITE_DIR=$fixtures/site" SHIM_IDENTITY=1 "SHIM_POLAR_CANARY_KEY=$polar_canary" \
    "SHIM_GUMROAD_CANARY_KEY=$gumroad_canary" -- --flavor paid --preflight-only --no-notarize
expect_status 1 "no Sparkle key"
expect_line '^error: generate_keys -p found no Sparkle key .*\(J6\)' "no Sparkle key"

# MARK: - release.sh stage 1: the appcast and commerce.json

run "$valid" release.sh "OTTO_SITE_DIR=$fixtures/site-first" "${ready[@]}" -- --flavor paid --preflight-only --no-notarize
expect_status 0 "no appcast.xml (the first release)"
expect_line 'no appcast\.xml in .*: this release starts the feed' "no appcast.xml (the first release)"

run "$valid" release.sh "OTTO_SITE_DIR=$fixtures/site-same-build" "${ready[@]}" -- \
    --flavor paid --preflight-only --no-notarize
expect_status 1 "an appcast item with this build number"
expect_line '^error: project\.yml: CURRENT_PROJECT_VERSION is 2, but .*appcast\.xml already has build 2' \
    "an appcast item with this build number"
expect_no_log '^curl ' "an appcast item with this build number: no network"

mkdir -p "$scratch/site-empty"
run "$valid" release.sh "OTTO_SITE_DIR=$scratch/site-empty" "${ready[@]}" -- --flavor paid --preflight-only --no-notarize
expect_status 1 "missing commerce.json"
expect_line '^error: .*commerce\.json is missing\.' "missing commerce.json"
expect_no_log '^curl ' "missing commerce.json: no network"

mkdir -p "$scratch/site-other-host"
sed 's/"siteHost": "otto-fixture.test"/"siteHost": "otto-elsewhere.test"/' "$fixtures/site/commerce.json" \
    >"$scratch/site-other-host/commerce.json"
run "$valid" release.sh "OTTO_SITE_DIR=$scratch/site-other-host" "${ready[@]}" -- \
    --flavor paid --preflight-only --no-notarize
expect_status 1 "commerce.json disagrees with the xcconfig"
expect_line '^error: .*commerce\.json: siteHost is "otto-elsewhere\.test", but Config/Commercial\.xcconfig sets OTTO_SITE_HOST = otto-fixture\.test \(J8\)' \
    "commerce.json disagrees with the xcconfig"

# MARK: - release.sh, Setapp

run "$valid" release.sh SHIM_IDENTITY=1 -- --flavor setapp --preflight-only --no-notarize
expect_status 1 "Setapp without its public key"
expect_line 'setappPublicKey\.pem .*\(J14\)' "Setapp without its public key"

mkdir -p "$valid/Config/Setapp"
cp "$commercial/setappPublicKey.pem" "$valid/Config/Setapp/setappPublicKey.pem"
run "$valid" release.sh SHIM_IDENTITY=1 -- --flavor setapp --preflight-only --no-notarize
expect_status 0 "Setapp"
expect_no_log '^(curl|xcodebuild|security find-generic-password|generate_keys) ' \
    "Setapp: no canary, no package resolution, no Sparkle key"

# MARK: - publish.sh

run "$valid" publish.sh -- --help
expect_status 0 "publish.sh --help"
expect_line '--dry-run' "publish.sh --help"

run "$valid" publish.sh --
expect_status 2 "publish.sh without --version"

run "$valid" publish.sh -- --version 1.1
expect_status 2 "publish.sh with a malformed version"

run "$valid" publish.sh -- --version 1.1.0 --tap-now
expect_status 2 "publish.sh with an unknown option"

# The notarized DMG release.sh would have written, and the app hdiutil "mounts" from it.
mkdir -p "$valid/dist/paid" "$scratch/mount/Otto.app/Contents"
head -c 4096 /dev/zero | tr '\0' 'o' >"$valid/dist/paid/Otto-1.1.0.dmg"
(cd "$valid/dist/paid" && shasum -a 256 Otto-1.1.0.dmg >SHA256SUMS.txt)
dmg_sha256=$(awk '{print $1}' "$valid/dist/paid/SHA256SUMS.txt")
cat >"$scratch/mount/Otto.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleShortVersionString</key>
    <string>1.1.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
</dict>
</plist>
PLIST
mounted=("SHIM_MOUNT_POINT=$scratch/mount")
site_before=$(cat "$fixtures/site/appcast.xml" "$fixtures/site/commerce.json" | shasum -a 256)
work="$valid/build/publish/1.1.0"

run "$valid" publish.sh "OTTO_SITE_DIR=$fixtures/site-placeholder" "${mounted[@]}" -- --version 1.1.0 --no-tap --dry-run
expect_status 1 "publish.sh with placeholder hosts"
expect_line '^error: commerce\.json: siteHost is still a placeholder \(J8\)\.$' "publish.sh with placeholder hosts"
expect_line '^error: commerce\.json: downloadsHost is still a placeholder \(J9\)\.$' "publish.sh with placeholder hosts"
expect_line 'Nothing was published\.$' "publish.sh with placeholder hosts"
expect_no_log '^generate_appcast ' "publish.sh with placeholder hosts: nothing generated"

run "$valid" publish.sh "OTTO_SITE_DIR=$fixtures/site" "${mounted[@]}" SHIM_BUY_STATUS=404 -- --version 1.1.0 --no-tap --dry-run
expect_status 0 "publish.sh --dry-run, /buy not live"
expect_line '^    Create the GitHub release after SITE_COMMERCIAL=1 is live \(docs/RELEASING\.md, gate HM3 step 6\)\.$' \
    "publish.sh --dry-run, /buy not live"
expect_no_line 'gh release create' "publish.sh --dry-run, /buy not live: no gh release line"
expect_log '^curl https://otto-fixture\.test/buy$' "publish.sh --dry-run: /buy is checked"
expect_log "^generate_appcast --download-url-prefix https://otto-fixture-downloads\.public\.blob\.vercel-storage\.com/releases/ --link https://otto-fixture\.test/ --embed-release-notes --maximum-deltas 0 --maximum-versions 0 -o $work/appcast\.xml $work/archives$" \
    "publish.sh --dry-run: the generate_appcast command"
expect_no_log '^vercel blob put' "publish.sh --dry-run: no upload"
expect_no_log '^node .*site_render' "publish.sh --dry-run: never site_render.mjs"
expect_file "$work/archives/Otto-1.1.0.html" "publish.sh --dry-run: release notes"
if grep -q '<kbd>⌘</kbd>' "$work/archives/Otto-1.1.0.html" && grep -q '&lt;script&gt;' "$work/archives/Otto-1.1.0.html" \
    && ! grep -q '1.0.9' "$work/archives/Otto-1.1.0.html"; then
    pass
else
    fail "publish.sh --dry-run: the release notes are the escaped 1.1.0 section"
fi
if cmp -s "$work/appcast.xml" "$work/site/appcast.xml"; then
    pass
else
    fail "publish.sh --dry-run: site/appcast.xml is a byte copy of the signed feed"
fi
if [ "$(xmllint --xpath "count(//*[local-name()='item'])" "$work/site/appcast.xml" 2>/dev/null)" = 2 ]; then
    pass
else
    fail "publish.sh --dry-run: the feed keeps the older item and adds the new one"
fi
release_json=$(cat "$work/site/release.json" 2>/dev/null)
if node -e '
    const release = JSON.parse(process.argv[1]);
    const ok = release.schema === 1 && release.version === "1.1.0" && release.build === "2"
        && release.dmgURL === "https://otto-fixture-downloads.public.blob.vercel-storage.com/releases/Otto-1.1.0.dmg"
        && release.sha256 === process.argv[2] && release.bytes === 4096 && release.minimumSystemVersion === "14.0"
        && /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(release.releasedAt);
    process.exit(ok ? 0 : 1);
' "$release_json" "$dmg_sha256"; then
    pass
else
    output=$release_json
    fail "publish.sh --dry-run: release.json"
fi
if [ "$(cat "$fixtures/site/appcast.xml" "$fixtures/site/commerce.json" | shasum -a 256)" = "$site_before" ]; then
    pass
else
    fail "publish.sh --dry-run: the site directory is unchanged"
fi

run "$valid" publish.sh "OTTO_SITE_DIR=$fixtures/site" "${mounted[@]}" SHIM_BUY_STATUS=200 -- --version 1.1.0 --no-tap --dry-run
expect_status 0 "publish.sh --dry-run, /buy live"
expect_line '^    gh release create v1\.1\.0 --title "Otto 1\.1\.0" --notes-file build/publish/1\.1\.0/github-release-notes\.md$' \
    "publish.sh --dry-run, /buy live"
expect_no_line 'Create the GitHub release after' "publish.sh --dry-run, /buy live"
if [ "$(tail -n 1 "$work/github-release-notes.md")" = "Get the signed app at https://otto-fixture.test/buy." ]; then
    pass
else
    fail "publish.sh --dry-run: the GitHub release notes end with the /buy line"
fi

run "$valid" publish.sh "OTTO_SITE_DIR=$fixtures/site-first" "${mounted[@]}" -- --version 1.1.0 --no-tap --dry-run
expect_status 0 "publish.sh, the first release"
expect_line 'no appcast\.xml yet: this release starts the feed' "publish.sh, the first release"
if [ "$(xmllint --xpath "count(//*[local-name()='item'])" "$work/site/appcast.xml" 2>/dev/null)" = 1 ]; then
    pass
else
    fail "publish.sh, the first release: one item"
fi

run "$valid" publish.sh "OTTO_SITE_DIR=$fixtures/site" "${mounted[@]}" SHIM_APPCAST_PRUNE=1 -- --version 1.1.0 --no-tap --dry-run
expect_status 1 "publish.sh when generate_appcast drops an item"
expect_line "^error: the feed has 1 item\(s\), expected 2 " "publish.sh when generate_appcast drops an item"

run "$valid" publish.sh "OTTO_SITE_DIR=$fixtures/site" "${mounted[@]}" SHIM_APPCAST_BUILD=3 -- --version 1.1.0 --no-tap --dry-run
expect_status 1 "publish.sh when the new item has another build number"
expect_line '^error: the feed has no single item with sparkle:version 2$' "publish.sh when the new item has another build number"

tap="$scratch/homebrew-tap"
git init -q "$tap"
git -C "$tap" remote add origin https://github.com/jke48222/homebrew-tap.git
run "$valid" publish.sh "OTTO_SITE_DIR=$fixtures/site" "${mounted[@]}" -- --version 1.1.0 --tap-dir "$tap" --dry-run
expect_status 0 "publish.sh --dry-run with a tap"
expect_file "$work/tap/Casks/otto.rb" "publish.sh --dry-run with a tap: the cask"
expect_log "^brew style --cask $work/tap/Casks/otto\.rb$" "publish.sh --dry-run with a tap: brew style"
if grep -q "sha256 \"$dmg_sha256\"" "$work/tap/Casks/otto.rb" 2>/dev/null && [ -z "$(git -C "$tap" status --porcelain)" ]; then
    pass
else
    fail "publish.sh --dry-run with a tap: the cask carries the DMG's SHA-256 and the tap is untouched"
fi

git -C "$tap" remote set-url origin https://github.com/someone-else/homebrew-tap.git
run "$valid" publish.sh "OTTO_SITE_DIR=$fixtures/site" "${mounted[@]}" -- --version 1.1.0 --tap-dir "$tap" --dry-run
expect_status 1 "publish.sh with another tap"
expect_line "origin is \"https://github\.com/someone-else/homebrew-tap\.git\", not jke48222/homebrew-tap" \
    "publish.sh with another tap"

mv "$valid/dist/paid/Otto-1.1.0.dmg" "$valid/dist/paid/Otto-1.1.0-UNNOTARIZED.dmg"
run "$valid" publish.sh "OTTO_SITE_DIR=$fixtures/site" "${mounted[@]}" -- --version 1.1.0 --no-tap --dry-run
expect_status 1 "publish.sh with only an unnotarized DMG"
expect_line '^error: only dist/paid/Otto-1\.1\.0-UNNOTARIZED\.dmg exists\. Unnotarized builds are never published' \
    "publish.sh with only an unnotarized DMG"

# MARK: - The cask from the golden fixtures (the HM5 command)

mkdir -p "$scratch/cask-tap/Casks"
output=$(node "$repo/scripts/release_tools.mjs" cask "$fixtures/cask/release.json" "$fixtures/cask/commerce.json" 2>&1 \
    >"$scratch/cask-tap/Casks/otto.rb")
status=$?
expect_status 0 "release_tools.mjs cask"
if cmp -s "$scratch/cask-tap/Casks/otto.rb" "$fixtures/cask/otto.rb.golden"; then
    pass
else
    output=$(diff "$fixtures/cask/otto.rb.golden" "$scratch/cask-tap/Casks/otto.rb")
    fail "release_tools.mjs cask: the golden file"
fi
if [ -n "$real_brew" ]; then
    output=$(HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_FROM_API=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_DEVELOPER=1 \
        "$real_brew" style --cask "$scratch/cask-tap/Casks/otto.rb" 2>&1)
    status=$?
    expect_status 0 "brew style --cask on the golden cask"
else
    echo "skipped: brew style --cask on the golden cask (Homebrew isn't installed)"
fi

echo "release_script_test.sh: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
