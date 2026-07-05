# 사이드바 그룹(접이식 워크스페이스 묶음) 전략

이 문서는 왼쪽 세로 사이드바의 **워크스페이스 그룹**(폴더처럼 묶어 접고 펴기)의 단일 출처다. 목표 UX,
근본 모델 재설계(왜 slot=card 가정을 걷어내는가), 데이터·직렬화·인터랙션·단계 분해·검증·리스크를 정한다.

사이드바 자체(카드 레이아웃·헤더·검색·드래그·스크롤)의 단일 출처는 [탭·split·레이아웃 전략](tabs-splits-layout.md)이고,
chrome 컴포넌트 경계는 [Chrome 전략](chrome-strategy.md) §5.4/§5.5다. 이 문서는 그 위에 **그룹**을 얹는 설계만 다룬다.

> **현황**: **SG1~SG8 완료** — 접기 우선(그룹 만들기·헤더 실제 렌더·접기·rename·단축키, 제품 스크린샷 검증) + 카드
> 드래그로 넣기/빼기(SG4) + 그룹 통째 드래그(SG5-1) + 그룹 색(SG5-2, 헤더 밴드 tint·소속 카드 막대·우클릭 프리셋) +
> **중첩 그룹(SG5-3, 폴더 트리처럼 그룹 안 그룹 — 위치 파생을 다단계 depth로 일반화)** +
> **드래그로 중첩 넣기/빼기(SG5-4 — 드롭 컨텍스트 depth로 group_depth 조정: 헤더에 드롭=자식으로 중첩·최상위로 드롭=빼기)** +
> **UX 조정(SG6 — 우클릭 "그룹에서 빼기"(카드 하나만 최상위로)·헤더 기본 밴드 제거(화살표+이름만, 색·hover만 밴드 유지))** +
> **SG7 폐기**(드래그 depth "작게" 프리뷰는 적대검증이 전제를 반박 → §9-7 결론이 SG8로 수렴) +
> **고스트+삽입선 드래그 프리뷰(SG8a~f 완료 — 사이드바 드래그를 라이브 재배치에서 비커밋 고스트+드롭 1회 확정으로 전환:
> 접힌 그룹 카드 사라짐·헤더 통과 yo-yo 근본 해결, subtree 고스트 depth 프리뷰)** +
> **그룹 고정(핀+그룹 통합, C2 — §12): GP1~5 완료** — 그룹 통째 고정/해제(헤더 우클릭, 마커 `pinned`가 그룹 고정 권위)·
> 핀-리전 인식 파생·**suffix-exclusion 정규화**·`toggleGroupPin`+plan clamp·`pin_derived` 렌더(멤버 📌 억제·헤더 고정
> 인디케이터)·`assertPinnedPrefixRuntime` 확장, 제품 스크린샷(`MARU_FORCE_GROUP_PIN`) 검증.
> 구현이 진행되면 이 문서를 코드와 맞춘다([project-rules](project-rules.md#문서와-설명)).

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
        has_color: bool = false, // 그룹 색(SG5-2)이 지정됐는가 — **헤더 밴드를 낼지의 유일 스위치**(아래 헤더 밴드 정책). host가 tab.group_color!=0로 채운다
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

**메트릭 출처(SG3b에서 확정)**: `card_slot_h` = 기존 `props.metrics.sidebar_slot_height_px`(그대로 재사용). `header_row_h` =
**신규 메트릭** — 헤더 한 줄이므로 `≈ cell_height_px`(+세로 패딩 약간)로 두고 `CellMetrics`에 추가한다(platform이 채움).
`group_indent_px`(card.depth 들여쓰기 폭) = **신규 spacing 토큰**(`tokens.space`), rich에서 ≈1ch. 셋 다 hit-test·view가
공유하는 단일 값이라, 값이 흩어지지 않게 한 곳(props/tokens)에서만 정의한다(§5.4 레이아웃 단일 소스).

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

| 동작 | 단계 | UX | 구현 경로(베이스) |
|---|---|---|---|
| **그룹 접기/펴기** | **우선** | 헤더 줄 클릭(삼각 ▾/▸) | `onGroupHeader` → 그 그룹 시작 탭의 `group_collapsed` 토글 → `projectRows` 재투영 + 영속(§4) |
| **그룹 만들기(중첩)** | **우선** | 우클릭 "새 그룹으로 묶기" · **단축키 `Cmd+Opt+G`** · 팔레트 "New Group" | `create_group` 액션 → 활성/클릭 탭에 `group_start` 세팅. **그룹 안 카드면 depth+1 중첩**(§9), 최상위면 depth 1. 아래 연속 카드가 자동 소속(위치 파생) |
| **형제 그룹으로 분리** | ✅ SG5-3 | 우클릭 "형제 그룹으로 분리" · **단축키 `Cmd+Opt+Shift+G`** · 팔레트 "New Sibling Group" | `create_sibling_group` 액션 → 그 카드에 `group_start` 세팅 + `group_depth=현재 그룹과 같은 depth`(형제, 중첩 아님). 최상위면 depth 1(create_group과 결과 동일). create_group의 미러 — depth 계산만 다르다(§10 tension 해소) |
| **그룹 이름 바꾸기** | **우선** | 헤더 더블클릭 · **헤더 우클릭 "Rename"**(SG5-2-header) | rename 인라인 편집(`OverlayInput`) — 워크스페이스 rename과 동형(tabs-splits-layout.md rename). 헤더 우클릭 메뉴의 "Rename"도 같은 `startRename(.group)`(대상=group_start 마커)이라 더블클릭과 동일 |
| **그룹 해제** | **우선** | 카드 우클릭 "그룹 풀기" · **헤더 우클릭 "그룹 풀기"**(SG5-2-header) · 팔레트 "Ungroup"(기본 키 없음) | `ungroup` 액션 → 그 탭의 `group_start=null`(마커 제거) → 아래 카드는 위 마커/최상위로 자동 재소속. 헤더 우클릭은 대상이 그 헤더의 마커 탭이라 `enclosingGroupMarkerIndex`가 자기 자신을 찾아 카드 경로와 동일 결과 |
| **그룹에서 빼기** | ✅ | 우클릭 "그룹에서 빼기"(**그룹 소속 카드에만** 노출·최상위 카드엔 안 보임) · 팔레트 "Remove from Group"(기본 키 없음) | `remove_from_group` 액션 → `removeFromGroupForTab`: 그 카드를 **첫 `group_start` 마커 직전**(§2.1 최상위 구간)으로 `moveTab`(중첩 깊이 무관 완전 최상위). ungroup(그룹 통째 해제)과 달리 **이 카드 하나만** 뺀다 — 그룹은 유지(마커 카드면 다음 소속 카드로 마커 **승계** = closeTab과 동형, 마지막 멤버면 그룹 소멸). 이미 최상위면 no-op. 주입 조건 = `tabIsInGroup`(첫 마커 이후 = 그룹 안). 위치 파생이라 별도 소속 편집 없음 |
| **카드 드래그로 넣기/빼기** | ✅ SG4 | 카드를 마커 위/아래·헤더로 드래그(중첩 자식 그룹 안 포함) | `sidebarGroupDropTargetTab`(드롭 row→목표 탭 매핑) + `sidebar_drop_slot` 하이라이트. 위치 파생이라 별도 소속 편집 없음 — 드롭 위치의 depth가 곧 카드 depth(자식 그룹 안=자식 depth·최상위=0). 마커 탭 드래그=그룹 통째=SG5 |
| **그룹 통째 드래그** | ✅ SG5-1 | 헤더 잡아 드래그(클릭=접기와 threshold 구분) | `moveGroupRange`(구간 블록 이동)·`sidebarGroupDropBoundary`(경계 clamp)·`sidebar_group_drag_*` |
| **드래그로 중첩 넣기/빼기** | ✅ SG5-4 | 그룹 헤더를 **다른 그룹 헤더에 드롭=자식으로 중첩**, **카드/최상위에 드롭=형제 재정렬(+얕으면 빼기)** | `groupNestPlan`(헤더 드롭→중첩 계획: target_depth=타겟 depth+1·insert=타겟 subtree 끝)·`moveGroupNesting`(이동+`relevelBlock`으로 subtree 상대 depth 유지)·`moveGroupSibling`(형제 이동+자연 eff releveel로 빼기). 카드 드롭=형제(SG5-1 보존)·헤더 드롭=넣기의 명시적 분리 |
| 그룹 색 | ✅ SG5-2 | **카드 우클릭 "그룹 색: …"** 프리셋(카드 색과 같은 팔레트) · **헤더 우클릭 "그룹 색: …"**(SG5-2-header, 같은 라벨·팔레트·`setGroupColorForTab` 재사용) / 헤더 밴드 tint·소속 카드 막대 | `group_start` 탭에 `group_color` 저장(마커 하나에만, 소속 카드는 위치 파생). 헤더 밴드=lowerSidebar 블렌드(카드 배경 tint와 같은 경로)·소속 카드 막대=per-tab accent 루프(개별 accent>그룹 색>기본). workspace.v1 `group-color`(0=키 생략). 헤더/카드가 같은 색 메뉴를 공유해 사용자가 헤더에서도 색을 찾는다(피드백 반영) |

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
   - **접힌 헤더 드롭도 drag-direction 보정(code-review #2)**: 접힌 브랜치는 `from<m`이면 마지막 멤버 자리 `j-1`, `from>m`이면
     마커 뒤 마지막 자리 `min(j, len-1)`을 쓴다(펼친 헤더의 `from<m`→`m`/`from>m`→`m+1`과 같은 결). 옛 코드는 항상 `j-1`이라
     **marker-only 그룹**(`j==m+1` → `j-1==m`)에 `from>m` 드롭이 `moveTab(from, m)`으로 카드를 마커 **앞**에 떨궈 그룹 밖으로
     샜다 — 이제 두 방향 모두 마커 뒤(그룹 안)에 안착한다.
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
     그룹 색 > 활성 기본 accent > 없음(개별 지정이 그룹 색보다 명시적). 설정 = **카드 우클릭**과 **헤더 우클릭**(SG5-2-header)
     "그룹 색: …" 프리셋(카드 색과 같은 `tab_color_presets` 팔레트·`setGroupColorForTab`이 소속 그룹 마커에 세팅, 그룹 밖이면
     no-op). 헤더 우클릭은 `renameTargetAt`이 group_header row의 마커 탭을 `.group` 대상으로 잡고, `buildContextMenuItems`/
     `acceptContextMenu`의 `.group` 분기가 카드 메뉴와 **같은 색 라벨/dispatch**를 재사용한다(중복 최소·같은 색 메뉴 공유). 직렬화 = workspace.v1
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
     - **드래그(subtree 통째 이동)**: 그룹 통째 이동(`moveGroupRange`)·드롭 경계(`sidebarGroupDropBoundary`)·접힌 헤더 드롭이
       "다음 마커" 대신 **subtree 끝**(`groupSubtreeEnd`=같거나 낮은 depth 마커 전까지)을 쓴다 — 부모+자식이 함께 이동해 무결성
       유지(비중첩이면 "다음 마커"와 동일이라 SG4/SG5-1 동작 보존). **드롭 위치로 depth 변경(넣기/빼기)은 SG5-4에서 구현**한다.
     - **헤드리스 검증**: 2단계 중첩(A>B) depth 0/1/2·헤더 depth·member_count·부모 직접카드가 자식 앞·다단계 접기(부모/자식)·
       ungroup 재소속/승격·workspace.v1 group-depth round-trip. **스크린샷 훅** `MARU_FORCE_GROUP_NESTED`(+`_COLLAPSED`/`_COLOR`).
   - **SG5-4 ✅ — 드래그로 중첩 넣기/빼기(드롭 컨텍스트 depth로 group_depth 조정)**: SG5-3의 subtree 통째 이동에, **드롭 위치가
     가리키는 depth로 명시적으로 넣고/뺀다**. 그룹 드래그의 드롭 해석을 **헤더 드롭 vs 카드 드롭**으로 나눠(`groupDragFrame` 분기):
     - **다른 그룹 헤더에 드롭 = 그 그룹의 자식으로 중첩**(`groupNestPlan`→`moveGroupNesting`). target_depth=타겟 그룹 eff+1,
       insert_before=타겟 subtree 끝(=마지막 자식 자리라 "부모 직접 카드가 자식 앞" §2.1 유지). 이동만으로는 dragged 마커가 부모를
       pop해 형제가 되므로, `relevelBlock`이 subtree 마커들의 `group_depth`를 target 기준으로 **상대 유지**(dragged=target·자식은
       상대 offset 유지)로 다시 쓴다 — 이동+depth 조정을 함께 해야 진짜 자식이 된다.
     - **카드/최상위에 드롭 = 형제 경계 이동**(기존 `sidebarGroupDropBoundary`) + **빼기(un-nest)**: `moveGroupSibling`이 새 위치의
       자연 eff(gap-clamp된)로 relevel한다 — 같은 레벨이면 no-op(SG5-1 보존), 얕은 곳(최상위 등)이면 저장 depth를 eff로 낮춰 빼기가
       저장에도 반영(gap 제거). **카드 드롭=형제·헤더 드롭=넣기의 명시적 분리**라 SG5-1(카드 드롭에 형제 이동) 헤드리스가 그대로 통과.
     - **카드 드래그**: 위치 파생이 이미 드롭 위치의 depth를 흡수한다(자식 그룹 카드 위=자식 depth·최상위=0). 접힌 자식 헤더 드롭도
       `groupSubtreeEnd`로 그 자식 subtree 끝을 타겟(SG5-3에서 배선). 별도 depth 편집 없음.
     - **트리 연속·연속 파티션 유지**: 삽입은 항상 마커 경계(moveGroupRange), depth relevel은 블록을 고립 subtree로 정규화(1,2,3…
       연속)해 target 기준으로 remap하므로 gap·역전이 없다. projectRows 스택 워크가 재투영 시 유효 트리를 보장(gap-clamp).
     - **드롭 하이라이트**: `sidebar_drop_slot`이 드롭 row(넣기면 타겟 그룹 헤더)를 `.drop_zone` 밴드로 표시 — 헤더 밴드가 켜지면
       "이 그룹 안으로 넣기"를 뜻한다. **한계**: 목표 depth를 미리 들여쓰기로 보여주는 **비커밋 프리뷰는 고스트+삽입선(§10·SG7 결론)이라야 성립**한다(적대검증 결론) — 현재는 라이브 relevel이라 indent 자체는 이미 실시간이고, 미구현인 건 "커밋하지 않는" 프리뷰 시맨틱뿐이다.
     - **헤드리스 검증**: ①그룹을 다른 그룹 헤더에 드롭→중첩(depth+1, subtree 상대 depth C:1→2·2→3 유지) ②중첩 그룹을 최상위 카드에
       드롭→빼기(depth1, 저장 relevel) ③카드를 자식 그룹 안→자식 depth·최상위→0 ④mouse 통합(헤더→헤더 중첩). 매 케이스 depth·연속
       파티션·트리 연속 단언. **스크린샷 훅** `MARU_FORCE_GROUP_DRAGNEST`(A를 B 헤더에 드롭한 결과 = A가 B 자식으로 들여쓰기, 검증 완료).
6. **SG6 — 그룹 UX 조정(그룹에서 빼기 + 헤더 밴드 정책) ✅**: 사용자 요청 2건.
   - **그룹에서 빼기(remove_from_group)**: 카드 하나만 자기 그룹에서 빼 완전 최상위로 옮긴다(§7 표 "그룹에서 빼기" 행).
     `removeFromGroupForTab`이 그 카드를 첫 `group_start` 마커 직전(최상위 구간)으로 `moveTab`하고, 카드가 마커면 다음 소속
     카드로 마커를 승계(closeTab 동형)해 그룹을 살린다(마지막 멤버면 소멸). 이미 최상위면 no-op. `action.zig`(Action+parseAction)·
     `dispatchAppAction`·`command_catalog`("Remove from Group")·우클릭("그룹에서 빼기", `tabIsInGroup`으로 그룹 소속 카드에만
     주입)에 배선(ungroup의 미러 — ungroup=그룹 통째 해제 vs remove=카드 하나만). 기본 키 없음(저빈도, ungroup과 동일 결).
   - **헤더 밴드 정책(기본 보더라인 제거)**: §5 "헤더 밴드 정책" — 무색 헤더는 밴드 없이 화살표+이름만, 색 지정 헤더만 밴드
     (그 색 tint), hover/active는 카드와 같은 경로로 유지(`Row.group_header.has_color` 스위치, `view` 헤더 밴드 루프가 그 값 게이트).
     헤드리스로 무색=밴드 op 0·색=1·호버=호버 밴드 있음을 단언, `MARU_FORCE_GROUP`(무색 깔끔)·`_COLOR`(색 유지) 스크린샷 검증.
7. **SG7 — 드래그 depth 프리뷰**: 초안은 "작게"(순서는 이미 라이브니 **depth만** 시각 프리뷰 — relevel 없이·`?u8` 한 스칼라·
   싸게)였으나, **doc-first 적대검증 3회가 전제를 전부 반박**해 "작게"는 폐기한다. 발견(근거 코드는 app_session.zig):
   - **이미 라이브 relevel이다(잉여)**: SG5-4 그룹 드래그는 매 프레임 `groupDragFrame`(4214)→`moveGroupNesting`/`moveGroupSibling`
     →`relevelBlock`(4304)이 `group_depth`를 **즉시 커밋 + rebuild**한다 — 드래그 중 indent가 오늘도 라이브로 바뀐다. 별도 depth
     프리뷰는 잉여다("live 프리뷰 미구현"은 오해 — 미구현인 건 *비커밋 프리뷰 시맨틱*뿐).
   - **"relevel 없이"는 모순+과소명세**: relevel을 미루면 `recomputeVisibleTabs`가 그 위치를 **"형제"로 파생**(gap-clamp)하므로,
     프리뷰가 그 파생값을 능동적으로 **뒤엎어야** 한다(모순 주입). 대상도 한 row가 아니라 **subtree**(헤더+직속카드+자식)라
     `relevelBlock`의 스택 정규화를 렌더에서 재현해야 해 `?u8` 하나로 과소명세.
   - **비용 회피는 허구**: 매 프레임 `rebuildSidebar`(O(n) 재투영)는 그대로 낸다. 건너뛰는 `relevelBlock` write는 `changed` 가드까지
     있어 무시 가능한 절감이다.
   - **`sidebarGroupDropBoundary`는 depth를 안 낸다**: 경계 인덱스만 반환. 빼기 depth는 `moveGroupSibling`의 **post-move**
     `effectiveDepthAt` — 실제 이동 뒤에야 존재. 카드 드래그(SG4)는 depth 계산 자체가 없다(위치 파생). "이미 산출하니 재사용"은 틀렸다.
   - **접힌 그룹 사라짐은 relevel 무관**: 사라짐은 `recomputeVisibleTabs` pass2의 가시성 게이트(투영 효과, `anyCollapsedInStack`)라
     relevel을 생략해도 발생. depth 프리뷰가 가장 필요한 이 케이스에서 삽입 row가 아예 없어 **SG7은 no-op**.
   - **정작 거슬리는 이동 커밋(yo-yo)은 SG7이 안 건드린다**: "순서는 라이브 유지"라 헤더 통과 시 그룹이 실제로 들락날락하는 커밋은 그대로.

   **결론**: "작게"는 잉여이거나 사실상 §10 고스트 리팩터로 수렴한다. **의미 있는 depth 프리뷰 = 위치까지 비커밋 프리뷰 = 고스트+삽입선
   (§10)** 하나로 귀결(중첩=depth라 order/depth 분리는 category error). 유리한 사실 하나: depth를 읽는 렌더 경로는 `buildSidebarTitleDrawList`
   glyph indent 2곳(13884·13956)뿐이고 밴드·accent·hit-test·배지는 depth 무관 → **고스트 구현 시 override 표면 자체는 작다**. 착수 시점은
   접힌 그룹 사라짐·드래그 yo-yo가 실사용에서 거슬릴 때(§10 고스트 리팩터). 그 전엔 현행 라이브 재배치로 충분(depth가 이미 실시간 보임).
8. **SG8 — 고스트+삽입선 드래그 프리뷰(완료 ✅ SG8a~f)**: SG7 폐기 결론(§9-7)이 가리킨 하나의 리팩터 — 사이드바 드래그를
   **라이브 재배치**(매 프레임 `self.tabs` 커밋+relevel+rebuild)에서 **고스트+삽입선**(비커밋 프리뷰 + 드롭 **1회** 확정)으로 전환한다.
   접힌 그룹 드롭 시 카드가 순간 사라짐·헤더 통과 시 그룹이 들락날락하는 yo-yo가 실사용에 거슬릴 때 착수했다(그 트리거가 왔다).
   초안은 **적대검증 3회**를 거쳐 아래 보강이 확정됐고, SG8a~f로 전량 구현·검증됐다. **결과**: 카드·그룹 드래그가 드래그 내내
   `self.tabs` 불변(비커밋)이라 **접힌 그룹 드롭 시 카드 사라짐·헤더 통과 yo-yo가 근본 해결**되고(SG7/SG8 국소 프리뷰 폐기의
   귀결 — 의미 있는 depth 프리뷰는 "위치까지 비커밋 프리뷰=고스트+삽입선" 하나로 수렴), 목표 depth가 subtree 고스트 들여쓰기로
   드래그 중 정직하게 보인다. 남은 것은 cosmetic(하이라이트 밴드 높이 등)과 별도 축 후속(그룹 고정=핀+그룹 파티션)뿐이다.
   - **핵심 결정 A — 고스트 복제(스냅) + 삽입선**: 드래그 대상(카드=1행·그룹=subtree N행)을 목표 위치·depth로 **반투명 고스트**로
     그리고 그 상단에 얇은 삽입선을 얹는다. 삽입선 단독은 기각 — 이동단위가 subtree(SG5-4)라 점 하나로는 상대 depth를 못 보인다.
     고스트는 floating이 아니라 목표 정지(snap)로 둔다(위치·depth 전달이 목적). depth를 읽는 렌더는 `buildSidebarTitleDrawList`
     indent 2곳뿐이라 override 표면이 작다(§9-7).
   - **핵심 결정 B — projectRows 가상배치 + 렌더/hit-test 도메인 분리**: 드래그 중 `self.tabs`는 **불변**. 프리뷰 상태를
     가상배치로 재투영해 **두 투영**을 둔다 — `sidebar_rows`(원본, 불변, hit-test·drop 계산이 봄) vs `sidebar_preview_rows`(신규,
     고스트 포함, 렌더가 봄). "사라짐"은 pass2 가시성 게이트(`anyCollapsedInStack`)가 원인이라 렌더-레이어 단독으로는 못 고친다 —
     투영이 프리뷰 입력을 받아 고스트를 **강제 방출**해야 성립한다. reflow·depth·연속 파티션은 가상배치에서 pass1/pass2 재사용으로 공짜.
   - **row-count 모델 = move(순열)로 확정(초안 정정)**: 고스트는 "복제(행 증가)"가 **아니라** 원본을 목표로 이동한 **가상 순열
     배치**(그 행을 반투명으로)다. 따라서 `preview_rows.len == sidebar_rows.len`(접힘 게이트로 빠질 행은 프리뷰가 예외로 **되메워**
     길이를 맞춘다)이라 **스크롤 높이가 발산하지 않는다**(복제 모델의 콘텐츠 높이 증가·스크롤 clamp 흔들림이 원천 제거). 프리뷰는
     `projectRowsFrom(order, group_depth)`에 **가상 order/group_depth**를 넘긴 결과일 뿐 — SG8a에서 이 코어가 이미 order를 존중한다.
   - **등가 안전화(이중경로 divergence 방어)**: 프리뷰(비커밋)와 드롭(커밋)이 갈리는 유일 위험은 두 경로가 다른 결과를 내는 것이다.
     완화 순서 — (i) **순열/depth 순수 코어를 *먼저* 단일화**(SG8a `projectRowsFrom` = 프리뷰·확정 공유 토대, 완료), (ii) 헤드리스
     **등가 테스트**로 `simulateDrop`이 낸 order/depth == 실제 move 후 read를 고정, (iii) up(확정)에서 **재계산하지 말고** 마지막
     프리뷰 `plan`을 재사용해 기존 `moveTab`/`moveGroupNesting`/`moveGroupSibling`을 **정확히 1회** 호출. `clampMoveToGroup`(핀 경계)을
     그 순수 코어에 포함해 **프리뷰가 클램프 전 목표를 보이는 고스트-확정 불일치**를 없앤다(고스트가 핀 경계에서 정직하게 멈춘다).
   - **게이트/투영 정합**: 프리뷰 투영은 타겟 헤더를 `collapsed=false`로 뒤집어(접힌 그룹에 넣어도 고스트가 보이게) code-review #6
     류 "접힘 표시인데 카드 보임" 모순 재발을 막는다. `member_count`와 pass2 헬퍼 — `directCardCount`·`subtreeHasMatch`·
     `effectiveDepthAt`·`groupSubtreeEnd` — 는 **order-aware**여야 가상배치 위에서 옳게 파생된다(**SG8a에서 완료**).
   - **도메인 인덱스 분리**: `sidebar_drop_slot` 하이라이트는 **preview 도메인**으로 재기준화(렌더가 보는 preview_rows 인덱스).
     고스트 범위는 상태 배열(`ghost_mask: []bool`, 길이 정합이 함정)이 아니라 **`ghost_lo`/`ghost_hi` range로 파생**(preview_rows에서
     고스트가 앉는 연속 구간). 표시-슬롯을 읽는 **놓치기 쉬운 렌더 소비자**를 preview 도메인으로 함께 이주 — **⌘1-9 배지**(app_session.zig
     14799 근처)·**IME caret**(2077 근처). 이 둘을 빠뜨리면 고스트 중 엉뚱한 행에 배지/caret이 간다.
   - **UX 완결 — 드롭 시 자동펼침**: 접힌 그룹 안으로 드롭하면 확정 후 그 그룹을 자동으로 펼친다(`group_collapsed=false`) —
     "드래그 중 안 사라짐"(고스트가 해결)에 더해 "드롭 후 접힌 폴더 안으로 사라짐"까지 닫는다.
   - **핀 파티션 — clamp 코어 포함으로 해소**: 위 등가 안전화의 `clampMoveToGroup`을 순수 코어에 태워 프리뷰·확정이 같은 클램프를
     본다(핀 경계 드롭이 프리뷰에서도 정직). **그룹 고정(핀+그룹 조합의 파티션 무결성)은 별도 축 후속**으로 §10 백로그.
   - **프리뷰 상태 모델**:
     ```zig
     sidebar_drag_preview: ?SidebarDragPreview = null,
     sidebar_preview_rows: ArrayListUnmanaged(Row) = .empty, // 렌더 전용(고스트 포함)
     const SidebarDragPreview = struct {
         origin: usize,      // 원본 subtree 시작(카드=tab, 그룹=마커). self.tabs 불변이라 안정
         origin_len: usize,  // subtree 길이(카드=1, 그룹=groupSubtreeEnd(origin)-origin)
         plan: DropPlan,     // 매 프레임 원본 sidebar_rows hit-test로 재계산(마지막 값이 확정에 재사용)
         cursor_y: f64,
     };
     const DropPlan = union(enum) {
         card: struct { target_tab: usize },                            // SG4: moveTab
         group_sibling: struct { insert_before: usize },                // SG5-1 형제 + SG5-4 빼기: moveGroupSibling
         group_nest: struct { insert_before: usize, target_depth: u8 }, // SG5-4 넣기: moveGroupNesting
         none,
     };
     ```
     depth 맵은 저장하지 않는다 — `group_nest{target_depth}`만 들고, 자식 상대 depth는 가상 order에 `projectRowsFrom` pass1을
     재실행해 파생한다(relevel 재현이 아니라 동일 pass1을 가상순서에 적용).
   - **simulateDrop 순수 코어**: `fn simulateDrop(self, plan, arena) VirtualLayout`이 plan을 `self.tabs`에 **커밋하지 않고** 이동
     후 순열 `order`·`group_depth`·`ghost_lo`/`ghost_hi`를 반환한다. 프리뷰 = `simulateDrop(plan)` → `projectRowsFrom(vl.order,
     vl.group_depth)` → `sidebar_preview_rows`(고스트 [lo,hi) 구간은 가시성 게이트 예외로 강제 방출). 확정 = 마지막 plan으로 기존
     move 1회. **적대검증 정정**: `surface_ptrs`/`active_tab`은 **divergence가 아니다** — `reorderTabs`가 활성 `*Tab` 포인터를
     추적해 새 인덱스로 보정하고 `surface_ptrs.items`는 `app_window.tabs`와 같은 backing이라, 순서/depth만 다루는 `simulateDrop`은
     포인터 셔플을 건드릴 필요가 없다(포인터 재배열은 확정 경로 `moveTab`/`moveGroupRange`에만 남는다).
   - **렌더 통합(모두 preview_rows를 봐야 함, 정합 핵심)**: 밴드(`view`)·glyph(`buildSidebarTitleDrawList`)·py_top/스크롤
     (`fillSidebarGlyphPyTop`·`contentHeight`)·accent/tint 순회가 드래그 중 **preview_rows**를 본다(고스트 알파↓≈40%, 무색/감쇠).
     hit-test·plan 계산은 항상 **원본 `sidebar_rows`**(불변)를 봐 yo-yo를 원천 차단한다. 삽입선은 `rowTop(preview_rows, ghost_lo)`에 얇은 quad.
   - **단계 분해(각 단계 독립 green)**:
     - **SG8a ✅ — projectRows를 order-aware 토대로(동작 보존, 프리뷰 없음)**: `recomputeVisibleTabs`를 `projectRowsFrom(order:
       []const usize, group_depth: []const u8)` 순수 코어 + **identity 래퍼**로 분리. pass1/pass2가 `self.tabs.items[order[i]]`를
       거치고 depth 파생은 `group_depth[i]`를 선언값으로 쓴다. `group_header.tab`=`order[i]`(원본 인덱스)·`.active`=`order[i]==active_tab`.
       pass2 헬퍼 4개 order-aware — `subtreeHasMatch`/`directCardCount`는 필수 `order`(투영 내부 전용), `effectiveDepthAt`/
       `groupSubtreeEnd`는 **optional `order`/`group_depth`**(null=라이브 self.tabs, 드래그/create 경로가 그대로 호출·byte-identical).
       **검증**: identity `projectRowsFrom` == 옛 flat/그룹 투영(모든 Row 태그·필드 byte-identical, 헤드리스 단언) + 뒤집힌 순열이
       표시 순서만 뒤집고 `self.tabs`는 불변임을 단언. 기존 projectRows/SG3~SG5 그룹 테스트 회귀 0.
     - **SG8b ✅ — `simulateDrop` 순수 코어 + 등가 테스트**: plan→VirtualLayout(order/group_depth/ghost 범위). 검증: `simulateDrop`
       산출 == 실제 move 후 read(헤드리스 등가).
     - **SG8c ✅ — 프리뷰 투영 + 고스트 방출 + 사라짐 예외**: `sidebar_preview_rows` + 게이트 예외([lo,hi) 강제 방출). 검증: 접힌 그룹
       카드 plan→preview_rows에 고스트 존재(원본 rows엔 없음).
     - **SG8d ✅ — 카드 드래그 고스트 렌더 + up 확정**: 반투명·삽입선·안 사라짐. 검증: up 후 `self.tabs`가 라이브 시절과 동일 + macOS 스크린샷.
     - **SG8e ✅ — 그룹 드래그 subtree 고스트 + depth 프리뷰**: 검증: up 등가 + 스크린샷.
     - **SG8f ✅ — 라이브 경로 잔재 제거·정리 + 완결**: SG8d/e로 동작은 이미 완성됐고, 이 단계는 옛 라이브 경로 잔재를 청소한다.
       (1) **매 프레임 앵커 팔로우 제거** — `groupDragFrame`→**`groupDragPreviewFrame`**로 개명(프리뷰 전용)하고 반환값을 `void`로.
       self.tabs가 드래그 내내 불변이라 마커 인덱스가 안정 → 옛 `sidebar_drag_index`/`sidebar_group_drag_marker`의 매 프레임
       반환값 대입(새-마커 추적 잔재)을 걷어냈다. (2) **`sidebar_drop_slot` 제거** — SG8d/e에서 고스트+삽입선으로 전환되며 이
       드롭 하이라이트 슬롯이 write-only-null(전부 dead)이 됐다. 필드+dead 분기+테스트 단언까지 제거(pane grip 드래그는 **별도**
       `pane_drop_slot`을 써 무관 — 상호배타). (3) **rebuild 수렴 확인** — 드래그 프레임은 `refreshDragPreview`(rebuild 없음)+
       `rebuildSidebar` 정확히 1회(두 투영: hit-test용 원본 `sidebar_rows` + 렌더용 `sidebar_preview_rows`는 설계상 필요, 이중
       rebuild 아님). 확정(up)의 `commitSidebarDragPreview`가 move 1회+rebuild로 마무리한다. 검증: `zig build test`+`mise run check`
       (oracle/e2e/stress) 회귀 0 + 스크린샷 4변형(카드·그룹·접힘·색) 정상 + 비드래그(`MARU_FORCE_GROUP`) 고스트 없이 clean.
   - **검증 비대칭**: SG8a/b/c는 순수 함수라 **헤드리스가 1급**(byte-identical·등가·고스트 존재). SG8d/e/f의 반투명 알파·삽입선 y·
     depth 픽셀은 헤드리스로 안 잡혀 **macOS 제품 스크린샷이 1급**(검증 매트릭스). 훅 `MARU_FORCE_GROUP_DRAGGHOST`(예정).
   - **적대검증이 정정한 것(요약)**: ① `surface_ptrs`/`active_tab`은 divergence 아님(reorderTabs가 활성 포인터 추적·같은 backing). ②
     핀은 clamp 코어 포함으로 해소(그룹 고정은 독립 백로그). ③ 프리뷰 투영은 타겟 헤더 `collapsed=false` **flip이 필요**(code-review #6
     재발 방지). ④ row-count는 복제(행 증가)가 아니라 **move(순열)**라 스크롤 발산 없음. ⑤ `ghost_mask`는 상태 배열이 아니라 range 파생.
   - **리스크**: [높음] 이중경로 divergence(→ 등가 테스트→코어 단일화, SG8a가 첫 단추). [중] 도메인 분리 이주 누락(렌더 소비자를
     preview_rows로, hit-test는 sidebar_rows로 정확히 — ⌘1-9 배지·IME caret 포함). [중] 스크롤 중 드래그 프리뷰 재투영·삽입선 트리거
     (autoscroll 없음=기존 한계). [낮] pane grip 별도 경로(상호배타)·rename 중 드래그 confirm 게이트가 up 삼키면 프리뷰 잔류(정리 경로 필요).

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

## 11. clean-room

- **cmux**(GPL-3.0): 세로 사이드바·그룹 UX가 있다면 **최종 동작 비교(오라클)만**, 소스 미열람.
- **Chrome/Arc 탭 그룹·VSCode 탐색기 폴더**: collapsible section·검색-임시-펼침·**위치 기반 소속**의 동작 관례만 베이스로 참고(공개 제품 UX).
- 자료구조·함수 분해는 옮기지 않고 위 §2~§9의 maru 독립 설계(위치 파생·Row 투영·연속 파티션)로 재구현한다.

## 12. 그룹 고정(핀+그룹 통합, C2)

§10 백로그의 "그룹 고정 — 핀+그룹 조합의 파티션 무결성"을 별도 축으로 승격해 **C2(핀-리전 인식 파생)**로 설계 확정한다.
현재 pin(`[고정][비고정]` 프리픽스, session_model 88·`moveTab`)과 그룹(§2.1 위치 파생 마커)은 **각자 파티션**이라, "그룹
통째를 고정/강등"할 때 그룹이 고정/비고정 경계를 가로지르면 고정 프리픽스 불변식이 깨진다(SG4/SG5-1/SG8 모두 범위 밖).
C2는 **그룹 마커 `Tab.pinned`를 그룹 고정 권위**로 실어(§12.2) 리스트를 `[고정][비고정]` 2리전으로 나누고, **각 리전
안에서 §2.1 연속 파티션이 다시 성립**하게 한다. 단계 GP1~5(§12.12)는 **전부 완료** — 파생 코어 pin-region 인식(GP1)·
suffix-exclusion 정규화(GP2)·`toggleGroupPin`+plan clamp(GP3)·`pin_derived` 렌더(GP4)·잔재/문서 동기(GP5). 아래
§12.4~§12.11의 헤드리스와 `MARU_FORCE_GROUP_PIN` 스크린샷이 그 게이트다.

> **doc-first 적대검증 3회가 초안(scratchpad group-pin-draft.md)의 세 자기진단을 반박했고, 아래는 그 정정본이다.**
> 틀린 진단 셋 — ① "pass1 상태 폭발이 최대 리스크", ② "정규화를 rebuild 직전 단일 chokepoint로", ③ "group clamp를
> 이동 함수(moveGroupRange/simulateGroupMove)에" — 은 각각 §12.4·§12.5·§12.6에서 정정한다. 보강 9개는 §12.4~§12.11에 반영.

### 12.1 판정 — 삼중 파티션 공존이 C2로만 성립

- **I1(핀 프리픽스)**: 고정 탭이 `[0, pinned_count)`에 연속(`stablePartitionPinned`·`togglePin`·`clampMoveToGroup`).
- **I2(그룹 연속+최상위 전방)**: 각 그룹 `[마커, subtree_end)` 연속, 최상위 카드는 그 리전 첫 마커 이전(§2.1).
- **I3(중첩 gap-clamp 트리)**: `projectRowsCore` pass1·`effectiveDepthAt`·relevel.
- **[약점 최상] "고정 그룹 + 비고정 최상위 카드"**: §2.1의 **전역 앵커**(첫 마커 이전=최상위)와 핀 프리픽스가 리스트 앞을
  다퉈 표현 불가다. C3(멤버별 pin)=I1×I2 직접 모순 → 폐기. C1(전역 앵커 유지)=이 인접을 못 담음. **C2(핀-리전 인식
  파생) = 리전별 앵커 2개로만 공존 성립**. 계층은 **pin ⊃ group ⊃ nest**(엄격) — 핀 경계가 **최상위 단위 경계에서만**
  자르면 subtree가 통째로 한 리전에 들어가 I3이 자동 안전하다.

### 12.2 모델 — 새 필드 0개, `Tab.pinned` 재해석

`group_color`가 "마커 저장·멤버 위치 파생"의 선례이듯, **`Tab.pinned`를 두 층으로 재해석**한다(새 필드 0).

- **마커 탭 `pinned` = 그룹 고정 권위**(`group_color`/`group_depth`와 같은 층). 그룹 고정 = 마커 pinned=1.
- **그룹 멤버 카드 `pinned` = 파생 캐시**(권위 = enclosing 마커). `normalizePinnedFromGroups`가 `member.pinned :=
  enclosingMarker.pinned`로 동기화(§12.5). 최상위 카드는 개별 pin(현행 그대로).
- **왜 캐시 미러인가**: `countPinnedTabs`·`stablePartitionPinned`·`clampMoveToGroup`이 **per-tab pinned**를 읽는다. 마커만
  두면 `stablePartition`이 마커만 옮겨 그룹을 shred한다. 멤버를 마커 값으로 재기록하면 **기존 per-tab 핀 머신을 무변경
  재사용**한다.

### 12.3 파티션 통합 레이아웃

```
[고정 최상위카드] [고정 그룹들] [비고정 최상위카드] [비고정 그룹들]
└──────── 고정 리전 [0,pinned_count) ────┘ └──── 비고정 리전 [pinned_count,len) ────┘
       리전 안: §2.1(최상위 전방→그룹)          그룹 안: 중첩(SG5-3)
```

pin이 최외곽 2리전을 만들고, 리전 안은 §2.1, 그룹 안은 중첩이다. 불변식: I1 자명(pinned_count=고정 리전 끝, 항상 최상위
단위 경계 정렬 — normalize가 보장). I2 **리전별 first-marker**. I3 subtree가 한 리전 통째(핀 균일).

### 12.4 파생 코어 — pin-region 인식(보강 1·8, 정정 ①) — **GP1 완료**

**정정 ①(pass1 폭발 아님)**: 초안은 "pass1에 pin-region 리셋을 넣으면 상태(스택,order,group_depth,region)가 폭발"을 최대
리스크로 봤다. 검증 결과, 리셋은 **pass1 하나가 아니라 7개 subtree-스캔 경계 전부**에 필요하고, 각 경계는 "인접(또는
subtree 스캔 중) **per-position pinned 플립**에서 리셋/break" **한 줄**일 뿐이라 폭발이 아니다. "고정 그룹 + 비고정 최상위
카드" 인접이 **마커가 아닌 카드**에서 리전 경계를 만들므로, 마커만 보던 기존 경계 조건이 이를 못 잡아 ⓐ비고정 카드가
고정 subtree에 삼켜지고 ⓑ고정 접힘이 비고정 카드로 상속(숨김 shred)되고 ⓒ`(N)` 배지가 오염된다. 그래서 **경계 도메인 =
order-공간 per-position `self.tabs.items[order[i]].pinned`**(고정 count 아님, 보강 8)를 7 경계에 추가한다:

| # | 스캔(`app_session.zig`) | pin-region 처리 | 막는 증상 |
|---|---|---|---|
| 1 | `projectRowsCore` pass1 depth stack | `pinned` 플립 시 depth 스택 리셋(`top=0`) | 비고정 카드가 고정 그룹 depth 상속(삼킴) |
| 2 | `projectRowsCore` pass2 cstack collapse | `pinned` 플립 시 접힘 조상 스택 리셋(`ctop=0`) | 고정 collapsed가 뒤 비고정 카드로 상속(shred) |
| 3 | `effectiveDepthAt` | 스택 재실행 중 `pinned` 플립 시 리셋 | 리전 밖 카드 depth 오파생 |
| 4 | `groupSubtreeEnd` | 마커 pin과 다른 위치에서 break | 고정 subtree가 비고정 카드까지 삼킴 |
| 5 | `subtreeHasMatch` | 〃 | 검색 헤더 가시성이 다른 리전 매치로 오판 |
| 6 | `directCardCount` | 〃 | `(N)` 배지가 다른 리전 카드로 오염 |
| 7 | `ghostOverlapsSubtree` | 〃 | 드래그 고스트 flip/force-show 오판 |

또한 위치 앵커/소속 헬퍼를 리전 국소화한다:

- `firstGroupStartIndex` → **`firstGroupStartInRegion(lo, hi)`**(리전 안 첫 마커). `firstGroupStartIndex`는 `(0, len)` 위임
  래퍼로 남긴다.
- `pinRegionBounds(idx)` 신설 — idx가 속한 핀 리전 `[lo, hi)`(per-position pinned가 같은 최대 연속 구간; I1 프리픽스를
  **가정하지 않고** 인접 pinned 플립만 본다).
- **`enclosingGroupMarkerIndex` 핀 클램프** — 상향 스캔이 pin 플립을 넘으면 null(비고정 카드는 고정 리전 마커에 소속 불가).
- **라이브 8 호출처**: `promotePaneToNewWorkspace`(새 비고정 탭 삽입점 = `firstGroupStartInRegion(pinned_count, len)`)·
  `sidebarGroupDropBoundary`(리전 앵커)·`tabIsInGroup`(리전 소속)·`removeFromGroupForTab`(×2, 리전 안 최상위)·
  `ungroupTab`·`setGroupColorForTab`·`startRenameGroupForTab`(뒤 셋은 `enclosingGroupMarkerIndex` 클램프로 자동 리전화).

**동작 보존(SG8a identity 패턴)**: 현재 모든 워크스페이스는 그룹 고정 개념이 없어 **마커 pinned=0**(고정 그룹 0개)이다.
그러면 마커는 전부 비고정 리전이라 **리전 경계 = 리스트 양끝**이 되고, 7 경계의 pin 리셋/break는 flip 지점에서 스택이
비어 **no-op** → 기존 `projectRows` 산출과 **byte-identical**이다. 헤드리스 검증(§12.11)이 이를 고정한다.

### 12.5 정규화 — `normalizePinnedFromGroups`(보강 2, 정정 ②) — **GP2 완료**

**정정 ②(chokepoint 단일화 불가)**: 초안은 "정규화를 rebuild 직전 단일 chokepoint(`recomputeVisibleTabs` 안)로 모으자"
했으나 세 이유로 불가다 — ⓐ `recomputeVisibleTabs`는 매 rebuild O(n) 스택워크라 여기서 `self.tabs.pinned`를 mutate하면
매 프레임 비용, ⓑ **`sidebar_drag_preview != null` 게이트**(프리뷰 중 `self.tabs.pinned` mutate 금지 = SG8 "드래그 내내
`self.tabs` 불변" 보존 — `normalize` 첫 줄이 early-return), ⓒ **복원 특례**(`applyWorkspaceWindow`에서 `stablePartitionPinned`
**앞**에 명시 호출, §12.9). 그래서 정규화는 rebuild가 아니라 **pinned/그룹을 바꾸는 6 mutation 지점** 뒤에 1회씩 부른다:
`toggleGroupPin`·그룹 생성(`beginGroupForTab`)·`ungroup`·`removeFromGroup`(빼기 경로)·`closeTab` 마커 승계·
`commitSidebarDragPreview`(+복원 특례 `applyWorkspaceWindow`). **`togglePin`(개별 pin)은 정규화 없음** — 최상위 카드는 자기
값 유지, 그룹 멤버는 개별 pin 입구가 차단(§12.7 보강5)이라 desync가 안 생긴다.

**정정 ②′(marker-propagation → suffix-exclusion)**: 초안·GP2 서술은 "pass1과 동형 스택워크로 `member.pinned :=
enclosingMarker.pinned`를 재기록"(marker-propagation)이었으나, 그러면 GP1 렌더(`groupSubtreeEnd` **pin-인식**)가 "고정 그룹 +
비고정 top카드"(§12.1) 인접에서 top카드를 그룹에서 배제하는 것과 tension이 생겨 canonical이 어긋난다. 실제 구현은 **suffix-exclusion**
이다: 각 **최상위 그룹의 pin-무시 구조 subtree** `[i, e)`(`effectiveDepthAt`+형제/얕은 마커 break)에서 마커 pin이 **마지막으로
일치**하는 위치 `last_match`까지를 진짜 멤버 범위로 보고 `member.pinned := marker.pinned`로 재기록한다. 그 뒤 꼬리 `[last_match+1, e)`
(마커와 다른 pin이 subtree 끝까지 이어짐 = 다음 pin 리전의 **genuine 최상위 카드**)는 **배제**하고, 사이에 낀 desync 멤버(마커 pin이
뒤에서 재등장)는 **흡수**한다. 이렇게 하면 canonical 상태에서 GP1 렌더와 **동일 답**(top카드 안 흡수·idempotent)을 내면서, 손상/
레거시 혼합 파일(멤버 pinned=1·마커=0, 또는 desync)은 여전히 마커 기준으로 canonical화해 **shred를 막는다**(누락 시 shred가 실패 모드).

### 12.6 이동/드래그(정정 ③) — **GP3 완료**

**정정 ③(clamp는 이동 함수가 아니라 plan 산출부)**: 초안은 `moveGroupRange`/`simulateGroupMove`에 `clampGroupMoveToRegion`을
넣자 했으나, 두 함수는 프리뷰/확정 **이중 경로**라 양쪽에 넣으면 divergence(SG8 이중경로 위험)가 재발한다. 대신 **`groupDragPreviewFrame`의
plan 산출부에서 단일 clamp** — `insert_before`를 `DropPlan`에 굽기 **전**에 드래그 그룹의 리전으로 clamp한다. 확정(up)은
마지막 plan을 재사용하므로(SG8 iii) 프리뷰=확정이 같은 clamp를 본다. 카드 드래그는 이미 `clampMoveToGroup`(핀 경계)을
순수 코어에 태워(SG8) 정직하다. 중첩 넣기(`groupNestPlan`)는 **두 그룹 pin이 같을 때만 허용**(다르면 null→형제 폴백,
C3 재발 방지). 드롭 고정 승계는 **없음**(clamp가 애초에 막고, pin은 명시 토글 전용).

**`toggleGroupPin`의 리전 안착(정정 ③′ — `moveGroupRange` 대신 `stablePartitionPinned`)**: 그룹 통째 고정/해제(§12.10)는
드래그가 아니라 명시 토글이라 위 plan 경로가 아니다. 순서: (1) 토글 **전** `groupSubtreeEnd`(pin-인식, 개별 pin 차단으로
마커·멤버 pin 일치)로 완전 subtree `[mi, e)`를 잡고, (2) 마커+멤버 pin을 새 값으로 **직접 동기**(suffix-exclusion은 전량
flip 직후를 "꼬리"로 보고 안 흡수하므로 여기서 명시 flip이 유일 동기원), (3) **`stablePartitionPinned`**로 그 연속·uniform-pin
블록을 목표 리전 경계에 안착한다 — 복원과 **같은 프리픽스 정렬**이라 그룹 리전 양쪽에 다른 고정 단위가 있어도(예: 고정 그룹 앞에
또 다른 고정 그룹) 프리픽스 불변식(I1)을 항상 지킨다(`moveGroupRange`의 단일 `insert_before`로는 표현 못 하는 경계 케이스 —
stable 수집이 그룹을 통째로 붙여 옮겨 파티션 무결 유지). (4) `normalize`(idempotent 확인) 후 1회 rebuild. `clampGroupMoveToRegion`은
어디까지나 **그룹 드래그** plan 지점 전용이고, 토글의 리전 안착은 `stablePartitionPinned`가 맡는다.

### 12.7 removeFromGroup·개별 pin·마커 승계(보강 4·5·6)

- **removeFromGroup 고정 멤버 빼기(보강 4)**: 그룹에서 빼면 pin을 잃는다(빼기=pin 상실). `clampMoveToGroup`이 pin-trap이라
  **unpin을 move 전에** 결정한다(그러지 않으면 clamp가 고정 영역에 붙잡는다).
- **개별 카드 pin 입구 차단(보강 5)**: 그룹 멤버에서 `togglePin`을 누르면 **그룹째 고정으로 위임하거나 비활성**한다(멤버만
  개별 pin하면 캐시 권위가 깨진다).
- **`inheritGroupMarker` pinned 승계(보강 6)**: 마커 승계(`closeTab`·removeFromGroup) 시 `group_start/collapsed/depth/color`에
  더해 **`pinned`도 승계**해야 승계 과정에서 그룹 고정이 소실되지 않는다.

### 12.8 렌더 힌트 `pin_derived`(보강 7) — **GP4 완료**

멤버 캐시 `pinned=1`을 그대로 렌더하면 **모든 멤버에 📌가 떠 노이즈**다. `Row.card`에 **`pin_derived: bool` 힌트**를 실어
(`chrome/components/sidebar.zig`: `card: struct { …, pin_derived }`) `projectRows`가 비마커 멤버 카드엔 `true`, 최상위 카드·
마커 자기 카드엔 `false`를 굽는다(마커 pinned는 파생이 아니라 **권위**).

**단일 출처 `sidebarRowShowsPin(row)`**: `buildSidebarTitleFrame`이 `pins[]`를 채울 때와 헤드리스 테스트가 **공유**하는 하나의
판정 함수(live `tab.pinned` 산발 판정 금지). 규칙 — (a) `group_header` row = 마커 `pinned`면 **그룹 고정 인디케이터 📌**(헤더 이름줄
우측 끝, "이 그룹 고정됨"을 헤더 하나에만), (b) `card` row 중 `pin_derived`(멤버 파생 캐시)면 **억제**, (c) **그룹 마커 자기 카드**
(`group_start != null`)도 **억제**(헤더가 인디케이터를 드므로 자기 카드 📌는 중복), (d) 그 외 최상위 카드만 live `tab.pinned` 그대로
📌(개별 위치 고정 유지). rename 중 헤더는 호출처가 억제(편집 폭 보존). 도메인은 `sidebarRenderRows()`(드래그 중이면 preview_rows).

### 12.9 직렬화 — 새 키 0

`workspace.v1`의 `pinned={d}`(탭 라인 스칼라)가 마커 pin을 그대로 싣는다 — 그룹 고정 = 마커 `pinned=1`. 멤버 pinned 캐시는
저장돼도 무해(복원 정규화가 흡수). **복원 순서: (1) 탭 설치 → (2) `normalizePinnedFromGroups` → (3) `stablePartitionPinned`.**
지금은 (3)만 있으니 **(2)를 (3) 앞에 삽입**한다(§12.5 복원 특례). 손상 파일(멤버 pinned=1·마커=0)은 복원 정규화가 canonical로
흡수 — round-trip 테스트는 "정규화 후 canonical 단언"으로 둔다.

### 12.10 UX

- **헤더 우클릭 "그룹 고정" 토글**(`ctx_group_menu_pin` = 그룹 헤더 메뉴 Rename 다음 항목, `.group` 분기): `toggleGroupPin(marker)`
  → 마커+멤버 pin 직접 동기 → **`stablePartitionPinned`로 리전 안착**(§12.6 정정 ③′, `moveGroupRange`가 아님) →
  `normalizePinnedFromGroups`(idempotent) → rebuild → `assertPinnedPrefixRuntime`(디버그).
- **카드 "위치 고정"**은 top-level 전용 — 그룹 소속 카드 우클릭 pin은 `enclosingGroupMarkerTab`로 마커를 찾아 **그룹째 위임**
  (`toggleGroupPin`), 최상위면 `togglePin`(§12.7 보강 5, 개별 desync 차단).
- pin 표시는 §12.8(`sidebarRowShowsPin` 단일 출처 — 멤버·마커 카드 📌 억제·헤더 인디케이터). pane 분리·removeFromGroup은
  **각 카드가 속한 핀 리전의 첫 마커 앞**(§12.4 리전 헬퍼 `firstGroupStartInRegion`/`pinRegionBounds`).

### 12.11 불변식·검증(보강 8·9)

- **경계 도메인(보강 8)**: order-공간 **per-position pinned**(고정 count 아님). 7 경계와 리전 헬퍼가 모두 이 도메인을 쓴다.
- **`assertPinnedPrefixRuntime` 확장(보강 9)**: 기존 "고정 프리픽스 연속"(비고정 뒤에 고정이 없음 = I1)에 더해 **핀 경계 =
  그룹(최상위 단위) 경계 정렬**을 런타임 assert(핀 경계가 subtree 중간을 자르지 않음 = I3 안전 전제). 정렬 판정은 **순수 함수
  `pinBoundariesAlignGroups()`에 위임**한다 — assert(panic)와 헤드리스 테스트(GP4(b))가 **같은 판정을 공유**하도록. 판정 구조는
  `normalizePinnedFromGroups`와 **동형(suffix-exclusion)**: 각 최상위 그룹 구조 subtree `[i,e)`에서 마커 pin이 마지막으로 일치하는
  `last_match`까지의 진짜 멤버 범위 안에 다른 pin 카드가 끼면(desync 샌드위치) `false`, canonical(normalize 후)은 항상 `true`,
  꼬리 top카드는 다음 리전이 다룬다. 호출처: `toggleGroupPin`·`applyWorkspaceWindow`(복원) 뒤 디버그 게이트.
- **헤드리스**: ① **identity byte-identical**(고정 그룹 0개면 리전 경계=양끝 → 기존 projectRows/SG3~SG8 회귀 0, `test "GP1: …"`).
  ② **7 경계**: "고정 그룹(마커 pinned=1) + 비고정 최상위 카드 + 비고정 그룹" 인위 배치로 비고정 카드가 안 삼켜지고(#4·#1)
  고정 접힘 뒤 안 숨고(#2) `(N)` 안 오염(#6) depth 리전별 정확(#3)함을 단언(GP1). ③ **정규화·안착**: shred→canonical·복원
  순서·마커 pinned 승계(GP2)·suffix-exclusion tension 해소·개별 pin 위임·`toggleGroupPin`·`clampGroupMoveToRegion` 프리뷰=확정
  (GP3). ④ **렌더**: `pin_derived`·`sidebarRowShowsPin`·`pinBoundariesAlignGroups` desync 검출/흡수(GP4).

### 12.12 단계 GP1~5

1. **GP1 — pin-region-aware 파생 토대(동작 보존, 그룹 고정 토글 없음) ✅**: 7 subtree-스캔에 pin-region 리셋/경계 +
   `firstGroupStartInRegion`·`pinRegionBounds`·`enclosingGroupMarkerIndex` 핀 클램프 + 8 호출처. 고정 그룹 0개면 byte-identical(§12.11 ①),
   인위 배치로 7 경계 단언(§12.11 ②). `toggleGroupPin`·정규화·clamp·`pin_derived`·UX는 **미포함**(파생 코어가 pin-region을
   **인식**하는 토대만).
2. **GP2 — `normalizePinnedFromGroups` + 복원 순서(§12.5) ✅**: shred → canonical(suffix-exclusion). `stablePartition`/`togglePin`
   회귀 0. 복원은 normalize→`stablePartitionPinned` 순서, 마커 pinned 승계(`inheritGroupMarker`), 드래그 게이트.
3. **GP3 — `toggleGroupPin` + plan 산출부 단일 clamp(§12.6) + 헤더 항목 ✅**: 고정 그룹 비고정 드래그 → `clampGroupMoveToRegion`
   (SG8 등가 확장, 프리뷰=확정). 토글은 `stablePartitionPinned` 안착. 개별 pin 입구 차단·removeFromGroup unpin 선행.
4. **GP4 — UX(§12.8·§12.10) ✅**: `pin_derived`+`sidebarRowShowsPin`으로 멤버·마커 카드 📌 억제·헤더 인디케이터, `assertPinnedPrefixRuntime`
   확장(`pinBoundariesAlignGroups`), pane/remove 리전 정정 + macOS 스크린샷. 훅 `MARU_FORCE_GROUP_PIN`.
5. **GP5 — 잔재/문서 ✅**: §10 백로그 "그룹 고정" → C2 해소, §12 최종 동기화(§12.5 suffix-exclusion·§12.6 `stablePartitionPinned`·
   §12.8 `sidebarRowShowsPin`·§12.11 `pinBoundariesAlignGroups`), dead code 없음 확인, 회귀 매트릭스(GP1~4+SG3~SG8+pin) green.

### 12.13 리스크

- **[약점 최상]** "고정 그룹 + 비고정 최상위 카드"(§12.1) — C2 2앵커만 해소. **정정: 파생 2차 일반화 폭발은 없다**(§12.4 —
  7 경계 각 한 줄). 적대검증 1순위였고 GP1 헤드리스로 닫힘. 정규화도 이 인접을 **suffix-exclusion**으로 흡수(§12.5, GP3 tension 해소).
- **[약점]** 이중표현 정규화 누락 = shred — chokepoint 단일화 대신 **6 mutation 지점 호출 + 게이트/복원 특례**(§12.5).
- **[중]** SG8 이중경로 divergence — group clamp를 **plan 산출부 단일 clamp**(§12.6)로, `assertPinnedPrefixRuntime` 확장(§12.11
  — 순수 `pinBoundariesAlignGroups`)으로 방어.
- **[중]** 기존 테스트(`togglePin`·`clampMoveToGroup`·SG4/5/8) — 그룹 고정 0개/전부 비고정 byte-identical(GP1 identity)로 회귀 0.

**단순화 대안**(C2 churn이 과하면): **S1(Chrome식)** — 그룹 고정 폐기, 카드 pin=그룹 자동 제외(위치 파생 무변경, "그룹째
고정" UX 상실). 원리는 C2, 리스크 회피는 S1. **C2로 완결(GP1~5)** — churn이 관리 범위였고 위 방어들이 회귀 0을 유지했다.
