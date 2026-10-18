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
expand_hashes() {
    archive_dir=$1
    pending=$(sed -n 's/.*\.hash = "\([^"]*\)".*/\1/p' build.zig.zon | sort -u)
    expanded=$pending
    while [ -n "$pending" ]; do
        hash=$(printf '%s\n' "$pending" | sed -n '1p')
        pending=$(printf '%s\n' "$pending" | sed -n '2,$p')
        archive="$archive_dir/$hash.tar.gz"
        [ -f "$archive" ] || continue
        manifest_member=$(tar -tzf "$archive" | sed -n -e '/^build\.zig\.zon$/p' -e '/\/build\.zig\.zon$/p' | sed -n '1p')
        [ -n "$manifest_member" ] || continue
        nested_hashes=$(tar -xOzf "$archive" "$manifest_member" | sed -n 's/.*\.hash = "\([^"]*\)".*/\1/p' | sort -u)
        for nested_hash in $nested_hashes; do
            case " $expanded " in
                *" $nested_hash "*) ;;
                *)
                    expanded="$expanded $nested_hash"
                    pending="$pending $nested_hash"
                    ;;
            esac
        done
    done
    printf '%s\n' "$expanded" | tr ' ' '\n' | sed '/^$/d' | sort -u
}

hashes=$(expand_hashes "$cache/p")
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

pcre2_archive=vendor/third-party/pcre2-10.48.tar.gz
pcre2_url=https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.48/pcre2-10.48.tar.gz
pcre2_expected_sha=$(cat vendor/third-party/pcre2-10.48.sha256)
pcre2_tmp="$pcre2_archive.tmp"
rm -f "$pcre2_tmp"
curl --fail --location --silent --show-error "$pcre2_url" --output "$pcre2_tmp"
if command -v sha256sum >/dev/null 2>&1; then
    pcre2_actual_sha=$(sha256sum "$pcre2_tmp" | awk '{print $1}')
else
    pcre2_actual_sha=$(shasum -a 256 "$pcre2_tmp" | awk '{print $1}')
fi
if [ "$pcre2_actual_sha" != "$pcre2_expected_sha" ]; then
    rm -f "$pcre2_tmp"
    echo "vendor-zig-packages: PCRE2 release archive SHA-256 불일치" >&2
    exit 1
fi
mv "$pcre2_tmp" "$pcre2_archive"

sh tools/ci/prime-zig-packages.sh --check
