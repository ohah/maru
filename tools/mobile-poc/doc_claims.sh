#!/bin/sh
# 계약 문서가 하는 **검증 가능한 주장**을 코드로 대조한다. "문서를 건드렸다" 와
# "문서가 맞다" 는 다른 얘기라, 주장마다 판정자를 붙인다.
cd /Users/yoonhb/Documents/workspace/maru/.claude/worktrees/cim4b-tab-drag || exit 1
B=src/platform/mobile/mobile_bridge.zig
H=src/platform/mobile/mobile_host_abi.h
I=src/platform/ios/ios_app_host.m
A=src/platform/android/android_app_host.c

ck() { # 이름, 기대, 실제
  if [ "$2" = "$3" ]; then printf "  OK   %-42s %s\n" "$1" "$3"
  else printf "  틀림 %-42s 기대=%s 실제=%s\n" "$1" "$2" "$3"; fi
}

echo "§3 브리지에 OS 호출이 없다"
ck "브리지의 @cImport/OS import" 0 "$(grep -cE '@cImport|std\.os\.|std\.posix\.' $B)"

echo "§5 조용히 실패하지 않는다"
ck "브리지의 catch {} 개수" 0 "$(grep -c 'catch {}' $B)"
ck "두 host 가 last_error 를 읽고 비운다" 2 "$(grep -l maru_mobile_clear_error $I $A | wc -l | tr -d ' ')"

echo "§4 셀 기하·글자 크기 단일 출처"
ck "헤더의 TEXT_PX 정의" 1 "$(grep -c 'define MARU_ATLAS_TEXT_PX' $H)"
ck "host 에 남은 하드코딩 22" 0 "$(grep -cE '(jfloat)22\.0f|CFSTR\("Menlo"\), 22|, 22, NULL\)' $I $A | awk -F: '{s+=$2} END{print s+0}')"

echo "§3 상한은 코어가 답한다"
ck "host 에 남은 quad 상한 하드코딩" 0 "$(grep -cE 'quad_cap = [0-9]|_quadCap = [0-9]' $I $A | awk -F: '{s+=$2} END{print s+0}')"

echo "ABI 헤더 ↔ Zig export"
h=$(grep -oE 'maru_mobile_[a-z_]+' $H | sort -u | md5)
z=$(grep -oE '^pub export fn maru_mobile_[a-z_]+' $B | grep -oE 'maru_mobile_[a-z_]+' | sort -u | md5)
ck "선언 집합 해시" "$h" "$z"

echo "문서에 낡을 값이 없는가"
ck "매트릭스에 테스트 개수 하드코딩" 0 "$(grep -c 'mobile_bridge_contract.zig`([0-9]*개)' docs/verification-matrix.md)"

echo "계획 ↔ 계약 슬라이스 참조"
for m in M4a2 M4a3 M4a4 M4a5 M10; do
  ck "$m 이 계획 표에 있다" 1 "$(grep -cE "^\| $m \|" docs/plans/mobile-platform.md)"
done
