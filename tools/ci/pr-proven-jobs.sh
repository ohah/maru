#!/bin/sh
# main push 가 **PR 에서 같은 tree 로 이미 통과한** macOS 잡을 다시 돌리지 않게, 잡마다 「PR 에서 증명됨」 플래그를 낸다.
#
# 왜: macOS 러너는 동시 5대가 상한이고, main push 한 번이 그 러너를 약 81분 쓴다(PR 은 29분 — 2026-09-30 ~ 10-01 실측
# run 60개). PR 과 main 이 같은 러너를 두고 줄을 서서, PR 의 macOS 잡은 실행 시간(중앙 9분)만큼 러너를 기다렸다.
# rebase 머지는 PR head 가 main 최신 위에 있으면 **tree 가 같은** 커밋을 만든다(최근 머지 15건 중 5건). 같은 tree 는 같은
# 소스·같은 워크플로라, PR 에서 통과한 잡을 main 에서 다시 돌려도 새로 알게 되는 것이 없다.
#
# 판정: 이 커밋을 만든 머지된 PR 이 **정확히 하나**이고, 그 PR head 의 tree 가 이 커밋의 tree 와 **같고**, 그 head 에서
# 그 잡의 **가장 최근** check run 이 completed/success 일 때만 true.
#
# fail-safe: 무엇이든 확인하지 못하면(API 실패·PR 없음·tree 다름·check 없음) 전부 false 로 내고 정상 종료한다 — 잡이
# 도는 쪽으로 기운다. 확인 못 한 것을 증명으로 치면 검증되지 않은 커밋이 main 에서 아무도 안 본 채 지나간다.
#
# 사용법: sh tools/ci/pr-proven-jobs.sh <owner/repo> <commit-sha> >> "$GITHUB_OUTPUT"
# 출력: proven_file_explorer · proven_macos_only · proven_appkit = true|false
# 테스트는 `PR_PROVEN_GH` 로 gh 대역을 꽂는다(tools/ci/pr-proven-jobs.test.sh).

set -eu

repo=${1:-}
sha=${2:-}
gh=${PR_PROVEN_GH:-gh}

# key=check run 이름(= ci.yml 의 잡 name). 이름이 바뀌면 이 표도 바뀌어야 한다 — 안 바뀌면 check 를 못 찾아 false 로
# 떨어진다(잡이 돈다). 조용히 건너뛰는 쪽으로 틀리지는 않는다.
jobs='file_explorer=file explorer macOS product path
macos_only=macOS-only gates
appkit=AppKit smokes macOS'

emit_none() {
	printf '%s\n' "$jobs" | while IFS== read -r key _; do
		echo "proven_$key=false"
	done
}

give_up() {
	echo "pr-proven-jobs: $1 — 모든 잡을 돌린다" >&2
	emit_none
	exit 0
}

[ -n "$repo" ] && [ -n "$sha" ] || give_up "repo/sha 가 비었다"
main_tree=$(git rev-parse "$sha^{tree}" 2>/dev/null) || give_up "커밋 $sha 의 tree 를 못 읽었다"

pr=$("$gh" api "repos/$repo/commits/$sha/pulls" \
	--jq '[.[] | select(.merged_at != null)] | if length == 1 then "\(.[0].number) \(.[0].head.sha)" else "" end' \
	2>/dev/null) || give_up "이 커밋의 PR 을 조회하지 못했다"
[ -n "$pr" ] || give_up "이 커밋을 만든 머지된 PR 이 정확히 하나가 아니다"
number=${pr%% *}
head=${pr#* }

head_tree=$("$gh" api "repos/$repo/git/commits/$head" --jq .tree.sha 2>/dev/null) ||
	give_up "PR #$number head 의 tree 를 조회하지 못했다"
[ "$head_tree" = "$main_tree" ] || give_up "PR #$number head 의 tree 가 다르다(머지 때 다시 쌓였다)"

runs=$("$gh" api --paginate "repos/$repo/commits/$head/check-runs?per_page=100" \
	--jq '.check_runs[] | "\(.id)\t\(.status)\t\(.conclusion)\t\(.name)"' 2>/dev/null) ||
	give_up "PR #$number head 의 check run 을 조회하지 못했다"

printf '%s\n' "$jobs" | while IFS== read -r key name; do
	# 같은 이름이 여럿이면(재실행) **가장 최근**(가장 큰 id)만 본다 — 앞의 성공이 뒤의 실패를 가리지 않게.
	latest=$(printf '%s\n' "$runs" | awk -F '\t' -v n="$name" '$4 == n' | sort -n -k1,1 | tail -n 1)
	status=$(printf '%s' "$latest" | cut -f2)
	conclusion=$(printf '%s' "$latest" | cut -f3)
	if [ "$status" = completed ] && [ "$conclusion" = success ]; then
		echo "proven_$key=true"
		echo "pr-proven-jobs: '$name' — PR #$number 의 같은 tree 에서 통과, main 에서 건너뛴다" >&2
	else
		echo "proven_$key=false"
	fi
done
