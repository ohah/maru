#!/bin/sh
# build.zig.zon 의 의존성을 **저장소 사본**(vendor/zig-packages)에서 Zig 전역 패키지 캐시로 채운다.
#
# 왜: CI 가 의존성 tarball 을 GitHub·crates.io 에서 받다가 연결이 끊기면(`invalid HTTP response:
# HttpConnectionClosing`) 그 잡이 통째로 빨갰다 — 테스트와 무관한 실패가 「cross-UID 스모크 실패」처럼 보였다
# (2026-09-29). Zig 0.16 은 `<global_cache>/p/<hash>.tar.gz` 가 있으면 내려받지 않고 거기서 풀므로, 첫 빌드
# 전에 여기서 채우면 **외부 다운로드가 0** 이다(네트워크를 막은 sandbox 에서 빈 캐시는 실패, 채운 캐시는 20개
# 모두 성공 — 2026-10-01 실측). 내용은 Zig 가 해시로 검증한다 — 사본이 바뀌면 빌드가 실패한다.
#
# **사본이 빠지거나 남으면 실패한다.** 빠진 채로 두면 Zig 가 조용히 네트워크로 받아 이 장치가 무의미해지고,
# 남은 것은 저장소 크기만 먹는다. 의존성을 바꿨다면: sh tools/ci/vendor-zig-packages.sh
#
# `--check` 는 대조만 하고 캐시는 건드리지 않는다.
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd -P)
vendor="$root/vendor/zig-packages"

hashes=$(sed -n 's/.*\.hash = "\([^"]*\)".*/\1/p' "$root/build.zig.zon" | sort -u)
if [ -z "$hashes" ]; then
    echo "prime-zig-packages: build.zig.zon 에서 의존성 해시를 못 읽었다" >&2
    exit 1
fi

bad=0
for h in $hashes; do
    if [ ! -f "$vendor/$h.tar.gz" ]; then
        echo "prime-zig-packages: 저장소 사본 없음 — vendor/zig-packages/$h.tar.gz" >&2
        bad=1
    fi
done
for f in "$vendor"/*.tar.gz; do
    [ -e "$f" ] || continue
    h=$(basename "$f" .tar.gz)
    if ! printf '%s\n' "$hashes" | grep -qxF "$h"; then
        echo "prime-zig-packages: build.zig.zon 에 없는 사본 — vendor/zig-packages/$h.tar.gz" >&2
        bad=1
    fi
done
if [ "$bad" -ne 0 ]; then
    echo "prime-zig-packages: 고치기 — sh tools/ci/vendor-zig-packages.sh" >&2
    exit 1
fi

count=$(printf '%s\n' "$hashes" | wc -l | tr -d ' ')
if [ "${1:-}" = "--check" ]; then
    echo "prime-zig-packages: $count 개 사본이 build.zig.zon 과 일치한다"
    exit 0
fi

cache=$(zig env | sed -n 's/^ *\.global_cache_dir = "\(.*\)",$/\1/p')
if [ -z "$cache" ]; then
    echo "prime-zig-packages: zig env 에서 global_cache_dir 를 못 읽었다" >&2
    exit 1
fi
mkdir -p "$cache/p"
for h in $hashes; do
    cp "$vendor/$h.tar.gz" "$cache/p/$h.tar.gz"
done
echo "prime-zig-packages: $count 개를 $cache/p 에 채웠다"
