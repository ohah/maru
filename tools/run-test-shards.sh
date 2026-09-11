#!/bin/sh
# 같은 테스트 바이너리를 MARU_TEST_SHARD=i/n 으로 n 개 프로세스에 나눠 **동시에** 돌린다.
#
# 왜 스크립트인가: Zig 0.16 빌드 러너는 stdio 를 물려받는 run 스텝(출력 인자가 없는 test 실행이 그렇다)을 돌리는
# 동안 stderr 잠금(`Io.lockStderr`, 진짜 mutex)을 자식이 끝날 때까지 쥔다 — `std/Build/Step/Run.zig`
# `spawnChildAndCollect`. 그래서 run 스텝을 n 개 만들어도 **전역 직렬**이다(실측 2026-09-06, PR #3302: CI 에서
# 샤드 넷이 80초 간격으로 차례로 끝났다). 병렬은 run 스텝 하나 안에서 해야 한다.
#
# 출력: 각 샤드의 줄 앞에 `[shard i/n] ` 를 붙여 stderr 로 흘린다(살아 있는 진행이 보이고, 멈춘 샤드가 드러난다).
# 종료: 샤드 하나라도 0 이 아니면 1. 러너의 가드(빈 샤드·필터 오타)는 그대로 샤드 종료 코드로 올라온다.
#
# ⚠️ **끝나고 묵은 픽스처를 쓸어 낸다**(아래 `sweep_stale_fixtures`). 테스트 216 곳이
# `/tmp/maru-<태그>-<pid>` 를 만드는데 `deleteTree` 로 치우는 곳은 **18 곳**뿐이라, 나머지가
# 그대로 쌓인다 — 실측 2026-09-10 에 **32,762 개 · 47.4 GB** 였다. pid 는 돌고 도므로 남은
# 디렉터리가 다음 실행과 **이름이 겹쳐** 간헐 실패까지 만든다(`/tmp` 픽스처 오염).
#
# 각 자리에서 치우게 고치는 것이 옳지만 216 곳이고, 그중 다수는 **자식 프로세스가 죽는 경로**라
# `defer` 가 안 돈다. 그래서 「만든 자리가 치운다」 대신 **러너가 한 번 쓸어 낸다** — 도는 것을
# 안 건드리도록 **하루 넘은 것만** 지운다.
#
# usage: run-test-shards.sh <n> <test-binary> [args...]
set -u

# 하루 넘은 `/tmp/maru-*` **테스트 픽스처**를 지운다. 실패해도 테스트를 막지 않는다(청소는 곁일이다).
#
# 🔥 **`/tmp/maru-<uid>` 는 건드리면 안 된다.** 그것은 테스트 픽스처가 아니라 **제품**의 session
# host 소켓 뿌리다(`short_endpoint.zig` — 그 아래 `sh/<host>.sock` 과 `session-host/` 가 산다).
# host 가 하루 넘게 조용하면 디렉터리 mtime 이 안 바뀌므로, 이름으로 안 가르면 **살아 있는
# 소켓을 지우고** keep-alive 터미널이 재접속을 잃는다(적대적 1회차에 잡았다 — 실측으로 그때
# `/private/tmp/maru-501` 아래에 `sh/` 39 개 · `session-host/` 52 개가 있었다).
#
# 가르는 법: **`maru-` 뒤가 숫자뿐이면 제품**(uid)이고, 그 밖은 테스트 픽스처다
# (`maru-<태그>-<pid>` · `maru-t<pid>`).
sweep_stale_fixtures() {
    # `/tmp` 는 macOS 에서 `/private/tmp` 로의 심볼릭 링크라 `find` 가 안 따라간다.
    root=/tmp
    [ -d /private/tmp ] && root=/private/tmp
    find "$root" -maxdepth 1 -name 'maru-*' -mtime +1 2>/dev/null | while IFS= read -r d; do
        case "${d##*/maru-}" in
            *[!0-9]*) rm -rf "$d" ;;
        esac
    done
    :
}
n=$1
bin=$2
shift 2
case "$n" in
    ''|*[!0-9]*|0) echo "run-test-shards: n must be a positive integer, got '$n'" >&2; exit 2 ;;
esac
tmp=$(mktemp -d "${TMPDIR:-/tmp}/maru-test-shards.XXXXXX") || exit 2
trap 'rm -rf "$tmp"' EXIT
i=0
while [ "$i" -lt "$n" ]; do
    (
        MARU_TEST_SHARD="$i/$n" "$bin" "$@" 2>&1
        echo "$?" > "$tmp/rc.$i"
    ) | while IFS= read -r line; do
        printf '[shard %s/%s] %s\n' "$i" "$n" "$line"
    done >&2 &
    i=$((i + 1))
done
wait
sweep_stale_fixtures
rc=0
i=0
while [ "$i" -lt "$n" ]; do
    r=$(cat "$tmp/rc.$i" 2>/dev/null || echo 127)
    if [ "$r" -ne 0 ]; then
        echo "run-test-shards: shard $i/$n exited with $r" >&2
        rc=1
    fi
    i=$((i + 1))
done
exit "$rc"
