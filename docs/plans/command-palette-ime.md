# 명령 팔레트 IME 문맥 — 재현과 구현 계획

상태: 실제 입력 재현 완료. 2026-10-19 사용자 진행 승인에 따라 기존 검색 길이를 유지하는 동적 문맥 안을 구현한다.

## 문제와 재현

2026-10-19 main `28c32e94b` 기반 Debug 앱을 별도 HOME·config·host root로 실행했다.
`MARU_OPEN_COMMAND_PALETTE=1`로 팔레트를 열고, foreground PID와 두벌식 source를 매 키마다
확인하는 외부 HID 도구로 `ㅎ → 하 → 한`, Option-Return, Escape를 보냈다.
Option-as-Meta는 기존 후보창 gate와 같이 껐다. 원래 입력 source는 종료 시 복원됐다.

실제 IME 로그는 marked `ㅎ`·`하`·`한`, 반복된 selectedRange `{0,0}`, Option-Return 뒤
원문 `한` insert를 기록했다. 요청 전후 WindowServer 목록에는 새 window ID가 없었다.
이는 후보 요청 실패의 진단이며 성공한 후보창의 소유권·픽셀 증거가 아니다.
산출물은 저장소 밖 `maru-palette-ime-20261019/baseline-live-normal-mode/`에 보존한다.
앞선 두 실행은 입력 전 테스트 터미널 종료로 실패했고 별도 폴더에 보존한다.

`chrome_ime.generation`은 현재 `.agent_session_search`만 지원한다. 팔레트는 state/substring
질의를 제공하지 않는 fallback으로 가며, 범위를 가진 쓰기도 일반 조합 입력으로 돌아간다.

## 길이와 저장 계약 추가 확인

기존 제품 `palette.handle`·`OverlayInput`과 고정 `Context`를 직접 import한 별도 판정자
5개를 Debug·ReleaseFast에서 각각 실행했다. 소스 사본과 실행 결과는 저장소 밖
`maru-palette-ime-20261019/length-audit/` 및 `/private/tmp/maru-palette-ime-length-audit*.log`에 둔다.

- ASCII 257개를 실제 palette key handler로 넣으면 query 257 byte가 유지된다.
  같은 검색어의 고정 Context reset은 거부된다.
- 한글 86자는 UTF-16 86 unit이지만 UTF-8 258 byte다. 기존 팔레트는 유지하고 고정 Context는 거부한다.
- 기존 OverlayInput은 1KB marked text의 확정도 허용한다. 고정 Context는 같은 입력을 거부한다.
- 확정 `한` 뒤 preview `韓`의 canonical은 `한`, projected text는 `韓`이다.
  화면·필터를 canonical+marked로 조립하면 `한韓`이 되어 잘못된다.
- 기존 고정 Context의 값 복사는 독립된 rollback이다. 동적 버퍼를 그대로 얕게 복사하는 방식으로
  이 보장을 옮길 수 없다.

빈 검색어 반복과 257-byte 접두어의 추가 실제 HID 실행은 첫 key 전 foreground guard에서
중단됐다. 이후 macOS의 `CGSSessionScreenIsLocked=1`을 확인했다. 두 실행 모두 원래 입력
source 복원을 완료했으며 제품 실패나 후보창 성공으로 분류하지 않는다. 당시 유니코드 접두어
실제 HID 시나리오는 실행하지 못했으며, 이후 잠금 해제 후 결과는 아래 절에 기록했다.

## 잠금 해제 후 실제 입력 재검증

같은 SHA-256 `a61ba9b2fb896bb9e596cab6f7fc4f4e77b221e9ac2569e1f64f5684fb9206c3` 앱으로
빈 검색어, ASCII 257-byte 접두어, `😀한` 접두어의 세 경우를 확인했다. 세 실행 모두 실제
setMarkedText `ㅎ`·`하`·`한` callback을 기록했고, 한자 요청 중 selectedRange는 `{0,0}`으로
남았다. 요청 전후 window inventory에 새 ID는 없었다. 모든 실행에서 원래 입력 source를 복원했다.
여전히 후보창 성공의 픽셀/owner 증거가 아니라 입력 문맥 공백을 확인하는 진단이다.

첫 두 실행(`unlocked-empty`, `unlocked-long-prefix`)은 helper의 global source 조회는 한국어였지만
실제 target callback은 영문 `gks`여서 한글 검증에서 제외했다. 외부 helper의 global source 조회만으로
앱 view의 input context까지 증명할 수 없다. 실제 marked callback을 별도로 요구한 재실행으로
빈 검색어·긴 접두어를 확인했다. 실패 기록을 덮어쓰지 않았고 결과는 외부 `unlocked-summary.json`에
분리했다. 유효한 실행 폴더는 `unlocked-empty-korean-retry`, `unlocked-long-prefix-korean-retry`,
`unlocked-unicode-prefix`다. 제품 코드와 앱 서명은 바꾸지 않았다.

## 유지할 계약

- `OverlayInput`의 query/preedit와 팔레트 UI·명령 카탈로그를 유지한다.
- 기존 팔레트는 조합 중에도 필터한다. Session Dock의 확정 후 필터 정책을 복사하지 않는다.
- 기존 ↑/↓ 선택, ←/→·Tab의 닫기, Enter 실행, Escape 닫기 동작을 유지한다.
  후보창이 소유한 키는 OS가 먼저 소비하며 확정 Enter가 명령 실행으로 새면 안 된다.
- 다른 검색창이나 공용 TextField로의 전면 이관은 포함하지 않는다.
- 기존 팔레트 검색 길이를 새로 제한하지 않는다.

## 저장 방식 — 기존 길이 유지

Session Dock의 `inline_text_input.Context`는 query 256 byte·marked 256 byte의 고정 배열과
값 복사 rollback을 사용한다. 팔레트의 `OverlayInput`에는 같은 길이 제한이 없다.
이 Context를 그대로 연결하면 기존 긴 검색·붙여넣기를 새 한계에서 거부하게 된다.

권장안은 팔레트의 길이를 유지하는 **동적 저장 문맥**이다. UTF-16 범위 계산은 기존 중립
`session/editor/text_input.zig`를 재사용한다. projection의 공통 판정은 caller-owned 저장
공간을 받도록 중립 계층에서 공유하고, Session Dock의 고정 배열 계약은 유지한다.
동적 storage의 reserve와 rollback snapshot은 platform adapter가 먼저 준비한다. 포인터를
가진 문맥을 값 복사해 rollback으로 쓰지 않는다. Session Dock의 고정 배열을 전체 동적
버퍼로 바꾸는 안은 현재 범위 밖이다.

대안은 팔레트에도 256-byte 제한을 명시적으로 도입하는 것이다. 이는 기존 UX 변경이므로
사용자 승인 없이 구현하지 않는다. 한계를 넘으면 조용히 일반 경로로 fallthrough하는 안은
동일 조합 중 ABI·문서 축이 바뀌므로 채택하지 않는다.

## 계획에 대한 적대적 검토

1. **길이**: 기존 모델을 그대로 재사용하면 256 byte 초과 검색·붙여넣기가 잘린다.
   → 기존 길이를 유지하고, 256/257 경계와 큰 UTF-8 입력의 성공 대조를 둔다.
2. **preview**: 확정 `한` 뒤 marked `韓`을 단순 append하면 화면·필터가 `한韓`이 된다.
   → canonical commit과 표시 projection을 구분하고 화면·필터·range는 같은 projection을 읽는다.
3. **owner**: 두 입력창이 같은 세대 숫자를 쓰면 팔레트의 늦은 callback이 Session Dock에 도착할 수 있다.
   → 창·입력 owner·activation을 결속한 token과 기존 별도 NSTextInputClient 신원을 함께 검사한다.
   팔레트 닫기·재열기·다른 modal 전환에서도 token을 폐기한다.
4. **할당 실패**: 동적 문맥의 얕은 snapshot은 rollback 전에 원본까지 바뀌거나 이중 해제될 수 있다.
   → key 시작 snapshot과 commit/preedit 저장을 먼저 준비한다. 실패 시 query·표시·필터를
   함께 보존하고, 실패한 후보 키를 명령 또는 PTY로 재생하지 않는다. 각 실패 뒤 성공 재시도를 둔다.
5. **키와 필터**: Session Dock 코드를 복사하면 조합 중 필터와 Enter 정책이 변한다.
   → 기존 팔레트 회귀를 유지하고, 후보 Escape/Return과 후보 종료 후 Escape/Return을 분리한다.
   후보창 선택으로 검색어만 바뀌며 명령 dispatch는 별도의 실제 Enter만 허용한다.

## 구현과 완료 조건

1. 고정/동적 저장이 같은 중립 projection 연산을 사용하게 한다. 동적 문맥은 reserve와 깊은 snapshot을 먼저 준비한다.
2. 팔레트 전용 owner 수명주기와 읽기/쓰기 ABI를 연결한다. 기존 ABI 계약을 확장하면 버전을 올린다.
3. 표시 텍스트·filter·caret을 같은 projection에 연결하고 기존 palette handle 정책을 보존한다.
4. native 성공·범위 거부·Unicode·길이·OOM·stale owner·닫기/재열기와 Swift callback을 검증한다.
5. 실제 두벌식 조합, 새 후보창 5회 취소, 별도 한자 선택, Enter 명령 오실행 0과 terminal 복귀를
   확인한다. 후보 성공에는 window 소유권·lifecycle·PNG/OCR·anchor 증거가 필요하다.
6. 서로 다른 결함 주입 5종을 컴파일 후 runtime 검사에서 거부하고 정상·복원 대조를 확인한다.

## 근거

기존 `docs/text-field-editor.md` §2.2의 전원 이관 비목표와 §7의 완전 IME 프로토콜 후속,
Session Dock의 `docs/plans/agent-session-list.md` 후보 문맥 계약을 따른다.
이번 계획은 새로운 입력 길이 제한을 승인한 것으로 해석하지 않는다.

## VS Code와의 비교

VS Code의 QuickInputBox는 FindInput의 InputBox를 사용하며 실제 HTML input의 value와
선택 범위를 읽는다. 확인한 두 구현에는 256-byte 고정 입력 버퍼를 두지 않는다. Chromium이
입력 요소의 IME 연결을 담당하므로, Maru의 네이티브 문맥 버퍼와 같은 구현이라는 뜻은 아니다.
우리는 긴 검색어를 유지한다는 기존 UX를 보존하고 native owner·할당·rollback을 명시한다.

- [QuickInputBox](https://github.com/microsoft/vscode/blob/main/src/vs/platform/quickinput/browser/quickInputBox.ts)
- [InputBox](https://github.com/microsoft/vscode/blob/main/src/vs/base/browser/ui/inputbox/inputBox.ts)

## 구현 중인 저장·owner 계약

- 중립 `ContextWithStorage`는 동일한 범위·replacement·preview 판정을 고정/동적 slice에 적용한다.
- `OwnedContext`는 projected/base/committed/scratch를 하나의 할당으로 준비하고 실패 시 원본을 유지한다.
  `clone`은 데이터까지 복사한다. snapshot 실패 시 그 키는 소비하고 다음 키에서 재시도한다.
- 팔레트 State가 동적 문맥을 소유하며 show/hide마다 activation을 증가시킨다. 상위 bit가 팔레트,
  나머지 bit가 세대다. Session Dock token과 겹치지 않으며 포화 시 재사용하지 않는다.
- 그리는 문자열·caret·필터는 canonical+marked의 단순 합이 아니라 현재 projection을 읽는다.
- ABI 234는 이 owner와 AppSession snapshot 수명을 포함한다. 새 runtime 의존성은 없다.
- 실제 후보창 성공·취소·선택 검증은 아직 완료되지 않았다.

## 로컬 구현 검증

- 고정 Context 9개·동적 OwnedContext 및 공유 범위 14개: Debug·ReleaseFast 통과.
- 실제 AppSession 팔레트 회귀 6개: Debug·ReleaseFast 통과. 기존 Enter·sidebar 우선권·CoreText 판정도 포함한다.
- key의 snapshot, projection/canonical/preedit reserve와 필터 정상화 중 할당 실패를 순차 주입하고
  실패 없는 첫 대조까지 확인했다. 실패 뒤 query·projection·preedit를 보존하며 선택 행 rollback도 검증했다.
  할당 횟수 자체를 제품 계약으로 고정하지 않는다.
- 긴 입력 상한 주입, 얕은 snapshot, committed relocation 누락, scratch alias, reset storage 누락의
  다섯 변이는 컴파일 성공 후 실행 검사에서 거부됐다. 매회 정상·복원 대조도 통과했다.
- 기존 Session Dock 입력 판정과 Swift host 268개·마우스·키 전달 하네스가 통과했다.
- 필터도 publication 전에 준비하며, key 시작의 catalog index 사본으로 rollback한다.
  callback이 key 밖에서 오거나 blur 확정이 실패하는 경우에도 깊은 사본으로 원상 복구한다.
- 수정 앱의 실제 입력 재검증을 시작했다. 아래 기록과 전체 완료 조건을 구분한다.
  앞의 실제 입력 기록은 수정 전 재현이며 수정 빌드 성공 증거로 재사용하지 않는다.

최종 `check-boundaries`도 통과했다. 필터 실패 보완 뒤 실제 검증용 앱은
`/private/tmp/maru-palette-ime-apps-501/e2a487b8987f00f21aca98c6474094497a6f1893d19befc626de9ba0c1878ca1/Maru.app`에 고정했다.
이전 `f9eaeb55…` 중간 빌드는 필터 원자성 보완 전이므로 최종 검증에 사용하지 않는다.

### 수정 빌드의 실제 입력 중간 결과

추가 조사에서 이모지 접두어의 실패 원인을 분리했다. 대상 view의 두벌식 소스와 최신 상태를
각 키 전에 확인한 시험에서도 `😀한`에 대한 조회가 `{0,1}`로 들어와 surrogate 중간 경계를
가리켰고, 기존 읽기 API가 nil을 반환했다. 읽기 범위만 scalar 경계로 넓힌 private 대조 빌드는
같은 입력에서 `韓` 미리보기와 앱 소유 새 후보창을 생성했다. 원본 빌드는 실패했다.
따라서 엄격한 편집 범위 검사는 유지하고, chrome IME의 읽기 조회만
`substringForInputMethod`로 경계를 보정하여 실제 반환 범위를 돌려준다. 읽기에는 할당이 없다.
문서 밖 시작은 nil이며, 과도한 끝은 먼저 문서 범위에 교차시킨다.
Apple은 실제 반환 범위를 문자 경계 등으로 조정할 수 있다고 명시한다:
[NSTextInputClient 조회 계약](https://developer.apple.com/documentation/appkit/nstextinputclient/attributedsubstring%28forproposedrange%3Aactualrange%3A%29).
이것은 수정된 최종 제품 빌드의 전체 후보창 검증 완료를 뜻하지 않는다.

같은 최종 빌드에서 `final-patched-empty`와 `final-patched-long`(257-byte 접두어)은
실제 `ㅎ → 하 → 한` 조합, Option-Return 뒤 `韓` replacement preview, Escape 뒤
`한` 복원 콜백을 기록했다. 두 경우 모두 동일 앱 PID 소유의 새로운 layer-20 창이 생성됐다.
입력 소스는 검증 후 복원했다. 산출물은 저장소 밖 `maru-palette-ime-20261019` 아래에 둔다.

이는 콜백과 창 목록 진단이며 PNG/OCR를 포함한 전체 후보창 완료 증거는 아니다.
유니코드 접두어 재시도에서 실제 한글 조합은 확인했지만 새 후보창이 없었다. 위 읽기 경계
대조 시험으로 원인을 분리하고 보정을 반영했다.
일부 다른 시도는 전역 한글 소스 조회에도 대상 입력 문맥에 영문 `gks`가 전달됐다.
해당 시도는 한글·후보창 성공/실패 집계에서 제외한다. 대상 view의 입력 소스를 확인하는
검증 드라이버가 필요하며, 후보 선택·취소 lifecycle·터미널 복귀와 5회 PNG/OCR 검증은 남아 있다.

읽기 보정 뒤 최종 제품 앱은 `16a72ab84f6c408c886e07efe4021cc468c1b91332b08e0b83d08e95644bf3aa`
해시로 고정했다. `product-scalar-emoji-select`에서 실제 `ㅎ/하/한` 조합과 `韓` preview,
Return 뒤 `insertText("韓")`를 확인했다. 앞선 `product-scalar-emoji` 시도는 영문 입력이라
제외했다. 새 읽기 범위 회귀와 실제 AppSession adapter 검사는 통과했으며, 편집의 surrogate
중간 범위 거부도 유지했다. 실제 픽셀 판정과 최종 상태·터미널 복귀는 별도 완료 조건이다.

`product-scalar-emoji-separated`에서도 실제 한글 조합·새 앱 소유 후보창·취소 후 창 종료를
확인했다. 선택 시험의 후보창도 Return 뒤 종료됐다. 두 유효 시험은 입력 소스 복원을 기록했다.
추가 반복 중 영문이 전달된 경우는 계속 제외하며 유효 후보창 횟수로 합산하지 않는다.
읽기 보정의 적대적 검사 5종(시작 보정 누락·끝 보정 누락·잘못된 actualRange·끝 교차 누락·
잘못된 편집 허용)은 모두 컴파일 후 회귀 검사에서 거부됐고, 정상 복원 대조도 통과했다.
이 결과는 실제 후보창 5개와 PNG/OCR 완료를 대체하지 않는다.
읽기 보정 뒤 `test-inline-text-input`·`test-inline-text-input-owned`·`test-palette-ime-context`·
`test-session-dock-search-input`과 전체 `check-boundaries`가 통과했다. `zig fmt --check`와
`git diff --check`도 통과했다. 이 단계에서는 커밋·PR·머지를 수행하지 않았다.

최신 main의 Inspector ABI 233과 합치므로 팔레트 변경은 ABI 234로 배정한다. 앞의 실제 GUI 기록은
리베이스 전 ABI 233 빌드의 기록이며, main 통합 뒤 검증 결과와 구분한다.
