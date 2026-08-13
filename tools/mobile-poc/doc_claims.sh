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

echo "§3.1 IME 가 입력을 고쳐 쓰지 못한다"
# 선언이 **없으면** OS 기본값(글 쓰기용)이 붙는다 — 없는 것을 세야 하므로 grep 하나로는 못
# 잡는다. iOS 는 여섯 traits 를 다 끄고, Android 는 제안을 끈다.
ck "iOS traits 여섯 개" 6 "$(grep -cE 'UITextAutocapitalizationTypeNone|UITextAutocorrectionTypeNo|UITextSpellCheckingTypeNo|UITextSmartQuotesTypeNo|UITextSmartDashesTypeNo|UITextSmartInsertDeleteTypeNo' $I)"
ck "Android NO_SUGGESTIONS" 1 "$(grep -c 'TYPE_TEXT_FLAG_NO_SUGGESTIONS' src/platform/android/MaruActivity.java)"

echo "§3.1 판단은 코어가 한다"
# 계약이 "뜻은 코어가 정한다" 고 적어 놨는데 host 가 스크롤·선택을 직접 부르면 그 말이
# 거짓이 된다. host 는 원시 포인터만 넘겨야 한다 — 관성(`maru_mobile_scroll`)은 예외다.
ck "host 가 선택 API 를 직접 부르지 않는다" 0 "$(grep -cE 'maru_mobile_(selection_clear|select)' $I $A | awk -F: '{s+=$2} END{print s+0}')"
ck "두 host 다 포인터를 넘긴다" 2 "$(grep -l maru_mobile_pointer $I $A | wc -l | tr -d ' ')"
# 길게 누름 지연은 OS 값이다 — 코어에 박으면 플랫폼 차이와 접근성 설정을 지운다.
ck "두 host 다 OS 값을 넘긴다" 2 "$(grep -l maru_mobile_set_long_press_ms $I $A | wc -l | tr -d ' ')"

echo "문서가 자기 자신과 모순되지 않는가"
# 슬라이스마다 절을 **고쳐야** 하는데 같은 제목으로 새로 **붙인** 적이 있다. 그러면 한
# 문서에 반대되는 두 문장이 남고("키는 코어의 인코더를 탄다" ↔ "아직 안 탄다") 어느 쪽이
# 참인지 문서만 봐서는 모른다. 제목과 굵은 첫 문장이 겹치는지로 잡는다.
D=docs/mobile-platform.md
ck "제목 중복" 0 "$(grep -E '^#{2,4} ' $D | sort | uniq -d | wc -l | tr -d ' ')"
ck "굵은 첫 문장 중복" 0 "$(grep -oE '^\*\*[^*]{10,60}' $D | sort | uniq -d | wc -l | tr -d ' ')"

echo "계획 ↔ 계약 슬라이스 참조"
for m in M4a2 M4a3 M4a4 M4a5 M10; do
  ck "$m 이 계획 표에 있다" 1 "$(grep -cE "^\| $m \|" docs/plans/mobile-platform.md)"
done
