# 주소창 TextField IME 문맥

상태: 2026-10-24 구현·집중 검사·적대적 대조·실제 후보창 PNG/OCR·한자 선택·터미널 복귀 검증 완료. 명령 팔레트 IME와 별도 범위다.

## 확인한 원인

변경 전 `chrome_ime.generation/projection`은 세션 검색과 팔레트만 다뤘다. 주소창은
`TextField.caret/selection`을 가지지만 IME의 UTF-16 selected/marked/substring 질의가
그 필드를 읽지 않는다. 기존 caret 삽입 경로는 replacementRange를 해석하지 않는다.
따라서 중간 커서·선택 영역의 재변환과 범위 교체를 주소창 편집 상태에 결속할 수 없다.

## 계약과 구현 순서

1. 기존 `inline_text_input.DynamicContext`와 `OwnedContext`의 UTF-16 검증·깊은 복사를 재사용한다.
   TextField에 대한 순수 어댑터는 chrome 컴포넌트에 두며 AppSession·OS 타입을 읽지 않는다.
   canonical text, caret, selection으로 projection을 만들고 marked span을 제외한 본문과
   preedit를 기존 TextField 레이아웃에 게시한다. 조합 내부 selectedRange도 실제 위치로 반환한다.
2. AppSession은 주소창 진입 세대·surface·현재 inputFocus를 묶는다. 주소창 종료·재진입·
   다른 입력 owner로 전환한 키의 콜백은 소비하고 다른 필드/PTY로 보내지 않는다.
   기존 창 단위 NSTextInputClient 바깥에서 오는 식별 불가능한 지연 콜백은 이번 범위에 포함하지 않는다.
3. key transaction 시작 전 깊은 snapshot과 메모리를 준비한다. 콜백 실패는 해당 키를
   되돌리고 소비한다. 트랜잭션 밖 콜백도 전부 준비한 뒤 게시한다. URL 길이 제한은 새로 만들지 않는다.
4. 기존 읽기/쓰기 ABI를 사용한다. runtime layout이 달라지면 ABI 버전·크기 pin을 함께 갱신한다.
   Enter는 조합 확정만으로 navigate하지 않으며 기존 replay 정책을 유지한다.
   선택·paste·마우스 변경으로 projection이 낡으면 다음 질의에서 현재 TextField로 다시 만든다.
5. 단위 검사로 emoji surrogate 분할 거부, 역방향 선택, 중간 조합·재변환·취소,
   insert+marked 연속 콜백, Backspace 상쇄, OOM 원자성, 소유권 변경을 고정한다.
   실제 macOS에서는 중간 한글 입력·선택 대체·한자 후보창 취소/선택·주소창 이탈과
   터미널 복귀를 관측한다. 실제 후보창 증거는 PNG/OCR 독립 판정과 분리하지 않는다.

## 설계 공격과 완료 조건

서로게이트 중간·범위 overflow, 낡은 selection, 다른 surface 재진입, 조합 도중 OOM,
확정 직후 다음 조합 삭제, 후보창 Return의 URL navigate 누출을 각각 공격한다.
적대적 검증 5회는 발견한 결함·수정과 정상 대조군 결과를 기록한다.
단위 성공, 실제 GUI 성공, CI 성공을 구분하며 실제 GUI 미완료를 완료로 표기하지 않는다.

범위 밖: find/rename/다른 검색창의 이관, 네이티브 NSTextField 임베드, 브라우저 페이지 내부 IME,
Undo/Redo 신설, 창별 NSTextInputClient 소유권 구조 변경.


## 구현·검증 결과

- `text_field_ime.State`는 공통 UTF-16 projection과 OwnedContext의 reserve/clone을 사용한다.
  marked span의 표시에서는 URL suffix를 보존하고, 비어 있는 marked 취소에서는 확정 원문을 복원한다.
- OOM 복원에서 선택의 방향·원래 caret까지 보존하도록 수정했다. 조합이 남은 Enter는
  순수 어댑터의 `finishKey`에서 소비해 URL navigate로 넘어가지 않는다.
- 기존 NFD→완성형 저장을 유지하며 incoming selectedRange도 함께 변환한다.
- AppSession은 주소창 진입 세대와 surface를 pin한다. 주소창↔팔레트 전환 뒤 오래된 키 콜백은
  현재 입력칸의 어댑터를 고르기 전에 차단한다. ABI 235로 런타임 구조 변경을 명시했다.
- 독립 사본의 변조 5종(뒤쪽 문자열 삭제, replacement 무시, rollback caret 복원 제거,
  취소 시 원문 유실, NFD 확정 정규화 제거)은 모두 런타임 검사에 걸렸다. 정상 대조군은 전후 통과했다.
  최초 사본 검사는 프로젝트 밖 mise가 다른 Zig를 골라 컴파일 단계에서 실패했으며 적대적 검증에
  포함하지 않았다. 재실행은 `mise exec zig@0.17.0`으로 컴파일러를 고정했다.
- 제품 앱 빌드 및 계측 앱 빌드를 통과했다. 실제 실행은 앱 자체의
  `CGPreflightScreenCaptureAccess=false`로 fixture·입력 소스·HID 변경 전에 종료됐다.
  고정 계측 앱 SHA-256은 `1fa90351f31e27712459162c6131947230e645194180acb69c8c1e023049d49c`다.

실제 시나리오는 `https://a.invalid/😀/z`의 이모지 선택을 fixture로 준비하고 실제 HID의
`ㅎ→하→한`으로 중간 선택 대체를 확인한다. 이후 후보창 5회 취소와 6번째 `韓` 선택을
관측하고, 제품 focus API로 원래 터미널에 돌아온 뒤 실제 `/` 1 byte를 확인한다.
선택 준비와 터미널 복귀는 fixture이므로 실제 마우스 선택·사용자 단축키 검증으로 주장하지 않는다.
관측 export는 읽기 전용이고 fixture export는 둘을 구분한다.

후보창의 전체 WindowServer inventory·소유권·생성/소멸·동일 series 검사는 기존
`reduceWindowTriplet/validateSeries`를 사용한다. `reduceWindowTriplet`은 window 권한 판정만
공개하며 텍스트와 콜백 카운터는 호출자의 별도 판정이 필수다. 기존 terminal/search reducer는
그대로 이 창 판정에 기존 의미 검사를 더한다. 주소창 artifact는 별도
`maru.address-ime-candidate.v1`이며 독립 Swift PNG/OCR 판정자는 기존과 동일한 이미지 결속·
파일·해시·크기·OCR 검사를 적용한다. 전체 URL·marked·owner·콜백·PTY·navigate 검사는
별도 독립 상태 판정자가 raw transcript와 결속한다. 기존 search schema에 URL을 가공해 넣지 않는다.

GUI harness와 로그·PNG는 저장소 밖 `maru-address-ime-live-20261024/`에 보존한다.
실제 GUI 성공 전에는 구현 전체 검증 완료로 표시하거나 머지하지 않는다.


주변 회귀 확인: Chrome 전체 1,132개 테스트와 기존 UI 1,211개 테스트가 통과했다.

최종 집중 gate는 주소창 호스트 회귀 18개와 순수 모델·발견 대조군 15개를 Debug/ReleaseFast 각각 통과했다. 모델의 의미 검사는 7개이며 나머지 8개는 모듈 발견용 test 블록이다. 전체 `check-boundaries`도 ABI 235 pin 동기화 후 통과했다.


## 권한 재등록 후 실제 실행과 시나리오 보완

첫 고정 앱은 권한 재등록 후 실제 URL 중간 이모지 선택을 `ㅎ→하→한`으로 교체하고,
한자 후보창 5회 생성·취소 및 원문 복원까지 관측했다. 전체 성공은 아니다.
한 실행의 iCloud 알림으로 전면 소유권이 바뀌어 HID guard가 중단한 결과도 분리했다.
외부 WindowServer 관측으로 첫 새 입력 변환은 89×266, 같은 글자의 반복 재변환은
102×295인 것을 확인했다. 동일 geometry를 요구하는 기존 series 판정에 다른 동작을
섞은 검증 시나리오 결함이었다. window/series 판정은 완화하지 않았다.

계측 드라이버가 매 회 주소창의 새 진입 세대와 이모지 선택 fixture부터 다시 시작하게 했다.
제품 편집 코드는 바뀌지 않았다. 변경한 관측 앱을 고정하고 입력 진단 2회를 실행해
각각 6회 중간 선택 대체·5회 후보 취소·6번째 한자 선택·터미널 `/` 복귀가 독립 상태
검사를 통과했다. 외부 WindowServer 관측에서도 첫 다섯 후보가 같은 89×266과 좌표임을 확인했다.
`diagnostic.json`은 `full_validation=false`이며, 후보 PNG 검증 완료로 주장하지 않는다.
선택 후 제품 GPU 캡처에서 `https://a.invalid/韓/z`와 suffix·caret도 직접 확인했다.

현재 고정 앱은 `291a1f1f8dbebc76d4dc0da49b09b67b68fb8e4d5da9c1268eec8ec86621e501`이다.
기존 TCC 허용은 이전 계측 앱 서명에 연결되어 새 앱은 `screen_capture=false`다.
`frozen-observer-v2.json`에 실제 계측 소스 전체의 해시를 보존하며, 공통 palette runner의
템플릿 해시를 실제 주소창 드라이버 해시로 오인하지 않는다. 외부 드라이버·probe 원본도 별도 보존했다.


## 실제 완료 결과

고정 앱 `291a1f…`의 `live-v2-2/validation.json`이 `passed=true`를 기록했다.
전체 WindowServer inventory와 창 ID 2056·2059·2062·2065·2068의 owner/생성/소멸을
공통 창 reducer·series 판정으로 확인했고, 각 PNG는 89×266과 OCR 한자 6행이었다.
독립 Swift 판정자는 이미지를 다시 열어 `candidate_capture_verifier=passed`를 기록했다.
실제 HID 31회, 조합 중간 상태 18개, 후보 취소 5회, 6번째 `韓` 선택과 터미널 `/` 1 byte를
독립 상태 검사로 확인했다. 선택·취소 후 suffix는 `/z`로 보존됐고 URL navigate는 0이었다.
최초의 macOS 화면 기록 알림이 전면을 가져가 중단한 실행은 별도 보존하고 성공에 포함하지 않는다.

기반 소스는 `cf3d1f4b7`에 이번 제품 패치와 외부 계측을 적용한 사본이다.
후속 main 리베이스의 빌드/단위/CI와 이 고정 앱 GUI 증거를 구분한다.
`tools/address-ime/`는 동일 scene의 드라이버·probe와 독립 판정자를 보존하고,
공통 source-copy 준비·GUI 실행·HID·입력 소스 복원·PNG/OCR 판정은 기존 도구를 재사용한다.
PNG와 실행 로그는 저장소에 넣지 않는다.

## 실제 포인터·단축키 후속

선택 준비와 터미널 복귀 fixture를 실제 클릭·드래그·Shift+Right·Escape로 대체하는 범위는
[주소창 실제 포인터 검증](address-field-ime-pointer.md)이 소유한다.
