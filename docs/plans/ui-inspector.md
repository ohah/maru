# UI 요소 인스펙터

2026-10-20 사용자 승인: 호버 경계 강조, 클릭 선택 상세, 같은 데이터의 CLI 조회.
기존 terminal diagnostics와 별개인 읽기 전용 Elements 탭이다.

## 동작과 경계

- Chrome [Inspect mode](https://developer.chrome.com/docs/devtools/inspect-mode)의 공개 동작인
  도구 버튼 활성화 → hover 경계 → 클릭 선택을 참고한다. 참조 코드는 복사하지 않는다.
- `chrome.ui.inspection`은 paint/input이 소비하는 **발행된** `UiRectTree`를 읽는다.
  유효 clip과 좌표 변환을 적용하고 뒤에서부터 가장 위 요소를 고른다. disabled 요소도 읽을 수 있다.
- 첫 대상은 상태바, 사이드바 scroll, pane divider, 표시 중인 파일·SCM·세션 도크의 발행 tree다.
  미발행 chrome 영역, terminal cell, 웹 DOM은 미지원이며 `elements.coverage`에 명시한다.
  전체 앱의 완성된 component tree를 제공한다고 표현하지 않는다.
- 각 node는 source + ID, parent ID, generation, kind/semantic role, 원래·보이는 rect,
  action ID/enabled, cursor를 제공한다. 문자열 label과 사용자 본문은 수집하지 않는다.
- CLI frame 예산을 위해 topmost node 최대 512개를 보관한다. `node_limit`과
  `limit_reached`로 한도 도달을 노출하며 이 경우 전체 트리라고 표시하지 않는다.
- 좌표는 **소유 앱 창의 backing pixel**이다. 분리 도구 창에서도 검사 대상 창은 바뀌지 않는다.
  SCM·세션 도크의 local tree는 실제 입력 경로와 같은 content offset으로 변환한다.
- 선택은 borrowed entry/배열 index가 아니라 source + ID로 보유한다. 목록 row는 publication
  generation도 고정해 새 목록의 같은 ID로 잘못 넘어가지 않는다. Index ID를 쓰는 divider도 세대를 고정한다. 사라진/낡은 요소는 null이다.
- Pick은 명시적으로 Live로 전환한다. Escape·Pick 재클릭·닫기·Pause·모달이 취소한다.
  선택 클릭과 up을 소비해 아래 버튼/터미널을 실행하지 않는다. 기존 drag owner를 빼앗지 않는다.
- `maru session inspect <surface> --json`의 additive `elements`는 GUI와 같은 collector다.
  여기의 window는 target surface의 owner 창, nodes는 그 창의 현재 표시 UI다.
  paused GUI의 고정 표본과 CLI의 새 live 표본은 시각이 다를 수 있다.
- UI 도구 상태는 workspace restore에 저장하지 않는다. 새 의존성·ABI 변경은 없다.

## 구현과 검증

구현 완료. 중립 모델·host 연결·Elements 표시·실제 NSEvent/Metal/CLI 하네스를 제공한다.
최종 Debug/ReleaseFast 61+11개, Chrome UI 1,166개, CLI 703개와 전체 경계 검사를 통과했다.
적대적 E2E 20/20과 제품 PNG 64장은 [검증 매트릭스](../verification-matrix.md)의 UI 요소 절을 따른다.
원격 CI와 머지는 PR checks에서 별도로 추적한다.
물리 HID·OS IME·다중 모니터 증거와 callback/Metal 검증을 구분한다.
