#!/bin/sh
# 테스트 픽스처가 `/tmp` 에 남긴 자리를 거둔다 — **주인이 죽은 것만**.
#
# ## 왜 필요한가
#
# session host 픽스처는 `/tmp/maru-<이름>-<pid>` 를 만들고 그 안에 daemon 을 띄운다. daemon 은 owner lock·
# incidents·manifest·소켓을 남기므로 `rmdir` 로는 못 지우고, 그 자리가 실행마다 하나씩 쌓인다.
#
# 실측(2026-08-25): 이 저장소를 개발하던 머신의 `/tmp` 에 그런 자리가 **2 만 개 넘게** 있었고, 표본 200 개
# 중 146 개가 **비어 있지 않았다**(소켓·lock·manifest 를 든 채).
#
# 쌓이는 것 자체보다 **pid 재사용**이 문제다. 같은 번호를 받은 다음 실행이 «이미 채워진» 디렉터리에서
# 시작하면, 죽은 manifest 가 «살아 있는 host» 로 읽히거나 stale 소켓·lock 이 정리 사슬을 다른 길로 보낸다.
# 증상은 코드와 무관해 보이는 **간헐 실패**라 진짜 결함과 구분하기 어렵다.
#
# ## 왜 픽스처마다 고치지 않고 도구를 두는가
#
# 남기는 자리가 세 파일이 아니라 **수십 곳**이다(`maru-sh-*`, `maru-e3-*`, `maru-p4-*`, `maru-recovery-*`,
# `maru-admin-cli-*` …). 새 픽스처가 생길 때마다 같은 실수가 되풀이되므로, 각자 고치는 것과 **함께**
# 한곳에서 거두는 그물을 둔다. CI 러너는 매번 새 머신이라 이 도구가 필요 없다 — 개발 머신용이다.
#
# ## 안전
#
# - `maru-<숫자>`(예: `maru-501`)는 **실 세션 host 의 루트**다(uid 기반). 절대 건드리지 않는다 —
#   지우면 사용자의 살아 있는 keep-alive 세션이 통째로 사라진다.
# - 이름 끝의 pid 가 **살아 있으면 남긴다**. 지금 돌고 있는 테스트의 자리일 수 있다.
# - `--dry-run` 이 기본이 아니다. 지우기 전에 무엇을 지울지 세어 보고 싶으면 `--dry-run` 을 준다.
set -u

dry_run=0
[ "${1:-}" = "--dry-run" ] && dry_run=1

removed=0
kept_alive=0
kept_guard=0

for path in /tmp/maru-*; do
  [ -d "$path" ] || continue
  name=${path#/tmp/}

  # `maru-<숫자>` = 실 세션 host 루트. 손대지 않는다.
  case "$name" in
    maru-*[!0-9-]*) ;;            # 숫자·하이픈 말고 다른 글자가 있으면 픽스처 후보
    *) kept_guard=$((kept_guard + 1)); continue ;;
  esac

  # **뒤에서부터** 숫자뿐인 칸을 찾는다. 픽스처 이름이 세 모양이라 그렇다:
  #   maru-sh-spawn-1234                        (끝이 pid)
  #   maru-admin-cli-1234-<hex>                 (pid 뒤에 nonce)
  #   maru-upgrade-owner-1234-second-exec-fail  (pid 뒤에 설명 꼬리)
  # 끝만 보면 뒤 둘을 놓친다(실측: 그 이름으로 570 개가 남아 있었다).
  #
  # ⚠️ 앞선 두 시도가 다 틀렸다 — `sed -E` 의 non-greedy(`*?`)는 **BSD sed 가 거부**하고(macOS 기본),
  # `IFS` 분해는 호출 문맥에 따라 흔들렸다. 파라미터 확장만 쓰면 그 둘 다 피한다.
  # 두 경우 모두 pid 를 «못 읽음» 으로 떨어져 **아무것도 안 지웠다** — 이 스크립트의 fail-safe 가
  # 그 방향으로 설계돼 있어서다(모르면 남긴다).
  pid=""
  cand=$name
  while [ "$cand" != "${cand%-*}" ]; do
    last=${cand##*-}
    case "$last" in
      ''|*[!0-9]*) cand=${cand%-*} ;;
      *) pid=$last; break ;;
    esac
  done
  case "$pid" in
    ''|*[!0-9]*) kept_guard=$((kept_guard + 1)); continue ;;   # pid 를 못 읽으면 남긴다
  esac

  if kill -0 "$pid" 2>/dev/null; then
    kept_alive=$((kept_alive + 1))
    continue
  fi

  if [ "$dry_run" -eq 1 ]; then
    removed=$((removed + 1))
  else
    rm -rf "$path" && removed=$((removed + 1))
  fi
done

if [ "$dry_run" -eq 1 ]; then
  echo "지울 것 $removed 개 (살아 있어 남김 $kept_alive, 가드로 남김 $kept_guard) — --dry-run"
else
  echo "거둠 $removed 개 (살아 있어 남김 $kept_alive, 가드로 남김 $kept_guard)"
fi
