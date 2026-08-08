//! Test-only Chrome Lab fixture seam.
//!
//! This module owns synthetic UI inputs and recorded actions only. It deliberately does not
//! import AppSession, session, PTY, provider, filesystem, or a platform window host.

const std = @import("std");
const maru = @import("maru");
const lowering = @import("metal_lowering.zig");

const chrome = maru.chrome;
const session_dock = chrome.components.session_dock;
const archive_detail = chrome.components.archive_detail;

/// A three-card dock specimen emits component text (five runs per card), header/search controls,
/// and generic tree paint. Both the unit fixture and the product Metal smoke must use this one
/// bound; otherwise a new affordance can pass the former while the latter fails before capture.
///
/// sticky 시나리오는 그룹 둘·카드 넷에 상단 고정 헤더까지 그리므로 여기가 가장 많이 든다. 상한을
/// 시나리오마다 나누지 않는 이유는 위와 같다 — 하나만 넉넉하면 다른 쪽이 캡처 전에 죽는다.
pub const frame_op_capacity = 80;
pub const frame_run_capacity = 80;

pub const ScenarioId = enum {
    empty,
    loading,
    retained_list,
    font_specimen,
    partial_scroll,
    partial_group_scroll,
    scrollbar,
    // sticky 헤더의 세 상태(§4.7). clamp가 한 줄이라 셋이 같은 식에서 나오므로, 하나만 캡처하면
    // 나머지 둘이 무판정으로 남는다.
    sticky_at_rest,
    sticky_pinned,
    sticky_pushed,
    detail_loading,
    detail_ready,
    detail_stale,
    detail_unavailable,
    /// SB1 §5.2 — 사이드바 배경 strip이 창 바닥까지 가지 않고 **상태바 위에서 끊기는지**를 픽셀로 본다.
    /// 도크 내용은 필요 없다(strip은 `.m`이 직접 그린다) — 빈 프레임에 사이드바 폭·상태바 높이만 실어 준다.
    sidebar_status_strip,
};

/// sticky 시나리오인가. 그룹이 둘 이상이어야 "다음 헤더가 밀어낸다"를 만들 수 있다.
pub fn isSticky(id: ScenarioId) bool {
    return switch (id) {
        .sticky_at_rest, .sticky_pinned, .sticky_pushed => true,
        else => false,
    };
}

pub const Scenario = struct {
    id: ScenarioId,
    viewport_px: chrome.ui.layout.UiSize,
    now_ns: u64,
};

pub const Result = struct {
    raster: lowering.OverlayRaster,
    recorded_action: ?chrome.ui.tree.UiActionId = null,
};

/// Caller-owned fixed storage. A Lab scenario cannot allocate a layout cache or retain a previous
/// frame; the next scenario rebuild overwrites this candidate exactly like the normal Chrome path.
pub const FrameBuffers = struct {
    entries: []chrome.ui.tree.RectEntry,
    items: []chrome.ui.layout.Item,
    flex_scratch: []chrome.ui.layout.FlexScratch,
    child_rects: []chrome.ui.layout.UiRect,
    ops: []chrome.draw.Op,
    dock_nodes: []chrome.ui.tree.UiNode,
    dock_actions: []session_dock.ids.Entry,
    detail_nodes: []chrome.ui.tree.UiNode = &.{},
    detail_actions: []archive_detail.ids.Entry = &.{},
    text_runs: []chrome.draw.Run,
    text_bytes: []u8,
};

pub const Frame = struct {
    tree: chrome.ui.tree.UiRectTree,
    draws: chrome.ChromeDraw,
};

/// Produces a deterministic, effect-free Chrome component through the product UI tree and paint
/// path. Detail fixtures carry only synthetic/redacted strings; the Lab cannot import an archive
/// provider or an AppSession merely to make a visual regression test pass.
pub fn buildFrame(
    scenario: Scenario,
    tokens: *const chrome.Tokens,
    buffers: FrameBuffers,
) !Frame {
    return switch (scenario.id) {
        .detail_loading, .detail_ready, .detail_stale, .detail_unavailable => buildDetailFrame(scenario, tokens, buffers),
        // strip은 `.m`이 직접 그린다(승인 예외) — chrome 프레임은 빈 것으로 충분하다. 도크 내용을 넣으면
        // 그쪽 변경마다 이 골든이 흔들려, 정작 보려는 strip 경계와 무관한 이유로 깨진다.
        .sidebar_status_strip,
        .empty,
        .loading,
        .retained_list,
        .font_specimen,
        .partial_scroll,
        .partial_group_scroll,
        .scrollbar,
        .sticky_at_rest,
        .sticky_pinned,
        .sticky_pushed,
        => buildDockFrame(scenario, tokens, buffers),
    };
}

fn buildDockFrame(
    scenario: Scenario,
    tokens: *const chrome.Tokens,
    buffers: FrameBuffers,
) !Frame {
    const retained = [_]session_dock.types.Item{
        // fixture 문자열은 synthetic이어야 한다(project-rules "fixture는 synthetic·redacted만"). 실제 조직·
        // 저장소 이름을 쓰면 그것이 골든 이미지에 **픽셀로 고정**돼 저장소에 영구히 남는다. 워크스페이스
        // 이름은 그룹 행의 레이아웃만 증명하면 되므로 명백히 가짜인 값을 쓴다.
        .{ .group = .{ .identity = 1, .label = "sample-workspace", .count = 3 } },
        .{ .card = .{ .identity = 2, .provider = .claude, .title = "Notion document root cause", .summary = "Check the original document and isolate the cause", .metadata = "94 messages · 3m ago · claude-opus-5", .selected = scenario.id == .retained_list } },
        .{ .card = .{ .identity = 3, .provider = .codex, .title = "Implement session dock layout", .summary = "Wire the snapshot, interaction tree, and host renderer", .metadata = "140 messages · 22h ago · gpt-5.6-sol" } },
        .{ .card = .{ .identity = 4, .provider = .claude, .title = "Refresh list without flicker", .summary = "Keep the prior snapshot until the replacement is complete", .metadata = "356 messages · 1d ago · claude-opus-5" } },
    };
    // 그룹 **둘**이 있어야 sticky의 세 번째 상태(다음 헤더가 밀어냄)를 만들 수 있다. 하나짜리
    // fixture로는 "상단 고정"까지만 보이고 두 헤더가 겹치는 회귀를 못 본다.
    const two_groups = [_]session_dock.types.Item{
        .{ .group = .{ .identity = 1, .label = "sample-workspace", .count = 2 } },
        .{ .card = .{ .identity = 2, .provider = .claude, .title = "Notion document root cause", .summary = "Check the original document and isolate the cause", .metadata = "94 messages · 3m ago · claude-opus-5" } },
        .{ .card = .{ .identity = 3, .provider = .codex, .title = "Implement session dock layout", .summary = "Wire the snapshot, interaction tree, and host renderer", .metadata = "140 messages · 22h ago · gpt-5.6-sol" } },
        .{ .group = .{ .identity = 4, .label = "second-workspace", .count = 2 } },
        .{ .card = .{ .identity = 5, .provider = .claude, .title = "Refresh list without flicker", .summary = "Keep the prior snapshot until the replacement is complete", .metadata = "356 messages · 1d ago · claude-opus-5" } },
        .{ .card = .{ .identity = 6, .provider = .codex, .title = "Publish scrollbar inside preorder", .summary = "Keep the tree invariants while the gutter stays reserved", .metadata = "12 messages · 2d ago · gpt-5.6-sol" } },
    };
    // This is deliberately a real Session Dock card, not an out-of-band font test canvas. The
    // retained-list fixture proves list behavior; this specimen instead makes font selection
    // reviewable at PR scale. ASCII differentiators expose the selected primary face, while the
    // Korean line makes a missing primary glyph visibly exercise CoreText's fallback face.
    const font_specimen = [_]session_dock.types.Item{
        .{ .group = .{ .identity = 1, .label = "font specimen", .count = 3 } },
        .{ .card = .{ .identity = 2, .provider = .claude, .title = "Il1 O0 MWmw @# [] {} <>", .summary = "ASCII primary-face specimen", .metadata = "한글 가나다라마바사 · primary or fallback", .selected = true } },
        .{ .card = .{ .identity = 3, .provider = .codex, .title = "rn m w |! `.,:; /\\", .summary = "narrow and wide glyph contours", .metadata = "가각간 한글 폰트 비교" } },
        .{ .card = .{ .identity = 4, .provider = .claude, .title = "S5 2Z 8B 0O 1l I|", .summary = "same fixed grid, distinct ink", .metadata = "fallback face is reported in JSON" } },
    };
    // sticky 세 상태의 스크롤 위치. clamp가 한 줄이라 offset 하나로 상태가 정해지므로, 그 offset을
    // 기하에서 유도한다 — 상수를 박으면 metric이 바뀔 때 시나리오가 조용히 다른 상태를 찍는다.
    const m = session_dock.types.DockMetrics.resolve(1000);
    const second_group_top: u32 = (m.group_h + m.item_gap) + 2 * (m.card_h + m.item_gap);
    const sticky_offset: u32 = switch (scenario.id) {
        // 아직 안 지남 — 헤더가 흐름 그대로다.
        .sticky_at_rest => 0,
        // 지나침 — 첫 카드가 헤더 **밑으로** 지나간다.
        .sticky_pinned => m.group_h + m.item_gap + m.card_h / 2,
        // 다음 헤더가 올라와 밀어내는 중. 반쯤 밀려난 자리라야 두 헤더가 겹치는 회귀가 픽셀에 남는다.
        .sticky_pushed => second_group_top - m.item_gap - m.group_h / 2,
        else => 0,
    };
    const sticky_head: ?session_dock.types.StickyGroup = if (isSticky(scenario.id))
        .{ .group = two_groups[0].group, .top_px = 0, .next_top_px = second_group_top }
    else
        null;

    const dock_props = session_dock.types.Props{
        .viewport_px = scenario.viewport_px,
        .cell_width_px = 8,
        .cell_height_px = 16,
        .snapshot_generation = 1,
        .displayed_count = if (scenario.id == .empty or scenario.id == .loading) 0 else 3,
        .loading = scenario.id == .loading,
        .refreshing = false,
        .spinner_phase = @intCast(scenario.now_ns % 8),
        .search = if (scenario.id == .empty) "" else "",
        // The partial fixture starts at the first card with an integer negative origin. It is the
        // same component geometry used by the host virtualization path, not a screenshot-only crop.
        // 스크롤바는 목록이 실제로 넘칠 때만 발행된다. 그 입력은 **보이는 item 수가 아니라** 전체
        // content 높이와 현재 offset이다(가상화 때문에 component는 보이는 창만 받는다). 그래서 이 둘을
        // 채우지 않으면 item이 몇 개든 스크롤바가 나오지 않는다 — 기존 골든 네 장에 스크롤바 픽셀이
        // 하나도 없던 이유가 이것이고, 그 상태에서는 스크롤바를 통째로 지워도 게이트가 통과한다.
        .scroll_content_height_px = if (scenario.id == .scrollbar)
            4000
        else if (isSticky(scenario.id))
            2 * m.group_h + 4 * m.card_h + 5 * m.item_gap
        else
            0,
        // 양 끝이 아닌 중간 위치라야 track과 thumb이 **둘 다** 픽셀로 남는다. 끝에 붙이면 한쪽 여백이
        // 사라져 thumb 높이·위치 회귀를 골든이 못 본다.
        .scroll_offset_px = if (scenario.id == .scrollbar) 1500 else sticky_offset,
        .sticky_group = sticky_head,
        .content_first_item_origin_y_px = switch (scenario.id) {
            .partial_scroll => -28,
            // 그룹 행을 절반쯤 스크롤 영역 위로 밀어, **radius를 가진** count pill이 잘리는 상태를 만든다.
            // 카드 배경(radius 0)으로는 못 보는 계약이 여기 걸린다: 잘린 변에 곡률이나 border stroke가
            // 생기면 안 된다(CPU가 rect를 미리 자르면 shader가 줄어든 rect를 원본으로 착각해 그렇게 된다).
            .partial_group_scroll => -22,
            // 목록 전체를 넘기므로 첫 항목 원점이 곧 -offset이다(가상화 창을 자르지 않는다).
            .sticky_at_rest, .sticky_pinned, .sticky_pushed => -@as(i32, @intCast(sticky_offset)),
            else => 0,
        },
        .items = switch (scenario.id) {
            .retained_list => &retained,
            .font_specimen => &font_specimen,
            .partial_scroll => retained[1..],
            .partial_group_scroll, .scrollbar => &retained,
            .sticky_at_rest, .sticky_pinned, .sticky_pushed => &two_groups,
            .empty, .loading, .sidebar_status_strip => &.{}, // strip 시나리오는 목록이 비어야 경계만 남는다
            .detail_loading, .detail_ready, .detail_stale, .detail_unavailable => unreachable,
        },
    };
    const session_frame = try session_dock.build.build(dock_props, .{
        .nodes = buffers.dock_nodes,
        .entries = buffers.entries,
        .layout_items = buffers.items,
        .flex_scratch = buffers.flex_scratch,
        .child_rects = buffers.child_rects,
        .actions = buffers.dock_actions,
    });
    const draws = try session_dock.view.view(dock_props, session_frame, .{}, tokens, .{ .ops = buffers.ops, .runs = buffers.text_runs, .text_bytes = buffers.text_bytes });
    return .{ .tree = session_frame.tree, .draws = draws };
}

fn buildDetailFrame(
    scenario: Scenario,
    tokens: *const chrome.Tokens,
    buffers: FrameBuffers,
) !Frame {
    const state: archive_detail.types.State = switch (scenario.id) {
        .detail_loading => .loading,
        .detail_ready => .ready,
        .detail_stale => .stale,
        .detail_unavailable => .unavailable,
        else => unreachable,
    };
    const turns = [_]archive_detail.types.Turn{
        .{ .role = .user, .text = "Show the current document work" },
        .{ .role = .assistant, .text = "This is a synthetic redacted recent-turn summary." },
    };
    const props = archive_detail.types.Props{
        .viewport_px = scenario.viewport_px,
        .cell_width_px = 8,
        .cell_height_px = 16,
        .snapshot_generation = 1,
        .state = state,
        .provider = .claude,
        .title = "Document implementation review",
        .metadata = "3 messages · 3m ago · claude-opus-5",
        .turns = if (state == .ready) &turns else &.{},
        .action_record_count = if (state == .ready) 2 else 0,
        .spinner_phase = @intCast(scenario.now_ns % 8),
        .resume_enabled = state == .ready,
        .reveal_enabled = state == .ready,
        // A Lab fixture deliberately never claims a live provider mapping.
        .focus_live_enabled = false,
    };
    const detail_frame = try archive_detail.build.build(props, .{
        .nodes = buffers.detail_nodes,
        .entries = buffers.entries,
        .layout_items = buffers.items,
        .flex_scratch = buffers.flex_scratch,
        .child_rects = buffers.child_rects,
        .actions = buffers.detail_actions,
    });
    const draws = try archive_detail.view.view(props, detail_frame, .{}, tokens, .{ .ops = buffers.ops, .runs = buffers.text_runs, .text_bytes = buffers.text_bytes });
    return .{ .tree = detail_frame.tree, .draws = draws };
}

pub fn dispatchRecordedAction(
    state: *chrome.ui.interaction.InteractionState,
    frame: Frame,
    event: chrome.ui.interaction.UiPointerEvent,
) !?chrome.ui.tree.UiActionId {
    return (try chrome.ui.interaction.dispatch(state, frame.tree, event)).action;
}

/// Lowers one already-built synthetic draw frame through the production lowerer. The caller owns
/// scenario construction and raster deinit; this leaf cannot create an OS surface or dispatch an
/// external effect.
pub fn lowerDraws(
    allocator: std.mem.Allocator,
    draws: []const chrome.ChromeDraw,
    tokens: *const chrome.Tokens,
    cell_width_px: u32,
    cell_height_px: u32,
) !Result {
    return .{ .raster = try lowering.lower(allocator, draws, tokens, cell_width_px, cell_height_px, true) };
}

test "Chrome Lab has no implicit surface and fails closed for an empty synthetic frame" {
    // The lowerer returns before reading tokens when there is no drawable box. This proves the Lab
    // seam cannot manufacture a fallback AppSession/window/terminal merely to make a fixture pass.
    const undefined_tokens: chrome.Tokens = undefined;
    try std.testing.expectError(error.NoBox, lowerDraws(std.testing.allocator, &.{}, &undefined_tokens, 8, 16));
}

test "Chrome Lab builds a deterministic font specimen card and records only its action" {
    const tokens = chrome.Tokens.rich(.{
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .accent = .{ .r = 13, .g = 14, .b = 15 },
    });
    var entries: [16]chrome.ui.tree.RectEntry = undefined;
    var items: [16]chrome.ui.layout.Item = undefined;
    var flex_scratch: [16]chrome.ui.layout.FlexScratch = undefined;
    var child_rects: [16]chrome.ui.layout.UiRect = undefined;
    // A specimen has three real cards. Each card now owns title, summary, provider,
    // metadata, and its disclosure affordance, in addition to generic paint. Keep this
    // fixture's explicit bounded scratch above that complete component contract rather
    // than relying on the old pre-disclosure 32-op estimate.
    var ops: [frame_op_capacity]chrome.draw.Op = undefined;
    var dock_nodes: [16]chrome.ui.tree.UiNode = undefined;
    var dock_actions: [12]session_dock.ids.Entry = undefined;
    var text_runs: [frame_run_capacity]chrome.draw.Run = undefined;
    var text_bytes: [2048]u8 = undefined;
    const frame = try buildFrame(.{
        .id = .font_specimen,
        .viewport_px = .{ .width = 720, .height = 960 },
        .now_ns = 77,
    }, &tokens, .{
        .entries = &entries,
        .items = &items,
        .flex_scratch = &flex_scratch,
        .child_rects = &child_rects,
        .ops = &ops,
        .dock_nodes = &dock_nodes,
        .dock_actions = &dock_actions,
        .text_runs = &text_runs,
        .text_bytes = &text_bytes,
    });

    try std.testing.expect(frame.tree.entries.len > 7);
    try std.testing.expect(frame.draws.ops.len > 8);
    try std.testing.expect(frame.draws.ops[0] == .quad);
    var saw_primary_ascii_probe = false;
    var saw_korean_fallback_probe = false;
    for (frame.draws.ops) |op| switch (op) {
        .text => |text| for (text.runs) |run| {
            saw_primary_ascii_probe = saw_primary_ascii_probe or std.mem.indexOf(u8, run.text, "Il1 O0 MWmw") != null;
            saw_korean_fallback_probe = saw_korean_fallback_probe or std.mem.indexOf(u8, run.text, "가각간") != null;
        },
        else => {},
    };
    try std.testing.expect(saw_primary_ascii_probe);
    try std.testing.expect(saw_korean_fallback_probe);

    const card_index = frame.tree.find(session_dock.build.NodeIds.item(1)).?;
    const card_rect = frame.tree.entries[card_index].rect;
    try std.testing.expect(card_rect.width > 0);
    try std.testing.expect(card_rect.height > 0);
    try std.testing.expect(frame.tree.entries[card_index].effective_clip != null);
    const card_clip = frame.tree.entries[card_index].effective_clip.?;
    try std.testing.expect(card_clip.width > 0);
    try std.testing.expect(card_clip.height > 0);
    const card_x = card_rect.x + card_rect.width / 2;
    const card_y = card_rect.y + card_rect.height / 2;

    var state = chrome.ui.interaction.InteractionState{};
    try std.testing.expectEqual(@as(?chrome.ui.tree.UiActionId, null), try dispatchRecordedAction(&state, frame, .{
        .phase = .down,
        .x_px = card_x,
        .y_px = card_y,
        .timestamp_ns = 1,
    }));
    try std.testing.expectEqual(@as(?chrome.ui.tree.UiActionId, 7), try dispatchRecordedAction(&state, frame, .{
        .phase = .up,
        .x_px = 1000,
        .y_px = 1000,
        .timestamp_ns = 2,
    }));
}
