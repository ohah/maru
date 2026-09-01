#!/bin/sh
set -eu

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"

workflow=.github/workflows/release.yml
test -f "$workflow"

test "$(grep -c '^    environment: release$' "$workflow")" = 1
test "$(grep -c '^    runs-on: macos-15$' "$workflow")" = 1
test "$(grep -c '^      - name: Capture trusted GitHub CLI before checkout$' "$workflow")" = 1
test "$(grep -c '^        id: trusted-gh$' "$workflow")" = 1
test "$(grep -c 'uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5' "$workflow")" = 1
test "$(grep -c 'command -v gh' "$workflow")" = 1

capture_line=$(grep -n '^      - name: Capture trusted GitHub CLI before checkout$' "$workflow" | cut -d: -f1)
checkout_line=$(grep -n 'uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5' "$workflow" | cut -d: -f1)
test "$capture_line" -lt "$checkout_line"

capture_block=$(sed -n '/^      - name: Capture trusted GitHub CLI before checkout$/,/^      - uses: actions\/checkout@/p' "$workflow" | sed '$d')
test "$(printf '%s\n' "$capture_block" | grep -c 'command -v gh')" = 1
test "$(printf '%s\n' "$capture_block" | grep -c '/usr/bin/realpath')" = 1
test "$(printf '%s\n' "$capture_block" | grep -c '\$canonical.*\\n.*\$canonical.*\\r')" = 1
test "$(printf '%s\n' "$capture_block" | grep -c "/usr/bin/stat -f '%HT'")" = 1
test "$(printf '%s\n' "$capture_block" | grep -c '/usr/bin/shasum -a 256')" = 1
test "$(printf '%s\n' "$capture_block" | grep -c 'path=%s\\n')" = 1
test "$(printf '%s\n' "$capture_block" | grep -c 'sha256=%s\\n')" = 1
test "$(printf '%s\n' "$capture_block" | grep -c 'GITHUB_OUTPUT')" = 2
! printf '%s\n' "$capture_block" | grep -q 'GITHUB_ENV'

action_uses=$(sed -n 's/^[[:space:]]*-\{0,1\}[[:space:]]*uses:[[:space:]]*\([^#[:space:]]*\).*/\1/p' "$workflow")
if printf '%s\n' "$action_uses" | grep -Ev '^[^@[:space:]]+@[0-9a-f]{40}$' >/dev/null; then
    echo 'error: release workflow contains an unpinned third-party Action' >&2
    exit 1
fi

trigger_block=$(sed -n '/^on:$/,/^permissions:$/p' "$workflow" | sed '$d')
expected_trigger_block='on:
  push:
    tags: ["v*"]'
test "$trigger_block" = "$expected_trigger_block"

echo 'Session-host release workflow authority capture contract: OK'
