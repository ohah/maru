#!/bin/sh
# `.mise.toml` 의 `check` 와 `check-without-boundaries` 가 **같은 집합**을 가리키는지 고정한다 —
# 정확히는 `check` = `check-without-boundaries` + `check-boundaries`.
#
# 왜 필요한가: CI 의 `check` 잡은 `check-without-boundaries` 를, 별도 잡이 `check-boundaries` 를 돈다.
# 로컬 `mise run check` 는 둘을 합친 원래 목록이다. 누가 `check` 에 게이트를 하나 더하고 CI 쪽 목록을
# 잊으면, 그 게이트는 로컬에서만 돌고 **CI 에서는 조용히 빠진다** — 초록인데 검증이 안 된 상태다.
# 반대로 `check-without-boundaries` 에 `check-boundaries` 가 섞이면 분리의 뜻이 사라진다(두 러너가 같은
# 덩어리를 두 번 돈다).
#
# 실행: sh tools/ci/check-task-split.sh [mise.toml 경로]
set -eu
toml="${1:-$(cd "$(dirname "$0")/../.." && pwd)/.mise.toml}"

# `[tasks.<name>]` 헤더 뒤 첫 `depends = [...]` 줄의 항목을 한 줄에 하나씩, 정렬해서 낸다.
depends_of() {
	awk -v want="[tasks.$1]" '
		$0 == want { in_block = 1; next }
		in_block && /^\[/ { exit }
		in_block && /^depends[ \t]*=/ {
			line = $0
			while (match(line, /"[^"]+"/)) {
				print substr(line, RSTART + 1, RLENGTH - 2)
				line = substr(line, RSTART + RLENGTH)
			}
			exit
		}
	' "$toml" | sort
}

full=$(depends_of check)
split=$(depends_of check-without-boundaries)
[ -n "$full" ] || { echo "check-task-split: [tasks.check] 의 depends 를 못 읽었다 ($toml)" >&2; exit 1; }
[ -n "$split" ] || { echo "check-task-split: [tasks.check-without-boundaries] 의 depends 를 못 읽었다 ($toml)" >&2; exit 1; }

if printf '%s\n' "$split" | grep -qx 'check-boundaries'; then
	echo "check-task-split: check-without-boundaries 에 check-boundaries 가 들어 있다 — 분리의 뜻이 없다" >&2
	exit 1
fi
expected=$(printf '%s\ncheck-boundaries\n' "$split" | sort)
if [ "$full" != "$expected" ]; then
	# POSIX sh 다 — `<(...)` 는 bash 전용이라 여기서 쓰면 문법 오류로 죽는다(자기검증이 잡았다).
	work=$(mktemp -d)
	printf '%s\n' "$full" >"$work/full"
	printf '%s\n' "$expected" >"$work/expected"
	echo "check-task-split: check ≠ check-without-boundaries + check-boundaries" >&2
	echo "--- check 에만 있는 것 (CI 가 조용히 빠뜨린다):" >&2
	comm -23 "$work/full" "$work/expected" >&2
	echo "--- check-without-boundaries 에만 있는 것:" >&2
	comm -13 "$work/full" "$work/expected" >&2
	rm -rf "$work"
	exit 1
fi
echo "check-task-split: OK — check = check-without-boundaries + check-boundaries ($(printf '%s\n' "$full" | wc -l | tr -d ' ') 개)"
