# ScrollArea 이관 구현 계획

흩어진 스크롤 구현을 ScrollArea 컴포넌트 하나로 모으는 이관(SV0~SV6)의 구현 계획이다. 계약의 단일 출처는 [ScrollArea](../scroll-area.md)다.

## ScrollArea 이관 (설계 완료 — 구현 미착수)

계약 단일 출처는 [ScrollArea](../scroll-area.md)다. 이 절은 순서와 상태만 소유한다.

지금 스크롤하는 곳이 일곱(Session Dock·파일 탐색기·소스 컨트롤·사이드바·알림 패널·팔레트/세팅·탭 바)인데
좌표 단위와 발행 경로가 모두 다르고, 같은 규율을 각자 다시 발견하다 매번 다른 것을 빠뜨렸다 — 탐색기는 tick 소비 누락("놓아야 움직이는" 스크롤바), 도크는
tree 교체에서 capture carry 누락(드래그가 첫 move에 죽음)·스크롤바가 목록 위에 겹침·장식 quad clip 누락.
넷 다 사용자 보고로 돌아왔다. ScrollArea는 그 규율을 한 번만 맞게 두는 자리다.

- **SV0 — 판정자 먼저(완료).** 도크 골든 어디에도 스크롤바 픽셀이 없었다 — Lab fixture가
  `scroll_content_height_px`를 채우지 않아 `scrollbarGeometry`가 `null`을 냈다(항목 수 무관). `scrollbar`
  Lab 시나리오와 `scrollbar-track-and-thumb` 골든 case로 닫았고, 스크롤바 발행을 막으면 2970픽셀 차이로
  실패하는 것을 확인했다. 캡처가 한 장만 없을 때 그 case를 건너뛰던 게이트 구멍도 `MARU_REQUIRE_GOLDEN`
  에서 실패하도록 함께 닫았다.
- **SV1 — Session Dock에서 추출.** 가상화·픽셀 offset·스크롤바·드래그·키보드 스크롤을 모두 쓰는
  유일한 소비처라 여기서 뽑으면 계약이 처음부터 전부 드러난다. 한 PR로 리뷰하기에 너무 커서 셋으로
  나눈다. 시각·동작 무변경이 셋 모두의 완료 기준이고, **SV0가 추가한 스크롤바 골든**이 그 판정이다
  (기존 네 장만으로는 판정되지 않는다).
  - **SV1a — 좌표계 추출(완료).** `session_dock/scroll.zig`를 `chrome/ui/scroll_area.zig`로 옮기고 도크
    전용 파일은 지운다(shim 없음). `project`가 도크의 `Kind`/`Metrics` 대신 comptime 높이 함수를 받아,
    그룹 헤더·카드·펼친 카드라는 예외가 host의 `ArchiveScrollItems` 한 자리로 모인다. 변이 검증에서
    드러난 무판정 구간(`withOffset`·`clamp`·무변화 반환값·host가 넘기는 높이/간격/개수/펼침 예약)을
    함께 닫았다.
  - **SV1b — 발행과 clip을 `build`로(완료).** 도크가 손으로 하던 세 단계(컨테이너 build → 자식
    평행이동 → 스크롤바 append)를 `tree.scrollArea` 선언 하나로 접고 그 처리를 `tree.build`로 옮겼다.
    스크롤바가 배열 끝의 `parent_index = null`에서 preorder 안으로 들어와 `UiRectTree`의
    preorder·subtree-range 불변식이 지켜지고 root가 하나로 돌아왔다.
    **clip 예외가 사라졌다**: gutter를 컨테이너가 자기 폭에서 예약하므로(CSS `scrollbar-gutter`,
    taffy `content_box_inset`) 스크롤바가 자기 컨테이너 clip 안이다. 조상 padding을 빌리던 옛 구조는
    조상 clip 예외를 강요했고 그 규칙은 padding 없는 소비처(SV2)에서 무너진다.
    시각은 불변이다 — 골든 다섯 장이 갱신되지 않았다. 고정 chrome이 오른쪽 여백을 `margin.right`로
    직접 갖게 하면서 도크의 `width: percent 1` 아홉 곳을 걷어냈다(percent는 border box 전체 크기라
    margin을 무시한다). 스크롤 자식의 `shrink = 0`을 컨테이너가 소유하는 것은 아직 남았다.
    **clip 경로가 둘이라는 것을 먼저 알고 들어간다.** 도크 텍스트의 실제 자르기는 measured 경로의
    `Artifact.appendGpuGlyphs`가 한다 — glyph마다 clip과 교차시켜 UV까지 줄이는 **부분 잘림**이고,
    적용 여부는 `placement.scroll_clipped`가 정한다. 반면 `Op.text.clip`은 셀 격자로 내리는 경로
    (`metal_lowering.placeText` — 모달)용이라 **도크에는 타지 않는다**(SV1a에서 그 판정을 통째로 막아도
    Lab 캡처가 픽셀 하나 안 바뀌는 것을 확인했다). 그래서 도크의 잘림 픽셀은 골든이 이미 보고 있고,
    SV1b가 지켜야 할 것은 `scroll_clipped` 소속 판정과 그 clip 사각형의 출처다.
  - **SV1c — 측정 pass와 drag 헬퍼(완료).** 뷰포트 높이 복제를 없앴다 — 자식 없는 scroll-area로
    layout을 한 번 돌려 그 값을 layout에게 묻고, `fixedChromeHeight`는 소비처가 사라져 지웠다.
    host의 drag 세 지점은 `scroll_area.Drag`로, 분수 휠 잔여와 그 산술(방향 전환 폐기·정수부 소비·
    overflow 가드)은 `State.scrollByWheel`로 모았다. `Drag`가 `interaction`을 import하지 않는 것이
    계약이다 — 그쪽이 `tree`를 쓰고 `tree`가 `scroll_area`를 쓰므로 순환이 된다. 그래서 이벤트가
    아니라 좌표만 받고 payload 판정은 소비처가 한다.
    **남은 것**: 스크롤 자식의 `shrink = 0` 소유 이관(§4.3), selection follow(§4.5).
- **SV1d — 그룹 헤더 sticky.** 지금은 스크롤하면 그룹 헤더가 밀려 올라가 글자가 반쯤 잘리고 "어느
  그룹인가"가 사라진다. [ScrollArea](../scroll-area.md) §4.7이 계약이다 — clamp 산술은 ScrollArea가, 무엇을
  붙일지는 소비처가 정한다(가상화 때문에 그 헤더는 창 밖일 수 있고, 창 밖 항목이 어느 그룹인지는
  domain만 안다). 높이는 그대로 자리를 차지하고 그리는 y만 clamp하므로 `project`의 content 높이·창
  계산·anchor 규칙이 바뀌지 않는다. **SV1b 뒤에 한다** — 발행이 `build`로 옮겨간 뒤라야 sticky 노드를
  preorder 안에서 낼 수 있고, 그 전에는 스크롤바처럼 배열 끝에 붙이는 임시 형태가 하나 더 생긴다.
  판정자: 그룹 둘 이상인 Lab 시나리오를 offset 셋(헤더 앞·지나침·다음 헤더 접근)으로 캡처한 골든.
- **SV2 — 파일 탐색기 이관.** 행 단위 좌표를 backing pixel로 옮기는 것이 실제 변경이다. 부분적으로
  보이는 행이 생기므로 행 기반 hit-test·reveal·follow가 픽셀 좌표를 읽도록 함께 바뀐다. 별도 스크롤바
  tree(`file_tree_scrollbar.publish`)와 전용 capture 경로는 이 단계에서 제거한다.

  **코드를 읽고 확인한 것**(SV1d 직후 조사). 이 셋이 단계 나눔을 정한다.

  1. **탐색기 행 텍스트는 셀 격자 draw list다**(`coretext_frame_builder.buildFileTreeDrawList` → `collectShaped`).
     도크처럼 measured 경로가 아니다. 그런데 **옮길 필요가 없다** — `PanePlacement`는 이미 픽셀
     `origin_y`와 `clip_rect`를 갖는다. 부분 행은 draw list를 `offset / cell_h` 행부터 만들고 pane 원점을
     `offset % cell_h`만큼 올린 뒤 content rect로 자르면 나온다. 행 하이라이트 quad도 이미 픽셀 위치라
     같은 편향만 받는다. 셀 텍스트를 measured로 옮기는 것은 SV2의 범위가 **아니다**.
  2. **탐색기 콘텐츠는 어떤 `UiRectTree`에도 없다.** 스크롤바조차 tree로 그리지 않는다 — 실제 그림은
     host의 GPU quad이고 `file_tree_scrollbar.publish`는 **스모크 probe 전용**이다(rect 두 개를 만들어
     thumb 좌표를 실어 보낸다). 그래서 `tree.scrollArea`는 SV1c가 만든 **자식 없는 measure pass**
     형태로 쓴다 — 컨테이너가 뷰포트와 gutter를 소유하고 track/thumb을 내되, 행은 그 content rect
     안에서 셀 경로가 그린다.

     이관하면 **idle fade가 함께 옮겨진다.** 지금 탐색기 스크롤바는 host가 `file_tree_scrollbar_idle_ticks`
     로 흐리는데 도크 스크롤바에는 그 개념이 없다(§8). 둘 중 하나로 통일할지, ScrollArea가 fade를
     소유할지는 SV2b가 정한다 — 지금 결론을 적지 않는다.
  3. **탐색기에는 시각 골든이 없다.** Chrome Lab은 `session_dock`·`archive_detail`만 그리고, CI의
     "file explorer macOS product path" 잡은 셰이더 스모크와 **도크** 골든을 돌린다. 즉 지금 탐색기
     스크롤을 통째로 망가뜨려도 초록이다 — SV0 직전의 도크와 같은 상태다.

  그래서 **SV2-0이 먼저다**(SV0와 같은 이유). 슬라이스:

  - **SV2-0 — 판정자.** 탐색기 행·스크롤바를 실제로 보는 게이트를 만든다. 판정 기준은 하나다 —
     **부분 행 하나를 없애면 빨개져야 한다.**

     **Lab은 이 소비처의 게이트가 될 수 없다.** 도크에서 Lab이 판정자인 이유는 도크의 기하·페인트가
     `session_dock.build`/`view`라는 **제품 컴포넌트**에 있어서다. 탐색기는 그 로직이 `app_session`에
     있고(행 하이라이트 quad, 스크롤바 quad, fade, reserved 칸 수), Lab이 그것을 다시 쓰면 골든은
     제품이 아니라 그 복제본을 판정한다 — 이미 한 번 밟은 함정이다([ScrollArea](../scroll-area.md) §10.1
     "테스트가 제품 경로를 태우는지 본다").

     그래서 **`test-macos-file-explorer-perf`가 쓰는 하네스를 쓴다.** 그 스텝은 `app_host_abi` 모듈에서
     실제 `AppSession`을 헤드리스로 만들어 탐색기 hot path를 돌린다 — 제품 경로 그대로다. 여기에
     기하 판정을 더한다: 주어진 픽셀 offset에서 draw list의 **시작 행**, 만드는 **행 수**(부분 행 몫
     +1), pane **원점 편향**(`offset % cell_h`), **clip rect**. 넷 중 하나만 틀어져도 부분 행이 사라지거나
     겹친다.

     **⚠️ 이 전제는 틀렸다(SV2-0에서 코드로 확인).** `PanePlacement.clip_rect`는 필드로 있지만
     **셀 경로에서는 아무도 읽지 않는다.** `app_session`은 `c.measured_text`가 있을 때만 그 값을
     쓰고(measured 전용), `metal_frame`이 scissor로 만드는 것은 **오버레이(모달) 프레임 하나**뿐이며
     그것도 프레임당 rect 하나다(`modal_clip`). 탐색기는 `collectShaped`(measured_text 없음)라
     `clip_rect`가 통째로 버려진다. 즉 "원점 편향 + clip"만으로는 부분 행이 나오지 않는다.

     **A로 갔고, 그 A가 틀렸다(2026-08-08 정정).** 당시 셋 중 A를 골랐다 — 프레임당 하나인 clip 슬롯을
     pane별로 넓히고, 자를 **구간**은 `PaneFrameRole`로 pane 루프가 찾아 `pane_clip_cells_start/len`으로
     투영하는 안이다. 그렇게 머지된 v147은 **한 번도 동작하지 않았다.**

     이유는 그 설계에 있다. 사각형은 프레임에 실리는데 그것이 가리키는 구간은 **매 프레임 다시
     계산되는 pane 구성**에서 나온다. 도크 목록 pane은 매 프레임 발행되지 않으므로, 그 pane이 없는
     프레임이 슬롯을 지운다 — 실측하니 같은 버퍼에 대해 30프레임 중 6프레임만 값이 실렸고 24프레임이
     null로 덮었으며, 렌더러의 scissor 분기는 **진입 0회**였다. 탐색기는 불투명한 뷰 바가 넘친 행을
     가려 이 실패가 화면에 안 보였고, 소스 컨트롤의 투명한 브랜치 헤더가 드러냈다.

     **v169가 대체했다(C안).** `NativeMetalCell.clip_index` + 프레임 clip 표(`cell_clips`)로 **셀이 자기
     clip을 든다**. 사각형과 대상이 같은 배열에 있으니 둘이 어긋날 수 없고, 구간을 role로 되찾을 필요도
     없다 — quad 경로(`GpuQuad.clip_*`)가 이미 그렇게 하고 있었다. 렌더러는 index가 바뀌는 경계에서
     draw를 쪼갠다. 옛 `pane_clip_*`·`modal_clip_*` 필드와 인자는 제거했다.

     **남길 교훈**: "무엇을 자를지"와 "어떤 사각형으로 자를지"를 **다른 수명의 두 곳**에 두면, 둘이
     어긋나도 컴파일도 헤드리스 단언도 통과한다. 그 조합은 소비자 하나가 우연히 매 프레임 발행될
     때만 동작하고, 그렇지 않은 둘째 소비자에서 조용히 실패한다.

     당시 적었던 선택지 셋(기록):

     - **A(당시 선택, v169가 되돌림). 프레임 단위 clip 슬롯을 pane별로 넓힌다.**
     - **B. 탐색기 텍스트를 measured 경로로 옮긴다**(도크와 같게). 셀 정렬 전제·아이콘 2패스·성능
       예산을 전부 다시 봐야 한다.
     - **C(v169가 채택). 셀이 자기 clip을 든다.** `ClipPx` 주석이 트리거를 미리 적어 뒀다 — "세 번째
       프레임 단위 clip 소비자가 생기면 셀 경로도 per-primitive clip으로 일반화할 때다".

     **픽셀 한 번은 손으로 본다 — 그리고 판정 가능한 화면에서 본다.** 셀 pane을 scissor로 자르는 것은
     이 저장소에서 처음이고(도크는 measured 경로의 per-glyph clip이다), 그것이 GPU에서 실제로 잘리는지는
     기하 단언이 말해 주지 않는다. SV2a에서 캡처를 봤지만 **탐색기는 판정자가 될 수 없었다** — 넘친 행이
     불투명한 뷰 바 뒤에 있어, 잘렸을 때와 안 잘렸을 때의 화면이 같다. 그래서 "캡처로 확인했다"는 SV2a의
     주장은 근거가 없었다. 잘림을 판정하려면 **넘친 내용이 실제로 보이는 화면**이어야 한다(소스 컨트롤의
     투명한 브랜치 헤더). 자동 픽셀 게이트가
     필요할 만큼 이 경로가 자주 바뀌면 그때 앱 스모크 캡처를 골든에 물린다 — 지금 만들면 쓰지 않을
     하네스를 먼저 짓는 것이다.
  - **SV2a — 픽셀 스크롤 상태(완료, clip 부분은 v169가 다시 함).** 셋으로 나눠 들어갔다. **SV2a-1**:
     셀 격자 본문 한 구간을 px 사각으로 자르는 ABI v147 seam(값 0 = 기존 동작). **SV2a-2**: 탐색기 pane이
     `PaneFrameRole.file_tree`로 자기 셀 구간을 표시해 그 seam의 첫 소비자가 된다. **SV2a-3**:
     `file_tree_scroll_rows: usize` → `scroll_area.State`(픽셀). 렌더는 위 ①의 원점 편향 + `clip_rect`이고,
     hit-test·reveal·follow·휠이 픽셀을 읽는다.

     **정정(2026-08-08)**: SV2a-1/2가 깐 v147 seam은 GPU에 한 번도 도달하지 않았다(위 "A로 갔고, 그 A가
     틀렸다"). 픽셀 스크롤 상태·창 계산·hit-test는 그대로 유효하고, **자르는 부분만** v169
     (`NativeMetalCell.clip_index` + 프레임 clip 표)로 다시 했다. 탐색기에서 이것이 안 보였던 이유도
     같은 항목에 적었다.

     **투영은 `scroll_area.project`가 아니라 나눗셈이다**(계획 정정). 탐색기 행은 높이가 균일해
     `offset / cell_h`가 walk와 같은 답을 내고, 행이 수천 개가 될 수 있어 매 프레임 O(n) walk를
     돌릴 이유가 없다. 그 둘이 같은 답이라는 것은 판정자가 `project`와 대조해 고정한다 — 도크는
     카드 높이가 가변이라 walk가 필수이고, 이것은 같은 좌표계의 특수화다.

     **`file_tree_scrollbar`의 도메인도 rows에서 px로 바꿨다.** 상태가 픽셀인데 스크롤바만 행이면
     thumb이 셀 경계로 스냅해 목록과 어긋난다. 비율 산술이라 수식은 그대로이고 이름만 정직해지며,
     SV2b가 `scroll_area.scrollbarGeometry`로 대체할 때 필드가 1:1로 대응한다. 발행·capture 경로는
     아직 `file_tree_scrollbar` 그대로다.

     **사용자에게 보이는 변화 둘.** 트랙패드 스크롤이 행 단위 점프에서 픽셀 스무스로 바뀌고(도크와
     같은 `State.scrollByWheel` 경로), 뷰포트 바닥의 부분 행이 잘린 채로 보인다(예전에는 그 자리에
     배경이 남았다).
  - **SV2b — 스크롤바 이관(완료).** 자식 없는 `tree.scrollArea` 선언이 track/thumb을 내고, 그리기는
     공용 `ui_paint` → `chrome_draw_lowering`이 한다(도크와 같은 경로). `file_tree_scrollbar.publish`와
     전용 capture 경로는 지웠고, **`components/file_tree_scrollbar.zig` 모듈 자체가 사라졌다** — 기하·
     drag·hit 판정이 전부 `ui/scroll_area.zig`에 이미 있었기 때문이다(SV2a-3에서 픽셀 도메인으로 옮겨
     둔 덕에 1:1 대응이었다). 드래그 수명도 host가 들던 세 필드에서 `scroll_area.Drag` 하나로 접혔다.

     `reservedColumns`(텍스트 **셀**을 통째로 빼 track 자리를 만드는 것)는 컨테이너가 소유하는 픽셀
     gutter로 대체됐다. gutter는 스크롤바 유무와 무관하게 상시 예약되므로 목록이 reflow하지 않는다.

     **사용자에게 보이는 변화 둘.** ① track(홈)이 새로 보인다 — 공용 paint가 track도 그리므로 도크와
     같은 모습이 된다. ② 행 오른쪽 여백이 셀 단위 예약에서 픽셀 gutter로 바뀌어 글자가 끝나는 자리가
     달라진다.

     **z가 실제로 움직인 슬라이스다.** 스크롤바가 layer 3(over — 텍스트 **위**)에서 layer 2(bottom —
     텍스트 **아래**)로 건너갔다(§8). 그래서 행 하이라이트 밴드와 같은 버킷이 되고, 밴드 폭을 gutter
     앞에서 끊고 스크롤바를 밴드 **뒤에** append하는 것 둘 다 필요하다 — 판정자가 그 둘을 고정한다.
     남은 z 정리(layer 상수 vs `(layer, z, order)`)는 SV6가 pane·사이드바와 함께 본다.
- **SV3 — 소스 컨트롤 이관.** 탐색기와 같은 행 좌표를 쓰고 스크롤바가 아예 없다. SV2가 만든 픽셀
  경로를 그대로 쓰므로 비용이 가장 작고, 없던 스크롤바가 생기는 것이 사용자에게 보이는 변화다.
  탐색기와 같은 이유로 둘로 나눈다.

  - **SV3a — 픽셀 스크롤 상태(완료).** `scm_scroll_rows: usize` → `scroll_area.State`(픽셀). 창은
     탐색기와 같은 세 값(`start`·`count`·`origin_shift_px`)이고 hit-test·휠이 픽셀을 읽는다.

     **탐색기와 다른 점 하나**: 첫 줄이 **브랜치 헤더**이고 스크롤에서 고정이다. 그래서 뷰포트는
     `tree_content.h`에서 그 한 줄을 뺀 값이고, 헤더는 스크롤 좌표 **밖**이다. 헤더와 목록이 한
     draw list였으므로(`buildDockScmDrawList`가 row 0에 헤더를 그렸다) `head`를 optional로 만들어
     둘로 나눴다 — 그러지 않으면 목록의 픽셀 편향이 헤더까지 끌고 간다.

     clip seam의 role을 `file_tree` → **`dock_list`** 로 일반화했다. 도크 뷰는 한 번에 하나만
     보이므로 프레임당 한 구간인 v147 seam을 탐색기와 소스 컨트롤이 공유한다.
  - **SV3b — 스크롤바 신규(완료).** SV2b가 만든 `scrollArea` 선언을 그대로 써서 없던 track/thumb을
     낸다. 소스 컨트롤은 스크롤바가 **아예 없던** 뷰라, 사용자에게 보이는 변화는 "막대가 생긴 것"이다.

     **두 뷰가 발행 저장소·드래그·interaction을 공유한다.** 도크 뷰는 한 번에 하나만 보이므로 상태를
     뷰마다 두지 않고, `dockListScroll()`이 지금 보이는 목록의 사각형·좌표계·offset을 고른다. 그래서
     이름도 `file_tree_scroll_*` → **`dock_list_scroll_*`** 로 옮겼다 — 두 소비처가 쓰는 상태에
     한쪽 이름을 남겨 두면 다음 소비처(SV4)가 그것을 보고 오해한다.

     **뷰별로 갈리는 것은 셋뿐이다**: 뷰포트 사각형(소스 컨트롤은 헤더 한 줄 아래에서 시작), extent,
     그리고 offset을 적용할 setter. 그 라우팅이 갈리면 **보이지 않는 목록이 스크롤되므로** 판정자가
     "thumb 드래그가 이 목록을 움직이고 탐색기 offset은 그대로"를 본다.
- **SV4 — 사이드바 이관.** 스크롤바가 host의 GPU quad라 발행 경로가 없다. 이관하면 사이드바도
  드래그 가능한 스크롤바를 얻는다(현재 휠 전용).

  **앞의 셋과 성격이 다르다.** 탐색기·소스 컨트롤은 목록 렌더가 `app_session`에 있어 host 안에서
  gutter를 뗄 수 있었다. 사이드바는 이미 제품 컴포넌트(`chrome/components/sidebar.zig`)가 밴드 op을
  내고 그 폭을 `p.metrics.sidebar_width_px` 하나로 정한다 — gutter 예약이 host 안의 산술이 아니라
  **그 컴포넌트의 계약 변경**이 된다. 그래서 둘로 나눈다.

  **layer는 3(over)으로 남는다(2026-08-08 실측 정정).** 처음에는 탐색기처럼 공용 lowering이 내는
  layer 2를 그대로 쓰려 했는데, 그러면 막대가 **화면에서 사라진다** — 렌더러가 layer 2 버킷을 맨 처음
  그리고 그 위에 자기가 소유한 사이드바 배경 strip을 덮기 때문이다(`docs/metal-ui-layout-paint.md` §5의
  승인된 예외). 도크·탐색기 스크롤바가 layer 2로 살아남는 것은 그 자리에 strip이 없어서지 layer 2가
  안전해서가 아니다. 그래서 lowering 뒤에 fade alpha와 함께 layer도 되돌린다. gutter는 그래도
  유지한다 — 막대가 카드 텍스트와 겹치지 않는 것은 별개의 이득이다.

  - **SV4a — 발행 경로(완료).** `appendSidebarScrollbar()`가 손으로 만드는 GpuQuad를 `tree.scrollArea` 선언
    + `ui_paint` + `chrome_draw_lowering`으로 교체하고, `sidebar.view`가 밴드 폭에서 gutter를 예약한다.
    **보이는 변화**: 카드 밴드가 gutter만큼 좁아진다(스크롤바가 나타나고 사라져도 폭은 안 변한다 —
    상시 예약이 [ScrollArea](../scroll-area.md) §4의 규율이다).
  - **SV4b — 드래그(완료).** capture를 붙여 잡아 끌 수 있게 한다. **판단**: 사이드바와 도크 목록은 **동시에
    보이므로** 발행 저장소는 각자 둔다. 그러나 한 번에 하나만 잡히므로 capture·`scroll_area.Drag`는
    공유하고 어느 쪽을 잡았는지만 태그한다 — SV3b가 상태까지 합친 근거("도크 뷰는 한 번에 하나만
    보인다")는 여기 적용되지 않는다. 근거가 다르면 결론도 다르게 적는다.
- **SV5 — 알림·팔레트·세팅(흡수하기로 결정, 2026-08-08).** 셋은 이미 `overlay_input.windowStart`로
  item-index windowing을 공유한다. 흡수 여부는 SV1~SV4를 마친 뒤 정하기로 미뤄 뒀고, 이제 정했다 —
  결론과 **반대 근거까지** [ScrollArea](../scroll-area.md) §SV5에 적었다(팔레트·세팅은 지금 스크롤 상태가
  0개라 흡수가 상태를 **만드는** 쪽이다. 그럼에도 스크롤바와 일관성을 택했다).

  셋으로 나눈다. 각 슬라이스는 **없던 스크롤바가 생긴다**는 것을 PR에 명시한다 — 순수 refactor가 아니다.

  - **SV5a — 알림 패널.** 셋 중 유일하게 스크롤 상태가 있다(카드 index). 그것을 픽셀로 옮기고
    스크롤바·드래그를 얻는다. 카드 단위로 넘기던 감각이 바뀌므로 **보이는 변화가 가장 크다**.
  - **SV5b — 팔레트. 상태를 만들지 않는다(2026-08-08 정정).** [ScrollArea](../scroll-area.md) §SV5는 이
    슬라이스가 "없던 픽셀 offset을 만든다"고 적었는데, 코드를 읽어 보니 **표시만 하는 한 만들 필요가
    없다.** 팔레트는 `win_start`를 selected에서 매번 재파생하므로 스크롤바에 필요한 셋이 전부 그
    파생값으로 나온다 — `offset_px = win_start × ch`, `content = total × ch`, `viewport = visible × ch`.

    **드래그를 붙이는 순간에만 상태가 필요하다.** 막대를 끌면 offset이 selected와 무관하게 움직여야
    하므로 그때는 저장해야 한다. 그 필요가 실제로 확인되기 전까지는 만들지 않는다 — 흡수의 비용으로
    미리 걱정했던 것이 사실은 **선택 가능한 비용**이었다.

    **스크롤바는 host가 `tree.scrollArea`로 발행한다(2026-08-08 결정).** 컴포넌트가 `total`·`offset`을
    받아 자기 막대를 그리는 안도 검토했지만, 그러면 스크롤바 모양·기하가 컴포넌트마다 한 벌씩 남아
    이관의 목적("스크롤바를 한 곳에서 소유한다")과 정반대가 된다 — SV5a의 알림 패널이 지금 그 상태이고,
    거기서 고친 thumb 비율 버그가 그 복제본 때문에 생긴 것이다. 오버레이 셋은 **한 번에 하나만
    열리므로**(모달) SV3b가 탐색기↔소스 컨트롤에서 쓴 것처럼 발행 저장소·drag·interaction을 통째로
    공유하고 어느 오버레이인지만 라우팅한다.

    **선행 확인 결과(코드로 확정, 2026-08-08)**: 공용 lowering이 내는 **layer 2는 안 된다.** 렌더러는
    layer 2를 터미널 pass 맨 처음에 그리고, 오버레이 pass가 그 위에 모달 배경 quad를 통째로 덮는다
    (`maru_metal_renderer.m`의 오버레이 순서: 그림자 → over quad → 모달 텍스트 셀 → caret). 그러니
    SV4와 같이 lowering 뒤에 **layer를 over 버킷으로 되돌린다**. 사이드바에서는 렌더러 소유 배경
    strip이, 여기서는 모달 배경 quad가 덮는다 — 원인은 달라도 처방은 같다. 실제 화면 확인은 구현 후
    한 번 더 한다(코드만 보고 틀린 전례가 이번 묶음에만 넷이다).
    **gutter를 컴포넌트가 손으로 빼는 것은 임시다(2026-08-08 기록).** 팔레트는 `overlay_input.panelLayout`
    으로 레이아웃을 손계산하므로, 스크롤바 gutter를 쓰는 요소(선택 밴드·우측 정렬 단축키)가 각자 그 폭을
    빼야 한다 — 하나라도 빠뜨리면 그 요소만 막대를 덮는다(실제로 두 번 그렇게 나갔다). 그래서 view 안에
    `usable_cols`를 **단일 출처**로 두어 그 파일 범위에서는 빠뜨릴 자리를 없앴다.

    **장기 정답은 오버레이도 `chrome/ui` 레이아웃 트리를 쓰는 것이다.** 레퍼런스 레이아웃 엔진(taffy)은
    `overflow: scroll`인 노드의 가용 공간에서 `scrollbar_width`를 **엔진이** 빼고 그 결과를
    `scrollbar_size`로 실어 준다(CSS `scrollbar-gutter`와 같은 모델) — 컴포넌트는 "내가 비켜야 한다"를
    알 필요가 없다. 우리 `chrome/ui/layout.zig`도 이미 border box·content box를 구분하고 `tree.scrollArea`가
    `gutter_px`를 예약하므로, **메커니즘은 이미 있고 오버레이만 그것을 안 쓰고 있다**(`docs/metal-ui-layout.md`
    ML6가 목표로 적어 둔 그 미완이다).

    `panelLayout`에 `content_cols`를 더하는 중간안도 검토했으나 접었다 — layout 엔진이 이미 가진 개념을
    오버레이용으로 한 벌 더 만드는 것이고, find처럼 스크롤바가 없는 소비처까지 그 필드를 갖게 된다.
    **세팅(SV5c)에서 같은 문제가 재현되면 그때가 세 번째 소비자**이니, 오버레이 레이아웃 이관을 정식
    슬라이스로 올린다(이 저장소가 `ClipPx` 주석에서 쓴 것과 같은 기준).
  - **SV5a-2 — 알림 스크롤바 이관.** SV5a는 스크롤 **좌표**만 픽셀로 옮겼고 막대는 여전히 컴포넌트가
    손수 그린다. SV5b가 만드는 공유 발행 경로에 알림도 얹어 그 복제본을 지운다.
  - **SV5c — 세팅(완료).** 팔레트와 같은 형태이되 뷰포트는 **컴포넌트가 준다**(`settings.scrollView`) —
    폼 폭이 nav·control·↺ 여백에 얽혀 있어 host가 다시 계산하면 두 벌이 갈린다.

    **팔레트의 흩어짐은 여기서 재현되지 않았다(2026-08-08 확인).** 세팅은 폼 폭이 `form_cols` 한 곳에서
    정해지고 `reset_gutter_cols`를 빼는 패턴을 이미 갖고 있어, 스크롤바 gutter를 그 자리에 한 번 더
    얹으니 control·↺ 위치가 자동으로 따라왔다. 그래서 **오버레이 레이아웃 이관(ML6)은 올리지 않는다** —
    "세 번째 소비자에서 재현되면 일반화한다"는 기준을 그대로 따른 결과다. 손계산이 흩어진 곳은 팔레트
    하나뿐이라는 사실만 남긴다.
  - **SV5d — 오버레이 휠·드래그(상태 도입).** 팔레트·세팅은 원래 휠 핸들러가 **없었고**(↑↓ 선택 이동으로만
    창이 움직였다) 막대도 표시 전용이다. 휠과 드래그는 선택과 무관하게 목록을 움직이므로 **offset을
    저장해야 한다** — SV5b가 "필요가 확인되기 전까지 만들지 않는다"고 미뤄 둔 그 상태다. 사용자가
    붙이기로 결정해(2026-08-08) 그 필요가 확인됐다.

    **selection follow는 값 비교다 — 장기 답은 아니다(2026-08-09 기록).** 선택이 바뀌면 창을 당겨야
    하는데, 그 "바뀜"을 `.selection_changed` 액션으로 잡으려다 실패했다. 선택은 그 액션 말고도 **쿼리
    필터**(`recomputePalette`가 `selected = 0`으로 되돌린다)·섹션 전환 등 여러 경로에서 바뀌고, 그
    목록을 host가 열거하면 새 경로가 생길 때 조용히 빠진다(증상이 "휠로 굴린 뒤 검색어를 고치면 창이
    안 따라온다"처럼 좁아 늦게 발견된다). 그래서 렌더 직전 `followed_selected`와 **값을 비교**한다 —
    경로를 묻지 않는다.

    그 비용은 소비처마다 파생 필드가 하나씩 는다는 것이고, "무엇이 바뀌었나"를 값으로 재구성한다는
    점에서 이 저장소가 반복해 밟은 함정(사실과 그 표현이 갈리는 구조)과 같은 계열이다.

    **"setter로 모으면 된다"는 답은 검증에서 무너졌다.** 그 안에서 follow를 부르려면 창을 계산할 재료
    (`sections`·`rows`·`props`·`tokens`)가 그 자리에 있어야 하는데, 세팅의 선택은 컴포넌트 `handle()`
    안에서 바뀌고 그 함수는 재료를 받지 않는다. 결국 setter는 "바뀌었다" 플래그만 세우고 렌더 직전에
    그걸 보게 되는데, 그건 **값 비교와 구조가 같으면서** 세우기/지우기 두 곳이 어긋날 여지가 더 있다.
    값 비교는 값이 곧 진실이라 그 실패 모드가 없다.

    **그래서 값 비교가 지금 구조에서 옳다.** 이를 넘어서려면 선택과 재료가 같은 자리에 있어야 하고,
    그건 오버레이 레이아웃을 `chrome/ui` 트리로 옮기는 것(ML6)이 전제다 — 컴포넌트가 창 계산에 필요한
    것을 스스로 갖게 되는 그때 사건 기반이 성립한다.

    **매 프레임 당기면 안 된다.** 처음에 "키 경로를 안 빠뜨려 견고하다"며 무조건 당기게 했는데, 선택이
    맨 위에 있으면 휠로 굴린 offset이 한 프레임 만에 0으로 되돌아가 **휠이 통째로 무효화됐다**(제품에서
    실측). 팔레트·세팅이 원래 `windowStart(prev=0)`로 매 프레임 창을 재파생하던 구조였고, 상태를
    도입하면서 그 호출 빈도를 검토 없이 이어받은 것이 원인이다.

    상태는 오버레이 셋이 **공유**한다(한 번에 하나만 열린다 — 발행 저장소와 같은 근거). selection follow는
    그대로 남되, offset이 저장되므로 "이미 창 안이면 움직이지 않는다"가 의미를 갖는다(알림이 SV5a에서
    쓰는 규칙과 같아진다).

  **오버레이 layer·clip을 먼저 확인한다.** 셋 다 모달 셀 경로를 지나므로 스크롤바 quad가 공용 lowering의
  layer 2로 살아남는지 **실측**한다. 사이드바에서는 렌더러가 소유한 배경 strip이 그것을 덮어 막대가 아예
  안 보였고, 그 사실은 헤드리스 단언이 전부 green인 채로 화면에서만 드러났다.
- **SV6 — z 축 정리(판단은 이관 중, 변경은 별도 슬라이스).** 정렬 축 변경은 lowering을 지나는 모든 quad
  소비자에 영향을 주므로 "시각 무변경"이 완료 기준인 이관 단계와 같은 PR에 넣지 않는다. 자기 게이트
  (모달·툴팁·스크롤바가 겹치는 화면의 골든)와 비용 측정을 함께 낸다. `GpuQuad.layer`는 닫힌 enum이 아니라 이미
  스크롤바 전용 layer 3이 추가된 상태이고, Session Dock 스크롤바만 layer 2에 나와 같은 역할이 두 층에
  흩어져 있다. 스크롤바 층을 layer 상수로 계속 표현할지, `(layer, z, order)` stable sort로 옮기고
  layer는 합성 패스 의미만 남길지를 이관과 함께 정한다.
  - **SV6a — 공용 lowering이 layer를 받는다(완료).** `appendBackgroundQuads`가 layer 2를 고정 출력해
    소비처 둘이 뒤에서 되돌리던 것을 없앴다. 인자로 받고 호출자가 명시한다(기본값 없음).
  - **SV6b — 오버레이 quad를 프레임 끝에 flush한다(완료).** 계획했던 "발행 순서 규약"은 대상이 없었다
    (이미 한 자리에서 순서대로 나오고 있었다). 실제로 깨져 있던 것은 sticky 배너 구분선(layer 3)이
    오버레이보다 **뒤**에 나와 열린 오버레이 위에 그어지는 것이었고 — find 바 상단과 정확히 같은 행이다 —
    구분선 좌표가 `placeAndDistribute` 뒤라야 나오므로 오버레이를 늦추는 쪽으로 고쳤다. `overlay_quads`
    대기 버퍼가 순서를 규율 아닌 구조로 만든다. 판정자는 `gpu_quads` 꼬리 == `overlay_quads`.
  - **전역 `(layer, z, order)` 정렬은 하지 않는다.** 근거와 재개 조건은 [ScrollArea](../scroll-area.md)가 소유한다.

**탭 바(가로 스크롤)는 이 순서에 없다.** 컬럼 좌표·‹› 버튼 affordance·`Pane.tab_scroll_cols` 소유자가
모두 다르므로, 세로 목록을 모으는 것과 가로 축을 여는 것은 별개의 결정이다.

각 단계는 앞 단계의 계약을 넓히기만 하고 바꾸지 않는다. 바꿔야 하면 [ScrollArea](../scroll-area.md)를
먼저 고친다.
