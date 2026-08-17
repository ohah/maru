#!/usr/bin/env sh
# `.zig-cache` 를 **예산 안으로** 줄인다. CI 가 캐시를 저장하기 **직전에** 부른다.
#
# **왜 필요한가.** 이 캐시는 빌드마다 `o/<hash>` 디렉터리가 쌓여 시간이 갈수록 커진다.
# 2026-08-16 에 `session host macOS (Debug)` 캐시가 5GB → 6GB 가 되자, 그것을 **복원하던**
# PR 들이 GitHub 호스티드 macOS 러너에서 연달아 죽었다:
#
#   System.IO.IOException: No space left on device
#     : '/Users/runner/actions-runner/cached/_diag/Worker_....log'
#
# 러너가 **자기 로그조차 못 쓰는** 상태라 테스트 실패처럼 안 보이고, 실패 단계도
# `actions/cache/restore` 라 원인이 한눈에 안 들어온다(세 번 재실행하고서야 찾았다).
# 캐시를 지우면 그 순간은 풀리지만 **다음 main 저장에서 재발**하므로, 저장 쪽에 상한을 둔다.
#
# **오래된 것부터 지운다.** `o/` 는 빌드 산출물이라 최근 것이 다음 빌드에 맞을 확률이 높다.
# 지워도 정확성 문제는 없다 — 캐시 미스는 다시 빌드할 뿐이다.
set -eu

budget_mb=${1:-3072}
cache=${2:-.zig-cache}

[ -d "$cache" ] || { echo "prune: $cache 없음 — 할 일 없다"; exit 0; }

size_mb() { du -sm "$1" 2>/dev/null | awk '{print $1}'; }

before=$(size_mb "$cache")
if [ "$before" -le "$budget_mb" ]; then
  echo "prune: ${before}MB ≤ 예산 ${budget_mb}MB — 그대로 둔다"
  exit 0
fi

# **오래된 것부터**: `ls -t` 는 새것이 먼저라 뒤집는다. `tail -r`(BSD)·`tac`(GNU) 둘 다 지원한다
# — 이 스크립트는 macOS 러너와 ubuntu 러너에서 같이 돈다.
reverse() { tail -r 2>/dev/null || tac; }

for d in $(ls -dt "$cache"/o/* 2>/dev/null | reverse); do
  cur=$(size_mb "$cache")
  [ "$cur" -le "$budget_mb" ] && break
  rm -rf "$d"
done

after=$(size_mb "$cache")
# **숫자를 남긴다.** 다음에 또 커지면 로그에서 바로 보인다 — 이번에는 그 숫자가 없어서
# 캐시 목록을 손으로 뒤져야 했다.
echo "prune: ${before}MB → ${after}MB (예산 ${budget_mb}MB)"
