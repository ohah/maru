//! Semantic paint and text projection for a completed Session Dock rect tree.
//!
//! The generic UI painter owns card backgrounds; this file adds only component-owned text runs.
//! It never asks a platform for glyph positions, so the backend remains a one-way ChromeDraw lowerer.

const std = @import("std");
const draw = @import("../../draw.zig");
const tokens = @import("../../tokens.zig");
const text_layout = @import("../../text_layout.zig");
const interaction = @import("../../ui/interaction.zig");
const ui_paint = @import("../../ui/paint.zig");
const tree = @import("../../ui/tree.zig");
const build = @import("build.zig");
const types = @import("types.zig");

pub const Buffers = struct {
    ops: []draw.Op,
    runs: []draw.Run,
    text_bytes: []u8,
};

pub const ViewError = ui_paint.PaintError || error{ InsufficientRunBuffer, InsufficientTextBuffer, MissingRect };

pub fn view(props: types.Props, frame: build.Frame, state: interaction.InteractionState, tk: *const tokens.Tokens, buffers: Buffers) ViewError!draw.ChromeDraw {
    const painted = try ui_paint.paint(frame.tree, state, tk, .sidebar, .{ .ops = buffers.ops });
    var writer = Writer{
        .props = props,
        .ops = buffers.ops,
        .op_count = painted.ops.len,
        .runs = buffers.runs,
        .text_bytes = buffers.text_bytes,
        .corner_radius_px = tk.space.corner_radius_px,
    };

    const header = find(frame.tree, build.NodeIds.header) orelse return error.MissingRect;
    try writer.text(header, 0, "AI 세션 기록", .surface_fg);
    var count_buf: [48]u8 = undefined;
    const count = std.fmt.bufPrint(&count_buf, "{d}개 표시 · 최근 {d}개", .{ props.displayed_count, props.recent_limit }) catch "";
    try writer.text(header, 1, count, .muted_fg);
    try writer.textRight(header, 0, if (props.loading or props.refreshing) spinner(props.spinner_phase) else "↻", .accent_bar);

    try writer.text(find(frame.tree, build.NodeIds.scope_workspace) orelse return error.MissingRect, 0, "작업공간", .surface_fg);
    try writer.text(find(frame.tree, build.NodeIds.scope_project) orelse return error.MissingRect, 0, "프로젝트", .surface_fg);
    try writer.text(find(frame.tree, build.NodeIds.scope_all) orelse return error.MissingRect, 0, "전체", .surface_fg);
    const search = find(frame.tree, build.NodeIds.search) orelse return error.MissingRect;
    try writer.text(search, 0, if (props.search.len == 0) "⌕ 세션 검색" else props.search, if (props.search.len == 0) .muted_fg else .surface_fg);

    if (props.loading and props.items.len == 0) {
        try writer.skeletons(find(frame.tree, build.NodeIds.content) orelse return error.MissingRect);
    }

    for (props.items, 0..) |item, index| {
        const rect = find(frame.tree, build.NodeIds.item(index)) orelse return error.MissingRect;
        switch (item) {
            .group => |group| {
                var group_buf: [96]u8 = undefined;
                const label = std.fmt.bufPrint(&group_buf, "{s}  {s}  {d}", .{ if (group.collapsed) "›" else "⌄", group.label, group.count }) catch group.label;
                try writer.text(rect, 0, label, .surface_fg);
            },
            .card => |card| {
                var title_buf: [384]u8 = undefined;
                const title = std.fmt.bufPrint(&title_buf, "{s}  {s}", .{ card.provider.label(), card.title }) catch card.title;
                try writer.text(rect, 0, title, .surface_fg);
                try writer.text(rect, 1, card.summary, .muted_fg);
                try writer.text(rect, 2, card.metadata, .muted_fg);
            },
        }
    }
    return .{ .layer = .sidebar, .ops = buffers.ops[0..writer.op_count] };
}

const Writer = struct {
    props: types.Props,
    ops: []draw.Op,
    op_count: usize,
    runs: []draw.Run,
    run_count: usize = 0,
    text_bytes: []u8,
    text_count: usize = 0,
    corner_radius_px: u16,

    fn text(self: *Writer, rect: tree.RectEntry, line: u32, source: []const u8, role: tokens.ColorRole) ViewError!void {
        const cw = self.props.cell_width_px;
        const ch = self.props.cell_height_px;
        if (cw == 0 or ch == 0) return;
        const x = rect.rect.x + @as(f32, @floatFromInt(cw));
        const y = rect.rect.y + @as(f32, @floatFromInt(ch * (line + 1)));
        if (rect.effective_clip) |clip| {
            // CoreText lowering receives semantic baselines, not a second content scissor. Do not
            // emit a baseline outside the tree's already-published clip while an item is partial.
            if (y < clip.y or y >= clip.y + clip.height) return;
        }
        const available_px = rect.rect.width - @as(f32, @floatFromInt(cw * 2));
        if (available_px <= 0) return;
        const max_cols: u16 = @intFromFloat(@floor(available_px / @as(f32, @floatFromInt(cw))));
        try self.emit(x, y, source, max_cols, .head, role);
    }

    fn textRight(self: *Writer, rect: tree.RectEntry, line: u32, source: []const u8, role: tokens.ColorRole) ViewError!void {
        const cw = self.props.cell_width_px;
        const ch = self.props.cell_height_px;
        if (cw == 0 or ch == 0) return;
        const cols: u16 = @intFromFloat(@floor(rect.rect.width / @as(f32, @floatFromInt(cw))));
        const width = text_layout.displayCols(source, null);
        const start: u16 = @intCast(@min(width, cols));
        const x = rect.rect.x + @as(f32, @floatFromInt((cols - start) * @as(u16, @intCast(cw))));
        const y = rect.rect.y + @as(f32, @floatFromInt(ch * (line + 1)));
        try self.emit(x, y, source, start, .tail, role);
    }

    fn emit(self: *Writer, x: f32, y: f32, source: []const u8, cols: u16, anchor: text_layout.Anchor, role: tokens.ColorRole) ViewError!void {
        if (cols == 0) return;
        if (self.op_count == self.ops.len) return error.InsufficientTextBuffer;
        if (self.run_count == self.runs.len) return error.InsufficientRunBuffer;
        const start = self.text_count;
        var plan = text_layout.plan(source, 0, cols, anchor, null);
        while (plan.next()) |item| switch (item) {
            .cluster => |cluster| try self.appendBytes(source[cluster.start..cluster.end]),
            .ellipsis => try self.appendBytes("…"),
        };
        self.runs[self.run_count] = .{ .text = self.text_bytes[start..self.text_count] };
        self.ops[self.op_count] = .{ .text = .{ .origin = .{ .x = @intFromFloat(@floor(x)), .y = @intFromFloat(@floor(y)) }, .runs = self.runs[self.run_count .. self.run_count + 1], .role = role } };
        self.run_count += 1;
        self.op_count += 1;
    }

    fn appendBytes(self: *Writer, bytes: []const u8) ViewError!void {
        if (bytes.len > self.text_bytes.len -| self.text_count) return error.InsufficientTextBuffer;
        @memcpy(self.text_bytes[self.text_count..][0..bytes.len], bytes);
        self.text_count += bytes.len;
    }

    /// There is no completed snapshot to preserve during the first scan. Paint three inert card
    /// placeholders instead of pretending an empty archive is a completed result. These quads
    /// deliberately do not enter the rect tree or action table, so an impatient click cannot
    /// resolve to a stale/fictional session action.
    fn skeletons(self: *Writer, content: tree.RectEntry) ViewError!void {
        const ch = self.props.cell_height_px;
        if (ch == 0) return;
        const metrics = types.Metrics.fromCellHeight(ch);
        const left = content.rect.x + @as(f32, @floatFromInt(metrics.pad));
        const available = content.rect.width - @as(f32, @floatFromInt(metrics.pad * 2));
        if (available <= 0) return;
        const line_h = @max(ch / 2, 2);
        const start_y = content.rect.y + @as(f32, @floatFromInt(metrics.gap));
        for (0..3) |card_index| {
            const card_y = start_y + @as(f32, @floatFromInt(card_index * (metrics.card_h + metrics.gap)));
            if (card_y >= content.rect.y + content.rect.height) break;
            try self.skeletonLine(left, card_y + @as(f32, @floatFromInt(ch)), available, line_h);
            try self.skeletonLine(left, card_y + @as(f32, @floatFromInt(ch * 2 + metrics.gap)), available * 0.82, line_h);
            try self.skeletonLine(left, card_y + @as(f32, @floatFromInt(ch * 3 + metrics.gap * 2)), available * 0.58, line_h);
        }
    }

    fn skeletonLine(self: *Writer, x: f32, y: f32, width: f32, height: u32) ViewError!void {
        if (width <= 0 or height == 0) return;
        if (self.op_count == self.ops.len) return error.InsufficientTextBuffer;
        self.ops[self.op_count] = .{ .quad = .{
            .rect = .{
                .x = @intFromFloat(@floor(x)),
                .y = @intFromFloat(@floor(y)),
                .w = @intFromFloat(@floor(width)),
                .h = height,
            },
            .fill_role = .divider,
            .corner_radii = .{ self.corner_radius_px, self.corner_radius_px, self.corner_radius_px, self.corner_radius_px },
            .alpha = 0x90,
        } };
        self.op_count += 1;
    }
};

fn find(snapshot: tree.UiRectTree, id: tree.UiId) ?tree.RectEntry {
    const index = snapshot.find(id) orelse return null;
    return snapshot.entries[index];
}

fn spinner(phase: u3) []const u8 {
    return switch (phase) {
        0 => "◴",
        1 => "◷",
        2 => "◶",
        3 => "◵",
        4 => "◴",
        5 => "◷",
        6 => "◶",
        7 => "◵",
    };
}

test "SessionDock view emits card paint and ellipsized semantic text from one tree" {
    const props = types.Props{
        .viewport_px = .{ .width = 320, .height = 480 },
        .cell_width_px = 8,
        .cell_height_px = 16,
        .snapshot_generation = 4,
        .displayed_count = 1,
        .search = "long query",
        .items = &.{
            .{ .group = .{ .identity = 1, .label = "workspace", .count = 1 } },
            .{ .card = .{ .identity = 2, .provider = .codex, .title = "a title that intentionally exceeds a narrow card", .summary = "summary", .metadata = "1 message", .selected = true } },
        },
    };
    var nodes: [9]tree.UiNode = undefined;
    var entries: [10]tree.RectEntry = undefined;
    var layout_items: [10]@import("../../ui/layout.zig").Item = undefined;
    var flex_scratch: [10]@import("../../ui/layout.zig").FlexScratch = undefined;
    var child_rects: [10]@import("../../ui/layout.zig").UiRect = undefined;
    var actions: [8]@import("ids.zig").Entry = undefined;
    const frame = try build.build(props, .{
        .nodes = &nodes,
        .entries = &entries,
        .layout_items = &layout_items,
        .flex_scratch = &flex_scratch,
        .child_rects = &child_rects,
        .actions = &actions,
    });
    const tk = tokens.Tokens.rich(.{
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
    var ops: [32]draw.Op = undefined;
    var runs: [32]draw.Run = undefined;
    var text_bytes: [1024]u8 = undefined;
    const out = try view(props, frame, .{}, &tk, .{ .ops = &ops, .runs = &runs, .text_bytes = &text_bytes });
    try std.testing.expect(out.ops.len > 8);
    var saw_quad = false;
    var saw_title = false;
    for (out.ops) |op| switch (op) {
        .quad => saw_quad = true,
        .text => |text| {
            for (text.runs) |run| {
                if (std.mem.indexOf(u8, run.text, "Codex") != null) saw_title = true;
            }
        },
        else => {},
    };
    try std.testing.expect(saw_quad);
    try std.testing.expect(saw_title);
}

test "SessionDock initial loading paints inert three-line skeleton cards" {
    const props = types.Props{
        .viewport_px = .{ .width = 320, .height = 480 },
        .cell_width_px = 8,
        .cell_height_px = 16,
        .snapshot_generation = 4,
        .displayed_count = 0,
        .loading = true,
    };
    var nodes: [8]tree.UiNode = undefined;
    var entries: [8]tree.RectEntry = undefined;
    var layout_items: [8]@import("../../ui/layout.zig").Item = undefined;
    var flex_scratch: [8]@import("../../ui/layout.zig").FlexScratch = undefined;
    var child_rects: [8]@import("../../ui/layout.zig").UiRect = undefined;
    var actions: [5]@import("ids.zig").Entry = undefined;
    const frame = try build.build(props, .{
        .nodes = &nodes,
        .entries = &entries,
        .layout_items = &layout_items,
        .flex_scratch = &flex_scratch,
        .child_rects = &child_rects,
        .actions = &actions,
    });
    const tk = tokens.Tokens.rich(.{
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
    var ops: [24]draw.Op = undefined;
    var runs: [8]draw.Run = undefined;
    var text_bytes: [256]u8 = undefined;
    const out = try view(props, frame, .{}, &tk, .{ .ops = &ops, .runs = &runs, .text_bytes = &text_bytes });
    var skeleton_lines: usize = 0;
    for (out.ops) |op| switch (op) {
        .quad => |quad| {
            if (quad.fill_role == .divider and quad.alpha == 0x90) skeleton_lines += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 9), skeleton_lines);
}
