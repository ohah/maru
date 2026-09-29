#!/bin/sh
# `tools/check-macos-app-entitlements.sh` 자체 시험(W7a1 적대 검증 8 차) — 그 검사는 릴리스 서명에서만 돌아 결함이 첫 출시에야
# 드러난다. 가짜 번들(main executable·CLI 는 `/usr/bin/true` 사본)을 ad-hoc 서명해 다섯 경우를 본다. `zig build
# test-macos-app-entitlements-check`(macOS CI 의 `test-macos-only`)가 부른다.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
check="$here/tools/check-macos-app-entitlements.sh"
ent="$here/src/platform/macos/MaruApp.entitlements"
root=$(mktemp -d "${TMPDIR:-/tmp}/maru-entcheck.XXXXXX")
trap 'rm -rf "$root"' EXIT

make_app() {
    app="$root/$1/Maru.app"
    mkdir -p "$app/Contents/MacOS"
    cp /usr/bin/true "$app/Contents/MacOS/maru-macos-app"
    cp /usr/bin/true "$app/Contents/MacOS/maru"
    cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>maru-macos-app</string>
	<key>CFBundleIdentifier</key>
	<string>dev.maru.entitlements-check</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
</dict>
</plist>
PLIST
    printf '%s\n' "$app"
}

extra="$root/extra.entitlements"
sed 's#</dict>#	<key>com.apple.security.cs.disable-library-validation</key>\
	<true/>\
</dict>#' "$ent" > "$extra"

# 서명이 실패하면 이유를 보이고 멈춘다(`set -e` 로 말없이 끝나지 않게 — W7a1 적대 검증 9 차).
sign() {
    if ! codesign "$@" 2> "$root/codesign.txt"; then
        echo "codesign 실패: $*" >&2
        cat "$root/codesign.txt" >&2
        exit 1
    fi
}

failures=0
expect() {
    want=$1
    name=$2
    app=$3
    if sh "$check" "$app" > "$root/out.txt" 2>&1; then got=pass; else got=fail; fi
    if [ "$got" = "$want" ]; then
        echo "PASS $name ($got)"
    else
        echo "FAIL $name — $want 이어야 하는데 $got" >&2
        cat "$root/out.txt" >&2
        failures=$((failures + 1))
    fi
}

# ① 릴리스와 같은 모양: CLI 는 entitlements 없이, 번들(main executable)은 셋.
app=$(make_app good)
sign --force --sign - "$app/Contents/MacOS/maru"
sign --force --options runtime --sign - --entitlements "$ent" "$app"
expect pass "entitlements 셋이 main executable 에만" "$app"

# ② main executable 에 키가 하나 더.
app=$(make_app extra)
sign --force --sign - "$app/Contents/MacOS/maru"
sign --force --options runtime --sign - --entitlements "$extra" "$app"
expect fail "main executable 에 넷째 키" "$app"

# ③ 번들 서명에 entitlements 가 빠짐.
app=$(make_app none)
sign --force --sign - "$app/Contents/MacOS/maru"
sign --force --options runtime --sign - "$app"
expect fail "main executable 에 entitlements 없음" "$app"

# ④ CLI 에도 entitlements 가 붙음.
app=$(make_app cli)
sign --force --sign - --entitlements "$ent" "$app/Contents/MacOS/maru"
sign --force --options runtime --sign - --entitlements "$ent" "$app"
expect fail "CLI 에 entitlements" "$app"

# ⑤ CLI 서명이 없음(읽지 못하면 실패).
app=$(make_app unsigned)
sign --force --options runtime --sign - --entitlements "$ent" "$app"
sign --remove-signature "$app/Contents/MacOS/maru"
expect fail "CLI 서명 없음" "$app"

if [ "$failures" != 0 ]; then
    echo "check-macos-app-entitlements 자체 시험: 틀림 $failures 건" >&2
    exit 1
fi
echo "check-macos-app-entitlements 자체 시험: 다섯 경우 모두 맞음"
