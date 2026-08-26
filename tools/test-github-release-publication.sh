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

# Signing credentials are tag-only. A manual dispatcher can select an arbitrary
# ref, so merely skipping the final upload would still expose Apple credentials
# to unreviewed workflow content.
trigger_block=$(sed -n '/^on:$/,/^permissions:$/p' .github/workflows/release.yml | sed '$d')
expected_trigger_block='on:
  push:
    tags: ["v*"]'
if test "$trigger_block" != "$expected_trigger_block"; then
    echo 'error: release signing workflow must be triggered only by canonical tags' >&2
    exit 1
fi

# Release credentials execute third-party code, so mutable action tags are not
# an acceptable trust root. Keep the human-readable major only as a comment.
action_uses=$(sed -n 's/^[[:space:]]*-\{0,1\}[[:space:]]*uses:[[:space:]]*\([^#[:space:]]*\).*/\1/p' .github/workflows/release.yml)
test "$(printf '%s\n' "$action_uses" | sed '/^$/d' | wc -l | tr -d ' ')" = 3
if printf '%s\n' "$action_uses" | grep -Ev '^[^@[:space:]]+@[0-9a-f]{40}$' >/dev/null; then
    echo 'error: release workflow contains an unpinned third-party Action' >&2
    exit 1
fi
test "$(printf '%s\n' "$action_uses" | grep -Fxc 'actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5')" = 1
test "$(printf '%s\n' "$action_uses" | grep -Fxc 'jdx/mise-action@c37c93293d6b742fc901e1406b8f764f6fb19dac')" = 1
test "$(printf '%s\n' "$action_uses" | grep -Fxc 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02')" = 1
test "$(grep -c 'persist-credentials: false' .github/workflows/release.yml)" = 1

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
