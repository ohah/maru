# UI 요소 인스펙터

2026-10-20 사용자 승인: 호버 경계 강조, 클릭 선택 상세, 같은 데이터의 CLI 조회.
기존 terminal diagnostics와 별개인 읽기 전용 Elements 탭이다.

## 동작과 경계

- Chrome [Inspect mode](https://developer.chrome.com/docs/devtools/inspect-mode)의 공개 동작인
  도구 버튼 활성화 → hover 경계 → 클릭 선택을 참고한다. 참조 코드는 복사하지 않는다.
- `chrome.ui.inspection`은 paint/input이 소비하는 **발행된** `UiRectTree`를 읽는다.
  유효 clip과 좌표 변환을 적용하고 뒤에서부터 가장 위 요소를 고른다. disabled 요소도 읽을 수 있다.
- 대상은 사이드바 상단 버튼 판·검색, 파일 헤더의 보기 mode·breadcrumb·상태·충돌 도구, pane 탭·닫기·추가·좌우 스크롤 버튼, 사이드바 workspace 카드·그룹·닫기 버튼과 하위 세션 행·접기 토글·닫기 버튼, 상태바, 사이드바 scroll, pane divider, 표시 중인 파일·SCM·세션 도크의 발행 tree다.
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
- 사용자 이름·경로 label을 복사하지 않는다. 하위 세션 행·토글은 아래 절을 따른다. 원격 tmux pane 및 recovered 행은
  Inspector 범위 밖이다. 네이티브 accessibility 이관 완료를 뜻하지 않는다.
- pane 탭 바 확장은 아래 절을 따른다. 도크 뷰 바 확장은 아래 절을 따른다. 파일별 헤더는 아래 두 절을 따른다.
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

## 도크 뷰 바 발행 트리

- `chrome.components.dock_view_bar.published.Frame`이 도크 상단의 뷰 전환 6개와
  현재 뷰의 동작 버튼(탐색기 새로고침·전체 접기)을 `dock_header` source로 제공한다.
  파일별 mode 선택기는 아래 절을 따른다. breadcrumb·상태·충돌 도구는 아래 절을 따르며 sidebar 상단 도구는 아래 절을 따른다.
- 기존 `slotRect`/`actionRect`가 셀 정렬 geometry를 준비한다. host paint의 활성/hover 밴드와
  일반 포인터 입력은 유효한 publication rect를 소비하고 CoreText glyph lowering은 기존 셀 경로를 유지한다.
  첫 paint 전이나 레이아웃 변경 직후에는 기존 계산으로 입력을 처리하며 Inspector에는 낡은 tree를 내보내지 않는다.
- root → tab/button 부모 구조와 빈 label만 저장한다. 사용자 경로·이름·본문·native pointer는 보관하지 않는다.
  geometry·활성 뷰·동작 목록의 의미/순서가 바뀌면 publication generation이 바뀌어 이전 선택은 null이다.
- 고정 배열(root 1개 + view 6개 + action 최대 8개)로 할당 없이 발행한다.
  지원 한도를 넘는 동작 목록·숨김·높이/폭 0은 전체 publication을 폐기한다.
  좁은 바에서 그려지지 않는 버튼은 tree에도 없고 클릭되지 않는다. 기존 512-node 보고 한도는 유지한다.
- 같은 collector가 GUI와 `session inspect --json`의 nodes/tree/hovered/selected를 제공한다.
  읽기 전용 Pick, owner 창 backing-pixel 좌표, Pause·Escape·분리 창 계약은 그대로다.
- 실제 앱 하네스는 `tools/inspector-picker-app/run.py --dock-header --rounds 20`과
  독립 `verify_dock_header.py`를 사용한다. `MARU_INSPECTOR_WITH_DOCK=header-wide`는
  실제 수동 너비 360pt 도크를 여는 캡처 fixture이며 제품 기본 너비는 기존 설정을 따른다.

## 파일 보기 모드 선택기 발행

- `chrome.components.file_header.Frame`은 Markdown의 읽기·라이브·소스와 SVG의 읽기·소스
  버튼을 `file_header` source로 발행한다. 모드가 없는 kind는 발행하지 않는다.
  root의 rect도 실제 모드 strip으로 제한한다. breadcrumb·상태·충돌 도구는 별도 `file_header_details` source로 발행한다.
- kind별 선택지·상태 칸 예약·셀 분할 정책은 기존 L2 `dock_layout`이 소유한다.
  macOS `app_session/inspector_file_header.zig`가 실제 활성 파일 Term의 band와 mode rect를
  중립 rect 모델로 옮긴다. L3는 파일/세션 타입을 import하지 않는다.
- 실제 paint 전에 발행한다. hover 밴드와 일반 클릭·cursor hit-test는 유효한 발행 rect를 소비하며,
  CoreText의 mode label·bold 및 breadcrumb lowering은 기존 셀 경로를 유지한다.
  첫 paint 전·layout 변경 직후에는 기존 기하로 입력하고 Inspector에는 낡은 발행을 내보내지 않는다.
- source + ID + generation으로 선택을 묶는다. 실제 Term surface/entry 신원·kind·mode·dirty·외부 변경·
  충돌 구간·geometry·pane lifetime이 바뀌면 새 세대를 발행한다. cached Term은 live owner와 비교만 하며
  오래된 포인터를 역참조하지 않는다. 이름·경로·본문·native pointer를 발행 tree에 저장하지 않는다.
- 할당 실패·잘못된 mode 개수/중복 ID는 부분 발행을 폐기한다. tab reorder preview 중에는
  발행을 비우고 기존 canonical/preview 입력 경로를 유지한다. 다음 정상 frame은 다시 발행한다.
- GUI와 `session inspect --json`의 `elements.nodes/tree/hovered/selected`는 동일한 collector를 쓴다.
  owner backing-pixel·분리 창·읽기 전용 Pick·512-node 예산을 유지한다.
- 실제 앱은 기존 `MARU_FILE_PANEL`로 격리 Markdown/SVG 파일을 연다.
  `tools/inspector-picker-app/run.py --file-header --rounds 20`과 독립 `verify_file_header.py`가
  mode 전환 차단·정상 클릭 대조군·원본 파일 bytes 보존·다섯 배치·2×·취소·재열기를 확인한다.
  Metal 캡처는 chrome 증거이며 WKWebView 본문/DOM 검증을 뜻하지 않는다.

파일 mode의 child ID는 pane별 root ID + 1 + 기존 Mode 값(읽기 0·소스 1·라이브 2)이다. 문자열 label을 수집하지 않고도 CLI에서 구별할 수 있으며 generation이 다른 선택은 재사용하지 않는다.

## 파일 헤더 breadcrumb·상태·충돌 도구 발행

- `components/file_header/details.zig`는 실제 그린 breadcrumb 한 묶음·수정 점·재읽기·이전/다음 충돌 glyph의 중립 rect를 발행한다.
  `app_session/inspector_file_header_details.zig`는 `fileHeaderBandDrawList`가 만든 같은 DrawCell을 읽으므로 생략된 경로·숨긴 status를 재구성하지 않는다.
- source는 `file_header_details`, pane별 root는 `0x4644000000000000 + index * 0x100000000`이다.
  child는 root + 1 + Part(0 breadcrumb·1 modified·2 reload·3 previous·4 next)다.
  breadcrumb·modified는 action 없는 text, 나머지는 action 있는 button이다. root는 계층만 제공하는 0 크기 group이며 빈 여백에 Pick 영역을 만들지 않는다.
- breadcrumb는 실제 표시 글자의 첫/끝 셀 범위 한 묶음이다. 심볼 피커 마디별 자식 tree와 native accessibility 전체 이관은 이 범위에 포함하지 않는다.
  기존 심볼 마디 클릭은 기존 painted span 경로를 유지한다. 이름·경로·심볼 문자열·문서 본문·native pointer는 발행 tree에 저장하지 않는다.
- 일반 재읽기·충돌 이동 클릭과 hand cursor는 유효한 발행 rect를 읽는다. 첫 paint 전·layout/state 변경 직후에는 기존 L2 셀 기하를 사용하고 Inspector에는 낡은 tree를 주지 않는다.
  모드 버튼은 기존 `file_header` source를 유지한다. 기존 저장·reload 확인·충돌 이동 정책을 바꾸지 않는다.
- 소유 Term/entry·kind·mode·status·충돌 구간 유무·문서 revision·caret·breadcrumb 마디 신원·geometry·pane lifetime이 바뀌면 이전 선택을 폐기한다.
  실제 draw-list 수집 후 frame 전체를 원자적으로 발행한다. 부분 할당 실패·draw-list 실패·tab reorder preview는 전체 발행을 닫고 다음 정상 frame에서 복구한다.
- 네이티브 편집기의 수정 `*`는 현재 탭이 소유한다. 헤더에 그리지 않은 `modified`/`reload`를 Inspector만 만들어 내지 않는다.
  조건부 status는 실제 헤더 DrawList를 사용하는 host 통합 테스트로 검증하며 native E2E 20회와 구분한다.
- GUI Elements와 CLI `elements.nodes/tree/hovered/selected`는 같은 collector·source/ID/generation을 사용한다.
  읽기 전용 Pick·owner backing pixels·독립 창·Pause·Escape·512-node 예산을 유지한다.
  실제 앱 검증은 `tools/inspector-picker-app/run.py --file-details --rounds 20`과 독립 `verify_file_header_details.py`를 따른다.

## 사이드바 상단 버튼 판·검색 발행

- `chrome.components.sidebar.header.Frame`은 펼친 헤더의 검색·보기 옵션·새 workspace·사이드바 토글·알림 판을
  `sidebar_header` source로 발행한다. 접힌 상태는 펼치기 토글·알림 두 개만 발행한다.
  root ID는 `0x5348000000000000`, child는 root + 1 + Part(검색 0·보기 옵션 1·새 workspace 2·토글 3·알림 4)다.
- 검색은 focus action이 있는 text/cursor=text, 아이콘은 action이 있는 button/cursor=press다.
  계층용 root는 0 크기 group으로 빈 창 드래그 영역을 Pick 대상으로 만들지 않는다.
  이름·검색어·workspace 문자열·알림 내용·native pointer를 복사하지 않는다.
- `app_session/inspector_sidebar_header.zig`는 기존 header pill·접힘 rect·검색 밴드를 중립 rect로 옮긴다.
  실제 header frame 수집 때 발행하며 아이콘/검색 DrawList 실패는 전체 발행을 폐기한다.
  고정 6-entry buffer를 사용하므로 발행에 동적 할당이 없다. 잘못된/비유한 기하는 원자적으로 비우고 정상 frame에서 복구한다.
- 펼친 아이콘의 기존 3셀 click zone·알림 배지 원형 판정·토글 잉크 우선순위는 기존 정책이 소유한다.
  Inspector는 버튼 판 본체를 제공하며 배지 원/숫자를 별도 node로 합성하지 않는다.
  일반 hover paint와 판 입력은 같은 발행 rect를 읽고, 검색 입력·접힘 토글/알림도 같은 발행 rect를 읽는다.
  판의 clip은 아이콘 띠로 제한한다. 검색 밴드/창 드래그 여백을 새로 버튼 영역으로 넓히지 않는다.
- geometry·접힘·검색 focus가 바뀌면 generation으로 이전 선택을 폐기한다. 첫 paint 전·상태 변경 직후에는
  기존 기하로 입력하고 Inspector에는 낡은 발행을 보이지 않는다. 0-tab recovery chooser는 기존 Inspector 지원 범위 밖이다.
- GUI Elements와 CLI는 같은 collector를 사용한다. 읽기 전용 Pick·Pause/Escape·owner backing pixels·독립 창·512-node 예산을 유지한다.
  실제 앱은 `tools/inspector-picker-app/run.py --sidebar-header --rounds 20`과 독립 `verify_sidebar_header.py`로 검사한다.
  기존 `MARU_COLLAPSE_SIDEBAR` fixture로 접힘·1자리/9+ 알림 폭을 재현한다. native accessibility 전체 이관은 포함하지 않는다.


## 사이드바 하위 세션 행·접기 토글

- 기존 `sidebar` source와 `published.rowId(slot)`을 유지한다. 카드의 직계 자식으로
  `agent_toggle`은 button, `agent`는 list_item을 발행한다. 이 목록은 이름과 달리
  터미널·웹·파일을 포함한 Term 목록이며, 표시 조건과 실제 클릭 의미는 [사이드바 목록](../sidebar-agent-list.md)을 따른다.
- 실제 canonical 행의 rect/clip/action/cursor를 paint·일반 입력·Inspector가 공유한다.
  토글의 semantic expanded는 실제 접힘 상태에서 만들며, Inspector tree 자체의 펼침 상태와 구분한다.
  현재 CLI node는 기존 kind/role/action/enabled/cursor/geometry를 제공하며 제품의 활성 Term 표시 필드를 새로 합성하지 않는다.
- 이름·cwd·브랜치·대화·native pointer는 수집하지 않는다. 원격 `agent_pane`·복구 후보는 이 범위 밖이다.
  세션 닫기 버튼의 독립 node는 아래 절을 따른다. row Pick은 닫기 영역에서도 제품 action을 실행하지 않는다.
- 같은 row index가 다른 Term을 가리키지 않게 live Tab/Pane/Term 순서·surface ID·pane teardown epoch·
  활성 Term도 내부 signature로 검사한다. 주소는 현재 live 목록에서만 읽고 밖으로 내보내지 않는다.
  새 Term·재정렬·pane 이동/제거·focus 변경 뒤 예전 선택은 폐기한다.
- retained 사이드바의 기존 `reprojectSidebarIfRowLinesStale` paint 준비 경로는 높이가 같아도
  publication 소유자가 바뀌었으면 canonical 행과 밴드를 갱신한다. 읽기 전용 collector에서 재발행하지 않는다.
  reorder preview는 기존 정책대로 publication을 폐기한다. OOM과 첫 paint 전 fallback도 기존 계약을 따른다.
- GUI와 CLI는 같은 collector, source/ID/generation과 owner 창 backing pixels를 쓴다.
  Pick·Pause/Escape·분리 도구 창·512-node 예산을 유지한다.
  실제 앱 검증은 `tools/inspector-picker-app/run.py --sidebar-sessions --rounds 20`과
  독립 `verify_sidebar_sessions.py`를 사용한다. `MARU_FORCE_TAB_COUNT=3`은 기존 제품의 새 Term 경로를 사용한다.


## 사이드바 세션 닫기 버튼

- 기존 `sidebar` source의 `closeId(slot) = rowId(slot) + 1`을 하위 세션 행에도 사용한다.
  button/press 역할이며 parent는 그 세션의 list_item이다. 사용자 label과 native pointer는 수집하지 않는다.
  workspace 닫기 버튼은 기존 ID를 유지하며 토글·원격 tmux pane·복구 후보에는 닫기를 만들어 내지 않는다.
- x는 실제 glyph를 배치하는 `Columns.closeXRange`에서 받는다. y/높이와 유효 clip은 canonical 행에서 받는다.
  기존 일반 입력이 닫기 열을 행 전체 높이에 적용하므로 Inspector도 이 입력 범위를 제공한다.
  잉크의 작은 사각형으로 클릭 영역을 바꾸거나 버튼 배경을 새로 그리지 않는다.
- 일반 닫기 입력은 유효한 `Frame.closeContainsX`를 소비한다. 첫 paint 전·reorder preview·낡은 publication은
  기존 Columns 경로를 유지한다. clip 밖·오른쪽 경계·비유한 x·닫기 없는 행은 버튼으로 판정하지 않는다.
  일반 입력과 Pick은 같은 source/ID/generation·좌표를 사용한다. glyph lowering은 기존 Columns 기반 경로다.
- Pick은 정상 클릭을 소비해 close 확인창·focus 전환·실제 세션 닫기를 실행하지 않는다.
  일반 클릭은 `closeAgentRow → requestClose`를 유지한다. 실행 중 명령 확인은 `closeTargetHasRunningJob(target)`로
  실제 닫을 Term을 검사한다. 활성 Term의 상태를 대신 적용하지 않는다. 확인/취소·미저장 내용의 기존 정책을 유지한다.
  Term 제거로 행 index가 재사용돼도 이전 publication 선택은 폐기한다.
- 실제 앱 검증은 `run.py --sidebar-close --rounds 20`과 독립 `verify_sidebar_close.py`다.
  idle 셸과 실행 중 sleep은 기존 OSC 133 fixture 상태로 기술한다. 실제 CLI sessions 목록으로
  Pick 동안의 전체 surface ID 보존과 일반 클릭 후 정확히 지정한 surface 하나만 제거됐는지 검사한다.
  다섯 배치·독립 창·2× split·기본 cursor·취소·오른쪽 경계·재열기를 포함하며 구체 결과는 검증 매트릭스를 따른다.
