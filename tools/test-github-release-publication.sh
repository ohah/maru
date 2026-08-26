#!/bin/sh
set -eu

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"

publisher=tools/publish-github-release.sh
test -x "$publisher" || {
    echo 'error: missing executable release publisher' >&2
    exit 1
}

! grep -q -- '--clobber' "$publisher"
test "$(grep -c 'gh release create' "$publisher")" = 1
test "$(grep -c 'gh release upload' "$publisher")" = 1
test "$(grep -c 'gh release download' "$publisher")" = 1
test "$(grep -c 'gh release edit' "$publisher")" = 1

create_line=$(grep -n 'gh release create' "$publisher" | cut -d: -f1)
upload_line=$(grep -n 'gh release upload' "$publisher" | cut -d: -f1)
download_line=$(grep -n 'gh release download' "$publisher" | cut -d: -f1)
publish_line=$(grep -n 'gh release edit' "$publisher" | cut -d: -f1)
test "$create_line" -lt "$upload_line"
test "$upload_line" -lt "$download_line"
test "$download_line" -lt "$publish_line"

test "$(grep -c 'sh tools/publish-github-release.sh "$RELEASE_TAG"' .github/workflows/release.yml)" = 1
! grep -q -- '--clobber' .github/workflows/release.yml

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
ln -s "$repo_root/tools/test-fixtures/fake-release-gh.sh" "$tmp/bin/gh"
asset="$tmp/Maru-1.2.3-universal.dmg"
printf 'signed-notarized-dmg\n' > "$asset"

if FAKE_GH_STATE="$tmp/bad-tag" PATH="$tmp/bin:$PATH" sh "$publisher" 'v1.2.3;false' "$asset" >/dev/null 2>&1; then
    echo 'error: unsafe release tag was accepted' >&2
    exit 1
fi
test ! -e "$tmp/bad-tag/exists"

ln -s "$asset" "$tmp/Maru-1.2.3-universal-link.dmg"
if FAKE_GH_STATE="$tmp/symlink" PATH="$tmp/bin:$PATH" sh "$publisher" v1.2.3 "$tmp/Maru-1.2.3-universal-link.dmg" >/dev/null 2>&1; then
    echo 'error: symlink release asset was accepted' >&2
    exit 1
fi
test ! -e "$tmp/symlink/exists"

FAKE_GH_STATE="$tmp/success" PATH="$tmp/bin:$PATH" sh "$publisher" v1.2.3 "$asset"
test "$(cat "$tmp/success/draft")" = false
cmp "$asset" "$tmp/success/asset"

if FAKE_GH_STATE="$tmp/success" PATH="$tmp/bin:$PATH" sh "$publisher" v1.2.3 "$asset" >/dev/null 2>&1; then
    echo 'error: existing release was reused' >&2
    exit 1
fi
test "$(cat "$tmp/success/draft")" = false
cmp "$asset" "$tmp/success/asset"

if FAKE_GH_STATE="$tmp/corrupt" FAKE_GH_CORRUPT_DOWNLOAD=1 PATH="$tmp/bin:$PATH" sh "$publisher" v1.2.3 "$asset" >/dev/null 2>&1; then
    echo 'error: corrupt downloaded asset was published' >&2
    exit 1
fi
test "$(cat "$tmp/corrupt/draft")" = true
! grep -q '^release edit ' "$tmp/corrupt/calls"

if FAKE_GH_STATE="$tmp/occupied" FAKE_GH_PRELOAD_ASSET=1 PATH="$tmp/bin:$PATH" sh "$publisher" v1.2.3 "$asset" >/dev/null 2>&1; then
    echo 'error: occupied draft asset was overwritten' >&2
    exit 1
fi
test "$(cat "$tmp/occupied/draft")" = true
test "$(cat "$tmp/occupied/asset")" = occupied
! grep -q '^release edit ' "$tmp/occupied/calls"

echo 'GitHub release publication contract: OK'
