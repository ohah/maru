# 사이드바 그룹(접이식 워크스페이스 묶음) 전략

이 문서는 왼쪽 세로 사이드바의 **워크스페이스 그룹**(폴더처럼 묶어 접고 펴기)의 단일 출처다. 목표 UX,
근본 모델 재설계(왜 slot=card 가정을 걷어내는가), 데이터·직렬화·인터랙션·단계 분해·검증·리스크를 정한다.

사이드바 자체(카드 레이아웃·헤더·검색·드래그·스크롤)의 단일 출처는 [탭·split·레이아웃 전략](tabs-splits-layout.md)이고,
chrome 컴포넌트 경계는 [Chrome 전략](chrome-strategy.md) §5.4/§5.5다. 이 문서는 그 위에 **그룹**을 얹는 설계만 다룬다.

> **현황**: 설계 단계(구현 착수). **접기 우선** — 그룹 만들기·헤더 접기까지 먼저 구현하고, 카드 드래그
> 이동(넣기/빼기)·그룹 통째 재정렬·색은 후속(§9)이다. 구현이 진행되면 이 문서를 코드와 맞춘다
> ([project-rules](project-rules.md#문서와-설명)).

## 1. 목표 UX

워크스페이스는 repo/프로젝트 단위라 개수가 늘기 쉬운 축이다. 지금은 `pinned`(고정)·검색 필터로만 많은
워크스페이스를 다루는데, 그 위에 **조직화 레이어**로 그룹을 둔다.

- **그룹 = 연속한 워크스페이스 카드들의 이름 붙은 묶음.** 그룹 헤더(▾ 이름)를 클릭하면 그 그룹의 카드들이
  접히고(▸), 다시 클릭하면 펴진다. 접힌 그룹은 헤더 한 줄만 남아 사이드바가 짧아진다.
- **그룹에 속하지 않는 카드**(최상위)는 지금처럼 헤더 없이 그대로 나열된다 — 그룹은 opt-in이라 안 쓰면 현재와 동일.
- **그룹 안 카드는 살짝 들여쓰기**해 소속을 시각적으로 보인다(depth 1).
- **접힘 상태는 영속**한다 — 세션을 껐다 켜도 접어둔 그룹은 접힌 채로 복원된다(workspace.v1).
- **검색과 그룹의 상호작용**: 검색 중에는 매치된 카드가 어느 그룹에 있든 보여야 찾기 쉽다 → 검색 활성 동안은 **그룹
  접힘을 일시 무시**(매치 카드를 그 그룹 헤더 아래 펼쳐 보임). 검색을 지우면 원래 접힘 상태로 돌아온다. 접힘은 사용자
  의도(영속)지만 검색은 일시 질의라 검색이 우선한다(베이스: VSCode 탐색기 검색이 접힌 폴더를 임시로 펼치는 동작).

**베이스/결정**: 접이식 그룹은 브라우저 탭 그룹(Chrome/Arc)·VSCode 탐색기 폴더·에디터 사이드바의 collapsible section을
공통 관례로 삼는다. 특히 **소속을 위치에서 파생**(아래 §2·§3)하는 것은 브라우저 탭 그룹 동작을 베이스로 한다 — 탭을
그룹 안으로 끌면 들어가고 밖으로 빼면 나오지, 별도 "넣기 메뉴"가 주가 아니다. 레퍼런스(cmux 세로 사이드바)는 **최종
동작 비교(오라클)만** 참고하고 소스는 옮기지 않는다([clean-room](project-rules.md#기본-규칙)).

## 2. 핵심 결정 두 가지

### 2.1 소속을 저장하지 않고 "위치에서 파생"한다 (단순성의 열쇠)

카드에 `group_id` 같은 **소속 필드를 두지 않는다.** 대신 그룹은 `self.tabs` 순서 위의 **"여기서 새 그룹 시작"
마커**일 뿐이고, 각 카드의 소속은 순서에서 계산한다.

```
self.tabs:  t0    t1          t2   t3          t4   t5    t6
마커:        -    ▾frontend    -   ▾infra       -    -     -
파생 소속:  최상위 frontend  frontend infra   infra infra infra
```

- **각 카드의 소속 = 자기 위에서 가장 가까운 그룹 시작 마커.** 위에 마커가 없으면 **최상위**(별도 상태가 아니라 자동).
- **"넣기/빼기"라는 명시 동작·메뉴가 없다** — 카드를 드래그해 마커 아래로 옮기면 그 그룹, 마커 위(첫 마커 이전)로
  옮기면 최상위. 소속은 항상 위치가 정한다.
- **불변식(연속 파티션)**: 그룹은 다음 그룹 시작 마커 전까지 이어진다. 최상위 카드는 **첫 그룹 시작 이전 구간에만** 온다
  (한 번 그룹이 시작되면 리스트 끝까지 그룹 안 — 중간에 최상위로 "복귀"하는 경계는 두지 않는다). pinned의 `[고정][비고정]`
  파티션(session_model.zig:88, `moveTab` 3967)을 N-구간으로 일반화한 것이다.

이 결정으로 초안에 있던 **`group` 필드·넣기/빼기 메뉴·최상위 null 상태·그룹-탭 정합 검사가 전부 사라진다.** 저장할 것은
"어느 탭에서 그룹이 시작하고, 그 그룹이 접혔는가" 둘뿐이다(§3·§4).

### 2.2 표시 행(SidebarRow)을 1급 타입으로 승격 — slot=card 가정을 걷어낸다

현재 사이드바 hit-test/렌더는 **"슬롯 인덱스 = 탭 인덱스 = 화면 행"을 1:1로** 가정한다:

| 가정을 박은 곳 | 현재 동작 |
|---|---|
| `chrome/components/sidebar.zig` `slotAt`(42)/`slotTop`(55)/`dragTargetSlot`(118) | `y ↔ 슬롯 인덱스`를 `slot_height_px` 배수로 직접 환산. 슬롯은 곧 탭 |
| `sidebar.zig` `view`(135)/`bandFill`(174) | `row * slot_h`로 밴드 y 산출 — 한 탭 = 한 슬롯 |
| `coretext_frame_builder.zig` `sidebar_line_base = 32` | 세로 위치 `slot*32 + line_count*4 + line_index` 인코딩 — slot이 정수 탭 인덱스 |
| `app_session.zig` `sidebarBandCell`(486)/`rebuildSidebar`(11773) | 밴드·per-tab tint/accent를 탭 인덱스 순회로 lower |

여기에 "그룹 헤더 행"(클릭하면 접기, 카드가 아님)과 "접힌 그룹의 숨은 카드"(있지만 화면 행 없음)를 끼우면
**화면 행 ≠ 탭 인덱스**가 되어 위 1:1이 전부 깨진다. 여기에 하나씩 `if (is_header)` 분기를 뿌리면
([project-rules §구조와 파일 분리](project-rules.md#구조와-파일-분리) 위반) 조건이 여러 파일로 번져 유지보수가 무너진다.

**이미 절반은 만들어져 있다.** 검색 필터가 `app_session.zig`의 `sidebar_visible_tabs: []usize`(1407, 검색 통과한 원본
인덱스의 표시 순서), `recomputeVisibleTabs`(5770), `visibleTab`(5779, 슬롯→원본), `displaySlotOf`(5785, 원본→슬롯),
`sidebarTabs`(12414)로 **이미 "표시 행 = 탭의 부분·재배열 투영"**을 한다.

**결정: `sidebar_visible_tabs`(usize 배열)를 `Row` 배열로 격상한다.** Row는 "화면 한 줄"이고 카드일 수도 그룹
헤더일 수도 있다. 검색 필터·그룹 접힘·들여쓰기는 전부 **하나의 투영 함수**(`projectRows`)의 입력일 뿐이고, 하류(hit-test·
view·lowering)는 row가 카드인지 헤더인지만 보고 균일하게 처리한다.

```
(tabs, 그룹 시작/접힘 마커, search_query)  ──projectRows──▶  []Row
                                                              │
                     ┌─────────────────────────────────────────┴────────────┐
                hit-test (slotAt→row)                                  view (row별 밴드/헤더)
                드래그 (후속)                                          lowering (row별 셀/glyph)
```

- **검색 필터 = projectRows의 한 입력**(이미 있는 `tabMatchesSearch`).
- **그룹 접힘 = projectRows의 한 입력**(접힌 그룹의 카드 row를 안 낸다).
- **그룹 헤더 = Row의 한 variant**(카드가 아닌 줄).
- **미래 확장**(구분선·중첩·색)도 **Row/입력 추가**로 흡수 — 하류 코드 0 변경.

이게 slot=card 가정을 **근본적으로 제거**하는 단일 결정이다. 지금 검색이 우회로 쓰던 것을 정식 모델로 만들면,
검색·그룹·미래 기능이 **같은 한 지점(projectRows)**에서만 갈라지고 나머지는 불변이 된다([관측 가능성 원칙](project-rules.md#관측-가능성)).

## 3. 데이터 모델 — `src/session/session_model.zig`

§2.1 위치 파생이라 새 타입이 필요 없다. `Tab`(session_model.zig:80)에 **additive 스칼라 2개**만 얹는다.

```zig
// Tab 블록에 추가:
/// 이 탭에서 시작하는 그룹의 이름(owned). null=그룹 시작 아님(위 마커에 소속되거나 최상위).
/// 소속은 저장하지 않고 위치에서 파생한다(§2.1) — 이 필드는 "여기서 새 그룹 시작 + 그 이름"만 든다.
/// destroyTab이 해제(custom_name과 같은 규율). 빈 문자열이면 "그룹 N" 폴백(app.label.pick 동형).
group_start: ?[]const u8 = null,
/// group_start!=null일 때만 의미 — 그 그룹이 접혔는지(영속). 검색 활성 동안은 projectRows가 일시 무시.
group_collapsed: bool = false,
```

**소속·접힘 판정(파생, 순수 함수)**: `self.tabs`를 순회하며 `group_start`가 있는 탭에서 현재 그룹을 갱신하고, 그
탭부터 다음 `group_start` 전까지가 그 그룹이다. 접힘도 그 그룹 시작 탭의 `group_collapsed`를 따른다. `AppSession`은
추가 소유 상태가 없다(그룹은 탭에 산다).

## 4. 직렬화 — `maru.workspace.v1` (순수 additive, 상·하위호환)

[Workspace Restore 전략](workspace-restore.md#직렬화-전략-스칼라-필드-key-addressed-파싱)의 key-addressed 규율을 따른다.
§2.1 덕분에 **새 블록·count 키가 필요 없고**, `tab` 라인에 스칼라 2개만 붙인다:

```text
tab panes=1 active-pane=0 custom-name="web" ... group-start="frontend" group-collapsed=0
tab panes=1 ... custom-name="docs" ...                                    # group-start 없음 = frontend에 소속(위 파생)
tab panes=1 ... group-start="infra" group-collapsed=1
```

- **backward-compat(새 바이너리 ← 옛 파일)**: `group-start`/`group-collapsed` 없음 → `null`/`false` → 그룹 없는 flat 정상 복원(`getQuoted`/`getUint` 기본값, additive).
- **forward-compat(옛 바이너리 ← 새 파일)**: 스칼라라 옛 리더가 **모르는 키로 자연 skip**(workspace.zig `LineFields` 미지 키 skip) → flat으로 정상. **다운그레이드해도 그룹만 안 보일 뿐 워크스페이스가 안 깨진다.** 초안의 `group` 블록(새 라인 타입 → 통째 폴백)보다 훨씬 견고하다 — 위치 파생의 직접 이득이다.
- **writer**: `tab` 라인 끝(writeTab, workspace.zig:134)에 두 키를 항상 쓴다(round-trip 고정점). group-start=""(빈)은 "그룹 아님"과 구분해 안 쓰거나, null은 키 자체를 생략(빈 문자열=이름 없는 그룹 시작과 충돌 방지 — null은 키 없음으로 인코딩).

## 5. chrome 컴포넌트 계약 — `src/chrome/components/sidebar.zig`

컴포넌트는 여전히 **무상태 순수 함수**(hit-test + view)다. `Tab`(라벨·활성)을 **`Row`(union)로 대체**하고, 모든 함수가
`tab_count: usize` 대신 `rows: []const Row`를 받게 일반화한다. host(platform)가 `projectRows`로 Row 배열을 채운다.

```zig
/// 사이드바 화면 한 줄. host가 projectRows로 tabs+마커+search를 이 리스트로 투영한다.
pub const Row = union(enum) {
    group_header: struct {
        collapsed: bool,
        label: []const u8,   // 그룹 이름(빈 문자열이면 platform이 "그룹 N" 폴백해 주입)
        member_count: u16,   // 접힘 시 "▸ name (N)" 표시용
    },
    card: struct {
        tab: usize,          // 원본 self.tabs 인덱스(visibleTab의 일반화)
        active: bool,
        label: []const u8,
        depth: u8,           // 0=최상위, 1=그룹 안(들여쓰기 = depth * tokens.space.group_indent_px)
    },
};

// hit-test: **가변 row 높이**(카드=slot_h, 헤더=header_row_h). y↔row를 고정 나눗셈이 아니라 rows를 순회하며
// 각 row 높이를 누적해 환산한다(순수 함수 — headless 테스트 가능). rows를 받아 종류로 높이를 판별한다.
pub fn rowHeight(row: Row, card_slot_h: u32, header_row_h: u32) u32; // card→slot_h, group_header→header_row_h
pub fn slotAt(y_px: f64, header_height_px: u32, rows: []const Row, card_slot_h: u32, header_row_h: u32, scroll_offset_px: u32) ?usize;
pub fn rowTop(rows: []const Row, index: usize, header_height_px: u32, card_slot_h: u32, header_row_h: u32, scroll_offset_px: u32) i64; // 옛 slotTop의 누적판
pub fn contentHeight(rows: []const Row, card_slot_h: u32, header_row_h: u32) u32; // 스크롤 clamp용(옛 rows.len*slot_h)
pub fn dragTargetSlot(...) usize;  // 후속(드래그 단계)에서 그룹 경계 인지 확장

// view: rows를 순회하며 header row엔 헤더 밴드+삼각(▾/▸), card row엔 기존 카드 밴드(depth 들여쓰기).
pub fn view(rows: []const Row, hovered: ?usize, drop: ?usize, p: props.ChromeProps, arena, out) !void;

// 그룹 헤더 hit — 헤더 row 전체가 접기 토글 클릭 영역(closeButton과 같은 결의 순수 함수).
pub fn onGroupHeader(rows: []const Row, row_index: usize) bool;
```

**핵심(§5.4 레이아웃 단일 소스 유지) — 가변 row 높이(사용자 결정)**: row는 종류별로 높이가 다르다 — **카드=`slot_h`**
(≈cell 3.8×, 이름·브랜치·경로 3줄), **그룹 헤더=`header_row_h`**(≈cell 1줄, 촘촘하게). hit-test(`slotAt`/`rowTop`)는
고정 `y/slot_h` 나눗셈 대신 **rows를 순회하며 각 row 높이를 누적**해 y↔row를 환산한다(여전히 순수 함수라 headless
테스트 가능). view도 **같은 누적 레이아웃 함수**(`rowTop`)로 밴드 y를 내야 정합이 유지된다(§5.4 — view와 hit-test가
한 레이아웃 소스 공유). **베이스/결정**: 브라우저 탭 그룹·VSCode 폴더가 헤더를 얇은 한 줄로 둬 촘촘한 게 접이식 그룹의
핵심 가치라, 균일 격자(구현 단순)보다 **가변 높이(시각 우선)**를 택했다.

**파급 — glyph 세로 위치 인코딩(§10 리스크)**: 현재 `coretext_frame_builder.sidebarGlyphRow`의 `slot*32` 인코딩은 `.m`
렌더러가 `slot*slot_h`로 디코드해 **균일 높이를 가정**한다(단일 출처). 가변 높이면 이 곱셈이 깨지므로 SG3에서 `.m`이
row별 누적 y(또는 각 row 높이/누적 오프셋 배열)를 받도록 인코딩·디코드를 함께 고쳐야 한다 — 이게 가변 높이의 실제
비용이다(hit-test는 Zig 순수라 누적이 쉽지만, glyph는 Zig↔`.m` FFI 경계라 양쪽을 맞춰야 함). 세로 스크롤 클리핑도
같은 누적 y를 쓴다. 헤더 glyph(삼각+이름)는 카드 제목과 같은 `buildSidebarDrawList` 경로에 row 종류만 분기한다.

## 6. platform 오케스트레이션 — `src/platform/macos/app_session.zig`

`sidebar_visible_tabs`(§2.2)를 **`sidebar_rows: []Row`로 격상**하고, `recomputeVisibleTabs`를 **`projectRows`로 일반화**한다.

```zig
/// tabs + 그룹 마커 + 검색 → 표시 행 리스트. recomputeVisibleTabs의 일반화(단일 투영점).
/// 규칙: self.tabs를 순회하며 (1) group_start 탭에서 group_header row 삽입, (2) 접힌 그룹의 카드는 skip
///       (단 검색 활성 시 매치 카드는 접힘 무시하고 냄), (3) 검색 미매치 카드는 skip(기존 tabMatchesSearch).
fn projectRows(self: *AppSession) void { ... }   // self.sidebar_rows 채움
```

- `visibleTab`/`displaySlotOf`는 **row↔tab 매핑**으로 흡수(`rows[i].card.tab`). 헤더 row는 tab이 없어 클릭 시 선택이 아니라 **접기 토글**로 분기.
- `rebuildSidebar`(11773)·per-tab tint/accent 루프는 `self.tabs` 순회 대신 **`sidebar_rows` 순회**로(카드 row만 tint).
- 세로 스크롤은 **거의 공짜로 흡수** — `sidebar_scroll_offset_px`·`clampSidebarScroll`(11634)이 콘텐츠 높이(row 수 × slot_h)만 보므로 접기로 row 수가 줄면 자동 재clamp(tabs-splits-layout.md ③c). 접힘 토글 시 `rebuildSidebar`가 이 재clamp를 부른다.

## 7. 인터랙션 (접기 우선)

| 동작 | 단계 | UX | 구현 경로(베이스) |
|---|---|---|---|
| **그룹 접기/펴기** | **우선** | 헤더 줄 클릭(삼각 ▾/▸) | `onGroupHeader` → 그 그룹 시작 탭의 `group_collapsed` 토글 → `projectRows` 재투영 + 영속(§4) |
| **그룹 만들기** | **우선** | 우클릭 "새 그룹으로 묶기"(이름 입력) | `buildContextMenuItems`(이미 pin·색 동적 주입)에 항목 추가 → 그 탭에 `group_start` 세팅. 그 아래 연속 카드가 자동 소속(위치 파생) |
| **그룹 이름 바꾸기** | **우선** | 헤더 더블클릭 | rename 인라인 편집(`OverlayInput`) — 워크스페이스 rename과 동형(tabs-splits-layout.md rename) |
| **그룹 해제** | **우선** | 우클릭 "그룹 풀기" | 그 탭의 `group_start=null`(마커 제거) → 아래 카드는 위 마커/최상위로 자동 재소속 |
| 카드 드래그로 넣기/빼기 | 후속 | 카드를 마커 위/아래로 드래그 | `moveTab`(3967) 확장 — 드롭 위치가 소속을 정함(위치 파생이라 별도 소속 편집 없음) |
| 그룹 통째 드래그·색 | 후속 | 헤더 잡아 재정렬 / 그룹 색 | `sidebar_drag_*` 확장, `group_indent`/색 토큰 |

**접기 우선의 이유**: 접기·만들기·이름·해제만으로 "묶어서 접는" 핵심 가치가 완성된다. 카드 이동은 드래그 재정렬(`moveTab`)과
드롭 좌표→그룹 경계 매핑이라 표면이 크므로 별도 단계로 뺀다. 위치 파생이라 후속에서 카드 이동을 붙여도 **소속 편집 코드가
따로 없다**(순서 바꾸면 소속 자동) — 접기 우선과 후속이 데이터 모델을 공유한다.

## 8. 관측 가능성·검증

[관측 가능성 원칙](project-rules.md#관측-가능성)대로 **단일 도메인 데이터(Row 투영)**를 여러 소비자가 쓴다 — 렌더·hit-test·
스냅샷·테스트가 모두 `projectRows` 결과를 본다.

- **컴포넌트 단위(헤드리스)**: `projectRows`가 순수 함수라(입력 tabs/마커/search → Row[]) **헤드리스 단언**이 1급이다:
  접힘 시 카드 row 제외·헤더 member_count·검색 시 접힘 무시·소속 파생(위 마커)·depth. `slotAt`/`slotTop`을 헤더 섞인
  row 배열로 확장(기존 `sidebar.zig` 테스트 스타일).
- **직렬화 round-trip**: `group-start`·`group-collapsed`가 serialize→parse→serialize 고정점(workspace.zig 기존 테스트 확장).
  하위호환: 두 키 없는 옛 파일이 flat으로 정상 복원(기존 "key-addressed 하위호환" 테스트 확장).
- **E2E/스냅샷**: 접힌/펼친 사이드바 셀 스냅샷. 헤더 glyph(삼각+이름)·들여쓰기는 macOS 제품 스크린샷으로 고정
  ([검증 매트릭스](verification-matrix.md): macOS 렌더 변경은 직접 검증).
- **게이트**: `check-boundaries`(chrome는 session/platform 모름 — Row는 chrome 중립 타입)·coretext/metal/app 스모크.

## 9. 단계 분해 — 각 단계 독립 동작·green

근본 모델(§2.2 Row 투영)을 **먼저** 깔고, 그 위에 그룹을 얹는다. 모델 이주는 동작 보존(그룹 0개면 현재와 동일)이라 위험이 낮다.

1. **SG1 — chrome Row 토대(동작 보존, 그룹 없음) ✅**: `sidebar.zig`를 `Tab`→`Row` union(card+group_header)으로
   일반화 — hit-test(`slotAt`/`dragTargetSlot`, count=row 수)·`view`가 row 위에서 균일 동작하고, host(`sidebarRows`)가
   `Row.card`를 공급한다(헤드리스 테스트: 헤더가 섞여도 카드 밴드만·슬롯=row 인덱스 유지). app_session 내부
   `sidebar_visible_tabs` → `sidebar_rows` **완전 격상은 헤더가 실제로 필요한 SG3로 미룬다**(카드만일 땐
   `sidebar_visible_tabs`로 충분 — YAGNI, 각 단계 green). 순수 리팩터라 검색·재정렬·스크롤 동작 그대로.
2. **SG2 — 데이터·직렬화 ✅**: `Tab.group_start`/`group_collapsed`(session_model + workspace 모델) + workspace.v1
   `group-start`/`group-collapsed` 스칼라(순수 additive) + 캡처/복원 변환(owned dup·errdefer·deinit free) +
   round-trip·하위호환·leak 테스트. 렌더는 아직 안 붙임(모델만).
3. **SG3 — sidebar_rows 격상 + 가변 높이 + 헤더 렌더 + 접기 + 만들기/이름/해제** (가변 높이라 커서 하위 분할):
   - **SG3a — sidebar_rows 격상 + 가변 높이 hit-test(그룹 없이 동작 보존)**: app_session `sidebar_visible_tabs` →
     `sidebar_rows: []Row` 완전 격상(`recomputeVisibleTabs` → `projectRows`; `visibleTab`/`displaySlotOf`·rebuildSidebar
     tint/accent 루프를 row 기반으로 — 조사 맵의 "표시 슬롯 도메인" 전부). `sidebar.zig` hit-test를 **가변 높이 누적**
     (`rowTop`/`slotAt`/`contentHeight`)으로 바꾸되 아직 헤더 row는 없어 전부 카드(누적=균일과 동일 → 동작 보존, 스냅샷 회귀).
     두 latent 버그 교정(rename caret `rowTop`, 드래그 `dragTargetSlot`).
   - **SG3b — 헤더 row + glyph 가변 인코딩**: `projectRows`가 group_header row 삽입(카드 depth 들여쓰기), `view`가 헤더
     밴드+삼각(▾/▸), `buildSidebarDrawList`+`.m`이 헤더 glyph(삼각+이름)와 **row별 누적 y**로 세로 위치를 그린다
     (§5 파급 — `sidebarGlyphRow` 균일 곱셈을 누적으로, `.m` 디코드 동반 수정). macOS 제품 스크린샷 검증.
   - **SG3c — 접기 + 만들기/이름/해제**: 헤더 클릭 → `group_collapsed` 토글 → 재투영·영속. 우클릭 "새 그룹으로 묶기"/
     "그룹 풀기" + 헤더 더블클릭 rename + closeTab 마커 승계. **여기까지가 "접기 우선" 완료.**
4. **SG4(후속) — 카드 드래그 넣기/빼기**: `moveTab` 확장 + 드롭 좌표→그룹 경계.
5. **SG5(후속) — 그룹 통째 드래그·색·(선택)중첩**.

## 10. 리스크 & 미해결

- **(중) 이주 표면(SG3a)**: `sidebar_visible_tabs` → `sidebar_rows` 격상이 `app_session` 오케스트레이션(조사 맵의 표시-슬롯
  도메인 12+곳)을 건드린다. 동작 보존 리팩터라 **스냅샷 회귀가 안전망**이다 — 착수 전 현재 사이드바 스냅샷을 고정해 두고 이주 후 동일 확인.
- **(높음) 가변 높이 glyph 인코딩(Zig↔`.m` FFI, SG3b)**: §5 파급 — `sidebarGlyphRow`의 `slot*32` 균일 인코딩과 `.m`의
  `slot*slot_h` 디코드가 균일 높이를 가정한다. 가변 높이면 이를 **row별 누적 y**로 함께 고쳐야 한다. hit-test(Zig 순수)는
  누적이 쉽지만 glyph는 FFI 경계라 양쪽 정합이 필요하고, 세로 위치는 headless로 안 잡혀 **macOS 제품 스크린샷 검증 필수**.
  가변 높이의 실제 비용이 여기 몰린다(사용자가 시각 품질을 위해 택한 트레이드오프).
- **(낮) 위치 파생의 경계 제약**: 최상위 카드는 첫 그룹 시작 이전 구간에만 온다(§2.1) — 그룹들 사이에 최상위 카드를 끼울 수
  없다. 브라우저 탭 그룹도 사실상 이 모델이라 실용상 충분. 정말 필요하면 후속에서 "그룹 끝" sentinel 마커로 열 여지만 둔다.
- **(낮) 접힌 그룹에 넣기**: 카드 드래그(SG4)에서 접힌 헤더에 드롭하면 그 그룹 끝에 추가로 처리(브라우저 관례). 접기 우선
  단계(SG1~3)에는 드래그가 없어 무관.
- **(낮) 접힘 상태 위치**: `group_collapsed`를 workspace.v1에 둔다(세션 넘어 유지). config가 아니라 workspace인 이유 — 그룹은
  per-워크스페이스-파일 구조이지 전역 설정이 아니다.
- **(낮) group_start 앵커 수명**: 그룹 시작 탭이 닫히면(closeTab) 그 `group_start` 마커를 **다음 탭으로 승계**해야 그룹이
  사라지지 않는다(그룹의 첫 카드를 닫아도 나머지가 그룹에 남게). 마지막 카드까지 닫히면 그룹 소멸 — SG3에서 closeTab 경로에 처리.

## 11. clean-room

- **cmux**(GPL-3.0): 세로 사이드바·그룹 UX가 있다면 **최종 동작 비교(오라클)만**, 소스 미열람.
- **Chrome/Arc 탭 그룹·VSCode 탐색기 폴더**: collapsible section·검색-임시-펼침·**위치 기반 소속**의 동작 관례만 베이스로 참고(공개 제품 UX).
- 자료구조·함수 분해는 옮기지 않고 위 §2~§9의 maru 독립 설계(위치 파생·Row 투영·연속 파티션)로 재구현한다.
