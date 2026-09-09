#!/bin/sh
# 계약 문서가 하는 **검증 가능한 주장**을 코드로 대조한다. "문서를 건드렸다" 와
# "문서가 맞다" 는 다른 얘기라, 주장마다 판정자를 붙인다.
# 저장소 루트는 **스크립트 위치에서** 찾는다. 절대경로를 박으면 그 체크아웃이 사라진 순간
# 판정자가 통째로 안 돈다(실제로 워크트리를 지우자 한 줄도 못 돌았다).
cd "$(dirname "$0")/../.." || exit 1
B=src/platform/mobile/mobile_bridge.zig
# SSH ABI 는 별도 파일이지만 **같은 계약 아래 있다** — OS 호출 0·조용한 catch 0·헤더 대조를
# 똑같이 받는다. 여기 안 적으면 새 파일만 규칙 밖에 선다.
S=src/platform/mobile/mobile_ssh.zig
H=src/platform/mobile/mobile_host_abi.h
I=src/platform/ios/ios_app_host.m
A=src/platform/android/android_app_host.c
# 하네스 스크립트도 계약의 일부다 — 개발 빌드에만 켜는 자리가 거기다(M11a).
H_RUN=tools/mobile-harness/run.sh
# Android 는 Java 도 host 다 — Keystore 를 여는 자리가 거기다(계약 §3.4).
J=src/platform/android/MaruActivity.java
K=src/platform/android/MaruKeyStore.java
V=src/platform/android/MaruSshService.java
N=src/platform/android/AndroidManifest.xml

# **틀린 것을 센다.** 예전에는 출력만 하고 항상 0 으로 끝나, 판정자가 전부 틀려도 이 스크립트를
# 부르는 쪽은 성공으로 봤다 — 게이트가 아니라 구경거리였다.
bad=0
ck() { # 이름, 기대, 실제
  if [ "$2" = "$3" ]; then printf "  OK   %-42s %s\n" "$1" "$3"
  else printf "  틀림 %-42s 기대=%s 실제=%s\n" "$1" "$2" "$3"; bad=$((bad+1)); fi
}

echo "§3 브리지에 OS 호출이 없다"
ck "브리지의 @cImport/OS import" 0 "$(grep -cE '@cImport|std\.os\.|std\.posix\.' $B $S | awk -F: '{s+=$2} END{print s+0}')"

echo "§5 조용히 실패하지 않는다"
# `catch {}` 만 세면 `catch return` 이 그대로 빠져나간다 — **연산을 끝내 버리는** 형태를 전부 본다.
# `catch null` 은 세지 않는다: 그건 끝내는 게 아니라 **호출자가 검사해야 하는 값**을 돌려주는
# 것이고, 실제로 그 자리(`keyFromId`)의 호출자가 `key_unknown_id` 를 남긴다. 오류를 남기고 도는
# `catch { setLastError(...) ... }` 는 블록이 비지 않으므로 안 걸린다.
ck "브리지의 조용한 catch" 0 "$(grep -cE 'catch \{\}|catch return' $B $S | awk -F: '{s+=$2} END{print s+0}')"
ck "두 host 가 last_error 를 읽고 비운다" 2 "$(grep -l maru_mobile_clear_error $I $A | wc -l | tr -d ' ')"

# **컨트롤 축은 새 연결이면 처음부터다**(계약 §4a). 이 호출이 빠지면 끊겼다 다시 붙었을 때
# **죽은 세션 목록이 살아 있는 것처럼** 남는다 — 화면만 보고는 그것이 낡은 값인지 알 수 없다.
# 점검에서 실제로 두 host 가 안 부르고 있었다(2026-08-22).
ck "두 host 가 컨트롤 축을 새 연결에서 재설정한다" 2 "$(grep -l maru_mobile_control_reset $I $A | wc -l | tr -d ' ')"
# 컨트롤 채널을 여는 쪽도 둘 다여야 한다 — 한쪽만 있으면 그 기기에서만 목록이 안 뜬다.
ck "두 host 가 컨트롤 채널을 연다" 2 "$(grep -l maru_ssh_pump_open_control $I $A | wc -l | tr -d ' ')"
# **원격 명령이 그냥 끝난 것은 시한과 다른 말이다**(계약 §4a). 이 보고가 빠지면 `maru` 경로가
# 안 잡힌 기계가 "답이 없다" 로만 뜨고, 종료 코드는 pump 가 들고 있는데 아무도 안 읽는다 —
# 실제로 그 화면을 두 번 오진했다(2026-08-23).
ck "두 host 가 exec 종료를 코어에 알린다" 2 "$(grep -l "maru_mobile_control_note_exit_at(" $I $A | wc -l | tr -d ' ')"
# **순서·가드는 이제 코어가 정한다**(계약 §4a). 예전에는 host 가 채널 상태를 보고 «스스로» 열기를
# 집었는데, 그 순서가 뒤집혀 「열고 그 자리에서 닫기」를 무한히 되풀이했다(실기 2026-09-04).
# 지금은 행동을 하나만 받는다 — 그 자리가 두 host 에 다 있어야 한다.
ck "두 host 가 코어에서 행동을 받는다" 2 "$(grep -l "maru_mobile_control_tick(" $I $A | wc -l | tr -d ' ')"
# 열기 결과의 분류(「아직 때가 아니다」 vs 「졌다」)도 코어 것이다 — host 는 알리기만 한다.
ck "두 host 가 열기 결과를 코어에 알린다" 2 "$(grep -l "maru_mobile_control_note_open(" $I $A | wc -l | tr -d ' ')"

echo "§4 셀 기하·글자 크기 단일 출처"
ck "헤더의 TEXT_PX 정의" 1 "$(grep -c 'define MARU_ATLAS_TEXT_PX' $H)"
ck "host 에 남은 하드코딩 22" 0 "$(grep -cE '\(jfloat\)22\.0f|CFSTR\("Menlo"\), 22|, 22, NULL\)' $I $A | awk -F: '{s+=$2} END{print s+0}')"

echo "§3 상한은 코어가 답한다"
ck "host 에 남은 quad 상한 하드코딩" 0 "$(grep -cE 'quad_cap = [0-9]|_quadCap = [0-9]' $I $A | awk -F: '{s+=$2} END{print s+0}')"

# **인터프리터 이름을 박지 않는다.** Windows 에는 `python3` 가 없다 — mise 가 깔아 주는 것도
# `python` 이다(실측). 박아 두면 이 판정 셋이 `127`(command not found)로 죽는데, 그 값이 «판정이
# 틀렸다» 와 **똑같은 모양**이라 게이트가 상시 빨간 채로 아무도 못 알아본다(§2m.109).
PY=python3
command -v "$PY" >/dev/null 2>&1 || PY=python
command -v "$PY" >/dev/null 2>&1 || { echo "FAIL: python3/python 둘 다 없다"; exit 1; }

echo "ABI 헤더 ↔ Zig export 타입"
# 이름 집합만 대조하면 **타입이 어긋나도 C 는 컴파일되고 값만 조용히 깨진다**
# (u32 자리에 u64, 포인터 자리에 정수 같은 것).
# 숫자가 아니라 **종료 코드**를 본다(아래 키 판정과 같은 이유 — 판정 축이 늘면 숫자 하나로는 샌다).
"$PY" "$(dirname "$0")/abi_types.py" > /tmp/maru_abi.$$ 2>&1
ck "ABI 타입" 0 "$?"
grep -E "^  (없음|다름|모름)" /tmp/maru_abi.$$ || true
rm -f /tmp/maru_abi.$$

echo "ABI 헤더 ↔ Zig export"
# **`md5` 는 macOS 전용이다** — Linux 에서는 없어서 양쪽이 **빈 값으로 같아져** 항상 통과했다.
# 해시가 필요한 것도 아니다(집합 비교면 충분하고, 다를 때 무엇이 다른지도 보인다).
# **선언 줄만 본다.** 전에는 파일 전체에서 이름을 긁어 **주석에 적힌 이름까지 선언으로 셌다** —
# 선언을 지우고 그 이름을 주석에 남기면 집합이 그대로라 **거짓 통과**한다(실제로 겪었다).
# 선언은 열 0 에서 반환형으로 시작하는 줄이다(`void maru_mobile_x(...);`).
# 반환형은 소문자만이 아니다(`const MaruQuad *maru_mobile_quads(void);`) — 실제로 이 하나를
# 놓쳐 집합이 어긋났다.
# **이름에 숫자가 들 수 있다**(`maru_mobile_a11y_*`). `[a-z_]+` 로 훑으면 `maru_mobile_a` 에서
# 잘려 두 집합이 어긋나고, 게이트가 **없는 불일치**를 알린다(2026-09-06 실측).
h=$(grep -E '^[A-Za-z_][A-Za-z0-9_ ]*\*? *maru_mobile_[a-z0-9_]+\(' $H | grep -oE 'maru_mobile_[a-z0-9_]+' | sort -u)
z=$(grep -hoE '^pub export fn maru_mobile_[a-z0-9_]+' $B $S | grep -oE 'maru_mobile_[a-z0-9_]+' | sort -u)
ck "선언 집합" "$(printf '%s' "$h" | wc -l | tr -d ' ')" "$(printf '%s' "$z" | wc -l | tr -d ' ')"
if [ "$h" != "$z" ]; then
  printf "  틀림 %-42s\n" "선언 집합이 다르다 — 한쪽에만 있는 것:"
  printf '%s\n%s\n' "$h" "$z" | sort | uniq -u | sed 's/^/         /'
  bad=$((bad+1))
fi

echo "문서에 낡을 값이 없는가"
ck "매트릭스에 테스트 개수 하드코딩" 0 "$(grep -c 'mobile_bridge_contract.zig`([0-9]*개)' docs/verification-matrix.md)"

echo "§3.1 IME 가 입력을 고쳐 쓰지 못한다"
# 선언이 **없으면** OS 기본값(글 쓰기용)이 붙는다 — 없는 것을 세야 하므로 grep 하나로는 못
# 잡는다. iOS 는 여섯 traits 를 다 끄고, Android 는 제안을 끈다.
ck "iOS traits 여섯 개" 6 "$(grep -cE 'UITextAutocapitalizationTypeNone|UITextAutocorrectionTypeNo|UITextSpellCheckingTypeNo|UITextSmartQuotesTypeNo|UITextSmartDashesTypeNo|UITextSmartInsertDeleteTypeNo' $I)"
ck "Android NO_SUGGESTIONS" 1 "$(grep -c 'TYPE_TEXT_FLAG_NO_SUGGESTIONS' src/platform/android/MaruActivity.java)"

echo "§5 안전 영역은 네 변 다"
# **좌우를 빠뜨리면 곡면 화면에서 양끝 글자가 모서리에 말린다** — 홀펀치·평면 기기에서는 그
# 값이 0 이라 아무 차이가 없어 **안 드러난 채 오래 잠복한다**(그래서 기기로 못 본다. 판정자가
# 유일한 방벽이다). iOS 는 `safeAreaInsets` 로 넷을 다 쓰고 있었고 Android 만 위·아래였다.
# **선언이 아니라 읽는 자리를 센다** — `got_left = 0` 같은 초기화까지 세면 실제 조회를 지워도
# 수가 그대로다(변이로 확인했다).
ck "Android 가 네 변을 다 읽는다" 4 "$(grep -c 'GetFieldID(env, boxCls, "' $A)"
# **빼는 것은 이제 코어다**(`maru_mobile_available_logical`). 예전에는 두 host 가 각자 뺐고
# 「키보드가 하단 inset 을 덮으니 두 번 빼지 않는다」가 iOS 의 ObjC 와 Android 의 Java 에
# **각자** 적혀 있었다 — 같은 사실이 두 자리면 한쪽만 고쳐진다. 그래서 세는 것도 옮긴다:
# 두 host 가 그 함수에 **네 변을 다 넘기는가**.
ck "두 host 가 가용 크기를 코어에 묻는다" 2 "$(grep -l 'maru_mobile_available_logical(' $I $A | wc -l | tr -d ' ')"
ck "Android 가 좌우 inset 을 코어로 넘긴다" 1 "$(grep -c 'g.inset_left, (unsigned int)g.inset_right' $A)"
ck "Android 가 좌측만큼 그림을 민다" 1 "$(grep -c 'float ox = (float)g.inset_left;' $A)"
# **그리는 자리와 누르는 자리가 같아야 한다** — 폭만 줄이고 터치를 안 옮기면 오른쪽 끝이 안 눌린다.
ck "Android 터치 x 가 좌측 inset 을 뺀다" 0 "$(grep -cE 'AMotionEvent_getX\(ev, [0-9a-z]+\) / g.scale' $A)"

echo "§3.1 한 제스처의 뜻은 상태 하나가 든다"
# **조합으로 되돌아가지 못하게 한다.** 전에는 표면마다 `active`·`moved`·`stop_tap`·`pressed` 를
# 따로 들고 "탭이다" 를 자리마다 새로 만들었다 — 한 자리에서 한 항을 빠뜨려도 컴파일도 테스트도
# 통과하고, 실제로 그 조합 하나가 톱니 판정으로 새어 설정이 안 열렸다.
# 넷에서 **다섯**이 됐다 — 터미널 앱 바가 생겼다(A). 일곱은 서버 목록·서버 편집(S9b-2b),
# **여덟**은 비밀번호 묻는 화면(S6a-2), **아홉**은 지문 승인 화면(S9b-3), **열**은 진단 화면(M15a)이다.
# 표면이 늘면 이 수도 같이 는다.
ck "표면마다 제스처 상태 하나" 10 "$(grep -c 'gesture.Press = .{}' $B)"
ck "브리지에 남은 손수 제스처 상태" 0 "$(grep -cE '^var (set_active|set_stop_tap|set_moved|kb_stop_tap|kb_moved|ptr_down|ptr_moved|selecting)' $B)"
# 임계가 다시 갈리면 같은 손짓이 표면마다 다르게 판정된다 — 한때 같은 10 이 세 곳에 있었다
# (`slop_px` · 설정의 매직 10 · `long_press_slop`).
ck "슬롭의 단일 출처" 1 "$(grep -c 'pub const slop_px' src/chrome/ui/scroll_area.zig)"
ck "브리지에 박힌 슬롭 상수" 0 "$(grep -cE 'slop.*(f32|:) *= *[0-9]' $B)"
# 컴포넌트가 소비처 없이도 CI 에서 돌아야 한다 — `refAllDecls` 는 한 단계라 `ui` 를 따로 ref
# 하지 않으면 **테스트를 써 놔도 집계 밖**이다(`gesture` 12개가 실제로 그랬다).
ck "ui 네임스페이스를 집계한다" 1 "$(grep -c 'testing.refAllDecls(ui);' src/chrome.zig)"

echo "§3.1 판단은 코어가 한다"
# 계약이 "뜻은 코어가 정한다" 고 적어 놨는데 host 가 스크롤·선택을 직접 부르면 그 말이
# 거짓이 된다. **예외가 없어졌다** — 관성이 코어로 오면서 `maru_mobile_scroll` 을 부르는 host 가
# 사라졌고, 그래서 그 선언을 헤더에서 내렸다. 지금 host 가 넣는 것은 원시 포인터뿐이다.
ck "host 가 선택 API 를 직접 부르지 않는다" 0 "$(grep -cE 'maru_mobile_(selection_clear|select)' $I $A | awk -F: '{s+=$2} END{print s+0}')"
ck "host 가 스크롤을 직접 부르지 않는다" 0 "$(grep -c 'maru_mobile_scroll(' $I $A | awk -F: '{s+=$2} END{print s+0}')"
ck "헤더에 스크롤 델타 진입점이 없다" 0 "$(grep -c '^void maru_mobile_scroll(' $H)"
ck "두 host 다 포인터를 넘긴다" 2 "$(grep -l maru_mobile_pointer $I $A | wc -l | tr -d ' ')"
# 길게 누름 지연은 OS 값이다 — 코어에 박으면 플랫폼 차이와 접근성 설정을 지운다.
ck "두 host 다 OS 값을 넘긴다" 2 "$(grep -l maru_mobile_set_long_press_ms $I $A | wc -l | tr -d ' ')"

echo "§3.2 주기는 기기 주사율과 무관하다"
# **vsync 를 세면 그건 30Hz 가 아니라 패널의 절반이다** — 90Hz 폰에서 45, 120Hz 에서 60 이
# 나온다. 60Hz 에뮬레이터에서는 우연히 맞아떨어져 `MARU_PACE` 도 PASS 라, 이 부류는 코드
# 모양으로 막는 수밖에 없다(실기기가 붙기 전까지).
ck "Android 가 vsync 를 세지 않는다" 0 "$(grep -cE 'vsync_count' $A)"
# **시각을 버리면 다시 세는 수밖에 없다.** 전에 `(void)frame_time_ns;` 로 버려 두고 vsync 를
# 셌다 — 위 조건만으로는 이름을 바꿔 다시 세는 것을 못 막으므로 쓰는 쪽도 못박는다.
ck "Android 가 vsync 시각을 버리지 않는다" 0 "$(grep -c '(void)frame_time_ns' $A)"
ck "iOS 가 OS 에 주기를 선언한다" 1 "$(grep -c 'preferredFrameRateRange =' $I)"
# 주기는 정책 하나인데 host 두 곳에 Hz·ns·ms·PASS창 네 표현으로 흩어져 있었다. 셀 기하와
# 같은 규율로 **헤더가 단일 출처**다 — host 에 남은 날 숫자가 0 이어야 한다.
ck "헤더의 주기 정의" 1 "$(grep -c 'define MARU_FRAME_TARGET_HZ' $H)"
ck "host 에 남은 주기 하드코딩" 0 "$(grep -cE '33333333|target=33\.33|>= 25\.0|<= 42\.0' $I $A | awk -F: '{s+=$2} END{print s+0}')"
# **판정 기준이 같아도 재는 방식이 다르면 두 수를 나란히 못 놓는다.** Android 만 첫 프레임을
# 버리고 iOS 는 안 버려, 같은 이름의 로그가 다른 것을 재고 있었다. 표본 수·워밍업도 헤더가
# 소유하고, host 에 제 것을 다시 두지 않는다.
ck "헤더의 표본 정의" 2 "$(grep -cE 'define MARU_FRAME_PACE_(WARMUP|SAMPLES)' $H)"
ck "host 에 남은 표본 하드코딩" 0 "$(grep -cE 'define PACE_(SAMPLES|WARMUP)|_paceMs\[60\]|_paceN < 60|n=60' $I $A | awk -F: '{s+=$2} END{print s+0}')"
ck "두 host 다 워밍업을 버린다" 2 "$(grep -l MARU_FRAME_PACE_WARMUP $I $A | wc -l | tr -d ' ')"
ck "두 host 다 같은 표본 수를 쓴다" 2 "$(grep -l MARU_FRAME_PACE_SAMPLES $I $A | wc -l | tr -d ' ')"
# **중앙값 색인을 손으로 적으면 표본 수를 바꿀 때 한쪽만 조용히 틀린 값을 읽는다**(iOS 가
# `_paceMs[30]` 이었다). 상수에서 파생시킨다.
ck "중앙값 색인이 파생이다" 2 "$(grep -cE 'MARU_FRAME_PACE_SAMPLES / 2' $I $A | awk -F: '{s+=$2} END{print s+0}')"
# `Info.plist` 는 번들에 박히는 **능력 선언**이라 config 로 못 켠다. 주기를 config(M10)로
# 열 때 이 키가 없으면 ProMotion 기기에서 조용히 60 으로 잘린다 — 그래서 미리 켜 둔다.
# **제품 자리를 본다**(M11a). 예전에는 하네스 폴더의 템플릿을 봤는데, 그것은 번들에 박히는 앱
# 소스라 그 폴더에 있으면 안 되고(그 폴더의 규율이다) 무엇보다 **제품 번들을 따로 만드는 순간
# 판정자는 초록인데 번들에서만 키가 빠진다**. 자리가 하나면 갈릴 수가 없다.
ck "주기 상한 해제가 번들 템플릿에 있다" 1 "$(grep -c 'CADisableMinimumFrameDuration' src/platform/ios/Info.plist.in)"
ck "하네스는 번들 템플릿 사본을 안 갖는다" 0 "$(ls tools/mobile-harness/Info.plist.in 2>/dev/null | wc -l | tr -d ' ')"

echo "§관성 — 숫자가 갈리지 않는다"
# **관성은 코어 한 곳에서 돈다.** 본문·키바·설정이 같은 값으로 흘러야 하고(다르면 사용자는
# 이유를 모른다), 그 값은 `scroll_area.Touch` 가 갖는다. host 가 자기 관성을 들면 목적지를
# 몰라 **남의 제스처까지 흘린다** — 실제로 R2 뒤에 키바를 비스듬히 튕기면 본문이 흘렀다.
ck "host 에 관성이 남았나" 0 "$(grep -ciE 'fling(_v|Vy|_t)' $I $A | awk -F: '{s+=$2} END{print s+0}')"
ck "감쇠의 단일 출처" 1 "$(grep -c 'decay_per_ms: f32 = ' src/chrome/ui/scroll_area.zig)"
# **프레임당 감쇠가 다시 생기면 잡는다.** 그것이 30Hz 기기를 두 배 멀리 미끄러뜨렸다.
# **관성이 사는 파일을 같이 본다** — 코드가 브리지로 옮겨왔는데 세는 자리를 안 옮기면, 거기
# 프레임당 감쇠가 다시 생겨도 판정자가 침묵한다(실제로 변이로 확인했다).
ck "프레임당 감쇠가 남았나" 0 "$(grep -cE '\*= *0\.9[0-9]*f? *;' $I $A $B src/chrome/ui/scroll_area.zig | awk -F: '{s+=$2} END{print s+0}')"
ck "코어가 시간으로 감쇠한다" 1 "$(grep -c 'std.math.pow(f32, scroll_area.Touch.decay_per_ms' $B)"
# 이관은 **반쯤 하기가 제일 쉽다** — 실제로 목록만 옮기고 키바·팝업에 손수 스크롤이 남아 있었다.
# 브리지에 f32 스크롤 변수가 다시 생기면 그때부터 규칙이 갈린다.
# `*_max_scroll` 은 레이아웃이 잰 콘텐츠 길이지 스크롤 위치가 아니다 — 그건 남아도 된다.
# `body_fling` 도 예외다: **본문은 ScrollArea 가 될 수 없다.** 키바·설정은 픽셀 오프셋을 옮기는
# 면이지만 본문은 코어의 뷰포트를 **줄 단위**로 옮긴다(`maru_mobile_scroll` 이 px 를 모아 줄로
# 바꾼다) — `Touch.step` 이 쓸 `State.offset_y_px` 가 아예 없다. 대신 감쇠·상한은 같은 곳에서
# 가져다 쓰고, 그것은 위의 "감쇠의 단일 출처" 가 본다.
ck "브리지에 남은 손수 스크롤 상태" 0 "$(grep -E '^var .*(_scroll|_fling): f32' $B | grep -vcE 'max_scroll|body_fling' || true)"
# 슬롭도 감쇠와 같다 — 네 곳에 `10` 이 흩어져 있었다. 컴포넌트가 소유하고 브리지는 읽기만 한다.
ck "브리지에 남은 슬롭 하드코딩" 0 "$(grep -cE '_moved < 1[0-9]\b' $B || true)"

echo "§죽은 chrome — 그리는데 아무도 안 받는 것"
# **13개가 눌러도 아무 일이 없었다**(탭 3·사이드바 5·하단 아이콘 5). 데스크톱 chrome 을 옮겨
# 놓고 배선을 안 한 것이고, 그것이 배칭 판정의 재료로 쓰이며 굳었다(U3a).
#
# 터미널 화면의 트리는 **자리만 잡는다** — 글자 노드를 놓으면 그 라벨을 그릴 경로가 필요하고,
# 그 경로가 없으면 다시 "보이는데 안 눌리는" 것이 된다. 본문·키바·각 화면이 직접 그린다.
ck "터미널 트리에 글자 노드가 없다" 0 "$(grep -c 'tree\.text(' $B)"
# 하드코딩 라벨 배열이 다시 생기면 잡는다(`zsh`/`vim`/`logs`·`maru`/`web`/... 이 그 모양이었다).
ck "브리지에 하드코딩 라벨 배열이 없다" 0 "$(grep -cE 'const [a-z_]+ = \[_\]\[\]const u8\{ *"' $B || true)"

echo "§라우팅 — 목적지는 코어가 든다"
# **host 가 "누가 먹었나" 를 들면 같은 사실이 두 층에 생긴다.** 그러면 정리도 두 곳에서 해야 하고,
# 한쪽을 빠뜨려 "복귀 후 첫 손짓이 통째로 삼켜지는" 결함이 났다 — 같은 모양을 세 번 겪었다.
ck "포인터 진입점이 하나다" 1 "$(grep -c 'pub export fn maru_mobile_.*pointer(' $B)"
ck "헤더에 포인터 진입점이 하나다" 1 "$(grep -c '^void maru_mobile_pointer(' $H)"
# 계약 문서가 옛 함수 이름을 **계약으로** 적고 있으면 안 된다. 헤더/계획 문서는 "전에는
# 이랬다" 를 적을 수 있으므로 대상은 스펙 하나뿐이다 — 실제로 R2 뒤에도 "세 포인터 함수가
# 전부 pointer_id 를 싣는다" 가 남아 있었다.
ck "스펙에 옛 포인터 함수 이름이 없다" 0 "$(grep -c 'keybar_pointer\|chrome_pointer' docs/mobile-platform.md)"
# 주석 속 과거 서술은 안 센다 — 왜 없앴는지 적어 두는 것이 오히려 필요하다.
ck "host 에 남은 라우팅 상태" 0 "$(grep -hE '(chrome|keybar)_active|_(chrome|keybar)Active' $I $A | grep -vcE '^\s*(//|///|\*)' || true)"

echo "§멀티터치 — 손가락을 아무거나 집지 않는다"
# iOS 는 `multipleTouchEnabled` 를 켠 순간부터 `touches` 에 여럿이 들어온다. 그때 `anyObject` 가
# 남아 있으면 **진짜로 임의 선택**이 된다 — 프레임마다 다른 손가락이 잡혀 좌표가 튄다.
# 남겨도 되는 자리는 **제스처가 없을 때 첫 손가락을 고르는 한 곳**뿐이다.
ck "iOS 가 멀티터치를 켠다" 1 "$(grep -c 'multipleTouchEnabled = YES' $I)"
ck "iOS 에 남은 anyObject" 1 "$(grep -c 'touches.anyObject' $I)"
# Android 도 index 0 만 보던 자리가 없어야 한다 — 사건이 가리키는 손가락을 쓴다.
ck "Android 가 사건의 손가락을 쓴다" 1 "$(grep -c 'ACTION_POINTER_INDEX_SHIFT' $A)"
# **배경 전환에 잡음을 다 풀어야 한다.** 뗀 적 없이 끝나는 경우가 그것이고, 하나라도 남으면
# 복귀 후 그 표면이 굳는다(실제로 `_hasBodyPtr` 를 빠뜨려 키바·설정이 안 눌릴 뻔했다).
# **이제 잡음이 아예 없다** — 목적지도 관성도 코어가 드니 host 가 들 상태가 없고, 배경 정리는
# 취소 한 번이다. 그래서 "취소를 보낸다" 만 세고, **host 에 본문 제스처 상태가 없다** 를 같이 본다.
# 두 자리다: `touchesCancelled`(제스처를 OS 가 뺏었다)와 배경 정리(뗀 적 없이 끝난다).
ck "iOS 가 코어에 취소를 보내는 자리" 2 "$(grep -c 'maru_mobile_pointer(3, 0, 0, 0, 0);' $I)"
ck "iOS 에 남은 본문 제스처 상태" 0 "$(grep -cE '_hasBodyPtr|_bodyPtrId' $I)"
# `allTouches` 는 이벤트에 딸린 전부다. 우리 뷰로 안 거르면 남의 터치가 "아직 손가락이 있다" 로
# 읽혀 **마지막 손가락 판정이 틀리고 그 표면이 잡힌 채 굳는다**. 자리는 하나다 —
# 이어받기는 코어가 하므로(`body_slots`) 뷰에는 `anyTouchRemains` 만 남았다.
ck "iOS 가 우리 뷰의 손가락만 센다" 1 "$(grep -c 't.view != self' $I)"

echo "§inset — 컷아웃을 빠뜨리지 않는다"
# `systemBars()` 만 물으면 카메라 홀이 있는 기기에서 짧게 나온다(실측: 홀이 y=64..130 인데 63 을
# 받아 본문 첫 줄들이 구멍 뒤에 깔렸다). 두 값을 함께 물어야 한다.
ck "Android 가 컷아웃도 묻는다" 1 "$(grep -c 'displayCutout' $A)"

echo "§config — 상한은 헤더가 소유한다"
# 페이싱 상수와 같은 규율이다. host 마다 숫자를 적으면 갈린다 — 실제로 갈려 있었다
# (Android 64KB 잘라 쓰기 · iOS 무제한 · 데스크톱 1MB). 그리고 넘치면 **안 읽어야** 한다:
# 자른 앞부분을 쓰면 반만 적용된 설정이 되고 사용자는 무엇이 먹었는지 알 수 없다.
ck "헤더의 config 상한 정의" 1 "$(grep -c 'define MARU_CONFIG_MAX_BYTES' $H)"
ck "두 host 가 그 상한을 쓴다" 2 "$(grep -l MARU_CONFIG_MAX_BYTES $I $A | wc -l | tr -d ' ')"
ck "host 에 남은 config 크기 하드코딩" 0 "$(grep -cE '64 \* 1024|65536' $I $A | awk -F: '{s+=$2} END{print s+0}')"
ck "두 host 가 초과를 거부한다" 2 "$(grep -l 'MARU_CONFIG too_large' $I $A | wc -l | tr -d ' ')"
# 읽는 **시점**도 같아야 한다 — 한쪽만 복귀 때 다시 읽으면 같은 손짓의 결과가 갈린다.
ck "두 host 가 두 번 읽는다(시작·복귀)" 2 "$(grep -cE 'loadConfigFile\(' $I $A | awk -F: '{if ($2>=2) c++} END{print c+0}')"

echo "§아틀라스 — 창이 부서져도 성장분이 남는다"
# **Android 만 창이 부서진다**(iOS 는 UIKit 이 레이어를 살린다). 그때 텍스처는 사라지는데
# 브리지의 등록부는 살아남아 미스가 안 나므로, 원본을 안 들고 있으면 **다시 굽지도 않고
# 영영 빈칸**이 된다. 글자 아틀라스는 `g_glyph_px` 로 그렇게 하고 있었고 컬러만 빠져 있어
# 이모지가 사라졌다(실측). 둘 다 원본이 있어야 하고, 굽는 자리에서 원본에도 써야 한다.
ck "두 아틀라스 다 원본을 든다" 2 "$(grep -cE '^static uint8_t \*g_(glyph|color)_px = NULL;' $A)"
# **딱 한 자리에서만 놓는다 — 다시 굽기.** 격자가 바뀌면 옛 픽셀이 엉뚱한 칸을 가리키므로
# 그때는 버리는 것이 맞고, 그 자리는 **곧바로** 새 원본을 세운다(등록부도 같은 프레임의 build 가
# 비워 이모지가 다시 구워진다). 부서짐 경로에서 놓는 것이 위 결함이었으므로 「0 개」가 아니라
# 「그 한 자리인가」를 묻는다.
ck "컬러 원본을 놓는 자리는 다시 굽기 하나뿐" 1 "$(grep -c 'free(g_color_px)' $A)"
ck "놓은 자리가 곧바로 새 원본을 세운다" 1 "$(grep -A1 'free(g_color_px);' $A | grep -c 'g_color_px = calloc')"
ck "굽는 자리가 두 원본에 다 쓴다" 2 "$(grep -cE 'memcpy\(g_(glyph|color)_px' $A)"

echo "§3.4 키는 첫 실행에 선다 (M16b)"
# **네이티브 스레드는 앱 클래스를 못 찾는다.** 시스템 클래스로더를 보기 때문이다(실측:
# `cls=0x0` + `ClassNotFoundException`) — 그래서 `dev/maru/*` 를 `FindClass` 로 찾는 자리가
# 하나라도 생기면 그 갈래는 **조용히** 안 된다. 첫 실행에 공개키가 안 서던 원인이 그것이었다.
# `android/*` 는 시스템 클래스라 괜찮으므로 여기서는 `dev/` 만 본다.
#
# **주석은 안 센다.** 이 함정을 설명하는 주석이 바로 그 문자열을 담고 있어서, 안 지우면
# 판정자가 자기 설명에 걸린다(같은 모양의 판정자 결함을 이 저장소가 이미 겪었다).
ck "네이티브가 앱 클래스를 안 찾는다" 0 "$(sed 's,//.*,,' $A | grep -c 'FindClass(env, "dev/')"
# 키를 세우는 일은 **`MaruKeyStore.ensureKey` 함수 하나**가 진다. 부르는 자리는 둘이지만
# (앱이 뜰 때·접속할 때) 하는 일은 하나여야 한다 — 자리마다 다시 적으면 한쪽만 고쳐진다.
ck "앱이 뜰 때 한 번 부른다" 1 "$(grep -c 'MaruKeyStore\.ensureKey(' $J)"
# **그리고 그 자리가 `onCreate` 다.** 「하나뿐」만 재면 `onResume` 으로 옮겨도 초록인데, 그러면
# 네이티브 창(`APP_CMD_INIT_WINDOW`)보다 늦어져 첫 프레임이 키 없이 뜬다. `onCreate` 본문만
# 잘라내 그 안에서 센다 — 본문은 4칸 들여쓰기의 닫는 괄호에서 끝난다.
onCreateBody() { awk '/protected void onCreate\(/{f=1} f{print} f&&/^    \}$/{exit}' "$J"; }
# **잘라내기가 됐는지부터 단언한다.** 포맷이 바뀌어 본문이 비면 아래 판정이 「없다」를 「옮겼다」로
# 읽는다 — 이미 있는 줄 하나를 닻으로 쓴다.
ck "onCreate 본문을 잘라냈다" 1 "$(onCreateBody | grep -c 'applyLongPressTimeout()')"
ck "키 세우기가 onCreate 안이다" 1 "$(onCreateBody | grep -c 'MaruKeyStore\.ensureKey(')"
# 공개키 줄의 **형식은 코어가 소유한다**(`maru_mobile_ssh_public_key_line`). host 가 조립하면
# 두 벌이 되고, 사용자는 어느 줄을 `authorized_keys` 에 넣어야 하는지 모른다.
ck "host 가 공개키 형식을 안 만든다" 0 "$(grep -c 'ssh-ed25519' $J $K $A $I | awk -F: '{s+=$2} END{print s+0}')"
# **봉인된 키를 여는 두 번째 자리도 같은 함수를 먼저 부른다.** 앱이 뜰 때 Keystore 가 실패하면
# 키는 **접속할 때 처음** 만들어지는데, 그때 한 줄을 안 남기면 봉인된 키는 있는데 화면은
# 「아직 키가 없습니다」인 상태가 남는다. 그래서 서비스도 `ensureKey` 를 **먼저** 부른다.
ck "서비스도 같은 함수를 먼저 부른다" 1 "$(awk '/MaruKeyStore\.ensureKey\(/{e=NR} /MaruKeyStore\.loadOrCreate\(/{l=NR} END{print (e&&l&&e<l)?1:0}' $V)"
# **두 host 가 다 «만든다».** 한쪽만 고치면 그 플랫폼만 계약 §3.4 를 지킨다 — 실제로 그랬다
# (Android 는 JNI 가 안 붙었고 iOS 는 만드는 코드가 아예 없었다).
ck "iOS 도 키를 만든다" 1 "$(sed 's,//.*,,' $I | grep -c 'maru_mobile_ssh_generate_key(')"
# **형식은 코어가 소유한다.** host 가 PEM 을 손으로 조립하면 읽는 자리와 갈리고, 그 어긋남은
# "우리가 쓴 키를 우리가 못 읽는다" 로 나타난다.
ck "iOS 가 PEM 을 손으로 안 만든다" 0 "$(sed 's,//.*,,' $I | grep -c 'BEGIN OPENSSH')"
ck "iOS 가 코어에게 PEM 을 받는다" 1 "$(sed 's,//.*,,' $I | grep -c 'maru_mobile_ssh_private_key_pem(')"
# 개인키 파일에 붙는 셋 — 자리·보호 등급·백업 제외. 하나라도 빠지면 「기기 밖으로 안 나간다」가
# 거짓이 된다(계약 §3.4).
# **주석은 안 센다** — 이 셋을 설명하는 주석이 바로 그 이름을 담는다(위 `FindClass` 판정자와 같다).
ck "키 파일을 백업에서 뺀다" 1 "$(sed 's,//.*,,' $I | grep -c 'NSURLIsExcludedFromBackupKey')"
ck "키 파일 보호 등급이 배경에서도 열린다" 1 "$(sed 's,//.*,,' $I | grep -c 'NSFileProtectionCompleteUntilFirstUserAuthentication')"

echo "§3.3 알림 권한은 붙을 때 묻는다 (M16c)"
# **선언만으로는 안 된다**(API 33+). 매니페스트에 적어 두고 런타임에 안 물어서, 배경 세션을
# 말하는 유일한 알림이 «떠 있으면서 안 보였다»(실측 `importance=NONE`). 둘 다 있어야 한다.
ck "매니페스트가 권한을 선언한다" 1 "$(grep -c 'POST_NOTIFICATIONS' $N)"
ck "런타임에도 «묻는다»" 1 "$(sed 's,//.*,,' $J | grep -c 'requestPermissions(')"
# **API 33 아래에는 이 권한이 없다**(minSdk 29). 없는 권한을 요청하면 대화상자 없이 거절이
# 돌아오고 로그가 「거절됐다」고 남는데, 실제로는 알림이 멀쩡히 뜬다 — 거짓 신호를 안 남긴다.
ck "옛 기기에는 안 묻는다" 1 "$(sed 's,//.*,,' $J | grep -c 'VERSION_CODES.TIRAMISU')"
# **묻는 자리는 붙는 경로다.** 첫 실행에 물으면 그때 앱이 선 곳은 서버 «등록» 화면이라(M16a)
# 무엇에 대한 알림인지가 화면에 없다 — Android 는 거절이 쌓이면 다시 못 묻는 자원이다.
startSshBody() { awk '/public static void startSsh\(/{f=1} f{print} f&&/^    \}$/{exit}' "$J"; }
# 잘라내기가 됐는지부터 단언한다(위 `onCreate` 판정자와 같은 이유).
ck "startSsh 본문을 잘라냈다" 1 "$(startSshBody | grep -c 'startForegroundService(')"
ck "묻는 자리가 붙는 경로다" 1 "$(startSshBody | grep -c 'askNotificationPermission()')"
# **거절해도 접속은 그대로 된다.** 답을 기다리거나 권한으로 가지 치면 「보여 줄 수 있나」가
# 「붙을 수 있나」가 된다 — 본문에 이른 return 은 `current == null` 하나뿐이다.
ck "권한이 접속을 막지 않는다" 1 "$(startSshBody | grep -c 'return;')"
# **허용은 «지금 도는 세션»에 닿아야 한다.** 권한 없이 올라간 알림을 OS 가 버리고 나중에
# 허용해도 되살려 주지 않는다(실측: 허용 직후·5초 뒤·홈으로 나간 뒤 모두 비어 있었다) — 그런데
# 사용자가 허용을 누른 이유가 바로 그 세션이다. 답을 받는 자리에서 다시 올린다.
ck "허용하면 그 세션 알림을 다시 올린다" 1 "$(sed 's,//.*,,' $J | grep -c 'MaruSshService\.onNotificationsAllowed()')"
# **없는 세션을 있다고 말하지 않는다** — 도는 서비스가 없으면 아무것도 안 올린다.
ck "세션이 없으면 안 올린다" 1 "$(awk '/public static void onNotificationsAllowed\(\)/{f=1} f{print} f&&/^    \}$/{exit}' $V | grep -c 'if (s == null) return;')"
# **iOS 는 안 묻는다** — 보내는 알림이 하나도 없기 때문이다. 알림을 보내게 되는 날 이 판정자가
# 붉어지고, 그때 «그 자리에서» 묻게 된다(계약 §3.3).
ck "iOS 는 알림을 안 보낸다" 0 "$(sed 's,//.*,,' $I | grep -c 'UNUserNotificationCenter\|requestAuthorization')"
# 알림이 처음 «보이게» 되면서 드러난 것 — 블루투스 아이콘이 붙어 있었다.
ck "알림 아이콘이 블루투스가 아니다" 0 "$(sed 's,//.*,,' $V | grep -c 'stat_sys_data_bluetooth')"

echo "§5 죽으면 그 자리를 남긴다 (M15b)"
# **두 host 가 같은 규율이다.** 한쪽만 걸면 그 플랫폼의 죽음만 미제로 남는다.
for f in $A $I; do
  ck "처리기를 건다 ${f##*/}" 1 "$(sed 's,//.*,,' $f | grep -c 'sa.sa_handler = crashHandler;')"
  # **스택이 넘쳐 죽었으면 처리기가 쓸 스택도 없다** — 하필 그 갈래가 재현하기 가장 어렵다.
  ck "따로 쓸 스택을 준다 ${f##*/}" 1 "$(sed 's,//.*,,' $f | grep -c 'sigaltstack(&ss, NULL);')"
  # **삼키지 않는다.** 되돌려 다시 올려야 OS 가 자기 크래시 보고(tombstone·.ips)를 만든다 —
  # 우리 파일은 그것을 대신하는 것이 아니라 «옆에» 두는 것이다.
  ck "되돌려 다시 올린다 ${f##*/}" 1 "$(sed 's,//.*,,' $f | grep -c 'signal(sig, SIG_DFL);')"
  ck "그 신호를 다시 올린다 ${f##*/}" 1 "$(sed 's,//.*,,' $f | grep -c 'raise(sig);')"
  # **프레임마다 미리 뜬다** — 죽는 순간에는 아무것도 만들 수 없다.
  ck "프레임마다 미리 뜬다 ${f##*/}" 1 "$(sed 's,//.*,,' $f | grep -c '^ *refreshCrashSnapshot();')"
done
# **처리기 안에서 쓸 수 있는 것은 셋뿐이다**(`open`·`write`·`close`). `malloc`·`printf`·`snprintf`·
# 잠금은 async-signal-safe 가 아니라 죽는 자리에서 또 죽거나 매달린다 — 그러면 남는 것이 없다.
crashBody() { awk '/^static void crashHandler\(int sig\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$1"; }
for f in $A $I; do
  # 잘라내기가 됐는지부터 단언한다(위 판정자들과 같은 이유).
  ck "처리기 본문을 잘라냈다 ${f##*/}" 1 "$(crashBody $f | grep -c 'raise(sig);')"
  ck "처리기가 안전한 것만 쓴다 ${f##*/}" 0 "$(crashBody $f | sed 's,//.*,,' | grep -cE 'malloc|printf|NSLog|pthread_mutex|fopen')"
done

echo "§하네스 — 조용히 빗나가지 않는다 (M8)"
R=tools/mobile-harness/sim_input.swift
# **좌표를 손으로 박지 않는다.** 창 세로 여유(66)보다 큰 오프셋(70)이 박혀 있어 보내는 점이
# 통째로 어긋났고, 그래서 손짓이 아무 데도 안 닿았다 — 그런데 **아무 말도 없었다**.
ck "박은 세로 오프셋이 없다" 0 "$(grep -c 'padY' $R)"
# 보정이 없으면 **말하고 멈춘다.** 어림값으로 보내면 조용히 빗나가고, 그 침묵을 「기능이 안 된다」
# 로 읽게 된다(실제로 슬라이스 둘의 iOS 확인을 그렇게 놓쳤다).
ck "보정이 없으면 안 보낸다" 1 "$(grep -c 'guard let cal = loadCalibration()' $R)"
ck "보정 모드가 있다" 1 "$(grep -c 'if mode == \"calibrate\"' $R)"
# **낡은 단정을 남기지 않는다** — `features-ios` 는 다시 도는 것을 확인했다(5 PASS / 1 FAIL).
ck "features-ios 가 멈춘다고 안 적는다" 0 "$(grep -c '지금 멈춘다' tools/mobile-harness/README.md)"
# **낡음을 «숫자»에 묶는다.** 위 판정자는 문구 하나를 무는 것이라 바꿔 적으면 빠져나간다 —
# 실측값이 함께 있어야 다음 사람이 다시 재 보고 고칠 수 있다.
ck "그 자리에 실측값이 있다" 1 "$(grep -c '5 PASS / 1 FAIL' tools/mobile-harness/README.md)"
# **성공 경로가 «한 번도 안 돈» 채로 남지 않게** 한다. CGEvent 가 이 기계에서 시뮬레이터에 안
# 닿아서 보정은 실패로만 돌았다 — 사상을 푸는 산술은 시뮬레이터 없이도 재어져야 한다.
# (첫 실행에서 진짜 결함을 잡았다: 보정을 적어 두고도 다시 못 읽었다.)
ck "시뮬레이터 없이 도는 자가 검사" 1 "$(grep -c 'if mode == \"selftest\"' $R)"
# **자가 검사가 «사본»을 검사하면 아무것도 안 지킨다** — 푸는 자리가 하나여야 한다.
ck "푸는 자리가 하나다" 1 "$(grep -c '^func solve(' $R)"
# **여기서 실제로 돌린다** — 있는지만 세면 그 안이 깨져도 초록이다.
#
# **건너뛰는 조건은 «macOS 인가» 다.** 처음에는 `command -v swift` 로 갈랐는데, CI(ubuntu)에도
# swift 가 있어서 **돌긴 돌고 CoreGraphics 가 없어 아무것도 안 뱉었다** — 그 빈 값이 「통과 아님」
# 으로 붉었다(CI 가 잡았다). 이 스크립트는 CGEvent·CGWindowList 를 쓰므로 macOS 에서만 돈다.
# 안 도는 자리에서는 **건너뛴다고 말한다**: 조용히 안 도는 게이트는 게이트가 아니다.
if [ "$(uname)" = "Darwin" ] && command -v swift >/dev/null 2>&1; then
  ck "자가 검사가 통과한다" "전부 통과" "$(swift $R selftest | tail -1 | sed 's/selftest: //')"
else
  printf "  건너뜀 %-40s macOS 아님\n" "자가 검사"
fi

echo "§3.4 배포 준비 (M11a)"
N=src/platform/android/AndroidManifest.xml
X=src/platform/ios/PrivacyInfo.xcprivacy
# **배포 기본값은 안전이다.** 이 값이 실리면 아무나 앱 저장소를 꺼낸다 — 개인키를 봉인해 두는
# 그 자리다(§3.4). 주석은 안 센다(그 함정을 설명하는 주석이 이 이름을 담는다).
ck "매니페스트에 debuggable 이 없다" 0 "$(sed '/<!--/,/-->/d' $N | grep -c 'android:debuggable=')"
# 개발 빌드는 **하네스가** 켠다. 그리고 **원본을 안 고친다** — 고치면 켜진 채 남아 다음 배포에 실린다.
# **두 번 나온다**: 끼워 넣는 `sed` 한 줄과 **넣었는지 확인하는** 한 줄. 확인이 없으면 치환이
# 빗나갔을 때(매니페스트 문구가 바뀌면) 조용히 안 켜진 apk 가 나오고, `run-as` 가 안 되는 이유를
# 한참 찾게 된다.
ck "개발 빌드가 켜고, 켜졌는지 확인한다" 2 "$(grep -c 'android:debuggable' $H_RUN)"
# **여는 태그 바로 뒤에 끼운다** — 줄 전체를 맞추면 속성이 하나만 늘어도 빗나간다(아이콘을
# 붙이면서 실제로 겪었다. 그때는 위 확인이 멈춰 세웠지만, 애초에 안 빗나가는 편이 낫다).
ck "치환이 속성 추가에 안 깨진다" 1 "$(grep -c 'sed .s|<application |' $H_RUN)"
ck "원본이 아니라 사본에 쓴다" 1 "$(grep -c 'AndroidManifest.dev.xml' $H_RUN)"
# **개인정보 선언은 제품 자리에 있고 번들에 든다.** 하네스가 자기 사본을 만들면 번들과 갈린다.
ck "개인정보 선언이 제품 자리에 있다" 1 "$(ls $X 2>/dev/null | wc -l | tr -d ' ')"
ck "번들에 그것을 넣는다" 1 "$(grep -c 'PrivacyInfo.xcprivacy' $H_RUN)"
# **우리 답은 전부 「없음」이다.** 배열 셋이 비어 있어야 그 선언이 참이다.
ck "추적 안 함" 1 "$(grep -c '<key>NSPrivacyTracking</key><false/>' $X)"
ck "수집하는 자료 없음" 1 "$(grep -c '<key>NSPrivacyCollectedDataTypes</key><array/>' $X)"
ck "사유를 밝힐 API 없음" 1 "$(grep -c '<key>NSPrivacyAccessedAPITypes</key><array/>' $X)"
# **그리고 그것이 «사실»이어야 한다.** 하나라도 쓰기 시작하면 위 선언이 거짓이 된다 — 그때
# 붉어져서 선언을 함께 고치게 한다(2026-09-09 실측: 전부 0건).
ck "사유를 밝힐 API 를 안 쓴다" 0 "$(sed 's,//.*,,' $I | grep -cE 'NSUserDefaults|systemUptime|NSFileCreationDate|NSFileModificationDate|attributesOfItemAtPath|statfs|activeInputModes')"

echo "§아이콘 — 한 그림이 세 플랫폼을 덮는다 (M11b·M11c)"
G=assets/icon/render.py
# **그리는 자리가 하나다.** 크기가 스물 몇 개라 손으로 맞추면 한 자리만 낡고, 그 한 자리는
# 그 크기에서만 드러난다(작은 아이콘이 특히 그렇다).
ck "그림의 단일 출처가 있다" 1 "$(ls $G 2>/dev/null | wc -l | tr -d ' ')"
ck "macOS 아이콘이 있다" 1 "$(ls assets/icon/Maru.icns 2>/dev/null | wc -l | tr -d ' ')"
ck "iOS 아이콘이 다 있다" 5 "$(ls assets/icon/ios/*.png 2>/dev/null | wc -l | tr -d ' ')"
ck "Android 아이콘이 다 있다" 10 "$(ls assets/icon/android/mipmap-*/*.png 2>/dev/null | wc -l | tr -d ' ')"
# **색은 제품에서 온다.** 여기 숫자를 새로 만들면 브랜드가 두 벌이 된다.
ck "앰버가 브랜드 강조색이다" 1 "$(grep -ci 'AMBER = (0xDD, 0xA1, 0x5E)' $G)"
ck "그 앰버가 제품 값이다" 1 "$(grep -ci 'accent_default = #dda15e' src/config/appearance.zig)"
# **모티프의 비율은 문서와 코드가 같은 수를 말해야 한다.** `ㅁ` 을 셀 비율(1:1.9)로 두면 글자가
# 「미」로 읽혀서 눕혔다 — 그 수가 갈리면 어느 쪽이 규칙인지 알 수 없다.
ck "ㅁ 을 눕힌 비율이 코드에 있다" 1 "$(grep -c 'ch / 1.25' $G)"
ck "그 비율이 문서에도 있다" 1 "$(grep -c '1:1.25' docs/distribution.md)"
# **여기서 실제로 돌린다** — 자산이 있는지만 세면 생성기를 고치고 다시 안 뽑아도 초록이다.
# `.icns` 는 `iconutil`(macOS 전용)이 손으로 굽는 산출물이라 이 판정이 유일한 파수꾼이다.
# CI(ubuntu)도 Pillow 를 쓴다(`tools/svg_to_coverage.py`) — 그래서 여기서도 돈다.
ck "뽑아 둔 자산이 규칙과 같다" 0 "$("$PY" $G --check >/dev/null 2>&1; echo $?)"
# **「작아도 안 뭉친다」를 눈이 아니라 자로 잰다.** 안전 원을 0.6px 넘은 것을 이게 잡았다.
ck "작은 크기·안전 영역을 잰다" 0 "$("$PY" $G --selftest >/dev/null 2>&1; echo $?)"
# **재료는 커밋하지 않는다** — 그러면 생성기를 돌릴 때마다 작업 나무가 더러워진다.
ck "iconset 은 무시한다" 1 "$(grep -c 'assets/icon/Maru.iconset/' .gitignore)"
# **적응형 배경색은 두 곳에 적힌다**(XML 이 색을 요구하고 생성기는 PNG 를 굽는다) — 묶어 둔다.
ck "적응형 배경이 생성기 바탕과 같다" 1 "$(grep -c '#1E1E2E' src/platform/android/res/values/colors.xml)"
ck "생성기 바탕도 그 값이다" 1 "$(grep -c 'GROUND = (0x1E, 0x1E, 0x2E)' $G)"
# **번들이 실제로 든다.** 자산만 있고 안 실으면 아무 데도 안 보인다.
ck "macOS 번들이 싣는다" 1 "$(grep -c 'assets/icon/Maru.icns zig-out/Maru.app' build.zig)"
ck "macOS plist 가 가리킨다" 1 "$(grep -c 'CFBundleIconFile' src/platform/macos/MaruAppHost-Info.plist.in)"
ck "iOS plist 가 가리킨다" 1 "$(grep -c 'CFBundleIconFiles' src/platform/ios/Info.plist.in)"
ck "iOS 번들이 싣는다" 1 "$(grep -c 'assets/icon/ios' $H_RUN)"
ck "Android 매니페스트가 가리킨다" 1 "$(grep -c 'android:icon=' $N)"
ck "Android 가 res 를 컴파일해 링크한다" 1 "$(grep -c 'aapt2\" compile --dir' $H_RUN)"

echo "문서가 자기 자신과 모순되지 않는가"
# 슬라이스마다 절을 **고쳐야** 하는데 같은 제목으로 새로 **붙인** 적이 있다. 그러면 한
# 문서에 반대되는 두 문장이 남고("키는 코어의 인코더를 탄다" ↔ "아직 안 탄다") 어느 쪽이
# 참인지 문서만 봐서는 모른다. 제목과 굵은 첫 문장이 겹치는지로 잡는다.
# **계약 문서 전부를 본다.** 한 파일만 박아 두면 계약 문서가 늘 때마다 새 문서가 사각지대로
# 들어간다(`mobile-config.md` 를 더하자 바로 그랬다 — 적대적 검증에서 드러났다).
for D in docs/mobile-platform.md docs/mobile-ux.md docs/mobile-config.md; do
  ck "제목 중복 ${D##*/}" 0 "$(grep -E '^#{2,4} ' $D | sort | uniq -d | wc -l | tr -d ' ')"
  ck "굵은 첫 문장 중복 ${D##*/}" 0 "$(grep -oE '^\*\*[^*]{10,60}' $D | sort | uniq -d | wc -l | tr -d ' ')"
done

echo "데스크톱 키 ↔ 모바일 판정"
# 모바일 문서는 "데스크톱 키를 전부 훑어 갈랐다" 고 주장한다 — 셀 수 있는 주장이라 센다.
# 적대적 검증에서 14개가 어디에도 없는 채로 통과하고 있었다. 데스크톱에 키가 늘 때도 문다.
# **숫자를 파싱하지 말고 종료 코드를 본다.** 숫자 하나만 읽으면 스크립트가 판정 축을 늘렸을 때
# (누락 → 누락+겹침) 새 축이 조용히 샌다 — 실제로 `bell.*` 겹침이 그렇게 통과하고 있었다.
"$PY" "$(dirname "$0")/config_key_coverage.py" > /tmp/maru_key_cov.$$ 2>&1
ck "모바일 문서의 키 판정" 0 "$?"
grep -E "^  (없음|겹침)" /tmp/maru_key_cov.$$ || true
rm -f /tmp/maru_key_cov.$$

echo "계획 ↔ 계약 슬라이스 참조"
# **이름을 여기 손으로 적지 않는다.** 예전 판은 `for m in M4a2 ... M10` 이라, 계획을 쪼개면
# 판정자가 없는 슬라이스를 계속 찾고(M10 을 M10a~d 로 가르자 바로 그렇게 됐다) 새 인용은
# 아예 안 봤다. 인용을 훑어 대조한다(접두어 인정 — `M3` 는 M3a~c 가족을 부르는 이름).
"$PY" "$(dirname "$0")/plan_citations.py" > /tmp/maru_cite.$$ 2>&1
ck "계획 인용" 0 "$?"
grep -E "^  없음" /tmp/maru_cite.$$ || true
rm -f /tmp/maru_cite.$$

# **비-0 으로 끝난다.** 이것이 없으면 어디에 걸어도 게이트가 안 된다.
if [ "$bad" -gt 0 ]; then printf "\n틀림 %d 건\n" "$bad"; exit 1; fi
printf "\n전부 통과\n"
