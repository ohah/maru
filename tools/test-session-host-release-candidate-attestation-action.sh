#!/bin/bash
set -euo pipefail

action=.github/actions/session-host-release-attest-candidate/action.yml
helper=.github/actions/session-host-release-attest-candidate/pin-candidate-pair.sh
single_action='./.github/actions/session-host-release-attest'
live_action=.github/actions/session-host-release-live-candidate-attestation/action.yml
payload_action='./.github/actions/session-host-release-attest-candidate'

test -f "$action"
test -x "$helper"
for input in dmg-path dmg-name frozen-path frozen-name; do
    test "$(grep -Fxc "  $input:" "$action")" -eq 1
done
test "$(grep -Fxc "    uses: $single_action" "$action")" -eq 2
test "$(grep -Fc 'uses: actions/attest@' "$action")" -eq 0
test "$(grep -Fc 'pin-candidate-pair.sh' "$action")" -eq 2
test "$(grep -Fxc '      "${{ github.action_path }}/pin-candidate-pair.sh" pin \' "$action")" -eq 1
test "$(grep -Fxc '      "${{ github.action_path }}/pin-candidate-pair.sh" verify \' "$action")" -eq 1
test "$(grep -Fxc '    value: ${{ steps.final.outputs.dmg-bundle-path }}' "$action")" -eq 1
test "$(grep -Fxc '    value: ${{ steps.final.outputs.frozen-bundle-path }}' "$action")" -eq 1
! sed -n '/^inputs:/,/^outputs:/p' "$action" | grep -Eq 'digest|attestation|bundle|predicate|success|action-ref'

pin_line=$(grep -nF 'name: Pin candidate pair' "$action" | cut -d: -f1)
dmg_line=$(grep -nF 'name: Attest candidate dmg' "$action" | cut -d: -f1)
frozen_line=$(grep -nF 'name: Attest frozen executable' "$action" | cut -d: -f1)
final_line=$(grep -nF 'name: Fence candidate pair and bundles' "$action" | cut -d: -f1)
test "$pin_line" -lt "$dmg_line"
test "$dmg_line" -lt "$frozen_line"
test "$frozen_line" -lt "$final_line"
dmg_block=$(sed -n '/name: Attest candidate dmg/,/name: Attest frozen executable/p' "$action")
frozen_block=$(sed -n '/name: Attest frozen executable/,/name: Fence candidate pair and bundles/p' "$action")
test "$(printf '%s\n' "$dmg_block" | grep -Fxc '      subject-path: ${{ inputs.dmg-path }}')" -eq 1
test "$(printf '%s\n' "$dmg_block" | grep -Fxc '      subject-name: ${{ inputs.dmg-name }}')" -eq 1
test "$(printf '%s\n' "$dmg_block" | grep -Fc 'inputs.frozen-')" -eq 0
test "$(printf '%s\n' "$frozen_block" | grep -Fxc '      subject-path: ${{ inputs.frozen-path }}')" -eq 1
test "$(printf '%s\n' "$frozen_block" | grep -Fxc '      subject-name: ${{ inputs.frozen-name }}')" -eq 1
test "$(printf '%s\n' "$frozen_block" | grep -Fc 'inputs.dmg-')" -eq 0
test "$(grep -Fxc 'bundle_max_bytes=16777216' "$helper")" -eq 1
! grep -Eq 'GH_TOKEN|APPLE_|GITHUB_|(^|[^A-Z_])HOME([^A-Z_]|$)|(^|[^A-Z_])PATH([^A-Z_]|$)' "$helper"

test -f "$live_action"
for input in dmg-path dmg-name frozen-path frozen-name; do
    test "$(grep -Fxc "  $input:" "$live_action")" -eq 1
    test "$(grep -Fxc "      $input: \${{ inputs.$input }}" "$live_action")" -eq 1
done
test "$(grep -Fxc "    uses: $payload_action" "$live_action")" -eq 1
test "$(grep -Fc 'uses: actions/attest@' "$live_action")" -eq 0
test "$(grep -Fc 'checkpoint' "$live_action")" -eq 0
test "$(grep -Fxc '    value: ${{ steps.payload.outputs.dmg-bundle-path }}' "$live_action")" -eq 1
test "$(grep -Fxc '    value: ${{ steps.payload.outputs.frozen-bundle-path }}' "$live_action")" -eq 1

fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/maru-candidate-attest-action.XXXXXX")
fixture_root=$(cd "$fixture_root" && pwd -P)
trap 'rm -rf "$fixture_root"' EXIT HUP INT TERM
dmg="$fixture_root/Maru-1.2.3-universal.dmg"
frozen="$fixture_root/maru-session-host-1.2.3"
dmg_bundle="$fixture_root/dmg.bundle.jsonl"
frozen_bundle="$fixture_root/frozen.bundle.jsonl"
pin_output="$fixture_root/pin.out"

make_fixture() {
    rm -f "$dmg" "$frozen" "$dmg_bundle" "$frozen_bundle" "$pin_output" "$fixture_root/final.out" "$fixture_root/unexpected.out"
    printf 'candidate dmg\n' > "$dmg"
    printf 'frozen executable\n' > "$frozen"
    printf 'dmg bundle\n' > "$dmg_bundle"
    printf 'frozen bundle\n' > "$frozen_bundle"
}

field() {
    /usr/bin/awk -F= -v key="$1" '$1 == key { print $2 }' "$2"
}

pin_pair() {
    "$helper" pin "$dmg" Maru-1.2.3-universal.dmg "$frozen" maru-session-host-1.2.3
}

verify_pair() {
    local output=$1
    "$helper" verify \
        "$dmg" Maru-1.2.3-universal.dmg "$frozen" maru-session-host-1.2.3 \
        "$(field dmg_device "$pin_output")" "$(field dmg_inode "$pin_output")" \
        "$(field dmg_size "$pin_output")" "$(field dmg_links "$pin_output")" "$(field dmg_sha256 "$pin_output")" \
        "$(field frozen_device "$pin_output")" "$(field frozen_inode "$pin_output")" \
        "$(field frozen_size "$pin_output")" "$(field frozen_links "$pin_output")" "$(field frozen_sha256 "$pin_output")" \
        "$dmg_bundle" "$frozen_bundle" > "$output"
}

make_fixture
pin_pair > "$pin_output"
verify_pair "$fixture_root/final.out"
test "$(field dmg-bundle-path "$fixture_root/final.out")" = "$dmg_bundle"
test "$(field frozen-bundle-path "$fixture_root/final.out")" = "$frozen_bundle"

make_fixture
pin_pair > "$pin_output"
printf X >> "$dmg"
if verify_pair "$fixture_root/unexpected.out"; then exit 1; fi
test ! -s "$fixture_root/unexpected.out"

make_fixture
pin_pair > "$pin_output"
rm "$frozen_bundle"
ln "$dmg_bundle" "$frozen_bundle"
if verify_pair "$fixture_root/unexpected.out"; then exit 1; fi
test ! -s "$fixture_root/unexpected.out"

make_fixture
pin_pair > "$pin_output"
frozen_bundle=$dmg_bundle
if verify_pair "$fixture_root/unexpected.out"; then exit 1; fi
test ! -s "$fixture_root/unexpected.out"
frozen_bundle="$fixture_root/frozen.bundle.jsonl"

make_fixture
pin_pair > "$pin_output"
rm "$dmg_bundle"
ln "$dmg" "$dmg_bundle"
if verify_pair "$fixture_root/unexpected.out"; then exit 1; fi
test ! -s "$fixture_root/unexpected.out"

make_fixture
pin_pair > "$pin_output"
/usr/bin/truncate -s 16777217 "$dmg_bundle" 2>/dev/null || truncate -s 16777217 "$dmg_bundle"
if verify_pair "$fixture_root/unexpected.out"; then exit 1; fi
test ! -s "$fixture_root/unexpected.out"

make_fixture
pin_pair > "$pin_output"
rm "$frozen_bundle"
ln -s "$dmg_bundle" "$frozen_bundle"
if verify_pair "$fixture_root/unexpected.out"; then exit 1; fi
test ! -s "$fixture_root/unexpected.out"

make_fixture
if "$helper" pin "$dmg" Maru-1.2.3-universal.dmg "$dmg" maru-session-host-1.2.3 > "$fixture_root/unexpected.out"; then exit 1; fi
test ! -s "$fixture_root/unexpected.out"
