# 사이드바 그룹(접이식 워크스페이스 묶음) 전략

이 문서는 왼쪽 세로 사이드바의 **워크스페이스 그룹**(폴더처럼 묶어 접고 펴기)의 단일 출처다. 목표 UX,
근본 모델 재설계(왜 slot=card 가정을 걷어내는가), 데이터·직렬화·인터랙션·단계 분해·검증·리스크를 정한다.

사이드바 자체(카드 레이아웃·헤더·검색·드래그·스크롤)의 단일 출처는 [탭·split·레이아웃 전략](tabs-splits-layout.md)이고,
chrome 컴포넌트 경계는 [Chrome 전략](chrome-strategy.md) §5.4/§5.5다. 이 문서는 그 위에 **그룹**을 얹는 설계만 다룬다.

> 어느 슬라이스까지 구현됐는지는 [단계 분해](plans/sidebar-groups.md)가 소유한다 — 이 문서는 계약만 현재형으로 적는다.

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
  **헤더 표시도 검색을 따른다** — 검색 중 강제로 펼친 카드 위에 접힘 표시(▸·(N) 배지)가 뜨면 모순이라, projectRows가
  검색 활성 동안 헤더 row를 `collapsed=false`(▾, 배지 없음)로 낸다(저장 `group_collapsed`은 불변 — 검색 종료 시 복귀).

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
- **불변식(연속 파티션)**: 그룹은 다음 그룹 시작 마커 전까지 이어진다. 초안 모델에선 최상위 카드가 **첫 그룹 시작 이전
  구간에만** 왔다(한 번 그룹이 시작되면 리스트 끝까지 그룹 안 — 중간 최상위 복귀 없음). pinned의 `[고정][비고정]`
  파티션(session_model.zig:192, `moveTab` — app_session/tab.zig:795)을 N-구간으로 일반화한 것이다. **§2.1 재설계(§14, SR1~5 완료)로 이 "중간 복귀
  없음"을 서브파티션으로 일반화**했다: 리딩 break 플래그 `Tab.top_level`이 한 핀 리전 **안**을 `[탑카드, 그룹, 탑카드, 그룹]`
  처럼 나눠, **그룹 뒤/사이에도 최상위 카드가 온다**(마커=push·top_level=pop-all·최상위 복귀). 계층은 **pin ⊃ subregion(top_level)
  ⊃ group ⊃ nest**. 그래도 "한 번 최상위로 나가면 재진입은 **새 마커로만**"은 유지(top_level은 depth를 항상 0으로만 되돌리므로
  중간에서 "부모 depth로 복귀"는 못 한다 — §14.7). "선택 탭만 그룹"(createGroup은 마커 뒤 첫 비선택 탭에 top_level write) ·
  드래그·메뉴로 그룹과 최상위 카드를 인터리빙한다(요구1·요구2 — §14 단일 출처). **고정 정책(§14.9 — "고정된 건 어디에도
  흡수 안 됨")**: pin이 최외곽 리전이라, **고정 탭은 top_level이 강제**돼 어느 그룹에도 흡수되지 않고(위치 무관), **고정
  그룹은 다른 그룹의 자식으로 nest 금지**(sibling만)이며, 둘 다 **고정 리전 `[0, pinned_count)`로 clamp**돼 비고정 영역과
  섞이지 않는다. **기존 mutation/render 경로도 이 top_level 경계를 유지**해야 한다(inherit·removal·normalize·guard·run_hi·
  accent — code-review PR#1197, §14.8): §2.1 재설계의 숨은 요구다.
- **새 워크스페이스 삽입점(끝 append 금지)**: 위 불변식의 직접 귀결로, **새 탭을 리스트 끝에 append하면 그룹이 하나라도
  있을 때 마지막 그룹의 멤버로 흡수**된다(사용자엔 "새 워크스페이스가 그룹에 빨려들어감" — 그 카드 우클릭 pin은
  `cardPinRole=.local`로 그룹 안 float까지 된다). 그래서 새 워크스페이스는 **비고정 리전의 첫 그룹 마커 직전**
  (`firstGroupStartInRegion(pinned_count, len)`)에 끼워 항상 최상위로 뜬다 — `promotePaneToNewWorkspace`와 `createTab`
  (Cmd+T·사이드바 +)이 이 단일 삽입점을 공유한다(그룹 전무면 끝 = byte-identical).
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

§2.1 위치 파생이라 새 타입이 필요 없다. `Tab`(session_model.zig)에 **additive 스칼라 2개**만 얹는다.

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
/// **이 union은 그룹만의 것이 아니다** — `agent_toggle`·`agent` row는
/// [사이드바 에이전트 목록](sidebar-agent-list.md)이 소유하며, 여기서는 그룹이 쓰는 둘만 적는다.
pub const Row = union(enum) {
    card: struct {
        tab: usize,          // 원본 self.tabs 인덱스(visibleTab의 일반화)
        label: []const u8,
        active: bool,
        depth: u8 = 0,       // 0=최상위, 1=그룹 안(들여쓰기 = depth * tokens.space.group_indent_px)
        pin_derived: bool = false,   // 그룹째 고정에서 파생된 멤버 — 카드 📌를 억제한다(§12.8)
        local_pinned: bool = false,  // 그룹-로컬 pin(§13.6) — 선두 분기가 이 값으로 📌를 낸다
        lines: u8 = 1,       // 카드가 쓰는 줄 수(이름·브랜치·경로·상태). 높이가 여기서 파생된다
    },
    group_header: struct {
        collapsed: bool,
        label: []const u8,   // 레거시(이제 tab에서 live 읽어 load-bearing 아님)
        member_count: u16,   // 접힘 시 "▸ name (N)" 표시용 — 이 그룹 **직접 카드 수**(중첩 자식 그룹 안 카드는 제외, SG5-3)
        tab: usize,          // 소스 group-start 탭 인덱스 — 헤더 glyph가 self.tabs[tab].group_start를 **live** 읽어(borrowed UAF #8 해소), 접기 토글·rename 타깃 겸용
        depth: u8 = 0,       // 정규화 중첩 깊이(SG5-3, 1=최상위·2=중첩·…). 헤더 삼각/이름 glyph를 (depth-1)*group_indent 들여씀(카드는 depth*group_indent). 밴드(view)는 depth 무관 전폭
        has_color: bool = false, // 그룹 색(SG5-2)이 지정됐는가 — **헤더 밴드를 낼지의 유일 스위치**(아래 헤더 밴드 정책). host가 tab.group_color!=0로 채운다
    },
    // agent_toggle · agent — sidebar-agent-list.md 소유
};

/// 높이 값은 **낱개로 나르지 않고 `Metrics` 하나로 묶는다.** row 종류마다 쓰는 값이 다르고(카드는
/// 줄 수 × 줄 간격 + 여백, 헤더는 고정 한 줄), 호출부가 늘 때마다 인자가 불어나기 때문이다.
/// 카드 높이는 `card.lines`에서 파생되므로 "카드 슬롯 높이"라는 단일 상수는 없다.
pub const Metrics = struct {
    line_h: u32,        // 한 줄(글자) 높이 = cell 높이
    line_step: u32,     // 줄과 줄 사이 세로 스텝(line_h + 여유)
    card_pad_v: u32,    // 카드 위/아래 **각각**의 여백
    header_row_h: u32,  // 그룹 헤더 row 높이(얇은 한 줄 — 카드 줄 수와 무관한 별도 값)
    content_pad_v: u32, // 목록 **전체**의 위/아래 여백
    list_pad_v: u32,    // 에이전트 목록 행의 위/아래 여백(카드보다 촘촘)

    pub fn init(cell_height_px: u32, header_row_h: u32) Metrics;
};

// hit-test: **가변 row 높이**(카드=줄 수에서 파생, 헤더=header_row_h). y↔row를 고정 나눗셈이 아니라
// rows를 순회하며 각 row 높이를 누적해 환산한다(순수 함수 — headless 테스트 가능).
pub fn rowHeight(row: Row, m: Metrics) u32;
pub fn slotAt(y_px: f64, header_height_px: u32, rows: []const Row, m: Metrics, scroll_offset_px: u32) ?usize;
pub fn rowTop(rows: []const Row, index: usize, header_height_px: u32, m: Metrics, scroll_offset_px: u32) i64; // 옛 slotTop의 누적판
pub fn contentHeight(rows: []const Row, m: Metrics) u32; // 스크롤 clamp용(옛 rows.len*slot_h)
pub fn dragTargetSlot(y_px: f64, header_height_px: u32, rows: []const Row, m: Metrics, scroll_offset_px: u32) usize;

// view: rows를 순회하며 header row엔 헤더 밴드+삼각(▾/▸), card row엔 기존 카드 밴드(depth 들여쓰기).
pub fn view(rows: []const Row, hovered_slot: ?usize, drop_slot: ?usize, p: props.ChromeProps, arena, out) !void;

// 그룹 헤더 hit — 헤더 row 전체가 접기 토글 클릭 영역(closeButton과 같은 결의 순수 함수).
pub fn onGroupHeader(rows: []const Row, row_index: usize) bool;
```

**핵심(§5.4 레이아웃 단일 소스 유지) — 가변 row 높이(사용자 결정)**: row는 종류별로 높이가 다르다 — **카드는
`card.lines`에서 파생**(줄 수 × `line_step` + 위아래 `card_pad_v`, 이름·브랜치·경로·상태), **그룹 헤더=`header_row_h`**
(≈cell 1줄, 촘촘하게). hit-test(`slotAt`/`rowTop`)는 고정 나눗셈 대신 **rows를 순회하며 각 row 높이를 누적**해
y↔row를 환산한다(여전히 순수 함수라 headless
테스트 가능). view도 **같은 누적 레이아웃 함수**(`rowTop`)로 밴드 y를 내야 정합이 유지된다(§5.4 — view와 hit-test가
한 레이아웃 소스 공유). **베이스/결정**: 브라우저 탭 그룹·VSCode 폴더가 헤더를 얇은 한 줄로 둬 촘촘한 게 접이식 그룹의
핵심 가치라, 균일 격자(구현 단순)보다 **가변 높이(시각 우선)**를 택했다.

**pane grip 드롭이 헤더 row에 떨어질 때(code-review #3 — 결정·문서화)**: pane grip 드래그의 드롭 판정(`computePaneDropDest`)은
카드 위=그 워크스페이스에 **merge**, 리스트 아래 빈 영역=**새 워크스페이스**다. **그룹 헤더 row는 워크스페이스가 아니라 묶음**이라
"어느 워크스페이스에 merge"가 정의되지 않고 새 워크스페이스도 아니므로, **헤더 드롭 = no-op**(무동작)로 둔다(상단 검색 헤더 드롭이
no-op인 것과 같은 결). 옛 코드는 헤더 slot에서 `visibleTab=null`이라 `.new_workspace`로 falls through해 헤더에 떨궈도 원치 않는 새
워크스페이스가 생겼다 — `visibleTab(slot) orelse return null`로 헤더를 걸러 최소 안전 동작을 택했다. (past-end=리스트 아래 빈
영역은 `sidebarSlotAt`이 null이라 이 가드를 건너뛰어 자연스러운 "빈 영역=새 워크스페이스"를 유지한다.)

**헤더 밴드 정책(사용자 결정 — 기본 보더라인 제거, 색·상호작용은 유지)**: 그룹 헤더는 **기본(무색) 상태에서 밴드(전폭
회색 배경 = 보더라인)를 그리지 않는다** — 삼각(▾/▸)+이름 텍스트만 배경 없는 줄로 남긴다("보더라인 굳이 필요 없다, 화살표만
있어도 직관적"). `view`의 헤더 밴드 루프는 **`group_header.has_color`일 때만** 헤더 밴드(`.tab_hover_bg`)를 내고, `lowerSidebar`가
그 밴드 색에 `tab.group_color`를 tint한다(SG5-2 색 구분은 그대로 유지 — 색 있는 그룹만 밴드가 보이고 그 색을 띤다). `has_color`는
host(projectRows)가 `tab.group_color!=0`로 채운다(chrome은 role 기반이라 RGB를 못 실어 "밴드를 낼지"만 판단, 실제 blend는 platform).
**단 hover·active 밴드는 has_color와 무관하게 그대로** — 그건 보더라인이 아니라 **상호작용 피드백**이라 카드와 **같은 경로**로
유지한다(hover=`hovered_slot`이 헤더 row를 가리키면 view의 호버 루프가 밴드를 낸다; 헤더 row는 활성 탭이 될 수 없어 active 밴드는
카드 전용). **호버 role 분기(code-review #4)**: 무색 헤더·카드는 `bandFill(.tab_hover_bg)`(카드와 동일). 하지만 **색 지정
헤더**는 이미 위 has_color 밴드가 `.tab_hover_bg`(+그룹색 tint)를 깔아, 같은 role 호버 밴드를 겹치면 byte-identical이라 호버가
안 보인다 → 색 헤더 호버는 한 단계 밝은 **`.tab_active_bg`로 오버레이**해(lowerSidebar가 같은 그룹색을 tint하되 더 밝은 base)
카드처럼 시각 변화가 나게 한다. 정리: **무색·비호버=밴드 없음(화살표+이름만), 색 지정=그 색 밴드, hover=카드와 같은 하이라이트
(색 헤더는 밝은 role로 색 위 오버레이).** (헤드리스로 무색·비호버 헤더=밴드 op 0, 색 헤더=밴드 op 1, 무색 호버 헤더=호버 밴드
op 있음, **색 호버 헤더=색 밴드(.tab_hover_bg)와 다른 role(.tab_active_bg) 밴드가 겹침**을 단언; 색 유지는 `MARU_FORCE_GROUP`
(무색: 밴드 없는 깔끔한 헤더)·`MARU_FORCE_GROUP_COLOR`(파랑 밴드 tint 유지) 제품 스크린샷으로 확인.)

**메트릭 출처**: 높이 값은 `Metrics.init(cell_height_px, header_row_h)`가 cell 높이에서 파생한다 — 줄 스텝은
`cell_height_px + max(1, 15%)`, 카드 여백·목록 여백도 같은 cell 높이의 비율이다. `header_row_h`만 platform이 따로
넘긴다(헤더는 카드 줄 수와 무관한 얇은 한 줄이라 파생 대상이 아니다). `group_indent_px`(card.depth 들여쓰기 폭)는
spacing 토큰(`tokens.space`)이고 rich에서 ≈1ch다. **낱개 상수를 여기저기 두지 않고 `Metrics` 하나가 나르는 것이
핵심**이다 — hit-test와 view가 같은 값을 봐야 "보이는 곳 = 눌리는 곳"이 유지된다(§5.4 레이아웃 단일 소스).

**파급 — glyph 세로 위치 인코딩(§10 리스크)**: 현재 `coretext_frame_builder.sidebarGlyphRow`의 `slot*32` 인코딩은 `.m`
렌더러가 `slot*slot_h`로 디코드해 **균일 높이를 가정**한다(단일 출처). 가변 높이면 이 곱셈이 깨지므로 SG3에서 `.m`이
row별 누적 y(또는 각 row 높이/누적 오프셋 배열)를 받도록 인코딩·디코드를 함께 고쳐야 한다 — 이게 가변 높이의 실제
비용이다(hit-test는 Zig 순수라 누적이 쉽지만, glyph는 Zig↔`.m` FFI 경계라 양쪽을 맞춰야 함). 세로 스크롤 클리핑도
같은 누적 y를 쓴다. 헤더 glyph(삼각+이름)는 카드 제목과 같은 `buildSidebarDrawList` 경로에 row 종류만 분기한다.

**밴드 셀도 같은 옵션2로(code-review #7·#8)**: 위 glyph 옵션2(`.m`이 Zig가 실은 `origin_y`만 씀)를 **tui 셀 밴드**(`slot_id==0`
sentinel)에도 적용한다 — 옛 밴드 분기는 `sc.row*slot_h`·높이 `slot_h`로 균일을 가정해, 그룹 헤더(header_row_h<slot_h)가 앞서면
밴드가 격자에서 어긋났다. 이제 `sidebarBandCell`이 chrome이 준 content-상대 rowTop(`q.rect.y`)을 `origin_y`로, 실제 row 높이
(`q.rect.h` — 카드=slot_h·색 헤더=header_row_h)를 `atlas_height_px`(sentinel이라 미사용 필드 재활용)로 실어 주고, `.m`은
`origin_y+header−scroll`·그 높이로 그린다(glyph와 단일 스크롤 소스). 또 **리스트 아래 새-워크스페이스 드롭 하이라이트**(drop_slot
==rows.len)는 bandFill이 `q.rect.y=contentHeight`로 내므로, 옛 `sidebarBandRow(y) orelse continue`(past-end null)가 삼키던 셀을
이제 `q.rect.y`를 직접 origin_y로 써서 방출한다(#8). tui 밴드 정합은 `MARU_FORCE_GROUP_COLOR` + `chrome.theme=tui` 스크린샷으로
확인(색 헤더 밴드=얇은 header_row_h·카드 밴드=slot_h가 각자 텍스트와 정렬).

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

| 동작 | UX | 구현 경로(베이스) |
|---|---|---|
| **그룹 접기/펴기** | 헤더 줄 클릭(삼각 ▾/▸) | `onGroupHeader` → 그 그룹 시작 탭의 `group_collapsed` 토글 → `projectRows` 재투영 + 영속(§4) |
| **그룹 만들기(중첩)** | 우클릭 "새 그룹으로 묶기" · **단축키 `Cmd+Opt+G`** · 팔레트 "New Group" | `create_group` 액션 → 활성/클릭 탭에 `group_start` 세팅. **그룹 안 카드면 depth+1 중첩**(§9), 최상위면 depth 1. 아래 연속 카드가 자동 소속(위치 파생) |
| **형제 그룹으로 분리** | 우클릭 "형제 그룹으로 분리" · **단축키 `Cmd+Opt+Shift+G`** · 팔레트 "New Sibling Group" | `create_sibling_group` 액션 → 그 카드에 `group_start` 세팅 + `group_depth=현재 그룹과 같은 depth`(형제, 중첩 아님). 최상위면 depth 1(create_group과 결과 동일). create_group의 미러 — depth 계산만 다르다(§10 tension 해소) |
| **그룹 이름 바꾸기** | 헤더 더블클릭 · **헤더 우클릭 "Rename"**(SG5-2-header) | rename 인라인 편집(`OverlayInput`) — 워크스페이스 rename과 동형(tabs-splits-layout.md rename). 헤더 우클릭 메뉴의 "Rename"도 같은 `startRename(.group)`(대상=group_start 마커)이라 더블클릭과 동일 |
| **그룹 해제** | 카드 우클릭 "그룹 풀기" · **헤더 우클릭 "그룹 풀기"**(SG5-2-header) · 팔레트 "Ungroup"(기본 키 없음) | `ungroup` 액션 → 그 탭의 `group_start=null`(마커 제거) → 아래 카드는 위 마커/최상위로 자동 재소속. 헤더 우클릭은 대상이 그 헤더의 마커 탭이라 `enclosingGroupMarkerIndex`가 자기 자신을 찾아 카드 경로와 동일 결과 |
| **그룹에서 빼기** | 우클릭 "그룹에서 빼기"(**그룹 소속 카드에만** 노출·최상위 카드엔 안 보임) · 팔레트 "Remove from Group"(기본 키 없음) | `remove_from_group` 액션 → `removeFromGroupForTab`: 그 카드를 **첫 `group_start` 마커 직전**(§2.1 최상위 구간)으로 `moveTab`(중첩 깊이 무관 완전 최상위). ungroup(그룹 통째 해제)과 달리 **이 카드 하나만** 뺀다 — 그룹은 유지(마커 카드면 다음 소속 카드로 마커 **승계** = closeTab과 동형, 마지막 멤버면 그룹 소멸). 이미 최상위면 no-op. 주입 조건 = `tabIsInGroup`(첫 마커 이후 = 그룹 안). 위치 파생이라 별도 소속 편집 없음 |
| **카드 드래그로 넣기/빼기** | 카드를 마커 위/아래·헤더로 드래그(중첩 자식 그룹 안 포함) | `sidebarGroupDropTargetTab`(드롭 row→목표 탭 매핑) + `sidebar_drop_slot` 하이라이트. 위치 파생이라 별도 소속 편집 없음 — 드롭 위치의 depth가 곧 카드 depth(자식 그룹 안=자식 depth·최상위=0). 마커 탭 드래그=그룹 통째=SG5 |
| **그룹 통째 드래그** | 헤더 잡아 드래그(클릭=접기와 threshold 구분) | `moveGroupRange`(구간 블록 이동)·`sidebarGroupDropBoundary`(경계 clamp)·`sidebar_group_drag_*` |
| **드래그로 중첩 넣기/빼기** | **`Cmd(⌘)` 누른 채** 그룹 헤더를 다른 그룹 헤더에 드롭=자식으로 **중첩**. **`Cmd` 없이는 항상 형제**(헤더 드롭이라도 단순 위치 변경, 중첩 절대 안 됨). 카드/최상위 드롭=형제 재정렬(+얕으면 빼기) | `groupDragPreviewFrame(cmd_held)`가 게이트: `cmd_held`면 헤더 드롭 시 `groupNestPlan`(target_depth=타겟 depth+1·insert=타겟 subtree 끝)→`moveGroupNesting`, 아니면 nest 미시도(`sidebarGroupDropBoundary`→`moveGroupSibling`, 형제/빼기). 카드 드롭은 Cmd 유무 무관 형제(N4 폴백). **modifier 전달**: Swift `modsBits`가 command=32 추가, 터미널 리포트 경로(`mouse`/`mouseMoved`)는 `mods & ~32`로 마스킹(SGR motion 비트 32 충돌 회피). 고스트 피드백: nest=타깃 그룹 하이라이트+들여쓴 고스트, sibling=삽입선만 |
| 그룹 색 | **카드 우클릭 "그룹 색: …"** 프리셋(카드 색과 같은 팔레트) · **헤더 우클릭 "그룹 색: …"**(SG5-2-header, 같은 라벨·팔레트·`setGroupColorForTab` 재사용) / 헤더 밴드 tint·소속 카드 막대 | `group_start` 탭에 `group_color` 저장(마커 하나에만, 소속 카드는 위치 파생). 헤더 밴드=lowerSidebar 블렌드(카드 배경 tint와 같은 경로)·소속 카드 막대=per-tab accent 루프(개별 accent>그룹 색>기본). workspace.v1 `group-color`(0=키 생략). 헤더/카드가 같은 색 메뉴를 공유해 사용자가 헤더에서도 색을 찾는다(피드백 반영) |

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
  검색 매치 0=헤더째 사라짐). 가변 높이 hit-test(`slotAt`/`rowTop`/`contentHeight`)를 **헤더 섞인 row 배열 + 카드 줄 수가
  서로 다른 `Metrics`**로 확장해 **누적 y ↔ row** 정합을 단언(카드가 모두 같은 줄 수면 누적=균일이라 동작 보존도 같은 테스트로).
- **직렬화 round-trip**: `group-start`·`group-collapsed`가 serialize→parse→serialize 고정점(workspace.zig 기존 테스트 확장).
  하위호환: 두 키 없는 옛 파일이 flat으로 정상 복원(기존 "key-addressed 하위호환" 테스트 확장).
- **E2E/스냅샷**: 접힌/펼친 사이드바 셀 스냅샷. 헤더 glyph(삼각+이름)·들여쓰기는 macOS 제품 스크린샷으로 고정
  ([검증 매트릭스](verification-matrix.md): macOS 렌더 변경은 직접 검증).
- **게이트**: `check-boundaries`(chrome는 session/platform 모름 — Row는 chrome 중립 타입)·coretext/metal/app 스모크.

## 계약 문서 구성

사이드바 그룹 계약은 아래 문서가 나눠 소유한다. **절 번호는 파일을 넘어 이어진다** — 다른 문서와
코드 주석이 `sidebar-groups.md §12.5`처럼 절 번호로 가리키므로 재번호하지 않는다.

| 절 | 문서 | 소유 |
|---|---|---|
| §1~§8 · §10 · §11 | 이 문서 | 목표 UX, 핵심 결정(위치 파생·Row 승격), 데이터 모델, 직렬화, chrome 계약, platform 오케스트레이션, 인터랙션, 검증, 리스크, clean-room |
| §9 | [단계 분해](plans/sidebar-groups.md) | SG1~SG8 단계와 완료 이력 |
| §12~§13 | [그룹 고정과 로컬 pin](sidebar-groups-pinning.md) | 그룹 통째 고정(C2)·멤버 그룹-로컬 pin(GL) |
| §14 | [top_level 재설계](sidebar-groups-top-level.md) | 고정 탭↔그룹 인터리빙, 선택 탭만 그룹 |

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
- **(해소됨, §14 §2.1 재설계 SR1~5 완료) 위치 파생의 경계 제약**: 초안에선 최상위 카드가 첫 그룹 시작 이전 구간에만 와
  그룹들 **사이에 최상위 카드를 끼울 수 없었다**. 이 제약을 리딩 break 플래그 `Tab.top_level`로 열었다(초안이 남겨둔 "그룹 끝
  sentinel"의 최종 형태 = 트레일링 `group_end`가 아니라 리딩 `top_level`, 드래그 orphan 회피 — §14.1 옵션 B). "선택 탭만 그룹"
  (createGroup)·드래그(model-2 `sidebarCardDropAfterGroup` "그룹 뒤 빈 gap" 착지 포함)·메뉴(promote-in-place)로 `[탑카드, 그룹,
  탑카드, 그룹]` 인터리빙이 성립한다. 단 top_level은 depth를 항상 0으로만 되돌려 **중첩 안 "부모 depth 복귀"는 여전히 불가**
  (그룹 뒤 카드는 depth 0 최상위로만 복귀 — §14.7 제약). **고정 정책(§14.9 — 사용자 규칙 "고정된 건 어디에도 흡수 안 됨")**:
  고정 탭은 top_level 강제(cardDropPlan/simulateDrop/commit 3레이어 OR — 그룹 흡수 금지)·고정 그룹은 nest 금지(groupNestPlan
  마커 pinned→null, sibling만)·둘 다 고정 리전 [0, pinned_count) clamp. **기존 경로의 경계 유지(code-review PR#1197, §14.8)**:
  inheritGroupMarker `!next.top_level`·top_level 카드 제거(closeTab·드래그 commit) 시 경계 재확립·normalize suffix-exclusion
  (pin flip 존중)·removeFromGroupForTab `!tabIsInGroup` 가드·sidebarGroupDropBoundary run_hi `!top_level`·accent
  current_group_color top_level 리셋. **설계·단계·정정된 자기진단은 §14를 단일 출처로 둔다**(SR1 저장·파생 토대·SR2 C2 정합·
  SR3 createGroup·SR4 model-2 드래그·SR5 빈 gap 제스처·3축 공존·§14.8 경계 유지·§14.9 고정 정책·문서 완결).
- **(해소됨, SG5-3 핵심 판단) create_group vs create_sibling_group — 중첩/형제를 명시적 2액션으로 분리**: §2.1 연속
  파티션상 첫 그룹은 리스트 끝까지 뻗으므로 첫 그룹 뒤의 모든 카드는 "그룹 안"이다. create_group은 "그룹 안 카드 → depth+1
  중첩"(§9)이라, 그것만으론 첫 그룹 뒤에 **형제 최상위 그룹을 못 만든다**(flat 모델(SG1~5-2)에선 create_group이 항상 depth 1이라
  형제가 됐다 — 여기서 동작이 바뀐다). 이는 "소속을 위치에서 파생"이 다단계로 갈 때 **의미가 겹치는 지점**(같은 카드에 대해
  "부모를 세분(중첩)"과 "부모를 쪼개 형제 시작"이 둘 다 타당)이다. **해소**: `create_sibling_group`(같은 depth 마커) 액션을
  create_group(depth+1 중첩)과 **명시적으로 분리**해 사용자가 중첩/형제를 골라 만든다(우클릭 "형제 그룹으로 분리"·`Cmd+Opt+Shift+G`·
  팔레트 "New Sibling Group"·config). 두 세션 메서드는 `beginGroupForTab(kind)` 공유이고 depth 계산만 다르다(중첩=현재+1·형제=현재,
  최상위 카드는 둘 다 1로 동일). 기존 SG5-1 헤드리스 테스트(형제 그룹 통째 드래그 검증)는 setup에서 `group_depth=1`을 명시해
  형제로 구성하도록만 조정했다(드래그 assertion·기능 불변 — 회귀 아님; 이제 `createSiblingGroupForTab`으로도 같은 형제 구성 가능).
- **(해소됨, SG5-4) 드래그로 중첩 넣기/빼기**: 이제 그룹 드래그의 **드롭 컨텍스트 depth**로 명시 넣기/빼기를 한다 — 다른 그룹
  **헤더에 드롭=자식으로 중첩**(depth+1, `moveGroupNesting`+`relevelBlock`으로 subtree 상대 depth 유지), **카드/최상위에 드롭=형제
  이동+빼기**(`moveGroupSibling`이 자연 eff로 relevel). **택한 규칙(모호성 해소·문서화)**: 그룹 드래그는 y-only라 "형제 재정렬"과
  "자식으로 넣기"가 같은 드롭 y에서 겹칠 수 있어, **헤더 드롭=넣기·카드 드롭=형제**로 분리했다(폴더 라벨에 떨구면 안에·본문에
  떨구면 옆). 이 규칙이 SG5-1 헤드리스(모두 카드에 드롭)를 그대로 통과시키면서 넣기 제스처를 새로 연다. **남은 한계**: (a) **새
  중첩 레벨을 카드 드롭으로는 못 만든다**(카드 드롭은 형제 전용 — 넣기는 헤더 드롭이 유일 경로). (b) 넣기 시 목표 depth **live
  들여쓰기 프리뷰 미구현**(드롭 row 헤더 밴드 하이라이트로만 "이 그룹 안"을 표시, 드롭 후 재투영으로 확정). (c) 핀+그룹 조합은
  당시 SG4/SG5-1과 같이 범위 밖이었으나 **이후 C2(§12, GP1~5)로 해소** — 그룹 드래그 plan이 리전에 clamp되고(§12.6) 넣기는
  같은 pin 그룹만 허용된다(C3 재발 방지). 카드 드래그(SG4)는 드롭 위치의 depth를 위치 파생으로 자연 흡수한다(자식 그룹 안=자식 depth).
- **(낮) 접힌 그룹에 넣기**: 카드 드래그(SG4)에서 접힌 헤더에 드롭하면 그 그룹 끝에 추가로 처리(브라우저 관례). 접기 우선
  단계(SG1~3)에는 드래그가 없어 무관.
- **(낮) 접힘 상태 위치**: `group_collapsed`를 workspace.v1에 둔다(세션 넘어 유지). config가 아니라 workspace인 이유 — 그룹은
  per-워크스페이스-파일 구조이지 전역 설정이 아니다.
- **(낮) group_start 앵커 수명**: 그룹 시작 탭이 닫히면(closeTab) 그 `group_start` 마커를 **다음 탭으로 승계**해야 그룹이
  사라지지 않는다(그룹의 첫 카드를 닫아도 나머지가 그룹에 남게). 마지막 카드까지 닫히면 그룹 소멸 — SG3에서 closeTab 경로에 처리.
- **(해소됨, §9-8 SG8 완료) 사이드바 드래그 프리뷰 방식 — 라이브 재배치 → 고스트+삽입선으로 전환 완료**: 옛 사이드바 드래그는
  **라이브 재배치**(드래그 중 실제 `moveTab`/`moveGroupRange`로 카드가 실시간 이동)라 순서는 이미 "프리뷰"가 됐지만, **접힌 그룹
  드롭 시 카드가 순간 사라짐**·헤더 통과 시 그룹이 들락날락하는 **yo-yo**가 남았다. **SG7(작게)은 폐기**(§9-7)됐고, 대신 드래그를
  **고스트+삽입선**(원본 유지·비커밋 프리뷰·드롭 1회 확정)으로 통일하는 SG8을 **SG8a~f로 완결**했다 — 드래그 내내 `self.tabs`가
  불변(hit-test·plan 계산은 원본 `sidebar_rows`, 렌더만 고스트 포함 `sidebar_preview_rows`를 봄)이라 **접힌 그룹 드롭 카드 사라짐·
  헤더 통과 yo-yo가 근본 해결**되고, 순서·depth 프리뷰가 한 시스템(subtree 고스트 들여쓰기)으로 모였다. 이중경로 divergence는
  **순열/depth 순수 코어 단일화**(SG8a `projectRowsFrom`·SG8b `simulateDrop`)+헤드리스 등가 테스트로 방어하고, 확정은 마지막
  프리뷰 plan을 `moveTab`/`moveGroupSibling`/`moveGroupNesting` **정확히 1회** 재사용(재계산 금지)한다. SG8f에서 옛 라이브 경로
  잔재(`groupDragFrame`의 매 프레임 앵커 팔로우·write-only-null `sidebar_drop_slot`)를 청소했다. **남은 것**: cosmetic(하이라이트
  밴드 높이 등)·별도 축 후속(아래 "그룹 고정")뿐.
- **(해소됨, C2 완료 — §12) 그룹 고정 — 핀+그룹 조합의 파티션 무결성**: 현재 pin(`[고정][비고정]`)과 그룹은 각자 파티션이라, 그룹이
  고정/비고정 경계를 가로지르면 고정 프리픽스 불변식을 보장하지 않았다(SG4/SG5-1/SG8 모두 범위 밖). SG8의 `clampMoveToGroup`은
  **드롭 목표를 핀 경계로 정직하게 클램프**(프리뷰-확정 일치)까지만 했다. 이 별도 축을 **C2(핀-리전 인식 파생)**로 설계 확정하고
  단계 **GP1~5로 완결**했다 — 그룹 마커 `pinned`를 그룹 고정 권위로 실어 리스트를 `[고정][비고정]` 2리전으로 나누고 각 리전 안에서
  §2.1가 다시 성립하게 한다(고정 그룹 0개면 byte-identical). **설계 확정본·단계·정정된 자기진단은 §12를 단일 출처로 둔다**(GP1~5 완료:
  파생 코어 pin-region 인식·suffix-exclusion 정규화·`toggleGroupPin`+plan clamp·`pin_derived` 렌더·헤더 인디케이터·문서 동기).
- **(진행 — GL1~4 완료·GL5 남음, §13) 그룹-로컬 pin — 멤버 그룹 내 위치 고정**: C2(그룹째 고정)와 **직교하는 별개 축**
  (`Tab.local_pinned` — 새 필드)로, 그룹 안 멤버 우클릭 "그룹 내 위치 고정"이 그 멤버를 subtree `[marker, end)` 안에서 마커 직후
  (렌더상 그룹 절대 최상단)로 float한다. **완료(GL1~4)**: `stablePartitionSubtree`(unit-aware·포인터 재탐색·드래그 게이트·early-out)
  파생 코어 · `toggleLocalPin` · 배선 `floatLocalPinsAllGroups`(§13.4 표준 순서 = `stablePartitionPinned` 뒤) · 드래그 clamp
  (`localPinPrefixBounds` + `commitSidebarDragPreview` 확정 clamp) · 렌더 📌(`sidebarRowShowsPin` 선두 분기·`Row.card.local_pinned`) ·
  위생(`clearStaleLocalPins`) · 마커 카드 위 배치(`PendingMarkerCard` 버퍼링·`flushMarkerCard`) · 공존/중첩 하드닝 + **버그 2건 수정**
  (버그1 `createTab` 그룹 흡수 방지 · 버그2 그룹 해제 시 로컬 pin 리셋). **남음(GL5)**: subgroup-as-member/마커 로컬 pin 확장(§13.8).
  **설계 확정본·단계·정정된 자기진단은 §13을 단일 출처로 둔다**.

## 11. clean-room

- **cmux**(GPL-3.0): 세로 사이드바·그룹 UX가 있다면 **최종 동작 비교(오라클)만**, 소스 미열람.
- **Chrome/Arc 탭 그룹·VSCode 탐색기 폴더**: collapsible section·검색-임시-펼침·**위치 기반 소속**의 동작 관례만 베이스로 참고(공개 제품 UX).
- 자료구조·함수 분해는 옮기지 않고 위 §2~§9의 maru 독립 설계(위치 파생·Row 투영·연속 파티션)로 재구현한다.
