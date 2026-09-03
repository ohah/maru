#!/bin/sh
set -eu

repo_root=$(cd "$(dirname "$0")/.." && pwd)
publisher="$repo_root/tools/publish-macos-release-candidate.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

make_inputs() {
    root=$1
    mkdir -p "$root/Maru.app/Contents/MacOS" "$root/out"
    printf 'universal executable bytes\n' > "$root/Maru.app/Contents/MacOS/maru-macos-app"
    chmod 755 "$root/Maru.app/Contents/MacOS/maru-macos-app"
    printf 'signed dmg bytes\n' > "$root/Maru-1.2.3-universal.dmg"
}

make_inputs "$tmp/success"
sh "$publisher" \
    "$tmp/success/Maru.app" \
    "$tmp/success/Maru-1.2.3-universal.dmg" \
    1.2.3 \
    "$tmp/success/out"
candidate="$tmp/success/out/session-host-candidate-1.2.3"
test -d "$candidate/Maru.app"
test -f "$candidate/Maru-1.2.3-universal.dmg"
test -f "$candidate/maru-session-host-1.2.3"
test -x "$candidate/maru-session-host-1.2.3"
cmp "$candidate/Maru.app/Contents/MacOS/maru-macos-app" "$candidate/maru-session-host-1.2.3"
test "$(find "$candidate" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" = 3

if sh "$publisher" "$tmp/success/Maru.app" "$tmp/success/Maru-1.2.3-universal.dmg" 1.2.3 "$tmp/success/out" >/dev/null 2>&1; then
    echo 'error: existing candidate was overwritten' >&2
    exit 1
fi

make_inputs "$tmp/symlink"
mkdir -p "$tmp/symlink/existing"
ln -s "$tmp/symlink/existing" "$tmp/symlink/out/session-host-candidate-1.2.3"
if sh "$publisher" "$tmp/symlink/Maru.app" "$tmp/symlink/Maru-1.2.3-universal.dmg" 1.2.3 "$tmp/symlink/out" >/dev/null 2>&1; then
    echo 'error: symlink candidate was followed' >&2
    exit 1
fi
test -L "$tmp/symlink/out/session-host-candidate-1.2.3"

make_inputs "$tmp/missing"
rm "$tmp/missing/Maru.app/Contents/MacOS/maru-macos-app"
if sh "$publisher" "$tmp/missing/Maru.app" "$tmp/missing/Maru-1.2.3-universal.dmg" 1.2.3 "$tmp/missing/out" >/dev/null 2>&1; then
    echo 'error: missing app executable was accepted' >&2
    exit 1
fi
test ! -e "$tmp/missing/out/session-host-candidate-1.2.3"

make_inputs "$tmp/copy-failure"
chmod 000 "$tmp/copy-failure/Maru-1.2.3-universal.dmg"
if sh "$publisher" "$tmp/copy-failure/Maru.app" "$tmp/copy-failure/Maru-1.2.3-universal.dmg" 1.2.3 "$tmp/copy-failure/out" >/dev/null 2>&1; then
    echo 'error: unreadable dmg was copied' >&2
    exit 1
fi
chmod 600 "$tmp/copy-failure/Maru-1.2.3-universal.dmg"
test ! -e "$tmp/copy-failure/out/session-host-candidate-1.2.3"

make_inputs "$tmp/version"
if sh "$publisher" "$tmp/version/Maru.app" "$tmp/version/Maru-1.2.3-universal.dmg" '../escape' "$tmp/version/out" >/dev/null 2>&1; then
    echo 'error: unsafe version was accepted' >&2
    exit 1
fi
test "$(find "$tmp/version/out" -mindepth 1 | wc -l | tr -d ' ')" = 0

build_script="$repo_root/tools/build-macos-universal-dmg.sh"
app_staple=$(grep -n 'xcrun stapler validate "$app"' "$build_script" | cut -d: -f1)
dmg_verify=$(grep -n 'spctl -a -t open --context context:primary-signature -v "$out"' "$build_script" | cut -d: -f1)
preserve=$(grep -n 'candidate_staged=$(sh tools/publish-macos-release-candidate.sh' "$build_script" | cut -d: -f1)
final_move=$(grep -n 'mv "$candidate_staged" "$candidate"' "$build_script" | cut -d: -f1)
test "$app_staple" -lt "$preserve"
test "$dmg_verify" -lt "$preserve"
test "$preserve" -lt "$final_move"
test "$(grep -F -c 'codesign --verify --strict --deep "$candidate_staged/Maru.app"' "$build_script")" = 1
test "$(grep -F -c 'xcrun stapler validate "$candidate_staged/Maru.app"' "$build_script")" = 1
test "$(grep -F -c 'xcrun stapler validate "$candidate_staged/Maru-$version-universal.dmg"' "$build_script")" = 1
# 떼어낸 main executable 에는 codesign 검증을 걸 수 없다 — 번들 밖에서는 `invalid resource directory` 로
# 반드시 실패하므로 릴리스가 통째로 막힌다. 사본의 무결성은 번들 서명 검증과 아래 `cmp` 가 이미 보장한다.
test "$(grep -F -c 'codesign --verify --strict "$candidate_staged/maru-session-host-' "$build_script")" = 0

echo 'macOS release candidate artifact contract: OK'
