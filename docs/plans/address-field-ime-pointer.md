# 주소창 IME 실제 포인터·키 경로

상태: 2026-10-25 도구 구현·자동/적대적 검사·실제 포인터 입력과 후보 PNG/OCR 검증 완료. 기존 fixture 선택·focus 이동을 실제 이벤트로 대체한다.

## 범위와 계약

- fixture는 격리 HOME의 두 pane(터미널·빈 브라우저)과 표시 URL만 준비한다.
  주소창 진입·caret·selection·편집 종료·터미널 focus는 fixture에서 쓰지 않는다.
- 외부 CGEvent relay가 주소창 클릭 후 이모지 드래그 또는 Shift+Right로 선택한다.
  실제 한국어 HID 입력·후보창 5회 취소·6번째 한자 선택은 기존 검증을 유지한다.
  Escape로 편집을 끝내 다시 클릭하고, 마지막에는 다른 터미널 pane을 클릭한 뒤 `/` 입력을 확인한다.
- relay는 고정 PID의 전면 key window·fresh request/state·generation을 확인한다.
  포인터는 제품 레이아웃에서 읽은 주소창/터미널 본문 사각형 안으로만 보낸다.
  드래그 각 이벤트에서 전면 소유를 재확인하며 도중 owner 변경도 다음 이벤트를 차단한다.
  기존 키 allowlist와 source guard는 유지한다. Shift+Right 추가는 이 주소창 scene에만 허용한다.
- backing→view→screen은 기존 Swift 호스트 변환을, AppKit→Quartz는 공통 순수 변환을 사용한다.
  클릭은 편집 전에도 가능하므로 native web view의 firstResponder와 key window 소유를 구분한다.
  일반 키는 여전히 terminal view firstResponder를 요구한다.
- 읽기 전용 witness가 실제 byte caret/선택과 각 포인터 단계의 frame·source·owner를 기록한다.
  독립 판정자는 빈 선택→이모지 한 개 선택→한글 대체→한자→실제 다른 pane focus를 결속한다.

## 검증

먼저 screen capture 없는 diagnostic으로 실제 입력 전 과정을 확인한다. 이는 PNG 성공이 아니다.
그 뒤 동일 바이너리를 고정해 기존 window/series reducer와 PNG/OCR 판정을 수행한다.
새 서명에 실제 권한이 필요하면 모든 드라이버 보완·입력 진단을 마친 뒤 정확한 앱만 등록한다.
다른 owner·낡은 generation·잘못된 좌표/선택·직접 fixture 복귀 위장을 적대적 검증 5회로 공격하고
정상 대조군 전후 통과를 확인한다. 이미지·로그는 저장소 밖, 이미지는 PR에만 첨부한다.

범위 밖: 페이지 네트워크 탐색, 다른 입력칸 이관, point→character API 확장, 새 제품 기능 신설.
문제가 재현되면 제품의 원인을 고치고 관련 문서·헤드리스 회귀를 같은 PR에 추가한다.

## 현재 구현과 검증

- 전면 window·WindowServer 실제 창 bounds와 일치하는 목표 영역만 허용하는 순수
  `IMEPointerPolicy`를 추가했다. 드래그 중 소유권을 잃으면 이후 이벤트를 중단하고,
  이미 눌린 버튼의 정리는 원래 앱 PID에만 보낸다.
- 주소창 클릭·드래그와 Shift+Right 선택, Escape 종료와 다른 pane 클릭을 드라이버에 연결했다.
  fixture 함수는 topology/표시 URL만 준비하며 pointer mode에서 직접 focus 복귀는 거부한다.
- 좌표 변환은 제품 레이아웃과 기존 AppKit→Quartz 함수를 재사용한다. 의미 판정자는 실제
  byte caret 18과 선택 [18,22]를 확인해 surrogate를 나누는 선택을 성공으로 취급하지 않는다.
- Python 주소창 판정 9개와 macOS 정책/기존 팔레트 판정 8개가 통과했다.
- 별도 사본에서 fixture 위장·부분 이모지 선택·receipt 재사용·stale owner·잘못된 terminal
  focus를 허용하는 다섯 변조가 모두 실패했다. 정상 대조군은 전후 통과했다.
- 계측 앱과 전체 relay가 빌드됐다. 실제 diagnostic 첫 실행은 전면 `loginwindow`와
  화면 잠금 값 1 때문에 앱 activation 단계에서 멈췄다. 아직 포인터 입력이나 픽셀 성공이 아니다.

고정 소스·실행 로그는 저장소 밖 `maru-address-pointer-20261024/`에 보존한다.
전체 경계 검사도 통과했다. 실제 후보 PNG/OCR이 통과하기 전에는 전체 완료/머지를 주장하지 않는다.


## 실제 입력 진단 결과

`diagnostic-2`의 실제 입력은 끝까지 실행됐지만, 독립 좌표 판정이 이전 fixture처럼 커서 전진을
요구해 실패했다. 실제 선택은 이모지 끝(caret=22)에 있으므로 같은 2셀 한글로 대체하면 커서는
같은 열이어야 한다. fixture 경로의 기존 전진 검사는 유지하고 pointer 경로에만 동일 폭 선택의
좌표 검사를 명시적으로 적용했다. 잘못된 좌표 이동도 별도 부정 대조로 거부한다.

같은 바이너리의 `diagnostic-3`이 독립 판정까지 통과했다. 실제 요청 49개,
클릭·선택·pane 복귀 관측 13개와 조합 18개를 결속했다. 6회 모두 실제 주소창 클릭 후
짝수 회차는 드래그, 홀수 회차는 Shift+Right로 이모지 전체를 선택했다.
실제 Escape로 다시 진입했고 마지막은 다른 pane 클릭과 `/` 입력 1 byte로 끝났다.
외부 WindowServer 관측도 6개 후보창 ID 2579·2583·2587·2591·2595·2599가
모두 89×266, 같은 좌표임을 확인했다. 이는 PNG/OCR 증거가 아니다.

고정 계측 앱 SHA-256은 `52dab85a441d265ea4e39ecfa72c19a04f4f1c2d78ff1c508e25421330999526`이며
기반은 main `306ec2429`다. 앱은 바꾸지 않고 입력 진단 후 독립 Python 판정만 보완했다.
`screen_capture=false`라 해당 앱의 화면 기록 등록을 마친 뒤 같은 앱으로 full 검증을 수행한다.


## 실제 PNG/OCR 완료 결과

같은 고정 앱 `52dab85…`의 `live-2/validation.json`이 `passed=true`를 기록했다.
처음의 추가 macOS 화면 접근 확인창이 전면을 차지한 실행은 HID owner guard가 중단했고,
사용자가 허용한 화면 캡처 권한의 시스템 확인창에서 허용한 뒤 앱을 바꾸지 않고 재실행했다.

- 실제 후보 ID 2633·2637·2641·2645·2649, 각각 89×266 PNG와 한자 OCR 6행.
- 기존 window/series reducer와 별도 Swift 이미지 재검사 `candidate_capture_verifier=passed`.
- 외부 실제 HID 요청 49개, 클릭/선택/pane 관측 13개, 조합 중간 상태 18개를 독립 판정했다.
- 6회 실제 주소창 클릭, 3회 드래그·3회 Shift+Right 선택, 5회 실제 Escape 후 재진입,
  5회 후보 취소·6번째 한자 선택·다른 pane 클릭·터미널 `/` 1 byte를 확인했다.
- 후보 선택 후 URL `https://a.invalid/韓/z`의 suffix와 caret, 터미널 복귀 제품 GPU 캡처도 확인했다.

선택과 복귀에 fixture 편집/focus 함수를 쓰지 않는다. fixture는 두 pane과 표시 URL의 준비에만 쓴다.
페이지 네트워크 탐색의 실측은 아니다. 고정 앱은 main `306ec2429` 기반이며 이후 리베이스의
빌드/CI와 이 GUI 실측을 구분한다. 캡처·로그는 저장소 밖 `maru-address-pointer-20261024/live-2`에 보존한다.
