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

# `zig` 가 없으면 이 테스트는 아무것도 못 지킨다 — 파싱 검사 경로가 통째로 안 돌기 때문이다.
# **조용히 건너뛰지 않고 여기서 죽는다.** 실제로 이 테스트를 mise 가 없는 job 에 붙였다가 CI 가 그것을
# 잡았고, 그때 "zig: not found" 가 테스트 실패로 보여 원인을 찾는 데 시간이 들었다.
if ! command -v zig >/dev/null 2>&1; then
  echo "zig 가 PATH 에 없다 — 이 테스트는 `zig ast-check` 경로를 돈다. mise 가 있는 job 에서 돌려야 한다." >&2
  exit 2
fi
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

# 픽스처 저장소: base → 소스 변경 → **원장만 고치는 커밋**(안티패턴) → 팁
repo="$work/repo"
mkdir -p "$repo"
(
  cd "$repo"
  git init -q .
  git config user.email t@t; git config user.name t
  mkdir -p tests/boundary src/config
  printf 'const x = 1;\n' > src/config/schema.zig
  printf 'pub const inventory = .{ .{ .path = "src/config/schema.zig", .digest_hex = "aa" } };\n' > tests/boundary/external_source_digests.zig
  git add -A; git commit -qm base
  printf 'const x = 2;\n' > src/config/schema.zig; git add -A; git commit -qm "소스를 바꾼다"
  printf 'pub const inventory = .{ .{ .path = "src/config/schema.zig", .digest_hex = "bb" } };\n' > tests/boundary/external_source_digests.zig
  git add -A; git commit -qm "원장만 맞춘다(안티패턴)"
  printf 'const x = 3;\n' > src/config/schema.zig
  printf 'pub const inventory = .{ .{ .path = "src/config/schema.zig", .digest_hex = "cc" } };\n' > tests/boundary/external_source_digests.zig
  git add -A; git commit -qm "소스와 원장을 함께(정상)"
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

# 2) **원장만 고치는 커밋**을 잡는다(사고 2 의 서명)
set +e
(cd "$repo" && sh "$SCRIPT" "$base" "$head") > "$work/out" 2>&1
rc=$?
set -e
check "원장만 고치는 커밋을 잡는다" 1 "$rc" "원장만 고치는 커밋"

# 3) 소스와 원장을 **함께** 고친 구간은 통과한다(정상 패턴을 막으면 못 쓴다)
set +e
(cd "$repo" && sh "$SCRIPT" "$(git -C "$repo" rev-parse HEAD~1)" "$head") > "$work/out" 2>&1
rc=$?
set -e
check "소스와 원장을 함께 고치면 통과한다" 0 "$rc"

# 4) 원장 **단독 수정 PR**(main 의 드리프트를 고치는 정상 PR)은 잡지 않는다 — 앞에 소스 커밋이 없다
solo="$work/solo"
mkdir -p "$solo"
(
  cd "$solo"
  git init -q .; git config user.email t@t; git config user.name t
  mkdir -p tests/boundary
  printf 'pub const inventory = .{ .{ .path = "x.zig", .digest_hex = "aa" } };\n' > tests/boundary/external_source_digests.zig
  git add -A; git commit -qm base
  printf 'pub const inventory = .{ .{ .path = "x.zig", .digest_hex = "bb" } };\n' > tests/boundary/external_source_digests.zig
  git add -A; git commit -qm "원장 드리프트만 고치는 PR"
)
set +e
(cd "$solo" && sh "$SCRIPT" "$(git -C "$solo" rev-parse HEAD~1)" "$(git -C "$solo" rev-parse HEAD)") > "$work/out" 2>&1
rc=$?
set -e
check "원장 단독 수정 PR 은 오탐이 아니다" 0 "$rc"

# 5) **파싱 안 되는 .zig** 를 잡는다(사고 1 의 서명)
broken="$work/broken"
mkdir -p "$broken"
(
  cd "$broken"
  git init -q .; git config user.email t@t; git config user.name t
  mkdir -p tests/boundary
  printf 'const a = .{};\n' > build.zig
  printf 'pub const inventory = .{ .{ .path = "build.zig", .digest_hex = "aa" } };\n' > tests/boundary/external_source_digests.zig
  git add -A; git commit -qm base
  printf 'const a = .{\n' > build.zig   # 닫히지 않은 초기화 — 자동 해소가 낸 것과 같은 형태
  git add -A; git commit -qm "반쪽 섞인 build.zig"
  printf 'const a = .{};\n' > build.zig; git add -A; git commit -qm "팁에서 고침"
)
set +e
(cd "$broken" && sh "$SCRIPT" "$(git -C "$broken" rev-parse HEAD~2)" "$(git -C "$broken" rev-parse HEAD)") > "$work/out" 2>&1
rc=$?
set -e
check "파싱 안 되는 .zig 를 잡는다" 1 "$rc" "파싱되지 않는다"

# 6) 없는 base → 2 (오타·잘못된 ref 도 조용히 통과하면 안 된다)
set +e
(cd "$repo" && sh "$SCRIPT" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$head") > "$work/out" 2>&1
rc=$?
set -e
check "없는 base 는 시끄럽게 죽는다" 2 "$rc" "해석할 수 없다"

if [ "$fails" -ne 0 ]; then
  echo "$fails 개 실패"; exit 1
fi
echo "전부 통과"
