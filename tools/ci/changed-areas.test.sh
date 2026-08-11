#!/bin/sh
# changed-areas.sh가 "어떤 CI 영역을 실행할지"를 실제로 옳게 고르는지 고정한다.
#
# 왜 중요한가: 이 분류가 틀리면 두 방향으로 손해가 난다. 과소 판정은 검증되지 않은 코드를 머지시키고
# (게이트가 조용히 열린다), 과대 판정은 문서 한 줄에 macOS 러너 4대를 태운다. 특히 fail-safe 경로
# (base/head 없음·diff 실패·미분류 경로)는 사고가 나야 드러나므로 여기서 직접 실행해 확인한다.
#
# 임시 git 저장소에 실제 커밋을 만들어 실제 `git diff`를 태운다 — 분류 정책만 흉내 내는 테스트는
# base/head 해석이 깨져도 통과하기 때문이다.
#
# 실행: sh tools/ci/changed-areas.test.sh

set -eu

script=$(cd "$(dirname "$0")" && pwd)/changed-areas.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

git -C "$work" init -q
git -C "$work" config user.email ci@example.com
git -C "$work" config user.name ci
: >"$work/seed"
git -C "$work" add seed
git -C "$work" commit -qm seed
base=$(git -C "$work" rev-parse HEAD)

failures=0

# 주어진 경로들을 한 커밋으로 만들고, 그 커밋의 분류 결과가 기대와 같은지 본다.
expect() {
	want=$1
	shift
	git -C "$work" checkout -q "$base"
	for path in "$@"; do
		mkdir -p "$work/$(dirname "$path")"
		echo change >"$work/$path"
		git -C "$work" add "$path"
	done
	git -C "$work" commit -qm change
	head=$(git -C "$work" rev-parse HEAD)

	got=$(cd "$work" && sh "$script" "$base" "$head" 2>/dev/null | tr '\n' ' ')
	got=${got% }
	if [ "$got" = "$want" ]; then
		echo "ok: [$*] -> $got"
	else
		echo "FAIL: [$*]"
		echo "  기대: $want"
		echo "  실제: $got"
		failures=$((failures + 1))
	fi
}

# 파일 **내용**까지 정해 한 줄을 고친다 — 주석 전용 판정은 경로가 아니라 diff를 봐야 고정된다.
expect_edit() {
	want=$1
	path=$2
	before=$3
	after=$4
	git -C "$work" checkout -q "$base"
	mkdir -p "$work/$(dirname "$path")"
	printf '%s' "$before" >"$work/$path"
	git -C "$work" add "$path"
	git -C "$work" commit -qm before
	edit_base=$(git -C "$work" rev-parse HEAD)
	printf '%s' "$after" >"$work/$path"
	git -C "$work" add "$path"
	git -C "$work" commit -qm after
	got=$(cd "$work" && sh "$script" "$edit_base" "$(git -C "$work" rev-parse HEAD)" 2>/dev/null | tr '\n' ' ')
	got=${got% }
	if [ "$got" = "$want" ]; then
		echo "ok: [$path 수정] -> $got"
	else
		echo "FAIL: [$path 수정]"
		echo "  기대: $want"
		echo "  실제: $got"
		failures=$((failures + 1))
	fi
}

# ── 주석 전용 변경은 macOS 잡을 켜지 않는다(code는 켜서 digest·fmt 게이트는 계속 돈다) ──────────
#
# 이 축이 없으면 문서 경로를 가리키는 주석 한 줄에 macOS 러너 다섯 대가 돈다. 반대로 판정이 느슨해
# 코드 변경을 주석으로 오인하면 검증 없이 머지되므로, 아래 네 케이스로 경계를 못박는다.

# doc comment만 고쳤다 — 문서 분할에서 실제로 반복된 모양이다.
expect_edit "code=true runtime=false web=false docs=false" src/mod.zig \
	'/// docs/old.md §3 참조.
pub const x = 1;
' \
	'/// docs/new.md §3 참조.
pub const x = 1;
'

# 일반 주석과 빈 줄만 — 빈 줄은 주석 블록을 재배치할 때 딸려 오고 동작을 바꾸지 않는다.
expect_edit "code=true runtime=false web=false docs=false" src/mod.zig \
	'// 설명 한 줄.
pub const x = 1;
' \
	'// 설명 한 줄.

// 덧붙인 설명.
pub const x = 1;
'

# 주석과 코드가 섞이면 코드 변경이다 — 한 줄이라도 섞이면 즉시 runtime을 켠다.
expect_edit "code=true runtime=true web=false docs=false" src/mod.zig \
	'// 설명.
pub const x = 1;
' \
	'// 설명을 고쳤다.
pub const x = 2;
'

# 문자열 안의 `//`는 주석이 아니다 — 판정은 **줄 시작**만 본다.
expect_edit "code=true runtime=true web=false docs=false" src/mod.zig \
	'pub const url = "https://a.example";
' \
	'pub const url = "https://b.example";
'

# Swift도 같은 규칙(macOS 잡이 이 파일들을 태운다).
expect_edit "code=true runtime=false web=false docs=false" src/platform/macos/Host.swift \
	'// docs/old.md §2.
let x = 1
' \
	'// docs/new.md §2.
let x = 1
'

# 주석 개념이 없거나 형식이 다른 경로는 그대로 켠다(과소 판정보다 과대 판정이 안전하다).
expect_edit "code=true runtime=true web=false docs=false" terminfo/maru.src \
	'a
' \
	'b
'

# 문서 전용 변경은 어떤 빌드 게이트도 켜지 않는다(docs 축만 켜져 check가 config 드리프트만 본다).
expect "code=false runtime=false web=false docs=true" docs/architecture.md
expect "code=false runtime=false web=false docs=true" AGENTS.md .claude/settings.json LICENSE

# Zig 변경은 Zig 게이트만 — web:check는 이 경로를 읽지 않는다.
expect "code=true runtime=true web=false docs=false" src/core.zig
expect "code=true runtime=true web=false docs=false" build.zig tests/boundary/imports.zig tools/perf/core.zig

# web 변경은 web 게이트만 — Zig 게이트는 이 경로를 읽지 않는다.
expect "code=false runtime=false web=true docs=false" web/src/main.ts
expect "code=false runtime=false web=true docs=false" web/package.json web/bun.lock

# 문서와 코드가 섞이면 코드 쪽 축이 이긴다(문서만이라는 판정은 문서'만' 바뀔 때 성립한다).
expect "code=true runtime=true web=false docs=true" docs/architecture.md src/core.zig

# docs/configuration.md는 @embedFile로 빌드에 들어가는 **코드**다. 문서로 분류하면 표 행 삭제나
# range 오기입이 src/config/schema.zig의 doc-drift 테스트를 건너뛴다.
expect "code=true runtime=true web=false docs=false" docs/configuration.md

# 파이프라인 정의는 어느 축에 영향을 줄지 파일 안을 봐야 알므로 둘 다 켠다.
expect "code=true runtime=true web=true docs=false" .mise.toml
expect "code=true runtime=true web=true docs=false" .github/workflows/ci.yml
expect "code=true runtime=true web=true docs=false" tools/ci/changed-areas.sh

# 분류되지 않은 새 경로는 fail-safe로 전부 실행한다 — 목록을 갱신하지 않아도 게이트가 열리지 않는다.
expect "code=true runtime=true web=true docs=false" newtop/thing.txt

# 비ASCII 경로. git 기본 core.quotePath는 `"docs/\355\225\234.md"`로 내보내 앞의 따옴표가 docs/* 매칭을
# 깨뜨린다 — 문서 하나에 macOS 러너가 전부 도는 과대 판정이 된다.
expect "code=false runtime=false web=false docs=true" "docs/한글문서.md"

# rename으로 코드를 문서 경로에 숨길 수 없어야 한다. git은 rename을 감지하면 **새 경로만** 내보내므로,
# `src/*.zig` → `docs/*.md` 이동이 "문서 전용"으로 오판되면 Zig 소스가 사라진 채 게이트가 열린다.
git -C "$work" checkout -q "$base"
mkdir -p "$work/src"
printf 'const a = 1;\nconst b = 2;\nconst c = 3;\n' >"$work/src/moved.zig"
git -C "$work" add src/moved.zig
git -C "$work" commit -qm add-source
renamed_base=$(git -C "$work" rev-parse HEAD)
mkdir -p "$work/docs"
git -C "$work" mv src/moved.zig docs/moved.md
git -C "$work" commit -qm rename-source-to-doc
renamed=$(cd "$work" && sh "$script" "$renamed_base" "$(git -C "$work" rev-parse HEAD)" 2>/dev/null | tr '\n' ' ')
if [ "${renamed% }" = "code=true runtime=true web=false docs=true" ]; then
	echo "ok: src -> docs rename -> Zig 게이트 유지"
else
	echo "FAIL: src -> docs rename -> ${renamed% }"
	failures=$((failures + 1))
fi

# base/head가 없거나(push·schedule) SHA가 못 미더우면 전부 실행한다.
noargs=$(cd "$work" && sh "$script" "" "" 2>/dev/null | tr '\n' ' ')
if [ "${noargs% }" = "code=true runtime=true web=true docs=true" ]; then
	echo "ok: base/head 없음 -> 전 영역"
else
	echo "FAIL: base/head 없음 -> ${noargs% }"
	failures=$((failures + 1))
fi

badsha=$(cd "$work" && sh "$script" 0000000000000000000000000000000000000000 HEAD 2>/dev/null | tr '\n' ' ')
if [ "${badsha% }" = "code=true runtime=true web=true docs=true" ]; then
	echo "ok: 알 수 없는 base SHA -> 전 영역"
else
	echo "FAIL: 알 수 없는 base SHA -> ${badsha% }"
	failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
	echo "changed-areas.test.sh: $failures개 실패" >&2
	exit 1
fi
echo "changed-areas.test.sh: 전부 통과"
