#!/bin/sh
set -eu

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

template=src/platform/macos/MaruAppHost-Info.plist.in
renderer=tools/render-macos-info-plist.sh

test "$(awk -v needle='@@MARU_VERSION@@' '{ text = $0; while ((at = index(text, needle)) != 0) { count++; text = substr(text, at + length(needle)) } } END { print count + 0 }' "$template")" = 1
test "$(awk -v needle='@@MARU_BUNDLE_ID@@' '{ text = $0; while ((at = index(text, needle)) != 0) { count++; text = substr(text, at + length(needle)) } } END { print count + 0 }' "$template")" = 1
test "$(awk -v needle='@@MARU_BUNDLE_VERSION@@' '{ text = $0; while ((at = index(text, needle)) != 0) { count++; text = substr(text, at + length(needle)) } } END { print count + 0 }' "$template")" = 1
! grep -q 'dev\.maru\.apphost' "$template"
! grep -q '<string>0\.1</string>' "$template"

sh "$renderer" render "$template" "$tmp/Info.plist" 1.2.3 dev.maru.apphost 1
test "$(grep -c '<string>1\.2\.3</string>' "$tmp/Info.plist")" = 1
test "$(grep -c '<string>dev\.maru\.apphost</string>' "$tmp/Info.plist")" = 1
! grep -q '@@MARU_VERSION@@' "$tmp/Info.plist"
! grep -q '@@MARU_BUNDLE_ID@@' "$tmp/Info.plist"
! grep -q '@@MARU_BUNDLE_VERSION@@' "$tmp/Info.plist"

if sh "$renderer" render "$template" "$tmp/bad.plist" '1.2.3/escape' dev.maru.apphost 1 >/dev/null 2>&1; then
    echo 'error: invalid version was accepted' >&2
    exit 1
fi
if sh "$renderer" render "$template" "$tmp/prerelease.plist" '1.2.3-beta.1' dev.maru.apphost 1 >/dev/null 2>&1; then
    echo 'error: prerelease version invalid for CFBundleShortVersionString was accepted' >&2
    exit 1
fi
if sh "$renderer" render "$template" "$tmp/leading-zero.plist" '01.2.3' dev.maru.apphost 1 >/dev/null 2>&1; then
    echo 'error: noncanonical numeric version was accepted' >&2
    exit 1
fi
if sh "$renderer" render "$template" "$tmp/injected.plist" 1.2.3 'dev.maru/app&host' 1 >/dev/null 2>&1; then
    echo 'error: unsafe bundle ID was accepted' >&2
    exit 1
fi
if sh "$renderer" render "$template" "$tmp/bad-bundle-version.plist" 1.2.3 dev.maru.apphost '01' >/dev/null 2>&1; then
    echo 'error: noncanonical bundle version was accepted' >&2
    exit 1
fi

sh "$renderer" check-tag 1.2.3 v1.2.3
if sh "$renderer" check-tag 1.2.3 v1.2.4 >/dev/null 2>&1; then
    echo 'error: mismatched release tag was accepted' >&2
    exit 1
fi

sed 's#@@MARU_VERSION@@#@@MARU_VERSION@@@@MARU_VERSION@@#' "$template" > "$tmp/duplicate.in"
if sh "$renderer" render "$tmp/duplicate.in" "$tmp/duplicate.plist" 1.2.3 dev.maru.apphost 1 >/dev/null 2>&1; then
    echo 'error: duplicate plist placeholder was accepted' >&2
    exit 1
fi

sed 's/@@MARU_VERSION@@/1.2.3/' "$template" > "$tmp/missing.in"
if sh "$renderer" render "$tmp/missing.in" "$tmp/missing.plist" 1.2.3 dev.maru.apphost 1 >/dev/null 2>&1; then
    echo 'error: missing plist placeholder was accepted' >&2
    exit 1
fi

sed 's#@@MARU_BUNDLE_ID@@#@@MARU_BUNDLE_ID@@@@MARU_BUNDLE_ID@@#' "$template" > "$tmp/duplicate-bundle.in"
if sh "$renderer" render "$tmp/duplicate-bundle.in" "$tmp/duplicate-bundle.plist" 1.2.3 dev.maru.apphost 1 >/dev/null 2>&1; then
    echo 'error: duplicate bundle ID placeholder was accepted' >&2
    exit 1
fi

sed 's#@@MARU_BUNDLE_VERSION@@#@@MARU_BUNDLE_VERSION@@@@MARU_BUNDLE_VERSION@@#' "$template" > "$tmp/duplicate-bundle-version.in"
if sh "$renderer" render "$tmp/duplicate-bundle-version.in" "$tmp/duplicate-bundle-version.plist" 1.2.3 dev.maru.apphost 1 >/dev/null 2>&1; then
    echo 'error: duplicate bundle version placeholder was accepted' >&2
    exit 1
fi

test "$(grep -c 'macos_info_plist_generate.addOutputFileArg("MaruAppHost-Info.plist")' build.zig)" = 1
test "$(grep -c 'macos_app_compile.addFileArg(macos_info_plist)' build.zig)" = 1
test "$(grep -F -c '\"$1\" zig-out/Maru.app/Contents/Info.plist' build.zig)" = 1
! grep -q 'addFileArg(b.path("src/platform/macos/MaruAppHost-Info.plist"))' build.zig
! grep -q 'cp src/platform/macos/MaruAppHost-Info.plist zig-out/Maru.app/Contents/Info.plist' build.zig
test "$(grep -F -c 'cmp "$work/arm.app/Contents/Info.plist" "$work/x86.app/Contents/Info.plist"' tools/build-macos-universal-dmg.sh)" = 1

verify_line=$(grep -n 'name: Verify release version SSOT' .github/workflows/release.yml | cut -d: -f1)
secret_line=$(grep -n 'name: Import Developer ID certificate' .github/workflows/release.yml | cut -d: -f1)
test "$verify_line" -lt "$secret_line"
test "$(grep -F -c 'zig build check-release-version -Drelease-tag="$RELEASE_TAG"' .github/workflows/release.yml)" = 1
! grep -F -q 'zig build check-release-version -Drelease-tag="${{' .github/workflows/release.yml

echo 'release version SSOT contract: OK'
