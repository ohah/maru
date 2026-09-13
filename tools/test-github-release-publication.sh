#!/bin/sh
set -eu

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"

workflow=.github/workflows/release.yml
live_action=.github/actions/session-host-release-live/action.yml

required_unique_line() {
    pattern=$1
    file=$2
    count=$(grep -F -c "$pattern" "$file" || true)
    if test "$count" != 1; then
        echo "error: expected exactly one '$pattern' in $file, found $count" >&2
        exit 1
    fi
    grep -n -F "$pattern" "$file" | cut -d: -f1
}

test ! -e tools/publish-github-release.sh
test -f "$live_action"
test "$(grep -F -c 'uses: ./.github/actions/session-host-release-live' "$workflow")" = 1
test "$(grep -F -c 'name: Run session host live release workflow' "$workflow")" = 1
test "$(grep -F -c 'id: session-host-live' "$workflow")" = 1
! grep -q -- '--clobber' "$workflow" "$live_action"

pin_line=$(required_unique_line 'name: Pin signed candidate inputs' "$live_action")
draft_line=$(required_unique_line 'name: Author profile-selected evidence and draft' "$live_action")
publish_line=$(required_unique_line 'name: Publish candidate release' "$live_action")
cleanup_line=$(required_unique_line 'name: Clean verified aggregate' "$live_action")
test "$pin_line" -lt "$draft_line"
test "$draft_line" -lt "$publish_line"
test "$publish_line" -lt "$cleanup_line"
test "$(grep -F -c 'GH_TOKEN: ${{ github.token }}' "$live_action")" = 3
test "$(grep -F -c 'MARU_SESSION_HOST_RELEASE_PROFILE_V1: ${{ vars.SESSION_HOST_RELEASE_PROFILE_V1 }}' "$workflow")" = 1

# Signing credentials are tag-only. A manual dispatcher can select an arbitrary
# ref, so merely skipping the final upload would still expose Apple credentials
# to unreviewed workflow content.
trigger_block=$(sed -n '/^on:$/,/^concurrency:$/p' "$workflow" | sed '$d')
expected_trigger_block='on:
  push:
    tags: ["v*"]'
if test "$trigger_block" != "$expected_trigger_block"; then
    echo 'error: release signing workflow must be triggered only by canonical tags' >&2
    exit 1
fi

# Release credentials execute third-party code, so mutable action tags are not
# an acceptable trust root. Keep the human-readable major only as a comment.
action_uses=$(sed -n 's/^[[:space:]]*-\{0,1\}[[:space:]]*uses:[[:space:]]*\([^#[:space:]]*\).*/\1/p' "$workflow")
third_party_uses=$(printf '%s\n' "$action_uses" | grep -v '^\./' || true)
test "$(printf '%s\n' "$third_party_uses" | sed '/^$/d' | wc -l | tr -d ' ')" = 21
if printf '%s\n' "$third_party_uses" | grep -Ev '^[^@[:space:]]+@[0-9a-f]{40}$' >/dev/null; then
    echo 'error: release workflow contains an unpinned third-party Action' >&2
    exit 1
fi
test "$(printf '%s\n' "$action_uses" | grep -Fxc 'actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5')" = 6
test "$(printf '%s\n' "$action_uses" | grep -Fxc 'jdx/mise-action@c37c93293d6b742fc901e1406b8f764f6fb19dac')" = 6
test "$(printf '%s\n' "$action_uses" | grep -Fxc 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02')" = 6
test "$(printf '%s\n' "$action_uses" | grep -Fxc 'actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093')" = 2
test "$(printf '%s\n' "$action_uses" | grep -Fxc 'actions/attest-build-provenance@43d14bc2b83dec42d39ecae14e916627a18bb661')" = 1
test "$(grep -c 'persist-credentials: false' "$workflow")" = 6

echo 'GitHub release publication contract: OK'
