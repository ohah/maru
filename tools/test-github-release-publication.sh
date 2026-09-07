#!/bin/sh
set -eu

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"

workflow=.github/workflows/release.yml
live_action=.github/actions/session-host-release-live/action.yml

test ! -e tools/publish-github-release.sh
test -f "$live_action"
test "$(grep -F -c 'uses: ./.github/actions/session-host-release-live' "$workflow")" = 1
test "$(grep -F -c 'name: Run session host live release workflow' "$workflow")" = 1
test "$(grep -F -c 'id: session-host-live' "$workflow")" = 1
! grep -q -- '--clobber' "$workflow" "$live_action"

pin_line=$(grep -n 'name: Pin signed candidate inputs' "$live_action" | cut -d: -f1)
draft_line=$(grep -n 'name: Author baseline evidence and draft' "$live_action" | cut -d: -f1)
publish_line=$(grep -n 'name: Publish candidate release' "$live_action" | cut -d: -f1)
cleanup_line=$(grep -n 'name: Clean verified aggregate' "$live_action" | cut -d: -f1)
test "$pin_line" -lt "$draft_line"
test "$draft_line" -lt "$publish_line"
test "$publish_line" -lt "$cleanup_line"
test "$(grep -F -c 'GH_TOKEN: ${{ github.token }}' "$live_action")" = 3

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
test "$(printf '%s\n' "$third_party_uses" | sed '/^$/d' | wc -l | tr -d ' ')" = 4
if printf '%s\n' "$third_party_uses" | grep -Ev '^[^@[:space:]]+@[0-9a-f]{40}$' >/dev/null; then
    echo 'error: release workflow contains an unpinned third-party Action' >&2
    exit 1
fi
test "$(printf '%s\n' "$action_uses" | grep -Fxc 'actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5')" = 1
test "$(printf '%s\n' "$action_uses" | grep -Fxc 'jdx/mise-action@c37c93293d6b742fc901e1406b8f764f6fb19dac')" = 1
test "$(printf '%s\n' "$action_uses" | grep -Fxc 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02')" = 2
test "$(grep -c 'persist-credentials: false' "$workflow")" = 1

echo 'GitHub release publication contract: OK'
