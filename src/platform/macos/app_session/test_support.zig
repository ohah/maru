//! `app_session.zig`의 test 전용 공용 헬퍼 — 세션 fixture 생성, 상태 단언, 드래그/드롭 시나리오 구성.
//!
//! 같은 트리의 `session_host/`가 두는 `*_test_support` 모듈들과 같은 성격이다 — 제품 경로가 참조하지
//! 않는 test 전용 harness를 별도 모듈로 둔다. (그 모듈들은 파일명을 여기 적으면 경계 판정자가 잡는다 —
//! src 어느 파일도 그 이름을 언급하면 안 된다는 게이트가 있다.)
//!
//! **왜 지금 빼는가.** 이 저장소는 `src/**/*.zig` 381개 중 339개(88%)가 인라인 test를 가지는데,
//! F 시리즈로 갈라 놓은 그룹 파일 9개는 test가 0개다 — 1,000줄이 넘으면서 test가 없는 파일은 저장소에서
//! 이 아홉 개뿐이다. test를 제 그룹으로 돌려보내려면 공용 헬퍼가 먼저 공용 자리에 있어야 한다.
//! 실측: 단일 그룹 test 312개를 옮길 때 pub화해야 할 허브 비공개 선언 70개 중 **57개가 이런 헬퍼**였다.
//!
//! **무엇을 옮겼는가.** 제품 경로가 한 번도 참조하지 않는 파일 레벨 선언만이다 — `app_session.zig`의
//! 비-test 라인, 그룹 파일 9개, `app_host_abi.zig` 어디에서도 참조가 없고 test 블록에서만 쓰이는 것을
//! 실측으로 걸렀다(주석 안의 언급은 참조로 세지 않는다).

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");

const chrome = maru.chrome;
const terminal = maru.terminal;
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const setGroupMarker = app_session_mod.setGroupMarker;
const CommandKind = app_session_mod.CommandKind;
const appendFixtureArchiveGroup = app_session_mod.appendFixtureArchiveGroup;
const barMetrics = app_session_mod.barMetrics;
const ctx_menu_pin = app_session_mod.ctx_menu_pin;
const dockTreeItemRects = app_session_mod.dockTreeItemRects;
const renderer = app_session_mod.renderer;
const web_panel_layout = app_session_mod.web_panel_layout;
const DockTreeItemRect = app_session_mod.DockTreeItemRect;
const PaneTree = app_session_mod.PaneTree;
const ProviderFixtureEntry = app_session_mod.ProviderFixtureEntry;
const Tab = app_session_mod.Tab;
const TabDragMidFlight = app_session_mod.TabDragMidFlight;
const Term = app_session_mod.Term;
const abi_version = app_session_mod.abi_version;
const agent_dock = app_session_mod.agent_dock;
const appendFixtureArchiveRecordN = app_session_mod.appendFixtureArchiveRecordN;
const coretext_frame_builder = app_session_mod.coretext_frame_builder;
const dock_ops = app_session_mod.dock_ops;
const file_panel_ops = app_session_mod.file_panel_ops;
const file_tree = app_session_mod.file_tree;
const initDockedRoutingSession = app_session_mod.initDockedRoutingSession;
const metal_frame = app_session_mod.metal_frame;
const pane_ops = app_session_mod.pane_ops;
const settings_ops = app_session_mod.settings_ops;
const sidebar_ops = app_session_mod.sidebar_ops;
const tab_ops = app_session_mod.tab_ops;
const testBuildSidebarTitleFrame = app_session_mod.testBuildSidebarTitleFrame;

/// Artifact 헤더는 절대경로(`/Users/...`)를 좁은 밴드에 밀어 넣지 않고 문맥 있는 마지막 두 component를
/// breadcrumb로 보인다(`docs / web-panel.md`). 파일 capability의 실제 절대경로는 DockEntry에 그대로 남는다.
pub fn fileDockBreadcrumbAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = std.fs.path.basename(path);
    const parent_path = std.fs.path.dirname(path) orelse return allocator.dupe(u8, file);
    const parent = std.fs.path.basename(parent_path);
    if (parent.len == 0 or std.mem.eql(u8, parent, std.fs.path.sep_str)) return allocator.dupe(u8, file);
    return std.fmt.allocPrint(allocator, "{s} / {s}", .{ parent, file });
}

pub fn expectProviderFixtureEntries(io: std.Io, base: []const u8, expected: []const ProviderFixtureEntry) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, base, .{ .iterate = true });
    defer dir.close(io);
    var seen: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        var matched = false;
        for (expected) |want| {
            if (!std.mem.eql(u8, entry.name, want.name)) continue;
            try std.testing.expectEqual(want.kind, entry.kind);
            matched = true;
            break;
        }
        try std.testing.expect(matched);
        seen += 1;
    }
    try std.testing.expectEqual(expected.len, seen);
}

/// `sidebar.agent-transcript-hook`을 끈 config 파일 내용. 이 계약의 "옵션이 꺼지면 provider 파일을 전혀 건드리지
/// 않는다"를 검사하는 fixture다(docs/agent-session.md «사이드바 대화 표시와의 경계»).
pub const hook_off_config = "sidebar.agent-transcript-hook = false\n";

/// 같은 계약의 반대편 — 켠 경로에서 `statusLine` 키 외에는 손대지 않는지 검사하는 fixture.
pub const hook_on_config = "sidebar.agent-transcript-hook = true\n";

/// SG8b 등가 헬퍼(docs/sidebar-groups.md §9) — simulateDrop이 낸 **가상 배치**가 **실제 move 함수 적용 후 self.tabs**와
/// 일치함을 단언한다: (1) move 전 탭 포인터·선언 depth 스냅샷, (2) simulateDrop → vl(+ self.tabs 불변 단언), (3) plan에
/// 대응하는 실제 move를 **정확히 1회**, (4) 모든 위치 i에서 `before[vl.order[i]]==tabs[i]`(같은 탭이 같은 위치에)·
/// `vl.group_depth[i]==tabs[i].group_depth`(같은 depth). 프리뷰(비커밋)와 확정(커밋)이 한 순수 코어로 수렴함을 고정한다.
/// 중간 버퍼(그룹 순열 perm/new_order 등)까지 arena가 정리하므로 leak 없음.
pub fn expectDropEquivalent(session: *AppSession, origin: usize, plan: AppSession.DropPlan) !void {
    const alloc = std.testing.allocator;
    const n = session.tabs.items.len;
    const before = try alloc.alloc(*Tab, n);
    defer alloc.free(before);
    const before_gd = try alloc.alloc(u8, n);
    defer alloc.free(before_gd);
    for (session.tabs.items, 0..) |t, i| {
        before[i] = t;
        before_gd[i] = t.group_depth;
    }
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const vl = try session.simulateDrop(origin, plan, arena.allocator());
    // (2) self.tabs 불변 단언 — 순서·group_depth가 그대로(비커밋).
    for (session.tabs.items, 0..) |t, i| {
        try std.testing.expectEqual(before[i], t);
        try std.testing.expectEqual(before_gd[i], t.group_depth);
    }
    // (3) 확정 경로 — plan별 실제 move 1회.
    switch (plan) {
        .none => {},
        .card => |c| _ = tab_ops.moveTab(session, origin, c.target_tab),
        .group_sibling => |g| _ = session.moveGroupSibling(origin, g.insert_before),
        .group_nest => |g| _ = session.moveGroupNesting(origin, g.insert_before, g.target_depth),
    }
    // (4) 등가 단언 — 같은 위치에 같은 탭·같은 depth.
    try std.testing.expectEqual(n, session.tabs.items.len);
    for (session.tabs.items, 0..) |t, i| {
        try std.testing.expectEqual(before[vl.order[i]], t);
        try std.testing.expectEqual(vl.group_depth[i], t.group_depth);
    }
}

/// §14.6 SR4 model-2 프리뷰=확정 등가(카드 경로) — simulateDrop이 낸 가상 `top_level[]`가 **실제 commitSidebarDragPreview**
/// 확정 후 self.tabs.top_level와 위치별로 일치함을 단언한다(+order·group_depth도). expectDropEquivalent(raw move)와 달리
/// **commit 경로**(top_level write 포함)를 태워, 프리뷰(가상 override)와 확정(실제 write)이 같은 게이트를 써 갈리지 않음을
/// 고정한다(카드 plan 전용 — 그룹 plan은 top_level 불변이라 expectDropEquivalent로 충분). 로컬 pin 없는 시나리오라 commit의
/// normalize/float/sweep 후처리는 no-op이라 vl와 committed가 그대로 일치한다(등가 정확성 보장).
pub fn expectCardDropTopLevelEquivalent(session: *AppSession, origin: usize, plan: AppSession.DropPlan) !void {
    const alloc = std.testing.allocator;
    const n = session.tabs.items.len;
    const before = try alloc.alloc(*Tab, n);
    defer alloc.free(before);
    for (session.tabs.items, 0..) |t, i| before[i] = t;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const vl = try session.simulateDrop(origin, plan, arena.allocator());
    for (session.tabs.items, 0..) |t, i| try std.testing.expectEqual(before[i], t); // self.tabs 불변(비커밋 SG8)
    // 확정 — 실제 commit 경로(moveTab + top_level write + normalize/float/sweep).
    session.sidebar_drag_preview = .{ .origin = origin, .origin_len = 1, .plan = plan, .cursor_y = 0, .ghost_lo = 0, .ghost_hi = 0 };
    sidebar_ops.commitSidebarDragPreview(session);
    try std.testing.expectEqual(n, session.tabs.items.len);
    for (session.tabs.items, 0..) |t, i| {
        try std.testing.expectEqual(before[vl.order[i]], t); // 같은 위치에 같은 탭(순열 일치)
        try std.testing.expectEqual(vl.group_depth[i], t.group_depth); // 선언 depth 일치
        try std.testing.expectEqual(vl.top_level[i], t.top_level); // ★ 가상 top_level == 확정 실제 top_level(프리뷰=확정)
    }
}

/// SG8c 테스트 헬퍼 — rows에 그 **원본 tab 인덱스**의 카드 row가 있으면 그 depth를 돌려준다(없으면 null). "고스트 존재/사라짐"
/// (원본 tab이 카드 row로 방출됐는가)과 depth 정확성을 함께 본다(카드 .tab=원본 인덱스, 프리뷰 가상순서도 동일).
pub fn sg8cFindCardDepth(rows: []const chrome.components.sidebar.Row, tab: usize) ?u8 {
    for (rows) |row| switch (row) {
        .agent_toggle, .agent => {},
        .card => |c| if (c.tab == tab) return c.depth,
        .group_header => {},
    };
    return null;
}

/// SG8c 테스트 헬퍼 — rows에서 그 **원본 마커 tab 인덱스**의 group_header row를 돌려준다(없으면 null). collapsed flip·
/// member_count·depth 단언용(헤더 .tab=마커 원본 인덱스).
pub fn sg8cFindHeader(rows: []const chrome.components.sidebar.Row, tab: usize) ?chrome.components.sidebar.Row {
    for (rows) |row| switch (row) {
        .agent_toggle, .agent => {},
        .group_header => |h| if (h.tab == tab) return row,
        .card => {},
    };
    return null;
}

/// 카드 `tab`이 **그룹 밖 최상위 고정 카드로 렌더**되는지 사용자 경로로 단언한다(pin 회귀 매트릭스 공용). self.tabs 인덱스가
/// 아니라 (1) cardPinRole=.individual(우클릭 pin이 개별 전역 pin으로 라우팅), (2) enclosing 마커 null·tabIsInGroup false
/// (소속 파생상 그룹 밖), (3) projectRowsCore가 이 카드를 depth 0·비파생·📌로 방출(렌더 소속=최상위)을 함께 본다.
pub fn expectCardTopLevelPinned(session: *AppSession, tab: *Tab) !void {
    try std.testing.expect(session.cardPinRole(tab) == .individual); // 우클릭 pin = 개별 전역 pin(그룹 위임/로컬 아님)
    try std.testing.expect(tab.group_start == null); // 마커 아님
    try std.testing.expect(tab.pinned); // 개별 pin 상태
    var idx: usize = 0;
    for (session.tabs.items, 0..) |t, i| if (t == tab) {
        idx = i;
        break;
    };
    try std.testing.expect(session.enclosingGroupMarkerIndex(idx) == null); // 어느 그룹에도 안 속함
    try std.testing.expect(!tab_ops.tabIsInGroup(session, tab)); // 그룹 밖(흡수 없음)
    tab_ops.recomputeVisibleTabs(session);
    var found = false;
    for (session.sidebar_rows.items) |r| switch (r) {
        .agent_toggle, .agent => {},
        .card => |c| if (c.tab == idx) {
            found = true;
            try std.testing.expectEqual(@as(u8, 0), c.depth); // ★ 렌더 depth 0 = 최상위(그룹 흡수 없음)
            try std.testing.expect(!c.pin_derived); // 개별 pin(그룹 파생 캐시 아님)
            try std.testing.expect(!c.local_pinned); // 로컬 pin 아님(최상위엔 무의미)
            try std.testing.expect(sidebar_ops.sidebarRowShowsPin(session, r)); // ★ 📌 표시(개별 pin 카드)
        },
        .group_header => {},
    };
    try std.testing.expect(found); // 카드가 실제로 렌더됨(숨김 아님)
}

/// 우클릭 "위치 고정" 실제 진입점을 태운다(라벨·dispatch 공유 cardPinRole 라우팅) — acceptContextMenu의 ctx_menu_pin 경로.
pub fn rightClickPin(session: *AppSession, tab: *Tab) void {
    session.context_menu_target = .{ .workspace = tab };
    session.chrome_host.context_menu.selected = ctx_menu_pin;
    settings_ops.acceptContextMenu(session);
}

/// 워크스페이스 카드 우클릭 메뉴의 pin 라벨(cardPinRole 분기 결과) — context_menu_target 세팅 후 buildContextMenuItems 공유.
pub fn pinMenuLabel(session: *AppSession, tab: *Tab) []const u8 {
    session.context_menu_target = .{ .workspace = tab };
    return settings_ops.buildContextMenuItems(session)[ctx_menu_pin];
}

/// 표시 카드 row 인덱스를 tab 인덱스로 찾는다(그룹 드래그 경계 테스트가 커서 hit-test 대신 쓰는 헤드리스 헬퍼).
pub fn cardRowOf(session: *AppSession, tab_idx: usize) usize {
    for (session.sidebar_rows.items, 0..) |row, s| switch (row) {
        .agent_toggle, .agent => {},
        .card => |c| if (c.tab == tab_idx) return s,
        .group_header => {},
    };
    return 0;
}

/// 표시 row의 화면 y(backing px)를 그 row 안 frac 위치로 — cardDropPlan 실좌표(y_px) 테스트가 커서 y를 구성한다.
pub fn sidebarDragScreenY(session: *AppSession, row: usize, frac: f64) f64 {
    const rows = session.sidebar_rows.items;
    const top = chrome.components.sidebar.rowTop(rows, row, session.sidebar_header_height_px, sidebar_ops.sidebarMetrics(session), session.sidebar_scroll_offset_px);
    const h = chrome.components.sidebar.rowHeight(rows[row], sidebar_ops.sidebarMetrics(session));
    return @as(f64, @floatFromInt(top)) + @as(f64, @floatFromInt(h)) * frac;
}

// ── 그룹 드래그 "Cmd=중첩 / 없으면 형제" modifier 매트릭스(N/P/R/B) 공용 헬퍼 ─────────────────────────────────────────
// 표시 row의 세로 중앙 y(backing px, scroll=0). 그룹 드래그 mouse 시뮬레이션 테스트가 공유한다(N2와 같은 산식).
pub fn sbRowCenterY(s: *AppSession, row: usize) f64 {
    const sb = chrome.components.sidebar;
    const top = sb.rowTop(s.sidebar_rows.items, row, s.sidebar_header_height_px, sidebar_ops.sidebarMetrics(s), 0);
    const rh = sb.rowHeight(s.sidebar_rows.items[row], sidebar_ops.sidebarMetrics(s));
    return @floatFromInt(top + @as(i64, @intCast(rh / 2)));
}

// 두 형제 최상위 그룹 A=[t0,t1]·B=[t2,t3]을 만든 4-탭 세션. 호출자가 defer deinit/destroy. cols 넉넉히 잡아 사이드바+본문 확보.
pub fn makeTwoSiblingGroups(allocator: std.mem.Allocator) !*AppSession {
    const session = try allocator.create(AppSession);
    errdefer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    session.window_padding_px = .{};
    _ = try session.resize(session.sidebar_width_px + 800, 600, session.scale_milli);
    inline for (0..3) |_| _ = try tab_ops.newTab(session); // [t0..t3]
    try setGroupMarker(session, 0, "A", 1);
    try setGroupMarker(session, 2, "B", 1);
    tab_ops.recomputeVisibleTabs(session); // [hA(0), c t0(1), c t1(2), hB(3), c t2(4), c t3(5)]
    return session;
}

// B1 헬퍼 — 각 위치의 (그룹 마커 이름 첫 글자<<8 | group_depth) 시그니처. 구조적으로 동일한 두 세션의 착지 비교용.
pub fn groupSig4(session: *AppSession, out: *[4]u16) void {
    for (session.tabs.items, 0..) |t, i| {
        if (i >= 4) break;
        const nm: u16 = if (t.group_start) |g| (if (g.len > 0) @as(u16, g[0]) else 0) else 0;
        out[i] = (nm << 8) | t.group_depth;
    }
}

pub fn appendTrackedRemoteTermForTest(session: *AppSession) !*Term {
    app_session_mod.app_keep_alive_after_quit = true;
    session.loaded_config.config.session.keep_alive_after_quit = true;
    const term = try session.createTerm(.{ .command = "/bin/cat" }, .{ .cols = 40, .rows = 10 }, 16, "cat", "/bin/cat");
    errdefer session.destroyTerm(term);
    try session.tabs.items[0].panes.items[0].terms.append(session.allocator, term);
    return term;
}

// renameCaretRect는 셀·사이드바 픽셀 메트릭과 tabs/sidebar_rows가 필요해 실제 session.init로 세션을 만든 뒤(비-undefined,
// UB 없음) headless라 0인 메트릭만 채워 호출한다. 검증 대상은 code-review high finding 1·2 수정: 워크스페이스/그룹 이름이
// 사이드바 폭을 넘치면 렌더가 tail 앵커로 caret을 이름영역 우경계에 두므로, caret rect의 x도 거기로 clamp돼야 IME
// 후보창이 사이드바 밖 터미널 위로 안 뜬다(head-anchored·unclamped 회귀 고정).
pub fn initRenameCaretTestSession(allocator: std.mem.Allocator) !*AppSession {
    const session = try allocator.create(AppSession);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 40,
        .rows = 10,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    // headless init은 셀·사이드바 픽셀 메트릭이 0이라 renameCaretRect가 조기 null → 테스트용으로 채운다.
    session.cell_width_px = 8;
    session.cell_height_px = 16;
    session.sidebar_width_px = 80; // full_cols = 80/8 = 10 → 우경계 clamp = full_cols-2 = 8칸(x=64)
    session.sidebar_slot_height_px = 32;
    // 카드 높이는 이제 줄 수 기반이라 슬롯 필드만으로는 안 잡힌다 — 1줄 카드 높이가 32이 되는 메트릭을 박아
    // 고정 슬롯 시절 좌표 기대값을 그대로 쓴다(여백 0·스텝=줄높이).
    session.sidebar_metrics = .{ .line_h = 32, .line_step = 32, .card_pad_v = 0, .header_row_h = session.sidebar_header_row_h_px, .content_pad_v = 0, .list_pad_v = 0 };
    session.sidebar_header_height_px = 0;
    session.sidebar_header_row_h_px = 16;
    return session;
}

// 위상 진행이 **tick 수가 아니라 실경과 시간** 기준임을 고정한다(§10.5 secondary — 스피너와 같은 모델).
// 회귀: 옛 코드는 ms를 **설정값** render.frame-rate로 틱 환산해 셌다. 실효 tick rate가 그보다 낮으면(무거운 tick·
// 백그라운드 스로틀링, 실측 ~17Hz vs 설정 60Hz) 반주기가 그만큼 늘어나 깜빡임이 3배 넘게 느려졌다(사용자 제보
// "너무 느리다"). 이제 tick을 아무리 많이 돌려도 시간이 안 지났으면 위상이 안 넘어가고, baseline을 과거로 밀면
// tick 한 번으로도 넘어간다 — 두 방향을 함께 잠근다.
/// 테스트 전용: blink 위상 baseline을 `halves`개 반주기만큼 과거로 밀어, 다음 `updateCursorBlink` 한 번이
/// 그만큼 실경과한 것으로 보게 한다. wall-clock 모델이라 tick을 여러 번 도는 것으로는 위상이 안 넘어간다.
pub fn testAdvanceBlinkHalves(session: *AppSession, halves: i128) void {
    const interval_ns: i128 = @as(i128, @max(session.appearance.cursor.blink_interval_ms, 1)) * std.time.ns_per_ms;
    session.blink_phase_ns = std.Io.Clock.awake.now(session.io).nanoseconds - halves * interval_ns;
}

pub fn testBuildChromeOverlayFrame(session: *AppSession) !metal_frame.PaneFrame {
    const prep = (try session.buildChromeOverlayPrep()) orelse return error.NotOpen;
    const f = try prep.builder.buildFromDrawList(session.allocator, prep.dl, &session.renderer_state);
    return .{ .frame = f, .origin_x = prep.placement.origin_x, .origin_y = prep.placement.origin_y, .colors = prep.placement.colors, .clip_rect = prep.placement.clip_rect };
}

pub fn testBuildFloatingTabFrame(session: *AppSession, builder: coretext_frame_builder.CoreTextFrameBuilder, built_frames: *std.ArrayList(renderer.RenderFrame)) ?metal_frame.PaneFrame {
    const dp = tab_ops.buildFloatingTabDrawListAndPlacement(session) orelse return null;
    var f = builder.buildFromDrawList(session.allocator, dp.dl, &session.renderer_state) catch return null;
    built_frames.append(session.allocator, f) catch {
        f.deinit(session.allocator);
        return null;
    };
    return .{ .frame = f, .origin_x = dp.placement.origin_x, .origin_y = dp.placement.origin_y, .colors = dp.placement.colors };
}

/// 불변식 검사 헬퍼: 고정 탭은 배열 앞쪽 `[0, pinned_count)`에 연속으로 모이고, 그 뒤는 전부 비고정.
pub fn assertPinnedPrefix(session: *AppSession) !void {
    const pc = tab_ops.countPinnedTabs(session);
    for (session.tabs.items, 0..) |t, i| {
        if (i < pc) try std.testing.expect(t.pinned) else try std.testing.expect(!t.pinned);
    }
}

/// SG4 테스트 헬퍼 — 재투영(projectRows/recomputeVisibleTabs) 후 그 탭의 카드 row depth를 돌려준다(0=최상위·1=그룹 안).
/// 위치 파생 소속을 단언하는 단일 출처: 넣기=depth 1, 빼기=depth 0. 표시 안 되는 탭(접힘 등)이면 null.
pub fn sidebarCardDepth(session: *AppSession, tab: *Tab) ?u8 {
    tab_ops.recomputeVisibleTabs(session);
    var idx: ?usize = null;
    for (session.tabs.items, 0..) |t, i| if (t == tab) {
        idx = i;
        break;
    };
    const ti = idx orelse return null;
    for (session.sidebar_rows.items) |row| switch (row) {
        .agent_toggle, .agent => {},
        .card => |c| if (c.tab == ti) return c.depth,
        .group_header => {},
    };
    return null;
}

/// 사이드바 제목 프레임에 📌(U+1F4CC) 핀 글리프 셀이 있는가 — buildSidebarTitleFrame이 pins[]로 tab.pinned를
/// 넘겨 buildSidebarDrawList가 이름줄 **우측 끝**에 그렸을 때만 나타난다(옛 설계의 이름 prefix "📌 "는 폐기). 프레임은
/// 매 frame 재-shape(tab.pinned 라이브)되므로 토글 직후 빌드하면 새 상태가 보인다.
pub fn frameHasPinGlyph(session: *AppSession) !bool {
    var f = try testBuildSidebarTitleFrame(session);
    defer f.deinit(session.allocator);
    for (f.draw_list.cells) |c| if (c.codepoint == 0x1F4CC) return true;
    return false;
}

// 탭 전환 sync-게이트 회귀 테스트 공용 스캐폴딩: controlled_smoke 세션을 만들어 tab0을 정착시키고(출력 소진),
// 둘째 탭을 만들어(→tab1 활성) 정착시킨 뒤 세션을 돌려준다(호출자가 deinit+destroy). tab0 surface는
// session.tabs.items[0].panes.items[0].terms.items[0].surface로 얻는다. [code-review 5] 네 테스트의 중복 제거.
pub fn setupTwoTabsSettled(allocator: std.mem.Allocator) !*AppSession {
    const session = try allocator.create(AppSession);
    errdefer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    errdefer session.deinit();
    var i: usize = 0;
    while (i < 150) : (i += 1) _ = try session.tick(); // tab0 정착(controlled 출력 소진 → output_events=0)
    _ = try tab_ops.newTab(session); // 둘째 탭 → tab1 활성(createTab이 새 탭을 활성으로)
    std.debug.assert(session.tabs.items.len == 2);
    i = 0;
    while (i < 150) : (i += 1) _ = try session.tick(); // tab1 정착
    return session;
}

pub fn testWriteActiveTermCwd(session: *AppSession, cwd: []const u8) !void {
    // 실제 OSC 7→core observation 경로를 쓴다. cache를 직접 바꾸면 updateFileTree가 renderer보다 먼저
    // observation을 refresh해야 한다는 제품 불변을 증명하지 못한다.
    var osc: [std.fs.max_path_bytes + 32]u8 = undefined;
    const bytes = try std.fmt.bufPrint(&osc, "\x1b]7;file://localhost{s}\x07", .{cwd});
    try pane_ops.activePane(session).activeTerm().surface.core.write(bytes);
}

pub fn testWaitForFileTreeRootCompletion(session: *AppSession) !void {
    var attempts: usize = 0;
    while (session.file_tree_root_validation != null and attempts < 2_000) : (attempts += 1) {
        try file_panel_ops.updateFileTree(session);
        std.Io.sleep(session.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    if (session.file_tree_root_validation != null) return error.TestUnexpectedResult;
    try file_panel_ops.updateFileTree(session);
}

/// 창이 뷰포트를 **덮되 최소한**임을 본다 — 이것이 `fileTreeDrawWindow`의 올림 계약이다. 개수를
/// 산술로 다시 적는 대신 성질로 판정한다: 복제한 산술은 그것이 판정해야 할 호출부와 함께 틀린다.
pub fn expectWindowCoversViewport(count: u16, shift_px: u32, cell_h: u32, viewport_h: u32) !void {
    const covered = @as(u32, count) * cell_h;
    try std.testing.expect(covered >= viewport_h + shift_px); // 바닥에 빈 띠가 남지 않는다
    try std.testing.expect((covered -| cell_h) < viewport_h + shift_px); // 안 보이는 행을 그리지 않는다
}

pub fn testFileTreeIdentity(path: []const u8) !file_tree.Identity {
    const path_z = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(path_z);
    var stat: std.posix.Stat = undefined;
    if (std.c.fstatat(std.posix.AT.FDCWD, path_z.ptr, &stat, std.posix.AT.SYMLINK_NOFOLLOW) != 0) return error.StatFailed;
    return .{
        .device = @intCast(stat.dev),
        .inode = @intCast(stat.ino),
        .kind = @intFromEnum(if (std.posix.S.ISREG(stat.mode))
            file_tree.IdentityKind.regular
        else if (std.posix.S.ISDIR(stat.mode))
            file_tree.IdentityKind.directory
        else if (std.posix.S.ISLNK(stat.mode))
            file_tree.IdentityKind.symlink
        else
            file_tree.IdentityKind.other),
    };
}

// [4e review 0] collectWebSurfaces seam inset 검증 헬퍼 — 각 web 본문 rect가 seam(형제 pane 경계) 가장자리서 `seam`만큼,
// 바깥 경계는 0, top은 탭 바(bar_h) + (7e-1b) browser면 주소창 밴드(addr_h=bar_h)까지 들어갔는지 확인하고 어느 seam을
// 실제로 밟았는지 [left,right,bottom]로 돌려준다. markdown web은 top=bar_h(주소창 없음), browser web은 top=2·bar_h.
pub fn checkWebSeamInsets(session: *AppSession, seam: u32, allocator: std.mem.Allocator) ![3]bool {
    var leaves: std.ArrayList(PaneTree.LeafRect) = .empty;
    defer leaves.deinit(allocator);
    try tab_ops.activeTabLeafRects(session, allocator, session.termRect(), &leaves);
    var cur: std.ArrayList(web_panel_layout.SurfaceLayout) = .empty;
    defer cur.deinit(allocator);
    try session.collectWebSurfaces(&cur);
    const tr = session.termRect();
    const bar_h = pane_ops.paneBarHeightPx(session);
    var saw = [3]bool{ false, false, false }; // left, right, bottom seam을 실제 밟았는지(non-vacuous)
    for (cur.items) |s| {
        var lr: ?maru.session.SplitRect = null;
        for (leaves.items) |lf| for (lf.leaf.terms.items) |t| {
            if (t.kind == .web and t.surfaceId() == s.surface_id) lr = lf.rect;
        };
        const rect = lr.?;
        const cr = s.content_rect;
        const el: u32 = if (rect.x > tr.x) seam else 0;
        const er: u32 = if (rect.x + rect.w < tr.x + tr.w) seam else 0;
        const eb: u32 = if (rect.y + rect.h < tr.y + tr.h) seam else 0;
        if (el > 0) saw[0] = true;
        if (er > 0) saw[1] = true;
        if (eb > 0) saw[2] = true;
        // 7e-1b: browser web은 탭 바 아래 읽기전용 주소창 밴드(addr_h=bar_h)만큼 top inset이 더 들어간다(markdown은 0).
        const addr_h: u32 = if (s.panel_kind == .browser) bar_h else 0;
        try std.testing.expectEqual(rect.x + el, cr.x);
        try std.testing.expectEqual(rect.y + bar_h + addr_h, cr.y); // top = 탭 바 + (browser면) 주소창 밴드(seam 추가 inset 없음)
        try std.testing.expectEqual(rect.w - el - er, cr.w);
        try std.testing.expectEqual(rect.h - bar_h - addr_h - eb, cr.h);
        // seam_edges 비트마스크(L=1·R=2·B=4)는 inset이 걸린 가장자리와 정확히 일치해야 한다(Swift hitTest 통과의 단일 출처).
        var expected_mask: u8 = 0;
        if (el > 0) expected_mask |= 1;
        if (er > 0) expected_mask |= 2;
        if (eb > 0) expected_mask |= 4;
        try std.testing.expectEqual(expected_mask, s.seam_edges);
    }
    return saw;
}

// 닫기 확인(실행 중 명령 보호)의 트리거 판정은 코어의 cursorIsAtPrompt(셸 통합 OSC 133 + alt 화면)로 결정된다.
// 아래 테스트들은 활성 Term 코어의 semantic_state/alt_active를 직접 세팅해 각 경우를 **결정론적**으로 증명한다
// (controlled_smoke는 `/bin/sh -c "printf; read"`라 OSC 133·alt를 안 쏘므로 코어 상태는 세팅한 값 그대로 유지).
// 프로세스/pgid를 안 쓰므로 job-control 셸이 필요 없다.
pub fn initSmokeSessionTwoTerms(allocator: std.mem.Allocator) !*AppSession {
    const session = try allocator.create(AppSession);
    errdefer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    errdefer session.deinit();
    session.window_padding_px = .{};
    _ = try session.resize(session.sidebar_width_px + 800, 600, session.scale_milli);
    // ⌘T → Term 2개(활성 pane). .term_or_pane 닫기는 활성 Term 하나만 teardown한다.
    _ = try session.handleKeyEvent(.{ .key = .{ .char = 't' }, .modifiers = .{ .command = true } });
    try std.testing.expectEqual(@as(usize, 2), pane_ops.activePane(session).terms.items.len);
    return session;
}

/// 테스트 유틸 — 세션의 모든 Term 코어를 "프롬프트에 idle"(OSC 133 input) 상태로 표시한다. controlled_smoke는
/// OSC 133을 안 쏘므로 코어가 unknown이라 닫기 확인이 보수적으로 뜬다(cursorIsAtPrompt=false). 닫기를 **메커니즘**
/// 으로만 쓰는(닫기 확인 자체가 검증 대상이 아닌) 탭/pane/Term 수명 테스트가, 프로덕션의 통합 셸 idle 상태를 흉내 내
/// 즉시 닫히게 한다. 새 Term을 만든 뒤 닫기 직전에 부른다.
pub fn markAllTermsAtPrompt(session: *AppSession) void {
    for (session.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |t| t.surface.core.semantic_state = .input;
        }
    }
}

// 실 AppSession(controlled_smoke) 단일 term + 창 사이즈 세팅(split/newTab 선행). initSmokeSessionTwoTerms와 같은
// 하니스 패턴(§ 위 close-confirm 테스트) — collector는 이 실 트리를 평탄화한다.
pub fn initSmokeSessionSized(allocator: std.mem.Allocator) !*AppSession {
    const session = try allocator.create(AppSession);
    errdefer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    errdefer session.deinit();
    session.window_padding_px = .{};
    _ = try session.resize(session.sidebar_width_px + 800, 600, session.scale_milli);
    return session;
}

pub fn initTabDragSession(allocator: std.mem.Allocator) !*AppSession {
    const session = try allocator.create(AppSession);
    errdefer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    errdefer session.deinit();
    session.window_padding_px = .{};
    _ = try session.resize(session.sidebar_width_px + 800, 600, session.scale_milli);
    return session;
}

pub fn beginTabDragToLastSlot(session: *AppSession, allocator: std.mem.Allocator) !TabDragMidFlight {
    _ = try session.handleKeyEvent(.{ .key = .{ .char = 't' }, .modifiers = .{ .command = true } });
    _ = try session.handleKeyEvent(.{ .key = .{ .char = 't' }, .modifiers = .{ .command = true } });
    const pane = pane_ops.activePane(session);
    try std.testing.expectEqual(@as(usize, 3), pane.terms.items.len);
    const terms: [3]*Term = .{ pane.terms.items[0], pane.terms.items[1], pane.terms.items[2] };

    var lr: std.ArrayList(PaneTree.LeafRect) = .empty;
    defer lr.deinit(allocator);
    try tab_ops.activeTabLeafRects(session, allocator, session.termRect(), &lr);
    const pb = pane_ops.paneBar(session, lr.items[0].rect, lr.items[0].leaf).?;
    // 세그먼트 폭은 **제품과 같은 토큰**으로 잰다 — tab_width_cols를 0으로 두면 rich 테마(16)와 어긋나
    // 겨냥한 슬롯과 제품이 잡는 슬롯이 갈린다(끝자리만 겨냥하는 테스트는 clamp 덕에 우연히 맞는다).
    const m = barMetrics(pb.tabs, session.cell_width_px, 3, session.buildChromeTokens().space.tab_width_cols, 0).?;
    const tab0_x: f64 = @floatFromInt(pb.tabs.x + (0 * m.tab_w + 1) * session.cell_width_px);
    const tab2_x: f64 = @floatFromInt(pb.tabs.x + (2 * m.tab_w + 1) * session.cell_width_px);
    const bar_y: f64 = @floatFromInt(pb.full.y + 1);

    session.mouse(1, tab0_x, bar_y, 0, 0);
    try std.testing.expect(session.pointerGestureIs(.terminal_tab));
    session.mouse(2, tab2_x, bar_y, 0, 0);
    try std.testing.expectEqual(terms[0], pane_ops.paneTermOrder(session, pane)[2]); // preview는 끝자리로 갔다
    try std.testing.expectEqual(@as(usize, 2), pane_ops.paneActiveTermIndex(session, pane));
    return .{ .pane = pane, .terms = terms, .tab0_x = tab0_x, .tab_last_x = tab2_x, .bar_y = bar_y };
}

/// 복원됐는가 = 보이는 순서가 시작 순서와 같고, model이 한 번도 안 바뀌었다(effect 0).
/// 각 복원 트리거는 `beginTabDragToLastSlot`이 만든 중간 상태에서 갈라져 이 한 가지만 본다.
pub fn expectTabDragRestored(session: *AppSession, f: TabDragMidFlight) !void {
    try std.testing.expect(!session.pointerGestureIs(.terminal_tab)); // 제스처가 끝났다
    try std.testing.expectEqual(f.terms[0], f.pane.terms.items[0]);
    try std.testing.expectEqual(f.terms[1], f.pane.terms.items[1]);
    try std.testing.expectEqual(f.terms[2], f.pane.terms.items[2]);
    try std.testing.expectEqual(@as(usize, 0), f.pane.active_term);
    // 접근자가 model로 되돌아왔다 — 파기된 preview가 화면에 남지 않는다.
    try std.testing.expectEqual(f.pane.terms.items.ptr, pane_ops.paneTermOrder(session, f.pane).ptr);
    try std.testing.expectEqual(@as(usize, 0), pane_ops.paneActiveTermIndex(session, f.pane));
}

/// 오버레이를 **실제 렌더 경로**(buildChromeOverlayFrame과 같은 collectDraws)로 그려 `needle` 텍스트가 나오는지
/// 본다 — 상태만 단언하면 view가 그 상태를 무시해도 통과하므로(그리는 것이 계약이다) 그림을 본다.
pub fn findOverlayHasText(allocator: std.mem.Allocator, session: *AppSession, needle: []const u8) !bool {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tk = session.buildChromeTokens();
    const props = session.buildChromeProps();
    var draws: std.ArrayList(chrome.ChromeDraw) = .empty;
    try session.chrome_host.collectDraws(props, &tk, arena, &draws);
    for (draws.items) |d| {
        for (d.ops) |op| {
            const t = switch (op) {
                .text => |tx| tx,
                else => continue,
            };
            for (t.runs) |run| {
                if (std.mem.indexOf(u8, run.text, needle) != null) return true;
            }
        }
    }
    return false;
}

/// 상태바를 **실제 렌더 경로**(`collectStatusBarItems`)로 그려 `needle`의 코드포인트가 모두 셀에 있는지 본다.
/// 상태만 단언하면 렌더가 그 상태를 무시해도 통과하므로(그리는 것이 계약이다) 그림을 본다.
pub fn statusBarHasText(allocator: std.mem.Allocator, session: *AppSession, needle: []const u8) !bool {
    var collected: std.ArrayList(AppSession.CollectedPane) = .empty;
    defer {
        for (collected.items) |*c| c.deinit(allocator);
        collected.deinit(allocator);
    }
    const colors: metal_frame.CellColors = .{ .default_fg = session.appearance.theme.foreground };
    session.collectStatusBarItems(&collected, pane_ops.paneFrameBuilder(session), colors);

    var it = (std.unicode.Utf8View.init(needle) catch return false).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp == ' ') continue; // 공백은 셀에 안 실릴 수 있다(패딩)
        var found = false;
        outer: for (collected.items) |c| {
            for (c.pane.owned_list.cells) |cell| {
                if (cell.codepoint == cp) {
                    found = true;
                    break :outer;
                }
            }
        }
        if (!found) return false;
    }
    return true;
}

/// 살아 있는 워크스페이스(탭)를 하나 더 만든다 — cat으로 stdin을 물고 있어 (tick하면) reap이 안 닫는다(여기선 tick 안 함).
pub fn addMoveTestWorkspace(session: *AppSession, title: []const u8) !void {
    _ = try tab_ops.createTab(
        session,
        .{ .command = "/bin/sh", .args = &.{ "-c", "cat" }, .size = .{ .cols = 20, .rows = 5 } },
        .{ .cols = 20, .rows = 5 },
        16,
        title,
        "sh",
    );
}

// host-backed(원격) Term의 Cmd+hover 회귀 가드. 이전에는 hoverCursor가 `activeSurface().core`를 직접 분류했는데,
// 원격 surface의 그 core는 **빈 placeholder**라(화면은 host가 소유) 어떤 링크도 잡히지 않았다 — 밑줄도 링크 커서도
// 무동작. 이제 host가 해석해 실어 준 RenderSnapshot.links를 조회한다(docs/link-detection.md §원격(host-backed) 세션).
// 이 테스트는 그 조회 경로와 client 정책 필터(`input.link-detection`)를 함께 고정한다.
pub const FakeLinkScreen = struct {
    snap: terminal.RenderSnapshot,

    fn render(ctx: *anyopaque) terminal.RenderSnapshot {
        const self: *FakeLinkScreen = @ptrCast(@alignCast(ctx));
        return self.snap;
    }
    // 이 fake는 host 연결 없이 화면 소스 계약만 흉내 낸다 — 단일 스레드 테스트라 락은 no-op으로 충분하다.
    fn lockNoop(_: *anyopaque, _: std.Io) void {}
    fn unlockNoop(_: *anyopaque, _: std.Io) void {}

    pub const vtable: maru.session.surface.ScreenSource.VTable = .{
        .render_snapshot = render,
        .lock = lockNoop,
        .unlock = unlockNoop,
    };
};

/// 도크 content 중앙 — 진행 중 gesture가 지나가더라도 도크로 새면 안 되는 좌표.
pub fn dockContentCenter(session: *AppSession) struct { x: f64, y: f64 } {
    const content = dock_ops.dockGeometry(session).tree_content;
    return .{
        .x = @floatFromInt(content.x + content.w / 2),
        .y = @floatFromInt(content.y + content.h / 2),
    };
}

/// 픽스처 archive record 한 건 — 문자열은 session이 소유(deinit이 해제)한다.
pub fn appendFixtureArchiveRecord(session: *AppSession, allocator: std.mem.Allocator) !void {
    try appendFixtureArchiveRecordN(session, allocator, 0);
}

// 도크 휠 경로에는 판정자가 하나도 없었다. 방향을 뒤집어도, 포인터가 터미널 위인데 도크가 먹어도,
// 분수 residue를 소비하고도 안 빼서 같은 픽셀을 반복해도 전체 스위트가 초록이었다(이름에 "wheel"이
// 든 기존 테스트는 파일 트리 것이다). §2가 residue를 ScrollArea 소유로 적었으므로 SV1c가 이 코드를
// 옮기는데, 판정자 없이 옮기면 옮기다 깨져도 아무도 모른다.
pub fn dockWheelFixture(allocator: std.mem.Allocator) !*AppSession {
    const session = try initDockedRoutingSession(allocator, .right);
    errdefer allocator.destroy(session);
    errdefer session.deinit();
    const card_count = 20;
    for (0..card_count) |index| try appendFixtureArchiveRecordN(session, allocator, index);
    try appendFixtureArchiveGroup(session, allocator, card_count);
    try session.agent_session_archive_projection.entries.append(allocator, .{ .group = 0 });
    for (0..card_count) |index| try session.agent_session_archive_projection.entries.append(allocator, .{ .card = index });
    return session;
}

/// 실제 발행 경로로 도크 tree를 publish해 스크롤바 기하가 생기게 한다. 기존 드래그 테스트는
/// `agent_session_dock_scroll_drag`를 직접 세팅해 `agent_dock.beginAgentSessionDockScrollDrag`를 건너뛰었고,
/// 그래서 down 시점의 계약(track 안인가·thumb인가·잡은 지점·점프 뒤 기하)이 전부 무판정이었다.
pub fn publishDockFrameForDrag(session: *AppSession, allocator: std.mem.Allocator) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const projection = agent_dock.agentSessionDockScrollProjection(session);
    const items = try agent_dock.buildAgentSessionDockItems(session, arena, projection);
    const sizes = chrome.components.session_dock.build.bufferSizes(items);
    const content = dock_ops.dockGeometry(session).tree_content;
    const frame = try chrome.components.session_dock.build.build(agent_dock.agentSessionDockProps(session, content, projection, items), .{
        .nodes = try arena.alloc(chrome.ui.tree.UiNode, sizes.nodes),
        .entries = try arena.alloc(chrome.ui.tree.RectEntry, sizes.entries),
        .layout_items = try arena.alloc(chrome.ui.layout.Item, sizes.layout_items),
        .flex_scratch = try arena.alloc(chrome.ui.layout.FlexScratch, sizes.flex_scratch),
        .child_rects = try arena.alloc(chrome.ui.layout.UiRect, sizes.child_rects),
        .actions = try arena.alloc(chrome.components.session_dock.ids.Entry, sizes.actions),
    });
    agent_dock.publishAgentSessionDockFrame(session, frame, session.agent_session_dock_snapshot_generation);
}

/// 스크롤 좌표계가 예약한 것과 발행 tree가 그린 것을 항목마다 대조한다. 높이뿐 아니라 **시작 y**도
/// 본다 — 높이만 보면 첫 항목의 음수 원점(부분적으로 보이는 카드)이 사라져도 통과한다.
pub fn expectDockTreeMatchesScroll(
    session: *AppSession,
    allocator: std.mem.Allocator,
    rects: *std.ArrayList(DockTreeItemRect),
) !void {
    const projection = agent_dock.agentSessionDockScrollProjection(session);
    const items = agent_dock.agentSessionDockScrollItems(session);
    try dockTreeItemRects(session, allocator, projection, rects);
    try std.testing.expect(rects.items.len > 0);

    var expected_y: f32 = @floatFromInt(projection.first_origin_y_px);
    for (rects.items, 0..) |rect, offset| {
        const reserved = items.heightPx(projection.first_index + offset);
        try std.testing.expectEqual(reserved, rect.height);
        // 예약 높이를 누적한 자리에 그 항목이 실제로 놓여야 한다. 하나라도 어긋나면 그 아래 전부가
        // 밀린다 — 카드가 겹치거나 목록 끝에 빈 띠가 생기는 것이 그 결과다.
        try std.testing.expectEqual(expected_y, rect.y);
        expected_y += @floatFromInt(reserved + items.gap_px);
    }
}

/// `InputFocus` 값이 단독으로 활성일 때 host override(`terminalOwnsInput`)가 참이어야 하는가.
pub fn expectedTerminalResponder(focus: AppSession.InputFocus) bool {
    return switch (focus) {
        // 터미널이 키를 갖는 기본 상태.
        .terminal => false,
        // 지나가는 토스트는 텍스트/IME를 받지 않으므로 웹 포커스를 뺏지 않는다(14차 리뷰 [3]).
        .notice => false,
        .confirm,
        .settings,
        .rename,
        .sidebar_search,
        .agent_session_search,
        .find,
        .palette,
        .addr_edit,
        .file_tree,
        .dock_pending,
        => true,
    };
}

/// 그 focus 하나만 활성인 상태를 만든다. 만들 수 없으면 false(사유를 여기 남긴다).
pub fn activateSoleFocus(session: *AppSession, focus: AppSession.InputFocus) bool {
    switch (focus) {
        .terminal => {},
        .confirm => session.chrome_host.confirm.open = true,
        .notice => session.chrome_host.notice.open = true,
        .settings => session.chrome_host.settings.open = true,
        .find => session.chrome_host.find.open = true,
        .palette => session.chrome_host.palette.open = true,
        .rename => settings_ops.startRename(session, .{ .workspace = session.tabs.items[0] }),
        .sidebar_search => session.sidebar_search_active = true,
        .addr_edit => session.addr_edit = 1,
        .file_tree => session.focus_owner = .{ .file_tree = .{ .restore_surface = null } },
        .agent_session_search => {
            session.dock.presented = true;
            session.dock.collapsed = false;
            session.dock.side = .right;
            session.agent_session_archive_initialized = false;
            dock_ops.setDockView(session, .agent_sessions);
            session.agent_session_archive_initialized = true;
            session.agent_session_archive_search_active = true;
        },
        // pending dock focus는 live entry + async epoch가 맞아야 참이 된다(`pendingDockEntryOwnsInput`).
        // 그 조합은 파일 패널 fixture가 소유하므로 여기서는 만들지 않는다 — 기대표에는 남아 있어
        // `InputFocus`가 늘어날 때의 컴파일 강제는 그대로다.
        .dock_pending => return false,
    }
    return true;
}
