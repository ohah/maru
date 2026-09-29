#!/bin/sh
# 서명한 Maru.app 의 main executable 이 릴리스 entitlements(카메라·마이크·위치 — W7a1)를 **정확히** 가졌는지 본다.
# hardened runtime 에서 이것이 빠지면 macOS 가 Chromium 탭의 권한 요청을 묻지 않고 거절할 수 있다.
# 사용: sh tools/check-macos-app-entitlements.sh <Maru.app>
set -eu
app=$1
plist=$(mktemp "${TMPDIR:-/tmp}/maru-entitlements.XXXXXX")
trap 'rm -f "$plist"' EXIT
if ! codesign -d --entitlements - --xml "$app/Contents/MacOS/maru-macos-app" > "$plist" 2>/dev/null; then
    echo "error: $app 의 main executable 서명을 읽지 못했다(서명되지 않았나?)" >&2
    exit 1
fi
for key in com.apple.security.device.camera com.apple.security.device.audio-input com.apple.security.personal-information.location; do
    if [ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null)" != true ]; then
        echo "error: $app 의 main executable 에 $key 가 없다" >&2
        exit 1
    fi
done
count=$(/usr/libexec/PlistBuddy -c "Print" "$plist" | grep -c " = " || true)
if [ "$count" != 3 ]; then
    echo "error: $app 의 main executable entitlements 가 셋이 아니다($count) — 넓히려면 이 검사와 MaruApp.entitlements 를 함께 고친다" >&2
    exit 1
fi
echo "==> Maru.app entitlements OK (camera · audio-input · location)"
