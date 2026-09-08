#!/bin/bash
set -euo pipefail

action=.github/actions/session-host-release-attest-authored/action.yml
helper=.github/actions/session-host-release-attest-authored/pin-authored-pair.sh
single_action='./.github/actions/session-host-release-attest'
live_action=.github/actions/session-host-release-live-authored-attestation/action.yml
payload_action='./.github/actions/session-host-release-attest-authored-profile'
legacy_payload_action='./.github/actions/session-host-release-attest-authored'
contract=src/platform/macos/session_host/release_adapter_attestation_bundle_contract.zig
workflow=.github/workflows/release.yml
build_file=build.zig

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
for input in preparation-path baseline-evidence-path upgrade-evidence-path manifest-path timing-path gh-path gh-sha256; do
  expected_count=1
  # timing-path is both a closed input and a final-fence output.
  if [[ "$input" == timing-path ]]; then expected_count=2; fi
  test "$(grep -Fxc "  $input:" "$live_action")" -eq "$expected_count"
    test "$(grep -Fc "inputs.$input" "$live_action")" -ge 1
done
for input in checkpoint-root checkpoint-root-identity; do
    test "$(grep -Fxc "  $input:" "$live_action")" -eq 1
done
test "$(grep -Fxc "    uses: $payload_action" "$live_action")" -eq 1
test "$(grep -Fxc "    uses: $legacy_payload_action" "$live_action")" -eq 0
test "$(grep -Fc 'uses: actions/attest@' "$live_action")" -eq 0
test "$(grep -Fc '/zig-out/bin/maru-session-host-release-workflow-checkpoint' "$live_action")" -eq 2
admit_line=$(grep -nF 'name: Admit authored attestation checkpoint' "$live_action" | cut -d: -f1)
select_line=$(grep -nF 'name: Select authored subjects without credentials' "$live_action" | cut -d: -f1)
live_payload_line=$(grep -nF 'name: Attest profile-selected authored payload' "$live_action" | cut -d: -f1)
fence_line=$(grep -nF 'name: Fence authored bundles without credentials' "$live_action" | cut -d: -f1)
commit_line=$(grep -nF 'name: Commit authored attestation checkpoint' "$live_action" | cut -d: -f1)
test "$admit_line" -lt "$select_line"
test "$select_line" -lt "$live_payload_line"
test "$live_payload_line" -lt "$fence_line"
test "$fence_line" -lt "$commit_line"
test "$live_payload_line" -lt "$commit_line"
test "$(grep -Fxc '    continue-on-error: true' "$live_action")" -eq 3
test "$(grep -Fxc '    if: always()' "$live_action")" -eq 1
test "$(grep -Fxc '    if: ${{ steps.select.outcome == '\''success'\'' }}' "$live_action")" -eq 1
test "$(grep -Fxc '    if: ${{ steps.select.outcome == '\''success'\'' && steps.payload.outcome == '\''success'\'' }}' "$live_action")" -eq 1
test "$(grep -Fc '/zig-out/bin/maru-session-host-release-workflow-authored-selector' "$live_action")" -eq 2
test "$(grep -Fxc '            session-host-release-workflow-authored-selector \' "$workflow")" -eq 1
test "$(grep -Fxc '        "session-host-release-workflow-authored-selector",' "$build_file")" -eq 1
test "$(grep -Fxc '                        .dest_sub_path = "maru-session-host-release-workflow-authored-selector",' "$build_file")" -eq 1
test "$(grep -Fc 'GH_TOKEN:' "$live_action")" -eq 0
test "$(grep -Ec '(^|[[:space:]])(eval|source)([[:space:]]|$)' "$live_action")" -eq 0
test "$(grep -Fc 'GITHUB_ENV' "$live_action")" -eq 0
commit_helper=.github/actions/session-host-release-live-authored-attestation/commit-profile-authored.sh
checkpoint_fixture=tools/session-host/test_profile_authored_checkpoint.sh
test -x "$commit_helper"
test -x "$checkpoint_fixture"
test "$(grep -Fxc '      MARU_COMMIT_HELPER: ${{ github.action_path }}/commit-profile-authored.sh' "$live_action")" -eq 1
test "$(grep -Fxc '      "$MARU_COMMIT_HELPER" "$MARU_SELECT_OUTCOME" "$MARU_PAYLOAD_OUTCOME" "$MARU_FENCE_OUTCOME" \' "$live_action")" -eq 1
test "$(grep -Fxc '    value: ${{ steps.commit.outputs.evidence-bundle-path }}' "$live_action")" -eq 1
test "$(grep -Fxc '    value: ${{ steps.commit.outputs.evidence-path }}' "$live_action")" -eq 1
test "$(grep -Fxc '    value: ${{ steps.commit.outputs.timing-path }}' "$live_action")" -eq 1
test "$(grep -Fxc '    value: ${{ steps.commit.outputs.manifest-bundle-path }}' "$live_action")" -eq 1
test "$(grep -Fxc '    value: ${{ steps.commit.outputs.timing-bundle-path }}' "$live_action")" -eq 1

fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/maru-authored-attest-action.XXXXXX")
fixture_root=$(cd "$fixture_root" && pwd -P)
trap 'rm -rf "$fixture_root"' EXIT HUP INT TERM

checkpoint_log="$fixture_root/checkpoint.log"
live_output="$fixture_root/live.out"
sentinel=sealed-test-root
export MARU_TEST_CHECKPOINT_LOG="$checkpoint_log"
export MARU_TEST_CHECKPOINT_SENTINEL="$sentinel"

run_commit() {
    "$commit_helper" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" \
        "$checkpoint_fixture" "$fixture_root/checkpoints" "$sentinel" "$live_output"
}

run_commit success success success false "$fixture_root/evidence.json" '' "$fixture_root/evidence.bundle" "$fixture_root/manifest.bundle" ''
test "$(wc -l < "$checkpoint_log" | tr -d ' ')" -eq 1
test "$(tail -n 1 "$checkpoint_log")" = "commit $fixture_root/checkpoints $sentinel authored_attestation succeeded"
test "$(wc -l < "$live_output" | tr -d ' ')" -eq 5
test "$(sed -n '1p' "$live_output")" = "evidence-path=$fixture_root/evidence.json"
test "$(sed -n '2p' "$live_output")" = 'timing-path='
test "$(sed -n '5p' "$live_output")" = 'timing-bundle-path='

: > "$checkpoint_log"
: > "$live_output"
run_commit success success success true "$fixture_root/evidence.json" "$fixture_root/timing.json" "$fixture_root/evidence.bundle" "$fixture_root/manifest.bundle" "$fixture_root/timing.bundle"
test "$(tail -n 1 "$checkpoint_log")" = "commit $fixture_root/checkpoints $sentinel authored_attestation succeeded"
test "$(sed -n '2p' "$live_output")" = "timing-path=$fixture_root/timing.json"
test "$(sed -n '5p' "$live_output")" = "timing-bundle-path=$fixture_root/timing.bundle"

for outcomes in 'failure skipped skipped' 'success failure skipped' 'success success failure' 'cancelled skipped skipped'; do
    : > "$checkpoint_log"
    : > "$live_output"
    read -r select_outcome payload_outcome fence_outcome <<< "$outcomes"
    if run_commit "$select_outcome" "$payload_outcome" "$fence_outcome" false '' '' '' '' ''; then
        echo 'expected terminal outcome rejection' >&2
        exit 1
    fi
    test "$(wc -l < "$checkpoint_log" | tr -d ' ')" -eq 1
    test "$(tail -n 1 "$checkpoint_log")" = "commit $fixture_root/checkpoints $sentinel authored_attestation failed"
    test ! -s "$live_output"
done

: > "$checkpoint_log"
: > "$live_output"
if run_commit success success success false "$fixture_root/evidence.json" '' "$fixture_root/evidence.bundle" "$fixture_root/manifest.bundle" "$fixture_root/unexpected-timing.bundle"; then
    echo 'expected baseline timing contradiction rejection' >&2
    exit 1
fi
test "$(tail -n 1 "$checkpoint_log")" = "commit $fixture_root/checkpoints $sentinel authored_attestation failed"
test ! -s "$live_output"

for invalid_bundle in 'relative.bundle' '/tmp/a/../bundle' '/tmp/a/.' '/tmp/trailing/' $'/tmp/control\tbundle'; do
    : > "$checkpoint_log"
    : > "$live_output"
    if run_commit success success success false "$fixture_root/evidence.json" '' "$invalid_bundle" "$fixture_root/manifest.bundle" ''; then
        echo 'expected noncanonical final-fence output rejection' >&2
        exit 1
    fi
    test "$(tail -n 1 "$checkpoint_log")" = "commit $fixture_root/checkpoints $sentinel authored_attestation failed"
    test ! -s "$live_output"
done

: > "$checkpoint_log"
: > "$live_output"
MARU_TEST_CHECKPOINT_FAIL=1
export MARU_TEST_CHECKPOINT_FAIL
if run_commit success success success false "$fixture_root/evidence.json" '' "$fixture_root/evidence.bundle" "$fixture_root/manifest.bundle" ''; then
    echo 'expected checkpoint failure propagation' >&2
    exit 1
fi
unset MARU_TEST_CHECKPOINT_FAIL
test "$(wc -l < "$checkpoint_log" | tr -d ' ')" -eq 1
test ! -s "$live_output"

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
