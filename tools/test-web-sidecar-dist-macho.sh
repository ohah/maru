#!/bin/sh
# `tools/web-sidecar-dist-macho.sh` 자체 시험(W7b) — 그 스크립트는 CEF SDK 가 있어야 도는 `web-sidecar-dist` 안에서만
# 돌아, 결함이 formula 설치에서야 드러난다. 가짜 설치물(작은 dylib 과 `/usr/bin/true` 사본)로 열한 경우를 본다.
# `zig build test-web-sidecar-dist-macho`(macOS CI 의 `test-macos-only`)가 부른다.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
fix="$here/tools/web-sidecar-dist-macho.sh"
root=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/maru-distmacho.XXXXXX")" && pwd -P)
trap 'rm -rf "$root"' EXIT

printf 'int maru_dist_macho_probe(void) { return 7; }\n' > "$root/probe.c"

# $1=디렉터리 — 설치물 모양: host·helper, 프레임워크 본체와 Libraries/ 의 dylib 둘. ID 는 CEF 배포본처럼 `./`·`@executable_path`.
make_dist() {
    d=$1
    fw="$d/Chromium Embedded Framework.framework"
    mkdir -p "$fw/Libraries" "$fw/Resources"
    # 실제 CEF 처럼 번들로 서명되게 Info.plist 를 둔다 — 없으면 봉인이 없어 재서명 순서 실수를 못 본다(W7b 적대 검증 1 차).
    cat > "$fw/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Chromium Embedded Framework</string>
<key>CFBundleIdentifier</key><string>dev.maru.distmacho-probe</string>
<key>CFBundlePackageType</key><string>FMWK</string>
</dict></plist>
PLIST
    cp /usr/bin/true "$d/maru-web-host"
    cp /usr/bin/true "$d/maru-web-helper"
    cc -dynamiclib -o "$fw/Chromium Embedded Framework" "$root/probe.c" \
        -install_name "@executable_path/../Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework"
    cc -dynamiclib -o "$fw/Libraries/libcef_sandbox.dylib" "$root/probe.c" -install_name ./libcef_sandbox.dylib
    cc -dynamiclib -o "$fw/Libraries/libvulkan.dylib" "$root/probe.c" -install_name ./libvulkan.dylib
    # x86_64 CEF 의 dylib 은 서명이 없다 — 그 모양으로 두어야 dylib 재서명을 빠뜨린 것이 드러난다(arm64 에서는
    # install_name_tool 이 linker-signed 서명을 스스로 다시 붙여 가려진다).
    codesign --remove-signature "$fw/Libraries/libcef_sandbox.dylib" "$fw/Libraries/libvulkan.dylib"
}

failures=0
expect() { # $1=pass|fail $2=이름 $3=디렉터리 [$4=실패 사유에 있어야 할 문구 — 다른 이유로 실패한 것을 통과로 치지 않게]
    if sh "$fix" "$3" > "$root/out.txt" 2>&1; then got=pass; else got=fail; fi
    if [ "$got" = "$1" ] && { [ -z "${4:-}" ] || grep -q "$4" "$root/out.txt"; }; then
        echo "PASS $2 ($got)"
    else
        echo "FAIL $2 — $1 이어야 하는데 $got" >&2
        cat "$root/out.txt" >&2
        failures=$((failures + 1))
    fi
}

# ① 배포본 모양 — ID 가 @rpath 로 바뀌고 재서명돼 통과한다.
make_dist "$root/good"
expect pass "CEF 배포본 모양의 ID 를 @rpath 로 바꾸고 재서명" "$root/good"
fw="$root/good/Chromium Embedded Framework.framework"
for pair in "Libraries/libcef_sandbox.dylib:@rpath/libcef_sandbox.dylib" \
    "Chromium Embedded Framework:@rpath/Chromium Embedded Framework.framework/Chromium Embedded Framework"; do
    file=${pair%%:*}
    want=${pair#*:}
    got=$(otool -D "$fw/$file" | sed -n 2p)
    if [ "$got" != "$want" ]; then
        echo "FAIL $file 의 ID 가 $got — $want 여야 한다" >&2
        failures=$((failures + 1))
    fi
    codesign --verify --strict "$fw/$file" || { echo "FAIL $file 서명" >&2; failures=$((failures + 1)); }
done

# ② Libraries 밖에 @rpath 가 아닌 dylib 이 새로 생겼다 — 고치지 않는 자리이니 잡아야 한다.
make_dist "$root/stray"
cc -dynamiclib -o "$root/stray/Chromium Embedded Framework.framework/Resources/libextra.dylib" "$root/probe.c" -install_name ./libextra.dylib
expect fail "Libraries 밖의 @rpath 아닌 dylib" "$root/stray" "libextra.dylib 의 ID 가 @rpath 가 아니다"

# ③ host 에 설치 경로 rpath 가 붙었다 — Homebrew 가 고쳐 쓰다 서명을 깬다.
make_dist "$root/rpath"
cc -o "$root/rpath/maru-web-host" "$root/probe.c" -Wl,-undefined,dynamic_lookup -Wl,-rpath,/opt/homebrew/lib -e _maru_dist_macho_probe
expect fail "host 의 절대 경로 rpath" "$root/rpath" "maru-web-host 에 rpath 가 있다"

# ④ helper 가 시스템 밖 절대 경로 라이브러리에 링크한다.
make_dist "$root/link"
cc -dynamiclib -o "$root/libdep.dylib" "$root/probe.c" -install_name "$root/libdep.dylib"
cc -o "$root/link/maru-web-helper" "$root/probe.c" "$root/libdep.dylib" -Wl,-undefined,dynamic_lookup -e _maru_dist_macho_probe
expect fail "helper 의 시스템 밖 링크" "$root/link" "maru-web-helper 가 시스템 밖 경로 라이브러리"

# ⑤ host 의 코드가 바뀌어 서명이 깨졌다(바꿔치기 뒤 재서명 안 함) — zig 가 만든 것처럼 서명된 실행 파일의 __text 를
#    고친다(파일 끝에 덧붙이면 코드 해시가 아니라 파일 배치 검사에 걸려 다른 것을 시험하게 된다 — W7b 3 차 적대 검증).
make_dist "$root/broken"
cc -o "$root/broken/maru-web-host" "$root/probe.c" -Wl,-undefined,dynamic_lookup -e _maru_dist_macho_probe
codesign --force --sign - "$root/broken/maru-web-host" 2>/dev/null
text_off=$(otool -l "$root/broken/maru-web-host" | awk '/sectname __text/{t=1} t&&/^ *offset /{print $2; exit}')
printf '\000\000\000\000' | dd of="$root/broken/maru-web-host" bs=1 seek="$text_off" conv=notrunc 2>/dev/null
expect fail "host 서명 깨짐" "$root/broken" "maru-web-host 의 서명이 온전하지 않다"

# ⑥ dylib 에 빌드 디렉터리 절대 경로 rpath — Homebrew 가 지우며 그 dylib 을 다시 서명해 번들 봉인이 깨진다.
make_dist "$root/dylib-rpath"
cc -dynamiclib -o "$root/dylib-rpath/Chromium Embedded Framework.framework/Libraries/libvulkan.dylib" "$root/probe.c" \
    -install_name ./libvulkan.dylib -Wl,-rpath,/private/tmp/build/lib
expect fail "dylib 의 절대 경로 rpath" "$root/dylib-rpath" "libvulkan.dylib 에 rpath 가 있다"

# ⑦ dylib 이 이름만으로 다른 dylib 에 링크 — Homebrew 가 @loader_path 로 고친다.
make_dist "$root/bare-link"
fwb="$root/bare-link/Chromium Embedded Framework.framework/Libraries"
cc -dynamiclib -o "$fwb/libvulkan.dylib" "$root/probe.c" "$fwb/libcef_sandbox.dylib" -install_name ./libvulkan.dylib
install_name_tool -change ./libcef_sandbox.dylib libcef_sandbox.dylib "$fwb/libvulkan.dylib"
expect fail "dylib 의 이름만 쓴 링크" "$root/bare-link" "시스템 밖 경로 라이브러리 libcef_sandbox.dylib"

# ⑧ 프레임워크 안의 다른 실행 파일에 절대 경로 rpath — host·helper 만 보던 확인이 놓쳤다.
make_dist "$root/inner-exe"
mkdir -p "$root/inner-exe/Chromium Embedded Framework.framework/Helpers"
cc -o "$root/inner-exe/Chromium Embedded Framework.framework/Helpers/crash_handler" "$root/probe.c" \
    -Wl,-undefined,dynamic_lookup -Wl,-rpath,/opt/homebrew/lib -e _maru_dist_macho_probe
expect fail "프레임워크 안 실행 파일의 절대 경로 rpath" "$root/inner-exe" "crash_handler 에 rpath 가 있다"

# ⑨ host·helper 에 서명이 없다(x86_64 대상 zig 빌드) — 서명을 붙여 통과해야 한다.
make_dist "$root/unsigned"
codesign --remove-signature "$root/unsigned/maru-web-host" "$root/unsigned/maru-web-helper"
expect pass "서명 없는 host·helper 에 서명을 붙임" "$root/unsigned"
for exe in maru-web-host maru-web-helper; do
    codesign --verify --strict "$root/unsigned/$exe" || { echo "FAIL $exe 에 서명이 붙지 않았다" >&2; failures=$((failures + 1)); }
done

# ⑩ Mach-O 가 아닌 dylib·프레임워크(자리만 있는 텍스트) — ID 를 바꾸는 단계에서 멈춰야 한다(아무것도 확인하지 않고 통과하면 안 된다).
mkdir -p "$root/empty/Chromium Embedded Framework.framework/Libraries"
printf 'not mach-o\n' > "$root/empty/Chromium Embedded Framework.framework/Chromium Embedded Framework"
printf 'not mach-o\n' > "$root/empty/Chromium Embedded Framework.framework/Libraries/libx.dylib"
expect fail "Mach-O 없는 설치물" "$root/empty" "install_name_tool -id 실패"

# ⑪ @ 로 시작하지만 풀면 같은 곳을 가리키는 rpath 둘 — Homebrew 는 풀어서 겹치는 것을 지운다(`@` 만 보던 확인이 놓쳤다).
make_dist "$root/loader-rpath"
cc -dynamiclib -o "$root/loader-rpath/Chromium Embedded Framework.framework/Libraries/libvulkan.dylib" "$root/probe.c" \
    -install_name ./libvulkan.dylib -Wl,-rpath,@loader_path/../lib -Wl,-rpath,@loader_path/../lib/
expect fail "풀면 겹치는 @loader_path rpath" "$root/loader-rpath" "libvulkan.dylib 에 rpath 가 있다"

if [ "$failures" != 0 ]; then
    echo "web-sidecar-dist-macho 자체 시험: 틀림 $failures 건" >&2
    exit 1
fi
echo "web-sidecar-dist-macho 자체 시험: 열한 경우 모두 맞음"
