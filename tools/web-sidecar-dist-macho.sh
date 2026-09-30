#!/bin/sh
# W7b: `maru-chromium` 설치물(`zig build web-sidecar-dist`)의 Mach-O 를 Homebrew 가 **고칠 것이 없는** 모양으로 맞추고
# 확인한다(docs/plans/web-osr-backend.md W7 행 「W7b」).
#
# 왜: Homebrew 는 소스 설치 뒤 `fix_dynamic_linkage` 로 keg 안 모든 dylib 의 ID 를 `opt/<formula>/…` 절대 경로로 고쳐
# 쓰고(빌드 디렉터리 rpath 는 지우고, 이름만 쓴 링크는 `@loader_path/…` 로 바꾸고), 파일을 다 고친 **뒤에** 한꺼번에
# 재서명한다. CEF 의 `libcef_sandbox.dylib`·`libvulkan.dylib` 는 Mach-O 머리 여유가 32·48 바이트뿐이라 고쳐 쓰다
# 실패하고, 그 전에 고친 프레임워크 본체는 서명이 깨진 채 남아 엔진이 뜨자마자 죽는다(9 차 적대 검증 실측). 그래서
# 설치물을 만들 때 ID 를 `@rpath/…` 로 바꿔 두고(formula 는 `preserve_rpath` 로 이 ID 를 그대로 둔다) 재서명한 뒤,
# 설치물 안 **모든** Mach-O 가 Homebrew 가 고칠 것 없는 모양인지 확인한다. host·helper 는 프레임워크와 dylib 을 경로로
# `dlopen` 하므로 ID 가 무엇이든 불러오기는 같다(실측 — 판정자 92/92).
#
# 사용: tools/web-sidecar-dist-macho.sh <설치물 디렉터리>
set -eu
dist=$1
fw_name="Chromium Embedded Framework.framework"
fw="$dist/$fw_name"
fw_bin="$fw/Chromium Embedded Framework"
die() {
    echo "web-sidecar-dist-macho: $*" >&2
    exit 1
}
test -f "$fw_bin" || die "$fw_bin 이 없다"
set -- "$fw"/Libraries/*.dylib
test -f "$1" || die "$fw/Libraries 에 dylib 이 없다"

# ① ID 를 @rpath 로 — dylib 은 이름만, 프레임워크 본체는 번들 안 경로로(표준 프레임워크 ID 모양).
for lib in "$fw"/Libraries/*.dylib; do
    install_name_tool -id "@rpath/$(basename "$lib")" "$lib" || die "install_name_tool -id 실패: $lib(머리 여유가 모자라나)"
done
install_name_tool -id "@rpath/$fw_name/Chromium Embedded Framework" "$fw_bin" || die "install_name_tool -id 실패: $fw_bin"

# ② 서명 — host·helper 는 서명이 없으면 붙인다(zig 링커는 arm64 대상에만 ad-hoc 서명을 붙인다 — x86_64 로 만든 것은
#    서명이 아예 없어 W7a2 가 거절하고 Intel 설치가 막혔다, W7b 2 차 적대 검증 실측). **서명이 없을 때만** 붙인다 —
#    깨진 서명을 다시 붙이면 바꿔치기된 파일을 온전하다고 만들어 버린다(깨진 것은 아래 확인에서 걸린다).
#    CEF 는 안쪽(dylib)을 먼저, 프레임워크를 마지막에(번들 서명이 안쪽 파일을 봉인하므로 순서가 바뀌면 봉인이 깨진다).
for exe in "$dist/maru-web-host" "$dist/maru-web-helper"; do
    if ! codesign --display "$exe" > /dev/null 2>&1; then
        codesign --sign - "$exe" 2>/dev/null || die "codesign 실패: $exe"
    fi
done
for lib in "$fw"/Libraries/*.dylib; do
    codesign --force --sign - "$lib" 2>/dev/null || die "codesign 실패: $lib"
done
codesign --force --sign - "$fw_bin" 2>/dev/null || die "codesign 실패: $fw_bin"

# ③ 확인 — 설치물 안 모든 Mach-O 를 본다(어긋나면 빌드 실패 — 망가진 설치물이 formula 로 조용히 나가지 않게).
fail=0
problem() {
    echo "web-sidecar-dist-macho: $*" >&2
    fail=1
}
list=$(mktemp "${TMPDIR:-/tmp}/maru-distmacho-list.XXXXXX")
trap 'rm -f "$list"' EXIT
find "$dist" -type f -print0 | xargs -0 file -N -F '|' | grep '| *Mach-O' | cut -d'|' -f1 > "$list"
while IFS= read -r f; do
    id=$(otool -D "$f" | sed -n 2p)
    # dylib 은 ID 가 @rpath 여야 한다(Homebrew 는 그 밖의 ID 를 opt 절대 경로로 고친다).
    if otool -hv "$f" | grep -q ' DYLIB '; then # 파일 종류 이름으로(열 위치에 기대지 않게)
        case "$id" in
            @rpath/*) ;;
            *) problem "$f 의 ID 가 @rpath 가 아니다($id)" ;;
        esac
    fi
    # rpath 는 없어야 한다 — 설치물은 모두 경로로 dlopen 해 rpath 가 필요 없다(실측: 여섯 Mach-O 모두 0 개). Homebrew 는
    # 절대 경로 rpath 를 지우고, `@loader_path`·`@executable_path` 를 풀어 **같은 곳을 가리키는** rpath 도 지운다
    # (`@loader_path/../lib` 와 `@loader_path/../lib/`) — 지우면 그 파일이 고쳐져 번들 봉인이 깨진다(W7b 3 차 적대 검증 실측).
    if otool -l "$f" | grep -q 'cmd LC_RPATH'; then problem "$f 에 rpath 가 있다(설치물은 rpath 없이 경로로 불러온다)"; fi
    # 링크는 자기 ID 말고 모두 @·/System/·/usr/lib/ 여야 한다(이름만 쓴 링크는 Homebrew 가 @loader_path 로 고친다).
    # 탭으로 시작하는 줄만 — universal 이면 아키텍처마다 `경로 (architecture …):` 머리 줄이 끼어든다.
    otool -L "$f" | awk -F'\t' '/^\t/{sub(/ \(compatibility.*/, "", $2); print $2}' | while IFS= read -r dep; do
        [ "$dep" = "$id" ] && continue
        case "$dep" in
            @* | /System/* | /usr/lib/*) ;;
            *) echo "web-sidecar-dist-macho: $f 가 시스템 밖 경로 라이브러리 $dep 에 링크한다" >&2; exit 1 ;;
        esac
    done || fail=1
    # 서명 — W7a2 가 띄우기 전에 보는 host·helper 와, 재서명한 프레임워크·dylib 모두 strict 로 온전해야 한다.
    codesign --verify --strict "$f" 2>/dev/null || problem "$f 의 서명이 온전하지 않다"
done < "$list"
exit $fail
