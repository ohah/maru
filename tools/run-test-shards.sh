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

# 끝나고 **묵은 테스트 픽스처를 거둔다** — 일은 `tools/clean-tmp-fixtures.sh` 가 한다.
#
# ⚠️ **로직을 여기 다시 쓰지 않는다.** 그 도구가 이미 있고 더 정교하다(적대적 3회차에 그것을 모르고
# 중복 구현했다가 되돌렸다):
#   · `maru-<숫자>` 는 **실 세션 host 루트**(uid)라 절대 안 건드린다 — 지우면 사용자의 살아 있는
#     keep-alive 세션이 통째로 사라진다.
#   · 이름 끝 pid 가 **살아 있으면 남긴다**(`kill -0`) — 지금 돌고 있는 테스트의 자리일 수 있다.
#   · pid 를 **앞에서부터** 찾는다 — 뒤에서 찾으면 `maru-cr6a2-launch-86495-0` 의 `0` 을 pid 로 읽고
#     `kill -0 0` 은 프로세스 그룹 질의라 언제나 성공해 그 자리가 영영 안 지워진다.
#
# 여기서 하는 일은 **부르는 것**뿐이다. 그 도구는 「개발 머신용」으로 만들어졌는데 아무도 안 불러
# 실측 2026-09-10 에 **32,762 개 · 47.4 GB** 가 쌓여 있었다 — 자동 호출이 빠진 조각이었다.
sweep_stale_fixtures() {
    cleaner=$(dirname "$0")/clean-tmp-fixtures.sh
    if [ -f "$cleaner" ]; then
        # 청소는 곁일이다 — 실패해도 테스트를 막지 않는다.
        sh "$cleaner" >&2 2>&1 || :
    else
        # ⚠️ **조용히 넘어가지 않는다.** 못 찾은 채로 지나가면 「돌았는데 아무것도 없었다」와
        # 「아예 안 돌았다」가 구분되지 않는다.
        echo "run-test-shards: clean-tmp-fixtures.sh 를 못 찾아 픽스처를 안 거뒀다 ($cleaner)" >&2
    fi
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
