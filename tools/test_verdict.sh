#!/bin/sh
# `zig build test` 로그에서 **실패 신호를 빠짐없이** 뽑고, 하나라도 있으면 **0이 아닌 코드로 끝난다**.
#
# 왜 있나: `grep FAIL`로만 판정하다가 **세그폴트를 놓쳐 한 커밋이 그대로 밀렸다**(2026-08-23,
# 편집기 ⌘F 슬라이스). Zig 러너는 크래시를 `FAIL`로 안 찍는다 — `Segmentation fault`로 찍는다.
#
# **정확히 무엇이 없었는가**(초판이 이 문장을 실제보다 넓게 적었다 — 적대적 검증 2026-08-24가
# 정정): 로그 **전체**에는 `FAIL`도 요약줄도 있었다(다른 바이너리들이 완주해 각자 냈다).
# 없던 것은 **크래시한 그 바이너리 자신의** 요약줄이고, 그 바이너리는 진행 번호가 총계에
# 못 닿은 채 멈췄다(`463/3854`). 그래서 아래 "완주 여부" 절이 필요하다 — 실패 신호 절만으로는
# "다른 바이너리의 실패"와 "이 바이너리의 죽음"이 구별되지 않는다.
#
# 쓰는 법:  zig build test > /tmp/t.log 2>&1;  sh tools/test_verdict.sh /tmp/t.log
#           (실패 신호가 있으면 exit 1 — `&&`로 이어 붙여 게이트로 쓸 수 있다)
#
# **이것으로 통과를 증명하지는 못한다.** `N/N`은 *완주*일 뿐 통과가 아니다 — 실패한 테스트도
# 번호를 올린다. 정식 게이트는 `mise run check`(CI와 같은 12개)다.
set -u
LOG="${1:?usage: test_verdict.sh <build-test-log>}"

# `tools/simple_test_runner.zig`가 0이 아닌 코드로 끝나는 **모든** 경로를 덮는다(그 파일의
# `failed_count`·`leaked_count`·`logged_errors`·focused-selection 검사). 여기에 러너가 아예
# 말할 기회를 못 얻는 크래시 계열을 더한다.
# **컴파일 오류도 실패다.** 초판은 이것을 빠뜨려, 컴파일이 안 된 뮤턴트를 "(없음)"으로 읽었다 —
# *"안 도는 것을 초록으로 읽는"* 정확히 그 실패 모드다(적대적 검증 2026-08-24가 실측).
PATTERNS='FAIL|Segmentation fault|Bus error|panic:|Abort trap|signal (SIG)?(SEGV|ABRT|BUS|ILL|KILL)|error: process exited|terminated with signal|tests? leaked memory|errors were logged|focused test selection mismatch|error: while executing test|error: '"'"'test\.|^[^ ]*\.zig:[0-9]+:[0-9]+: error:|^error: '

echo "=== 실패 신호 ==="
if grep -nE "$PATTERNS" "$LOG" | grep -v '\.\.\.OK$' > /tmp/.tv_hits 2>/dev/null && [ -s /tmp/.tv_hits ]; then
  cat /tmp/.tv_hits
  HITS=1
else
  echo "(없음)"
  HITS=0
fi

echo
echo "=== 러너 요약 ==="
# 러너는 전원 통과면 `All N tests passed.`, 아니면 `N passed; M skipped; K failed.`를 낸다
# (`simple_test_runner.zig`). **둘 다 봐야 한다** — 초판은 뒤엣것만 봐서 완전히 초록인 로그에도
# "요약줄 없음"이라 경보했다.
grep -nE "^All [0-9]+ tests passed\.|^[0-9]+ passed; [0-9]+ skipped; [0-9]+ failed" "$LOG" \
  || echo "(요약줄이 하나도 없다 — 러너가 말할 기회를 못 얻었다)"

echo
echo "=== Build Summary ==="
grep -n "Build Summary" -A 6 "$LOG" || echo "(없음 — 빌드가 요약 전에 끝났다)"

echo
echo "=== 완주 여부 ==="
# **바이너리마다 따로 센다.** 진행 번호가 되감기면(N이 줄거나 총계가 바뀌면) 다른 바이너리다 —
# 총계를 키로 잡으면 **같은 총계의 다른 바이너리가 완주할 때 죽은 것을 가린다**(적대적 검증
# 2026-08-24가 합성 로그로 실증).
DEAD=$(grep -oE "^[0-9]+/[0-9]+ " "$LOG" | tr -d ' ' | awk -F/ '
  function flush() { if (tot != "") printf "  %s/%s%s\n", cur, tot, (cur + 0 == tot + 0 ? "" : "   <-- 총계에 못 닿았다(중간에 죽었다)") }
  { if ($2 != tot || $1 + 0 < cur + 0) { flush(); tot = $2 } ; cur = $1 }
  END { flush() }' | sort -u)
echo "$DEAD"
echo "$DEAD" | grep -q "못 닿았다" && HITS=1

rm -f /tmp/.tv_hits
exit "$HITS"
