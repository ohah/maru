//! Test-only Chrome Lab fixture seam.
//!
//! This module owns synthetic UI inputs and recorded actions only. It deliberately does not
//! import AppSession, session, PTY, provider, filesystem, or a platform window host.

const std = @import("std");
const maru = @import("maru");
const lowering = @import("metal_lowering.zig");

const chrome = maru.chrome;

pub const ScenarioId = enum { empty, loading, retained_list };

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
};

pub const Frame = struct {
    tree: chrome.ui.tree.UiRectTree,
    draws: chrome.ChromeDraw,
};

/// Produces a deterministic, effect-free card fixture through the product UI tree and paint path.
/// Text nodes intentionally remain semantic until the later CoreText/readback slice owns shaping.
pub fn buildFrame(
    scenario: Scenario,
    tokens: *const chrome.Tokens,
    buffers: FrameBuffers,
) !Frame {
    const title: []const u8 = switch (scenario.id) {
        .empty => "No sessions yet",
        .loading => "Analyzing sessions",
        .retained_list => "Notion document root cause",
    };
    const visual: chrome.ui.tree.CardVisual = switch (scenario.id) {
        .empty => .{ .variant = .surface, .paint = .{} },
        .loading => .{ .variant = .raised, .paint = .{} },
        .retained_list => .{ .variant = .selected, .paint = .{} },
    };
    const root = chrome.ui.tree.container(.{
        .id = 1,
        .style = .{ .padding = .{ .top = 16, .right = 16, .bottom = 16, .left = 16 } },
        .overflow = .clip,
    }, &.{chrome.ui.tree.card(.{
        .id = 2,
        // The Lab fixture is responsive too: an auto-width, clipped card with an unmeasured text
        // leaf has a zero-width content clip and cannot be hit. Fill makes the card's paint, clip,
        // and action rect one concrete product-tree result at every supplied viewport size.
        .style = .{ .width = .{ .fill = 1 }, .height = .{ .px = 72 }, .padding = .{ .top = 12, .right = 12, .bottom = 12, .left = 12 } },
        .variant = visual.variant,
        .paint = visual.paint,
        .action = .{ .id = 100 },
        .overflow = .clip,
    }, &.{chrome.ui.tree.text(.{ .id = 3, .value = title, .tone = .primary })})});

    const tree = try chrome.ui.tree.build(root, .{
        .root_size = scenario.viewport_px,
        .max_entries = 3,
        .max_depth = 3,
    }, .{
        .entries = buffers.entries,
        .items = buffers.items,
        .flex_scratch = buffers.flex_scratch,
        .child_rects = buffers.child_rects,
    });
    const draws = try chrome.ui.paint.paint(tree, .{}, tokens, .sidebar, .{ .ops = buffers.ops });
    return .{ .tree = tree, .draws = draws };
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

test "Chrome Lab builds a deterministic card and records only its action" {
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
    var entries: [3]chrome.ui.tree.RectEntry = undefined;
    var items: [3]chrome.ui.layout.Item = undefined;
    var flex_scratch: [3]chrome.ui.layout.FlexScratch = undefined;
    var child_rects: [3]chrome.ui.layout.UiRect = undefined;
    var ops: [1]chrome.draw.Op = undefined;
    const frame = try buildFrame(.{
        .id = .retained_list,
        .viewport_px = .{ .width = 320, .height = 240 },
        .now_ns = 77,
    }, &tokens, .{
        .entries = &entries,
        .items = &items,
        .flex_scratch = &flex_scratch,
        .child_rects = &child_rects,
        .ops = &ops,
    });

    try std.testing.expectEqual(@as(usize, 3), frame.tree.entries.len);
    try std.testing.expectEqual(@as(usize, 1), frame.draws.ops.len);
    try std.testing.expect(frame.draws.ops[0] == .quad);

    const card_rect = frame.tree.entries[1].rect;
    try std.testing.expect(card_rect.width > 0);
    try std.testing.expect(card_rect.height > 0);
    const card_x = card_rect.x + card_rect.width / 2;
    const card_y = card_rect.y + card_rect.height / 2;

    var state = chrome.ui.interaction.InteractionState{};
    try std.testing.expectEqual(@as(?chrome.ui.tree.UiActionId, null), try dispatchRecordedAction(&state, frame, .{
        .phase = .down,
        .x_px = card_x,
        .y_px = card_y,
        .timestamp_ns = 1,
    }));
    try std.testing.expectEqual(@as(?chrome.ui.tree.UiActionId, 100), try dispatchRecordedAction(&state, frame, .{
        .phase = .up,
        .x_px = 1000,
        .y_px = 1000,
        .timestamp_ns = 2,
    }));
}
