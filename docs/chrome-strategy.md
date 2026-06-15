# Chrome 전략 — 디자인 시스템 구조 설계

chrome(탭바·사이드바·divider·focus 테두리·탭점·팝업·모달)을 **이식 가능한 디자인 시스템**으로 재구성하는 1차 구조 설계다. 터미널 콘텐츠(셀·글리프)는 이 문서의 범위가 아니다 — 코어 렌더러 경로를 그대로 둔다. chrome만 이 디자인 시스템을 따른다.

이 문서는 chrome 레이어(L3)의 **목표 구조와 점진 경로**를 정의한다. chrome이 속한 4층 위상(renderer 계약·session core·chrome·platform 어댑터), 두 번의 추출(chrome + session core), 전체 시퀀싱, 이식성 현실은 상위 단일 출처 [레이어링과 이식성 전략](layering-and-portability.md)을 따른다. 단일 출처: 구현이 진행되면 이 문서를 코드와 맞춘다([project-rules](project-rules.md#문서와-설명)).

> **현황(구현 진행)**: C0(Notice)·S1(구조-무효화)·**C1(palette·find 이주)**·**C2(divider 이주)**·**C3a(sidebar 이주)**·**C3b(tabbar hit-test 이주)**·**C4a(rich 토큰셋)** 완료. 두 오버레이는 이제 `src/chrome/components/{notice,find,palette}.zig`(neutral State+view+handle, 헤드리스 테스트)이고, `src/chrome/host.zig`(`ChromeHost`)가 입력 라우팅·draw 수집을, platform(`app_dev_session.zig`)이 props/tokens 빌드·카탈로그 행 주입·ChromeDraw→cell lowering(`rasterizeOverlayCells`)을 맡는다. 레거시 `command_palette.zig`/`find_overlay.zig`의 UI 상태·`build*Frame`·`handle*Key`는 **제거**됐고, palette는 카탈로그 결합 필터(`command_palette.filter`/`actionAt`)만 platform에 남는다(neutral chrome이 `command_catalog`를 import 못 함). 입력 caret은 cursor-role fill → 오버레이 `PaneFrame.cursor` → `setCursorVisible` suffix-trim으로 **터미널 커서 깜빡임을 재활용**하고, 한글 2칸 폭·IME 조합 표시도 터미널과 같은 경로를 공유한다. **C2(divider)**는 `chrome/components/divider.zig`(마우스 hit-test 컴포넌트의 첫 선례 — State 없는 순수 `hitTest`/`view`(Rule op 선)/`dragRatio`)로 이주했고, platform이 app `*Split` 매핑·드래그 상태(§6 라이브 포인터)·Rule op→부분사각형 lowering을 맡는다(divider는 pane chrome 셀이라 overlay rasterizer가 아니다). **C3a(sidebar)**도 `chrome/components/sidebar.zig`(hit-test 순수 6함수 + 밴드 view; 제목 glyph는 platform `buildSidebarTitleFrame` 유지, 드래그 재정렬은 인덱스 기반)로 이주했다. **C3b(tabbar)**는 탭 컬럼 분할 hit-test를 `chrome/components/tabbar.zig`의 `Metrics` 메서드로 이주했다(활성 밴드는 platform 단일 셀 — round-trip 회피; 라이브 `*Pane`·드롭·제목 glyph는 platform). 이로써 chrome hit-test(divider·sidebar·tabbar)가 전부 컴포넌트화. **C4a(rich 토큰셋)**도 완료 — `Tokens.rich`가 tui의 sidebar_active-공유 role을 분리 파생색으로, config `chrome.theme = tui|rich` 분기(컴포넌트·lowering 불변). 아래 §3~ 표는 이주 **전** 출발 스냅샷(설계 근거 보존)이다. **C4b(GPU 렌더 프리미티브)** 완료 — metal SDF quad/shadow·`ChromeDraw.quad`+모양 토큰·사이드바 둥근 밴드·모달 둥근 배경/테두리/그림자/패딩·tabbar §6 픽셀 retrofit(`segCols` 단일 소스)·둥근 탭+vertical gradient(draw layer 3분할). **U(C4b 이후): UI 형태 다듬기** — 사이드바 세로 카드 + 좌측 maru-accent(앰버) 막대(U1)·카드 레이아웃(U2)·가로 탭 VSCode식(U3 — 활성 탭 평평한 약한 배경 + 하단 maru 앰버 언더바(active indicator), 둥근 밴드·gradient 폐기; 활성 pane은 사각 ring 대신 탭 언더바로 일원화; 탭 전용 고정 폭(`tab_width_cols`, 적으면 빈 영역)·세로 패딩(`tab_bar_pad_y_px`, 제목 가운데)·넘치면 우측 ‹› 가로 스크롤(`tabLayout` 단일 소스 + `tab_scroll_cols`→`segCols`, `eff_scroll` clamp로 stale 복구, rich 고정폭만; ‹› affordance(사각 버튼·hover 색·클릭 가능 영역 pointingHand 커서·스크롤 여지 방향만 강조[경계 muted=부분 탭 잘림 단서]) 완료, 트랙패드 가로만 진행 중)), maru 독립 설계.

## 1. 목표

- chrome 컴포넌트는 **플랫폼·세션·렌더 백엔드를 모른다.** 순수 로직(상태) + 순수 렌더(상태+토큰 → semantic draw) + 순수 hit-test로, macOS·PTY 없이 헤드리스 단위 테스트한다.
- **TUI(현재 cell-grid 룩)는 theme로 보존**하고 rich를 추가한다(교체 아님). 같은 컴포넌트 코드가 두 룩을 다 만든다.
- 7600줄 `app_dev_session.zig`의 chrome를 `src/chrome/`로 옮겨 세션은 "세션 코어(수명·입력·워크스페이스·ABI)"로 줄인다.

## 2. 베이스·결정 (왜 이 구조인가)

이 설계는 새 철학이 아니라 **기존 Maru 원칙을 chrome에 적용**한 것이다([document-basis-and-decision] 원칙대로 베이스를 명시):

| 결정 | 베이스(기존 원칙) | 출처 |
|---|---|---|
| semantic chrome draw → {tui 백엔드, rich 백엔드, 후속 inspector} | "디버그·로그·스냅샷·리플레이·테스트·inspector가 **같은 도메인 데이터를 소비**" | project-rules §관측 가능성 |
| 순수 컴포넌트(State) 헤드리스 테스트 | "동작을 구현 전 표현 가능하면 TDD; 모든 기능 영역에 E2E" | project-rules §테스트 |
| `src/chrome/` facade + check-boundaries | "터미널 코어 API는 Maru 내부 facade 뒤에" | project-rules §기본 규칙 |
| Zig가 chrome 로직·draw 소유, platform은 백엔드/입력 어댑터 | ABI capabilities: `zig_owns_frame_loop` vs `swift_owns_focus_and_input` | app_host_abi |
| 네이티브 UI 프레임워크 없이 Zig draw + GPU | 런타임 의존성 0·native 최소(SwiftUI=Apple 전용) | project-rules §의존성 |
| theme = 토큰(데이터), 코드 분기 없음(tui\|rich) | 기존 TUI를 theme로 보존 + 같은 chrome 모델을 두 스킨이 소비 | 사용자 결정 |
| props seam + 단일 ChromeState로 구조 분해 | "버그는 루트커즈. 구조가 원인이면 구조를 바꾼다" | project-rules §버그 수정 |
| 컴포넌트·룩을 cmux/Ghostty 코드 표현 안 옮김 | clean-room(renderer·platform interop에도 적용) | project-rules §기본 규칙 |

레퍼런스 사용은 동작 비교(오라클)만 — cmux의 세로 사이드바·드래그 UX는 최종 동작만 참고하고 소스를 옮기지 않는다.

## 3. 현재 상태 (조사로 확정)

| 층 | 현재 위치 | 사실 |
|---|---|---|
| 셀 프리미티브(입력) | `renderer/draw_list.zig` `DrawCell{row,col,codepoint,combining,width,style}` | 터미널 코어→렌더러 **입력 계약**. sentinel/kind/origin/packed-color 없음 |
| 백엔드 출력 셀 | `metal_frame.zig` `NativeMetalCell`(extern) | 백엔드가 실제로 그리는 셀. `reserved`(0/2~5=부분사각형 kind), UV sentinel(-1=배경만), `origin_x/y`, `foreground`(0x00RRGGBB)/`background`(0xAARRGGBB) |
| 합성 seam | `MetalFrameBuffer.replace(pane_frames, sidebar_*, pane_chrome_cells, pane_overlay_cells, overlay_frame)` | N-pane + 사이드바 + chrome + 모달을 Z-순서 단일 스트림으로. **chrome가 백엔드를 거쳐 들어오는 자리** |
| 오버레이 컴포넌트(순수) | `command_palette.zig`·`find_overlay.zig` | `PaletteState`/`FindState` 순수(std+타입만, 헤드리스 테스트). 물리적으로 platform/macos |
| chrome 렌더·hit-test | `app_dev_session.zig`(chrome fn 다수) | `NativeMetalCell`을 **손으로 직접 구성**(`sentinelBgCell`/`appendVerticalLine`/`BarMetrics`/`sidebarBandCell`). DrawList 안 거침 |
| theme | `config/theme.zig`→`appearance.ResolvedTheme`(9 색 role, `color.Rgb`) | 파생(lighten +24/+48·hover 중점·muted 55/45·drop alpha 0x55)이 코드 리터럴로 흩어짐. **비-색 토큰(spacing/border/radius) 없음** |

**확정된 사실 3가지(설계 전제):**
1. chrome 출력은 `NativeMetalCell`(shape) + `RenderFrame`/`PaneFrame`(text glyph)다 — `DrawCell` 아님. semantic draw 백엔드의 **lowering 타깃이 NativeMetalCell**이다.
2. 컴포넌트 패턴은 이미 존재: `State`(순수) + `build*Frame`(렌더) + `handle*Key`(입력→`?Action`). 빠진 건 **마우스 hit-test 컴포넌트 선례**(palette/find는 키보드 전용; 탭/divider는 `BarMetrics`/`dividerHit` 순수 함수로 따로 존재).
3. theme 로더 갭: config 파일로 파싱되는 theme key는 **4개뿐**(`background`/`foreground`/`cursor`/`selection`). `search_match*`·`sidebar_*` 5개는 struct·resolver엔 있으나 **로더 case가 없어 config로 설정 불가** — 토큰화 시 함께 메운다.

## 4. 아키텍처 — 레이어와 의존 방향

```mermaid
flowchart TD
    tokens["Tokens 토큰 (색 role + spacing/border)"] --> comp["Component 순수: State + view + hitTest + handle"]
    props["Props (host가 빌드한 불변 모델 뷰)"] --> comp
    comp --> cdraw["ChromeDraw (semantic: fill/border/rule/text + layer)"]
    cdraw --> backend["Backend.lower: ChromeDraw → 셀/프레임"]
    tokens --> backend
    backend --> bundle["ChromeFrame: NativeMetalCell들 + 텍스트 PaneFrame들 (layer별)"]
    bundle --> replace["metal_frame.replace 합성 (기존 seam)"]
    host["ChromeHost: ChromeState 소유, props 공급, event→Action"] --> props
    host --> comp
    host --> backend
    session["app_dev_session: 세션/PTY/워크스페이스"] -->|"모델 상태"| host
    boundary["check-boundaries: chrome는 tokens·props·ChromeDraw만 의존. session·platform·NSWindow·NativeMetalCell 모름"] -.-> comp
```

**핵심: 컴포넌트는 `NativeMetalCell`조차 모른다.** 컴포넌트는 `ChromeDraw`(semantic)만 뱉고, **백엔드**가 그걸 `NativeMetalCell`(tui) 또는 GPU 프리미티브(rich)로 lowering한다. 이게 tui|rich를 컴포넌트 변경 0으로 만드는 단일 결정이다.

## 5. 타입 계약 (concrete)

아래는 목표 타입의 스케치다(최종 필드는 구현에서 확정). 위치는 모두 `src/chrome/`.

### 5.1 Design Tokens — `chrome/tokens.zig`
theme = 토큰 묶음(데이터). 컴포넌트는 `tokens.color(.tab_active_bg)`만 읽고 `if (rich)` 분기를 **절대 안 한다**.

```zig
pub const ColorRole = enum {
    surface_bg, surface_fg, muted_fg,          // 사이드바/패널 기본
    tab_active_bg, tab_hover_bg,               // 탭 밴드
    divider, focus_accent, drop_zone,          // 현재 sidebar_active 재사용 → rich 위해 분리 role
    search_match, search_match_current,        // Find 하이라이트
    selection, cursor,                         // 터미널과 공유하는 role(참조만)
};
pub const Tokens = struct {
    palette: std.EnumArray(ColorRole, color.Rgb),  // 9+ role을 Rgb로
    space: Spacing,    // 사이드바 폭, 슬롯 높이비, 패널 margin — 지금 흩어진 픽셀 상수
    border: Border,    // 선 두께(tui=2px strip kind), (rich) radius
    // tui와 rich는 같은 struct의 두 값. 현재 파생(+24/+48/55-45/0x55)은 tui Tokens의 기본 생성에 박는다.
    pub fn color(self: Tokens, role: ColorRole) color.Rgb { return self.palette.get(role); }
    pub fn tui(resolved: appearance.ResolvedTheme) Tokens { ... }   // 현재 ResolvedTheme → tui 토큰
    pub fn rich(resolved: appearance.ResolvedTheme) Tokens { ... }  // C4
};
```
`appearance.ResolvedTheme`(9 색)는 유지하되, `Tokens.tui()`가 그걸 받아 role+derivation을 채운다. **로더 갭(5 key)은 여기서 config→Tokens로 메운다.**

### 5.2 ChromeDraw — `chrome/draw.zig` (semantic 어휘, 백엔드 중립)
컴포넌트의 유일한 출력. **픽셀 좌표**(rich의 sub-cell 정밀도 대비)로 표현하고, tui 백엔드가 셀로 스냅한다.

```zig
pub const Px = struct { x: i32, y: i32 };
pub const Rect = struct { x: i32, y: i32, w: u32, h: u32 };  // 픽셀
pub const Layer = enum { sidebar, pane_chrome_bg, pane_overlay, modal };  // replace()의 슬롯/Z에 매핑
pub const Sides = packed struct { top: bool=false, right: bool=false, bottom: bool=false, left: bool=false };

pub const Op = union(enum) {
    fill:   struct { rect: Rect, role: ColorRole, alpha: u8 = 0xFF },   // 밴드·탭bg·hover·drop-zone
    border: struct { rect: Rect, sides: Sides, role: ColorRole },       // focus 테두리(상/우선)
    rule:   struct { from: Px, to: Px, role: ColorRole },               // divider 선
    text:   struct { origin: Px, runs: []const Run, role: ColorRole },  // 탭 제목·팝업·Notice 글자
};
pub const Run = struct { text: []const u8, bold: bool = false };
pub const ChromeDraw = struct { layer: Layer, ops: []const Op };  // 한 컴포넌트의 한 프레임 출력
```

### 5.3 Backend — `chrome/backend.zig` (계약) + `platform/macos/chrome_tui_backend.zig`
ChromeDraw를 실제 합성 입력으로 lowering. tui = `NativeMetalCell`(+텍스트는 glyph `PaneFrame`). rich(C4) = GPU 프리미티브.

```zig
pub const ChromeFrame = struct {                 // replace()가 먹을 번들(layer별)
    sidebar_cells: []NativeMetalCell,
    pane_chrome_cells: []NativeMetalCell,
    pane_overlay_cells: []NativeMetalCell,
    text_frames: []PositionedFrame,              // sidebar 제목·모달(overlay_frame) glyph
};
// tui 백엔드: fill→sentinel-UV bg 셀, border/rule→reserved-kind 2px 띠 셀, text→기존 glyph RenderFrame 경로
pub fn lower(allocator, draws: []const ChromeDraw, tokens: Tokens, metrics: CellMetrics) !ChromeFrame;
```
tui 백엔드의 lowering 로직 = 현재 `sentinelBgCell`/`appendVerticalLine`/`appendHorizontalLine`/`buildSidebarDrawList`/`appendPaletteRow`를 **이주**한 것. 즉 새 코드가 아니라 현재 수작업 셀 생성을 백엔드로 격상.

### 5.4 Component 계약 — `chrome/components/*.zig`
Zig엔 trait가 없으니 **계약은 컨벤션**(각 컴포넌트 모듈이 같은 4개를 노출)이고 `ChromeHost`가 명시 호출한다(vtable 없음 — 컴파일타임 고정 집합, 기존 `self.palette`/`self.find` 패턴 그대로). 선례 = `FindState`/`PaletteState`.

```zig
// 예: chrome/components/notice.zig
pub const State = struct { open: bool = false, message: []const u8 = "", ... };   // 순수
pub fn view(state: *const State, props: NoticeProps, tokens: Tokens) ChromeDraw;  // 순수
pub fn hitTest(props: NoticeProps, p: Px) ?Region;                                // 순수(키보드 전용이면 생략)
pub fn handle(ev: InputEvent, state: *State) ?Action;                             // 순수, intent 반환
```
규칙(기존 패턴에서 승계):
- State는 **렌더를 모르고**, view는 **State를 읽기만**, handle은 **State를 mutate + `?Action` 반환**(단방향).
- 라이프사이클(언제 열고/배타성)은 **host**가 소유(현 `toggle*` 패턴).
- 동적 데이터(예: Find 매치)는 State에 슬롯으로 노출하고 채우기는 host(코어 단일 출처)에 위임 — State에 I/O·검색 안 넣음.
- handle은 **intent(`?Action`) 반환** 표준(palette `selectedAction` 선례). 부수효과 필요 시 host가 호출 후 수행(find `scroll`/`recompute` 선례).
- **레이아웃 단일 모델(view↔hitTest 공유) — 필수.** 마우스 컴포넌트(탭바·divider)는 `view`와 `hitTest`가 **하나의 픽셀-레이아웃 함수**(탭 advance·padding·icon slot·✕ 위치를 토큰에서 산출)를 공유한다. 그려진 위치와 클릭 영역이 같은 출처라야 한다. tui는 그 픽셀 레이아웃을 셀에 스냅하고, rich는 다른 레이아웃 토큰(둥근 탭·패딩·아이콘)만 준다 — 그래서 rich가 색뿐 아니라 *레이아웃*을 바꿔도 컴포넌트 코드는 불변이다. 현재 `BarMetrics`(hit-test)가 `paneTabWidth`(렌더)를 호출해 정렬을 맞추는 셀-열 결합을, 이 픽셀 모델로 일반화한 것. **이 공유가 깨지면 그려진 ✕와 클릭 ✕가 어긋난다(검증이 짚은 rich-layout seam).**

### 5.5 Props(seam) & ChromeState — `chrome/props.zig`, `chrome/state.zig`
컴포넌트는 **session을 모른다.** host가 매 프레임 불변 props를 빌드한다.

```zig
// 컴포넌트가 읽는 모델 데이터(불변 뷰). raw *Pane/*Split는 노출하지 않고 안정 핸들/값으로.
pub const ChromeProps = struct {
    workspaces: []const WorkspaceInfo,   // { title, active: bool } — self.tabs + active_tab
    active_tree: LayoutView,             // LeafRect[]/DividerSeg[] (이미 PaneTree.layout 산출)
    pane_tabs: []const PaneTabInfo,      // leaf별 { titles: []const []const u8, active_term }
    metrics: CellMetrics,                // cell_w/h_px, sidebar_width_px, backing_*, chrome_minimal, rects
    // 후속 richer props 후보(현재 chrome 미사용): cwd, command, process_state, exit
};
// 상호작용 상태 단일 소유 — 현재 DevSession에 흩어진 15개 필드를 한 곳으로(흩어진 stale 포인터 버그 계열 제거)
pub const ChromeState = struct {
    hovered_slot: ?usize = null, hovered_plus: bool = false, hovered_tab: ?TabRef = null,
    sidebar_drag: ?Drag = null, tab_drag: ?TabDrag = null, divider_drag: ?DividerDrag = null,
    sidebar_resize: bool = false,
    pub fn resetHover(self: *ChromeState) void { ... }  // 현 resetHoverState 승계
};
```
**수명 주의(리스크):** `divider_drag`/`tab_drag`/`drop_target`은 모델의 `*Split`/`*Pane`을 가리킨다 — heap-pin + 구조 변경 시 명시 null화로만 유효. ChromeState로 옮겨도 이 세션 트리와의 수명 결합은 그대로다. props가 안정 핸들(인덱스/`surface.id`)을 주면 이 결합을 줄일 수 있는지 C2/C3에서 평가.

### 5.6 ChromeHost — `chrome/host.zig` (드라이버)
세션과 chrome의 유일한 접점. 컴포넌트 집합·ChromeState 소유, props 공급, 입력 라우팅, 백엔드 호출.

```zig
pub const ChromeHost = struct {
    state: ChromeState,
    notice: notice.State, palette: palette.State, find: find.State, /* tabbar, sidebar, divider ... */
    pub fn buildFrame(self, props: ChromeProps, tokens: Tokens, backend, allocator) !ChromeFrame {
        var draws = ...; // 각 컴포넌트 view(state, props, tokens) 수집(layer 포함)
        return backend.lower(draws, tokens, props.metrics);
    }
    pub fn handleInput(self, ev: InputEvent, props: ChromeProps) ?Action {  // 모달 우선 라우팅(현 패턴)
        // notice/palette/find open이면 가로채 handle → ?Action; 아니면 hitTest로 마우스 라우팅
    }
};
```
세션(`view()`)은 `host.buildFrame(...)` 결과(`ChromeFrame`)를 `metal_buffer.replace(...)`의 chrome 인자들로 넘기기만 한다. 입력은 `host.handleInput(...)`이 반환한 `?Action`을 `dispatchAppAction`으로.

## 6. 현재 코드 → 새 구조 매핑

| 현재 (`app_dev_session.zig` 등) | → 새 위치 |
|---|---|
| `PaletteState`/`FindState` | `chrome/components/palette.zig`·`find.zig` (이동, 거의 그대로) |
| `sentinelBgCell`/`appendVerticalLine`/`appendHorizontalLine`/`buildSidebarDrawList`/`appendPaletteRow` | `platform/macos/chrome_tui_backend.zig` (lowering) |
| `sidebarBandCell`/`rebuildSidebar`/`buildSidebarTitleFrame` | `chrome/components/sidebar.zig` view + tui backend |
| `BarMetrics`/per-pane 탭바 렌더(`view()` 인라인) | `chrome/components/tabbar.zig` (view + hitTest) |
| `appendActiveTabDividers`/`dividerAtPoint`/`dividerHit` | `chrome/components/divider.zig` |
| `appendMinimalTabIndicator`/`appendActivePaneBorder` | `chrome/components/pane_decor.zig` |
| 15개 상호작용 필드 + `resetHoverState` | `chrome/state.zig` `ChromeState` |
| `sidebarBg/sidebarActiveBg/.../mutedForeground` 파생 | `chrome/tokens.zig` `Tokens.tui()` |
| `handlePaletteKey`/`handleFindKey`/모달 라우팅/`toggle*` | `chrome/host.zig` `handleInput` |

세션에 남는 것: PTY·frame loop·워크스페이스·resize·ABI·입력 전처리(US 배열 변환 등).

전체 시퀀싱(C0·S1·S2·C1~C4·B)과 의존성 순서는 [레이어링과 이식성 전략 §5](layering-and-portability.md#5-시퀀싱-의존성-순서-각-단계-green)가 단일 출처다. chrome 관점 요약:

- **C0 — 스켈레톤 + Notice (저위험 수직 슬라이스).** `chrome/{tokens,draw,backend,props,state,host}.zig` + `components/notice.zig` + `platform/macos/chrome_tui_backend.zig`. Notice는 키보드 전용(hitTest 불필요)이라 가장 작은 슬라이스로 **전 파이프라인(토큰→view→ChromeDraw→tui 백엔드→replace)을 증명**. 손상 알림(`workspace_window_count < 0`)을 `notice.State.show(...)`로 연결. 토큰화하며 **로더 갭(5 key) 메움**. check-boundaries에 `src/chrome` 경계 추가. (C0는 neutral 모델이라 동작 보존이 아닌 **신규 기능** — "동작 보존"으로 적지 않는다.)
- **S1·S2 (chrome 큰 조각 전에 선결, 상위 문서 소유)** — S1: session-tree **구조-무효화 계약** 형식화(§5.5의 stale 포인터 UAF 선제거). S2: session core(L2) 추출. C2/C3가 이 둘에 의존한다.
- **C1 — Palette·Find 이주.** 이미 순수 → 이동 + `view`가 ChromeDraw 뱉도록 + 렌더를 tui 백엔드로. 동작·테스트 보존.
- **C2 — Divider·pane_decor.** hitTest 컴포넌트 첫 도입(`dividerHit` 승계). `divider_drag`/`tab_drag_pane`의 **세션-트리 포인터 수명**은 S1 계약으로 다룬다(props 핸들로 줄이거나, 호스트가 구조-무효화 콜백 소유). **스냅샷 가드는 UAF를 못 잡으니** 명시적 null화 계약 필수.
- **C3 — TabBar·Sidebar(최대 추출).** `BarMetrics`/드래그/hit-test. 세션에서 chrome 코드가 떠나며 monolith가 얇아짐. **rich 픽셀-레이아웃 모델(§5.4)** 위에서 — view와 hitTest가 단일 레이아웃 소스를 공유해야 셀→픽셀 전환에서 클릭이 안 어긋난다. 가장 큰 위험 — UAF(S1) + 레이아웃 정합 둘 다 가드.
- **C4 — rich 백엔드 + rich 토큰.** `chrome_rich_backend`(렌더러 프리미티브 확장: rounded rect/gradient/icon) + `Tokens.rich()`. **컴포넌트 0줄 변경**(단 §5.4 레이아웃 모델 전제 — rich가 색뿐 아니라 *레이아웃*을 바꾸면 모델이 그걸 흡수해야 컴포넌트 불변이 성립). config `chrome.theme = tui|rich` 분기.

## 8. 테스트 전략 (관측 가능성 우선)

- **컴포넌트 단위(헤드리스)**: State 전이(현 palette/find 테스트 스타일) + `view(state,props,tokens)`가 내는 ChromeDraw를 단언(예: Notice open이면 modal layer에 text op) + `hitTest` 순수 함수(현 `sidebarBandCell`/`dividerHit`/`BarMetrics` 테스트 스타일).
- **백엔드 단위**: tui 백엔드가 ChromeDraw→NativeMetalCell을 정확히 lowering(밴드 col/width, border reserved-kind, 텍스트 glyph 수).
- **E2E/스냅샷**: ChromeDraw(또는 lowering된 셀)를 **스냅샷**으로 — 터미널 snapshot과 같은 결(chrome의 E2E 경로). 각 마이그레이션 단계가 "동작 보존"을 스냅샷 회귀로 증명.
- **게이트**: 기존 `check-boundaries`·`coretext/metal/app-dev 스모크`로 통합 회귀.

## 9. 결정 & 트레이드오프 (해소)

1. **ChromeDraw(semantic) 도입 O.** 셀 직출력보다 레이어 +1이지만, **이게 tui|rich를 컴포넌트 churn 0으로 만드는 핵심**이고 관측 가능성 원칙("한 데이터, 여러 소비자")과 정합. 도입.
2. **ChromeDraw 범위 = tui가 쓰는 fill/border/rule/text부터.** icon/gradient/shadow는 rich(C4) 때 확장(YAGNI).
3. **좌표 = 픽셀.** rich의 sub-cell 정밀도 위해. tui 백엔드가 셀로 스냅.
4. **컴포넌트 디스패치 = 컴파일타임 고정(vtable 없음).** 3rd-party 확장은 비목표(컴파일타임 라이브러리). host가 컴포넌트 집합을 명시 소유(현 패턴).
5. **터미널 콘텐츠는 별도 경로 유지.** chrome만 이 시스템. 둘은 `replace()`에서 합성.

## 10. 리스크 & 미해결

- **(높음) ChromeState 포인터 수명 — 경계를 넘는 UAF**: `*Split`/`*Pane`이 라이브 세션 트리를 가리킨다. 15필드를 ChromeState로 **옮겨도 결합은 안 옮겨진다** — S1의 구조-무효화 계약(트리 변형 시 단일 콜백으로 무효화)이 없으면 C3가 use-after-free다. 스냅샷 가드는 시각 회귀만 잡고 UAF는 못 잡으니([[devsession-undefined-test-field-trap]]), 명시적 null화 계약을 C2 전에 형식화.
- **(높음) chrome 추출은 necessary-not-sufficient**: chrome이 떠나도 `app_dev_session.zig`에 ~2500줄 OS-중립 세션 로직(workspace·split/IME·scroll)이 남아 platform/macos에 갇힌다. 2차 추출([layering-and-portability.md §3](layering-and-portability.md#3-두-번의-추출))이 이를 `src/session`으로 마저 뺀다.
- **(높음) rich-layout seam**: 현재 탭 분할(`paneTabWidth`)·hit-test(`BarMetrics`)가 셀-열에 고정 결합. rich가 레이아웃(둥근 탭·패딩·아이콘)을 바꾸면 view와 hitTest가 단일 픽셀-레이아웃 모델을 공유해야 한다(§5.4) — 안 그러면 그려진 ✕와 클릭 ✕가 어긋난다. C0 컴포넌트 계약에 이 모델을 처음부터 넣는다.
- **frame-loop 라벨**: `zig_owns_frame_loop`는 tick **본문** 소유일 뿐, 클럭은 OS(macOS `NSTimer` `.common`)다 — chrome은 무관하나 이식 시 타깃별 클럭 필요(상위 문서 §7).
- **텍스트 lowering 비용**: tui 백엔드의 text op이 glyph shaping(CoreText) 경로를 타므로, 컴포넌트별 RenderFrame 생성 빈도를 현재처럼 dirty-gated로 유지(여기에 ChromeDraw Op-slice라는 추가 transient tier가 얹히나 chrome 셀 수가 작아 무시 가능).
- **rich 범위 미정**: 어디까지 고급화(rounded/gradient/icon/shadow)는 C4 착수 전 별도 설계.
- **atlas 소유권**: 멀티 윈도우 공유는 grid-per-size로 수렴([multi-window-atlas-ownership] 메모리) — chrome glyph도 그 모델 따를지 C3에서.
- **로더 갭**: theme key 5개 미파싱 — C0 토큰화에서 메운다(안 메우면 rich 토큰도 config 불가).

## 11. 다음

C0 착수 전, 이 문서의 §5 타입 계약(특히 ChromeDraw 어휘·Props 형태)을 확정한다. 확정되면 C0(스켈레톤 + Notice + tui 백엔드 + 손상 알림 연결)부터 구현하며 각 단계 tests green을 유지한다.
