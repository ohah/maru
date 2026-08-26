#!/bin/sh
set -eu

test "$#" = 2 || {
    echo 'usage: publish-github-release.sh TAG ASSET' >&2
    exit 2
}

tag=$1
asset=$2
version=${tag#v}

printf '%s\n' "$version" | awk '
    /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/ { ok = 1 }
    END { exit ok ? 0 : 1 }
' || {
    echo "error: invalid release tag: $tag" >&2
    exit 1
}
test "$tag" = "v$version"
test -f "$asset" && test ! -L "$asset" || {
    echo "error: release asset is not one regular file: $asset" >&2
    exit 1
}

asset_name=$(basename "$asset")
expected_name="Maru-$version-universal.dmg"
test "$asset_name" = "$expected_name" || {
    echo "error: unexpected release asset name: $asset_name" >&2
    exit 1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir "$work/candidate" "$work/download"
candidate="$work/candidate/$expected_name"
cp "$asset" "$candidate"

# Existing tag releases are never reused: concurrent or repeated publication fails here.
gh release create "$tag" --draft --verify-tag --title "$tag" --generate-notes
gh release upload "$tag" "$candidate"

test "$(gh release view "$tag" --json isDraft --jq '.isDraft')" = true
test "$(gh release view "$tag" --json assets --jq '.assets[].name')" = "$expected_name"
gh release download "$tag" --pattern "$expected_name" --dir "$work/download"
cmp "$candidate" "$work/download/$expected_name"

gh release edit "$tag" --draft=false
test "$(gh release view "$tag" --json isDraft --jq '.isDraft')" = false
