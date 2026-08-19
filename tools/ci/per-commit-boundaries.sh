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
# 왜 모든 커밋이 아닌가 — 커밋마다 게이트를 돌리면 커밋 수에 비례해 비싸다. 이 사고가 나는 조건은
# **원장이 참조하는 파일이 바뀌었는데 원장이 함께 안 바뀐 것**이므로, 그 파일들을 건드린 커밋만 본다.
# 무관한 커밋(문서만·web 만)은 건너뛰고, **건너뛴 수를 반드시 출력한다** — 조용한 축소는 "전부 봤다" 로
# 읽히기 때문이다(이 저장소의 게이트 관례: 재고를 줄일 때는 무엇이 빠졌는지 로그로 남긴다).
#
# 팁 커밋은 보지 않는다 — 같은 job 의 `mise run check` 가 이미 그것을 돌린다. 여기서 또 돌리면 두 배다.
#
# 사용법: sh tools/ci/per-commit-boundaries.sh <base-sha> <head-sha>
# 종료 코드: 0 = 전부 통과(또는 볼 커밋 없음), 1 = 하나라도 실패
set -eu

BASE="${1:?base sha required}"
HEAD_SHA="${2:?head sha required}"

LEDGER="tests/boundary/external_source_digests.zig"

# 본체의 zig 캐시를 **절대 경로로** 잡아 둔다. 워크트리 안에서 `$PWD` 를 쓰면 `cd` 뒤에 평가돼 그 워크트리의
# 캐시를 가리키고, 그러면 커밋마다 처음부터 빌드한다(실측으로 그 상태였다). 공유해야 두 번째부터 싸다.
SHARED_CACHE="$(git rev-parse --show-toplevel)/.zig-cache"

# 원장이 참조하는 경로 + 원장 자신. 원장은 comptime import 라 값이 바뀌면 게이트 결과가 바뀐다.
# 목록을 손으로 복사하지 않고 **원장에서 뽑는다** — 두 벌을 두면 그 둘이 갈리는 순간 조용히 새는 쪽이 생긴다.
WATCHED="$(sed -n 's/.*\.path = "\([^"]*\)".*/\1/p' "$LEDGER" | sort -u)"
WATCHED="$WATCHED
$LEDGER"

# `base..head` 의 커밋을 **오래된 것부터**. 팁은 뺀다(같은 job 이 이미 본다).
COMMITS="$(git rev-list --reverse "$BASE..$HEAD_SHA" | grep -v "^$(git rev-parse "$HEAD_SHA")$" || true)"

if [ -z "$COMMITS" ]; then
  echo "중간 커밋 없음 — 팁 하나뿐이거나 빈 범위다(같은 job 의 check 가 그것을 본다)."
  exit 0
fi

total=0
relevant=0
skipped=0
failed=0
failed_list=""

for sha in $COMMITS; do
  total=$((total + 1))
  touched="$(git diff-tree --no-commit-id --name-only -r "$sha")"
  hit=""
  for path in $WATCHED; do
    if printf '%s\n' "$touched" | grep -qxF "$path"; then hit="$path"; break; fi
  done
  if [ -z "$hit" ]; then
    skipped=$((skipped + 1))
    continue
  fi
  relevant=$((relevant + 1))

  work="$(mktemp -d)"
  # 워크트리를 detached 로 붙여 그 커밋의 트리를 그대로 재현한다. 게이트는 cwd 기준으로 소스를 읽으므로
  # **그 커밋이 보던 파일**을 보게 된다. zig 캐시는 본체와 공유해 커밋마다 처음부터 빌드하지 않는다.
  git worktree add -q --detach "$work" "$sha"
  short="$(git rev-parse --short "$sha")"
  echo "── $short ($hit 를 건드림) 에서 check-boundaries"
  if (cd "$work" && ZIG_LOCAL_CACHE_DIR="$SHARED_CACHE" zig build check-boundaries >/dev/null 2>&1); then
    echo "   OK"
  else
    echo "   FAIL — 이 커밋에서 경계 게이트가 빨갛다"
    # 왜 빨간지 보여 준다. 조용히 실패하면 고치는 사람이 다시 재현해야 한다.
    (cd "$work" && ZIG_LOCAL_CACHE_DIR="$SHARED_CACHE" zig build check-boundaries 2>&1 | grep -E "mismatch|error:" | head -3) || true
    failed=$((failed + 1))
    failed_list="$failed_list $short"
  fi
  git worktree remove --force "$work"
done

echo ""
echo "중간 커밋 $total 개 — 원장 관련 $relevant 개 검사, $skipped 개 건너뜀(원장이 보는 파일을 안 건드림)."
if [ "$failed" -ne 0 ]; then
  echo "빨간 커밋$failed_list"
  echo "고치는 법: 그 커밋에 수렴을 접어 넣는다(\`git rebase -i\` 의 fixup). 팁에 새 커밋을 얹으면 이 검사가 다시 잡는다."
  exit 1
fi
exit 0
