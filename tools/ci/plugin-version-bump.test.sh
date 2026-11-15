#!/bin/sh
# plugin-version-bump.sh 가 「플러그인을 고쳤는데 version 을 안 올린 PR」을 실제로 막고, 그렇지 않은 PR 은 통과시키는지 고정한다.
#
# 왜 중요한가: 이 판정자가 조용히 통과하면 사용자는 고친 스킬을 영영 못 받는다(Claude Code 가 version 문자열로
# 캐시를 가른다). 반대로 과하게 막으면 플러그인과 무관한 PR 이 빨개진다. 둘 다 실제 git 저장소로 재야 한다 —
# merge-base·three-dot 해석이 깨져도 정책만 흉내 내는 시험은 통과하기 때문이다(changed-areas.test.sh 와 같은 이유).
#
# 실행: sh tools/ci/plugin-version-bump.test.sh

set -eu

script=$(cd "$(dirname "$0")" && pwd)/plugin-version-bump.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

g() { git -C "$work" "$@"; }

g init -q
g config user.email ci@example.com
g config user.name ci
g checkout -q -b main

manifest() { # <plugin> <version-json-value>
	mkdir -p "$work/plugins/$1/.claude-plugin"
	printf '{\n  "name": "%s",\n  "version": %s\n}\n' "$1" "$2" >"$work/plugins/$1/.claude-plugin/plugin.json"
	g add "plugins/$1/.claude-plugin/plugin.json"
}
touch_file() { # <path>
	mkdir -p "$work/$(dirname "$1")"
	echo "$(date +%s%N) $RANDOM" >>"$work/$1"
	g add "$1"
}

manifest maru-browser '"0.1.0"'
touch_file plugins/maru-browser/skills/maru-browser/SKILL.md
touch_file src/core.zig
g commit -qm seed
seed=$(g rev-parse HEAD)

failures=0

# 브랜치를 seed 에서 새로 떠서 준비 함수를 돌리고 커밋한 뒤, 판정 결과(pass/fail)가 기대와 같은지 본다.
check() { # <want pass|fail> <설명> <준비 함수>
	want=$1
	what=$2
	g checkout -q -B "case" "$seed"
	"$3"
	g commit -qm "$what" --allow-empty
	head=$(g rev-parse HEAD)
	if (cd "$work" && sh "$script" "$seed" "$head") >/dev/null 2>&1; then got=pass; else got=fail; fi
	if [ "$got" = "$want" ]; then
		echo "ok: $what -> $got"
	else
		echo "FAIL: $what — 기대 $want, 실제 $got"
		failures=$((failures + 1))
	fi
}

skill_only() { touch_file plugins/maru-browser/skills/maru-browser/SKILL.md; }
skill_and_bump() { skill_only; manifest maru-browser '"0.1.1"'; }
skill_and_lower() { skill_only; manifest maru-browser '"0.0.9"'; }
bump_to_two_digit_minor() { skill_only; manifest maru-browser '"0.10.0"'; }
unrelated() { touch_file src/core.zig; touch_file docs/x.md; }
marketplace_only() { touch_file .claude-plugin/marketplace.json; }
new_plugin() { manifest maru-editor '"0.1.0"'; touch_file plugins/maru-editor/skills/x/SKILL.md; }
new_plugin_no_version() { manifest maru-editor 'null'; touch_file plugins/maru-editor/skills/x/SKILL.md; }
version_not_semver() { skill_only; manifest maru-browser '"0.2"'; }
version_removed() { skill_only; printf '{ "name": "maru-browser" }\n' >"$work/plugins/maru-browser/.claude-plugin/plugin.json"; g add -A; }
manifest_broken() { skill_only; printf '{ not json\n' >"$work/plugins/maru-browser/.claude-plugin/plugin.json"; g add -A; }
manifest_deleted() { skill_only; g rm -q plugins/maru-browser/.claude-plugin/plugin.json; }
plugin_deleted() { g rm -q -r plugins/maru-browser; }
nothing() { :; }

check fail "스킬만 고치고 version 그대로" skill_only
check pass "스킬을 고치고 version 을 올림" skill_and_bump
check fail "version 을 내림" skill_and_lower
check pass "0.1.0 -> 0.10.0(두 자리 minor)" bump_to_two_digit_minor
check pass "플러그인 밖만 고침" unrelated
check pass "마켓플레이스 목록만 고침(플러그인 폴더 밖)" marketplace_only
check pass "새 플러그인 추가" new_plugin
check fail "새 플러그인인데 version 이 없음" new_plugin_no_version
check fail "version 이 semver 가 아님" version_not_semver
check fail "version 칸을 지움" version_removed
check fail "plugin.json 이 JSON 이 아님" manifest_broken
check fail "plugin.json 을 지우고 폴더는 남김" manifest_deleted
check pass "플러그인 폴더째 지움" plugin_deleted
check pass "빈 PR" nothing

# 0.9 -> 0.10: 위 두 자리 minor 사례는 0.1.0 에서 출발해 문자열 비교로도 통과한다 —
# 문자열 비교면 "0.10.0" < "0.9.0" 이 되는 꼴을 직접 만든다.
g checkout -q -B nine "$seed"
manifest maru-browser '"0.9.0"'
g commit -qm nine
nine=$(g rev-parse HEAD)
g checkout -q -B ten "$nine"
touch_file plugins/maru-browser/skills/maru-browser/SKILL.md
manifest maru-browser '"0.10.0"'
g commit -qm ten
if (cd "$work" && sh "$script" "$nine" "$(g rev-parse HEAD)") >/dev/null 2>&1; then
	echo "ok: 0.9.0 -> 0.10.0 통과(수 비교)"
else
	echo "FAIL: 0.9.0 -> 0.10.0 을 막았다 — 문자열로 비교하고 있다"
	failures=$((failures + 1))
fi

# three-dot: main 이 그 사이 플러그인을 고치고 올렸어도, PR 이 플러그인을 안 건드렸으면 PR 은 통과한다.
g checkout -q -B main "$seed"
touch_file plugins/maru-browser/skills/maru-browser/SKILL.md
manifest maru-browser '"0.2.0"'
g commit -qm main-bump
main_tip=$(g rev-parse HEAD)
g checkout -q -B pr "$seed"
touch_file src/core.zig
g commit -qm pr
if (cd "$work" && sh "$script" "$main_tip" "$(g rev-parse HEAD)") >/dev/null 2>&1; then
	echo "ok: main 이 앞서 플러그인을 올림 + PR 은 무관 -> pass"
else
	echo "FAIL: main 의 변경을 PR 의 변경으로 셌다(merge-base 가 아니라 base 와 비교)"
	failures=$((failures + 1))
fi

# merge-base 기준: PR 이 스킬을 고쳤고 version 은 갈라진 자리(0.1.0) 그대로 — main 이 0.2.0 으로 갔어도 막는다.
g checkout -q -B pr2 "$seed"
touch_file plugins/maru-browser/skills/maru-browser/SKILL.md
g commit -qm pr2
if (cd "$work" && sh "$script" "$main_tip" "$(g rev-parse HEAD)") >/dev/null 2>&1; then
	echo "FAIL: 갈라진 자리와 같은 version 을 통과시켰다"
	failures=$((failures + 1))
else
	echo "ok: PR 이 스킬만 고침(갈라진 자리 0.1.0 그대로) -> fail"
fi

# base/head 가 비면(push) 볼 범위가 없어 통과, 모르는 SHA 면 판정할 수 없어 실패.
if (cd "$work" && sh "$script" "" "") >/dev/null 2>&1; then echo "ok: base/head 없음 -> pass"; else
	echo "FAIL: base/head 없음에서 막았다"
	failures=$((failures + 1))
fi
if (cd "$work" && sh "$script" 0123456789abcdef0123456789abcdef01234567 "$seed") >/dev/null 2>&1; then
	echo "FAIL: 모르는 base SHA 를 통과시켰다"
	failures=$((failures + 1))
else echo "ok: 모르는 base SHA -> fail"; fi

if [ "$failures" -ne 0 ]; then
	echo "plugin-version-bump.test.sh: $failures 건 실패"
	exit 1
fi
echo "plugin-version-bump.test.sh: 전부 통과"
