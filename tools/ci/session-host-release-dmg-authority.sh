#!/bin/sh
set -eu

test_bin=$1
fixture_root=$(mktemp -d /tmp/maru-release-dmg-authority.XXXXXX)
fixture_root=$(cd "$fixture_root" && pwd -P)
source_root="$fixture_root/source"
dmg="$fixture_root/candidate.dmg"
work="$fixture_root/private-work"
cleanup() {
  hdiutil detach "$work-success/mount" -force >/dev/null 2>&1 || true
  hdiutil detach "$work-failure/mount" -force >/dev/null 2>&1 || true
  rm -rf "$fixture_root"
}
trap cleanup EXIT INT TERM

mkdir -p "$source_root/Maru.app/Contents/MacOS" "$source_root/Maru.app/Contents/Helpers"
printf '%s\n' fixture-plist > "$source_root/Maru.app/Contents/Info.plist"
printf '%s\n' frozen-product > "$source_root/Maru.app/Contents/MacOS/maru-macos-app"
printf '%s\n' candidate-cli > "$source_root/Maru.app/Contents/MacOS/maru"
printf '%s\n' notification-helper > "$source_root/Maru.app/Contents/Helpers/maru-session-host-notification-center-helper"
hdiutil create -quiet -fs HFS+ -format UDZO -srcfolder "$source_root" "$dmg"

MARU_DMG_AUTHORITY_CANDIDATE="$dmg" \
MARU_DMG_AUTHORITY_WORK="$work" \
MARU_DMG_AUTHORITY_SIZE=$(stat -f %z "$dmg") \
MARU_DMG_AUTHORITY_SHA256=$(shasum -a 256 "$dmg" | awk '{print $1}') \
"$test_bin" --maru-expect-tests=1

test ! -e "$work-success"
test ! -e "$work-failure"
if hdiutil info | grep -F "$work-" >/dev/null; then
  echo "DMG authority left a mounted fixture" >&2
  exit 1
fi
