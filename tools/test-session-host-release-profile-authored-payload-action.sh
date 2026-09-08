#!/bin/bash
set -euo pipefail

action=.github/actions/session-host-release-attest-authored-profile/action.yml
helper=.github/actions/session-host-release-attest-authored-profile/validate-projection.sh
single_action='./.github/actions/session-host-release-attest'

test -f "$action"
test -x "$helper"

for input in evidence-path evidence-name manifest-path manifest-name timing-required timing-path timing-name; do
    test "$(grep -Fxc "  $input:" "$action")" -eq 1
done
for output in evidence-bundle-path manifest-bundle-path timing-bundle-path; do
    test "$(grep -Fxc "  $output:" "$action")" -eq 1
done

test "$(grep -Fxc "    uses: $single_action" "$action")" -eq 3
test "$(grep -Fc 'uses: actions/attest@' "$action")" -eq 0
test "$(grep -Ec 'MARU_SESSION_HOST_RELEASE_PROFILE|github\.token|GH_TOKEN|GITHUB_ENV|test +-|\[\[ +-e|\[\[ +-f|stat |readlink |realpath ' "$action")" -eq 0
test "$(grep -Fxc '    if: ${{ inputs.timing-required == '\''true'\'' }}' "$action")" -eq 1

preflight_line=$(grep -nF 'name: Validate closed authored subject projection' "$action" | cut -d: -f1)
evidence_line=$(grep -nF 'name: Attest selected evidence' "$action" | cut -d: -f1)
manifest_line=$(grep -nF 'name: Attest selected manifest' "$action" | cut -d: -f1)
timing_line=$(grep -nF 'name: Attest authenticated upgrade timing' "$action" | cut -d: -f1)
test "$preflight_line" -lt "$evidence_line"
test "$evidence_line" -lt "$manifest_line"
test "$manifest_line" -lt "$timing_line"

test "$(grep -Fxc '      subject-path: ${{ inputs.evidence-path }}' "$action")" -eq 1
test "$(grep -Fxc '      subject-name: ${{ inputs.evidence-name }}' "$action")" -eq 1
test "$(grep -Fxc '      subject-path: ${{ inputs.manifest-path }}' "$action")" -eq 1
test "$(grep -Fxc '      subject-name: ${{ inputs.manifest-name }}' "$action")" -eq 1
test "$(grep -Fxc '      subject-path: ${{ inputs.timing-path }}' "$action")" -eq 1
test "$(grep -Fxc '      subject-name: ${{ inputs.timing-name }}' "$action")" -eq 1

test "$(grep -Fxc '    value: ${{ steps.evidence.outputs.bundle-path }}' "$action")" -eq 1
test "$(grep -Fxc '    value: ${{ steps.manifest.outputs.bundle-path }}' "$action")" -eq 1
test "$(grep -Fxc '    value: ${{ steps.timing.outputs.bundle-path }}' "$action")" -eq 1
test "$(grep -Fc 'attestation-id' "$action")" -eq 0
test "$(grep -Fc 'attestation-url' "$action")" -eq 0

test "$(grep -Fc '>> "$GITHUB_OUTPUT"' "$action")" -eq 0
test "$(grep -Fc '/validate-projection.sh" \' "$action")" -eq 1
! grep -Eq '(^|[^A-Z_])GH_TOKEN([^A-Z_]|$)|GITHUB_ENV|test +-|\[\[ +-e|\[\[ +-f|stat |readlink |realpath ' "$helper"

baseline=(
    /tmp/preparation/baseline-evidence.json baseline-evidence.json
    /tmp/preparation/Maru-1.2.3-session-host-release.json Maru-1.2.3-session-host-release.json
    false '' ''
)
upgrade=(
    /tmp/preparation/upgrade-evidence.json upgrade-evidence.json
    /tmp/preparation/Maru-1.2.3-session-host-release.json Maru-1.2.3-session-host-release.json
    true /tmp/profile-upgrade-timing.json profile-upgrade-timing.json
)
"$helper" "${baseline[@]}"
"$helper" "${upgrade[@]}"

reject() {
    if "$helper" "$@" > /dev/null 2>&1; then
        echo 'expected projection rejection' >&2
        exit 1
    fi
}

reject "${baseline[@]:0:4}" true '' ''
reject "${baseline[@]:0:4}" false /tmp/profile-upgrade-timing.json profile-upgrade-timing.json
reject /tmp/preparation/upgrade-evidence.json upgrade-evidence.json "${baseline[@]:2:2}" false '' ''
reject "${upgrade[@]:0:4}" true '' profile-upgrade-timing.json
reject "${upgrade[@]:0:4}" true /tmp/profile-upgrade-timing.json wrong.json
reject /tmp/preparation/baseline-evidence.json baseline-evidence.json /tmp/other/Maru-1.2.3-session-host-release.json Maru-1.2.3-session-host-release.json false '' ''
reject /tmp/preparation/baseline-evidence.json baseline-evidence.json /tmp/preparation/baseline-evidence.json baseline-evidence.json false '' ''
reject $'/tmp/preparation/bad\nname.json' badname.json "${baseline[@]:2:5}"
reject relative/baseline-evidence.json baseline-evidence.json "${baseline[@]:2:5}"
reject /tmp/preparation/../baseline-evidence.json baseline-evidence.json "${baseline[@]:2:5}"
reject /tmp//preparation/baseline-evidence.json baseline-evidence.json /tmp//preparation/Maru-1.2.3-session-host-release.json Maru-1.2.3-session-host-release.json false '' ''
reject "${upgrade[@]:0:4}" true /tmp/preparation/nested/profile-upgrade-timing.json profile-upgrade-timing.json
