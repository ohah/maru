#!/bin/sh
# `per-commit-boundaries.sh` 자신을 검증한다.
#
# 왜 필요한가 — `ci.yml` 의 `changes` job 주석이 이 저장소의 규칙을 적어 두었다: "분류가 틀리면 게이트가
# 조용히 열린다. 판정을 쓰기 전에 분류기 자신을 먼저 검증한다." 그 규칙을 안 지켰다가 정확히 그 사고가 났다 —
# 얕은 클론에서 범위 해석이 실패했는데 `|| true` 가 삼켜 **항상 무동작·항상 초록**이었다. 여기서 그
# **fail-safe 경로**(범위 없음·얕은 클론)를 직접 돌려 확인한다. 사고가 나야만 드러나는 종류이기 때문이다.
#
# 무거운 경로(실제 `zig build`)는 여기서 안 돌린다 — 그건 커밋마다 분 단위다. 이 테스트가 지키는 것은
# **판정과 조기 반환**이고, 빌드 자체는 게이트가 이미 다른 곳에서 증명한다.
#
# 사용법: sh tools/ci/per-commit-boundaries.test.sh
set -eu

SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/tools/ci/per-commit-boundaries.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
fails=0

check() { # <이름> <기대 종료코드> <실제 종료코드> [기대 문구]
  name="$1"; want="$2"; got="$3"; needle="${4:-}"
  if [ "$got" != "$want" ]; then
    echo "FAIL $name — 종료코드 기대 $want, 실제 $got"; fails=$((fails + 1)); return
  fi
  if [ -n "$needle" ] && ! grep -qF "$needle" "$work/out"; then
    echo "FAIL $name — 출력에 '$needle' 이 없다"; sed 's/^/    /' "$work/out"; fails=$((fails + 1)); return
  fi
  echo "ok   $name"
}

# 픽스처 저장소: base → 무관 커밋 → 게이트 입력을 건드린 커밋 → 팁
repo="$work/repo"
mkdir -p "$repo"
(
  cd "$repo"
  git init -q .
  git config user.email t@t; git config user.name t
  mkdir -p tests/boundary
  echo "x" > README.md
  echo "inventory" > tests/boundary/external_source_digests.zig
  git add -A; git commit -qm base
  echo "y" >> README.md; git add -A; git commit -qm "무관한 커밋"
  echo "moved" >> tests/boundary/external_source_digests.zig; git add -A; git commit -qm "원장을 건드린 커밋"
  echo "z" >> README.md; git add -A; git commit -qm tip
)
base="$(git -C "$repo" rev-parse HEAD~3)"
head="$(git -C "$repo" rev-parse HEAD)"

# 1) **얕은 클론**: 범위를 못 읽으면 조용히 통과하지 말고 2 로 죽어야 한다. 이것이 실제로 난 사고다.
shallow="$work/shallow"
git clone -q --depth 1 "file://$repo" "$shallow" 2>/dev/null
set +e
(cd "$shallow" && sh "$SCRIPT" "$base" "$head") > "$work/out" 2>&1
rc=$?
set -e
check "얕은 클론은 조용히 통과하지 않는다" 2 "$rc" "fetch-depth"

# 2) 게이트 입력을 안 건드린 범위 → 빌드 없이 0
set +e
(cd "$repo" && sh "$SCRIPT" "$base" "$(git -C "$repo" rev-parse HEAD~2)") > "$work/out" 2>&1
rc=$?
set -e
check "게이트 입력을 안 건드리면 곧장 끝낸다" 0 "$rc" "안 건드린 PR"

# 3) 중간 커밋이 없는 단일 커밋 PR → 0
set +e
(cd "$repo" && sh "$SCRIPT" "$(git -C "$repo" rev-parse HEAD~1)" "$head") > "$work/out" 2>&1
rc=$?
set -e
check "단일 커밋 PR 은 볼 중간이 없다" 0 "$rc"

# 4) base 가 없는 인자 → 2 (오타·잘못된 ref 도 조용히 통과하면 안 된다)
set +e
(cd "$repo" && sh "$SCRIPT" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$head") > "$work/out" 2>&1
rc=$?
set -e
check "없는 base 는 시끄럽게 죽는다" 2 "$rc" "해석할 수 없다"

if [ "$fails" -ne 0 ]; then
  echo "$fails 개 실패"; exit 1
fi
echo "전부 통과"
