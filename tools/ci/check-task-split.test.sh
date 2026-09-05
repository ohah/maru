#!/bin/sh
# check-task-split.sh 가 **실제로 어긋남을 잡는지** 고정한다. 판정자가 항상 초록이면 없는 것과 같다 —
# 이 저장소가 「이름만 걸려 공허하게 통과」를 여러 번 겪었으므로, 어긋난 fixture 를 넣어 빨간지 본다.
#
# 실행: sh tools/ci/check-task-split.test.sh
set -eu
script=$(cd "$(dirname "$0")" && pwd)/check-task-split.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
fixture() {
	printf '[tasks.check]\ndepends = [%s]\n\n[tasks.check-without-boundaries]\ndepends = [%s]\n' "$1" "$2" >"$work/mise.toml"
}
expect() {
	want=$1; name=$2
	if sh "$script" "$work/mise.toml" >/dev/null 2>&1; then got=pass; else got=fail; fi
	if [ "$got" = "$want" ]; then echo "  ok   $name ($got)"; else echo "  FAIL $name — 기대 $want, 실제 $got"; failures=$((failures + 1)); fi
}
fixture '"a", "check-boundaries", "b"' '"b", "a"';                      expect pass "같은 집합(순서 무관)"
fixture '"a", "check-boundaries", "b", "c"' '"b", "a"';                 expect fail "check 에만 있는 게이트(CI 가 빠뜨림)"
fixture '"a", "check-boundaries"' '"a", "b"';                            expect fail "split 에만 있는 게이트"
fixture '"a", "check-boundaries"' '"a", "check-boundaries"';             expect fail "split 에 check-boundaries 가 섞임"
fixture '"a", "b"' '"a", "b"';                                           expect fail "check 에 check-boundaries 가 없음"
[ "$failures" -eq 0 ] || { echo "check-task-split.test: $failures 건 실패" >&2; exit 1; }
echo "check-task-split.test: 5/5"
