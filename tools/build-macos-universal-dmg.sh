#!/bin/sh
# Maru universal(arm64 + x86_64) .app을 빌드해 서명·공증·staple한 배포용 .dmg를 만든다.
#
# 왜 스크립트인가: build.zig의 macos-dmg 스텝은 단일 아키텍처(host)만 만든다. universal은
# 같은 앱을 두 아키텍처로 따로 빌드한 뒤 lipo로 실행파일을 합쳐야 하는데, 이는 한 번의
# `zig build` 호출(전역 target 하나)로 표현하기 어렵다. 그래서 두 번의 macos-app-bundle
# 빌드를 오케스트레이션하는 별도 스크립트로 둔다. x86_64를 arm64 호스트에서 cross 빌드하는
# SDK 통합(sysroot 등)은 build.zig가 처리한다(거기 주석 참고).
#
# 사전조건(둘 다 로컬에만 두고 리포엔 없음):
#   1) 키체인에 Developer ID Application 인증서 (서명 이름은 MARU_SIGN_IDENTITY로 덮어쓰기)
#   2) notarytool 키체인 프로파일 (기본 maru-notary, MARU_NOTARY_PROFILE로 덮어쓰기):
#        xcrun notarytool store-credentials maru-notary \
#          --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
#          --password "$APPLE_APP_SPECIFIC_PASSWORD"
#
# 산출물: dist/Maru-<버전>-universal.dmg (dist/는 git에 커밋하지 않는다)
set -eu

# 서명 주체(조직명·Team ID)는 저장소에 두지 않는다. 키체인에 인증서가 하나면 이 접두사만으로 찾히고,
# 여러 개면 MARU_SIGN_IDENTITY로 전체 이름을 지정한다.
SIGN_ID="${MARU_SIGN_IDENTITY:-Developer ID Application}"
PROFILE="${MARU_NOTARY_PROFILE:-maru-notary}"
ZIG="${ZIG:-zig}"
# 배포 하한(11.0)은 build.zig의 default_target과 맞춘다. arm64는 Apple Silicon 시작 버전이라
# 이 값이 하한이고, x86_64도 같은 값으로 맞춰 한 dmg가 두 아키텍처에서 동일 하한을 갖게 한다.
MIN="11.0"

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "==> build arm64 (aarch64-macos.$MIN)"
"$ZIG" build macos-app-bundle -Doptimize=ReleaseFast -Dtarget="aarch64-macos.$MIN"
cp -R zig-out/Maru.app "$work/arm.app"

echo "==> build x86_64 (x86_64-macos.$MIN)"
"$ZIG" build macos-app-bundle -Doptimize=ReleaseFast -Dtarget="x86_64-macos.$MIN"
cp -R zig-out/Maru.app "$work/x86.app"

echo "==> lipo merge -> universal .app"
# arm64 빌드를 베이스로 쓰고(Info.plist·Resources 동일), 실행파일만 두 아키텍처로 합친다.
cp -R "$work/arm.app" "$work/Maru.app"
app="$work/Maru.app"
helper_rel="Contents/Helpers/MaruMermaidRenderer.app"
helper_bin_rel="$helper_rel/Contents/MacOS/maru-mermaid-renderer"
for bin in maru-macos-app maru; do
    lipo -create \
        "$work/arm.app/Contents/MacOS/$bin" \
        "$work/x86.app/Contents/MacOS/$bin" \
        -output "$app/Contents/MacOS/$bin"
done
# Helper의 Swift executable만 lipo 대상이다. Info/resource가 arch build 사이에서 달라지면 arm
# 번들을 임의 선택하지 않고 실패해 embedded digest와 nested resource seal의 결합을 보존한다.
cmp "$work/arm.app/Contents/Info.plist" "$work/x86.app/Contents/Info.plist"
cmp "$work/arm.app/$helper_rel/Contents/Info.plist" "$work/x86.app/$helper_rel/Contents/Info.plist"
cmp "$work/arm.app/$helper_rel/Contents/Resources/web/mermaid-helper.js" "$work/x86.app/$helper_rel/Contents/Resources/web/mermaid-helper.js"
lipo -create \
    "$work/arm.app/$helper_bin_rel" \
    "$work/x86.app/$helper_bin_rel" \
    -output "$app/$helper_bin_rel"
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
echo "    universal archs: $(lipo -archs "$app/Contents/MacOS/maru-macos-app")"
for universal_bin in \
    "$app/Contents/MacOS/maru-macos-app" \
    "$app/Contents/MacOS/maru" \
    "$app/$helper_bin_rel"
do
    archs=$(lipo -archs "$universal_bin")
    case "$archs" in
        "arm64 x86_64"|"x86_64 arm64") ;;
        *) echo "error: non-universal executable: $universal_bin ($archs)" >&2; exit 1 ;;
    esac
done
test ! -e "$app/Contents/Helpers/maru-mermaid-renderer"
test ! -e "$app/Contents/Resources/web/mermaid-helper.js"

echo "==> codesign (Developer ID, hardened runtime, timestamp)"
# 중첩 실행파일을 먼저 서명하고 마지막에 번들을 서명한다.
codesign --force --options runtime --timestamp \
    --entitlements src/platform/macos/MaruMermaidRenderer.entitlements \
    --sign "$SIGN_ID" "$app/$helper_rel"
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$app/Contents/MacOS/maru"
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$app/Contents/MacOS/maru-macos-app"
# RW2b 감시자(Resources/remote-watch/<variant>/maru-remote-watch). **번들 서명은 이들을 봉인만 하고
# 서명하지 않는다** — `codesign "$app"` 은 Resources 안의 Mach-O 를 seal 에 넣을 뿐이라 각 실행파일은
# 서명도, hardened runtime 도, secure timestamp 도 없는 채로 남는다. `--verify --strict --deep` 은
# 중첩 **번들**을 따라가므로 이것을 잡지 못하고 통과하지만, 공증은 모든 Mach-O 를 검사해 거부한다.
# 2026-09-03 실측: 공증이 `Invalid` 로 돌아왔고 사유 6 건이 전부 이 두 파일이었다.
# linux 변종은 ELF 라 서명 대상이 아니므로 `macos-*` 만 고른다.
for watcher in "$app"/Contents/Resources/remote-watch/macos-*/maru-remote-watch; do
    [ -f "$watcher" ] || continue
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$watcher"
done
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$app"
codesign --verify --strict --deep "$app"

echo "==> P5d signed artifact PATH + localhost SSH gate"
MARU_P5D_REQUIRE_DEVELOPER_ID=1 \
"$ZIG" build test-session-host-p5d-artifact \
	-Dp5d-artifact-cli="$app/Contents/MacOS/maru" -Doptimize=ReleaseFast -j1

echo "==> notarize .app + staple (티켓을 .app에 부착 — dmg에서 꺼내 복사해도 Gatekeeper 통과)"
ditto -c -k --keepParent "$app" "$work/app.zip"
xcrun notarytool submit "$work/app.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"

echo "==> create dmg + sign"
mkdir -p "$work/stage"
ditto "$app" "$work/stage/Maru.app"
ln -s /Applications "$work/stage/Applications"
dmg="$work/Maru-${version}-universal.dmg"
hdiutil create -volname Maru -srcfolder "$work/stage" -ov -format UDZO "$dmg"
codesign --force --timestamp --sign "$SIGN_ID" "$dmg"

echo "==> notarize dmg + staple"
xcrun notarytool submit "$dmg" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$dmg"

mkdir -p dist
out="dist/Maru-${version}-universal.dmg"
cp "$dmg" "$out"
echo "==> verify"
spctl -a -t open --context context:primary-signature -v "$out"
echo "==> done: $out ($(lipo -archs "$app/Contents/MacOS/maru-macos-app"))"
