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
# usage: run-test-shards.sh <n> <test-binary> [args...]
set -u
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
