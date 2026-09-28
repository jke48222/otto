#!/bin/bash
#
# sparkle_tools.sh
# Otto
#
# Finds Sparkle's command-line tools (generate_appcast, generate_keys, sign_update) for release.sh and publish.sh
# (SPEC-v2 §14.12). Swift Package Manager downloads them with the Sparkle package into the paid build's derived data,
# at SourcePackages/artifacts/sparkle/Sparkle/bin, so they always match the Sparkle version the app links.
#
# Sourced:   . scripts/lib/sparkle_tools.sh; generate_keys=$(sparkle_tool generate_keys "$ROOT") || exit 1
# Run:       bash scripts/lib/sparkle_tools.sh generate_appcast     # prints the tool's path
#
# Search order: $SPARKLE_BIN (a directory; tests point it at shims, and nothing else is searched when it is set),
# then build/release/paid/DerivedData (release.sh), build/paid (the everyday paid build) and build/spm (CI's
# -clonedSourcePackagesDirPath).

# sparkle_tool_candidates ROOT: the directories that may hold the tools, most authoritative first.
sparkle_tool_candidates() {
    local root=$1
    if [ -n "${SPARKLE_BIN:-}" ]; then
        printf '%s\n' "$SPARKLE_BIN"
        return
    fi
    printf '%s\n' \
        "$root/build/release/paid/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin" \
        "$root/build/paid/SourcePackages/artifacts/sparkle/Sparkle/bin" \
        "$root/build/spm/artifacts/sparkle/Sparkle/bin"
}

# sparkle_tool NAME ROOT: prints the path of Sparkle's NAME tool, or explains what's missing on stderr and returns 1.
sparkle_tool() {
    local name=$1 root=$2 directory
    case "$name" in
        generate_appcast | generate_keys | sign_update) ;;
        *)
            echo "error: $name is not one of Sparkle's tools (generate_appcast, generate_keys, sign_update)." >&2
            return 1
            ;;
    esac
    while IFS= read -r directory; do
        if [ -x "$directory/$name" ]; then
            printf '%s\n' "$directory/$name"
            return 0
        fi
    done < <(sparkle_tool_candidates "$root")
    if [ -n "${SPARKLE_BIN:-}" ]; then
        echo "error: SPARKLE_BIN is $SPARKLE_BIN, which has no executable $name." >&2
    else
        echo "error: Sparkle's $name isn't in the paid build's Swift packages. Resolve them first:" \
            "xcodegen generate --spec project-paid.yml && xcodebuild -resolvePackageDependencies" \
            "-project OttoPaid.xcodeproj -scheme Otto -derivedDataPath build/release/paid/DerivedData" >&2
    fi
    return 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -u
    if [ $# -ne 1 ]; then
        echo "usage: sparkle_tools.sh generate_appcast|generate_keys|sign_update" >&2
        exit 2
    fi
    sparkle_tool "$1" "$(cd "$(dirname "$0")/../.." && pwd)"
fi
