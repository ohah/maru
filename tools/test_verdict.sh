#!/bin/sh
# `zig build test` 로그에서 **실패 신호를 빠짐없이** 뽑는다.
#
# 왜 있나: `grep FAIL`로만 판정하다가 **세그폴트가 두 라운드를 통과했다**(2026-08-23,
# 편집기 ⌘F 슬라이스). Zig 테스트 러너는 크래시를 `FAIL`로 안 찍는다 —
# `Segmentation fault`로 찍고, 그때 로그에는 `FAIL`도 `N passed;` 요약줄도 **없다**.
# 그래서 "실패 없음"으로 읽혔고, 그동안 CI는 그 크래시로 빨간 상태였다.
#
# 쓰는 법:  zig build test > /tmp/t.log 2>&1;  sh tools/test_verdict.sh /tmp/t.log
#
# **이것으로 통과를 증명하지는 못한다.** 진행 번호가 총계에 닿는 것(`N/N`)은 *완주*를 뜻할 뿐
# 통과가 아니다 — 실패한 테스트도 번호를 올린다. 정식 게이트는 `mise run check`(CI와 같은 12개)다.
set -u
LOG="${1:?usage: test_verdict.sh <build-test-log>}"

echo "=== 실패 신호 ==="
grep -nE "FAIL|Segmentation fault|Bus error|panic:|Abort trap|signal (SIG)?(SEGV|ABRT|BUS|ILL)|error: process exited|terminated with signal|leaked|error: 'test\." "$LOG" \
  | grep -v '\.\.\.OK$' || echo "(없음)"

echo
echo "=== 러너 요약(있으면) ==="
grep -nE "^[0-9]+ passed; [0-9]+ skipped; [0-9]+ failed" "$LOG" || echo "(요약줄 없음 — 러너가 중간에 죽었을 수 있다)"

echo
echo "=== Build Summary ==="
grep -n "Build Summary" -A 6 "$LOG" || echo "(없음 — 빌드가 요약 전에 끝났다)"

echo
echo "=== 완주 여부(진행 번호가 총계에 닿았나) ==="
grep -oE "^[0-9]+/[0-9]+ " "$LOG" | tr -d ' ' | awk -F/ '
  { if ($1 + 0 > seen[$2] + 0) seen[$2] = $1 }
  END {
    for (t in seen)
      printf "  %s/%s%s\n", seen[t], t, (seen[t] + 0 == t + 0 ? "" : "   <-- 총계에 못 닿았다(중간에 죽었다)")
  }' | sort -t/ -k2 -n
