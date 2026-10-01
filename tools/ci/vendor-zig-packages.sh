#!/bin/sh
# 의존성(build.zig.zon)을 바꾼 뒤 저장소 사본(vendor/zig-packages)을 맞춘다.
#
# `zig build --fetch` 로 전역 패키지 캐시를 채우고, build.zig.zon 이 가리키는 tarball 만 사본으로 복사하고,
# 더는 안 쓰는 사본은 지운다. CI 는 `prime-zig-packages.sh` 로 이 사본만 써서 외부 다운로드 없이 빌드한다.
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd -P)
cd "$root"
vendor=vendor/zig-packages

zig build --fetch
cache=$(zig env | sed -n 's/^ *\.global_cache_dir = "\(.*\)",$/\1/p')
hashes=$(sed -n 's/.*\.hash = "\([^"]*\)".*/\1/p' build.zig.zon | sort -u)
mkdir -p "$vendor"
for h in $hashes; do
    if [ ! -f "$cache/p/$h.tar.gz" ]; then
        # 프로젝트의 zig-pkg/ 에 이미 풀려 있으면 Zig 는 전역 캐시에 tarball 을 다시 안 받는다.
        echo "vendor-zig-packages: 전역 캐시에 $h.tar.gz 가 없다 — zig-pkg/$h 를 지우고 다시 돌린다" >&2
        exit 1
    fi
    cp "$cache/p/$h.tar.gz" "$vendor/$h.tar.gz"
done
for f in "$vendor"/*.tar.gz; do
    [ -e "$f" ] || continue
    h=$(basename "$f" .tar.gz)
    printf '%s\n' "$hashes" | grep -qxF "$h" || rm -f "$f"
done
sh tools/ci/prime-zig-packages.sh --check
