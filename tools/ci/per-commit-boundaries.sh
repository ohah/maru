#!/bin/sh
# PR 의 **중간 커밋**들이 경계 게이트를 통과하는지 확인한다.
#
# 왜 필요한가 — 이 저장소가 같은 사고를 두 번 냈다. 리베이스에서 값이 움직였을 때 그 수렴을 **팁 커밋에
# 몰아** 넣으면 작업 트리는 초록인데 앞 커밋들이 빨간 상태로 `main` 에 남는다. CI 는 팁만 보므로 그것을
# 못 잡고, `git bisect`·커밋별 CI·그 지점 체크아웃이 그 구간에서 죽는다.
#   · 2026-08-18: `build.zig` 반쪽 섞임 → 9 커밋이 `zig build` 조차 안 됨
#   · 2026-08-19: digest 원장 낡음 → 2 커밋이 `check-boundaries` 실패
# 규율은 `docs/project-rules.md` `## 리베이스와 머지` 에 있고, 이 스크립트가 그 규율의 **기계 절반**이다.
#
# **비용은 "언제 도는가" 로만 줄인다 — "어느 커밋을 보는가" 로는 줄이지 않는다.**
# 앞 판은 "원장이 참조하는 파일을 건드린 커밋만" 보게 해서 값싸게 만들려 했는데, 그 전제가 틀렸다:
# `check-boundaries` 는 테스트 바이너리 **열 개**를 묶고 원장에 묶인 것은 그중 하나뿐이다. `build.zig` 는
# 목록에 아예 없었고, 실제 사고 구간에서 `build.zig` 를 건드린 **확실히 빨간 커밋을 "무관" 으로 건너뛰었다**.
# 건너뛴 수를 출력하는 것이 정직해 보였지만 그 수가 거짓 단언을 싣고 있었다. 그래서 발동 조건만 좁히고,
# 발동하면 **중간 커밋을 전부 본다**.
#
# 팁 커밋은 보지 않는다 — 같은 job 의 `mise run check` 가 이미 그것을 돌린다.
#
# 사용법: sh tools/ci/per-commit-boundaries.sh <base-sha> <head-sha>
# 종료 코드: 0 = 전부 통과(또는 볼 커밋 없음), 1 = 하나라도 실패, 2 = 범위를 해석할 수 없음
set -eu

BASE="${1:?base sha required}"
HEAD_SHA="${2:?head sha required}"

# 게이트 결과를 바꿀 수 있는 자리. 이 중 **아무것도** 안 건드린 PR 은 중간 커밋이 빨갈 수 없다.
LEDGER="tests/boundary/external_source_digests.zig"

# **범위를 못 읽으면 시끄럽게 죽는다.** 앞 판은 `|| true` 로 삼켰고, 그래서 얕은 클론(CI 기본 depth=1)에서
# `fatal: Invalid revision range` 가 "중간 커밋 없음" 으로 둔갑해 **항상 무동작·항상 초록**이었다.
# 조용히 열리는 게이트는 없는 게이트보다 나쁘다 — 있다고 믿게 만들기 때문이다.
for rev in "$BASE" "$HEAD_SHA"; do
  if ! git rev-parse --verify --quiet "$rev^{commit}" >/dev/null; then
    echo "범위를 해석할 수 없다: '$rev' 가 이 클론에 없다." >&2
    echo "CI 라면 checkout 의 fetch-depth 가 얕다는 뜻이다 — `check` job 에 fetch-depth: 0 이 필요하다." >&2
    exit 2
  fi
done

# **언제 도는가.** 원장·`build.zig`·경계 테스트 중 하나라도 PR 이 건드렸을 때만 본다. 셋 다 안 건드렸으면
# 중간 커밋이 게이트를 깰 방법이 없다(게이트의 판정자와 그 입력이 그대로이므로). 대부분의 PR 이 여기서 끝난다.
if ! git diff --name-only "$BASE..$HEAD_SHA" |
  grep -qE "^($LEDGER|build\.zig|tests/boundary/)"; then
  echo "경계 게이트의 입력(원장·build.zig·tests/boundary/)을 안 건드린 PR — 중간 커밋이 그것을 깰 수 없다."
  exit 0
fi

# `base..head` 의 커밋을 **오래된 것부터**. 팁은 뺀다(같은 job 이 이미 본다).
HEAD_FULL="$(git rev-parse "$HEAD_SHA")"
COMMITS="$(git rev-list --reverse "$BASE..$HEAD_SHA" | grep -v "^$HEAD_FULL$" || true)"

if [ -z "$COMMITS" ]; then
  echo "중간 커밋 없음 — 팁 하나뿐이다(같은 job 의 check 가 그것을 본다)."
  exit 0
fi

SHARED_CACHE="$(git rev-parse --show-toplevel)/.zig-cache"
work=""
# 중간에 죽거나 취소돼도 워크트리를 남기지 않는다(이 워크플로는 `cancel-in-progress` 를 켜 두었다).
cleanup() {
  [ -n "$work" ] && git worktree remove --force "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

total=0
failed=0
failed_list=""

for sha in $COMMITS; do
  total=$((total + 1))
  work="$(mktemp -d)"
  # 워크트리를 detached 로 붙여 그 커밋의 트리를 그대로 재현한다. 게이트는 cwd 기준으로 소스를 읽으므로
  # **그 커밋이 보던 파일**을 보게 된다. zig 캐시는 본체와 공유해 커밋마다 처음부터 빌드하지 않는다
  # (`$PWD` 를 쓰면 `cd` 뒤에 평가돼 워크트리의 캐시를 가리킨다 — 그러면 매번 cold 다).
  git worktree add -q --detach "$work" "$sha"
  short="$(git rev-parse --short "$sha")"
  echo "── $short 에서 check-boundaries"
  # **한 번만 돌린다.** 앞 판은 실패 시 사유를 얻으려고 한 번 더 돌렸고, zig 는 실패한 run step 을 캐시하지
  # 않으므로 그 재실행이 정확히 두 배였다(실측: 커밋 하나에 4분 추가).
  if out="$(cd "$work" && ZIG_LOCAL_CACHE_DIR="$SHARED_CACHE" zig build check-boundaries 2>&1)"; then
    echo "   OK"
  else
    echo "   FAIL — 이 커밋에서 경계 게이트가 빨갛다"
    # `error:` 는 줄머리로만 본다. `mismatch` 를 넓게 잡으면 **통과한 테스트 이름**이 걸린다 —
    # `known_hosts.test.아는 호스트인데 키가 다르면 mismatch 다...OK` 가 그것이고, 실측에서 그 노이즈가
    # 진짜 사유를 밀어냈다.
    printf '%s\n' "$out" | grep -E "inventory mismatch|^error:" | head -3 || true
    failed=$((failed + 1))
    failed_list="$failed_list $short"
  fi
  git worktree remove --force "$work"
  work=""
done

echo ""
echo "중간 커밋 $total 개를 전부 검사했다."
if [ "$failed" -ne 0 ]; then
  echo "빨간 커밋$failed_list"
  echo "고치는 법: 그 커밋에 수렴을 접어 넣는다(\`git rebase -i\` 의 fixup). 팁에 새 커밋을 얹으면 이 검사가 다시 잡는다."
  exit 1
fi
exit 0
