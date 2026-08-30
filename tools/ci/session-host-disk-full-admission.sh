#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <test-executable>" >&2
  exit 64
fi
if [ -z "${MARU_SESSION_HOST_PRODUCT_EXE:-}" ]; then
  echo "MARU_SESSION_HOST_PRODUCT_EXE is required" >&2
  exit 64
fi

product_bytes=$(stat -f %z "$MARU_SESSION_HOST_PRODUCT_EXE")
image_bytes=$((product_bytes * 2 + 128 * 1024 * 1024))
image_megabytes=$(((image_bytes + 1024 * 1024 - 1) / (1024 * 1024)))

fixture_root=$(mktemp -d /tmp/maru-disk-full.XXXXXX)
image="$fixture_root/fixture.dmg"
mount="$fixture_root/mount"
mkdir -m 700 "$mount"
mounted=0
cleanup() {
  if [ "$mounted" -eq 1 ]; then
    hdiutil detach "$mount" -force >/dev/null 2>&1 || true
  fi
  unlink "$image" 2>/dev/null || true
  rmdir "$mount" 2>/dev/null || true
  rmdir "$fixture_root" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

hdiutil create -size "${image_megabytes}m" -fs HFS+ -volname MaruDiskFullFixture -ov "$image" >/dev/null
hdiutil attach -nobrowse -mountpoint "$mount" "$image" >/dev/null
mounted=1
MARU_SESSION_HOST_DISK_FULL_MOUNT="$mount" "$1" --maru-expect-tests=1
