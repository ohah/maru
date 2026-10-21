# UI 요소 인스펙터

2026-10-20 사용자 승인: 호버 경계 강조, 클릭 선택 상세, 같은 데이터의 CLI 조회.
기존 terminal diagnostics와 별개인 읽기 전용 Elements 탭이다.

## 동작과 경계

- Chrome [Inspect mode](https://developer.chrome.com/docs/devtools/inspect-mode)의 공개 동작인
  도구 버튼 활성화 → hover 경계 → 클릭 선택을 참고한다. 참조 코드는 복사하지 않는다.
- `chrome.ui.inspection`은 paint/input이 소비하는 **발행된** `UiRectTree`를 읽는다.
  유효 clip과 좌표 변환을 적용하고 뒤에서부터 가장 위 요소를 고른다. disabled 요소도 읽을 수 있다.
- 대상은 pane 탭·닫기·추가·좌우 스크롤 버튼, 사이드바 workspace 카드·그룹·닫기 버튼, 상태바, 사이드바 scroll, pane divider, 표시 중인 파일·SCM·세션 도크의 발행 tree다.
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

## 첫 선택기 구현과 검증 (2026-10-20)

구현 완료. 중립 모델·host 연결·Elements 표시·실제 NSEvent/Metal/CLI 하네스를 제공한다.
최종 Debug/ReleaseFast 61+11개, Chrome UI 1,166개, CLI 703개와 전체 경계 검사를 통과했다.
적대적 E2E 20/20과 제품 PNG 64장은 [검증 매트릭스](../verification-matrix.md)의 UI 요소 절을 따른다.
원격 CI와 머지는 PR checks에서 별도로 추적한다.
물리 HID·OS IME·다중 모니터 증거와 callback/Metal 검증을 구분한다.

## Elements 계층 탐색 (2026-10-21 승인)

- Chrome [DOM tree 탐색](https://developer.chrome.com/docs/devtools/dom)의 계층 선택·검색 UX를 참고한다.
  Maru는 발행 UI 트리의 읽기 전용 검사로 범위를 한정하며 reference 코드를 복사하지 않는다.
- `chrome.ui.inspection.hierarchy`가 발행 순서·source·generation을 기준으로
  부모/자식, 깊이, 자식 유무, 펼침 상태와 검색 일치를 계산한다. GUI와 CLI가 같은 함수를 쓴다.
  앞서 발행된 유일한 부모만 인정하므로 잘린 부모·모호한 ID·역방향 참조는 루트로 표시한다.
  source나 publication을 넘어 부모를 연결하지 않으며 재귀 없이 최대 512개를 처리한다.
  내보내는 depth는 실제 깊이이고 화면의 들여쓰기만 최대 16단계로 제한한다.
- Elements는 들여쓴 노드 행, 왼쪽 펼침 표시와 선택 상세를 제공한다. 펼침 표시의
  28pt 영역은 가지를 접고 펼친다. 나머지 행 클릭은 선택만 바꾸며 제품 action을 실행하지 않는다.
  선택 행의 source·kind/role·geometry와 하단 kind/role/publication·action/enabled/cursor·bounds를 표시한다.
  낮은 도크에서는 중복 요약 밴드를 생략해 트리 행 공간을 확보한다.
- 필터는 source, kind, role, 십진수 ID를 대소문자 구분 없이 찾는다. 일치 노드와 부모 경로를
  함께 표시하고 검색 중 접힘을 무시한다. 검색을 지우면 기존 접힘이 복원된다.
- 화면 Pick은 선택 경로의 부모만 펼치고 필터를 지우며 선택 노드까지 스크롤한다.
  트리 선택도 현재 발행 identity로 재검증하고 소유 창의 경계 강조와 상세에 연결한다.
  Pick 활성 중 트리 행을 선택해도 Pick을 종료해 hover가 선택 경계를 가리지 않게 한다.
  사라진 요소와 다른 publication으로 바뀐 목록 행은 재선택하지 않는다.
- `session inspect --json`의 `elements.tree`는 현재 검색/접힘을 반영한 preorder 행이다.
  각 행은 `key`, `parent`, `depth`, `children`, `expanded`, `matched`, `node`를 제공한다.
  `elements.collapsed`와 `elements.query`, 기존 `nodes`·`selected`·`hovered`도 함께 노출한다.
  조회 CLI는 읽기 전용이며 GUI가 Paused여도 새 표본을 수집한다.
- Paused 상태의 명시적 트리 선택/펼침은 Refresh처럼 표본을 한 번 갱신한다.
  Paused 상태 자체는 유지한다. Pick은 기존 계약대로 Live로 전환한다.
- 실제 앱 검증: `tools/inspector-tree-app/run.py`는 격리 HOME의 실제 git 작업 디렉터리와
  Codex archive를 만들고 제품 파일·SCM·세션 도크를 연다. 실제 NSEvent 클릭, native cursor,
  Metal readback과 CLI 왕복으로 선택·접기·검색·복원·Pick을 검사한다.
  테스트 fixture의 `MARU_INSPECTOR_WITH_DOCK=scm/sessions`는 해당 제품 도크를 연다.

계층 탐색의 최종 Debug/ReleaseFast·Chrome UI·전체 경계·실제 앱 20회 및 추가 선택기 회귀 10회는
[검증 매트릭스](../verification-matrix.md)의 Elements 절에 기록한다.


## 사이드바 발행 트리 (2026-10-21 승인)

- `chrome.components.sidebar.published.Frame`이 canonical 행에서 카드·그룹·닫기 버튼과
  스크롤 컨테이너의 rect/clip/parent/semantic role을 발행한다. 새 `sidebar` source는
  GUI Elements와 CLI `elements.nodes/tree/hovered/selected`에서 동일하게 제공한다.
- 일반 프레임의 밴드 view와 행 입력은 이 발행 geometry를 소비한다. CoreText 텍스트와
  색상 lowering은 기존 host 경로를 유지하며, Inspector에서 별도 좌표를 만들지 않는다.
- 상단 헤더와 하단 상태바를 제외한 viewport로 clip한다. 카드 닫기 영역은 기존 입력의
  실제 close 열 × 카드 높이를 반영한다. glyph 크기로 임의 축소하지 않는다.
- source/row ID/publication generation으로 선택한다. 행 순서·깊이·접힘·geometry·활성 상태와
  host workspace identity가 바뀌면 세대를 갱신한다. host identity는 내부 Tab 주소 순서와
  teardown epoch로 구분하며 주소 자체를 내보내지 않는다. 할당 실패는 예전 발행을 폐기한다.
- 카드 reorder 중에는 paint의 preview 행과 입력의 canonical 행이 의도적으로 다르므로
  사이드바 카드 publication을 폐기하고 Inspector에서 제외한다. 기존 drag 경로를 유지한다.
- 사용자 이름·경로 label을 복사하지 않는다. agent/recovered 행은 공유 geometry의 일부지만
  이번 Inspector 카드·그룹 범위에서는 제외한다. 네이티브 accessibility 이관 완료를 뜻하지 않는다.
- pane 탭 바 확장은 아래 절을 따른다. 도크 헤더 확장은 후속 범위다.
- 이번 PR의 적대적 검증은 사용자 요청에 따라 최초 **5회 + 추가 5회, 누적 10회**다
  (기본 20회에 대한 이번 작업의 예외).
  실제 앱·CLI·Metal PNG와 정상 입력 대조군, 컴파일 결함 5종의 결과는
  [검증 매트릭스](../verification-matrix.md)의 사이드바 절을 따른다.


## Pane 탭 바 발행 트리

- `chrome.components.tabbar.published.Frame`이 실제 pane 탭 바의 container → tab → close 및
  plus/left/right 버튼 tree를 발행한다. `pane_tabs` source를 GUI Elements와 같은 CLI collector에 추가한다.
- `Metrics.rawSegOf`는 발행을 준비하는 기존 컬럼 분할이다. 일반 paint/input의 `Metrics.segOf`와
  plus/scroll hit-test는 유효한 발행 rect를 소비한다. 활성 탭·제목·버튼 배경을 같은 geometry로 그린다.
  버튼 폭은 실제 컬럼 끝으로 제한하므로 남는 부분 픽셀을 클릭 영역으로 넓히지 않는다.
- `app_session/inspector_tabs.zig`는 실제 leaf layout에서 publication을 만들고 live pane/Term 순서·활성 상태·
  메트릭·pane teardown epoch를 검사한다. Inspector는 기존 publication의 유효성만 검사하고 별도 tree를 만들지 않는다.
  pane/Term 포인터와 이름·경로·URL을 내보내지 않는다.
- source/row ID/publication generation으로 선택을 고정한다. 순서·메트릭·활성 상태·모델 신원이 바뀌면
  낡은 선택은 null이다. pane별 ID 영역을 나눠 split의 같은 탭 index가 충돌하지 않는다.
- 첫 native viewport/paint 전과 tab reorder preview에는 기존 입력·그리기 경로를 유지하고
  해당 pane tab publication을 Inspector에서 제외한다. 기존 preview/canonical 매핑과 drag owner를 바꾸지 않는다.
  부분 발행 OOM은 전체 publication을 폐기한다. label/native accessibility 전체 이관 완료를 뜻하지 않는다.
- CLI는 `elements.nodes/tree/hovered/selected`에서 `pane_tabs`를 제공한다. 좌표는 기존대로 owner 창의
  backing pixels이며 분리 Inspector 창의 좌표로 바꾸지 않는다. 기존 512-node 한도를 유지한다.
- 실제 앱 검증은 `tools/inspector-picker-app/run.py --pane-tabs --rounds 20`을 사용한다.
  기존 `MARU_FORCE_TAB_COUNT`/`MARU_FORCE_SPLIT`으로 실제 Term 생성·split 경로를 실행한다.
  새 제품 의존성·설정·ABI 변경은 없다. 최종 회차·증거는 [검증 매트릭스](../verification-matrix.md)를 따른다.
