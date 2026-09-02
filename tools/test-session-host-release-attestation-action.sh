#!/bin/bash
set -euo pipefail

action=.github/actions/session-host-release-attest/action.yml
helper=.github/actions/session-host-release-attest/pin-subject.sh
test -f "$action"
test -x "$helper"
test "$(grep -Fxc '        Darwin)' "$helper")" -eq 1
test "$(grep -Fxc '        Linux)' "$helper")" -eq 1
test "$(grep -Fc "/usr/bin/stat -f '%d %i %z %l'" "$helper")" -eq 1
test "$(grep -Fc "/usr/bin/stat -c '%d %i %s %h'" "$helper")" -eq 1
test "$(grep -Fc '/usr/bin/sha256sum' "$helper")" -eq 1

test "$(grep -Fxc '    uses: actions/attest@1e69f48acb82d1966a394da916b4c1698aa569d6 # v4.2.2' "$action")" -eq 1
test "$(grep -Fxc '      subject-name: ${{ inputs.subject-name }}' "$action")" -eq 1
test "$(grep -Fxc '      subject-digest: sha256:${{ steps.pin.outputs.sha256 }}' "$action")" -eq 1
test "$(grep -Fc 'uses: actions/attest@' "$action")" -eq 1
! grep -Eq 'subject-checksums|predicate|push-to-registry|eval|command -v' "$action"
test "$(grep -Fc 'subject-path: ${{ inputs.subject-path }}' "$action")" -eq 0
test "$(grep -Fc '[[ -n "$MARU_ATTESTATION_' "$action")" -eq 2
test "$(grep -Fc '[[ -n "$MARU_BUNDLE_PATH"' "$action")" -eq 1

pin_line=$(grep -nF 'name: Pin exact subject' "$action" | cut -d: -f1)
attest_line=$(grep -nF 'name: Attest exact subject' "$action" | cut -d: -f1)
verify_line=$(grep -nF 'name: Revalidate exact subject' "$action" | cut -d: -f1)
test "$pin_line" -lt "$attest_line"
test "$attest_line" -lt "$verify_line"

fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/maru-attest-action.XXXXXX")
fixture_root=$(cd "$fixture_root" && pwd -P)
trap 'rm -rf "$fixture_root"' EXIT HUP INT TERM
subject="$fixture_root/artifact.bin"
printf 'candidate bytes\n' > "$subject"
pin_output="$fixture_root/pin.out"
"$helper" pin "$subject" artifact.bin > "$pin_output"
device=$(awk -F= '$1 == "device" { print $2 }' "$pin_output")
inode=$(awk -F= '$1 == "inode" { print $2 }' "$pin_output")
size=$(awk -F= '$1 == "size" { print $2 }' "$pin_output")
links=$(awk -F= '$1 == "links" { print $2 }' "$pin_output")
sha256=$(awk -F= '$1 == "sha256" { print $2 }' "$pin_output")
test -n "$device" && test -n "$inode" && test -n "$size" && test "$links" = 1 && test "${#sha256}" -eq 64
"$helper" verify "$subject" artifact.bin "$device" "$inode" "$size" "$links" "$sha256"

printf 'mutated bytes\n' > "$subject"
if "$helper" verify "$subject" artifact.bin "$device" "$inode" "$size" "$links" "$sha256"; then
    echo 'expected mutation rejection' >&2
    exit 1
fi
printf x > "$fixture_root/glob[1].bin"
if "$helper" pin "$fixture_root/glob[1].bin" 'glob[1].bin'; then
    echo 'expected glob-character rejection' >&2
    exit 1
fi
printf x > "$fixture_root/hardlink-source.bin"
ln "$fixture_root/hardlink-source.bin" "$fixture_root/hardlink.bin"
if "$helper" pin "$fixture_root/hardlink.bin" hardlink.bin; then
    echo 'expected hardlink rejection' >&2
    exit 1
fi
ln -s "$subject" "$fixture_root/link.bin"
if "$helper" pin "$fixture_root/link.bin" link.bin; then
    echo 'expected symlink rejection' >&2
    exit 1
fi
if "$helper" pin "$subject" wrong.bin; then
    echo 'expected basename rejection' >&2
    exit 1
fi
control_path="$fixture_root/line"$'\n'"break"
printf x > "$control_path"
if "$helper" pin "$control_path" break; then
    echo 'expected control-character rejection' >&2
    exit 1
fi
