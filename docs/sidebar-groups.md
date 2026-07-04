# 사이드바 그룹(접이식 워크스페이스 묶음) 전략

이 문서는 왼쪽 세로 사이드바의 **워크스페이스 그룹**(폴더처럼 묶어 접고 펴기)의 단일 출처다. 목표 UX,
근본 모델 재설계(왜 slot=card 가정을 걷어내는가), 데이터·직렬화·인터랙션·단계 분해·검증·리스크를 정한다.

사이드바 자체(카드 레이아웃·헤더·검색·드래그·스크롤)의 단일 출처는 [탭·split·레이아웃 전략](tabs-splits-layout.md)이고,
chrome 컴포넌트 경계는 [Chrome 전략](chrome-strategy.md) §5.4/§5.5다. 이 문서는 그 위에 **그룹**을 얹는 설계만 다룬다.

> **현황**: **SG1~SG5-3 완료** — 접기 우선(그룹 만들기·헤더 실제 렌더·접기·rename·단축키, 제품 스크린샷 검증) + 카드
> 드래그로 넣기/빼기(SG4) + 그룹 통째 드래그(SG5-1) + 그룹 색(SG5-2, 헤더 밴드 tint·소속 카드 막대·우클릭 프리셋) +
> **중첩 그룹(SG5-3, 폴더 트리처럼 그룹 안 그룹 — 위치 파생을 다단계 depth로 일반화)**. 구현이 진행되면 이 문서를 코드와
> 맞춘다([project-rules](project-rules.md#문서와-설명)).

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
- **다단계(중첩) 불변식(SG5-3)**: 중첩은 위 규칙을 **depth로 일반화**한다. `Tab.group_depth`(1=최상위 그룹·2=중첩·…)로
  각 마커의 깊이를 두고, projectRows가 `self.tabs`를 스택으로 훑어 **각 카드의 depth = 자기 위에서 유효한 가장 가까운
  마커(스택 top)의 depth**로 파생한다. 핵심 제약: **부모 그룹의 직접 카드는 자식 그룹보다 앞에 온다** —
  `[부모마커, 부모직접카드들…, 자식마커, 자식카드들…]` 순이고, 자식 그룹이 끝나고 부모의 직접 카드로 "복귀"하는 경계는
  두지 않는다(SG1의 "중간 최상위 복귀 없음"을 다단계로 일반화 — 카드에 마커가 없으면 스택 top depth를 그대로 받으므로,
  자식으로 들어간 뒤 같은 depth의 부모 직접 카드를 다시 낼 방법이 위치상 없다). 마커의 정규화 depth는 항상 `부모depth+1`로
  **gap을 클램프**한다(선언 depth가 부모+1을 넘어도 한 칸씩만 깊어짐 → 트리가 항상 연속·구멍 없음). 형제 그룹은 같은 depth
  마커가 앞 그룹을 스택에서 pop하며 시작한다(`[부모][형제]`처럼 `[자식A][자식B]`도 같은 depth로 나란히).

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

> **이 절은 SG3까지의 목표 계약이다(현재 코드와 다름).** SG1(✅)은 `Row` union(card+group_header)과 `view`를 넣되
> hit-test는 아직 **고정 높이·count 기반**(`slotAt(y, header, slot_height_px, scroll, row_count)`·`slotTop`·`dragTargetSlot`)을
> 유지한다(헤더가 없어 충분 — 카드만이면 누적=균일). 아래 **가변 높이 시그니처**(`rowHeight`/`rowTop`/`contentHeight`, `slotAt`이
> `rows`+두 높이를 받는 형태)와 `onGroupHeader`는 **SG3a/b/c에서** 이 계약으로 이주한다. 즉 아래 코드 스케치는 SG3 완료 시점의 모습이다.

```zig
/// 사이드바 화면 한 줄. host가 projectRows로 tabs+마커+search를 이 리스트로 투영한다.
pub const Row = union(enum) {
    group_header: struct {
        tab: usize,          // 소스 group-start 탭 인덱스 — 헤더 glyph가 self.tabs[tab].group_start를 **live** 읽어(borrowed UAF #8 해소), 접기 토글·rename 타깃 겸용
        collapsed: bool,
        label: []const u8,   // 레거시(이제 tab에서 live 읽어 load-bearing 아님)
        member_count: u16,   // 접힘 시 "▸ name (N)" 표시용 — 이 그룹 **직접 카드 수**(중첩 자식 그룹 안 카드는 제외, SG5-3)
        depth: u8 = 0,       // 정규화 중첩 깊이(SG5-3, 1=최상위·2=중첩·…). 헤더 삼각/이름 glyph를 (depth-1)*group_indent 들여씀(카드는 depth*group_indent). 밴드(view)는 depth 무관 전폭
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

**메트릭 출처(SG3b에서 확정)**: `card_slot_h` = 기존 `props.metrics.sidebar_slot_height_px`(그대로 재사용). `header_row_h` =
**신규 메트릭** — 헤더 한 줄이므로 `≈ cell_height_px`(+세로 패딩 약간)로 두고 `CellMetrics`에 추가한다(platform이 채움).
`group_indent_px`(card.depth 들여쓰기 폭) = **신규 spacing 토큰**(`tokens.space`), rich에서 ≈1ch. 셋 다 hit-test·view가
공유하는 단일 값이라, 값이 흩어지지 않게 한 곳(props/tokens)에서만 정의한다(§5.4 레이아웃 단일 소스).

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
///       (단 검색 활성 시 매치 카드는 접힘 무시하고 냄), (3) 검색 미매치 카드는 skip(기존 tabMatchesSearch),
///       (4) 표시 카드가 0개가 된 그룹의 헤더는 아래 "빈 그룹" 규칙, (5) member_count = 표시 카드 수(검색 중=매치 수).
fn projectRows(self: *AppSession) void { ... }   // self.sidebar_rows 채움
```

- `visibleTab`/`displaySlotOf`는 **row↔tab 매핑**으로 흡수(`rows[i].card.tab`). 헤더 row는 tab이 없어 클릭 시 선택이 아니라 **접기 토글**로 분기.
- `rebuildSidebar`(11773)·per-tab tint/accent 루프는 `self.tabs` 순회 대신 **`sidebar_rows` 순회**로(카드 row만 tint).
- 세로 스크롤은 **거의 공짜로 흡수** — `sidebar_scroll_offset_px`·`clampSidebarScroll`(11634)이 콘텐츠 높이(row 수 × slot_h)만 보므로 접기로 row 수가 줄면 자동 재clamp(tabs-splits-layout.md ③c). 접힘 토글 시 `rebuildSidebar`가 이 재clamp를 부른다.

**빈 그룹 헤더 규칙(엣지 — §8 검증)**: 그룹의 표시 카드가 0개가 될 때 헤더를 낼지가 두 경우로 갈린다.
- **접힘으로 카드가 없는 건 정상** → 헤더를 **남긴다**(`▸ name (N)`). 그게 접힘의 목적이다.
- **검색 매치가 0인 그룹**(그 그룹 어느 카드도 질의에 안 맞음) → 헤더까지 **skip**한다. 그 그룹은 질의와 무관하니 통째 숨겨야
  "매치만 보인다"가 성립한다(빈 헤더만 덩그러니 뜨는 걸 막음).
- 정리: **평소** = 접힌 그룹은 헤더만·펼친 그룹은 헤더+카드. **검색 중** = 매치 있는 그룹만 헤더+매치카드로 뜨고, 매치 없는
  그룹은 헤더째 사라진다. `member_count`는 접힘 배지(`(N)`)용이라 평소엔 **그룹 전체 카드 수**, 검색 중엔 그 그룹이 매치로
  떠 있을 때의 **매치 수**로 채운다.

## 7. 인터랙션 (접기 우선)

| 동작 | 단계 | UX | 구현 경로(베이스) |
|---|---|---|---|
| **그룹 접기/펴기** | **우선** | 헤더 줄 클릭(삼각 ▾/▸) | `onGroupHeader` → 그 그룹 시작 탭의 `group_collapsed` 토글 → `projectRows` 재투영 + 영속(§4) |
| **그룹 만들기(중첩)** | **우선** | 우클릭 "새 그룹으로 묶기" · **단축키 `Cmd+Opt+G`** · 팔레트 "New Group" | `create_group` 액션 → 활성/클릭 탭에 `group_start` 세팅. **그룹 안 카드면 depth+1 중첩**(§9), 최상위면 depth 1. 아래 연속 카드가 자동 소속(위치 파생) |
| **형제 그룹으로 분리** | ✅ SG5-3 | 우클릭 "형제 그룹으로 분리" · **단축키 `Cmd+Opt+Shift+G`** · 팔레트 "New Sibling Group" | `create_sibling_group` 액션 → 그 카드에 `group_start` 세팅 + `group_depth=현재 그룹과 같은 depth`(형제, 중첩 아님). 최상위면 depth 1(create_group과 결과 동일). create_group의 미러 — depth 계산만 다르다(§10 tension 해소) |
| **그룹 이름 바꾸기** | **우선** | 헤더 더블클릭 | rename 인라인 편집(`OverlayInput`) — 워크스페이스 rename과 동형(tabs-splits-layout.md rename) |
| **그룹 해제** | **우선** | 우클릭 "그룹 풀기" · 팔레트 "Ungroup"(기본 키 없음) | `ungroup` 액션 → 그 탭의 `group_start=null`(마커 제거) → 아래 카드는 위 마커/최상위로 자동 재소속 |
| **카드 드래그로 넣기/빼기** | ✅ SG4 | 카드를 마커 위/아래·헤더로 드래그 | `sidebarGroupDropTargetTab`(드롭 row→목표 탭 매핑) + `sidebar_drop_slot` 하이라이트. 위치 파생이라 별도 소속 편집 없음. 마커 탭 드래그=그룹 통째=SG5 |
| **그룹 통째 드래그** | ✅ SG5-1 | 헤더 잡아 드래그(클릭=접기와 threshold 구분) | `moveGroupRange`(구간 블록 이동)·`sidebarGroupDropBoundary`(경계 clamp)·`sidebar_group_drag_*` |
| 그룹 색 | ✅ SG5-2 | 우클릭 "그룹 색: …" 프리셋(카드 색과 같은 팔레트) / 헤더 밴드 tint·소속 카드 막대 | `group_start` 탭에 `group_color` 저장(마커 하나에만, 소속 카드는 위치 파생). 헤더 밴드=lowerSidebar 블렌드(카드 배경 tint와 같은 경로)·소속 카드 막대=per-tab accent 루프(개별 accent>그룹 색>기본). workspace.v1 `group-color`(0=키 생략) |

**단축키·설정 노출(베이스/결정)**: `create_group`/`ungroup`을 **bindable 액션**으로 정의하고 `command_catalog`에 등록하면
세 경로에 **자동으로** 뜬다 — (1) 커맨드 팔레트, (2) 설정 화면(⌘,) Input 섹션의 **키바인딩 리바인더**(행 클릭 → 녹음
모드로 지정/수정, `CS-4-3` 이미 구현), (3) config `keybind = <조합> = create_group`. 새 GUI 코드는 0이다(스키마 스칼라가
아니라 카탈로그 기반 bespoke 리바인더가 이미 존재 — [config-gui.md §6.7](config-gui.md)). 우클릭·팔레트·키·컨텍스트
메뉴가 **같은 세션 메서드**를 부른다(rename이 세 트리거를 `startRename`으로 모으는 패턴 — tabs-splits-layout.md).

**기본 단축키 = `Cmd+Opt+G`**(create_group=중첩) · **`Cmd+Opt+Shift+G`**(create_sibling_group=형제, SG5-3). `Cmd+Shift+G`는
**Find Previous가 선점**(keybinding.zig `default_app_bindings`, macOS Find Next/Previous 관례)이라 못 쓰고, `Cmd+Opt+G`는
비어 있으면서 `G`로 그룹을 직관적으로 표현한다(`Cmd+Opt`는 이미 pane/Term 이동 modifier 그룹이나 `G` 키는 미사용 — 충돌
없음). `create_sibling_group`은 `Cmd+Opt+Shift+G`로 create_group과 **Shift만 다르게** 둔다(Cmd+Opt+Shift+G는 미사용 — 선점
확인). maru 규율은 "macOS 단일 관례가 없는 기능은 기본 키를 비우고 bindable만"([key-input-and-shortcuts.md](key-input-and-shortcuts.md);
rename·move_pane이 그 예)이지만, **사용자 요청으로 create_group·create_sibling_group에 기본 키를 부여**한다(사용자 결정이
베이스 — 브라우저/VSCode에도 표준 그룹 단축키는 없다). `ungroup`은 저빈도라 기본 키 없이 팔레트/우클릭/설정 리바인더로
지정한다. 액션 추가는 4곳: `action.zig`의 `Action` union + `parseAction` + `dispatchAppAction` arm + `command_catalog`
entry(SG3c에서 create_group·ungroup·rename_group, SG5-3에서 create_sibling_group 추가). 세 그룹-생성/해제 액션과 우클릭·
팔레트·키·컨텍스트 메뉴가 **같은 세션 메서드**를 부른다(create_group→`createGroupForTab`·create_sibling_group→`createSiblingGroupForTab`,
둘 다 `beginGroupForTab`(kind) 공유 — depth 계산만 다름).

**접기 우선의 이유**: 접기·만들기·이름·해제만으로 "묶어서 접는" 핵심 가치가 완성된다. 카드 이동은 드래그 재정렬(`moveTab`)과
드롭 좌표→그룹 경계 매핑이라 표면이 크므로 별도 단계로 뺀다. 위치 파생이라 후속에서 카드 이동을 붙여도 **소속 편집 코드가
따로 없다**(순서 바꾸면 소속 자동) — 접기 우선과 후속이 데이터 모델을 공유한다.

## 8. 관측 가능성·검증

[관측 가능성 원칙](project-rules.md#관측-가능성)대로 **단일 도메인 데이터(Row 투영)**를 여러 소비자가 쓴다 — 렌더·hit-test·
스냅샷·테스트가 모두 `projectRows` 결과를 본다.

- **컴포넌트 단위(헤드리스)**: `projectRows`가 순수 함수라(입력 tabs/마커/search → Row[]) **헤드리스 단언**이 1급이다:
  접힘 시 카드 row 제외·헤더 member_count·검색 시 접힘 무시·소속 파생(위 마커)·depth·**빈 그룹 규칙**(접힘=헤더만 뜸 /
  검색 매치 0=헤더째 사라짐). 가변 높이 hit-test(`slotAt`/`rowTop`/`contentHeight`)를 **헤더 섞인 row 배열 + 서로 다른
  card_slot_h/header_row_h**로 확장해 **누적 y ↔ row** 정합을 단언(카드만이면 누적=균일이라 SG3a 동작 보존도 같은 테스트로).
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
   - **SG3a — sidebar_rows 격상 + 가변 프리미티브(그룹 없이 동작 보존) ✅**: app_session `sidebar_visible_tabs` →
     `sidebar_rows: []Row` 완전 격상(`recomputeVisibleTabs`가 `Row.card` 채움; `visibleTab`/`displaySlotOf`·rebuild
     tint/accent·glyph 조립·⌘숫자 배지·`anyAgentRunning`을 row switch로 — 조사 맵의 "표시 슬롯 도메인" 전부). `sidebar.zig`에
     가변 누적 프리미티브(`rowHeight`/`rowTop`/`contentHeight`) 추가 + 헤드리스 테스트(**카드만이면 `rowTop`==옛 `slotTop`**로
     동작 보존 증명). **`slotAt`/`dragTargetSlot`의 가변 교체·`slotTop`→`rowTop` 전환·두 latent 버그(rename caret·드래그)
     교정은 헤더가 실제로 가변을 요구하는 SG3b로 미룬다**(헤더 없는 SG3a는 고정 hit-test로 카드만 처리 = 균일이라 동작 보존).
   - **SG3b — 헤더 row + 가변 hit-test + glyph 가변 인코딩** (완료 + SG3c로 묶인 잔여):
     - **SG3b-1 ✅**(머지 #1174): `slotAt`/`dragTargetSlot` 가변 교체 + `slotTop`→`rowTop` + rename caret 버그 교정.
     - **SG3b-2-i ✅**(머지 #1174): `projectRows`가 group_header row 삽입·카드 depth·접힘·빈 그룹 규칙·member_count.
     - **SG3b-2-ii**(카드 glyph 완료, 헤더 실제 렌더는 SG3c): (a) `header_row_h` 메트릭 배선 ✅ — `props.CellMetrics` +
       `AppSession` 필드 + `refreshCellMetrics` 계산 + `slotAt`/`dragTargetSlot`/`rowTop`(caret·배지) 4곳 alias 교체. (b) **인덱스
       도메인 통일** ✅ — glyph slot을 압축 카드 서수(`active_card_ord`/`close_card_ord`)로 일치(§10 함정). (c) 렌더 y 가변 ✅ —
       tint/accent를 `rowTop`, 스크롤을 `contentHeight`로(#4·#7), 드래그 row→tab 변환(#2). (d) `.m` 디코드 **옵션 2** ✅ —
       `applySidebarGlyphPyTop`이 py_top을 Zig `rowTop`+블록중앙으로 계산해 셀 `origin_y`에 싣고 `.m`은 `origin_y+header-scroll`만
       (code-review #1·3·5·6 해소). (e)(SG3c) `view` 헤더 밴드 `rowTop` + `buildSidebarDrawList` 헤더 삼각(▾/▸)+이름 glyph +
       `card.depth` 들여쓰기 + **헤더 label borrowed 해소**(`group_header`에 소스 tab 인덱스/dupe — 현재 `tab.group_start` borrow해
       destroyTab 후 dangling, **code-review #8 UAF 잠복**). (f)(SG3c) **macOS 제품 스크린샷 검증**(create_group으로 헤더가 실제 떠야 가능).
     **참고: `/code-review max`가 SG3b-2-ii 계획을 findings #1~7의 정확한 해소 경로로 confirmed 검증했고, #1~7은 (a)~(d)에서 전부 닫혔다.**
   - **SG3c ✅ — 접기 + 만들기/이름/해제 + 헤더 실제 렌더(SG3b-2-ii-(e)(f) 흡수)**: `sidebar.view`가 group_header 밴드를
     내고 **모든 밴드 y를 `rowTop` 누적**으로(`bandFill`이 rows+header_row_h 수령, `sidebarBandRow`가 가변 y→row 역산 —
     옛 `@divTrunc(y,slot_h)` 대체). `buildSidebarTitleDrawList`가 헤더 삼각(▾/▸)+이름(접힘 시 `(N)`)+카드 `group_indent`
     들여쓰기를 그리고 `fillSidebarGlyphPyTop`이 row별 높이로 블록중앙(glyph 도메인=표시 row 인덱스). 헤더 클릭 →
     `toggleGroupCollapsedAt`·헤더 더블클릭 rename. `create_group`(`Cmd+Opt+G`)·`ungroup`·`rename_group` 액션
     (action.zig+keybinding+command_catalog+dispatch) → 팔레트·설정 리바인더·config·우클릭 노출. closeTab 마커 승계.
     **code-review #8 해소**: `Row.group_header.tab`(소스 탭 인덱스)로 헤더 glyph가 `tab.group_start`를 **live** 읽어
     borrowed dangling 제거(접기 토글·rename 타깃 겸용). **제품 스크린샷 검증 완료**(펼침 `▾ 그룹 1`+얇은 밴드+들여쓴 활성
     카드·접힘 `▸ 그룹 1 (2)`, 가변 높이 정확 — `MARU_FORCE_GROUP` 헤드리스 훅). **여기까지가 "접기 우선" 완료.**
4. **SG4 ✅ — 카드 드래그 넣기/빼기**: `sidebarGroupDropTargetTab`(드롭 row→moveTab 목표 탭 매핑 단일 출처 —
   카드=그 위치, 펼친 헤더=그룹 최상단(방향 보정), 접힌 헤더=그룹 끝 `[M,j)` §10). 드래그 핸들러가 헤더 드롭도
   처리(옛 visibleTab null-skip 대체), `sidebar_drop_slot` 드롭 하이라이트. **마커 탭 드래그는 가드로 무동작**(그룹
   통째=SG5). 연속 파티션은 마커 없는 카드만 재정렬해 사실상 공짜. 헤드리스 2테스트(넣기/빼기·펼친/접힌 헤더·마커
   가드·재투영 depth). 한계: 핀+그룹 조합·카드→마커카드 위-드롭은 헤더 드롭이 신뢰 경로.
5. **SG5 — 그룹 통째 드래그·색·(선택)중첩**:
   - **SG5-1 ✅ — 그룹 통째 드래그**: 헤더를 잡아 드래그하면 그룹 구간 `[M,j)`(마커 탭 + 소속 카드)가 통째 이동.
     `moveGroupRange`(구간을 블록으로 그룹 경계에만 삽입 — 파티션 위반 불가능)·`sidebarGroupDropBoundary`(드롭 row→그룹
     경계, 항상 경계 clamp)·헤더 클릭 vs 드래그 threshold 구분(mouseDown arm→미달=접기·초과=이동). SG4의 마커 탭 가드를
     실제 이동으로 대체. 헤드리스 3테스트. 한계: 핀+그룹 조합·floating 미리보기(선택) 미구현.
   - **SG5-2 ✅ — 그룹 색**: 헤더·소속 카드 공통 색(브라우저 탭 그룹식). `Tab.group_color`(?u32→u32, 0=색 없음)를
     **그룹 시작 마커 탭 하나에만** 저장하고 소속 카드는 위치 파생으로 그 색을 따른다(별도 저장 없음, §2.1 동형). 나타나는 곳:
     (a) **헤더 밴드 tint** — `lowerSidebar`가 group_header 밴드(.tab_hover_bg) 색에 그룹 색을 **카드 배경 tint와 같은 blend
     경로·같은 알파**로 섞는다(층 분리 — 개별 카드 background_color와 다른 row라 안 겹침). (b) **소속 카드 좌측 accent 막대** —
     `rebuildSidebar` per-tab 루프가 순회 중 위 헤더의 색을 기억해 카드 막대에 싣는다. 막대 색 우선순위 = 개별 `accent_color` >
     그룹 색 > 활성 기본 accent > 없음(개별 지정이 그룹 색보다 명시적). 설정 = 우클릭 "그룹 색: …" 프리셋(카드 색과 같은
     `tab_color_presets` 팔레트·`setGroupColorForTab`이 소속 그룹 마커에 세팅, 그룹 밖이면 no-op). 직렬화 = workspace.v1
     `group-color` 스칼라(비영만 group-start 블록에 쓰고 0=키 생략 — additive·round-trip 고정, 옛 리더 미지 키 skip으로 양쪽 호환).
     헤드리스: projectRows/렌더가 헤더 밴드·카드 막대에 그 색을 싣는지 gpu_quad 단언 + workspace.v1 round-trip + 색 없는 그룹
     기본 폴백. **제품 스크린샷 검증 완료**(`MARU_FORCE_GROUP_COLOR=1` — 헤더 밴드 파란 tint + 소속 카드 파란 막대·최상위 카드 무색).
   - **SG5-3 ✅ — 중첩 그룹(그룹 안 그룹, 폴더 트리)**: 위치 파생을 **다단계 depth로 일반화**한다. `Tab.group_depth: u8`
     (마커에만 의미, 1=최상위·2=중첩·…, 기본 1) 추가. `projectRows`를 **스택 기반 2패스**로 재작성 — pass1이 `self.tabs`를
     스택으로 훑어 각 탭의 **정규화 eff_depth**(마커 pop→`부모+1` gap 클램프, 카드=스택 top)와 검색 매치를 계산하고, pass2가
     마커 스택(접힘 조상 추적)으로 row를 순서대로 방출한다(자식 헤더가 부모 직접 카드 뒤·자식 카드 앞에 자연 삽입 = §2.1
     다단계 제약). 렌더: 카드·헤더 `depth`×/(`depth-1`)×`group_indent` 다단계 들여쓰기(`card.depth`·신규 `group_header.depth`).
     **member_count = 그 그룹 직접 카드 수**(중첩 자식 그룹 안 카드 제외 — 접힘 배지 `(N)`은 "이 그룹에 직접 든 워크스페이스 수").
     - **접기(다단계)**: 마커를 접으면 그 subtree(같거나 낮은 depth 마커 전까지의 깊은 카드·자식 헤더)를 전부 숨긴다. **부모
       접기 = 자식 그룹 통째 숨김**(조상 접힘이 헤더까지 가림), **자식만 접기 = 자식 카드만 숨김**(자식 헤더는 `▸ name (N)`로 남음).
     - **create_group 중첩 생성 + create_sibling_group 형제 생성(명시적 2액션)**: `create_group`은 그룹 **안** 카드에서 실행하면
       그 카드의 현재 depth+1로 자식 그룹 마커(중첩), 최상위에서는 depth 1. 위치 파생상 마커 뒤 형제 카드들은 새 그룹으로 흡수된다.
       첫 그룹이 리스트 끝까지 뻗는 연속 파티션이라 첫 그룹 뒤 카드는 모두 "그룹 안"이므로 create_group은 **항상 중첩**한다 —
       그래서 **`create_sibling_group`**(SG5-3)을 create_group과 **명시적으로 분리**해 둔다: 그 카드의 **현재 그룹과 같은 depth**로
       마커를 얹어(그 카드부터 현재 그룹에서 분할돼 형제로 시작) 형제 그룹을 만든다(최상위 카드면 depth 1 = create_group과 동일).
       둘은 `beginGroupForTab(kind)` 공유 미러이고 depth 계산만 다르다(중첩=현재+1, 형제=현재). 이로써 §10의 "형제 못 만듦"
       tension이 해소된다(중첩/형제를 사용자가 액션으로 명시 선택).
     - **ungroup(중첩)**: 그 탭의 **가장 가까운(innermost) 마커**를 해제한다. 자식 ungroup → 자식 카드가 부모로 재소속(한 단계
       얕아짐). 부모 ungroup → 부모 직접 카드는 최상위로, 남은 자식 그룹은 부모가 사라져 projectRows의 **gap 클램프로 depth 1
       (최상위 그룹)로 자동 승격**(저장 group_depth는 그대로 두고 투영이 정규화 — 위치 파생 철학과 동형).
     - **직렬화**: workspace.v1 `group-depth` 스칼라(additive·기본 1=키 생략→round-trip 고정·옛 리더 미지 키 skip으로 양쪽 호환).
     - **드래그(최소 안전 동작)**: 그룹 통째 이동(`moveGroupRange`)·드롭 경계(`sidebarGroupDropBoundary`)·접힌 헤더 드롭이
       "다음 마커" 대신 **subtree 끝**(`groupSubtreeEnd`=같거나 낮은 depth 마커 전까지)을 쓰게 확장 — 부모+자식이 함께 이동해
       무결성 유지(비중첩이면 "다음 마커"와 동일이라 SG4/SG5-1 동작 보존). **한계**: 완전한 "드래그로 중첩 넣기/빼기"(드롭 위치로
       depth 변경)는 미구현 — 중첩 그룹을 다른 그룹 경계로 끌면 projectRows가 depth를 재정규화해 예기치 않게 재중첩될 수 있다
       (크래시·파티션 손상은 없음 — 삽입이 항상 마커 경계라 연속 파티션 유지). 핀+그룹 조합도 SG4/SG5-1과 같이 범위 밖.
     - **헤드리스 검증**: 2단계 중첩(A>B) depth 0/1/2·헤더 depth·member_count·부모 직접카드가 자식 앞·다단계 접기(부모/자식)·
       ungroup 재소속/승격·workspace.v1 group-depth round-trip. **스크린샷 훅** `MARU_FORCE_GROUP_NESTED`(+`_COLLAPSED`/`_COLOR`).

## 10. 리스크 & 미해결

- **(중) 이주 표면(SG3a)**: `sidebar_visible_tabs` → `sidebar_rows` 격상이 `app_session` 오케스트레이션(조사 맵의 표시-슬롯
  도메인 12+곳)을 건드린다. 동작 보존 리팩터라 **스냅샷 회귀가 안전망**이다 — 착수 전 현재 사이드바 스냅샷을 고정해 두고 이주 후 동일 확인.
- **(높음) 인덱스 도메인 불일치 — SG3b-2-ii의 진짜 핵심 함정(조사 발견)**: glyph 인코딩 slot(`sidebarGlyphRow`)은
  `buildSidebarTitleDrawList`가 헤더를 skip해 만든 **압축 카드 인덱스**인데, 밴드(`bandFill`)·hit-test(`slotAt`)·tint 루프·
  caret·배지는 **row 인덱스**(헤더 포함)다. 헤더 0개인 SG3a까진 둘이 같아 동작 보존이지만, **헤더가 생기는 순간 glyph slot ≠
  밴드/hit-test slot**이 되어 카드 glyph가 헤더 높이만큼 위로 어긋나고, `active_row`/`close_row`(row 인덱스)가 압축 `i`와 비교돼
  활성 강조·✕가 엉뚱한 카드에 간다. → SG3b-2-ii에서 glyph 경로 slot 도메인을 **row 인덱스로 통일**하고 색 디코드(`row/32`)도 동반 수정한다.
- **(높음) 가변 높이 glyph 인코딩(Zig↔`.m` FFI, SG3b-2-ii)**: §5 파급 — `.m`(`maru_metal_renderer.m`)이 `slot_idx*slot_h`
  (glyph)·`sc.row*slot_h`(밴드)·블록중앙 `(slot_h-block_h)/2`로 균일을 가정한다. **결정: 옵션 2** — py_top을 Zig에서 `rowTop`+
  블록중앙으로 완전 계산해 per-cell로 넘겨 `.m` 기하를 없앤다(옵션 1의 per-row 누적/높이 배열 FFI보다, 정합 단일 출처가 Zig
  한 곳으로 모여 회귀 표면이 작다 — caret·배지·색 디코드가 같은 수식 공유). 부수: `bandFill`이 누적 y를 emit하면 `lowerSidebar`의
  `@divTrunc(rect.y, slot_h)` row 역산이 비가역이 되므로, chrome op에 row 인덱스를 실어 넘긴다. 세로 위치는 headless로 안 잡혀 **macOS 스크린샷 검증 필수**.
- **(낮) 위치 파생의 경계 제약**: 최상위 카드는 첫 그룹 시작 이전 구간에만 온다(§2.1) — 그룹들 사이에 최상위 카드를 끼울 수
  없다. 브라우저 탭 그룹도 사실상 이 모델이라 실용상 충분. 정말 필요하면 후속에서 "그룹 끝" sentinel 마커로 열 여지만 둔다.
- **(해소됨, SG5-3 핵심 판단) create_group vs create_sibling_group — 중첩/형제를 명시적 2액션으로 분리**: §2.1 연속
  파티션상 첫 그룹은 리스트 끝까지 뻗으므로 첫 그룹 뒤의 모든 카드는 "그룹 안"이다. create_group은 "그룹 안 카드 → depth+1
  중첩"(§9)이라, 그것만으론 첫 그룹 뒤에 **형제 최상위 그룹을 못 만든다**(flat 모델(SG1~5-2)에선 create_group이 항상 depth 1이라
  형제가 됐다 — 여기서 동작이 바뀐다). 이는 "소속을 위치에서 파생"이 다단계로 갈 때 **의미가 겹치는 지점**(같은 카드에 대해
  "부모를 세분(중첩)"과 "부모를 쪼개 형제 시작"이 둘 다 타당)이다. **해소**: `create_sibling_group`(같은 depth 마커) 액션을
  create_group(depth+1 중첩)과 **명시적으로 분리**해 사용자가 중첩/형제를 골라 만든다(우클릭 "형제 그룹으로 분리"·`Cmd+Opt+Shift+G`·
  팔레트 "New Sibling Group"·config). 두 세션 메서드는 `beginGroupForTab(kind)` 공유이고 depth 계산만 다르다(중첩=현재+1·형제=현재,
  최상위 카드는 둘 다 1로 동일). 기존 SG5-1 헤드리스 테스트(형제 그룹 통째 드래그 검증)는 setup에서 `group_depth=1`을 명시해
  형제로 구성하도록만 조정했다(드래그 assertion·기능 불변 — 회귀 아님; 이제 `createSiblingGroupForTab`으로도 같은 형제 구성 가능).
- **(낮, SG5-3) 드래그로 중첩 넣기/빼기 미구현**: 그룹 통째 드래그는 subtree를 함께 옮기지만(무결성), 드롭 위치로 depth를
  바꾸는 완전한 재중첩은 미구현 — 중첩 그룹을 다른 그룹 경계로 끌면 projectRows가 depth를 재정규화해 예기치 않게 재중첩될
  수 있다(크래시·파티션 손상 없음 — 삽입이 항상 마커 경계). 카드 드래그(SG4)는 드롭 위치의 depth를 위치 파생으로 자연 흡수한다.
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
