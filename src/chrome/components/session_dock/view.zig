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

// The dock owns this registered SVG icon. A text glyph such as `↻` varies by fallback font and
// cannot promise the size or optical centre of a Chrome header affordance.
// Dock controls use component-specific coverage glyphs: all occupy the standard two-cell
// icon slot, while their tighter SVG view boxes keep their optical size consistent with cards.
const refresh_icon = "\u{F0021}";
const search_icon = "\u{F0022}";
const chevron_down_icon = "\u{F0023}";
const chevron_right_icon = "\u{F0024}";
const resume_icon = "\u{F000C}";
const reveal_icon = "\u{F0011}";
const host_label = "Local Mac";

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
    try writer.textStrong(header, 0, "AI 세션 기록", .surface_fg, 2, false, true);
    var count_buf: [48]u8 = undefined;
    const count = std.fmt.bufPrint(&count_buf, "{d}개 표시 · 최근 {d}개", .{ props.displayed_count, props.recent_limit }) catch "";
    try writer.text(header, 1, count, .muted_fg, 2, false, true);
    try writer.headerLabel(header, host_label);
    try writer.textRight(header, if (props.loading or props.refreshing) spinner(props.spinner_phase) else refresh_icon, if (props.loading or props.refreshing) .muted_fg else .surface_fg, !(props.loading or props.refreshing));

    try writer.text(find(frame.tree, build.NodeIds.scope_workspace) orelse return error.MissingRect, 0, "작업공간", .surface_fg, 1, false, true);
    try writer.text(find(frame.tree, build.NodeIds.scope_project) orelse return error.MissingRect, 0, "프로젝트", .surface_fg, 1, false, true);
    try writer.text(find(frame.tree, build.NodeIds.scope_all) orelse return error.MissingRect, 0, "전체", .surface_fg, 1, false, true);
    const search = find(frame.tree, build.NodeIds.search) orelse return error.MissingRect;
    try writer.textInset(search, 0, search_icon, .muted_fg, 1, true, true, 1);
    try writer.textInset(search, 0, if (props.search.len == 0) "세션 검색" else props.search, if (props.search.len == 0) .muted_fg else .surface_fg, 1, false, true, 4);

    if (props.loading and props.items.len == 0) {
        try writer.skeletons(find(frame.tree, build.NodeIds.content) orelse return error.MissingRect);
    }

    for (props.items, 0..) |item, index| {
        const rect = find(frame.tree, build.NodeIds.item(index)) orelse return error.MissingRect;
        switch (item) {
            .group => |group| {
                var group_buf: [96]u8 = undefined;
                const label = std.fmt.bufPrint(&group_buf, "{s} {s}  {d}", .{ if (group.collapsed) chevron_right_icon else chevron_down_icon, group.label, group.count }) catch group.label;
                try writer.textStrong(rect, 0, label, .surface_fg, 1, true, true);
            },
            .card => |card| {
                const card_rect = if (card.expanded != null)
                    find(frame.tree, build.NodeIds.cardHeader(index)) orelse return error.MissingRect
                else
                    rect;
                // Provider belongs to the metadata badge, not the title.  Prefixing the title
                // made long session names lose their first useful words and differed from the
                // dock's reference hierarchy (title → safe summary → provider metadata).
                // The three base rows deliberately occupy 1/3/5 cell baselines.  This gives
                // title, safe summary, and metadata visible breathing room without inventing a
                // second card rect or breaking the one shared scroll/hit-test geometry.
                try writer.textStrong(card_rect, 0, card.title, .surface_fg, 6, false, false);
                try writer.text(card_rect, 2, card.summary, .muted_fg, 6, false, false);
                try writer.cardMetadata(card_rect, 4, 6, card.provider.label(), card.metadata);
                // The whole title card remains one disclosure action, but its trailing chevron
                // makes that interaction discoverable and shares the exact card rect used by
                // pointer/Enter. No separate tiny hit target is manufactured for the icon.
                try writer.textRight(card_rect, chevron_down_icon, .surface_fg, true);
                if (card.expanded) |expanded| try writer.expanded(frame.tree, index, expanded);
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

    fn text(self: *Writer, rect: tree.RectEntry, line: u32, source: []const u8, role: tokens.ColorRole, line_count: u32, wide_icons: bool, centered: bool) ViewError!void {
        return self.textStyled(rect, line, source, role, line_count, wide_icons, centered, false);
    }

    /// Weight is semantic hierarchy, not a per-font coordinate tweak. The backend already owns
    /// the selected face and its measured advance, so title/group emphasis remains font-safe.
    fn textStrong(self: *Writer, rect: tree.RectEntry, line: u32, source: []const u8, role: tokens.ColorRole, line_count: u32, wide_icons: bool, centered: bool) ViewError!void {
        return self.textStyled(rect, line, source, role, line_count, wide_icons, centered, true);
    }

    fn textStyled(self: *Writer, rect: tree.RectEntry, line: u32, source: []const u8, role: tokens.ColorRole, line_count: u32, wide_icons: bool, centered: bool, bold: bool) ViewError!void {
        return self.textInsetStyled(rect, line, source, role, line_count, wide_icons, centered, 1, bold);
    }

    /// Places an entire line stack inside the completed rect before selecting the requested line.
    /// This keeps scope/search/group labels optically centred without font-specific pixel nudges.
    fn textInset(self: *Writer, rect: tree.RectEntry, line: u32, source: []const u8, role: tokens.ColorRole, line_count: u32, wide_icons: bool, centered: bool, left_inset_cols: u16) ViewError!void {
        return self.textInsetStyled(rect, line, source, role, line_count, wide_icons, centered, left_inset_cols, false);
    }

    fn textInsetStyled(self: *Writer, rect: tree.RectEntry, line: u32, source: []const u8, role: tokens.ColorRole, line_count: u32, wide_icons: bool, centered: bool, left_inset_cols: u16, bold: bool) ViewError!void {
        const cw = self.props.cell_width_px;
        const ch = self.props.cell_height_px;
        if (cw == 0 or ch == 0 or line_count == 0 or line >= line_count) return;
        const cell_height: f32 = @floatFromInt(ch);
        const stack_height = cell_height * @as(f32, @floatFromInt(line_count));
        const x = rect.rect.x + @as(f32, @floatFromInt(cw)) * @as(f32, @floatFromInt(left_inset_cols));
        const y = if (centered)
            if (rect.rect.height >= stack_height) rect.rect.y + (rect.rect.height - stack_height) / 2 + cell_height * @as(f32, @floatFromInt(line)) else return
        else
            rect.rect.y + cell_height * @as(f32, @floatFromInt(line + 1));
        if (!loweredTextCellFitsClip(rect, y, ch)) return;
        const required_inset_cols = @as(u32, left_inset_cols) + 1;
        const available_px = rect.rect.width - @as(f32, @floatFromInt(cw)) * @as(f32, @floatFromInt(required_inset_cols));
        if (available_px <= 0) return;
        const max_cols: u16 = @intFromFloat(@floor(available_px / @as(f32, @floatFromInt(cw))));
        try self.emit(x, y, source, max_cols, .head, role, wide_icons, bold);
    }

    fn textRight(self: *Writer, rect: tree.RectEntry, source: []const u8, role: tokens.ColorRole, wide_icon: bool) ViewError!void {
        const cw = self.props.cell_width_px;
        const ch = self.props.cell_height_px;
        if (cw == 0 or ch == 0) return;
        // Trailing header affordances need the same one-cell horizontal inset as ordinary
        // labels. Placing the refresh glyph at the outer rect edge works for a cell-sized
        // terminal glyph, but a CoreText fallback glyph can have wider natural ink and will
        // visibly touch or cross the rounded-card clip once it is lowered as a pixel GpuGlyph.
        const inset_px: f32 = @floatFromInt(cw);
        const usable_width = rect.rect.width - inset_px;
        if (usable_width <= 0) return;
        const cols: u16 = @intFromFloat(@floor(usable_width / @as(f32, @floatFromInt(cw))));
        const icon_predicate: ?text_layout.WideIconFn = if (wide_icon) isSessionDockIcon else null;
        const width = text_layout.displayCols(source, icon_predicate);
        // The header owns one stable two-cell affordance slot. A loading spinner is only one
        // cell wide, so centre it inside that same slot instead of letting refresh→spinner
        // move one cell to the right.
        const slot_cols: u16 = 2;
        if (width == 0 or width > slot_cols or cols < slot_cols) return;
        const start: u16 = @intCast(width);
        const cell_width: f32 = @floatFromInt(cw);
        const slot_width = @as(f32, @floatFromInt(slot_cols)) * cell_width;
        const glyph_width = @as(f32, @floatFromInt(start)) * cell_width;
        const x = rect.rect.x + rect.rect.width - inset_px - slot_width + (slot_width - glyph_width) / 2;
        const y = rect.rect.y + (rect.rect.height - @as(f32, @floatFromInt(ch))) / 2;
        try self.emit(x, y, source, start, .tail, role, wide_icon, false);
    }

    /// The provenance label shares the header baseline with refresh but is placed from the same
    /// measured display-column plan as every other Chrome label. It is intentionally text-only
    /// until the registered host icon is added; a terminal fallback glyph would reintroduce the
    /// font-dependent size drift this component otherwise avoids.
    fn headerLabel(self: *Writer, rect: tree.RectEntry, source: []const u8) ViewError!void {
        const cw = self.props.cell_width_px;
        const ch = self.props.cell_height_px;
        if (cw == 0 or ch == 0) return;
        const label_cols = plannedCols(source, 16);
        const refresh_slot_cols: u32 = 3;
        const total_cols: u32 = @intCast(label_cols);
        const required_cols = total_cols + refresh_slot_cols + 2;
        const available_cols: u32 = @intFromFloat(@floor(rect.rect.width / @as(f32, @floatFromInt(cw))));
        if (required_cols > available_cols) return;
        const x = rect.rect.x + rect.rect.width - @as(f32, @floatFromInt((refresh_slot_cols + total_cols + 1) * cw));
        const y = rect.rect.y + (rect.rect.height - @as(f32, @floatFromInt(ch))) / 2;
        try self.emit(x, y, source, label_cols, .head, .surface_fg, false, true);
    }

    /// Provider is a dedicated metadata slot rather than a title prefix.  Both runs use the
    /// same third-line baseline and bounded column plan, keeping the label readable without
    /// letting long model metadata overlap the card's disclosure affordance.
    fn cardMetadata(self: *Writer, rect: tree.RectEntry, line: u32, line_count: u32, provider: []const u8, metadata: []const u8) ViewError!void {
        try self.text(rect, line, provider, .surface_fg, line_count, false, false);
        const cw = self.props.cell_width_px;
        const ch = self.props.cell_height_px;
        if (cw == 0 or ch == 0) return;
        const provider_cols = plannedCols(provider, 24);
        const left_inset_cols: u16 = provider_cols + 2;
        const y = rect.rect.y + @as(f32, @floatFromInt(ch)) * @as(f32, @floatFromInt(line + 1));
        if (!loweredTextCellFitsClip(rect, y, ch)) return;
        const used_px = @as(f32, @floatFromInt((left_inset_cols + 1) * cw));
        const available_px = rect.rect.width - used_px;
        if (available_px <= 0) return;
        const max_cols: u16 = @intFromFloat(@floor(available_px / @as(f32, @floatFromInt(cw))));
        const x = rect.rect.x + @as(f32, @floatFromInt(left_inset_cols * cw));
        try self.emit(x, y, metadata, max_cols, .head, .muted_fg, false, false);
    }

    fn expanded(self: *Writer, snapshot: tree.UiRectTree, index: usize, expanded_props: types.Expanded) ViewError!void {
        const detail = find(snapshot, build.NodeIds.expandedDetail(index)) orelse return error.MissingRect;
        // The reserved detail rect contains a bounded line stack.  Passing one as the line count
        // here used to make `textInset` reject every line after the heading, leaving ready cards
        // visually empty even though the worker had returned safe turns.
        const detail_lines: u32 = 9;
        try self.text(detail, 0, switch (expanded_props.state) {
            .loading => "세션 분석 중",
            .ready => "최근 대화",
            .stale => "세션 원본이 변경되었습니다",
            .unavailable => "세션을 열 수 없습니다",
        }, .surface_fg, detail_lines, false, false);
        switch (expanded_props.state) {
            .ready => {
                if (expanded_props.action_record_count > 0) {
                    var count: [80]u8 = undefined;
                    const label = std.fmt.bufPrint(&count, "도구/권한 관련 기록 {d}건", .{expanded_props.action_record_count}) catch "도구/권한 관련 기록";
                    try self.text(detail, 1, label, .muted_fg, detail_lines, false, false);
                }
                for (expanded_props.turns, 0..) |turn, turn_index| {
                    const line: u32 = @intCast(2 + turn_index * 2);
                    try self.text(detail, line, switch (turn.role) {
                        .user => "사용자",
                        .assistant => "에이전트",
                    }, .muted_fg, detail_lines, false, false);
                    try self.text(detail, line + 1, turn.text, .surface_fg, detail_lines, false, false);
                }
            },
            .loading => try self.skeletons(detail),
            .stale => try self.text(detail, 2, "안전하게 재개하거나 로그를 열 수 없습니다.", .muted_fg, detail_lines, false, false),
            .unavailable => try self.text(detail, 2, "원본을 읽을 수 없습니다.", .muted_fg, detail_lines, false, false),
        }
        try self.action(find(snapshot, build.NodeIds.resumeAction(index)) orelse return error.MissingRect, resume_icon ++ " 터미널에서 이어하기");
        try self.action(find(snapshot, build.NodeIds.reveal(index)) orelse return error.MissingRect, reveal_icon ++ " 로그 보기");
        if (expanded_props.focus_live_enabled)
            try self.action(find(snapshot, build.NodeIds.focusLive(index)) orelse return error.MissingRect, "열린 세션으로 이동");
    }

    fn action(self: *Writer, rect: tree.RectEntry, source: []const u8) ViewError!void {
        const cw = self.props.cell_width_px;
        const ch = self.props.cell_height_px;
        if (cw == 0 or ch == 0) return;
        const available_px = rect.rect.width - @as(f32, @floatFromInt(cw * 2));
        if (available_px <= 0) return;
        const max_cols: u16 = @intFromFloat(@floor(available_px / @as(f32, @floatFromInt(cw))));
        const planned = plannedCols(source, max_cols);
        if (planned == 0) return;
        const text_width: f32 = @floatFromInt(@as(u32, planned) * cw);
        const x = rect.rect.x + (rect.rect.width - text_width) / 2;
        const y = rect.rect.y + (rect.rect.height - @as(f32, @floatFromInt(ch))) / 2;
        if (!loweredTextCellFitsClip(rect, y, ch)) return;
        try self.emit(x, y, source, max_cols, .head, if (rect.action.?.enabled) .surface_fg else .muted_fg, true, true);
    }

    fn plannedCols(source: []const u8, max_cols: u16) u16 {
        var plan = text_layout.plan(source, 0, max_cols, .head, isSessionDockIcon);
        while (plan.next()) |_| {}
        return plan.endCol();
    }

    fn emit(self: *Writer, x: f32, y: f32, source: []const u8, cols: u16, anchor: text_layout.Anchor, role: tokens.ColorRole, wide_icons: bool, bold: bool) ViewError!void {
        if (cols == 0) return;
        if (self.op_count == self.ops.len) return error.InsufficientTextBuffer;
        if (self.run_count == self.runs.len) return error.InsufficientRunBuffer;
        const start = self.text_count;
        var plan = text_layout.plan(source, 0, cols, anchor, if (wide_icons) isSessionDockIcon else null);
        while (plan.next()) |item| switch (item) {
            .cluster => |cluster| try self.appendBytes(source[cluster.start..cluster.end]),
            .ellipsis => try self.appendBytes("…"),
        };
        self.runs[self.run_count] = .{ .text = self.text_bytes[start..self.text_count], .bold = bold };
        self.ops[self.op_count] = .{ .text = .{ .origin = .{ .x = @intFromFloat(@floor(x)), .y = @intFromFloat(@floor(y)) }, .runs = self.runs[self.run_count .. self.run_count + 1], .role = role, .wide_icons = wide_icons } };
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
        const start_y = content.rect.y + @as(f32, @floatFromInt(metrics.item_gap));
        for (0..3) |card_index| {
            const card_y = start_y + @as(f32, @floatFromInt(card_index * (metrics.card_h + metrics.item_gap)));
            if (card_y >= content.rect.y + content.rect.height) break;
            try self.skeletonLine(left, card_y + @as(f32, @floatFromInt(ch)), available, line_h);
            try self.skeletonLine(left, card_y + @as(f32, @floatFromInt(ch * 2 + metrics.item_gap)), available * 0.82, line_h);
            try self.skeletonLine(left, card_y + @as(f32, @floatFromInt(ch * 3 + metrics.item_gap * 2)), available * 0.58, line_h);
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

/// `chrome_draw_lowering` floors a semantic text origin to a terminal cell row before CoreText
/// rasterization. A partial item therefore cannot use the unquantized origin as a clip test: a
/// nominally in-clip origin can lower to the preceding, out-of-clip glyph cell. We intentionally
/// omit that whole cell rather than add an unrelated glyph scissor path just for scrolling.
fn loweredTextCellFitsClip(rect: tree.RectEntry, origin_y: f32, cell_height_px: u32) bool {
    const clip = rect.effective_clip orelse return true;
    if (cell_height_px == 0) return false;
    const cell_height: i32 = @intCast(cell_height_px);
    const origin: i32 = @intFromFloat(@floor(origin_y));
    const lowered_top = @divFloor(origin, cell_height) * cell_height;
    const clip_top: i32 = @intFromFloat(@ceil(clip.y));
    const clip_bottom: i32 = @intFromFloat(@floor(clip.y + clip.height));
    return lowered_top >= clip_top and lowered_top <= clip_bottom - cell_height;
}

fn isSessionDockIcon(codepoint: u21) bool {
    return switch (codepoint) {
        0xF000C, 0xF0011, 0xF0021, 0xF0022, 0xF0023, 0xF0024 => true,
        else => false,
    };
}

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
            .{ .card = .{ .identity = 2, .provider = .claude, .title = "a title that intentionally exceeds a narrow card", .summary = "summary", .metadata = "Claude · 메시지 1개 · claude-fixture", .selected = true } },
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
    var saw_provider = false;
    var refresh_origin_x: ?i32 = null;
    var workspace_origin_y: ?i32 = null;
    var project_origin_y: ?i32 = null;
    var all_origin_y: ?i32 = null;
    var saw_search_icon = false;
    var saw_group_chevron = false;
    for (out.ops) |op| switch (op) {
        .quad => saw_quad = true,
        .text => |text| {
            for (text.runs) |run| {
                saw_provider = saw_provider or std.mem.indexOf(u8, run.text, "Claude") != null;
                if (std.mem.eql(u8, run.text, refresh_icon)) {
                    refresh_origin_x = text.origin.x;
                    try std.testing.expect(text.wide_icons);
                }
                if (std.mem.eql(u8, run.text, "작업공간")) workspace_origin_y = text.origin.y;
                if (std.mem.eql(u8, run.text, "프로젝트")) project_origin_y = text.origin.y;
                if (std.mem.eql(u8, run.text, "전체")) all_origin_y = text.origin.y;
                if (std.mem.eql(u8, run.text, search_icon)) {
                    saw_search_icon = true;
                    try std.testing.expect(text.wide_icons);
                }
                if (std.mem.indexOf(u8, run.text, chevron_down_icon) != null) {
                    saw_group_chevron = true;
                    try std.testing.expect(text.wide_icons);
                }
            }
        },
        else => {},
    };
    try std.testing.expect(saw_quad);
    try std.testing.expect(saw_provider);
    try std.testing.expect(saw_search_icon);
    try std.testing.expect(saw_group_chevron);
    inline for (.{ .scope_workspace, .scope_project, .scope_all }, .{ workspace_origin_y, project_origin_y, all_origin_y }) |id, origin| {
        const scope = find(frame.tree, @field(build.NodeIds, @tagName(id))) orelse return error.TestUnexpectedResult;
        const expected_y: i32 = @intFromFloat(@floor(scope.rect.y + (scope.rect.height - @as(f32, @floatFromInt(props.cell_height_px))) / 2));
        try std.testing.expectEqual(expected_y, origin orelse return error.TestUnexpectedResult);
    }
    const refresh_x = refresh_origin_x orelse return error.TestUnexpectedResult;
    const header = find(frame.tree, build.NodeIds.header) orelse return error.TestUnexpectedResult;
    const right_ink_edge = refresh_x + @as(i32, @intCast(props.cell_width_px * 2));
    const expected_right_edge: i32 = @intFromFloat(@floor(header.rect.x + header.rect.width - @as(f32, @floatFromInt(props.cell_width_px))));
    try std.testing.expect(right_ink_edge <= expected_right_edge);

    // The loading indicator must not re-anchor at the outer header edge. It is a one-cell
    // glyph optically centred in the same two-cell slot as the registered refresh SVG.
    var loading_props = props;
    loading_props.loading = true;
    const loading_out = try view(loading_props, frame, .{}, &tk, .{ .ops = &ops, .runs = &runs, .text_bytes = &text_bytes });
    var spinner_origin_x: ?i32 = null;
    for (loading_out.ops) |op| switch (op) {
        .text => |text| for (text.runs) |run| {
            if (std.mem.eql(u8, run.text, spinner(loading_props.spinner_phase))) {
                spinner_origin_x = text.origin.x;
                try std.testing.expect(!text.wide_icons);
            }
        },
        else => {},
    };
    const spinner_x = spinner_origin_x orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(refresh_x + @as(i32, @intCast(props.cell_width_px / 2)), spinner_x);
}

test "SessionDock partial card never emits a CoreText cell that crosses its published clip" {
    const metrics = types.Metrics.fromCellHeight(16);
    const props = types.Props{
        // Fixed chrome is intentionally roomier in AS4-e. Keep enough scroll viewport below it
        // to prove a one-pixel partial first card cannot suppress the next card's title.
        .viewport_px = .{ .width = 320, .height = 480 },
        .cell_width_px = 8,
        .cell_height_px = 16,
        .snapshot_generation = 4,
        .displayed_count = 2,
        // Leave one backing pixel of the first row inside the clip. Its own lowered glyph cells
        // must still be rejected, while the following row begins in the same content clip.
        .content_first_item_origin_y_px = -@as(i32, @intCast(metrics.card_h - 1)),
        .items = &.{
            .{ .card = .{ .identity = 1, .provider = .claude, .title = "partial-card-title", .summary = "visible-summary", .metadata = "visible-meta" } },
            .{ .card = .{ .identity = 2, .provider = .codex, .title = "next-card-title", .summary = "next-summary", .metadata = "next-meta" } },
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
    var saw_partial_title = false;
    var saw_partial_summary = false;
    var saw_partial_metadata = false;
    var saw_next_title = false;
    for (out.ops) |op| switch (op) {
        .text => |text| for (text.runs) |run| {
            saw_partial_title = saw_partial_title or std.mem.indexOf(u8, run.text, "partial-card-title") != null;
            saw_partial_summary = saw_partial_summary or std.mem.indexOf(u8, run.text, "visible-summary") != null;
            saw_partial_metadata = saw_partial_metadata or std.mem.indexOf(u8, run.text, "visible-meta") != null;
            saw_next_title = saw_next_title or std.mem.indexOf(u8, run.text, "next-card-title") != null;
        },
        else => {},
    };
    try std.testing.expect(!saw_partial_title);
    try std.testing.expect(!saw_partial_summary);
    try std.testing.expect(!saw_partial_metadata);
    try std.testing.expect(saw_next_title);
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
    var runs: [9]draw.Run = undefined;
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
