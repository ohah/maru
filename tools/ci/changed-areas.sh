#!/bin/sh
# PR의 변경 파일을 "어떤 CI 영역을 실행해야 하는가"로 분류한다.
#
# 왜 별도 스크립트인가: 같은 분류 정책을 ci.yml·web.yml·performance.yml 세 워크플로가 함께 쓴다.
# 워크플로마다 인라인 case 문을 복사하면 새 디렉터리가 생겼을 때 한쪽만 갱신돼 조용히 어긋난다.
# 이 파일이 분류 정책의 단일 출처이고, 워크플로는 결과 플래그만 소비한다.
#
# 왜 workflow-level `paths` 필터를 쓰지 않는가: required 체크로 등록된 워크플로에 `paths`를 두면
# 무관한 PR에서 워크플로 자체가 트리거되지 않아 required 컨텍스트가 영원히 pending으로 남아 머지를
# 막는다. 반면 job-level `if:`로 건너뛴 job은 GitHub이 conclusion=skipped로 보고하고 branch
# protection은 이를 통과로 취급한다. 그래서 트리거는 모든 PR에 열어 두고 job 단위로 거른다.
# 필수 체크 목록의 단일 출처는 docs/performance-budget.md "필수 CI 체크"다.
#
# 사용법: sh tools/ci/changed-areas.sh <base-sha> <head-sha> >> "$GITHUB_OUTPUT"
#
# 출력(GitHub Actions output 형식):
#   code=true|false   Zig/빌드/테스트 등 제품 코드 경로가 바뀌었는가
#   web=true|false    web/ 번들 경로가 바뀌었는가
#   docs=true|false   문서 경로가 바뀌었는가(config 문서 드리프트 게이트를 켜는 축)
#
# 세 축은 서로 독립이다 — Zig만 바꾸면 web:check를 돌리지 않고, web만 바꾸면 Zig 게이트를 돌리지
# 않는다. 양쪽에 걸치는 파일(.mise.toml·.github/*·tools/ci/*)과 분류되지 않은 파일만 둘 다 켠다.
#
# fail-safe: base/head를 못 구하거나 diff가 실패하면 **전부 true**를 내보내고 정상 종료한다.
# 변경 감지가 불확실할 때 CI를 건너뛰는 쪽으로 기울면 검증되지 않은 코드가 머지되므로,
# 애매하면 항상 "전부 실행"으로 넘어간다.

set -eu

base="${1:-}"
head="${2:-}"

emit_all() {
	echo "code=true"
	echo "web=true"
	echo "docs=true"
}

if [ -z "$base" ] || [ -z "$head" ]; then
	echo "changed-areas: base/head가 비어 있다 — 전 영역을 실행한다" >&2
	emit_all
	exit 0
fi

# three-dot diff: base 브랜치가 그 사이 전진했어도 merge-base 이후의 PR 변경분만 본다.
if ! files=$(git diff --name-only "$base...$head" 2>/dev/null); then
	echo "changed-areas: git diff $base...$head 실패 — 전 영역을 실행한다" >&2
	emit_all
	exit 0
fi

if [ -z "$files" ]; then
	echo "changed-areas: 변경 파일이 없다 — 전 영역을 실행한다" >&2
	emit_all
	exit 0
fi

code=false
web=false
docs=false

# 분류 규칙은 fail-safe다. 아래 어느 패턴에도 걸리지 않는 파일은 code·web을 **둘 다** 켠다.
# 새 최상위 디렉터리가 생겼는데 목록을 갱신하지 않으면 CI가 더 도는 쪽으로 틀린다(안전한 방향).
while IFS= read -r path; do
	[ -n "$path" ] || continue
	case "$path" in
	# 문서·라이선스와 에이전트 로컬 설정. 제품 빌드에도 파이프라인에도 들어가지 않는다.
	# docs/*.md는 check-config-docs가 런타임에 훑으므로 `check` job의 축소 실행이 계속 검증한다
	# (tests/config_docs/keys.zig).
	docs/* | *.md | LICENSE | .claude/*)
		docs=true
		;;
	# 파이프라인 정의 자체. 어느 축에 영향을 줄지 파일 안을 봐야 알 수 있으므로 둘 다 켠다.
	.mise.toml | .github/* | tools/ci/*)
		code=true
		web=true
		;;
	# web 번들(bun build/test/lint/license). Zig 게이트는 이 경로를 읽지 않는다.
	web/*)
		web=true
		;;
	# Zig 제품 코드·테스트·빌드. web:check는 이 경로를 읽지 않는다.
	src/* | tests/* | tools/* | terminfo/* | assets/* | build.zig | build.zig.zon)
		code=true
		;;
	*)
		code=true
		web=true
		;;
	esac
done <<EOF
$files
EOF

echo "changed-areas: code=$code web=$web docs=$docs" >&2
echo "$files" | sed 's/^/changed-areas:   /' >&2

echo "code=$code"
echo "web=$web"
echo "docs=$docs"
