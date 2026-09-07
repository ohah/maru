#!/bin/bash
set -euo pipefail

action=.github/actions/session-host-release-attest-authored/action.yml
helper=.github/actions/session-host-release-attest-authored/pin-authored-pair.sh
single_action='./.github/actions/session-host-release-attest'
live_action=.github/actions/session-host-release-live-authored-attestation/action.yml
payload_action='./.github/actions/session-host-release-attest-authored'
contract=src/platform/macos/session_host/release_adapter_attestation_bundle_contract.zig

test -f "$action"
test -x "$helper"
test "$(grep -Fxc '  preparation-path:' "$action")" -eq 1
test "$(grep -Fxc '  evidence-path:' "$action")" -eq 1
test "$(grep -Fxc '  evidence-name:' "$action")" -eq 1
test "$(grep -Fxc '  manifest-path:' "$action")" -eq 1
test "$(grep -Fxc '  manifest-name:' "$action")" -eq 1
test "$(grep -Fxc "    uses: $single_action" "$action")" -eq 2
test "$(grep -Fc 'uses: actions/attest@' "$action")" -eq 0
test "$(grep -Fc 'attestation-id' "$action")" -eq 0
test "$(grep -Fc 'attestation-url' "$action")" -eq 0
test "$(grep -Fxc '    value: ${{ steps.final.outputs.evidence-bundle-path }}' "$action")" -eq 1
test "$(grep -Fxc '    value: ${{ steps.final.outputs.manifest-bundle-path }}' "$action")" -eq 1

pin_line=$(grep -nF 'name: Pin authored pair' "$action" | cut -d: -f1)
evidence_line=$(grep -nF 'name: Attest baseline evidence' "$action" | cut -d: -f1)
manifest_line=$(grep -nF 'name: Attest candidate manifest' "$action" | cut -d: -f1)
final_line=$(grep -nF 'name: Fence authored pair and bundles' "$action" | cut -d: -f1)
test "$pin_line" -lt "$evidence_line"
test "$evidence_line" -lt "$manifest_line"
test "$manifest_line" -lt "$final_line"

test "$(grep -Fxc 'bundle_max_bytes=16777216' "$helper")" -eq 1
test "$(grep -Fxc 'pub const max_bytes: u64 = 16 * 1024 * 1024;' "$contract")" -eq 1
test "$(grep -Fc '"$owner" == "$(/usr/bin/id -u)"' "$helper")" -eq 3
! grep -Eq 'GH_TOKEN|APPLE_|(^|[^A-Z_])HOME([^A-Z_]|$)|(^|[^A-Z_])PATH([^A-Z_]|$)' "$helper"

test -f "$live_action"
for input in preparation-path evidence-path evidence-name manifest-path manifest-name; do
    test "$(grep -Fxc "  $input:" "$live_action")" -eq 1
    test "$(grep -Fxc "      $input: \${{ inputs.$input }}" "$live_action")" -eq 1
done
for input in checkpoint-root checkpoint-root-identity; do
    test "$(grep -Fxc "  $input:" "$live_action")" -eq 1
done
test "$(grep -Fxc "    uses: $payload_action" "$live_action")" -eq 1
test "$(grep -Fc 'uses: actions/attest@' "$live_action")" -eq 0
test "$(grep -Fc '/zig-out/bin/maru-session-host-release-workflow-checkpoint' "$live_action")" -eq 2
admit_line=$(grep -nF 'name: Admit authored attestation checkpoint' "$live_action" | cut -d: -f1)
live_payload_line=$(grep -nF 'name: Attest authored pair payload' "$live_action" | cut -d: -f1)
commit_line=$(grep -nF 'name: Commit authored attestation checkpoint' "$live_action" | cut -d: -f1)
test "$admit_line" -lt "$live_payload_line"
test "$live_payload_line" -lt "$commit_line"
test "$(grep -Fxc '    continue-on-error: true' "$live_action")" -eq 1
test "$(grep -Fxc '    if: always()' "$live_action")" -eq 1
bundle_guard_line=$(grep -nF '[[ -n "$MARU_EVIDENCE_BUNDLE"' "$live_action" | cut -d: -f1)
success_commit_line=$(grep -nF 'authored_attestation succeeded' "$live_action" | cut -d: -f1)
output_line=$(grep -nF "printf 'evidence-bundle-path=" "$live_action" | cut -d: -f1)
test "$bundle_guard_line" -lt "$success_commit_line"
test "$success_commit_line" -lt "$output_line"
test "$(grep -Fxc '          "$MARU_CHECKPOINT_EXE" commit "$MARU_CHECKPOINT_ROOT" "$MARU_CHECKPOINT_ROOT_IDENTITY" authored_attestation failed' "$live_action")" -eq 1
test "$(grep -Fxc '        *) exit 1 ;;' "$live_action")" -eq 1
test "$(grep -Fxc '    value: ${{ steps.commit.outputs.evidence-bundle-path }}' "$live_action")" -eq 1
test "$(grep -Fxc '    value: ${{ steps.commit.outputs.manifest-bundle-path }}' "$live_action")" -eq 1

fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/maru-authored-attest-action.XXXXXX")
fixture_root=$(cd "$fixture_root" && pwd -P)
trap 'rm -rf "$fixture_root"' EXIT HUP INT TERM

preparation="$fixture_root/preparation"
evidence="$preparation/baseline-evidence.json"
manifest="$preparation/Maru-1.2.3-session-host-release.json"
evidence_bundle="$fixture_root/evidence.bundle.jsonl"
manifest_bundle="$fixture_root/manifest.bundle.jsonl"

make_fixture() {
    rm -rf "$preparation"
    mkdir -m 700 "$preparation"
    printf 'baseline evidence\n' > "$evidence"
    printf 'candidate manifest\n' > "$manifest"
    chmod 600 "$evidence" "$manifest"
    printf 'evidence bundle\n' > "$evidence_bundle"
    printf 'manifest bundle\n' > "$manifest_bundle"
}

field() {
    /usr/bin/awk -F= -v key="$1" '$1 == key { print $2 }' "$2"
}

pin_pair() {
    "$helper" pin "$preparation" "$evidence" baseline-evidence.json "$manifest" Maru-1.2.3-session-host-release.json
}

verify_pair() {
    local observed=$1
    "$helper" verify \
        "$preparation" "$evidence" baseline-evidence.json "$manifest" Maru-1.2.3-session-host-release.json \
        "$(field preparation_device "$observed")" "$(field preparation_inode "$observed")" \
        "$(field preparation_owner "$observed")" "$(field preparation_mode "$observed")" \
        "$(field evidence_device "$observed")" "$(field evidence_inode "$observed")" \
        "$(field evidence_size "$observed")" "$(field evidence_links "$observed")" \
        "$(field evidence_mode "$observed")" "$(field evidence_sha256 "$observed")" \
        "$(field manifest_device "$observed")" "$(field manifest_inode "$observed")" \
        "$(field manifest_size "$observed")" "$(field manifest_links "$observed")" \
        "$(field manifest_mode "$observed")" "$(field manifest_sha256 "$observed")" \
        "$evidence_bundle" "$manifest_bundle"
}

make_fixture
pin_output="$fixture_root/pin.out"
pin_pair > "$pin_output"
final_output="$fixture_root/final.out"
verify_pair "$pin_output" > "$final_output"
test "$(field evidence-bundle-path "$final_output")" = "$evidence_bundle"
test "$(field manifest-bundle-path "$final_output")" = "$manifest_bundle"

printf X >> "$evidence"
if verify_pair "$pin_output" > "$fixture_root/unexpected.out"; then
    echo 'expected evidence mutation rejection' >&2
    exit 1
fi
test ! -s "$fixture_root/unexpected.out"

make_fixture
pin_pair > "$pin_output"
printf X >> "$manifest"
if verify_pair "$pin_output" > "$fixture_root/unexpected.out"; then
    echo 'expected manifest mutation rejection' >&2
    exit 1
fi
test ! -s "$fixture_root/unexpected.out"

make_fixture
pin_pair > "$pin_output"
mv "$preparation" "$fixture_root/old-preparation"
mkdir -m 700 "$preparation"
cp "$fixture_root/old-preparation/baseline-evidence.json" "$evidence"
cp "$fixture_root/old-preparation/Maru-1.2.3-session-host-release.json" "$manifest"
chmod 600 "$evidence" "$manifest"
if verify_pair "$pin_output" > "$fixture_root/unexpected.out"; then
    echo 'expected preparation replacement rejection' >&2
    exit 1
fi
test ! -s "$fixture_root/unexpected.out"
rm -rf "$fixture_root/old-preparation"

make_fixture
printf x > "$preparation/extra"
if pin_pair > "$fixture_root/unexpected.out"; then
    echo 'expected extra inventory rejection' >&2
    exit 1
fi
test ! -s "$fixture_root/unexpected.out"

make_fixture
rm "$manifest"
if pin_pair > "$fixture_root/unexpected.out"; then
    echo 'expected missing inventory rejection' >&2
    exit 1
fi
test ! -s "$fixture_root/unexpected.out"

make_fixture
chmod 755 "$preparation"
if pin_pair > "$fixture_root/unexpected.out"; then
    echo 'expected preparation mode rejection' >&2
    exit 1
fi
test ! -s "$fixture_root/unexpected.out"

make_fixture
chmod 644 "$evidence"
if pin_pair > "$fixture_root/unexpected.out"; then
    echo 'expected subject mode rejection' >&2
    exit 1
fi
test ! -s "$fixture_root/unexpected.out"

make_fixture
if "$helper" pin "$preparation" "$manifest" baseline-evidence.json "$evidence" Maru-1.2.3-session-host-release.json > "$fixture_root/unexpected.out"; then
    echo 'expected swapped role rejection' >&2
    exit 1
fi
test ! -s "$fixture_root/unexpected.out"

make_fixture
if "$helper" pin relative "$evidence" baseline-evidence.json "$manifest" Maru-1.2.3-session-host-release.json > "$fixture_root/unexpected.out"; then
    echo 'expected relative preparation rejection' >&2
    exit 1
fi
test ! -s "$fixture_root/unexpected.out"

control_path="$fixture_root/line"$'\n'"break"
mkdir -m 700 "$control_path"
if "$helper" pin "$control_path" "$evidence" baseline-evidence.json "$manifest" Maru-1.2.3-session-host-release.json > "$fixture_root/unexpected.out"; then
    echo 'expected control path rejection' >&2
    exit 1
fi
test ! -s "$fixture_root/unexpected.out"

make_fixture
ln -s "$preparation" "$fixture_root/preparation-link"
if "$helper" pin "$fixture_root/preparation-link" "$evidence" baseline-evidence.json "$manifest" Maru-1.2.3-session-host-release.json > "$fixture_root/unexpected.out"; then
    echo 'expected preparation symlink rejection' >&2
    exit 1
fi
test ! -s "$fixture_root/unexpected.out"

make_fixture
ln -s "$evidence" "$fixture_root/evidence-link"
if "$helper" pin "$preparation" "$fixture_root/evidence-link" baseline-evidence.json "$manifest" Maru-1.2.3-session-host-release.json > "$fixture_root/unexpected.out"; then
    echo 'expected symlink rejection' >&2
    exit 1
fi
test ! -s "$fixture_root/unexpected.out"

make_fixture
ln "$evidence_bundle" "$fixture_root/evidence-bundle-hardlink"
pin_pair > "$pin_output"
if verify_pair "$pin_output" > "$fixture_root/unexpected.out"; then
    echo 'expected hardlinked bundle rejection' >&2
    exit 1
fi
test ! -s "$fixture_root/unexpected.out"
rm "$fixture_root/evidence-bundle-hardlink"

make_fixture
: > "$evidence_bundle"
pin_pair > "$pin_output"
if verify_pair "$pin_output" > "$fixture_root/unexpected.out"; then
    echo 'expected empty bundle rejection' >&2
    exit 1
fi
test ! -s "$fixture_root/unexpected.out"

make_fixture
pin_pair > "$pin_output"
evidence_bundle="$evidence"
if verify_pair "$pin_output" > "$fixture_root/unexpected.out"; then
    echo 'expected subject bundle alias rejection' >&2
    exit 1
fi
test ! -s "$fixture_root/unexpected.out"
evidence_bundle="$fixture_root/evidence.bundle.jsonl"

make_fixture
/usr/bin/truncate -s 16777217 "$evidence_bundle" 2>/dev/null || truncate -s 16777217 "$evidence_bundle"
pin_pair > "$pin_output"
if verify_pair "$pin_output" > "$fixture_root/unexpected.out"; then
    echo 'expected oversized bundle rejection' >&2
    exit 1
fi
test ! -s "$fixture_root/unexpected.out"

make_fixture
pin_pair > "$pin_output"
mv "$evidence_bundle" "$preparation/evidence.bundle.jsonl"
evidence_bundle="$preparation/evidence.bundle.jsonl"
if verify_pair "$pin_output" > "$fixture_root/unexpected.out"; then
    echo 'expected preparation-contained bundle rejection' >&2
    exit 1
fi
test ! -s "$fixture_root/unexpected.out"
