#!/bin/sh
# 에이전트 플러그인(plugins/<이름>/)을 고친 PR 이 그 플러그인의 `version` 을 올렸는가를 본다.
#
# 왜 필요한가: Claude Code 는 플러그인 캐시를 `.claude-plugin/plugin.json` 의 `version` 문자열로 가른다. 글을 고치고
# 버전을 그대로 두면 사용자가 `/plugin marketplace update` 를 해도 **옛 판에 머문다**(공식 문서: "users stay on their
# cached copy until the string changes"). 머지된 뒤에야 드러나고, 그때는 이미 사용자에게 고친 스킬이 안 간다.
# 설계는 docs/control-plane-browser.md §9.6.3 이 단일 출처다.
#
# 판정: PR 범위(merge-base..head)에서 `plugins/<이름>/` 아래 파일이 하나라도 바뀌었으면, head 의 그 플러그인
# `version` 이 merge-base 의 것보다 **커야** 한다(같으면 실패, 내려가도 실패 — 내려간 문자열도 캐시를 갈지만
# 사용자의 「더 새 판」 판단을 거꾸로 만든다). merge-base 에 플러그인이 없으면(새 플러그인) 통과, head 에서 폴더째
# 지웠으면 통과. 그 밖에 판정할 수 없는 모든 경우(git 실패·JSON 아님·semver 아님)는 **실패**한다 — 못 보면 막는다.
#
# 사용법: sh tools/ci/plugin-version-bump.sh <base-sha> <head-sha>
# base/head 가 비면(push·schedule — 볼 PR 범위가 없다) 아무것도 안 하고 통과한다.

set -eu

base="${1:-}"
head="${2:-}"

if [ -z "$base" ] || [ -z "$head" ]; then
	echo "plugin-version-bump: base/head 가 비었다 — PR 이 아니라 볼 범위가 없다"
	exit 0
fi

if ! mb=$(git merge-base "$base" "$head" 2>/dev/null); then
	echo "plugin-version-bump: merge-base($base, $head) 를 못 구했다 — 판정할 수 없어 막는다" >&2
	exit 1
fi

if ! changed=$(git -c core.quotePath=false diff --no-renames --name-only "$mb" "$head" -- plugins/); then
	echo "plugin-version-bump: git diff 실패 — 판정할 수 없어 막는다" >&2
	exit 1
fi

if [ -z "$changed" ]; then
	echo "plugin-version-bump: plugins/ 변경 없음"
	exit 0
fi

# 바뀐 플러그인 이름들(plugins/<이름>/… 의 두 번째 조각). plugins/ 바로 아래 파일은 플러그인이 아니라 건너뛴다.
names=$(printf '%s\n' "$changed" | awk -F/ 'NF >= 3 { print $2 }' | sort -u)

# git 객체 하나(JSON)에서 version 을 꺼낸다. semver(MAJOR.MINOR.PATCH 숫자)가 아니면 실패.
# 구조로 읽는다(JSON 파서) — 정규식으로 `"version"` 을 찾으면 다른 칸·주석의 같은 글자에 속는다.
read_version() {
	git show "$1" | python3 -I -c '
import json, re, sys
data = json.load(sys.stdin)
v = data.get("version") if isinstance(data, dict) else None
if not isinstance(v, str) or not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", v):
    sys.exit("version is missing or not MAJOR.MINOR.PATCH: %r" % (v,))
print(v)
'
}

failures=0
for name in $names; do
	manifest="plugins/$name/.claude-plugin/plugin.json"
	if ! git cat-file -e "$head:plugins/$name" 2>/dev/null; then
		echo "plugin-version-bump: $name — head 에서 폴더째 지웠다(올릴 버전이 없다)"
		continue
	fi
	if ! git cat-file -e "$mb:$manifest" 2>/dev/null; then
		echo "plugin-version-bump: $name — merge-base 에 없던 새 플러그인"
		# 새 플러그인도 version 은 읽을 수 있어야 한다.
		if ! read_version "$head:$manifest" >/dev/null; then
			echo "plugin-version-bump: $name — head 의 $manifest 에서 version 을 못 읽었다" >&2
			failures=$((failures + 1))
		fi
		continue
	fi
	if ! old=$(read_version "$mb:$manifest"); then
		echo "plugin-version-bump: $name — merge-base 의 $manifest 에서 version 을 못 읽었다" >&2
		failures=$((failures + 1))
		continue
	fi
	if ! new=$(read_version "$head:$manifest"); then
		echo "plugin-version-bump: $name — head 의 $manifest 에서 version 을 못 읽었다(지웠거나 형식이 틀렸다)" >&2
		failures=$((failures + 1))
		continue
	fi
	if python3 -I -c 'import sys; t = lambda s: tuple(int(x) for x in s.split(".")); sys.exit(0 if t(sys.argv[2]) > t(sys.argv[1]) else 1)' "$old" "$new"; then
		echo "plugin-version-bump: $name — $old -> $new"
	else
		echo "plugin-version-bump: $name — plugins/$name/ 를 고쳤는데 version 이 $old -> $new 다. $manifest 의 version 을 올린다" >&2
		echo "  (안 올리면 사용자는 갱신해도 옛 판에 머문다 — docs/control-plane-browser.md §9.6.3)" >&2
		printf '%s\n' "$changed" | grep "^plugins/$name/" | sed 's/^/  바뀐 파일: /' >&2
		failures=$((failures + 1))
	fi
done

[ "$failures" -eq 0 ]
