//! Sidebar — 세로 워크스페이스 사이드바의 hit-test + 밴드 렌더. chrome **마우스 hit-test 컴포넌트**(divider 동형 —
//! State 없는 순수 함수). 드래그 재정렬이 인덱스 기반(`sidebar_drag_index: usize`)이라 라이브 포인터 부담이
//! divider(`*Split`)보다 적다(§6). host가 중립 `Tab`(라벨·활성)을 주입하고, platform이 라이브 상태(폭·드래그
//! 인덱스·hover)·제목 glyph 렌더(`buildSidebarTitleFrame` — CoreText는 platform 책임)·밴드 fill lowering을 맡는다.
//! 이 컴포넌트는 (1) hit-test 순수 함수(옛 app_session의 xInSidebar 등 이전)와 (2) 밴드 view(활성/호버 fill)를
//! 단일 출처로 든다. 단일 출처: docs/chrome-strategy.md §5.4, docs/layering-and-portability.md §5(C3a).

const std = @import("std");
const draw = @import("../draw.zig");
const props = @import("../props.zig");
const tokens = @import("../tokens.zig");

/// 이 컴포넌트가 그리는 레이어 — 사이드바(가장 아래 Z, 터미널 strip 왼쪽). platform이 밴드 fill을 lower해 sidebar 셀 슬롯에.
pub const layer = draw.Layer.sidebar;

/// host(projectRows)가 주입하는 사이드바 화면 **한 줄(row)**. 카드일 수도 그룹 헤더일 수도 있다 — hit-test/view는
/// row가 어느 종류인지만 보고 균일하게 처리해 "슬롯=카드=탭 인덱스" 1:1 가정을 없앤다(docs/sidebar-groups.md §2.2).
/// SG1에선 card만 생성해 동작을 보존하고(그룹 없음), group_header는 SG3에서 채운다. 라벨 glyph 렌더는 platform
/// (`buildSidebarDrawList`)이 맡고(CoreText 경계), chrome은 밴드(fill)·hit-test만 든다.
pub const Row = union(enum) {
    /// 워크스페이스 카드. tab=원본 self.tabs 인덱스(옛 visibleTab 값), active=활성 워크스페이스,
    /// depth=그룹 안이면 1(들여쓰기 — SG3). label은 제목 glyph 완전 이주(후속) 시 view가 text op으로 쓸 자리다.
    /// pin_derived=이 카드의 `tab.pinned`가 **그룹 고정에서 파생된 캐시**(멤버)인가(그룹 고정 C2 — docs/sidebar-groups-pinning.md §12.8).
    /// 멤버 카드 pinned는 enclosing 마커의 권위를 미러한 값이라(§12.2), 그대로 렌더하면 모든 멤버에 📌 노이즈가 뜬다.
    /// projectRowsCore가 order-aware로(depth/member_count와 동형) 채운다 — **비마커 그룹 멤버=true**(파생 억제 대상),
    /// **그룹 마커 카드·최상위 개별 pin 카드=false**(마커는 권위·헤더가 인디케이터, 최상위는 자기 pin). buildSidebarDrawList가
    /// live `tab.pinned` 대신 이 힌트를 읽어 멤버 📌를 억제한다. depth와 달리 "마커 카드 vs 멤버 카드"를 구별한다(둘 다 depth>0).
    /// local_pinned=이 카드가 **그룹-로컬 pin된 멤버**(그룹 내 위치 고정, GL — docs/sidebar-groups-pinning.md §13.6)인가. pin_derived가
    /// 모든 멤버 📌를 억제하는 것과 달리, 로컬 pin은 **실제 사용자 pin**이라 sidebarRowShowsPin이 **선두 분기**(pin_derived보다
    /// 먼저)로 📌를 살린다. projectRowsCore가 비마커 그룹 멤버 카드에만 `tab.local_pinned`로 채운다(마커 카드·최상위 카드=false —
    /// 로컬 pin은 leaf 멤버에서만 의미, §13.8). pin_derived와 **직교**한다(그룹째 고정 그룹 안 로컬 pin 멤버는 둘 다 true 가능).
    /// lines=이 카드가 **실제로 그리는 줄 수**(이름 + 브랜치? + 경로? + 상태?). 카드 높이가 고정 슬롯이 아니라 이
    /// 값에서 나오므로(docs/sidebar-agent-list.md §3), host가 렌더에 쓰는 줄 수와 **같은 값**을 실어야 한다 —
    /// 어긋나면 클릭 좌표와 렌더 좌표가 갈려 "보이는 곳과 눌리는 곳이 다른" 회귀가 난다. 기본 1(이름줄만).
    card: struct { tab: usize, label: []const u8, active: bool, depth: u8 = 0, pin_derived: bool = false, local_pinned: bool = false, lines: u8 = 1 },
    /// 그룹 헤더(SG3) — 접기 토글 줄(카드 아님). collapsed=접힘, member_count=접힘 시 "▸ name (N)" 표시용.
    /// tab=이 그룹을 **시작하는 원본 self.tabs 인덱스**(group_start 마커를 든 탭). 헤더 클릭 시 그 탭의 group_collapsed를
    /// 토글하고(onGroupHeader), platform이 라벨 glyph를 그 탭의 `group_start`에서 **직접 라이브로** 뽑는다(label은
    /// borrowed라 destroyTab 후 dangling 위험 — code-review #8 UAF 해소: 소스 tab 인덱스를 실어 live 재조회).
    /// depth=이 그룹의 정규화 깊이(SG5-3 중첩 — 1=최상위, 2=중첩, …). 헤더 삼각/이름 glyph는 platform이 (depth-1)*group_indent
    /// 만큼 들여쓴다(소속 카드는 depth*group_indent). 밴드(view)는 depth 무관 전폭(카드 밴드와 동형).
    /// has_color=이 그룹에 그룹 색(SG5-2)이 지정됐는가. **기본(무색) 헤더는 밴드(보더라인) 없이 화살표+이름만** 남기고
    /// (사용자 결정 — docs/sidebar-groups.md §5), 색이 지정된 그룹만 view가 헤더 밴드를 내 lowerSidebar가 그 색으로
    /// tint한다(색 구분 유지). host(projectRows)가 tab.group_color!=0로 채운다 — chrome은 role 기반이라 RGB를 못 실어
    /// "밴드를 낼지"만 판단하고, 실제 색 blend는 platform이 tab.group_color로 한다(층 분리). hover/active 밴드는 has_color와
    /// 무관하게 그대로(상호작용 하이라이트는 보더라인이 아니라 피드백이라 카드와 같은 경로로 유지).
    group_header: struct { collapsed: bool, label: []const u8, member_count: u16, tab: usize, depth: u8 = 0, has_color: bool = false },
    /// 카드 하위 **에이전트 목록 토글**(`N agents`) — 에이전트가 **2개 이상**일 때만 방출한다(1개면 행 하나만 붙고
    /// 토글이 없다, docs/sidebar-agent-list.md §1). tab=소속 워크스페이스의 원본 인덱스(클릭 시 그 탭의
    /// `agents_collapsed`를 토글한다 — group_header와 같은 규율). count=그 워크스페이스의 에이전트 수.
    /// last=이 행이 그 카드 묶음의 **마지막 행**인가(접혀서 토글만 남은 경우). 마지막 행은 아래 여백을 카드와 같게
    /// 잡아 밴드 하단이 좁아지지 않게 한다(사용자 피드백 — 목록 행을 촘촘하게 만든 부작용).
    agent_toggle: struct { tab: usize, count: u16, collapsed: bool, depth: u8 = 0, last: bool = false },
    /// 에이전트 한 줄 — **Term 하나가 행 하나**다(§2). 표시 텍스트(kind·상태·시각·폴더·브랜치·마지막 대화)는
    /// **싣지 않는다**: borrowed 슬라이스는 Term이 사라지면 dangling이고(group_header label에서 겪은 UAF),
    /// 상태·시각은 매 tick 변하므로 platform이 이 인덱스 경로로 **라이브 재조회**해 그린다.
    /// pane/term=그 워크스페이스 안의 인덱스 경로(클릭 라우팅이 워크스페이스 → Pane → Term 순으로 쓴다).
    /// lines=이 행이 그리는 줄 수(라벨 / 폴더·브랜치 / 마지막 응답) — 카드와 같은 규율로 행 높이가 여기서 나온다.
    /// last=이 행이 그 카드 묶음의 마지막 행인가(위 `agent_toggle.last`와 같은 목적).
    agent: struct { tab: usize, pane: usize, term: usize, depth: u8 = 0, lines: u8 = 2, last: bool = false },
    /// App-global session-host recovery projection의 typed system header. 사용자 그룹이 아니므로 tab/name/drag
    /// identity를 싣지 않는다. primary Window만 이 variant를 materialize한다.
    recovered_sessions_header,
    /// `Recovered Sessions` 아래의 inert candidate. projection_index만 싣고 platform이 app-global canonical row를
    /// live 재조회한다. CR6a-2에서는 클릭/Enter/action이 없고 CR6b가 이 typed identity에 adopt를 붙인다.
    recovered_session: struct { projection_index: usize, lines: u8 = 1 },
};

/// row_index가 그룹 헤더 row인가(클릭 시 선택이 아니라 접기 토글 대상). closeButton과 같은 결의 순수 hit-test
/// 헬퍼 — host(mouseDown)가 slotAt로 얻은 row가 헤더면 group_collapsed 토글로 분기한다(docs/sidebar-groups.md §5·§7).
pub fn onGroupHeader(rows: []const Row, row_index: usize) bool {
    if (row_index >= rows.len) return false;
    return rows[row_index] == .group_header;
}

// ── hit-test (옛 app_session 순수 함수 이전, 같은 수학) ────────────────────────

/// x(backing px)가 세로 사이드바 영역(0..width) 안인가. 폭 0·x<0·width 이상이면 false.
pub fn inSidebar(x_px: f64, sidebar_width_px: u32) bool {
    return sidebar_width_px > 0 and x_px >= 0 and x_px < @as(f64, @floatFromInt(sidebar_width_px));
}

/// x가 사이드바 우측 경계(폭조절 드래그) 밴드 [width, width + cell절반+2px) 안인가 — 터미널 쪽으로만(슬롯/✕와 안 겹침).
/// 폭 0·cell 0·비유한이면 false. cell==0은 렌더 전 degenerate 상태 — platform 호출처가 sibling(pxToCell·imeCursorRect)과
/// 일관되게 placeholder 폭을 적용해 넘기므로(chrome은 placeholder 상수를 모른다) 여기선 단순히 false로 둔다.
pub fn onResizeEdge(x_px: f64, sidebar_width_px: u32, cell_width_px: u32) bool {
    if (sidebar_width_px == 0 or cell_width_px == 0 or !std.math.isFinite(x_px)) return false;
    const edge: f64 = @floatFromInt(sidebar_width_px);
    const margin = @as(f64, @floatFromInt(cell_width_px)) / 2 + 2;
    return x_px >= edge and x_px < edge + margin;
}

/// 사이드바 y(backing px) → row 인덱스(**가변 높이 누적** — 카드=card_slot_h·그룹 헤더=header_row_h). 사이드바 헤더
/// (검색바·아이콘) 영역 y<header_height_px는 null. rows 빈·비유한·콘텐츠 아래 빈 영역이면 null. header_height_px=0이면
/// 사이드바 헤더 없음(콘텐츠가 y=0부터). scroll_offset_px는 콘텐츠가 위로 밀린 양 — 화면 y의 row는 콘텐츠 좌표
/// (y-header+scroll)로 역산한다. 사이드바 헤더는 스크롤 무관 고정이라 y<header 판정엔 scroll을 안 더한다("보이는=클릭되는").
/// 각 row 높이를 누적하며 콘텐츠 y가 드는 row를 찾는다(고정 나눗셈 대신 — 헤더/카드 높이가 달라서). 카드만이면 균일과 동일.
pub fn slotAt(y_px: f64, header_height_px: u32, rows: []const Row, m: Metrics, scroll_offset_px: u32) ?usize {
    if (rows.len == 0 or !std.math.isFinite(y_px)) return null;
    const h: f64 = @floatFromInt(header_height_px);
    if (y_px < h) return null; // 사이드바 헤더(검색바·아이콘) 영역 — row 아님(스크롤 무관, 고정)
    const content = y_px - h - @as(f64, @floatFromInt(m.content_pad_v)) + @as(f64, @floatFromInt(scroll_offset_px));
    if (content < 0) return null; // 목록 위 여백 = row 아님(카드가 없는 자리)
    var acc: f64 = 0;
    for (rows, 0..) |r, i| {
        const rh: f64 = @floatFromInt(rowHeight(r, m));
        if (rh <= 0) continue;
        if (content < acc + rh) return i;
        acc += rh;
    }
    return null; // 콘텐츠 아래 빈 영역
}

// ── 가변 높이 프리미티브(SG3b — 헤더=얇은 한 줄 header_row_h, 카드=card_slot_h; docs/sidebar-groups.md §5) ──────
// 헤더 row가 카드보다 낮으므로 y↔row를 고정 나눗셈이 아니라 **각 row 높이를 누적**해 환산한다. slotAt/dragTargetSlot가
// 위에서 이 누적을 쓰고, 옛 고정 slotTop(index*slot_h)은 rowTop으로 대체됐다(app_session의 배지·rename caret도 rowTop 사용).

/// 사이드바 세로 레이아웃 메트릭. 카드 높이가 **줄 수에 따라 달라지므로**(docs/sidebar-agent-list.md §3) 고정 슬롯
/// 하나가 아니라 줄 기하를 나른다. `init`이 cell 높이에서 파생하는 단일 출처 — platform도 이걸 불러 같은 값을 쓴다
/// (예전엔 줄 스텝·블록 높이 공식이 platform에만 있어 chrome은 높이를 계산할 수 없었다).
pub const Metrics = struct {
    /// 한 줄(글자) 높이 = cell 높이.
    line_h: u32,
    /// 줄과 줄 사이 세로 스텝(line_h + 여유).
    line_step: u32,
    /// 카드 위/아래 **각각**의 여백.
    card_pad_v: u32,
    /// 그룹 헤더 row 높이(얇은 한 줄 — 카드 줄 수와 무관한 별도 값).
    header_row_h: u32,
    /// 목록 **전체**의 위/아래 여백 — 첫 카드가 검색바에 붙고 마지막 카드가 바닥에 붙는 답답함을 없앤다(사용자 피드백).
    /// row 사이 간격이 아니라 콘텐츠 블록의 바깥 여백이라 `rowTop`·`slotAt`·`contentHeight`가 함께 반영해야
    /// "보이는 곳 = 눌리는 곳"이 유지된다.
    content_pad_v: u32,
    /// **에이전트 목록 행**(토글·에이전트)의 위/아래 여백 — 카드보다 촘촘하다. 목록은 행이 연달아 쌓이므로 카드와
    /// 같은 여백을 주면 통째로 성기고 스크롤이 길어진다(사용자 피드백). 카드는 서로 떨어져 있어야 구분되지만,
    /// 목록 행은 한 카드에 딸린 묶음이라 붙어 있는 편이 읽기 좋다.
    list_pad_v: u32,

    pub fn init(cell_height_px: u32, header_row_h: u32) Metrics {
        return .{
            .line_h = cell_height_px,
            .line_step = lineStep(cell_height_px),
            .card_pad_v = cardPadV(cell_height_px),
            .header_row_h = header_row_h,
            .content_pad_v = cell_height_px * 3 / 4,
            .list_pad_v = cell_height_px * 25 / 100,
        };
    }
};

/// 줄과 줄 사이 세로 스텝 = cell + 15%(최소 1px). 여러 줄 카드가 답답해 보이지 않게 하는 여유다.
pub fn lineStep(cell_height_px: u32) u32 {
    return cell_height_px +| @max(1, cell_height_px * 15 / 100);
}

/// 카드 위/아래 각각의 여백 = cell × 0.7.
/// **베이스/결정**: 처음엔 0.375였다 — 옛 고정 슬롯(cell × 5.2)에서 **4줄 카드**(이름·브랜치·경로·상태)가 차지하던
/// 여백과 같게 잡아 겉모습을 보존하려는 값이었다. 그런데 상태줄이 카드에서 **에이전트 목록 행으로 이동**해
/// (docs/sidebar-agent-list.md §2) 4줄 카드 자체가 사라졌고, 남은 1~3줄 카드에서는 글자가 밴드 위아래에 붙어
/// 답답했다(사용자 피드백). 4줄 동등성이 지킬 대상이 아니게 됐으므로 **읽기 편한 값**으로 올린다.
pub fn cardPadV(cell_height_px: u32) u32 {
    return cell_height_px * 700 / 1000;
}

/// `lines` 줄이 차지하는 블록 높이 = (lines−1)×step + line_h(마지막 줄 뒤엔 스텝 여유가 없다).
pub fn blockHeight(lines: u32, m: Metrics) u32 {
    if (lines == 0) return m.line_h;
    return (lines -| 1) *| m.line_step +| m.line_h;
}

/// 카드 한 장의 높이 = 줄 블록 + 위아래 여백.
pub fn cardHeight(lines: u8, m: Metrics) u32 {
    return blockHeight(lines, m) +| 2 *| m.card_pad_v;
}

/// 에이전트 목록 행의 높이 = 줄 블록 + 위 `list_pad_v` + 아래(마지막 행이면 `card_pad_v`, 아니면 `list_pad_v`).
/// 마지막 행만 넉넉한 이유는 위 `rowHeight` 주석 참고(밴드 하단 여백).
pub fn listRowHeight(lines: u8, m: Metrics, last: bool) u32 {
    const below = if (last) m.card_pad_v else m.list_pad_v;
    return blockHeight(lines, m) +| m.list_pad_v +| below;
}

/// 목록 행(토글·에이전트) **호버 밴드가 행 안에서 차지하는 세로 구간**(행 상단 기준 offset·높이) =
/// 행 높이에서 위아래 `list_pad_v/2`만 들인 값. 즉 **밴드 ≈ 클릭되는 행**이다.
///
/// **베이스/결정**: 밴드를 `card_gap`만큼 들여 만들지 **않는다**. `card_gap`(rich=8px 고정)은 *카드끼리* 떨어뜨리는
/// 간격이라 84px 카드에선 티가 안 나지만, 목록 행은 높이가 글자 블록 + `list_pad_v`(≈cell×0.25)뿐이라 위아래에서
/// 그만큼 빼면 밴드가 글자보다 **작아진다** — 실측(cell 18px)에서 1줄 토글 행 26px 중 20px이 인셋으로 날아가 6px
/// 띠만 남았고, 그 띠가 글자 한가운데를 가로질러 "호버 하이라이트"가 아니라 밑줄처럼 보였다(사용자 제보).
///
/// 들이는 양을 `list_pad_v/2`로 **작게** 두는 두 번째 이유: 호버 하이라이트는 "지금 누르면 이게 눌린다"는 표시라
/// **클릭 판정(`slotAt`)이 쓰는 행 전체**와 눈에 띄게 달라선 안 된다(밴드는 작은데 그 밖을 눌러도 반응하면 어긋난
/// 것으로 읽힌다 — 사용자 제보). 그래도 0으로 두지 않는 건 위아래 행 밴드가 맞닿으면 어느 행을 가리키는지 흐려지기
/// 때문이다. 행 높이 = 글자 블록 + 위아래 여백(≥`list_pad_v`)이므로 이 인셋이면 **글자 블록은 항상 밴드 안**이다.
pub fn listRowBandV(row_h: u32, m: Metrics) struct { top: u32, h: u32 } {
    const gap = m.list_pad_v / 2;
    return .{ .top = gap, .h = row_h -| 2 *| gap };
}

/// row 하나의 세로 높이(px). 카드=줄 수에서 계산, 그룹 헤더=header_row_h(얇은 한 줄). 가변 누적의 단위.
pub fn rowHeight(row: Row, m: Metrics) u32 {
    return switch (row) {
        .card => |c| cardHeight(c.lines, m),
        .group_header => m.header_row_h,
        // 목록 행(토글·에이전트)은 카드와 **같은 줄 블록 규칙**을 쓰되 여백만 `list_pad_v`로 촘촘하게 잡는다.
        // 단 **마지막 행의 아래 여백만 카드와 같게** 준다 — 밴드가 카드+목록을 한 덩어리로 덮으므로, 마지막 행이
        // 촘촘한 여백을 그대로 쓰면 글자가 밴드 하단에 붙는다(사용자 피드백).
        .agent_toggle => |t| listRowHeight(1, m, t.last),
        .agent => |a| listRowHeight(a.lines, m, a.last),
        .recovered_sessions_header => m.header_row_h,
        .recovered_session => |r| listRowHeight(r.lines, m, true),
    };
}

/// row_index가 에이전트 목록 토글 행인가(클릭 시 선택이 아니라 접기 토글 대상 — `onGroupHeader`와 같은 결).
pub fn onAgentToggle(rows: []const Row, row_index: usize) bool {
    if (row_index >= rows.len) return false;
    return rows[row_index] == .agent_toggle;
}

/// row_index가 에이전트 행이면 그 인덱스 경로(tab/pane/term)를, 아니면 null. host(mouseDown)가 이걸로
/// 워크스페이스 → Pane → Term 이동을 수행한다. **포인터가 아니라 인덱스**라 사이 tick에 Term이 사라져도
/// 재조회에서 걸러진다(stale deref 금지 — docs/sidebar-agent-list.md §5).
pub fn agentAt(rows: []const Row, row_index: usize) ?struct { tab: usize, pane: usize, term: usize } {
    if (row_index >= rows.len) return null;
    return switch (rows[row_index]) {
        .agent => |a| .{ .tab = a.tab, .pane = a.pane, .term = a.term },
        else => null,
    };
}

/// 카드 `index`에 딸린 **에이전트 목록까지 포함한 span의 끝**(반열림 `[index, end)`). 카드 뒤에 이어지는
/// `agent_toggle`/`agent` row가 끝나는 지점이다 — 목록은 그 워크스페이스의 부속이라 활성 밴드·배경 tint·좌측
/// accent 막대가 전부 이 범위를 한 덩어리로 쓴다(카드에서 끊기면 "어디까지가 이 워크스페이스인지"가 안 보인다).
/// 카드가 아닌 row나 범위 밖이면 자기 자신 하나(`index+1`)로 포화한다.
pub fn cardSpanEnd(rows: []const Row, index: usize) usize {
    var end = index + 1;
    while (end < rows.len) : (end += 1) switch (rows[end]) {
        .agent_toggle, .agent => {},
        else => break,
    };
    return end;
}

/// `[from, to)` row 구간의 **슬롯 상대 rect**(x=0, w=사이드바 폭, y=앞선 row 높이 누적, h=구간 높이 합).
/// 밴드(`bandFillSpan`)·platform의 per-card 배경 tint·좌측 accent 막대·드래그 고스트가 **모두 이 함수 하나**를
/// 쓴다 — 예전엔 chrome이 `rowTop`+`rowHeight` 누적으로, platform이 같은 누적을 따로 계산해 두 벌을 들고 있었고,
/// 한쪽 인셋만 바꾸면 막대가 밴드 안쪽에 떠 보이는 드리프트가 실제로 났다(docs/sidebar-agent-list.md §3.2).
/// `from >= rows.len`(목록 아래 "새 워크스페이스" 행)이면 **기본 1줄 카드 높이**로 둔다(옛 고정 slot_h 자리).
/// 절대 y가 필요한 호출자(platform)는 여기에 사이드바 헤더 높이를 더한다 — 헤더 시프트는 그쪽 단일 책임이다.
pub fn spanRect(rows: []const Row, from: usize, to: usize, w: u32, m: Metrics) draw.Rect {
    const top: i64 = rowTop(rows, from, 0, m, 0); // 슬롯 상대(헤더·스크롤 제외), ≥0
    var h: u32 = 0;
    if (from >= rows.len) {
        h = cardHeight(1, m);
    } else {
        var i = from;
        while (i < to and i < rows.len) : (i += 1) h +|= rowHeight(rows[i], m);
    }
    return .{ .x = 0, .y = @intCast(top), .w = w, .h = h };
}

/// row 인덱스의 화면 상단 y(backing px) — 옛 slotTop의 가변판(고정 `index*slot_h` 대신 앞 row 높이 누적).
/// header + Σ(rows[0..index] 높이) − scroll. index≥rows.len이면 전체 콘텐츠 하단(모든 row 합) 기준. i64라 음수(위로 밀림) 안전.
pub fn rowTop(rows: []const Row, index: usize, header_height_px: u32, m: Metrics, scroll_offset_px: u32) i64 {
    var off: i64 = 0;
    const n = @min(index, rows.len);
    for (rows[0..n]) |r| off += @as(i64, rowHeight(r, m));
    return @as(i64, header_height_px) + @as(i64, m.content_pad_v) + off - @as(i64, scroll_offset_px);
}

/// **그 슬롯이 보이게 하는 새 스크롤 offset** — 이미 보이면 지금 값을 그대로 돌려준다.
///
/// 파일을 열거나 세션을 활성으로 만들면 그 카드가 화면 밖일 수 있다. 그때 **활성 표시만 옮기고
/// 화면을 안 움직이면** 사용자에게는 "눌렀는데 아무 일도 안 났다" 로 보인다(계획서 W8.18⒜).
///
/// **가장 적게 움직인다**(편집기 `viewport.scrollToRow` 와 같은 규율): 위로 벗어났으면 카드 위
/// 끝을, 아래로 벗어났으면 아래 끝을 뷰포트에 맞춘다. 카드가 뷰포트보다 크면 **위를 맞춘다** —
/// 아래를 맞추면 이름이 있는 첫 줄이 화면 밖으로 나간다.
///
/// `view_h_px` 는 **헤더를 뺀** 목록 뷰포트 높이다(헤더는 고정이라 스크롤에 안 든다 — `slotAt` 이
/// 정한 그 규칙). 카드 구간은 `cardSpanEnd` 가 정한다(에이전트 줄까지 한 카드다).
pub fn scrollToSlot(rows: []const Row, slot: usize, m: Metrics, view_h_px: u32, scroll_offset_px: u32) u32 {
    if (slot >= rows.len or view_h_px == 0) return scroll_offset_px;
    // **자리는 `spanRect` 가 소유한다** — 여기서 높이를 다시 누적하면 밴드와 갈린다(그 함수 doc 이
    // 겪은 그 드리프트다).
    const r = spanRect(rows, slot, cardSpanEnd(rows, slot), 0, m);
    const top: i64 = r.y;
    const bottom: i64 = top + @as(i64, r.h);
    const view_h: i64 = @intCast(view_h_px);
    const max_scroll: i64 = @intCast(contentHeight(rows, m) -| view_h_px);
    var off: i64 = @intCast(scroll_offset_px);
    // **큰 카드는 위를 먼저 본다.** 아래 끝을 맞추는 가지에 먼저 걸리면 이름이 있는 첫 줄이
    // 화면 밖으로 나간다(실측: `expected 40, found 100`).
    if (top < off or r.h > view_h_px) {
        off = top;
    } else if (bottom > off + view_h) {
        off = bottom - view_h;
    }
    return @intCast(std.math.clamp(off, 0, max_scroll));
}

/// 표시 콘텐츠 전체 높이(px) — 모든 row 높이 합(옛 `rows.len*slot_h`의 가변판). 세로 스크롤 clamp(sidebarMaxScroll)용.
/// u32 포화(비현실적으로 많은 row에서도 trap 없이 상한)로 clamp 계산이 degenerate하지 않게 한다.
pub fn contentHeight(rows: []const Row, m: Metrics) u32 {
    var acc: u64 = 2 * @as(u64, m.content_pad_v); // 목록 위·아래 여백도 콘텐츠 높이에 든다(스크롤 끝에서 잘리지 않게)
    for (rows) |r| acc += rowHeight(r, m);
    return @intCast(@min(acc, @as(u64, std.math.maxInt(u32))));
}

/// 헤더 줄0 우측 **단일-셀 아이콘**의 glyph col(우측부터 +·⚙·◧). render(buildSidebarHeaderFrame)·단축키 배지가 같은
/// col을 쓰게 하는 단일 출처(예전엔 cols-2/-5/-8을 곳곳에 하드코딩). hit-test(headerHit)는 글리프 col이 아니라 **zone
/// 경계**(cols-3/-6/-9)를 별도로 둔다(클릭 영역은 글리프보다 넓다 — 의도적 분리).
/// 알림 종(🔔)은 EAW 2칸 이모지라 별도 경로(appendBellAndBadge, 좌단 cols-12). 우측 1칸(cols-1)은 패딩.
pub const HeaderIcon = enum { new_workspace, view_options, toggle_sidebar };
pub fn headerIconCol(icon: HeaderIcon, cols: u32) u32 {
    return switch (icon) {
        .new_workspace => cols - 2,
        .view_options => cols - 5,
        .toggle_sidebar => cols - 8,
    };
}

/// 헤더 줄 수(신호등 높이 흡수). render(buildSidebarHeaderFrame)·IME caret(sidebarSearchCaretRect)·hit-test(headerHit)가
/// 같은 값을 써야 아이콘·검색 glyph·caret·클릭 영역이 같은 줄에 놓인다(§5.4 단일 레이아웃 소스 — 셋이 따로 계산하면 어긋난다).
/// 아이콘은 줄0, 검색은 마지막 줄(headerRows-1), 사이 줄은 비운다.
pub fn headerRows(header_height_px: u32, cell_height_px: u32) u32 {
    if (cell_height_px == 0) return 2;
    return @max(@as(u32, 2), header_height_px / cell_height_px);
}

/// 헤더의 두 밴드 경계. **아이콘 줄 = [0, icon_band_px), 검색 줄 = [icon_band_px, header_height_px).**
///
/// 예전에는 두 줄을 셀 row 인덱스로 갈랐는데(`headerRows() - 1`), 그러면 줄 위치가 terminal 폰트에 묶여 창 오른쪽
/// 밴드(신호등 띠 / 탭 바)와 어긋난다(docs/file-explorer.md §3.5). 밴드는 platform이 그 두 바와 **같은 출처**
/// (`titlebar_strip_px`, `chromeBarHeightPx`)에서 계산해 넘긴다 — chrome은 경계만 판정한다.
///
/// `icon_band_px`가 0이거나 헤더보다 크면 옛 동작(마지막 셀 줄이 검색)으로 떨어진다. 그 값은 platform이 아직
/// 띠를 못 잡은 초기 프레임에서만 나오므로, 여기서 fail-close하면 헤더가 통째로 클릭 불가가 된다.
pub fn headerSearchBandTop(header_height_px: u32, icon_band_px: u32, cell_height_px: u32) u32 {
    if (icon_band_px > 0 and icon_band_px < header_height_px) return icon_band_px;
    if (cell_height_px == 0) return 0;
    return (headerRows(header_height_px, cell_height_px) - 1) * cell_height_px;
}

/// 사이드바 상단 헤더([0, header_h) 영역)의 어느 부분을 가리키는가. **아이콘 줄(row 0)**: 우측 아이콘 4개(셀 col
/// cols-2=새 워크스페이스, cols-5=view options, cols-8=사이드바 접기, cols-11=알림 종(EAW 2칸이라 cols-11·cols-10 점유)),
/// 좌측은 네이티브 신호등
/// (닫기·최소화·확대) 영역이라 none(macOS가 클릭 소비). **검색 줄(마지막 줄)**: 전체 폭 검색 입력. 사이 빈 줄·헤더 밖·
/// 폭/cell 0·비유한·cols<13(아이콘 4개가 안 들어감)은 none. 영역 경계는 buildSidebarHeaderFrame이 glyph를 그리는 cell
/// row/col(floor cols)과 정확히 같게 잡는다 — 안 그리면 hit-test도 none(그려진 것=클릭되는 것 단일 출처).
pub const HeaderRegion = enum { none, search, view_options, new_workspace, toggle_sidebar, notifications };
pub fn headerHit(x_px: f64, y_px: f64, sidebar_width_px: u32, cell_width_px: u32, cell_height_px: u32, header_height_px: u32, icon_band_px: u32) HeaderRegion {
    if (header_height_px == 0 or sidebar_width_px == 0 or cell_width_px == 0 or cell_height_px == 0) return .none;
    if (!std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return .none;
    const h: f64 = @floatFromInt(header_height_px);
    if (y_px < 0 or y_px >= h) return .none;
    if (x_px < 0 or x_px >= @as(f64, @floatFromInt(sidebar_width_px))) return .none;
    const cw: f64 = @floatFromInt(cell_width_px);
    const ch: f64 = @floatFromInt(cell_height_px);
    const cols: u32 = sidebar_width_px / cell_width_px; // buildSidebarHeaderFrame과 같은 floor — 아이콘 col 정합
    if (cols < 13) return .none; // 헤더 glyph 4개(종·◧·⚙·+)가 안 들어가는 폭 — 안 그리면 hit-test도 none(단일 출처)
    // 밴드 경계는 렌더(검색 frame origin)와 **같은 단일 출처**다 — 셀 row로 가르면 terminal 폰트에 묶여 오른쪽
    // 탭 바와 어긋난다(docs/file-explorer.md §3.5).
    const search_top: f64 = @floatFromInt(headerSearchBandTop(header_height_px, icon_band_px, cell_height_px));
    if (y_px >= search_top) return .search; // 상단 바 밴드 = 검색(그려진 🔍/입력 줄)
    // 아이콘 줄은 띠 밴드 **안에서 세로 중앙**에 한 셀 줄로 그려진다(렌더러가 `(띠 - 셀) / 2`만큼 내린다).
    // hit도 그 사각형이어야 "그려진 것 = 클릭되는 것"이 성립한다 — 예전처럼 `[0, ch)`로 두면 띠가 셀보다 높은
    // 만큼 클릭 영역이 아이콘보다 위로 밀린다. 띠 위아래로 남는 부분은 빈 영역 = 창 드래그다.
    const icon_top: f64 = if (search_top > ch) (search_top - ch) / 2 else 0;
    if (y_px < icon_top or y_px >= icon_top + ch) return .none;
    if (x_px >= @as(f64, @floatFromInt(cols - 3)) * cw) return .new_workspace; // 줄0 우측, 그려진 '+' col(cols-2) 포함 3칸 zone
    if (x_px >= @as(f64, @floatFromInt(cols - 6)) * cw) return .view_options; // 그려진 ⚙ col(cols-5) 포함 3칸 zone
    if (x_px >= @as(f64, @floatFromInt(cols - 9)) * cw) return .toggle_sidebar; // 그려진 ◧ col(cols-8) 포함 3칸 zone
    if (x_px >= @as(f64, @floatFromInt(cols - 12)) * cw) return .notifications; // 그려진 종(cols-11·cols-10)+배지(cols-12) 포함 3칸 zone[cols-12,cols-9)
    return .none; // 줄0 좌측 = 네이티브 신호등 영역(클릭은 macOS가 소비) 또는 빈 영역
}

/// x가 사이드바 슬롯의 닫기(✕) zone(우측 2칸) 안인가 — 호버 시 ✕를 그 자리에 그리므로 그 폭만큼을 닫기 영역으로 본다.
/// 마지막 활동 시각을 사이드바 폭에 맞는 **짧은 상대 표기**로(`now`·`5m`·`3h`·`2d`).
///
/// 절대 시각(`14:23`)이 아니라 상대인 이유: 이 줄이 답하는 질문은 "언제였나"가 아니라 **"얼마나 됐나"**다 —
/// 방금 멈춘 에이전트와 어제 멈춘 에이전트를 한눈에 가르는 게 목적이고, 정확한 시각이 필요하면 그 자리로 가면 된다.
///
/// 폭을 **최대 4칸**으로 묶는다. 이 표기는 행 우측에 고정 폭으로 자리를 잡고 제목이 그만큼 일찍 잘리므로, 폭이
/// 들쭉날쭉하면 제목 잘리는 지점이 행마다 달라져 목록이 어수선해진다. 그래서 큰 값은 `99d`에서 멈춘다 —
/// 그보다 오래된 것에 하루 단위 정밀도는 의미가 없다.
///
/// **0은 sentinel이 아니다.** 방금 출력한 에이전트는 경과가 정확히 0ms일 수 있고(같은 tick에 스탬프된다),
/// 그때 빈 문자열을 내면 이 칼럼이 가장 보여주고 싶은 행 — 지금 일하는 에이전트 — 만 빈칸이 되어 `""`↔`now`로
/// 깜빡인다. "기록이 아예 없다"는 신호는 **호출부**가 낸다(활동 시각 자체가 없으면 이 함수를 부르지 않는다).
pub fn formatRelativeAge(age_ms: u64, buf: []u8) []const u8 {
    const sec = age_ms / 1000;
    if (sec < 60) return "now"; // 초 단위는 매 tick 바뀌어 눈에 거슬리고, 정보 가치도 없다
    const min = sec / 60;
    if (min < 60) return std.fmt.bufPrint(buf, "{d}m", .{min}) catch "";
    const hour = min / 60;
    if (hour < 24) return std.fmt.bufPrint(buf, "{d}h", .{hour}) catch "";
    const day = hour / 24;
    return std.fmt.bufPrint(buf, "{d}d", .{@min(day, 99)}) catch "";
}

/// `formatRelativeAge`가 쓸 수 있는 최대 칸 수. 렌더러가 이 값으로 우측 자리를 예약한다.
pub const relative_age_cols: u16 = 3;

/// 사이드바 카드 줄의 **열 배치 단일 출처**. 그리는 자리(draw list col)와 눌리는 자리(x_px zone)를 이 하나가
/// 낸다 — `dock_view_bar.slotRect`가 렌더·hover·클릭에 대해 하는 역할과 같다.
///
/// **왜 필요했나**: 예전에는 ✕를 그리는 쪽이 "칸 인덱스"(`cols - 3`)로, 누르는 쪽이 "폭에서 역산"(`w - 3cw`)으로
/// 각자 표현했다. 두 식이 같은 답을 내려면 gutter=0·indent=0이고 `w % cw == 0`이어야 하는데 셋 다 참이 아니다.
/// 스크롤바 gutter가 상시 예약되면서(SV4a) 그리는 쪽만 좁아졌고, 실측 348px·cw 8·gutter 11에서 글리프는
/// 304~312에, hit zone은 324~348에 놓여 **아예 겹치지 않았다** — 보이는 ✕를 눌러도 닫히지 않았다(사용자 보고).
/// 상수를 맞추는 수정은 같은 실패를 반복시킨다(2칸→3칸 조정이 이미 한 번 그랬다). 식을 하나로 만든다.
///
/// 값(gutter·좌우 inset)은 호출자가 넘긴다 — chrome은 토큰도 platform 상수도 직접 읽지 않고 산술만 소유한다.
pub const Columns = struct {
    /// 카드 텍스트가 시작하는 열(좌측 accent 막대 + 패딩 뒤).
    indent_cols: u16,
    /// draw list가 쓰는 폭(`indent_cols` 기준 상대). 셀 col은 [0, cols)로 나오고 호출자가 `indent_cols`를 더한다.
    cols: u16,
    /// ✕가 놓이는 **최종** 열(`indent_cols` 반영 뒤). draw list와 hit-test가 같이 본다.
    close_col: u16,
    /// gutter를 뺀 전체 열 수. 시프트된 셀(`indent_cols + cols`)을 담을 surface 폭이다 — 이보다 좁게 잡으면
    /// 폭을 꽉 채운 줄이 surface 밖으로 나가 프레임이 통째로 실패한다. 항상 `indent_cols + cols` 이상이다.
    full_cols: u16,

    /// ✕ 열이 차지하는 x 구간 [start, end). hit-test가 이걸 그대로 쓰므로 "보이는 칸 = 눌리는 칸"이다.
    pub fn closeXRange(self: Columns, cell_width_px: u32) struct { start: f64, end: f64 } {
        const cw: f64 = @floatFromInt(cell_width_px);
        const start = @as(f64, @floatFromInt(self.close_col)) * cw;
        return .{ .start = start, .end = start + cw };
    }
};

/// ✕가 열 끝에서 몇 칸 안쪽인가. 그 오른쪽 두 칸은 여백이라 경계에 붙지 않는다(사용자 피드백).
pub const close_col_from_end: u16 = 3;

/// 카드 줄의 열 배치를 낸다. 폭이 모자라면 null(그 폭에서는 카드 텍스트도 ✕도 그리지 않는다).
///
/// `gutter_px`는 스크롤바가 상시 예약하는 우측 폭이고, `text_left_px`/`text_right_px`는 카드 좌우 inset이다.
/// 셋 다 0이어도 성립한다(tui) — 그때 `indent_cols`가 0이 되어 예전 동작과 같은 자리를 낸다.
pub fn columns(
    sidebar_width_px: u32,
    cell_width_px: u32,
    gutter_px: u32,
    text_left_px: u32,
    text_right_px: u32,
) ?Columns {
    if (sidebar_width_px == 0 or cell_width_px == 0) return null;
    const cw = cell_width_px;
    const usable = sidebar_width_px -| gutter_px;
    const full_cols: u32 = usable / cw;
    const indent_cols: u32 = if (text_left_px > 0) (text_left_px + cw - 1) / cw else 0;
    // 텍스트 폭은 좌우 inset을 뺀 나머지를 내림한 값과, `full_cols - indent_cols` 중 작은 쪽이다. 후자로도
    // clamp하는 이유는 올림(indent)과 내림(text)이 합쳐져 `full_cols`를 한 칸 넘길 수 있어서다 — 넘기면
    // 제목 우단이 터미널 영역을 침범한다.
    const text_w = usable -| text_left_px -| text_right_px;
    const cols: u32 = @min(text_w / cw, full_cols -| indent_cols);
    if (cols <= close_col_from_end) return null; // ✕ 자리조차 안 나오는 폭
    return .{
        .indent_cols = @intCast(@min(indent_cols, @as(u32, std.math.maxInt(u16)))),
        .cols = @intCast(@min(cols, @as(u32, std.math.maxInt(u16)))),
        .close_col = @intCast(@min(indent_cols + cols - close_col_from_end, @as(u32, std.math.maxInt(u16)))),
        .full_cols = @intCast(@min(full_cols, @as(u32, std.math.maxInt(u16)))),
    };
}

/// x가 사이드바 슬롯의 닫기(✕) 칸 안인가. **그리는 자리와 같은 `Columns`에서 나온다** — 인자로 받은 배치를
/// 그대로 쓰므로 gutter·inset이 바뀌어도 한쪽만 움직일 수 없다.
pub fn closeButton(x_px: f64, cols: Columns, cell_width_px: u32) bool {
    if (cell_width_px == 0) return false;
    const range = cols.closeXRange(cell_width_px);
    return x_px >= range.start and x_px < range.end;
}

/// 드래그 중 사이드바 y → 타겟 row(항상 valid 인덱스로 clamp — slotAt과 달리 row 아래 빈 영역도 마지막 row로 본다,
/// 드래그를 끝까지 끌 수 있게). rows 0·비유한이면 0. scroll_offset_px는 slotAt과 같은 의미(콘텐츠가 위로 밀린 양) —
/// 콘텐츠 좌표 content=(y-header+scroll)로 각 row 높이를 누적하며 역산하고, content<=0(헤더/그 위)이면 첫 row로 본다.
/// 가변 높이(카드=card_slot_h·헤더=header_row_h)라 slotAt과 같은 누적을 쓴다.
pub fn dragTargetSlot(y_px: f64, header_height_px: u32, rows: []const Row, m: Metrics, scroll_offset_px: u32) usize {
    if (rows.len == 0 or !std.math.isFinite(y_px)) return 0;
    const h: f64 = @floatFromInt(header_height_px);
    const content = y_px - h - @as(f64, @floatFromInt(m.content_pad_v)) + @as(f64, @floatFromInt(scroll_offset_px));
    if (content <= 0) return 0;
    var acc: f64 = 0;
    for (rows, 0..) |r, i| {
        acc += @as(f64, @floatFromInt(rowHeight(r, m)));
        if (content < acc) return i;
    }
    return rows.len - 1;
}

// ── view (밴드 fill — 옛 rebuildSidebar 대체) ──────────────────────────────────────

/// 사이드바 밴드(활성 슬롯·호버 슬롯·"+" 호버)를 fill op으로 `out`에 emit한다. 슬롯 r 밴드 = (0, r×slot_h, width,
/// slot_h). **slot_height_px는 cell 높이가 아니다**(= cell_h × ratio, 더 크다) — platform이 `sidebar_slot_height_px`를
/// 넘긴다. strip 배경·제목 glyph는 platform이 따로(밴드만 chrome). 활성 우선(활성 슬롯은 호버여도 활성 색). tabs
/// 빈(사이드바 꺼짐)이거나 메트릭 0이면 무동작. 순수: tabs·hover 상태만 읽는다. out·op은 호출자 frame arena 소유.
pub fn view(rows: []const Row, hovered_slot: ?usize, drop_slot: ?usize, p: props.ChromeProps, arena: std.mem.Allocator, out: *std.ArrayList(draw.Op)) !void {
    // 밴드는 스크롤바 gutter를 **뗀** 폭을 쓴다. 스크롤바가 카드 위(layer 3)가 아니라 같은 층에서 그려지면
    // 밴드가 사이드바 폭을 다 먹을 때 그것을 덮는다 — 컨테이너가 자기 폭에서 예약하는 것이 §4의 규율이다.
    const w = p.metrics.sidebar_width_px -| p.metrics.sidebar_scroll_gutter_px;
    // 카드 높이는 줄 수에서 나온다(Metrics) — 옛 고정 sidebar_slot_height_px는 밴드 기하의 입력이 아니다.
    const m = Metrics.init(p.metrics.cell_height_px, p.metrics.sidebar_header_row_h_px);
    if (w == 0 or m.line_h == 0 or rows.len == 0) return;
    // 밴드는 슬롯(row) **상대** 좌표(= 앞선 row 높이 누적 rowTop, 헤더·스크롤 제외)로 낸다 — **가변 높이**라 고정
    // row*slot_h가 아니라 각 row 높이(카드=slot_h·그룹 헤더=header_row_h)를 누적해야 그룹 헤더가 낮은 높이를 반영한다
    // (SG3b-2-ii-e — code-review 잔여). platform lowerSidebar는 이 상대 y로 row를 역산할 때 같은 누적을 쓰고(rowTop 역),
    // 헤더(검색바·아이콘)만큼의 절대 시프트는 .m이 사이드바 셀 py_top에 더한다(sidebar_header_height_px 단일 책임).

    // 그룹 헤더 밴드(SG3·SG5-2 — 색 있을 때만): 기본(무색) 헤더는 **밴드 없이 화살표+이름만** 남긴다(보더라인 제거 —
    // 사용자 결정, docs/sidebar-groups.md §5). 그룹 색이 지정된 헤더(has_color)만 얇은 한 줄(header_row_h) 밴드를 내고
    // lowerSidebar가 그 밴드 색에 그룹 색을 tint해 색 구분을 유지한다(삼각+이름 glyph는 platform이 그 위에 올린다).
    // hover/active 밴드(아래)는 has_color 무관하게 그대로 — 상호작용 피드백은 보더라인이 아니라 카드와 같은 하이라이트다.
    for (rows, 0..) |r, i| switch (r) {
        .group_header => |h| if (h.has_color) try out.append(arena, bandFill(rows, i, w, m, .tab_hover_bg, p.shape)),
        // 에이전트 목록 행은 소속 카드 아래 붙는 부속이라 자기 색 밴드를 내지 않는다(hover/active는 아래 공통 경로).
        .card, .agent_toggle, .agent, .recovered_sessions_header, .recovered_session => {},
    };

    // 활성 슬롯 밴드(첫 active=true 카드 row). group_header row는 활성 대상이 아니다.
    var active_idx: ?usize = null;
    for (rows, 0..) |r, i| switch (r) {
        .card => |c| if (c.active) {
            active_idx = i;
            break;
        },
        .group_header, .agent_toggle, .agent, .recovered_sessions_header, .recovered_session => {},
    };
    if (active_idx) |ai| {
        // 활성 밴드는 **카드 + 그 아래 에이전트 목록 전체**를 덮는다 — 목록은 그 워크스페이스에 딸린 부속이라
        // 카드만 칠하면 "어디까지가 이 워크스페이스인지"가 안 보인다(사용자 피드백). 범위는 `cardSpanEnd`가
        // 단일 출처로 준다(platform의 per-card tint·accent 막대도 같은 함수를 쓴다 — 두 벌 누적 금지).
        try out.append(arena, bandFillSpan(rows, ai, cardSpanEnd(rows, ai), w, m, .tab_active_bg, p.shape)); // 카드+목록 배경 밴드
        // 좌측 accent 막대는 여기서 내지 않는다 — 막대색이 카드별(우클릭 "바: …", tab.accent_color)이라 role 기반
        // chrome op으로 임의 RGB를 실을 수 없어, 배경 tint와 같은 이유로 **platform이 카드별 GpuQuad로 직접 그린다**
        // (app_session rebuildSidebar의 per-tab accent 루프 — 활성=기본 앰버/지정색, 비활성=지정 시에만). 카드 폭 inset과
        // 텍스트 좌측 여백은 여전히 tokens.space.accent_bar_width_px(=막대 폭)로 예약된다(밴드 위 정합·단일 출처).
    }

    // 호버 슬롯 밴드(활성과 다르고 범위 안일 때만 — 활성이면 활성 색 우선). 슬롯은 row 인덱스라 헤더/카드 무관하게 칠한다.
    if (hovered_slot) |hs| {
        if (hs < rows.len and (active_idx == null or hs != active_idx.?)) {
            // 카드·무색 헤더는 .tab_hover_bg 호버 밴드. **색 지정 그룹 헤더**는 위 색 밴드 루프가 이미 .tab_hover_bg
            // 밴드를 깔아, 같은 role 호버 밴드를 겹치면 lowerSidebar가 둘 다 같은 그룹색으로 tint해 byte-identical →
            // 호버 피드백이 안 보인다(code-review #4). 한 단계 밝은 .tab_active_bg로 오버레이해 카드처럼 하이라이트가
            // 나게 한다(docs/sidebar-groups.md §5 "hover=카드와 같은 하이라이트"; 무색 헤더·카드는 .tab_hover_bg 유지 = 회귀 없음).
            const hover_role: tokens.ColorRole = switch (rows[hs]) {
                .group_header => |gh| if (gh.has_color) .tab_active_bg else .tab_hover_bg,
                .card => .tab_hover_bg,
                // 목록 행은 **활성 밴드 위에 놓일 수 있다**(활성 카드의 목록). `.tab_hover_bg`는 활성색보다 어둡고
                // `.tab_active_bg`는 활성색과 **똑같아** 둘 다 그 위에서 구분이 사라진다(사용자 제보 — 활성 카드의
                // 하위 행을 호버해도 색 변화가 없다). 활성보다 한 단계 밝은 전용 role로 오버레이한다.
                .agent_toggle, .agent => .row_hover_bg,
                .recovered_sessions_header, .recovered_session => .row_hover_bg,
            };
            // 카드·헤더 호버 밴드는 **행 전체**(bandFill = 클릭 판정 구간과 동일). 목록 행만 사방 `list_pad_v/2`
            // 한 겹 들여 "카드에 딸린 부속"으로 보이게 하고 활성 밴드 위 위아래 행과 맞닿지 않게 한다
            // (사용자 피드백). 인셋이 얕아 클릭 영역과 어긋나 보이지 않는다 — docs/sidebar-agent-list.md §3.2.
            switch (rows[hs]) {
                .agent_toggle, .agent => try out.append(arena, listRowHoverBand(rows, hs, w, m, hover_role, p.shape)),
                .card, .group_header => try out.append(arena, bandFill(rows, hs, w, m, hover_role, p.shape)),
                .recovered_sessions_header, .recovered_session => {},
            }
        }
    }

    // 드롭 타겟 하이라이트 밴드(pane grip 드래그 중에만 platform이 슬롯을 준다) — 활성/호버 위에 .drop_zone 색으로
    // 그린다. drop_slot < rows.len이면 합칠 카드, == rows.len이면 카드 목록 아래 행('새 워크스페이스'). 범위 검사 없이
    // 그 행에 밴드를 낸다(카드 아래 행도 유효 — platform이 드래그 중에만, 그리고 자기 카드는 제외해 넘긴다).
    if (drop_slot) |ds| {
        try out.append(arena, bandFill(rows, ds, w, m, .drop_zone, p.shape));
    }
}

/// row의 전체-폭 밴드 fill op. row→y는 **앞선 row 높이 누적**(rowTop의 헤더·스크롤 제외분 = 슬롯 상대) — 가변
/// 높이(카드=slot_h·헤더=header_row_h)라 고정 row*slot_h가 아니다. row==rows.len(카드 목록 아래 새 워크스페이스 행)이면
/// 콘텐츠 하단·카드 높이로 둔다. platform lowerSidebar가 같은 누적으로 row를 역산해 tint를 얹고(.m이 header_h를 더해 절대
/// y를 맞춘다 — 헤더 시프트는 .m 단일 책임).
fn bandFill(rows: []const Row, row: usize, w: u32, m: Metrics, role: tokens.ColorRole, shape: props.ShapeTokens) draw.Op {
    return bandFillSpan(rows, row, row + 1, w, m, role, shape);
}

/// `[from, to)` **여러 row를 한 덩어리로** 덮는 밴드. 활성 워크스페이스가 카드 + 에이전트 목록을 함께 칠할 때 쓴다
/// (단일 row는 `bandFill`이 to=from+1로 위임).
///
/// 기하는 `spanRect` 하나에서 나온다 — **밴드 = 행 전체**(인셋 없음). 예전엔 사방 `card_gap`(rich 8px)을 들여
/// "떠 있는 카드"로 그렸는데, 클릭 판정(`slotAt`)은 행 전체(사이드바 폭 × 행 높이)라 밴드 밖 8px 띠를 눌러도
/// 카드가 눌렸다 — "보이는 곳 = 눌리는 곳"이 깨져 호버 하이라이트가 무엇을 가리키는지 어긋나 보인다(사용자
/// 제보 → 결정 2026-07-28: **밴드를 클릭 행에 맞춘다**). `card_gap_px`는 이제 카드 **텍스트 좌측 들여쓰기**
/// 전용 토큰이다. platform(rebuildSidebar의 per-card tint·accent 막대·드래그 고스트)도 같은 `spanRect`를 부른다.
fn bandFillSpan(rows: []const Row, from: usize, to: usize, w: u32, m: Metrics, role: tokens.ColorRole, shape: props.ShapeTokens) draw.Op {
    return quadOp(spanRect(rows, from, to, w, m), role, shape);
}

/// 목록 행(토글·에이전트) **호버 밴드** op = 행에서 사방 `list_pad_v/2`만 들인 rect. 카드 밴드(행 전체)와 달리
/// 한 겹 들이는 건 "목록 행은 카드에 딸린 부속"이라는 위계와, 활성 밴드 위에 놓일 때 위아래 행과 맞닿지 않게
/// 하려는 것이다(사용자 피드백). `card_gap`은 쓰지 않는다 — 행이 얕아 그만큼 들이면 밴드가 글자보다 작아지고
/// 클릭 영역과도 크게 어긋난다(`listRowBandV` 주석의 6px 띠 회귀).
fn listRowHoverBand(rows: []const Row, row: usize, w: u32, m: Metrics, role: tokens.ColorRole, shape: props.ShapeTokens) draw.Op {
    const top: i64 = rowTop(rows, row, 0, m, 0); // 슬롯 상대(헤더·스크롤 제외), ≥0
    const v = listRowBandV(rowHeight(rows[row], m), m);
    const g: u16 = @intCast(@min(m.list_pad_v / 2, @as(u32, std.math.maxInt(u16))));
    const band = draw.Rect{ .x = 0, .y = @intCast(top + @as(i64, v.top)), .w = w, .h = v.h };
    return quadOp(band.inset(.{ .left = g, .right = g }), role, shape);
}

/// 밴드 rect + role → quad op(둥근 모서리는 shape 토큰). tui(r=0)면 lowerSidebar가 셀 밴드로, rich(r>0)면 GPU
/// quad(둥근)로 lower한다 — 같은 op, 토큰만 다름.
fn quadOp(rect: draw.Rect, role: tokens.ColorRole, shape: props.ShapeTokens) draw.Op {
    const r = shape.corner_radius_px;
    return .{ .quad = .{ .rect = rect, .fill_role = role, .corner_radii = .{ r, r, r, r } } };
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────

// 테스트용 메트릭: **1줄 카드 높이 = card_h**가 되도록 구성한다(여백 0·스텝=줄높이). 이러면 가변 높이 도입 전의
// 균일 슬롯 기대값을 그대로 쓸 수 있어, 이 파일의 회귀 테스트가 옛 동작을 계속 고정한다.
fn testMetrics(card_h: u32, header_row_h: u32) Metrics {
    return .{ .line_h = card_h, .line_step = card_h, .card_pad_v = 0, .header_row_h = header_row_h, .content_pad_v = 0, .list_pad_v = 0 };
}

test "sidebar hit-test: inSidebar·onResizeEdge·slotAt·headerHit·closeButton·dragTargetSlot 경계" {
    // inSidebar: [0, w).
    try std.testing.expect(inSidebar(50, 100));
    try std.testing.expect(!inSidebar(100, 100)); // 경계 밖(반열림)
    try std.testing.expect(!inSidebar(-1, 100));
    try std.testing.expect(!inSidebar(50, 0)); // 폭 0(꺼짐)
    // onResizeEdge: [w, w + cw/2+2). w=100, cw=8 → [100, 106).
    try std.testing.expect(onResizeEdge(100, 100, 8));
    try std.testing.expect(onResizeEdge(105, 100, 8));
    try std.testing.expect(!onResizeEdge(106, 100, 8)); // 밴드 밖
    try std.testing.expect(!onResizeEdge(99, 100, 8)); // 사이드바 안쪽
    try std.testing.expect(!onResizeEdge(105, 100, 0)); // cell 0 → false(렌더 전; platform이 placeholder 적용)
    try std.testing.expect(!onResizeEdge(std.math.nan(f64), 100, 8)); // 비유한
    // slotAt: 가변 높이 누적. 카드만 rows(card_h=16·header_h 무관)로 옛 고정 동작을 그대로 재현(동작 보존).
    const vcard = Row{ .card = .{ .tab = 0, .label = "", .active = false } };
    const v3 = [_]Row{ vcard, vcard, vcard };
    const v5 = [_]Row{ vcard, vcard, vcard, vcard, vcard };
    const v0 = [_]Row{};
    // header=0: content=y, row는 누적으로. card_h=16, 3장.
    try std.testing.expectEqual(@as(?usize, 0), slotAt(8, 0, &v3, testMetrics(16, 16), 0));
    try std.testing.expectEqual(@as(?usize, 2), slotAt(40, 0, &v3, testMetrics(16, 16), 0)); // 2번 row
    try std.testing.expectEqual(@as(?usize, null), slotAt(48, 0, &v3, testMetrics(16, 16), 0)); // row 아래 빈 영역(3*16=48)
    try std.testing.expectEqual(@as(?usize, null), slotAt(8, 0, &v0, testMetrics(16, 16), 0)); // 카드 없음
    try std.testing.expectEqual(@as(?usize, null), slotAt(40, 0, &v3, testMetrics(0, 0), 0)); // 높이 0(모든 row skip)
    try std.testing.expectEqual(@as(?usize, null), slotAt(std.math.nan(f64), 0, &v3, testMetrics(16, 16), 0)); // 비유한
    // header=20: 헤더 영역(y<20)은 null, row는 (y-20) 누적.
    try std.testing.expectEqual(@as(?usize, null), slotAt(10, 20, &v3, testMetrics(16, 16), 0)); // 헤더 영역
    try std.testing.expectEqual(@as(?usize, 0), slotAt(20, 20, &v3, testMetrics(16, 16), 0)); // 헤더 직후 = row0
    try std.testing.expectEqual(@as(?usize, 1), slotAt(40, 20, &v3, testMetrics(16, 16), 0)); // (40-20)/16=1
    // 스크롤: 콘텐츠가 scroll만큼 위로 밀려 화면 같은 y가 더 아래 row를 가리킨다(header=20, card_h=16, 5장).
    try std.testing.expectEqual(@as(?usize, 1), slotAt(20, 20, &v5, testMetrics(16, 16), 16)); // 헤더 직후 + scroll 16 = row1
    try std.testing.expectEqual(@as(?usize, 3), slotAt(40, 20, &v5, testMetrics(16, 16), 32)); // (20+32)/16=3
    try std.testing.expectEqual(@as(?usize, null), slotAt(15, 20, &v5, testMetrics(16, 16), 16)); // 헤더 영역은 scroll 무관 null(고정)
    try std.testing.expectEqual(@as(?usize, null), slotAt(40, 20, &v5, testMetrics(16, 16), 64)); // (20+64)/16=5 ≥ 5장 → null
    // headerHit(2줄, ch=10, header=20 → rows=2, search_row=1): row0=아이콘 줄, row1(y≥10)=검색 줄. w=160,cw=8 → cols=20.
    // 우측 아이콘 4개 zone(3칸씩): new_workspace=col cols-2(x≥(cols-3)cw=136), view_options=cols-5(x≥112),
    // toggle_sidebar=cols-8(x≥88), notifications zone[cols-12,cols-9)=x≥64(종 글리프 cols-11·cols-10, 배지 cols-12 포함).
    // 좌측(<64)=신호등 영역(none).
    try std.testing.expectEqual(HeaderRegion.search, headerHit(10, 15, 160, 8, 10, 20, 0)); // 검색 줄(y≥10)
    try std.testing.expectEqual(HeaderRegion.new_workspace, headerHit(150, 5, 160, 8, 10, 20, 0)); // 줄0 우측 [136,160)
    try std.testing.expectEqual(HeaderRegion.view_options, headerHit(120, 5, 160, 8, 10, 20, 0)); // 줄0 ⚙ [112,136)
    try std.testing.expectEqual(HeaderRegion.toggle_sidebar, headerHit(95, 5, 160, 8, 10, 20, 0)); // 줄0 ◧ [88,112)
    try std.testing.expectEqual(HeaderRegion.notifications, headerHit(70, 5, 160, 8, 10, 20, 0)); // 줄0 종 [64,88)
    try std.testing.expectEqual(HeaderRegion.none, headerHit(10, 5, 160, 8, 10, 20, 0)); // 줄0 좌측 = 신호등 영역(<64)
    try std.testing.expectEqual(HeaderRegion.none, headerHit(10, 25, 160, 8, 10, 20, 0)); // 헤더 밖(y≥20)
    try std.testing.expectEqual(HeaderRegion.none, headerHit(10, 10, 160, 8, 10, 0, 0)); // 헤더 없음
    // 3줄 헤더(ch=10, header=30 → rows=3, search_row=2): row0=아이콘, row1=빈 줄(none), row2(y≥20)=검색.
    try std.testing.expectEqual(HeaderRegion.new_workspace, headerHit(150, 5, 160, 8, 10, 30, 0)); // 줄0 아이콘
    try std.testing.expectEqual(HeaderRegion.none, headerHit(150, 15, 160, 8, 10, 30, 0)); // 빈 가운데 줄(아이콘 col이어도 none)
    try std.testing.expectEqual(HeaderRegion.search, headerHit(10, 25, 160, 8, 10, 30, 0)); // 검색 줄(y≥20)
    // cols<13(너무 좁아 아이콘 4개가 안 들어감)이면 헤더 glyph가 안 그려지므로 클릭 무시(검색 무단 활성 방지).
    try std.testing.expectEqual(HeaderRegion.none, headerHit(50, 15, 96, 8, 10, 20, 0)); // w=96,cw=8 → cols=12<13
    try std.testing.expectEqual(HeaderRegion.none, headerHit(35, 15, 40, 8, 10, 20, 0)); // w=40,cw=8 → cols=5<13

    // 밴드가 주어지면 경계는 **셀 격자가 아니라 그 밴드**다. 이것이 이 함수가 존재하는 이유다 — 셀 배수로 가르면
    // 왼쪽 검색 줄이 창 오른쪽 탭 바와 어긋난다(docs/file-explorer.md §3.5).
    // 띠=28, 헤더=68(=28+40), ch=10: 아이콘 줄=[9,19)(띠 중앙), 검색=[28,68).
    try std.testing.expectEqual(HeaderRegion.search, headerHit(10, 30, 160, 8, 10, 68, 28)); // 상단 바 밴드 = 검색
    try std.testing.expectEqual(HeaderRegion.search, headerHit(10, 67, 160, 8, 10, 68, 28)); // 밴드 끝 직전도 검색
    try std.testing.expectEqual(HeaderRegion.new_workspace, headerHit(150, 14, 160, 8, 10, 68, 28)); // 띠 중앙 아이콘 줄
    // 그려진 것 = 클릭되는 것: 아이콘은 띠 **중앙**에 그려지므로 띠 상단(y<9)·하단(y≥19)은 빈 영역이다.
    // 예전 `[0, ch)` 판정을 남겨 두면 이 두 줄이 각각 new_workspace/none으로 뒤집힌다.
    try std.testing.expectEqual(HeaderRegion.none, headerHit(150, 2, 160, 8, 10, 68, 28)); // 아이콘 위 = 창 드래그 영역
    try std.testing.expectEqual(HeaderRegion.none, headerHit(150, 22, 160, 8, 10, 68, 28)); // 아이콘 아래 = 창 드래그 영역
    // 밴드가 0이거나 헤더보다 크면 옛 셀 격자로 떨어진다(platform이 아직 띠를 못 잡은 초기 프레임 — fail-close하면
    // 헤더가 통째로 클릭 불가가 된다).
    try std.testing.expectEqual(@as(u32, 10), headerSearchBandTop(20, 0, 10)); // 밴드 없음 → 마지막 셀 줄
    try std.testing.expectEqual(@as(u32, 10), headerSearchBandTop(20, 99, 10)); // 헤더보다 큰 밴드 → 마지막 셀 줄
    try std.testing.expectEqual(@as(u32, 28), headerSearchBandTop(68, 28, 10)); // 정상 밴드
    // closeButton: ✕가 실제로 그려지는 **그 칸**이다. w=100·cw=8·gutter/inset 0이면 cols=12, close_col=9 → [72, 80).
    {
        const c = columns(100, 8, 0, 0, 0).?;
        try std.testing.expectEqual(@as(u16, 9), c.close_col);
        try std.testing.expect(closeButton(72, c, 8));
        try std.testing.expect(closeButton(79, c, 8));
        try std.testing.expect(!closeButton(71, c, 8)); // 왼쪽(제목 영역)
        try std.testing.expect(!closeButton(80, c, 8)); // 오른쪽(여백 두 칸)
    }
    // dragTargetSlot(header=0): 항상 clamp. 아래 빈 영역도 마지막 row(가변 누적, 카드만=균일). v3/v5/v0 재사용.
    try std.testing.expectEqual(@as(usize, 2), dragTargetSlot(999, 0, &v3, testMetrics(16, 16), 0)); // 끝으로 clamp
    try std.testing.expectEqual(@as(usize, 0), dragTargetSlot(8, 0, &v3, testMetrics(16, 16), 0));
    try std.testing.expectEqual(@as(usize, 0), dragTargetSlot(50, 0, &v0, testMetrics(16, 16), 0)); // 카드 없음 → 0
    try std.testing.expectEqual(@as(usize, 0), dragTargetSlot(25, 20, &v3, testMetrics(16, 16), 0)); // header=20: (25-20)/16=0
    // 스크롤: content=(y-header+scroll). header=20, card_h=16, 5장.
    try std.testing.expectEqual(@as(usize, 2), dragTargetSlot(25, 20, &v5, testMetrics(16, 16), 32)); // (5+32)/16=2
    try std.testing.expectEqual(@as(usize, 4), dragTargetSlot(999, 20, &v5, testMetrics(16, 16), 32)); // 끝으로 clamp(scroll 무관)
    try std.testing.expectEqual(@as(usize, 0), dragTargetSlot(10, 20, &v5, testMetrics(16, 16), 0)); // 헤더 위(content<0) → 0
}

test "sidebar view: 활성·호버·+ 밴드 fill(우선순위·좌표·role)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = props.ChromeProps{
        .metrics = .{
            .cell_width_px = 8,
            .cell_height_px = 16,
            .sidebar_width_px = 120,
            .sidebar_slot_height_px = 40, // = cell_h × ratio(예: 16×2.5), cell 높이가 아님
            .backing_width_px = 800,
            .backing_height_px = 600,
        },
    };
    const rows = [_]Row{
        .{ .card = .{ .tab = 0, .label = "1 sh", .active = false } },
        .{ .card = .{ .tab = 1, .label = "2 vim", .active = true } },
        .{ .card = .{ .tab = 2, .label = "3 top", .active = false } },
    };

    // 활성(idx 1) + 호버(idx 0) → 밴드 2개(header_h=0, 하단 "+" 밴드는 헤더 아이콘으로 이동해 폐기).
    var out: std.ArrayList(draw.Op) = .empty;
    try view(&rows, 0, null, p, arena, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    // 활성: row 1 → y=40, role tab_active_bg, 전체 폭.
    try std.testing.expect(out.items[0] == .quad);
    try std.testing.expect(out.items[0].quad.fill_role == .tab_active_bg);
    const vm = Metrics.init(16, 20);
    const card1_h = cardHeight(1, vm); // 1줄 카드(cell 16) 높이 — 아래 기대값의 단일 출처
    const pad_top: i32 = @intCast(vm.content_pad_v); // 목록 위 여백만큼 모든 row가 내려간다
    try std.testing.expectEqual(pad_top + @as(i32, @intCast(card1_h)), out.items[0].quad.rect.y);
    try std.testing.expectEqual(@as(u32, 120), out.items[0].quad.rect.w);
    try std.testing.expectEqual(card1_h, out.items[0].quad.rect.h);
    // p.shape 기본(tui) → corner_radii 0(직각 → lowering이 셀 밴드로).
    try std.testing.expectEqual(@as(u16, 0), out.items[0].quad.corner_radii[0]);
    // 호버: row 0 → y=0, tab_hover_bg.
    try std.testing.expect(out.items[1].quad.fill_role == .tab_hover_bg);
    try std.testing.expectEqual(pad_top, out.items[1].quad.rect.y);

    // 호버 슬롯 == 활성이면 호버 밴드 생략(활성 색 우선).
    out.clearRetainingCapacity();
    try view(&rows, 1, null, p, arena, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len); // 활성만

    // 드롭 타겟 하이라이트: drop_slot 주면 활성/호버 위에 .drop_zone 밴드 추가(pane grip 드래그 중 platform이 준다).
    out.clearRetainingCapacity();
    try view(&rows, null, 0, p, arena, &out); // 활성(idx1) + 드롭(slot 0)
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expect(out.items[1].quad.fill_role == .drop_zone);
    try std.testing.expectEqual(pad_top, out.items[1].quad.rect.y); // slot 0
    // drop_slot == rows.len이면 카드 목록 아래 행(새 워크스페이스) — 범위 밖 행도 밴드를 낸다.
    out.clearRetainingCapacity();
    try view(&rows, null, rows.len, p, arena, &out);
    const last = out.items[out.items.len - 1].quad;
    try std.testing.expect(last.fill_role == .drop_zone);
    try std.testing.expectEqual(pad_top + @as(i32, @intCast(3 * card1_h)), last.rect.y); // row 3(카드 아래)

    // 사이드바 꺼짐(폭 0)·줄 높이 0(렌더 전 degenerate)·탭 없음이면 무동작.
    // **cell 높이 0**이 그 판정 입력이다 — 카드 높이가 줄 기하에서 나오므로 옛 `sidebar_slot_height_px = 0`은
    // 더 이상 "그릴 수 없음"을 뜻하지 않는다(그 필드는 카드 높이 계산에 안 쓰인다).
    out.clearRetainingCapacity();
    var off = p;
    off.metrics.sidebar_width_px = 0;
    try view(&rows, null, null, off, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    off = p;
    off.metrics.cell_height_px = 0;
    try view(&rows, 0, null, off, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);

    // rich shape(corner_radius>0): 같은 밴드가 둥근 quad로(radii 실림 → lowering이 GPU quad). tui와 같은 view 코드.
    out.clearRetainingCapacity();
    var rich_p = p;
    rich_p.shape = .{ .corner_radius_px = 8, .border_width_px = 1 };
    try view(&rows, null, null, rich_p, arena, &out);
    try std.testing.expect(out.items[0] == .quad);
    try std.testing.expectEqual(@as(u16, 8), out.items[0].quad.corner_radii[0]);

    // 좌측 accent 막대는 chrome이 내지 않는다(카드별 색이라 platform이 GpuQuad로 직접 — app_session per-tab accent 루프).
    // **카드 밴드 = 행 전체**다(사용자 결정 2026-07-28 — 클릭 판정 slotAt이 행 전체라 밴드를 거기 맞춘다).
    // card_gap은 밴드 기하에 **안 들어간다**(텍스트 좌측 들여쓰기 전용) — 옛 사방 인셋이면 밴드 밖 gap 띠를
    // 눌러도 카드가 눌려 "보이는 곳 ≠ 눌리는 곳"이었다.
    out.clearRetainingCapacity();
    var card_p = p;
    card_p.shape = .{ .corner_radius_px = 8 };
    try view(&rows, null, null, card_p, arena, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len); // 활성 카드 밴드만(막대 op 없음)
    const card = out.items[0].quad.rect;
    try std.testing.expectEqual(@as(i32, 0), card.x); // ★ 행 좌단(옛: gap=4)
    try std.testing.expectEqual(@as(u32, 120), card.w); // ★ 사이드바 전폭(옛: w-2×gap)
    try std.testing.expectEqual(pad_top + @as(i32, @intCast(card1_h)), card.y); // ★ 행 상단(옛: +gap)
    try std.testing.expectEqual(card1_h, card.h); // ★ 행 높이 그대로(옛: -2×gap)
    // 밴드 = 클릭 판정(slotAt) 행과 정확히 같은 구간이다 — 밴드 안 어디든 그 카드가 눌린다.
    try std.testing.expectEqual(@as(?usize, 1), slotAt(@floatFromInt(card.y), 0, &rows, Metrics.init(16, 20), 0));
    try std.testing.expectEqual(@as(?usize, 1), slotAt(@floatFromInt(card.y + @as(i32, @intCast(card.h)) - 1), 0, &rows, Metrics.init(16, 20), 0));
}

test "sidebar view: group_header 밴드 정책 — 무색=밴드 없음(화살표만)·색 있음=tint 밴드·hover 유지(SG5-2/보더라인 제거)" {
    // 헤더 정책(사용자 결정, docs/sidebar-groups.md §5): **기본(무색) 헤더는 밴드(보더라인) 없이** 화살표+이름만 남기고
    // (view가 헤더 row에 아무 밴드 op도 안 냄), 그룹 색이 지정된 헤더(has_color)만 얇은 한 줄(header_row_h) 밴드를 낸다
    // (lowerSidebar가 그 색으로 tint). **hover/active 밴드는 has_color 무관하게 유지** — 상호작용 피드백은 카드와 같은 경로.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = props.ChromeProps{
        .metrics = .{
            .cell_width_px = 8,
            .cell_height_px = 16,
            .sidebar_width_px = 120,
            .sidebar_slot_height_px = 40,
            .sidebar_header_row_h_px = 20, // 그룹 헤더 얇은 한 줄(카드 40보다 낮다)
            .backing_width_px = 800,
            .backing_height_px = 600,
        },
    };
    // row0=무색 그룹 헤더(has_color=false), row1=활성 카드(40), row2=비활성 카드(40).
    const rows_nocolor = [_]Row{
        .{ .group_header = .{ .collapsed = false, .label = "frontend", .member_count = 2, .tab = 0 } },
        .{ .card = .{ .tab = 0, .label = "web", .active = true } },
        .{ .card = .{ .tab = 1, .label = "docs", .active = false } },
    };
    var out: std.ArrayList(draw.Op) = .empty;
    // 무색·비호버: 헤더 밴드 없음 → 활성 카드 밴드(row1)만. 헤더 y=0에는 아무 밴드도 안 난다(보더라인 제거).
    try view(&rows_nocolor, null, null, p, arena, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len); // 활성 카드 밴드만(헤더 기본 밴드 없음)
    try std.testing.expect(out.items[0].quad.fill_role == .tab_active_bg);
    try std.testing.expectEqual(@as(i32, @intCast(Metrics.init(16, 20).content_pad_v + 20)), out.items[0].quad.rect.y); // 여백 + header_row_h(20)
    try std.testing.expectEqual(cardHeight(1, Metrics.init(16, 20)), out.items[0].quad.rect.h);

    // 색 지정 헤더(has_color=true): 헤더 밴드(row0, y=0, h=20, tab_hover_bg) + 활성 카드 밴드(row1). lowerSidebar가 tint.
    const rows_color = [_]Row{
        .{ .group_header = .{ .collapsed = false, .label = "frontend", .member_count = 2, .tab = 0, .has_color = true } },
        .{ .card = .{ .tab = 0, .label = "web", .active = true } },
        .{ .card = .{ .tab = 1, .label = "docs", .active = false } },
    };
    out.clearRetainingCapacity();
    try view(&rows_color, null, null, p, arena, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len); // 헤더 밴드(row0) + 활성 카드 밴드(row1)
    try std.testing.expect(out.items[0].quad.fill_role == .tab_hover_bg);
    try std.testing.expectEqual(@as(i32, @intCast(Metrics.init(16, 20).content_pad_v)), out.items[0].quad.rect.y);
    try std.testing.expectEqual(@as(u32, 20), out.items[0].quad.rect.h); // 헤더 높이(header_row_h)
    try std.testing.expect(out.items[1].quad.fill_role == .tab_active_bg);
    try std.testing.expectEqual(@as(i32, @intCast(Metrics.init(16, 20).content_pad_v + 20)), out.items[1].quad.rect.y);

    // 무색 헤더 hover(row0): 기본 밴드가 없어도 호버 밴드는 그대로 난다(카드와 같은 하이라이트 피드백 유지).
    out.clearRetainingCapacity();
    try view(&rows_nocolor, 0, null, p, arena, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len); // 활성 카드 밴드(row1) + 헤더 호버 밴드(row0)
    // 호버 밴드는 헤더 row0(y=0)에 tab_hover_bg로 난다 — 그중 하나가 그 조건을 만족해야 한다.
    var saw_header_hover = false;
    for (out.items) |op| {
        if (op.quad.fill_role == .tab_hover_bg and op.quad.rect.y == @as(i32, @intCast(Metrics.init(16, 20).content_pad_v)) and op.quad.rect.h == 20) saw_header_hover = true;
    }
    try std.testing.expect(saw_header_hover);

    // 색 지정 헤더 hover(row0, code-review #4): 기본 색 밴드(.tab_hover_bg, row0)와 **다른** role(.tab_active_bg, 한 단계
    // 밝음)의 호버 밴드가 같은 헤더 row에 겹쳐 나야 한다 — 옛 코드는 둘 다 .tab_hover_bg라 byte-identical(호버 무피드백).
    out.clearRetainingCapacity();
    try view(&rows_color, 0, null, p, arena, &out); // 색 헤더(row0) hover, 활성 카드=row1
    var saw_base_color_band = false; // 기본 색 밴드(.tab_hover_bg @ row0)
    var saw_header_hover_active = false; // 호버 밴드(.tab_active_bg @ row0) — 색 위 오버레이로 시각 변화
    for (out.items) |op| {
        if (op.quad.rect.y == @as(i32, @intCast(Metrics.init(16, 20).content_pad_v)) and op.quad.rect.h == 20) {
            if (op.quad.fill_role == .tab_hover_bg) saw_base_color_band = true;
            if (op.quad.fill_role == .tab_active_bg) saw_header_hover_active = true;
        }
    }
    try std.testing.expect(saw_base_color_band); // 색 밴드 유지(색 구분)
    try std.testing.expect(saw_header_hover_active); // 호버가 색과 다른 role로 나 시각 변화가 생긴다
}

test "sidebar onGroupHeader: 헤더 row만 true(카드·범위 밖 false)" {
    const rows = [_]Row{
        .{ .group_header = .{ .collapsed = false, .label = "g", .member_count = 1, .tab = 0 } },
        .{ .card = .{ .tab = 0, .label = "web", .active = true } },
    };
    try std.testing.expect(onGroupHeader(&rows, 0)); // 헤더 row
    try std.testing.expect(!onGroupHeader(&rows, 1)); // 카드 row
    try std.testing.expect(!onGroupHeader(&rows, 2)); // 범위 밖
}

// 카드 높이가 **줄 수에 비례**하고 여백이 위아래 각각 들어가는지 못박는다. 사이드바에서 왜 중요한가: 카드 높이는
// 클릭 좌표(slotAt)·밴드·glyph 배치가 모두 공유하는 기준이라, 여기가 어긋나면 "보이는 곳과 눌리는 곳"이 통째로
// 갈린다. (옛 고정 슬롯 cell×5.2와의 4줄 동등성은 상태줄이 목록 행으로 이동해 4줄 카드가 사라지면서 폐기됐다.)
// code-review(max) 회귀: 닫기 ✕ glyph는 `cols-3`에 그려지는데 hit zone은 우측 **2칸**이라, 보이는 ✕는 안 눌리고
// 그 옆 빈칸이 닫는 상태였다. 사이드바에서 왜 중요한가: 그 빈칸 클릭은 워크스페이스나 Term을 되돌릴 수 없이
// 닫으므로, "보이는 것 = 눌리는 것"이 깨지면 사용자가 의도하지 않은 파괴가 일어난다.
test "formatRelativeAge: 상대 표기가 폭 상한 안에 머문다" {
    var buf: [8]u8 = undefined;
    // 0은 sentinel이 아니라 **방금**이다 — 같은 tick에 출력한 에이전트가 정확히 0ms로 들어온다(code-review max).
    try std.testing.expectEqualStrings("now", formatRelativeAge(0, &buf));
    try std.testing.expectEqualStrings("now", formatRelativeAge(1, &buf));
    try std.testing.expectEqualStrings("now", formatRelativeAge(59_000, &buf));
    try std.testing.expectEqualStrings("1m", formatRelativeAge(60_000, &buf));
    try std.testing.expectEqualStrings("59m", formatRelativeAge(59 * 60_000, &buf));
    try std.testing.expectEqualStrings("1h", formatRelativeAge(60 * 60_000, &buf));
    try std.testing.expectEqualStrings("23h", formatRelativeAge(23 * 60 * 60_000, &buf));
    try std.testing.expectEqualStrings("1d", formatRelativeAge(24 * 60 * 60_000, &buf));
    // 폭이 행마다 달라지면 제목 잘리는 지점이 흔들린다 — 큰 값은 99d에서 멈춘다.
    try std.testing.expectEqualStrings("99d", formatRelativeAge(500 * 24 * 60 * 60_000, &buf));
    // 어떤 입력도 예약 폭을 넘지 않아야 한다(렌더러가 이 값으로 자리를 잡는다).
    const samples = [_]u64{ 1, 60_000, 3_600_000, 86_400_000, std.math.maxInt(u64) };
    for (samples) |ms| try std.testing.expect(formatRelativeAge(ms, &buf).len <= relative_age_cols);
}

// **상수가 맞는가가 아니라 두 자리가 겹치는가를 고정한다.** 이 회귀는 정확히 그 지점에서 뚫렸다 — 예전
// 테스트는 gutter=0·indent=0인 이상적 폭만 봐서, 스크롤바 gutter가 상시 예약된 뒤(SV4a) 그리는 자리만
// 좁아졌는데도 계속 green이었다. 실측 메트릭(사이드바 348px·cw 8·gutter 11)에서 그리는 칸과 눌리는 구간이
// 어긋나 사용자가 ✕를 눌러도 닫히지 않았다.
test "sidebar closeButton: gutter·indent가 있어도 그려진 ✕ 칸과 클릭 구간이 같다" {
    // 실측 재현: 사용자 로그의 sidebar_px=348, cell=8. gutter=11(스크롤바 8+inset 3), 좌 inset 11(카드 패딩
    // 8 + accent 막대 3), 우 inset 8.
    {
        const c = columns(348, 8, 11, 11, 8).?;
        const range = c.closeXRange(8);
        // 그리는 자리 = close_col 칸. 그 칸의 양 끝과 중앙이 전부 눌려야 한다.
        try std.testing.expectEqual(@as(f64, @floatFromInt(c.close_col)) * 8.0, range.start);
        try std.testing.expect(closeButton(range.start, c, 8));
        try std.testing.expect(closeButton(range.start + 4, c, 8));
        try std.testing.expect(closeButton(range.end - 0.5, c, 8));
        // 그 칸 밖은 아니어야 한다 — 옛 구현은 여기(왼쪽)를 눌러도 안 닫히고 오른쪽 빈칸이 닫았다.
        try std.testing.expect(!closeButton(range.start - 0.5, c, 8));
        try std.testing.expect(!closeButton(range.end, c, 8));
    }

    // gutter·inset 조합을 바꿔도 관계가 유지된다 — 한쪽 식만 바뀌면 여기서 걸린다.
    const cases = [_]struct { w: u32, cw: u32, gutter: u32, left: u32, right: u32 }{
        .{ .w = 348, .cw = 8, .gutter = 11, .left = 11, .right = 8 }, // 실측(폭이 셀 배수가 아님)
        .{ .w = 200, .cw = 10, .gutter = 0, .left = 0, .right = 0 }, // tui(인셋 없음)
        .{ .w = 300, .cw = 16, .gutter = 22, .left = 22, .right = 16 }, // 2x 대역
        .{ .w = 137, .cw = 9, .gutter = 7, .left = 5, .right = 3 }, // 어느 것도 배수가 아닌 경우
    };
    for (cases) |t| {
        const c = columns(t.w, t.cw, t.gutter, t.left, t.right).?;
        const range = c.closeXRange(t.cw);
        // ✕ 칸은 항상 사이드바 안이고 gutter를 침범하지 않는다(스크롤바 위에 ✕가 앉으면 둘 다 못 누른다).
        try std.testing.expect(range.end <= @as(f64, @floatFromInt(t.w -| t.gutter)));
        // 칸 안은 전부 true, 양 옆은 false — "보이는 칸 = 눌리는 칸".
        try std.testing.expect(closeButton(range.start, c, t.cw));
        try std.testing.expect(closeButton(range.end - 0.5, c, t.cw));
        try std.testing.expect(!closeButton(range.start - 0.5, c, t.cw));
        try std.testing.expect(!closeButton(range.end, c, t.cw));
        // 텍스트 열은 ✕를 침범하지 않는다(제목이 ✕ 위로 흘러들면 둘 다 읽을 수 없다).
        try std.testing.expect(c.indent_cols + c.cols > c.close_col);
        try std.testing.expectEqual(c.indent_cols + c.cols - close_col_from_end, c.close_col);
        // surface 폭은 시프트된 셀을 항상 담는다 — 모자라면 긴 줄이 surface 밖으로 나가 프레임이 실패한다.
        try std.testing.expect(c.full_cols >= c.indent_cols + c.cols);
    }

    // 폭이 모자라면 배치 자체가 없다 — 반쯤 걸친 ✕를 그리거나 누르게 두지 않는다.
    try std.testing.expect(columns(8, 8, 0, 0, 0) == null);
    try std.testing.expect(columns(0, 8, 0, 0, 0) == null);
    try std.testing.expect(columns(100, 0, 0, 0, 0) == null);
}

test "sidebar closeButton: 메트릭이 없으면 누를 수 없다" {
    const cw: u32 = 10;
    const c = columns(200, cw, 0, 0, 0).?;
    // 셀 폭 0(렌더 전)이면 누를 수 없다 — 자리를 모르는 채 닫기가 일어나면 안 된다.
    try std.testing.expect(!closeButton(170, c, 0));
    // 사이드바 밖(폭 경계 너머)도 false.
    try std.testing.expect(!closeButton(200, c, cw));
    try std.testing.expect(!closeButton(-1, c, cw));
}

test "sidebar 카드 높이: 줄 수에 비례하고 여백이 위아래 각각 들어간다" {
    const ch: u32 = 16;
    const m = Metrics.init(ch, 24);

    // 줄이 늘면 카드가 자란다(옛 고정 슬롯에서는 1줄이든 4줄이든 같은 높이였다).
    try std.testing.expect(cardHeight(1, m) < cardHeight(2, m));
    try std.testing.expect(cardHeight(2, m) < cardHeight(3, m));
    try std.testing.expect(cardHeight(3, m) < cardHeight(4, m));

    // 줄 하나가 느는 폭 = 줄 스텝(마지막 줄 뒤엔 여유가 없으므로 정확히 step만큼).
    try std.testing.expectEqual(m.line_step, cardHeight(3, m) - cardHeight(2, m));

    // 여백은 **위아래 각각** 들어간다 — 카드 높이 = 줄 블록 + 2×여백. 이 관계가 깨지면 글자가 밴드에 붙는다
    // (여백을 0.375→0.7로 올린 이유이자, 그 값이 계산에 실제로 두 번 반영되는지의 가드).
    try std.testing.expectEqual(blockHeight(2, m) + 2 * m.card_pad_v, cardHeight(2, m));

    // 0줄(비정상 입력)도 1줄과 같은 최소 높이로 포화한다 — 높이 0 row가 생기면 slotAt이 그 row를 건너뛴다.
    try std.testing.expectEqual(cardHeight(1, m), cardHeight(0, m));

    // rowHeight는 카드만 줄 수를 보고, 그룹 헤더는 별도 값(얇은 한 줄)을 그대로 쓴다.
    const c3 = Row{ .card = .{ .tab = 0, .label = "", .active = false, .lines = 3 } };
    const h = Row{ .group_header = .{ .collapsed = false, .label = "g", .member_count = 0, .tab = 0 } };
    try std.testing.expectEqual(cardHeight(3, m), rowHeight(c3, m));
    try std.testing.expectEqual(m.header_row_h, rowHeight(h, m));
}

test "sidebar 가변 높이: rowHeight·rowTop·contentHeight(혼합 누적 + 카드만=균일 동작 보존)" {
    // 가변 높이(§5): 헤더=header_row_h(얇은 한 줄), 카드=card_slot_h. y↔row를 고정 나눗셈이 아니라 누적으로 환산한다.
    // 핵심: **카드만이면 가변 rowTop이 옛 고정 slotTop과 정확히 같다** — SG3a 이주가 그룹 없는 현재 동작을 보존함을 증명.
    const card = Row{ .card = .{ .tab = 0, .label = "c", .active = false } };
    const hdr = Row{ .group_header = .{ .collapsed = false, .label = "g", .member_count = 0, .tab = 0 } };
    // rowHeight: 종류별 높이(card=40, header=16).
    try std.testing.expectEqual(@as(u32, 40), rowHeight(card, testMetrics(40, 16)));
    try std.testing.expectEqual(@as(u32, 16), rowHeight(hdr, testMetrics(40, 16)));

    // 혼합 [헤더(16), 카드(40), 카드(40)], header_px=0, scroll=0: 누적 상단 y.
    const mixed = [_]Row{ hdr, card, card };
    try std.testing.expectEqual(@as(i64, 0), rowTop(&mixed, 0, 0, testMetrics(40, 16), 0)); // 헤더 상단
    try std.testing.expectEqual(@as(i64, 16), rowTop(&mixed, 1, 0, testMetrics(40, 16), 0)); // 헤더(16) 뒤
    try std.testing.expectEqual(@as(i64, 56), rowTop(&mixed, 2, 0, testMetrics(40, 16), 0)); // 16+40
    try std.testing.expectEqual(@as(i64, 96), rowTop(&mixed, 3, 0, testMetrics(40, 16), 0)); // 16+40+40 = 콘텐츠 하단
    try std.testing.expectEqual(@as(u32, 96), contentHeight(&mixed, testMetrics(40, 16)));

    // header_height_px·scroll 반영: header=20, scroll=10.
    try std.testing.expectEqual(@as(i64, 10), rowTop(&mixed, 0, 20, testMetrics(40, 16), 10)); // 20-10
    try std.testing.expectEqual(@as(i64, 26), rowTop(&mixed, 1, 20, testMetrics(40, 16), 10)); // 20+16-10

    // 카드만 → 가변 rowTop == 옛 고정 공식(header + index*card_h − scroll). header=20, card_h=40, scroll=5.
    const cards = [_]Row{ card, card, card };
    try std.testing.expectEqual(@as(i64, 20 + 2 * 40 - 5), rowTop(&cards, 2, 20, testMetrics(40, 16), 5)); // = 95
    try std.testing.expectEqual(@as(i64, 20 - 5), rowTop(&cards, 0, 20, testMetrics(40, 16), 5)); // = 15
    try std.testing.expectEqual(@as(u32, 120), contentHeight(&cards, testMetrics(40, 16))); // 3*40(카드만이라 header_row_h 무관)

    // 빈 rows: rowTop=header-scroll, contentHeight=0.
    const empty = [_]Row{};
    try std.testing.expectEqual(@as(i64, 20), rowTop(&empty, 0, 20, testMetrics(40, 16), 0));
    try std.testing.expectEqual(@as(u32, 0), contentHeight(&empty, testMetrics(40, 16)));
}

test "sidebar cardSpanEnd·spanRect: 카드+목록 span 기하가 chrome 단일 출처다(platform이 재계산하지 않는다)" {
    // 이 두 함수는 chrome 밴드(bandFillSpan)와 platform(per-card 배경 tint·좌측 accent 막대·드래그 고스트)이
    // **함께** 쓰는 유일한 기하 소스다. 예전엔 같은 누적이 두 벌이라 한쪽 인셋만 바꾸면 막대가 밴드 안쪽에 떠
    // 보였다(docs/sidebar-agent-list.md §3.2). 여기서 값을 고정해 두 소비자가 갈라지지 못하게 한다.
    const m = testMetrics(40, 16);
    const card = Row{ .card = .{ .tab = 0, .label = "c", .active = false } };
    const hdr = Row{ .group_header = .{ .collapsed = false, .label = "g", .member_count = 0, .tab = 0 } };
    const toggle = Row{ .agent_toggle = .{ .tab = 0, .count = 2, .collapsed = false } };
    const agent = Row{ .agent = .{ .tab = 0, .pane = 0, .term = 0, .lines = 2 } };
    // [카드0, 토글, 에이전트, 카드3, 헤더4] — 카드0의 span은 목록 둘을 삼키고 카드3에서 멈춘다.
    const rows = [_]Row{ card, toggle, agent, card, hdr };
    try std.testing.expectEqual(@as(usize, 3), cardSpanEnd(&rows, 0)); // 카드 + 목록 2행
    try std.testing.expectEqual(@as(usize, 4), cardSpanEnd(&rows, 3)); // 뒤가 헤더 → 자기 하나
    try std.testing.expectEqual(@as(usize, 5), cardSpanEnd(&rows, 4)); // 헤더도 자기 하나(목록 안 딸림)
    try std.testing.expectEqual(@as(usize, 3), cardSpanEnd(&rows, 2)); // 목록 행 자신도 자기 하나
    try std.testing.expectEqual(@as(usize, 6), cardSpanEnd(&rows, 5)); // 범위 밖(새 워크스페이스 행) → index+1

    // spanRect: x=0·w=전폭·y=앞선 row 높이 누적·h=구간 높이 합(인셋 없음 = 클릭 행과 같은 구간).
    const span0 = spanRect(&rows, 0, cardSpanEnd(&rows, 0), 120, m);
    try std.testing.expectEqual(@as(i32, 0), span0.x);
    try std.testing.expectEqual(@as(u32, 120), span0.w);
    try std.testing.expectEqual(@as(i32, 0), span0.y);
    // 카드(40) + 토글(1줄) + 에이전트(2줄) — testMetrics는 여백 0·스텝=줄높이라 각 40·80.
    try std.testing.expectEqual(rowHeight(card, m) + rowHeight(toggle, m) + rowHeight(agent, m), span0.h);
    // 밴드 op(bandFillSpan)이 같은 rect를 쓴다 — 두 경로가 같은 값임을 직접 고정한다.
    const op = bandFillSpan(&rows, 0, cardSpanEnd(&rows, 0), 120, m, .tab_active_bg, .{});
    try std.testing.expectEqual(span0.x, op.quad.rect.x);
    try std.testing.expectEqual(span0.y, op.quad.rect.y);
    try std.testing.expectEqual(span0.w, op.quad.rect.w);
    try std.testing.expectEqual(span0.h, op.quad.rect.h);
    // 카드3의 span y = 앞선 세 row 높이 합(rowTop과 같은 누적).
    const span3 = spanRect(&rows, 3, cardSpanEnd(&rows, 3), 120, m);
    try std.testing.expectEqual(@as(i32, @intCast(span0.h)), span3.y);
    try std.testing.expectEqual(rowHeight(card, m), span3.h);
    // 범위 밖(목록 아래 "새 워크스페이스" 행)은 기본 1줄 카드 높이 — 드롭 밴드가 여기 그려진다.
    const past = spanRect(&rows, rows.len, rows.len + 1, 120, m);
    try std.testing.expectEqual(cardHeight(1, m), past.h);
    // y는 콘텐츠 하단(rowTop의 past-end 값 — contentHeight와 달리 아래 여백을 안 더한다).
    try std.testing.expectEqual(@as(i32, @intCast(rowTop(&rows, rows.len, 0, m, 0))), past.y);
}

test "sidebar scrollToSlot: 화면 밖 카드를 가장 적게 움직여 보이게 한다" {
    // 이 함수가 없으면 파일을 열어도 그 카드가 화면 밖에 남는다 — 활성 표시는 옮겨졌는데 사용자
    // 눈에는 아무 일도 안 난 것으로 보인다(계획서 W8.18⒜).
    const m = testMetrics(40, 16);
    const card = Row{ .card = .{ .tab = 0, .label = "c", .active = false } };
    const rows = [_]Row{ card, card, card, card, card, card }; // 6 × 40 = 240
    const view_h: u32 = 100;

    // 맨 아래 카드(top=200, bottom=240)를 맨 위에서 부르면 **아래 끝**을 맞춘다.
    try std.testing.expectEqual(@as(u32, 140), scrollToSlot(&rows, 5, m, view_h, 0));
    // 이미 보이는 카드는 **안 움직인다** — 이 판정이 없으면 "부를 때마다 튀는" 배선이 지나간다.
    try std.testing.expectEqual(@as(u32, 0), scrollToSlot(&rows, 1, m, view_h, 0));
    try std.testing.expectEqual(@as(u32, 60), scrollToSlot(&rows, 2, m, view_h, 60));
    // 바닥까지 내려간 상태에서 첫 카드를 부르면 **위 끝**을 맞춘다.
    try std.testing.expectEqual(@as(u32, 0), scrollToSlot(&rows, 0, m, view_h, 140));
    // 상한을 넘지 않는다 — 목록이 뷰포트보다 짧으면 0 이다.
    try std.testing.expectEqual(@as(u32, 0), scrollToSlot(&rows, 5, m, 1000, 0));
    // 범위 밖 슬롯·높이 0 은 지금 값 그대로(부르는 쪽이 매 프레임 불러도 안전하다).
    try std.testing.expectEqual(@as(u32, 33), scrollToSlot(&rows, 99, m, view_h, 33));
    try std.testing.expectEqual(@as(u32, 33), scrollToSlot(&rows, 0, m, 0, 33));

    // 카드가 뷰포트보다 크면 **위**를 맞춘다 — 아래를 맞추면 이름이 있는 첫 줄이 밖으로 나간다.
    const toggle = Row{ .agent_toggle = .{ .tab = 0, .count = 2, .collapsed = false } };
    const agent = Row{ .agent = .{ .tab = 0, .pane = 0, .term = 0, .lines = 2 } };
    const tall = [_]Row{ card, card, toggle, agent }; // 카드1 span = 40+40+80 = 160 > view_h
    try std.testing.expectEqual(@as(u32, 40), scrollToSlot(&tall, 1, m, view_h, 0));
}

test "sidebar 목록 행 호버 밴드: 글자 블록을 덮고 클릭 행과 같은 크기다(사방 card_gap 인셋으로 쪼그라들지 않음)" {
    // 회귀(사용자 제보 2건): 목록 행 호버 밴드를 행 높이에서 **사방 card_gap(+list_pad_v/2)** 인셋으로 만들었더니
    // (1) 행이 얕은 1줄 토글("N agents")에서 밴드가 글자보다 작아져 글자 한가운데를 가로지르는 6px 띠가 됐고
    // (2) 그 띠 바깥을 눌러도 행이 눌려 "클릭 영역과 호버 표시 크기가 다르다"가 됐다.
    // 실측 재현값(cell 18px, rich card_gap 8px): 행 26px − 인셋 2×10px = 6px < 글자 18px.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cell: u32 = 18;
    const m = Metrics.init(cell, 20);
    const p = props.ChromeProps{
        .metrics = .{
            .cell_width_px = 9,
            .cell_height_px = cell,
            .sidebar_width_px = 220,
            .sidebar_slot_height_px = 40,
            .sidebar_header_row_h_px = 20,
            .backing_width_px = 800,
            .backing_height_px = 600,
        },
        .shape = .{ .corner_radius_px = 8 }, // rich — 회귀가 났던 토큰 조합(card_gap은 밴드 기하에서 폐기됨)
    };
    const rows = [_]Row{
        .{ .card = .{ .tab = 0, .label = "ws", .active = true, .lines = 3 } },
        .{ .agent_toggle = .{ .tab = 0, .count = 1, .collapsed = false } },
        .{ .agent = .{ .tab = 0, .pane = 0, .term = 0, .lines = 3, .last = true } },
    };

    // 각 목록 행을 호버 → 마지막 op이 그 행의 호버 밴드(앞은 활성 카드+목록 span 밴드).
    for ([_]struct { row: usize, lines: u8 }{ .{ .row = 1, .lines = 1 }, .{ .row = 2, .lines = 3 } }) |c| {
        var out: std.ArrayList(draw.Op) = .empty;
        try view(&rows, c.row, null, p, arena, &out);
        const band = out.items[out.items.len - 1].quad;
        try std.testing.expect(band.fill_role == .row_hover_bg);

        const row_top = rowTop(&rows, c.row, 0, m, 0);
        const row_h = rowHeight(rows[c.row], m);
        const block = blockHeight(c.lines, m);
        // platform(fillSidebarGlyphPyTop)이 글자 블록을 놓는 자리 — 밴드는 이 블록을 **완전히** 덮어야 한다.
        const glyph_top = row_top + @as(i64, (row_h -| block) / 2);
        const glyph_bot = glyph_top + @as(i64, block);
        const band_top: i64 = band.rect.y;
        const band_bot: i64 = band_top + @as(i64, band.rect.h);
        try std.testing.expect(band_top <= glyph_top); // ★ 옛 코드: band_top > glyph_top(글자 위가 밖)
        try std.testing.expect(band_bot >= glyph_bot); // ★ 옛 코드: band_bot < glyph_bot(글자 아래가 밖)
        // 그래도 행을 넘지는 않는다 — 위아래 행 밴드와 맞닿으면 어느 행을 가리키는지 흐려진다.
        try std.testing.expect(band_top >= row_top);
        try std.testing.expect(band_bot <= row_top + @as(i64, row_h));
        // ★ 클릭 판정(slotAt이 쓰는 행 전체)과 **거의 같은 크기** — 밴드 밖을 눌러도 반응하는 어긋남이 보이지
        //   않으려면 차이가 얕은 인셋(위아래 list_pad_v/2)에 머물러야 한다. 옛 코드는 26px 행에 6px 밴드였다.
        try std.testing.expectEqual(row_h -| 2 * (m.list_pad_v / 2), band.rect.h);
        // 그 행 안 어디를 눌러도 hit-test가 이 행을 준다(밴드가 대표하는 영역 = 실제로 눌리는 영역).
        // rowTop은 content_pad_v를 포함하고 slotAt은 같은 양을 되빼므로 둘은 같은 화면 y 도메인이다(header=0·scroll=0).
        const probe_top: f64 = @floatFromInt(row_top + 1);
        const probe_bot: f64 = @floatFromInt(row_top + @as(i64, row_h) - 1);
        try std.testing.expectEqual(@as(?usize, c.row), slotAt(probe_top, 0, &rows, m, 0));
        try std.testing.expectEqual(@as(?usize, c.row), slotAt(probe_bot, 0, &rows, m, 0));
        // 가로는 카드 밴드(행 전체)보다 한 겹 들어간다(목록 행은 카드의 부속이라는 시각 위계) — 다만 card_gap이
        // 아니라 얕은 list_pad_v/2라 클릭 영역과 크게 어긋나지 않는다.
        try std.testing.expectEqual(@as(i32, @intCast(m.list_pad_v / 2)), band.rect.x);
        try std.testing.expectEqual(220 - 2 * (m.list_pad_v / 2), band.rect.w);
    }

    // listRowBandV 단위: 밴드는 행에서 위아래 얕은 인셋만 뺀 값이고(클릭 행과 정합), 글자 블록은 항상 그 안이다
    // (마지막 행처럼 아래 여백이 card_pad_v로 커지는 경우 포함).
    const toggle_h = listRowHeight(1, m, false);
    const v = listRowBandV(toggle_h, m);
    try std.testing.expect(v.h >= blockHeight(1, m)); // ★ 6px 띠 회귀 가드
    try std.testing.expectEqual(toggle_h -| 2 * (m.list_pad_v / 2), v.h);
    try std.testing.expect(v.top + v.h <= toggle_h);
    const last_h = listRowHeight(3, m, true);
    const v_last = listRowBandV(last_h, m);
    try std.testing.expect(v_last.h >= blockHeight(3, m));
    try std.testing.expect(v_last.top + v_last.h <= last_h);
}

// 실측 회귀 재현: 사용자 로그의 사이드바 348px·cell 8·gutter 11에서 옛 식(`w - 3cw`)과 새 배치가 실제로
// 어긋났음을 숫자로 남긴다. 이 테스트는 "고쳤다"가 아니라 **"무엇이 왜 틀렸었나"**를 고정한다 — 같은 종류의
// 어긋남(그리는 식과 누르는 식이 둘)이 다시 들어오면 여기가 먼저 설명해 준다.
test "sidebar closeButton: 옛 폭-역산 zone은 실측 메트릭에서 그려진 ✕와 겹치지 않았다" {
    const w: u32 = 348;
    const cw: u32 = 8;
    const c = columns(w, cw, 11, 11, 8).?;
    const range = c.closeXRange(cw);

    // 옛 구현이 보던 구간: [w - 3cw, w) = [324, 348).
    const legacy_start: f64 = @floatFromInt(w - 3 * cw);
    // 새(=그려진) 구간은 그보다 **왼쪽**에 있고 서로 닿지도 않는다 — 그래서 보이는 ✕를 눌러도 안 닫혔다.
    try std.testing.expect(range.end <= legacy_start);
    // 사용자가 실제로 누른 좌표들(로그: 309·311·313·317·321)은 전부 옛 zone 밖이었다.
    for ([_]f64{ 309, 311, 313, 317, 321 }) |x| try std.testing.expect(x < legacy_start);
    // 그중 그려진 ✕ 칸에 든 좌표는 이제 닫힌다.
    try std.testing.expect(closeButton(range.start, c, cw));
}
