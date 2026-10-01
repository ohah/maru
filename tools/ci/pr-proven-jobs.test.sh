#!/bin/sh
# pr-proven-jobs.sh 가 「PR 에서 증명됨」을 **좁게만** 내는지 고정한다.
#
# 이 판정이 틀리면 main 에서 macOS 잡이 조용히 안 돈다 — 과대 판정이 곧 검증 구멍이다. 그래서 true 가 나오는
# 경우는 하나(머지된 PR 하나 · tree 같음 · 가장 최근 check 가 success)로 고정하고, 나머지는 전부 false 인지 본다.
# fail-safe 경로(API 실패·PR 없음)는 사고가 나야 드러나므로 여기서 직접 실행한다.
#
# 실제 git 커밋의 tree 를 쓰고, gh 는 경로별로 정해 둔 응답을 내는 대역으로 바꾼다(PR_PROVEN_GH).
#
# 실행: sh tools/ci/pr-proven-jobs.test.sh

set -eu

script=$(cd "$(dirname "$0")" && pwd)/pr-proven-jobs.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

git -C "$work" init -q
git -C "$work" config user.email ci@example.com
git -C "$work" config user.name ci
echo one >"$work/a"
git -C "$work" add a
git -C "$work" commit -qm one
sha=$(git -C "$work" rev-parse HEAD)
tree=$(git -C "$work" rev-parse "HEAD^{tree}")

# gh 대역: 요청 경로로 응답을 고른다. FAKE_FAIL 에 걸린 경로는 실패(exit 1)한다.
fake="$work/fake-gh"
cat >"$fake" <<'EOF'
#!/bin/sh
path=""
for arg in "$@"; do
	case "$arg" in repos/*) path=$arg ;; esac
done
case "$path" in
	*"${FAKE_FAIL:-__never__}"*) exit 1 ;;
esac
case "$path" in
	*/pulls) printf '%s' "$FAKE_PULLS" ;;
	*/git/commits/*) printf '%s\n' "$FAKE_HEAD_TREE" ;;
	*/check-runs*) printf '%b' "$FAKE_RUNS" ;;
	*) exit 1 ;;
esac
EOF
chmod +x "$fake"

all_ok='1\tcompleted\tsuccess\tfile explorer macOS product path\n2\tcompleted\tsuccess\tmacOS-only gates\n3\tcompleted\tsuccess\tAppKit smokes macOS\n'
failures=0

expect() {
	label=$1
	want=$2
	got=$(cd "$work" && PR_PROVEN_GH="$fake" sh "$script" "${REPO-o/r}" "${SHA-$sha}" 2>/dev/null | tr '\n' ' ')
	got=${got% }
	if [ "$got" = "$want" ]; then
		echo "ok: $label -> $got"
	else
		echo "FAIL: $label"
		echo "  기대: $want"
		echo "  실제: $got"
		failures=$((failures + 1))
	fi
}

none='proven_file_explorer=false proven_macos_only=false proven_appkit=false'

# 유일하게 true 가 나오는 모양.
FAKE_PULLS="7 headsha" FAKE_HEAD_TREE="$tree" FAKE_RUNS="$all_ok" FAKE_FAIL="" \
	expect "같은 tree · 셋 다 성공" 'proven_file_explorer=true proven_macos_only=true proven_appkit=true'

# tree 가 다르면(머지 때 main 위로 다시 쌓임) 아무것도 증명되지 않는다.
FAKE_PULLS="7 headsha" FAKE_HEAD_TREE="0000000000000000000000000000000000000000" FAKE_RUNS="$all_ok" FAKE_FAIL="" \
	expect "tree 다름" "$none"

# 머지된 PR 이 없거나 하나가 아니면(직접 push 등) 판정하지 않는다 — jq 가 빈 문자열을 낸다.
FAKE_PULLS="" FAKE_HEAD_TREE="$tree" FAKE_RUNS="$all_ok" FAKE_FAIL="" \
	expect "PR 없음" "$none"

# 재실행: 앞의 성공이 뒤의 실패를 가리면 안 된다 — 가장 큰 id 만 본다.
FAKE_PULLS="7 headsha" FAKE_HEAD_TREE="$tree" \
	FAKE_RUNS='1\tcompleted\tsuccess\tfile explorer macOS product path\n9\tcompleted\tfailure\tfile explorer macOS product path\n2\tcompleted\tsuccess\tmacOS-only gates\n3\tcompleted\tsuccess\tAppKit smokes macOS\n' \
	FAKE_FAIL="" \
	expect "재실행 뒤 실패" 'proven_file_explorer=false proven_macos_only=true proven_appkit=true'

# 반대 순서(실패 뒤 재실행 성공)는 성공이다.
FAKE_PULLS="7 headsha" FAKE_HEAD_TREE="$tree" \
	FAKE_RUNS='1\tcompleted\tfailure\tfile explorer macOS product path\n9\tcompleted\tsuccess\tfile explorer macOS product path\n2\tcompleted\tsuccess\tmacOS-only gates\n3\tcompleted\tsuccess\tAppKit smokes macOS\n' \
	FAKE_FAIL="" \
	expect "실패 뒤 재실행 성공" 'proven_file_explorer=true proven_macos_only=true proven_appkit=true'

# 건너뛴 잡(skipped)·진행 중·아예 없는 잡은 증명이 아니다.
FAKE_PULLS="7 headsha" FAKE_HEAD_TREE="$tree" \
	FAKE_RUNS='1\tcompleted\tskipped\tfile explorer macOS product path\n2\tin_progress\t\tmacOS-only gates\n' \
	FAKE_FAIL="" \
	expect "skipped·진행 중·없음" "$none"

# API 실패는 어느 단계든 전부 false 다.
for step in pulls git/commits check-runs; do
	FAKE_PULLS="7 headsha" FAKE_HEAD_TREE="$tree" FAKE_RUNS="$all_ok" FAKE_FAIL="$step" \
		expect "API 실패: $step" "$none"
done

# 인자가 비면 판정하지 않는다.
SHA="" FAKE_PULLS="7 headsha" FAKE_HEAD_TREE="$tree" FAKE_RUNS="$all_ok" FAKE_FAIL="" \
	expect "sha 없음" "$none"

if [ "$failures" -ne 0 ]; then
	echo "pr-proven-jobs.test: $failures 건 실패"
	exit 1
fi
echo "pr-proven-jobs.test: 전부 통과"
