#!/bin/sh
# PR 의 **중간 커밋**이 히스토리를 빨갛게 남기는 두 형태를 잡는다 — **빌드 없이**.
#
# 왜 필요한가 — 이 저장소가 같은 사고를 두 번 냈다. 리베이스에서 값이 움직였을 때 그 수렴을 **팁 커밋에
# 몰아** 넣으면 작업 트리는 초록인데 앞 커밋들이 빨간 채로 `main` 에 남는다. CI 는 팁만 보므로 못 잡고,
# `git bisect`·커밋별 CI·그 지점 체크아웃이 그 구간에서 죽는다.
#   · 2026-08-18: `build.zig` 반쪽 섞임 → 9 커밋이 `zig build` 조차 안 됨
#   · 2026-08-19: digest 원장 낡음 → 2 커밋이 `check-boundaries` 실패
# 규율은 `docs/project-rules.md` `## 리베이스와 머지` 에 있고, 이것이 그 **기계 절반**이다.
#
# **왜 커밋마다 게이트를 돌리지 않는가 — 실측했더니 못 쓸 비용이었다.**
# 앞 판은 중간 커밋마다 워크트리를 만들어 `zig build check-boundaries` 를 돌렸다. 캐시를 공유해도
# **커밋당 3분 48초**였고(중간 커밋 2개에 7분 33초), 발동 조건이 최근 60 커밋의 **38%** 에 걸린다.
# CI 러너는 로컬보다 느리다. 그 비용은 이 사고가 주는 손해(bisect 몇 칸)에 비해 크다.
#
# **대신 두 형태의 서명을 직접 본다.** 둘 다 `git` 과 `zig ast-check` 만으로 밀리초~초 단위다.
#
#   ① **원장만 고치는 커밋** — 사고 2 의 정확한 서명이다. 실제로 `42e1965b`·`0534ce89` 둘 다 파일 하나
#      (`external_source_digests.zig`)만 건드렸다. 소스와 **같은 커밋**에서 수렴시켰다면 그런 커밋이
#      아예 안 생긴다. 앞선 커밋이 원장이 보는 파일을 건드렸을 때만 잡는다 — `main` 의 드리프트를
#      고치는 단독 PR 은 그 앞이 없으므로 정상이다.
#
#   ② **파싱 안 되는 `.zig`** — 사고 1 의 서명이다. 자동 해소가 `build.zig` 의 블록을 반쪽씩 이어 붙여
#      `error: expected field initializer` 가 났다. `zig ast-check` 가 초 단위로 잡는다.
#
# **한계 — 이 둘 밖은 못 본다.** 중간 커밋이 다른 이유로 게이트를 깨는 경우(경계 위반을 넣었다가 뒤
# 커밋에서 고침, 충돌 마커를 넣었다가 지움)는 안 잡힌다. 그것까지 보려면 커밋마다 빌드해야 하고 그
# 비용이 위와 같다. **좁힌 채로 "전부 봤다" 고 말하지 않는 것**이 이 주석의 목적이다.
#
# 사용법: sh tools/ci/per-commit-boundaries.sh <base-sha> <head-sha>
# 종료 코드: 0 = 통과, 1 = 빨간 커밋 있음, 2 = 범위를 해석할 수 없음
set -eu

BASE="${1:?base sha required}"
HEAD_SHA="${2:?head sha required}"
LEDGER="tests/boundary/external_source_digests.zig"

# **범위를 못 읽으면 시끄럽게 죽는다.** 앞 판은 `|| true` 로 삼켰고, 그래서 얕은 클론(CI 기본 depth=1)에서
# `fatal: Invalid revision range` 가 "중간 커밋 없음" 으로 둔갑해 **항상 무동작·항상 초록**이었다.
# 조용히 열리는 게이트는 없는 게이트보다 나쁘다 — 있다고 믿게 만들기 때문이다.
for rev in "$BASE" "$HEAD_SHA"; do
  if ! git rev-parse --verify --quiet "$rev^{commit}" >/dev/null; then
    echo "범위를 해석할 수 없다: '$rev' 가 이 클론에 없다." >&2
    echo "CI 라면 checkout 의 fetch-depth 가 얕다는 뜻이다 — check job 에 fetch-depth: 0 이 필요하다." >&2
    exit 2
  fi
done

WATCHED="$(sed -n 's/.*\.path = "\([^"]*\)".*/\1/p' "$LEDGER" | sort -u)"
COMMITS="$(git rev-list --reverse "$BASE..$HEAD_SHA")"
# `mktemp -t X` 는 `X.XXXX` 를 만든다 — 거기에 `.zig` 를 덧붙이면 **원본 스텁이 남는다**(적대적 검증이
# TMPDIR 에서 실측: 7회 호출에 11 → 18). 디렉터리를 만들고 그 안에 이름을 두면 하나만 지우면 된다.
tmp_dir="$(mktemp -d)"
tmp_zig="$tmp_dir/probe.zig"
trap 'rm -rf "$tmp_dir"' EXIT INT TERM
[ -n "$COMMITS" ] || { echo "빈 범위 — 볼 커밋이 없다."; exit 0; }

failed=0
seen_watched=0   # 앞선 커밋이 원장이 보는 파일을 건드렸는가(①의 전제)
checked=0

for sha in $COMMITS; do
  checked=$((checked + 1))
  short="$(git rev-parse --short "$sha")"
  touched="$(git diff-tree --no-commit-id --name-only -r -m --first-parent "$sha")"
  [ -n "$touched" ] || continue

  # ① 원장만 고치는 커밋
  if [ "$(printf '%s\n' "$touched")" = "$LEDGER" ] && [ "$seen_watched" -eq 1 ]; then
    echo "FAIL $short — **원장만 고치는 커밋**이다."
    echo "     앞 커밋이 원장이 보는 파일을 건드렸는데 수렴을 여기로 미뤘다 → 그 사이 커밋들이 빨갛다."
    echo "     고치는 법: 이 커밋을 그 소스 커밋에 fixup 으로 접는다(\`git rebase -i\`)."
    failed=$((failed + 1))
  fi

  # ② 파싱 안 되는 .zig
  for f in $touched; do
    case "$f" in *.zig) ;; *) continue ;; esac
    git cat-file -e "$sha:$f" 2>/dev/null || continue   # 그 커밋에서 지워진 파일
    # `ast-check` 는 파일 인자를 받는다(stdin 을 안 받는다) — 그 커밋의 내용을 임시 파일로 꺼내 본다.
    git show "$sha:$f" > "$tmp_zig"
    if ! out="$(zig ast-check "$tmp_zig" 2>&1)"; then
      echo "FAIL $short — \`$f\` 가 파싱되지 않는다(그 커밋에서 \`zig build\` 가 무엇이든 실패한다)."
      printf '%s\n' "$out" | head -2 | sed 's/^/     /'
      failed=$((failed + 1))
    fi
  done

  # 다음 커밋의 ① 판정을 위해, 이 커밋이 원장이 보는 파일을 건드렸는지 기억한다.
  for path in $WATCHED; do
    if printf '%s\n' "$touched" | grep -qxF "$path"; then seen_watched=1; break; fi
  done
done

echo ""
echo "커밋 $checked 개를 봤다(원장만 고치는 커밋 · 파싱 안 되는 .zig)."
[ "$failed" -eq 0 ] || exit 1
exit 0
