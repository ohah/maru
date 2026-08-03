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
const typography = @import("../../ui/typography.zig");
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
    var count_buf: [48]u8 = undefined;
    const count = std.fmt.bufPrint(&count_buf, "{d}개 표시 · 최근 {d}개", .{ props.displayed_count, props.recent_limit }) catch "";
    try writer.headerStack(header, "Agent 세션 기록", count);
    try writer.headerLabel(header, host_label);
    try writer.textRight(header, if (props.loading or props.refreshing) spinner(props.spinner_phase) else refresh_icon, if (props.loading or props.refreshing) .muted_fg else .surface_fg, !(props.loading or props.refreshing));

    try writer.text(find(frame.tree, build.NodeIds.scope_workspace) orelse return error.MissingRect, 0, "작업공간", .surface_fg, .control, 1, false, true);
    try writer.text(find(frame.tree, build.NodeIds.scope_project) orelse return error.MissingRect, 0, "프로젝트", .surface_fg, .control, 1, false, true);
    try writer.text(find(frame.tree, build.NodeIds.scope_all) orelse return error.MissingRect, 0, "전체", .surface_fg, .control, 1, false, true);
    const search = find(frame.tree, build.NodeIds.search) orelse return error.MissingRect;
    try writer.textInset(search, 0, search_icon, .muted_fg, .control, 1, true, true, 1);
    try writer.textInset(search, 0, if (props.search.len == 0) "세션 검색" else props.search, if (props.search.len == 0) .muted_fg else .surface_fg, .control, 1, false, true, 4);

    if (props.loading and props.items.len == 0) {
        try writer.skeletons(find(frame.tree, build.NodeIds.content) orelse return error.MissingRect);
    }

    for (props.items, 0..) |item, index| {
        const rect = find(frame.tree, build.NodeIds.item(index)) orelse return error.MissingRect;
        switch (item) {
            .group => |group| {
                try writer.groupHeader(rect, group);
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
                try writer.textStrong(card_rect, 0, card.title, .surface_fg, .card_heading, 6, false, false);
                try writer.text(card_rect, 2, card.summary, .muted_fg, .body, 6, false, false);
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

    fn text(self: *Writer, rect: tree.RectEntry, line: u32, source: []const u8, role: tokens.ColorRole, text_role: typography.ChromeTextRole, line_count: u32, wide_icons: bool, centered: bool) ViewError!void {
        return self.textStyled(rect, line, source, role, text_role, line_count, wide_icons, centered, false);
    }

    /// Weight is semantic hierarchy, not a per-font coordinate tweak. The backend already owns
    /// the selected face and its measured advance, so title/group emphasis remains font-safe.
    fn textStrong(self: *Writer, rect: tree.RectEntry, line: u32, source: []const u8, role: tokens.ColorRole, text_role: typography.ChromeTextRole, line_count: u32, wide_icons: bool, centered: bool) ViewError!void {
        return self.textStyled(rect, line, source, role, text_role, line_count, wide_icons, centered, true);
    }

    /// The dock header is a real two-role typographic stack, not two terminal cells.  Centre
    /// its heading/supporting line boxes together so point-size changes or a 2x backing scale
    /// cannot make the count cling to the heading as in the legacy cell path.
    fn headerStack(self: *Writer, rect: tree.RectEntry, heading: []const u8, supporting: []const u8) ViewError!void {
        const cw = self.props.cell_width_px;
        if (cw == 0) return;
        const available_px = rect.rect.width - @as(f32, @floatFromInt(cw * 2));
        if (available_px <= 0) return;
        const max_cols: u16 = @intFromFloat(@floor(available_px / @as(f32, @floatFromInt(cw))));
        if (max_cols == 0) return;
        const scale = if (self.props.scale_milli == 0) 1000 else self.props.scale_milli;
        const heading_h: f32 = @floatFromInt(typography.lineHeightPx(.dock_heading, scale));
        const supporting_h: f32 = @floatFromInt(typography.lineHeightPx(.supporting, scale));
        const stack_h = heading_h + supporting_h;
        if (rect.rect.height < stack_h) return;
        const x = rect.rect.x + @as(f32, @floatFromInt(cw));
        const y = rect.rect.y + (rect.rect.height - stack_h) / 2;
        try self.emit(x, y, heading, max_cols, .head, .surface_fg, .dock_heading, false, true);
        try self.emit(x, y + heading_h, supporting, max_cols, .head, .muted_fg, .supporting, false, false);
    }

    fn textStyled(self: *Writer, rect: tree.RectEntry, line: u32, source: []const u8, role: tokens.ColorRole, text_role: typography.ChromeTextRole, line_count: u32, wide_icons: bool, centered: bool, bold: bool) ViewError!void {
        return self.textInsetStyled(rect, line, source, role, text_role, line_count, wide_icons, centered, 1, bold);
    }

    /// Places an entire line stack inside the completed rect before selecting the requested line.
    /// This keeps scope/search/group labels optically centred without font-specific pixel nudges.
    fn textInset(self: *Writer, rect: tree.RectEntry, line: u32, source: []const u8, role: tokens.ColorRole, text_role: typography.ChromeTextRole, line_count: u32, wide_icons: bool, centered: bool, left_inset_cols: u16) ViewError!void {
        return self.textInsetStyled(rect, line, source, role, text_role, line_count, wide_icons, centered, left_inset_cols, false);
    }

    fn textInsetStyled(self: *Writer, rect: tree.RectEntry, line: u32, source: []const u8, role: tokens.ColorRole, text_role: typography.ChromeTextRole, line_count: u32, wide_icons: bool, centered: bool, left_inset_cols: u16, bold: bool) ViewError!void {
        const cw = self.props.cell_width_px;
        const ch = self.props.cell_height_px;
        if (cw == 0 or ch == 0 or line_count == 0 or line >= line_count) return;
        const cell_height: f32 = @floatFromInt(ch);
        // Registered SVG icons remain in the legacy cell path, but ordinary semantic text now
        // has a measured system-UI raster path.  Centre those controls by their role line box,
        // not the terminal cell: the old calculation was visibly low at 1x and diverged further
        // at Retina scale. Non-centred card rows intentionally retain their fixed virtualization
        // rhythm until the card line-stack migration owns their reserved height as a whole.
        const role_line_height: f32 = if (centered and !wide_icons)
            @floatFromInt(typography.lineHeightPx(text_role, effectiveScale(self.props.scale_milli)))
        else
            cell_height;
        const stack_height = role_line_height * @as(f32, @floatFromInt(line_count));
        const x = rect.rect.x + @as(f32, @floatFromInt(cw)) * @as(f32, @floatFromInt(left_inset_cols));
        const y = if (centered)
            if (rect.rect.height >= stack_height) rect.rect.y + (rect.rect.height - stack_height) / 2 + role_line_height * @as(f32, @floatFromInt(line)) else return
        else
            rect.rect.y + cell_height * @as(f32, @floatFromInt(line + 1));
        if ((wide_icons or !centered) and !loweredTextCellFitsClip(rect, y, ch)) return;
        const required_inset_cols = @as(u32, left_inset_cols) + 1;
        const available_px = rect.rect.width - @as(f32, @floatFromInt(cw)) * @as(f32, @floatFromInt(required_inset_cols));
        if (available_px <= 0) return;
        const max_cols: u16 = @intFromFloat(@floor(available_px / @as(f32, @floatFromInt(cw))));
        try self.emit(x, y, source, max_cols, .head, role, text_role, wide_icons, bold);
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
        const control_h: f32 = @floatFromInt(typography.lineHeightPx(.control, effectiveScale(self.props.scale_milli)));
        if (rect.rect.height < control_h) return;
        const y = rect.rect.y + (rect.rect.height - control_h) / 2;
        try self.emit(x, y, source, start, .tail, role, .control, wide_icon, false);
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
        // Display columns are only a conservative placement estimate. Passing that exact width
        // to CTLine caused `Local Mac` to become `Local…` because the system face's proportional
        // advance was a few pixels wider than terminal cells. Reserve a small utility slot and
        // let the measured path ellipsize only at the actual slot edge.
        const label_slot_cols: u16 = label_cols +| 2;
        const refresh_slot_cols: u32 = 3;
        const total_cols: u32 = @intCast(label_slot_cols);
        const required_cols = total_cols + refresh_slot_cols + 2;
        const available_cols: u32 = @intFromFloat(@floor(rect.rect.width / @as(f32, @floatFromInt(cw))));
        if (required_cols > available_cols) return;
        const x = rect.rect.x + rect.rect.width - @as(f32, @floatFromInt((refresh_slot_cols + total_cols + 1) * cw));
        const y = rect.rect.y + (rect.rect.height - @as(f32, @floatFromInt(ch))) / 2;
        try self.emit(x, y, source, label_slot_cols, .head, .surface_fg, .control, false, true);
    }

    /// Provider is a dedicated metadata slot rather than a title prefix.  Both runs use the
    /// same third-line baseline and bounded column plan, keeping the label readable without
    /// letting long model metadata overlap the card's disclosure affordance.
    fn cardMetadata(self: *Writer, rect: tree.RectEntry, line: u32, line_count: u32, provider: []const u8, metadata: []const u8) ViewError!void {
        try self.text(rect, line, provider, .surface_fg, .metadata, line_count, false, false);
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
        try self.emit(x, y, metadata, max_cols, .head, .muted_fg, .metadata, false, false);
    }

    /// A workspace group has three independent slots: disclosure affordance, name, and count.
    /// Packing them into one terminal-style string made the count drift next to a long workspace
    /// name, which is visibly unlike the reference and leaves no stable place for its count pill.
    /// The group row itself remains the sole hit target from the completed tree; the pill is paint
    /// only and cannot introduce a competing pointer region.
    fn groupHeader(self: *Writer, rect: tree.RectEntry, group: types.Group) ViewError!void {
        const cw = self.props.cell_width_px;
        const ch = self.props.cell_height_px;
        if (cw == 0 or ch == 0) return;

        var count_buf: [16]u8 = undefined;
        const count = std.fmt.bufPrint(&count_buf, "{d}", .{group.count}) catch return;
        const horizontal_inset: u32 = cw;
        const pill_pad: u32 = cw;
        const count_cols = @max(plannedCols(count, 4), 1);
        // A one-digit count must still read as a horizontal count pill rather than a circular
        // notification dot. Three cell-heights gives the same stable visual slot to 1, 12, and
        // 230 while longer values can grow from their measured cell budget.
        const pill_width = @max(ch * 3, @as(u32, count_cols) * cw + pill_pad * 2);
        if (rect.rect.width < @as(f32, @floatFromInt(horizontal_inset * 2 + pill_width + cw * 3))) return;

        const pill_h = @min(ch * 2, @as(u32, @intFromFloat(@floor(rect.rect.height))));
        if (pill_h == 0) return;
        const pill_x: f32 = rect.rect.x + rect.rect.width - @as(f32, @floatFromInt(horizontal_inset + pill_width));
        const pill_y: f32 = rect.rect.y + (rect.rect.height - @as(f32, @floatFromInt(pill_h)) / 2);
        const pill_radius: u16 = @intCast(@min(pill_h / 2, @as(u32, std.math.maxInt(u16))));
        try self.appendQuad(.{
            .rect = .{
                .x = @intFromFloat(@floor(pill_x)),
                .y = @intFromFloat(@floor(pill_y)),
                .w = pill_width,
                .h = pill_h,
            },
            .fill_role = .inset_bg,
            .corner_radii = .{ pill_radius, pill_radius, pill_radius, pill_radius },
            .border_widths = .{ 1, 1, 1, 1 },
            .border_role = .divider,
        });

        const icon_y = rect.rect.y + (rect.rect.height - @as(f32, @floatFromInt(ch))) / 2;
        try self.emit(
            rect.rect.x + @as(f32, @floatFromInt(horizontal_inset)),
            icon_y,
            if (group.collapsed) chevron_right_icon else chevron_down_icon,
            2,
            .head,
            .surface_fg,
            .control,
            true,
            false,
        );

        const label_x = rect.rect.x + @as(f32, @floatFromInt(horizontal_inset + cw * 3));
        const label_end = pill_x - @as(f32, @floatFromInt(cw));
        if (label_end > label_x) {
            const max_cols: u16 = @intFromFloat(@floor((label_end - label_x) / @as(f32, @floatFromInt(cw))));
            const group_heading_h: f32 = @floatFromInt(typography.lineHeightPx(.group_heading, effectiveScale(self.props.scale_milli)));
            if (max_cols > 0 and rect.rect.height >= group_heading_h)
                try self.emit(label_x, rect.rect.y + (rect.rect.height - group_heading_h) / 2, group.label, max_cols, .head, .surface_fg, .group_heading, false, true);
        }

        const count_width: f32 = @floatFromInt(@as(u32, count_cols) * cw);
        const count_x = pill_x + (@as(f32, @floatFromInt(pill_width)) - count_width) / 2;
        // The group row and its count pill intentionally have different heights.  Centre the
        // count in the pill's own rect; using the row baseline lifted it above the dark pill in
        // real Metal captures even though the horizontal slot was correct.
        const count_line_h: f32 = @floatFromInt(typography.lineHeightPx(.control, effectiveScale(self.props.scale_milli)));
        if (@as(f32, @floatFromInt(pill_h)) < count_line_h) return;
        const count_y = pill_y + (@as(f32, @floatFromInt(pill_h)) - count_line_h) / 2;
        try self.emit(count_x, count_y, count, count_cols, .head, .surface_fg, .control, false, true);
    }

    fn appendQuad(self: *Writer, quad: draw.Op.Quad) ViewError!void {
        if (self.op_count == self.ops.len) return error.InsufficientTextBuffer;
        self.ops[self.op_count] = .{ .quad = quad };
        self.op_count += 1;
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
        }, .surface_fg, .body, detail_lines, false, false);
        switch (expanded_props.state) {
            .ready => {
                if (expanded_props.action_record_count > 0) {
                    var count: [80]u8 = undefined;
                    const label = std.fmt.bufPrint(&count, "도구/권한 관련 기록 {d}건", .{expanded_props.action_record_count}) catch "도구/권한 관련 기록";
                    try self.text(detail, 1, label, .muted_fg, .metadata, detail_lines, false, false);
                }
                for (expanded_props.turns, 0..) |turn, turn_index| {
                    const line: u32 = @intCast(2 + turn_index * 2);
                    try self.text(detail, line, switch (turn.role) {
                        .user => "사용자",
                        .assistant => "에이전트",
                    }, .muted_fg, .overline, detail_lines, false, false);
                    try self.text(detail, line + 1, turn.text, .surface_fg, .body, detail_lines, false, false);
                }
            },
            .loading => try self.skeletons(detail),
            .stale => try self.text(detail, 2, "안전하게 재개하거나 로그를 열 수 없습니다.", .muted_fg, .body, detail_lines, false, false),
            .unavailable => try self.text(detail, 2, "원본을 읽을 수 없습니다.", .muted_fg, .body, detail_lines, false, false),
        }
        try self.action(find(snapshot, build.NodeIds.resumeAction(index)) orelse return error.MissingRect, resume_icon, "터미널에서 이어하기");
        try self.action(find(snapshot, build.NodeIds.reveal(index)) orelse return error.MissingRect, reveal_icon, "로그 보기");
        if (expanded_props.focus_live_enabled)
            try self.action(find(snapshot, build.NodeIds.focusLive(index)) orelse return error.MissingRect, null, "열린 세션으로 이동");
    }

    /// The action label must not inherit the SVG icon's legacy cell lowering.  Combining both
    /// into one `wide_icons` run made Korean labels bypass the detached CoreText worker, so
    /// their advance, ellipsis and line box were all terminal-font guesses.  Keep the existing
    /// registered icon path as a separate op while B1-button-b moves its final-pixel placement
    /// into the same worker artifact as the label.
    fn action(self: *Writer, rect: tree.RectEntry, icon: ?[]const u8, label: []const u8) ViewError!void {
        const cw = self.props.cell_width_px;
        const ch = self.props.cell_height_px;
        if (cw == 0 or ch == 0) return;
        const icon_cols: u16 = if (icon != null) 2 else 0;
        const icon_gap_cols: u16 = if (icon != null) 1 else 0;
        const available_px = rect.rect.width - @as(f32, @floatFromInt(cw * 2));
        if (available_px <= 0) return;
        const max_cols: u16 = @intFromFloat(@floor(available_px / @as(f32, @floatFromInt(cw))));
        const reserved_cols = icon_cols + icon_gap_cols;
        if (max_cols <= reserved_cols) return;
        const label_max_cols = max_cols - reserved_cols;
        const planned_label_cols = plannedCols(label, label_max_cols);
        if (planned_label_cols == 0) return;
        // B1-button-a deliberately uses this conservative icon-slot plan only to position the
        // still-cell-backed SVG. The adjacent label is a normal semantic text op, so CoreText
        // owns its proportional Korean/fallback advance and ellipsis instead of this estimate.
        const group_cols = reserved_cols + planned_label_cols;
        const group_width: f32 = @floatFromInt(@as(u32, group_cols) * cw);
        const x = rect.rect.x + (rect.rect.width - group_width) / 2;
        const icon_y = rect.rect.y + (rect.rect.height - @as(f32, @floatFromInt(ch))) / 2;
        const line_h: f32 = @floatFromInt(typography.lineHeightPx(.button_label, effectiveScale(self.props.scale_milli)));
        if (rect.rect.height < line_h) return;
        const label_y = rect.rect.y + (rect.rect.height - line_h) / 2;
        const enabled = rect.action != null and rect.action.?.enabled;
        const foreground: tokens.ColorRole = if (!enabled) .muted_fg else switch (rect.visual) {
            .button => |visual| switch (visual.variant) {
                .primary => .surface_bg,
                .secondary => .surface_fg,
            },
            // A SessionDock action must be a Button.  Keeping this fail-safe fallback makes a
            // stale/malformed published snapshot readable rather than guessing a Card variant.
            else => .surface_fg,
        };
        if (icon) |source| {
            if (loweredTextCellFitsClip(rect, icon_y, ch))
                try self.emit(x, icon_y, source, icon_cols, .head, foreground, .button_label, true, false);
        }
        try self.emit(x + @as(f32, @floatFromInt(@as(u32, reserved_cols) * cw)), label_y, label, label_max_cols, .head, foreground, .button_label, false, true);
    }

    fn plannedCols(source: []const u8, max_cols: u16) u16 {
        var plan = text_layout.plan(source, 0, max_cols, .head, isSessionDockIcon);
        while (plan.next()) |_| {}
        return plan.endCol();
    }

    fn emit(self: *Writer, x: f32, y: f32, source: []const u8, cols: u16, anchor: text_layout.Anchor, role: tokens.ColorRole, text_role: typography.ChromeTextRole, wide_icons: bool, bold: bool) ViewError!void {
        if (cols == 0) return;
        if (self.op_count == self.ops.len) return error.InsufficientTextBuffer;
        if (self.run_count == self.runs.len) return error.InsufficientRunBuffer;
        // Keep the source intact until lowering.  The legacy path and the measured CoreText
        // path share `max_cols`/`anchor`, but only the latter can decide a Korean/fallback
        // ellipsis from its actual glyph advances.  Pre-truncating here would make that
        // information irrecoverable and would silently give the two renderers different text.
        const start = self.text_count;
        try self.appendBytes(source);
        self.runs[self.run_count] = .{ .text = self.text_bytes[start..self.text_count], .bold = bold };
        self.ops[self.op_count] = .{ .text = .{
            .origin = .{ .x = @intFromFloat(@floor(x)), .y = @intFromFloat(@floor(y)) },
            .runs = self.runs[self.run_count .. self.run_count + 1],
            .role = role,
            .text_role = text_role,
            .max_cols = cols,
            .anchor = anchor,
            .wide_icons = wide_icons,
        } };
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

fn effectiveScale(scale_milli: u32) u32 {
    return if (scale_milli == 0) 1000 else scale_milli;
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
    var saw_group_label = false;
    var saw_group_count = false;
    var saw_group_count_pill = false;
    var group_count_origin_y: ?i32 = null;
    var group_count_pill_y: ?i32 = null;
    var saw_dock_heading = false;
    var saw_card_heading = false;
    var saw_metadata = false;
    var title_max_cols: ?u16 = null;
    var host_label_max_cols: ?u16 = null;
    var saw_untruncated_title = false;
    for (out.ops) |op| switch (op) {
        .quad => |quad| {
            saw_quad = true;
            if (quad.fill_role == .inset_bg) {
                saw_group_count_pill = true;
                group_count_pill_y = quad.rect.y;
                try std.testing.expect(quad.rect.w >= props.cell_height_px * 3);
            }
        },
        .text => |text| {
            saw_dock_heading = saw_dock_heading or text.text_role == .dock_heading;
            saw_card_heading = saw_card_heading or text.text_role == .card_heading;
            saw_metadata = saw_metadata or text.text_role == .metadata;
            for (text.runs) |run| {
                if (std.mem.eql(u8, run.text, "a title that intentionally exceeds a narrow card")) {
                    saw_untruncated_title = true;
                    title_max_cols = text.max_cols;
                }
                saw_provider = saw_provider or std.mem.indexOf(u8, run.text, "Claude") != null;
                if (std.mem.eql(u8, run.text, refresh_icon)) {
                    refresh_origin_x = text.origin.x;
                    try std.testing.expect(text.wide_icons);
                }
                if (std.mem.eql(u8, run.text, host_label)) host_label_max_cols = text.max_cols;
                if (std.mem.eql(u8, run.text, "작업공간")) workspace_origin_y = text.origin.y;
                if (std.mem.eql(u8, run.text, "프로젝트")) project_origin_y = text.origin.y;
                if (std.mem.eql(u8, run.text, "전체")) all_origin_y = text.origin.y;
                saw_group_label = saw_group_label or std.mem.eql(u8, run.text, "workspace");
                if (std.mem.eql(u8, run.text, "1")) {
                    saw_group_count = true;
                    group_count_origin_y = text.origin.y;
                }
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
    try std.testing.expect(saw_group_label);
    try std.testing.expect(saw_group_count);
    try std.testing.expect(saw_group_count_pill);
    const expected_pill_centered_y = (group_count_pill_y orelse return error.TestUnexpectedResult) + @as(i32, @intCast((props.cell_height_px * 2 - typography.lineHeightPx(.control, effectiveScale(props.scale_milli))) / 2));
    try std.testing.expectEqual(expected_pill_centered_y, group_count_origin_y orelse return error.TestUnexpectedResult);
    try std.testing.expect(saw_dock_heading);
    try std.testing.expect(saw_card_heading);
    try std.testing.expect(saw_metadata);
    // Overflow remains a semantic constraint instead of a pre-truncated source string. This is
    // what lets the measured path choose an ellipsis from the actual system UI font advance.
    try std.testing.expect(saw_untruncated_title);
    try std.testing.expect((title_max_cols orelse 0) < "a title that intentionally exceeds a narrow card".len);
    try std.testing.expect((host_label_max_cols orelse 0) > Writer.plannedCols(host_label, 16));
    inline for (.{ .scope_workspace, .scope_project, .scope_all }, .{ workspace_origin_y, project_origin_y, all_origin_y }) |id, origin| {
        const scope = find(frame.tree, @field(build.NodeIds, @tagName(id))) orelse return error.TestUnexpectedResult;
        const expected_line_h: f32 = @floatFromInt(typography.lineHeightPx(.control, effectiveScale(props.scale_milli)));
        const expected_y: i32 = @intFromFloat(@floor(scope.rect.y + (scope.rect.height - expected_line_h) / 2));
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

test "SessionDock Retina controls centre measured line boxes instead of terminal cells" {
    const props = types.Props{
        .viewport_px = .{ .width = 640, .height = 960 },
        .cell_width_px = 16,
        .cell_height_px = 32,
        .scale_milli = 2000,
        .snapshot_generation = 6,
        .displayed_count = 1,
        .items = &.{
            .{ .group = .{ .identity = 1, .label = "workspace", .count = 12 } },
        },
    };
    var nodes: [8]tree.UiNode = undefined;
    var entries: [9]tree.RectEntry = undefined;
    var layout_items: [9]@import("../../ui/layout.zig").Item = undefined;
    var flex_scratch: [9]@import("../../ui/layout.zig").FlexScratch = undefined;
    var child_rects: [9]@import("../../ui/layout.zig").UiRect = undefined;
    var actions: [6]@import("ids.zig").Entry = undefined;
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
        .sidebar_background = .{ .r = 28, .g = 28, .b = 28 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 82, .g = 82, .b = 82 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .accent = .{ .r = 13, .g = 14, .b = 15 },
    });
    var ops: [24]draw.Op = undefined;
    var runs: [16]draw.Run = undefined;
    var text_bytes: [512]u8 = undefined;
    const out = try view(props, frame, .{}, &tk, .{ .ops = &ops, .runs = &runs, .text_bytes = &text_bytes });
    var workspace_y: ?i32 = null;
    var count_y: ?i32 = null;
    var count_pill_y: ?i32 = null;
    for (out.ops) |op| switch (op) {
        .quad => |quad| {
            if (quad.fill_role == .inset_bg) count_pill_y = quad.rect.y;
        },
        .text => |text| for (text.runs) |run| {
            if (std.mem.eql(u8, run.text, "작업공간")) workspace_y = text.origin.y;
            if (std.mem.eql(u8, run.text, "12")) count_y = text.origin.y;
        },
        else => {},
    };
    const scope = find(frame.tree, build.NodeIds.scope_workspace) orelse return error.TestUnexpectedResult;
    const control_h: f32 = @floatFromInt(typography.lineHeightPx(.control, props.scale_milli));
    try std.testing.expectEqual(@as(i32, @intFromFloat(@floor(scope.rect.y + (scope.rect.height - control_h) / 2))), workspace_y orelse return error.TestUnexpectedResult);
    const expected_count_y = (count_pill_y orelse return error.TestUnexpectedResult) + @as(i32, @intCast((props.cell_height_px * 2 - typography.lineHeightPx(.control, props.scale_milli)) / 2));
    try std.testing.expectEqual(expected_count_y, count_y orelse return error.TestUnexpectedResult);
}

test "SessionDock action keeps SVG icon separate from measured Korean label" {
    const props = types.Props{
        .viewport_px = .{ .width = 640, .height = 960 },
        .cell_width_px = 8,
        .cell_height_px = 16,
        .snapshot_generation = 9,
        .displayed_count = 1,
        .expanded_identity = 7,
        .items = &.{.{ .card = .{
            .identity = 7,
            .provider = .codex,
            .title = "measured action",
            .summary = "summary",
            .metadata = "metadata",
            .expanded = .{ .state = .ready, .resume_enabled = true, .reveal_enabled = true },
        } }},
    };
    var nodes: [16]tree.UiNode = undefined;
    var entries: [17]tree.RectEntry = undefined;
    var layout_items: [17]@import("../../ui/layout.zig").Item = undefined;
    var flex_scratch: [17]@import("../../ui/layout.zig").FlexScratch = undefined;
    var child_rects: [17]@import("../../ui/layout.zig").UiRect = undefined;
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
    var ops: [48]draw.Op = undefined;
    var runs: [48]draw.Run = undefined;
    var text_bytes: [1024]u8 = undefined;
    const out = try view(props, frame, .{}, &tk, .{ .ops = &ops, .runs = &runs, .text_bytes = &text_bytes });
    var icon_x: ?i32 = null;
    var label_x: ?i32 = null;
    var label_y: ?i32 = null;
    var label_cols: ?u16 = null;
    for (out.ops) |op| switch (op) {
        .text => |text| for (text.runs) |run| {
            if (std.mem.eql(u8, run.text, resume_icon)) {
                try std.testing.expect(text.wide_icons);
                icon_x = text.origin.x;
            }
            if (std.mem.eql(u8, run.text, "터미널에서 이어하기")) {
                try std.testing.expect(!text.wide_icons);
                try std.testing.expectEqual(typography.ChromeTextRole.button_label, text.text_role);
                label_x = text.origin.x;
                label_y = text.origin.y;
                label_cols = text.max_cols;
            }
        },
        else => {},
    };
    const action_rect = find(frame.tree, build.NodeIds.resumeAction(0)) orelse return error.TestUnexpectedResult;
    try std.testing.expect((label_x orelse return error.TestUnexpectedResult) > (icon_x orelse return error.TestUnexpectedResult));
    try std.testing.expect((label_cols orelse 0) < @as(u16, @intFromFloat(@floor(action_rect.rect.width / @as(f32, @floatFromInt(props.cell_width_px))))));
    const line_h: f32 = @floatFromInt(typography.lineHeightPx(.button_label, props.scale_milli));
    try std.testing.expectEqual(@as(i32, @intFromFloat(@floor(action_rect.rect.y + (action_rect.rect.height - line_h) / 2))), label_y orelse return error.TestUnexpectedResult);
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
