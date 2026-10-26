# 심볼 피커 IME 범위 문맥

상태: 범위 덧붙임 실패 재현과 수정 완료. 집중 호스트 검사와 실제 AppKit/Metal 회귀 통과. 제품 변이 5종·정상/원복 대조군 통과. 전체 ABI·경계·Swift·문서 게이트도 통과했다.

## 보존할 계약

파일 안 심볼 검색과 breadcrumb 형제 범위 피커의 기존 공용 palette UI를 유지한다.
workspace symbol 검색은 이 피커의 기능이 아니며 이번 범위에 추가하지 않는다.
확정 query로만 목록을 필터하고 preedit는 표시만 한다. 후보 Return은 이동·닫기로 재생하지 않으며
별도 Return만 기존 accept 경로를 따른다. preview 중 정본 선택·스크롤·Undo·탐색 이력은 바꾸지 않는다.

UTF-16 범위·선택·취소·깊은 키 snapshot·OOM rollback은 기존 중립 overlay_input_ime를 재사용한다.
query/preedit에 새 고정 길이 제한이나 Unicode 정규화를 추가하지 않는다. 기존 palette의 표시와
caret이 같은 projection을 읽게 한다. 필터 결과는 기존 목록을 교체하기 전에 별도로 준비한다.
공용 모델이 키의 잠정 query를 계산한 뒤 필터 준비에 실패하면 같은 키 snapshot으로 입력도
되돌린다. 이 동기 경로는 중간에 event loop로 돌아가거나 외부에 반쪽 결과를 게시하지 않는다.
범위 오류·할당 실패는 query·preedit·선택 행·행 목록을 함께 보존해야 한다.

## 소유와 수명

macOS adapter는 열기 세대, 활성 surface, 문서 registry/handle/revision과 형제 scope를 owner로 본다.
닫기·재열기·pane/문서 교체·revision·scope 전환, modal·terminal pin·빈 topology·포화에서
오래된 키가 새 입력을 쓰지 못하게 한다. bit 53 namespace를 사용하며 Session Dock의 token 상한도 낮춘다.
순수 편집 정책은 중립 모듈에 유지하고, host에는 owner와 필터 publication만 둔다.

## 검증

실제 editor fixture에서 a😀z의 UTF-16 (1,2)를 韓으로 교체하는 실패를 먼저 재현한다.
중간/빈 범위·surrogate·NFD·잘못된 UTF-8·취소/확정·후보/독립 Return·다중 콜백·OOM·다음 키 회복,
문서/범위/열기 세대 전환과 preview 정본 보존을 포함해 서로 다른 20개 이상 조건을 검사한다.
컴파일되는 제품 변이와 정상/원복 대조군으로 판정 효과를 확인한다. 기존 심볼 preview·palette·활동 IME
회귀와 전체 ABI·경계·Swift·문서 검사를 수행한다. 실제 입력과 PNG/OCR은 별도 증거로 구분하고
이미지는 저장소에 커밋하지 않는다.

## 확인된 내용

기존 경로에서 기대 `a韓z` 대신 `a😀z韓`이 되는 실패를 재현했고 공용 projection 연결 후 통과했다.
심볼 결과는 기존 filter를 공유하는 준비 함수에서 별도로 구성한 뒤 게시한다. 할당 실패를
snapshot부터 각 필터 label allocation까지 순회하는 검사는 원래 query·50행·선택 37을 보존하고
정상 대조군에서 target4·10행·선택 0이 되는지 확인했다. 호스트 artifact 31개와 기존 Inspector·활동 IME 회귀가 통과했다.

기존 `tools/symbol-preview-app`의 실제 NSTextInputClient 콜백에 `sample😀4` 중간 non-BMP 삭제를 추가했다.
이 경로는 실제 AppKit/Metal 회귀이며 물리적 한국어 HID나 OS 후보창 픽셀 증거로 계산하지 않는다.

실제 GUI는 첫 시도에서 기존 도구가 view에 직접 콜백을 주입해 owner 검사를 통과하지 못했다.
제품 검사를 우회하지 않고 도구를 현재 NSTextInputContext.client로 연결한 뒤 8개 상태가 통과했다.
sample😀4의 emoji 범위를 삭제하면 sample4·10행이 표시되고, 취소 시 revision/선택/스크롤/이력이
유지됐다. 별도 Enter 뒤에만 offset 2590으로 이동하고 탐색 이력 1개가 생겼다.
8개 제품 Metal PNG는 `../maru-symbol-picker-ime-gui-20261027-client/artifacts/`에 있으며 저장소에 넣지 않는다.

제품 변이는 범위 무시·필터 실패 rollback 누락·조합 조기 publication·scope owner 누락·후보 Return 누출이다.
각각 컴파일 뒤 단언 실패를 확인했고 정상/원복 제어도 통과했다.
명령은 `python3 tools/symbol-picker-ime/mutations.py --output <new-external-dir>`이며
원시 로그는 `../maru-symbol-picker-ime-mutations-20261027/`에 있다.

전체 ABI는 7,102개 중 6,983 통과·119 skip·0 실패였다. 경계·Swift·문서 링크/config/줄 참조,
명령 팔레트 집중 회귀, fmt/diff 검사도 통과했다. 물리적 한국어 HID·OS 후보창 검증과
전체 mise run check/필수 CI 결과는 이 로컬 증거에 포함하지 않는다.
