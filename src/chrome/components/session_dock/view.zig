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
const paint_style = @import("../../ui/paint_style.zig");
const spacing = @import("../../ui/spacing.zig");
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
const host_icon = "\u{F0025}";
const resume_icon = "\u{F000C}";
const reveal_icon = "\u{F0011}";
const host_label = "로컬";

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
        .state = state,
        .tokens_ref = tk,
    };

    const header = find(frame.tree, build.NodeIds.header) orelse return error.MissingRect;
    const dock_metrics = types.DockMetrics.resolve(props.scale_milli);
    var count_buf: [48]u8 = undefined;
    const count = std.fmt.bufPrint(&count_buf, "{d}개 표시 · 최근 {d}개", .{ props.displayed_count, props.recent_limit }) catch "";
    try writer.headerStack(header, "Agent 세션 기록", count);
    try writer.headerProvenance(header, host_label);
    // The in-flight state deliberately keeps the registered SVG at its idle optical size.  The
    // old Unicode clock frames were one terminal-cell glyphs, so clicking refresh made the
    // control visibly shrink even though its hit rect stayed 24pt.  Until component transforms
    // own SVG rotation, a muted registered refresh glyph is the truthful busy affordance.
    try writer.headerRefresh(header, refresh_icon, if (props.loading or props.refreshing) .muted_fg else .surface_fg, true);

    try writer.text(find(frame.tree, build.NodeIds.scope_workspace) orelse return error.MissingRect, 0, "작업공간", .surface_fg, .control, 1, false, true);
    try writer.text(find(frame.tree, build.NodeIds.scope_project) orelse return error.MissingRect, 0, "프로젝트", .surface_fg, .control, 1, false, true);
    try writer.text(find(frame.tree, build.NodeIds.scope_all) orelse return error.MissingRect, 0, "전체", .surface_fg, .control, 1, false, true);
    const search = find(frame.tree, build.NodeIds.search) orelse return error.MissingRect;
    try writer.searchField(search);

    if (props.loading and props.items.len == 0) {
        try writer.skeletons(find(frame.tree, build.NodeIds.content) orelse return error.MissingRect);
    }

    // 여기부터가 스크롤 목록이다. 고정 chrome은 위에서 이미 emit됐다.
    writer.scroll_clipped = true;
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
                // Card y offsets are DockMetrics values, not 1/3/5 terminal rows. This keeps
                // its three-line density and the disclosure hit rect stable across terminal
                // font zoom while the worker still owns actual glyph shaping and ellipsis.
                try writer.textAtY(card_rect, dock_metrics.card_inset_x, dock_metrics.card_title_y, card.title, .surface_fg, .card_heading, false);
                try writer.textAtY(card_rect, dock_metrics.card_inset_x, dock_metrics.card_summary_y, card.summary, .muted_fg, .body, false);
                try writer.cardMetadataAtY(card_rect, dock_metrics, card.provider.label(), card.metadata);
                // The whole title card remains one disclosure action, but its trailing chevron
                // makes that interaction discoverable and shares the exact card rect used by
                // pointer/Enter. No separate tiny hit target is manufactured for the icon.
                try writer.cardDisclosure(card_rect, dock_metrics);
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
    /// label 전경은 quad와 **같은 함수**에서 나와야 한다. variant만으로 고르면 hover/press에서
    /// `resolveButton`이 전경을 바꾸는 것을 놓쳐 배경색 label이 배경 위에 얹힌다.
    state: interaction.InteractionState,
    tokens_ref: *const tokens.Tokens,
    /// 지금 emit 중인 op이 스크롤 목록에 속하는지. 고정 chrome(헤더·scope·검색)은 스크롤해도 제자리이므로
    /// 이 구분이 없으면 backend가 "스크롤은 순수 평행이동"이라는 사실을 쓸 수 없다.
    scroll_clipped: bool = false,

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
        const metrics = types.DockMetrics.resolve(self.props.scale_milli);
        const reserved_utility = metrics.headerUtilityWidth();
        const available_px = rect.rect.width - @as(f32, @floatFromInt(metrics.header_content_inset_x + reserved_utility));
        if (available_px <= 0) return;
        const max_cols: u16 = @intFromFloat(@floor(available_px / @as(f32, @floatFromInt(cw))));
        if (max_cols == 0) return;
        const scale = if (self.props.scale_milli == 0) 1000 else self.props.scale_milli;
        const heading_h: f32 = @floatFromInt(typography.lineHeightPx(.dock_heading, scale));
        const supporting_h: f32 = @floatFromInt(typography.lineHeightPx(.supporting, scale));
        const stack_h = heading_h + supporting_h;
        if (rect.rect.height < stack_h) return;
        const x = rect.rect.x + @as(f32, @floatFromInt(metrics.header_content_inset_x));
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
        const required_inset_cols = @as(u32, left_inset_cols) + 1;
        const available_px = rect.rect.width - @as(f32, @floatFromInt(cw)) * @as(f32, @floatFromInt(required_inset_cols));
        if (available_px <= 0) return;
        const max_cols: u16 = @intFromFloat(@floor(available_px / @as(f32, @floatFromInt(cw))));
        try self.emit(x, y, source, max_cols, .head, role, text_role, wide_icons, bold);
    }

    /// 카드의 disclosure chevron. 등록 SVG affordance는 `icon_in_rect`의 명시 slot으로만 lower한다는
    /// 계약(docs/agent-session-list.md §2.1.1)을 이 아이콘만 지키지 않고 legacy cell 경로(`wide_icons`)에
    /// 남아 있었다. 그 경로는 measured artifact를 타지 않아 어떤 clip도 닿지 않으므로, 카드가 스크롤로
    /// 목록 위를 벗어나면 chevron만 고정 chrome 위에 그려졌다. 다른 affordance(refresh·search·group
    /// chevron)와 같은 경로로 합류시켜 clip을 함께 받는다.
    fn cardDisclosure(self: *Writer, rect: tree.RectEntry, metrics: types.DockMetrics) ViewError!void {
        const cw = self.props.cell_width_px;
        if (cw == 0) return;
        const extent = metrics.group_disclosure_extent;
        const inset: f32 = @floatFromInt(cw);
        if (rect.rect.width <= inset + @as(f32, @floatFromInt(extent))) return;
        if (rect.rect.height < @as(f32, @floatFromInt(extent))) return;
        const slot = draw.Rect{
            .x = @intFromFloat(@floor(rect.rect.x + rect.rect.width - inset - @as(f32, @floatFromInt(extent)))),
            .y = @intFromFloat(@floor(rect.rect.y + (rect.rect.height - @as(f32, @floatFromInt(extent))) / 2)),
            .w = extent,
            .h = extent,
        };
        try self.iconInRect(slot, chevron_down_icon, std.unicode.utf8Decode(chevron_down_icon) catch return, @intCast(metrics.header_host_icon_extent), .surface_fg);
    }

    /// Provenance is a measured host-SVG + label group. Its content rect, the refresh sibling,
    /// and header title reserve use one `DockMetrics` snapshot; terminal cells only cap text
    /// truncation after the real worker has measured the Korean label.
    fn headerProvenance(self: *Writer, rect: tree.RectEntry, source: []const u8) ViewError!void {
        const cw = self.props.cell_width_px;
        if (cw == 0) return;
        const metrics = types.DockMetrics.resolve(self.props.scale_milli);
        const utility_width = metrics.headerUtilityWidth();
        if (rect.rect.width < @as(f32, @floatFromInt(metrics.header_content_inset_x + utility_width))) return;
        const x = rect.rect.x + rect.rect.width - @as(f32, @floatFromInt(metrics.header_trailing_inset + metrics.header_refresh_extent + metrics.header_utility_gap + metrics.header_host_label_w));
        const control_h = typography.lineHeightPx(.control, effectiveScale(self.props.scale_milli));
        if (rect.rect.height < @as(f32, @floatFromInt(control_h))) return;
        const content = draw.Rect{
            .x = @intFromFloat(@floor(x)),
            .y = @intFromFloat(@floor(rect.rect.y + (rect.rect.height - @as(f32, @floatFromInt(control_h))) / 2)),
            .w = metrics.header_host_label_w,
            .h = control_h,
        };
        const reserved = metrics.header_host_icon_extent + metrics.header_host_icon_gap;
        if (content.w <= reserved) return;
        const label_max_width = content.w - reserved;
        const label_cols: u16 = @intFromFloat(@min(
            @ceil(@as(f32, @floatFromInt(label_max_width)) / @as(f32, @floatFromInt(cw))),
            @as(f32, @floatFromInt(std.math.maxInt(u16))),
        ));
        if (label_cols == 0) return;
        try self.emitPlaced(@floatFromInt(content.x), @floatFromInt(content.y), source, label_cols, .head, .surface_fg, .control, false, true, label_max_width, .{ .leading_icon_group = .{
            .content_rect = content,
            .icon_codepoint = std.unicode.utf8Decode(host_icon) catch return,
            .icon_extent_px = @intCast(metrics.header_host_icon_extent),
            .gap_px = @intCast(metrics.header_host_icon_gap),
        } });
    }

    /// Idle and busy refresh use one logical trailing SVG slot. Terminal glyph width therefore
    /// cannot pull this header control away from the provenance group or shrink it in-flight.
    fn headerRefresh(self: *Writer, rect: tree.RectEntry, source: []const u8, role: tokens.ColorRole, wide_icon: bool) ViewError!void {
        const metrics = types.DockMetrics.resolve(self.props.scale_milli);
        if (rect.rect.width < @as(f32, @floatFromInt(metrics.header_content_inset_x + metrics.headerUtilityWidth()))) return;
        const slot = draw.Rect{
            .x = @intFromFloat(@floor(rect.rect.x + rect.rect.width - @as(f32, @floatFromInt(metrics.header_trailing_inset + metrics.header_refresh_extent)))),
            .y = @intFromFloat(@floor(rect.rect.y + (rect.rect.height - @as(f32, @floatFromInt(metrics.header_refresh_extent))) / 2)),
            .w = metrics.header_refresh_extent,
            .h = metrics.header_refresh_extent,
        };
        if (!wide_icon) {
            const control_h: f32 = @floatFromInt(typography.lineHeightPx(.control, effectiveScale(self.props.scale_milli)));
            if (rect.rect.height < control_h) return;
            try self.emit(@as(f32, @floatFromInt(slot.x)) + (@as(f32, @floatFromInt(slot.w)) - @as(f32, @floatFromInt(self.props.cell_width_px))) / 2, rect.rect.y + (rect.rect.height - control_h) / 2, source, 1, .head, role, .control, false, false);
            return;
        }
        const icon = std.unicode.utf8Decode(source) catch return;
        try self.iconInRect(slot, source, icon, @intCast(metrics.header_host_icon_extent), role);
    }

    /// The search field is a real Chrome input: its SVG owns a fixed optical box and the text
    /// begins after the same 16/18/8pt content group used by buttons.  It must not use the
    /// terminal-cell icon path, which had a different baseline from the measured input label.
    fn searchField(self: *Writer, rect: tree.RectEntry) ViewError!void {
        const cw = self.props.cell_width_px;
        if (cw == 0) return;
        const button = types.ButtonMetrics.resolve(self.props.scale_milli);
        const icon_extent = button.leading_icon_extent_px;
        if (rect.rect.width <= @as(f32, @floatFromInt(button.content_inset_x_px * 2 + icon_extent + button.leading_icon_gap_px))) return;
        const icon_slot = draw.Rect{
            .x = @intFromFloat(@floor(rect.rect.x + @as(f32, @floatFromInt(button.content_inset_x_px)))),
            .y = @intFromFloat(@floor(rect.rect.y + (rect.rect.height - @as(f32, @floatFromInt(icon_extent))) / 2)),
            .w = icon_extent,
            .h = icon_extent,
        };
        try self.iconInRect(icon_slot, search_icon, std.unicode.utf8Decode(search_icon) catch return, @intCast(icon_extent), .muted_fg);

        const x = rect.rect.x + @as(f32, @floatFromInt(button.content_inset_x_px + icon_extent + button.leading_icon_gap_px));
        const end = rect.rect.x + rect.rect.width - @as(f32, @floatFromInt(button.content_inset_x_px));
        if (end <= x) return;
        const max_cols: u16 = @intFromFloat(@floor((end - x) / @as(f32, @floatFromInt(cw))));
        if (max_cols == 0) return;
        const line_h: f32 = @floatFromInt(typography.lineHeightPx(.control, effectiveScale(self.props.scale_milli)));
        if (rect.rect.height < line_h) return;
        const y = rect.rect.y + (rect.rect.height - line_h) / 2;
        const show_caret = self.props.search_focused and self.props.search_cursor_visible;
        const empty = self.props.search.len == 0 and self.props.search_preedit.len == 0;
        if (empty and !show_caret) {
            return self.emit(x, y, "세션 검색", max_cols, .head, .muted_fg, .control, false, false);
        }
        return self.emitJoined(x, y, self.props.search, self.props.search_preedit, if (show_caret) "|" else "", max_cols, if (empty) .muted_fg else .surface_fg);
    }

    /// A fixed Chrome component can use terminal columns only as a conservative horizontal
    /// truncation budget. Its vertical hierarchy must come from the published DockMetrics
    /// snapshot, otherwise terminal zoom moves text inside a stable card/hit rect.
    fn textAtY(self: *Writer, rect: tree.RectEntry, inset_x: u32, offset_y: u32, source: []const u8, role: tokens.ColorRole, text_role: typography.ChromeTextRole, bold: bool) ViewError!void {
        const cw = self.props.cell_width_px;
        const ch = self.props.cell_height_px;
        if (cw == 0 or ch == 0) return;
        const x = rect.rect.x + @as(f32, @floatFromInt(inset_x));
        const y = rect.rect.y + @as(f32, @floatFromInt(offset_y));
        const available_px = rect.rect.width - @as(f32, @floatFromInt(inset_x + cw));
        if (available_px <= 0) return;
        const max_cols: u16 = @intFromFloat(@min(
            @floor(available_px / @as(f32, @floatFromInt(cw))),
            @as(f32, @floatFromInt(std.math.maxInt(u16))),
        ));
        try self.emit(x, y, source, max_cols, .head, role, text_role, false, bold);
    }

    fn cardMetadataAtY(self: *Writer, rect: tree.RectEntry, metrics: types.DockMetrics, provider: []const u8, metadata: []const u8) ViewError!void {
        try self.textAtY(rect, metrics.card_inset_x, metrics.card_metadata_y, provider, .surface_fg, .metadata, false);
        const cw = self.props.cell_width_px;
        const ch = self.props.cell_height_px;
        if (cw == 0 or ch == 0) return;
        const provider_cols = plannedCols(provider, 24);
        const provider_width = @as(u32, provider_cols) * cw;
        const metadata_inset = metrics.card_inset_x + provider_width + spacing.px(.xs, effectiveScale(self.props.scale_milli));
        const x = rect.rect.x + @as(f32, @floatFromInt(metadata_inset));
        const y = rect.rect.y + @as(f32, @floatFromInt(metrics.card_metadata_y));
        const available_px = rect.rect.width - @as(f32, @floatFromInt(metadata_inset + cw));
        if (available_px <= 0) return;
        const max_cols: u16 = @intFromFloat(@min(
            @floor(available_px / @as(f32, @floatFromInt(cw))),
            @as(f32, @floatFromInt(std.math.maxInt(u16))),
        ));
        try self.emit(x, y, metadata, max_cols, .head, .muted_fg, .metadata, false, false);
    }

    /// A workspace group has three independent slots: disclosure affordance, name, and count.
    /// Packing them into one terminal-style string made the count drift next to a long workspace
    /// name, which is visibly unlike the reference and leaves no stable place for its count pill.
    /// The group row itself remains the sole hit target from the completed tree; the pill is paint
    /// only and cannot introduce a competing pointer region.
    fn groupHeader(self: *Writer, rect: tree.RectEntry, group: types.Group) ViewError!void {
        const cw = self.props.cell_width_px;
        if (cw == 0) return;
        const metrics = types.DockMetrics.resolve(self.props.scale_milli);
        const scale = effectiveScale(self.props.scale_milli);

        var count_buf: [16]u8 = undefined;
        const count = std.fmt.bufPrint(&count_buf, "{d}", .{group.count}) catch return;
        const horizontal_inset = metrics.group_disclosure_inset_x;
        const pill_pad = spacing.px(.xs, scale);
        const count_cols = @max(plannedCols(count, 4), 1);
        // A one-digit count remains a horizontal count pill at every terminal font size; the
        // cell estimate only reserves enough room for a longer measured label.
        const pill_width = @max(spacing.pointsPx(44, scale), @as(u32, count_cols) * cw + pill_pad * 2);
        const icon_slot = metrics.group_disclosure_extent + metrics.group_disclosure_label_gap;
        if (rect.rect.width < @as(f32, @floatFromInt(horizontal_inset * 2 + pill_width + icon_slot))) return;

        const pill_h = @min(spacing.pointsPx(32, scale), @as(u32, @intFromFloat(@floor(rect.rect.height))));
        if (pill_h == 0) return;
        const pill_x: f32 = rect.rect.x + rect.rect.width - @as(f32, @floatFromInt(horizontal_inset + pill_width));
        // 세로 중앙은 `(행 높이 - pill 높이) / 2`다. 괄호가 하나 밀려 `행 높이 - pill/2`가 되면 pill이
        // 행 바닥 밖으로 내려가 아래 카드에 걸친다(사용자 보고).
        const pill_y: f32 = rect.rect.y + (rect.rect.height - @as(f32, @floatFromInt(pill_h))) / 2;
        const pill_radius: u16 = @intCast(@min(pill_h / 2, @as(u32, std.math.maxInt(u16))));
        try self.appendClippedQuad(rect, .{
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

        const disclosure = draw.Rect{
            .x = @intFromFloat(@floor(rect.rect.x + @as(f32, @floatFromInt(horizontal_inset)))),
            .y = @intFromFloat(@floor(rect.rect.y + (rect.rect.height - @as(f32, @floatFromInt(metrics.group_disclosure_extent))) / 2)),
            .w = metrics.group_disclosure_extent,
            .h = metrics.group_disclosure_extent,
        };
        const disclosure_source = if (group.collapsed) chevron_right_icon else chevron_down_icon;
        try self.iconInRect(disclosure, disclosure_source, std.unicode.utf8Decode(disclosure_source) catch return, @intCast(metrics.header_host_icon_extent), .surface_fg);

        const label_x = rect.rect.x + @as(f32, @floatFromInt(horizontal_inset + icon_slot));
        const label_end = pill_x - @as(f32, @floatFromInt(spacing.px(.xs, scale)));
        if (label_end > label_x) {
            const max_cols: u16 = @intFromFloat(@floor((label_end - label_x) / @as(f32, @floatFromInt(cw))));
            const group_heading_h: f32 = @floatFromInt(typography.lineHeightPx(.group_heading, scale));
            if (max_cols > 0 and rect.rect.height >= group_heading_h)
                try self.emit(label_x, rect.rect.y + (rect.rect.height - group_heading_h) / 2, group.label, max_cols, .head, .surface_fg, .group_heading, false, true);
        }

        const count_width: f32 = @min(
            @as(f32, @floatFromInt(@as(u32, count_cols) * cw)),
            @as(f32, @floatFromInt(pill_width -| pill_pad * 2)),
        );
        const count_x = pill_x + (@as(f32, @floatFromInt(pill_width)) - count_width) / 2;
        // The group row and its count pill intentionally have different heights.  Centre the
        // count in the pill's own rect; using the row baseline lifted it above the dark pill in
        // real Metal captures even though the horizontal slot was correct.
        const count_line_h: f32 = @floatFromInt(typography.lineHeightPx(.control, scale));
        if (@as(f32, @floatFromInt(pill_h)) < count_line_h) return;
        const count_y = pill_y + (@as(f32, @floatFromInt(pill_h)) - count_line_h) / 2;
        try self.emit(count_x, count_y, count, count_cols, .head, .surface_fg, .control, false, true);
    }

    fn appendQuad(self: *Writer, quad: draw.Op.Quad) ViewError!void {
        if (self.op_count == self.ops.len) return error.InsufficientTextBuffer;
        self.ops[self.op_count] = .{ .quad = quad };
        self.op_count += 1;
    }

    /// `ui_paint`가 만드는 카드/버튼 배경은 이미 published clip으로 잘려 나온다. component가 직접 내는
    /// 장식 quad(그룹 count pill 등)도 같은 규율을 따라야 스크롤로 목록 위로 나간 조각이 고정 chrome
    /// 위에 남지 않는다.
    fn appendClippedQuad(self: *Writer, rect: tree.RectEntry, quad: draw.Op.Quad) ViewError!void {
        const clip = rect.effective_clip orelse return self.appendQuad(quad);
        const left: i32 = @intFromFloat(@ceil(clip.x));
        const top: i32 = @intFromFloat(@ceil(clip.y));
        const right: i32 = @intFromFloat(@floor(clip.x + clip.width));
        const bottom: i32 = @intFromFloat(@floor(clip.y + clip.height));
        const x0 = @max(quad.rect.x, left);
        const y0 = @max(quad.rect.y, top);
        const x1 = @min(quad.rect.x + @as(i32, @intCast(quad.rect.w)), right);
        const y1 = @min(quad.rect.y + @as(i32, @intCast(quad.rect.h)), bottom);
        if (x1 <= x0 or y1 <= y0) return;
        var owned = quad;
        owned.rect = .{ .x = x0, .y = y0, .w = @intCast(x1 - x0), .h = @intCast(y1 - y0) };
        // 잘린 변은 원래 모양의 **내부**다. 거기에 radius와 테두리를 그대로 남기면 shader가 줄어든 rect의
        // 네 모서리를 다시 둥글리고 잘린 선을 따라 stroke를 그어, 클립 경계에 없어야 할 곡률과 1px 선이
        // 생긴다. 잘린 변만 각지게 만들고 그 변의 테두리를 뗀다(반대 변은 원래 모양이므로 유지).
        const cut_left = x0 > quad.rect.x;
        const cut_top = y0 > quad.rect.y;
        const cut_right = x1 < quad.rect.x + @as(i32, @intCast(quad.rect.w));
        const cut_bottom = y1 < quad.rect.y + @as(i32, @intCast(quad.rect.h));
        // corner_radii = [tl, tr, br, bl], border_widths = [top, right, bottom, left].
        if (cut_top or cut_left) owned.corner_radii[0] = 0;
        if (cut_top or cut_right) owned.corner_radii[1] = 0;
        if (cut_bottom or cut_right) owned.corner_radii[2] = 0;
        if (cut_bottom or cut_left) owned.corner_radii[3] = 0;
        if (cut_top) owned.border_widths[0] = 0;
        if (cut_right) owned.border_widths[1] = 0;
        if (cut_bottom) owned.border_widths[2] = 0;
        if (cut_left) owned.border_widths[3] = 0;
        return self.appendQuad(owned);
    }

    fn expanded(self: *Writer, snapshot: tree.UiRectTree, index: usize, expanded_props: types.Expanded) ViewError!void {
        const detail = find(snapshot, build.NodeIds.expandedDetail(index)) orelse return error.MissingRect;
        const metrics = types.DockMetrics.resolve(self.props.scale_milli);
        try self.textAtY(detail, metrics.detail_inset_x, metrics.detail_heading_y, switch (expanded_props.state) {
            .loading => "세션 분석 중",
            .ready => "최근 대화",
            .stale => "세션 원본이 변경되었습니다",
            .unavailable => "세션을 열 수 없습니다",
        }, .surface_fg, .body, false);
        switch (expanded_props.state) {
            .ready => {
                if (expanded_props.action_record_count > 0) {
                    var count: [80]u8 = undefined;
                    const label = std.fmt.bufPrint(&count, "도구/권한 관련 기록 {d}건", .{expanded_props.action_record_count}) catch "도구/권한 관련 기록";
                    try self.textAtY(detail, metrics.detail_inset_x, metrics.detail_record_y, label, .muted_fg, .metadata, false);
                }
                for (expanded_props.turns, 0..) |turn, turn_index| {
                    const turn_y = metrics.detail_turn_y + @as(u32, @intCast(turn_index)) * metrics.detail_turn_step;
                    try self.textAtY(detail, metrics.detail_inset_x, turn_y, switch (turn.role) {
                        .user => "사용자",
                        .assistant => "에이전트",
                    }, .muted_fg, .overline, false);
                    const body_y = turn_y + typography.lineHeightPx(.overline, effectiveScale(self.props.scale_milli)) + spacing.px(.xxs, effectiveScale(self.props.scale_milli));
                    try self.textAtY(detail, metrics.detail_inset_x, body_y, turn.text, .surface_fg, .body, false);
                }
            },
            .loading => try self.skeletons(detail),
            .stale => try self.textAtY(detail, metrics.detail_inset_x, metrics.detail_turn_y, "안전하게 재개하거나 로그를 열 수 없습니다.", .muted_fg, .body, false),
            .unavailable => try self.textAtY(detail, metrics.detail_inset_x, metrics.detail_turn_y, "원본을 읽을 수 없습니다.", .muted_fg, .body, false),
        }
        try self.action(find(snapshot, build.NodeIds.resumeAction(index)) orelse return error.MissingRect, resume_icon, "터미널에서 이어하기");
        try self.action(find(snapshot, build.NodeIds.reveal(index)) orelse return error.MissingRect, reveal_icon, "로그 보기");
        if (expanded_props.focus_live_enabled)
            try self.action(find(snapshot, build.NodeIds.focusLive(index)) orelse return error.MissingRect, null, "열린 세션으로 이동");
    }

    /// Button text is one semantic content group, not an icon op whose cell estimate happens to
    /// precede a measured label.  The detached worker receives the unrounded content rect and
    /// publishes both the actual label advance and registered-SVG placement in one artifact.
    fn action(self: *Writer, rect: tree.RectEntry, icon: ?[]const u8, label: []const u8) ViewError!void {
        const cw = self.props.cell_width_px;
        if (cw == 0) return;
        const button = types.ButtonMetrics.resolve(effectiveScale(self.props.scale_milli));
        const border = draw.Rect{
            .x = @intFromFloat(@floor(rect.rect.x)),
            .y = @intFromFloat(@floor(rect.rect.y)),
            .w = @intFromFloat(@floor(rect.rect.width)),
            .h = @intFromFloat(@floor(rect.rect.height)),
        };
        // `ButtonMetrics.minimum_height_px` is enforced by the layout tree.  Do not repeat that
        // rule after the final physical-pixel rounding: a valid 48pt action may become 46px at a
        // fractional backing scale, and the content-area checks below are the renderer's real
        // safety boundary.
        const content = border.inset(.{
            .top = @intCast(button.content_inset_y_px),
            .right = @intCast(button.content_inset_x_px),
            .bottom = @intCast(button.content_inset_y_px),
            .left = @intCast(button.content_inset_x_px),
        });
        if (content.w == 0 or content.h == 0) return;
        const line_height = typography.lineHeightPx(.button_label, effectiveScale(self.props.scale_milli));
        if (content.h < line_height) return;
        // 전경은 quad를 칠한 바로 그 함수에서 받는다. `buttonForeground`는 variant만 보므로
        // hover/press에서 `resolveButton`이 전경을 `.surface_fg`로 바꾸는 것을 놓쳤고, 그때
        // `.primary` label이 어두운 배경 위 배경색 글자가 되어 사라졌다.
        const foreground: tokens.ColorRole = switch (rect.visual) {
            .button => |visual| paint_style.resolveButton(rect.id, visual, rect.action, self.state, self.tokens_ref).foreground,
            // A SessionDock action must be a Button.  Keeping this fail-safe fallback makes a
            // stale/malformed published snapshot readable rather than guessing a Card variant.
            else => if (rect.action != null and rect.action.?.enabled) .surface_fg else .muted_fg,
        };
        const placement: draw.TextPlacement = if (icon) |source| .{ .leading_icon_group = .{
            .content_rect = content,
            .icon_codepoint = std.unicode.utf8Decode(source) catch return,
            .icon_extent_px = @intCast(@min(button.leading_icon_extent_px, std.math.maxInt(u16))),
            .gap_px = @intCast(@min(button.leading_icon_gap_px, std.math.maxInt(u16))),
        } } else .{ .center_in_rect = content };
        const reserved_px: u32 = switch (placement) {
            .leading_icon_group => |group| @as(u32, group.icon_extent_px) + group.gap_px,
            else => 0,
        };
        if (content.w <= reserved_px) return;
        const max_width_px = content.w - reserved_px;
        const label_max_cols: u16 = @intFromFloat(@min(
            @ceil(@as(f32, @floatFromInt(max_width_px)) / @as(f32, @floatFromInt(cw))),
            @as(f32, @floatFromInt(std.math.maxInt(u16))),
        ));
        if (label_max_cols == 0) return;
        try self.emitPlaced(@floatFromInt(content.x), @floatFromInt(content.y), label, label_max_cols, .head, foreground, .button_label, false, true, max_width_px, placement);
    }

    /// Fixed-width header utility slots still use this conservative display-column estimate;
    /// Button content deliberately does not, because its worker policy receives pixels above.
    fn plannedCols(source: []const u8, max_cols: u16) u16 {
        var plan = text_layout.plan(source, 0, max_cols, .head, isSessionDockIcon);
        while (plan.next()) |_| {}
        return plan.endCol();
    }

    fn emit(self: *Writer, x: f32, y: f32, source: []const u8, cols: u16, anchor: text_layout.Anchor, role: tokens.ColorRole, text_role: typography.ChromeTextRole, wide_icons: bool, bold: bool) ViewError!void {
        return self.emitPlaced(x, y, source, cols, anchor, role, text_role, wide_icons, bold, null, .origin);
    }

    /// A single measured input run preserves the actual system-font advance across committed
    /// query, IME preedit, and caret.  Three separately lowered text ops would re-start at the
    /// same origin or reintroduce terminal-cell advance guesses between them.
    fn emitJoined(self: *Writer, x: f32, y: f32, first: []const u8, second: []const u8, third: []const u8, cols: u16, role: tokens.ColorRole) ViewError!void {
        if (cols == 0) return;
        if (self.op_count == self.ops.len) return error.InsufficientTextBuffer;
        if (self.run_count == self.runs.len) return error.InsufficientRunBuffer;
        const start = self.text_count;
        try self.appendBytes(first);
        try self.appendBytes(second);
        try self.appendBytes(third);
        self.runs[self.run_count] = .{ .text = self.text_bytes[start..self.text_count] };
        self.ops[self.op_count] = .{ .text = .{
            .origin = .{ .x = @intFromFloat(@floor(x)), .y = @intFromFloat(@floor(y)) },
            .runs = self.runs[self.run_count .. self.run_count + 1],
            .role = role,
            .text_role = .control,
            .max_cols = cols,
            .anchor = .head,
            .max_width_px = @intFromFloat(@floor(@as(f32, @floatFromInt(cols)) * @as(f32, @floatFromInt(self.props.cell_width_px)))),
            .scroll_clipped = self.scroll_clipped,
        } };
        self.run_count += 1;
        self.op_count += 1;
    }

    fn iconInRect(self: *Writer, rect: draw.Rect, source: []const u8, icon: u21, extent: u16, role: tokens.ColorRole) ViewError!void {
        // The PUA bytes are never shaped as text (`icon_in_rect` resolves the registered SVG
        // directly), but retain them as the atlas request's stable input payload. A zero-byte
        // run crosses neither legacy nor retained-atlas admission paths reliably.
        try self.emitPlaced(@floatFromInt(rect.x), @floatFromInt(rect.y), source, 1, .head, role, .control, false, false, rect.w, .{ .icon_in_rect = .{ .content_rect = rect, .icon_codepoint = icon, .icon_extent_px = extent } });
    }

    fn emitPlaced(self: *Writer, x: f32, y: f32, source: []const u8, cols: u16, anchor: text_layout.Anchor, role: tokens.ColorRole, text_role: typography.ChromeTextRole, wide_icons: bool, bold: bool, max_width_px: ?u32, placement: draw.TextPlacement) ViewError!void {
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
            .max_width_px = max_width_px,
            .placement = placement,
            .scroll_clipped = self.scroll_clipped,
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
        const metrics = types.DockMetrics.resolve(self.props.scale_milli);
        const left = content.rect.x + @as(f32, @floatFromInt(metrics.card_inset_x));
        const available = content.rect.width - @as(f32, @floatFromInt(metrics.card_inset_x * 2));
        if (available <= 0) return;
        const line_h = @max(spacing.px(.xs, effectiveScale(self.props.scale_milli)), 2);
        const start_y = content.rect.y + @as(f32, @floatFromInt(metrics.item_gap));
        for (0..3) |card_index| {
            const card_y = start_y + @as(f32, @floatFromInt(card_index * (metrics.card_h + metrics.item_gap)));
            if (card_y >= content.rect.y + content.rect.height) break;
            try self.skeletonLine(left, card_y + @as(f32, @floatFromInt(metrics.card_title_y)), available, line_h);
            try self.skeletonLine(left, card_y + @as(f32, @floatFromInt(metrics.card_summary_y)), available * 0.82, line_h);
            try self.skeletonLine(left, card_y + @as(f32, @floatFromInt(metrics.card_metadata_y)), available * 0.58, line_h);
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

fn effectiveScale(scale_milli: u32) u32 {
    return if (scale_milli == 0) 1000 else scale_milli;
}

fn isSessionDockIcon(codepoint: u21) bool {
    return switch (codepoint) {
        0xF000C, 0xF0011, 0xF0021, 0xF0022, 0xF0023, 0xF0024, 0xF0025 => true,
        else => false,
    };
}

fn find(snapshot: tree.UiRectTree, id: tree.UiId) ?tree.RectEntry {
    const index = snapshot.find(id) orelse return null;
    return snapshot.entries[index];
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
    var host_label_placement: ?draw.TextPlacement = null;
    var refresh_placement: ?draw.TextPlacement = null;
    var search_placement: ?draw.TextPlacement = null;
    var group_chevron_placement: ?draw.TextPlacement = null;
    var group_label_x: ?i32 = null;
    var saw_untruncated_title = false;
    for (out.ops) |op| switch (op) {
        .quad => |quad| {
            saw_quad = true;
            if (quad.fill_role == .inset_bg) {
                saw_group_count_pill = true;
                group_count_pill_y = quad.rect.y;
                try std.testing.expect(quad.rect.w >= spacing.pointsPx(44, effectiveScale(props.scale_milli)));
            }
        },
        .text => |text| {
            saw_dock_heading = saw_dock_heading or text.text_role == .dock_heading;
            saw_card_heading = saw_card_heading or text.text_role == .card_heading;
            saw_metadata = saw_metadata or text.text_role == .metadata;
            switch (text.placement) {
                .icon_in_rect => |icon| {
                    try std.testing.expectEqual(@as(?u32, icon.content_rect.w), text.max_width_px);
                    if (icon.icon_codepoint == 0xF0021) refresh_placement = text.placement;
                    if (icon.icon_codepoint == 0xF0022) search_placement = text.placement;
                    // 카드의 disclosure도 같은 chevron codepoint를 같은 `icon_in_rect` 경로로 낸다.
                    // 목록에서 group이 먼저 나오므로 첫 매칭만 잡아 그룹 것을 본다.
                    if (icon.icon_codepoint == 0xF0023 and group_chevron_placement == null) {
                        saw_group_chevron = true;
                        group_chevron_placement = text.placement;
                    }
                },
                else => {},
            }
            for (text.runs) |run| {
                if (std.mem.eql(u8, run.text, "a title that intentionally exceeds a narrow card")) {
                    saw_untruncated_title = true;
                    title_max_cols = text.max_cols;
                }
                saw_provider = saw_provider or std.mem.indexOf(u8, run.text, "Claude") != null;
                if (std.mem.eql(u8, run.text, host_label)) {
                    host_label_max_cols = text.max_cols;
                    host_label_placement = text.placement;
                }
                if (std.mem.eql(u8, run.text, "작업공간")) workspace_origin_y = text.origin.y;
                if (std.mem.eql(u8, run.text, "프로젝트")) project_origin_y = text.origin.y;
                if (std.mem.eql(u8, run.text, "전체")) all_origin_y = text.origin.y;
                if (std.mem.eql(u8, run.text, "workspace")) {
                    saw_group_label = true;
                    group_label_x = text.origin.x;
                }
                if (std.mem.eql(u8, run.text, "1")) {
                    saw_group_count = true;
                    group_count_origin_y = text.origin.y;
                }
            }
        },
        else => {},
    };
    try std.testing.expect(saw_quad);
    try std.testing.expect(saw_provider);
    switch (search_placement orelse return error.TestUnexpectedResult) {
        .icon_in_rect => |icon| {
            saw_search_icon = true;
            const search_rect = find(frame.tree, build.NodeIds.search) orelse return error.TestUnexpectedResult;
            const button = types.ButtonMetrics.resolve(props.scale_milli);
            try std.testing.expectEqual(@as(u21, 0xF0022), icon.icon_codepoint);
            try std.testing.expectEqual(button.leading_icon_extent_px, icon.content_rect.w);
            try std.testing.expectEqual(
                @as(i32, @intFromFloat(@floor(search_rect.rect.x + @as(f32, @floatFromInt(button.content_inset_x_px))))),
                icon.content_rect.x,
            );
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(saw_search_icon);
    try std.testing.expect(saw_group_chevron);
    try std.testing.expect(saw_group_label);
    try std.testing.expect(saw_group_count);
    try std.testing.expect(saw_group_count_pill);
    const expected_pill_centered_y = (group_count_pill_y orelse return error.TestUnexpectedResult) + @as(i32, @intCast((spacing.pointsPx(32, effectiveScale(props.scale_milli)) - typography.lineHeightPx(.control, effectiveScale(props.scale_milli))) / 2));
    try std.testing.expectEqual(expected_pill_centered_y, group_count_origin_y orelse return error.TestUnexpectedResult);
    try std.testing.expect(saw_dock_heading);
    try std.testing.expect(saw_card_heading);
    try std.testing.expect(saw_metadata);
    // Overflow remains a semantic constraint instead of a pre-truncated source string. This is
    // what lets the measured path choose an ellipsis from the actual system UI font advance.
    try std.testing.expect(saw_untruncated_title);
    try std.testing.expect((title_max_cols orelse 0) < "a title that intentionally exceeds a narrow card".len);
    try std.testing.expect((host_label_max_cols orelse 0) > Writer.plannedCols(host_label, 16));
    const metrics = types.DockMetrics.resolve(props.scale_milli);
    switch (host_label_placement orelse return error.TestUnexpectedResult) {
        .leading_icon_group => |group| {
            try std.testing.expectEqual(@as(u21, 0xF0025), group.icon_codepoint);
            try std.testing.expectEqual(@as(u16, @intCast(metrics.header_host_icon_extent)), group.icon_extent_px);
            try std.testing.expectEqual(@as(u16, @intCast(metrics.header_host_icon_gap)), group.gap_px);
            try std.testing.expectEqual(metrics.header_host_label_w, group.content_rect.w);
        },
        else => return error.TestUnexpectedResult,
    }
    inline for (.{ .scope_workspace, .scope_project, .scope_all }, .{ workspace_origin_y, project_origin_y, all_origin_y }) |id, origin| {
        const scope = find(frame.tree, @field(build.NodeIds, @tagName(id))) orelse return error.TestUnexpectedResult;
        const expected_line_h: f32 = @floatFromInt(typography.lineHeightPx(.control, effectiveScale(props.scale_milli)));
        const expected_y: i32 = @intFromFloat(@floor(scope.rect.y + (scope.rect.height - expected_line_h) / 2));
        try std.testing.expectEqual(expected_y, origin orelse return error.TestUnexpectedResult);
    }
    const header = find(frame.tree, build.NodeIds.header) orelse return error.TestUnexpectedResult;
    switch (refresh_placement orelse return error.TestUnexpectedResult) {
        .icon_in_rect => |icon| {
            try std.testing.expectEqual(@as(u21, 0xF0021), icon.icon_codepoint);
            try std.testing.expectEqual(metrics.header_refresh_extent, icon.content_rect.w);
            const expected_refresh_x: i32 = @intFromFloat(@floor(header.rect.x + header.rect.width - @as(f32, @floatFromInt(metrics.header_trailing_inset + metrics.header_refresh_extent))));
            try std.testing.expectEqual(expected_refresh_x, icon.content_rect.x);
            const header_right: i32 = @intFromFloat(@floor(header.rect.x + header.rect.width));
            try std.testing.expectEqual(@as(i32, @intCast(metrics.header_trailing_inset)), header_right - (icon.content_rect.x + @as(i32, @intCast(icon.content_rect.w))));
            try std.testing.expect(icon.content_rect.x >= @as(i32, @intFromFloat(@floor(header.rect.x))));
            try std.testing.expect(icon.content_rect.x + @as(i32, @intCast(icon.content_rect.w)) <= header_right);
        },
        else => return error.TestUnexpectedResult,
    }
    const group_rect = find(frame.tree, build.NodeIds.item(0)) orelse return error.TestUnexpectedResult;
    const expected_group_chevron_x: i32 = @intFromFloat(@floor(group_rect.rect.x + @as(f32, @floatFromInt(metrics.group_disclosure_inset_x))));
    switch (group_chevron_placement orelse return error.TestUnexpectedResult) {
        .icon_in_rect => |icon| try std.testing.expectEqual(expected_group_chevron_x, icon.content_rect.x),
        else => return error.TestUnexpectedResult,
    }
    const expected_group_label_x: i32 = @intFromFloat(@floor(group_rect.rect.x + @as(f32, @floatFromInt(metrics.group_disclosure_inset_x + metrics.group_disclosure_extent + metrics.group_disclosure_label_gap))));
    try std.testing.expectEqual(
        expected_group_label_x,
        group_label_x orelse return error.TestUnexpectedResult,
    );

    // Refreshing retains the registered SVG's exact optical box instead of replacing it with
    // the old one-cell Unicode clock glyph.
    var loading_props = props;
    loading_props.loading = true;
    const loading_out = try view(loading_props, frame, .{}, &tk, .{ .ops = &ops, .runs = &runs, .text_bytes = &text_bytes });
    var loading_refresh: ?draw.TextPlacement = null;
    for (loading_out.ops) |op| switch (op) {
        .text => |text| switch (text.placement) {
            .icon_in_rect => |icon| {
                if (icon.icon_codepoint == 0xF0021) loading_refresh = text.placement;
            },
            else => {},
        },
        else => {},
    };
    switch (loading_refresh orelse return error.TestUnexpectedResult) {
        .icon_in_rect => |icon| switch (refresh_placement orelse return error.TestUnexpectedResult) {
            .icon_in_rect => |idle| {
                try std.testing.expectEqual(idle.content_rect, icon.content_rect);
                try std.testing.expectEqual(idle.icon_extent_px, icon.icon_extent_px);
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

// 부분적으로 걸친 카드의 글자는 이제 **버려지지 않고** 잘린다. clip 판정은 component가 아니라 backend가
// 픽셀 단위로 수행하므로(glyph quad ∩ viewport + UV 비례 조정), component가 할 일은 "이 op은 스크롤
// 목록 소속"이라고 표시하는 것뿐이다. 예전처럼 셀 단위로 통째 버리면 반쯤 보이는 줄이 통으로 사라진다.
test "SessionDock marks partial card runs as scroll clipped instead of dropping them" {
    const metrics = types.DockMetrics.resolve(1000);
    const props = types.Props{
        .viewport_px = .{ .width = 320, .height = 480 },
        .cell_width_px = 8,
        .cell_height_px = 16,
        .snapshot_generation = 4,
        .displayed_count = 2,
        // 첫 카드를 1px만 남기고 위로 밀어 올린다.
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
    var partial_title_scroll_clipped: ?bool = null;
    var next_title_scroll_clipped: ?bool = null;
    var header_scroll_clipped: ?bool = null;
    for (out.ops) |op| switch (op) {
        .text => |text| for (text.runs) |run| {
            if (std.mem.indexOf(u8, run.text, "partial-card-title") != null) partial_title_scroll_clipped = text.scroll_clipped;
            if (std.mem.indexOf(u8, run.text, "next-card-title") != null) next_title_scroll_clipped = text.scroll_clipped;
            if (std.mem.indexOf(u8, run.text, "Agent 세션 기록") != null) header_scroll_clipped = text.scroll_clipped;
        },
        else => {},
    };
    // 부분적으로 걸친 카드의 제목도 emit된다 — backend가 뷰포트로 자른다.
    try std.testing.expectEqual(@as(?bool, true), partial_title_scroll_clipped);
    try std.testing.expectEqual(@as(?bool, true), next_title_scroll_clipped);
    // 고정 chrome은 스크롤 대상이 아니다. 여기에 같은 표시가 붙으면 backend가 헤더까지 잘라 버린다.
    try std.testing.expectEqual(@as(?bool, false), header_scroll_clipped);
}

// 사용자 보고 회귀: 목록을 스크롤하면 펼친 카드의 내용이 다른 카드 위에 겹쳐 보였다. rect tree 단언만으로는
// 부족하다 — 사용자가 보는 것은 여기서 나가는 text op의 origin이다.
//
// **한 tree 안에서의 단언은 이 결함을 못 잡는다**: 평행이동이 빠진 detail은 자기 rect도 함께 안 옮겨져
// "detail 글자는 detail rect 안"이 여전히 참이다(실제로 그 단언은 버그 코드에서도 통과했다). 그래서 같은
// 목록을 스크롤 전/후로 두 번 렌더해 **모든 run이 정확히 같은 양만큼 움직였는지**를 본다. 겹침은 곧
// "어떤 글자만 안 움직였다"이므로, 이 차분이 증상 그 자체를 고정한다.
test "SessionDock scrolling moves every emitted run by the same virtualization offset" {
    const shift: i32 = -140;
    var props = types.Props{
        // 목록 아이템은 더 이상 viewport에 맞춰 축소되지 않는다. 이 테스트가 보려는 것은 평행이동의
        // 균일성이므로, 확장 카드와 이웃 카드가 **둘 다 실제로 보이는** viewport를 준다. 예전 640은
        // 축소 덕분에만 둘 다 들어갔고, 그 축소가 바로 이 PR이 없앤 결함이다.
        .viewport_px = .{ .width = 320, .height = 960 },
        .cell_width_px = 8,
        .cell_height_px = 16,
        .snapshot_generation = 7,
        .displayed_count = 2,
        .expanded_identity = 1,
        .items = &.{
            .{ .card = .{
                .identity = 1,
                .provider = .claude,
                .title = "expanded-card-title",
                .summary = "expanded-summary",
                .metadata = "expanded-meta",
                .expanded = .{
                    .state = .ready,
                    .resume_enabled = true,
                    .reveal_enabled = true,
                    .action_record_count = 61,
                    .turns = &.{.{ .role = .user, .text = "detail-turn-text" }},
                },
            } },
            .{ .card = .{ .identity = 2, .provider = .codex, .title = "neighbour-card-title", .summary = "neighbour-summary", .metadata = "neighbour-meta" } },
        },
    };
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

    var nodes_a: [16]tree.UiNode = undefined;
    var entries_a: [17]tree.RectEntry = undefined;
    var layout_items_a: [17]@import("../../ui/layout.zig").Item = undefined;
    var flex_scratch_a: [17]@import("../../ui/layout.zig").FlexScratch = undefined;
    var child_rects_a: [17]@import("../../ui/layout.zig").UiRect = undefined;
    var actions_a: [12]@import("ids.zig").Entry = undefined;
    var ops_a: [64]draw.Op = undefined;
    var runs_a: [64]draw.Run = undefined;
    var text_bytes_a: [2048]u8 = undefined;
    const rested = try view(props, try build.build(props, .{
        .nodes = &nodes_a,
        .entries = &entries_a,
        .layout_items = &layout_items_a,
        .flex_scratch = &flex_scratch_a,
        .child_rects = &child_rects_a,
        .actions = &actions_a,
    }), .{}, &tk, .{ .ops = &ops_a, .runs = &runs_a, .text_bytes = &text_bytes_a });

    props.content_first_item_origin_y_px = shift;
    var nodes_b: [16]tree.UiNode = undefined;
    var entries_b: [17]tree.RectEntry = undefined;
    var layout_items_b: [17]@import("../../ui/layout.zig").Item = undefined;
    var flex_scratch_b: [17]@import("../../ui/layout.zig").FlexScratch = undefined;
    var child_rects_b: [17]@import("../../ui/layout.zig").UiRect = undefined;
    var actions_b: [12]@import("ids.zig").Entry = undefined;
    var ops_b: [64]draw.Op = undefined;
    var runs_b: [64]draw.Run = undefined;
    var text_bytes_b: [2048]u8 = undefined;
    const scrolled = try view(props, try build.build(props, .{
        .nodes = &nodes_b,
        .entries = &entries_b,
        .layout_items = &layout_items_b,
        .flex_scratch = &flex_scratch_b,
        .child_rects = &child_rects_b,
        .actions = &actions_b,
    }), .{}, &tk, .{ .ops = &ops_b, .runs = &runs_b, .text_bytes = &text_bytes_b });

    // 목록에 속한 run만 본다. 고정 chrome(헤더·scope·검색)은 스크롤해도 제자리다.
    const list_texts = [_][]const u8{
        "expanded-card-title",  "expanded-summary",  "expanded-meta",
        "최근 대화",
        "61건",
        "detail-turn-text",
        "터미널에서 이어하기",
        "로그 보기",
        "neighbour-card-title", "neighbour-summary", "neighbour-meta",
    };
    var matched: usize = 0;
    for (list_texts) |needle| {
        const before = originYFor(rested.ops, needle) orelse continue;
        // 스크롤로 clip 밖에 나간 run은 아예 emit되지 않는다 — 그건 올바른 결과다.
        const after = originYFor(scrolled.ops, needle) orelse continue;
        matched += 1;
        try std.testing.expectEqual(before + shift, after);
    }
    // 단언이 비지 않았는가 — 겹침 그 자체인 조합(펼친 detail의 글자 + 뒤따르는 이웃 카드)이 실제로
    // 두 프레임 모두에 있어야 이 비교가 결함을 잡는다.
    try std.testing.expect(matched >= 3);
    var matched_detail = false;
    inline for (.{ "최근 대화", "61건", "detail-turn-text" }) |needle| {
        if (originYFor(rested.ops, needle) != null and originYFor(scrolled.ops, needle) != null) matched_detail = true;
    }
    try std.testing.expect(matched_detail);
    try std.testing.expect(originYFor(rested.ops, "neighbour-card-title") != null);
    try std.testing.expect(originYFor(scrolled.ops, "neighbour-card-title") != null);
}

// 사용자 보고 회귀: 펼친 카드의 액션이 라벨도 아이콘도 없는 빈 상자로 보였다. `action`은 button
// content 높이가 label line box보다 작으면 **조용히** 아무 op도 내지 않는데, 그 조용한 drop이
// 도달 가능하다는 것이 결함이다. 라벨과 아이콘은 legacy cell 경로가 아니라 measured 경로에만 있으므로
// 이 drop은 곧 "활성처럼 보이는 빈 버튼"이다 — 문서가 금지한 상태다(§2.1.2: label이 비면 icon-only
// action을 추측해 활성화하지 않는다). 목록이 viewport를 넘겨 layout이 압축을 시도하는 바로 그 상황에서
// 단언한다.
test "SessionDock keeps its action label when the expansion cannot fit the viewport" {
    const props = types.Props{
        .viewport_px = .{ .width = 640, .height = 640 },
        .cell_width_px = 8,
        .cell_height_px = 16,
        .snapshot_generation = 3,
        .displayed_count = 2,
        .expanded_identity = 1,
        .items = &.{
            .{ .card = .{
                .identity = 1,
                .provider = .claude,
                .title = "expanded-title",
                .summary = "expanded-summary",
                .metadata = "expanded-meta",
                .expanded = .{
                    .state = .ready,
                    .resume_enabled = true,
                    .reveal_enabled = true,
                    .turns = &.{.{ .role = .user, .text = "turn-text" }},
                },
            } },
            .{ .card = .{ .identity = 2, .provider = .codex, .title = "next-title", .summary = "next-summary", .metadata = "next-meta" } },
        },
    };
    var nodes: [16]tree.UiNode = undefined;
    var entries: [17]tree.RectEntry = undefined;
    var layout_items: [17]@import("../../ui/layout.zig").Item = undefined;
    var flex_scratch: [17]@import("../../ui/layout.zig").FlexScratch = undefined;
    var child_rects: [17]@import("../../ui/layout.zig").UiRect = undefined;
    var actions: [12]@import("ids.zig").Entry = undefined;
    const frame = try build.build(props, .{
        .nodes = &nodes,
        .entries = &entries,
        .layout_items = &layout_items,
        .flex_scratch = &flex_scratch,
        .child_rects = &child_rects,
        .actions = &actions,
    });
    const tk = fixtureTokens();
    var ops: [96]draw.Op = undefined;
    var runs: [96]draw.Run = undefined;
    var text_bytes: [4096]u8 = undefined;
    const out = try view(props, frame, .{}, &tk, .{ .ops = &ops, .runs = &runs, .text_bytes = &text_bytes });
    var resume_label: ?draw.TextPlacement = null;
    var reveal_label = false;
    for (out.ops) |op| switch (op) {
        .text => |text| for (text.runs) |run| {
            if (std.mem.eql(u8, run.text, "터미널에서 이어하기")) resume_label = text.placement;
            reveal_label = reveal_label or std.mem.eql(u8, run.text, "로그 보기");
        },
        else => {},
    };
    // 배경 quad만 남고 label/icon이 사라지는 것이 사용자가 본 빈 버튼이다.
    try std.testing.expect(resume_label != null);
    try std.testing.expect(reveal_label);
    switch (resume_label.?) {
        .leading_icon_group => |group| try std.testing.expectEqual(@as(u21, 0xF000C), group.icon_codepoint),
        else => return error.TestUnexpectedResult,
    }
}

// 사용자 보고 회귀: 목록을 스크롤하면 그룹 이름과 count pill이 고정 chrome(검색 필드) 위에 그려졌다.
// 그룹 행은 텍스트와 **직접 만든 장식 quad**를 함께 내는 유일한 행이라, 두 경로 모두 published clip을
// 소비해야 한다. 텍스트는 backend가 뷰포트로 자르도록 소속만 표시하고(픽셀 정확), component가 직접
// 만드는 pill quad는 `ui_paint`의 카드 배경과 같은 규율로 여기서 교차시킨다.
test "SessionDock group header runs are scroll clipped and its pill stays inside the clip" {
    const metrics = types.DockMetrics.resolve(1000);
    const props = types.Props{
        .viewport_px = .{ .width = 640, .height = 480 },
        .cell_width_px = 8,
        .cell_height_px = 16,
        .snapshot_generation = 1,
        .displayed_count = 1,
        // 그룹 행의 위쪽 절반을 content clip 위로 밀어 올린다. pill이 부분적으로 걸쳐야 "잘려서 남는다"를
        // 볼 수 있다 — 완전히 밖이면 아예 안 나오는 것이 옳은 결과라 단언이 비어 버린다.
        .content_first_item_origin_y_px = -@as(i32, @intCast(metrics.group_h / 2)),
        .items = &.{
            .{ .group = .{ .identity = 1, .label = "OVERFLOWGROUP", .count = 7 } },
            .{ .card = .{ .identity = 2, .provider = .claude, .title = "next-title", .summary = "next-summary", .metadata = "next-meta" } },
        },
    };
    var nodes: [10]tree.UiNode = undefined;
    var entries: [11]tree.RectEntry = undefined;
    var layout_items: [11]@import("../../ui/layout.zig").Item = undefined;
    var flex_scratch: [11]@import("../../ui/layout.zig").FlexScratch = undefined;
    var child_rects: [11]@import("../../ui/layout.zig").UiRect = undefined;
    var actions: [10]@import("ids.zig").Entry = undefined;
    const frame = try build.build(props, .{
        .nodes = &nodes,
        .entries = &entries,
        .layout_items = &layout_items,
        .flex_scratch = &flex_scratch,
        .child_rects = &child_rects,
        .actions = &actions,
    });
    const tk = fixtureTokens();
    var ops: [64]draw.Op = undefined;
    var runs: [64]draw.Run = undefined;
    var text_bytes: [2048]u8 = undefined;
    const out = try view(props, frame, .{}, &tk, .{ .ops = &ops, .runs = &runs, .text_bytes = &text_bytes });
    const content = find(frame.tree, build.NodeIds.content) orelse return error.TestUnexpectedResult;
    const clip_top: f32 = content.rect.y;
    const clip_bottom: f32 = content.rect.y + content.rect.height;
    var label_scroll_clipped: ?bool = null;
    var saw_next = false;
    for (out.ops) |op| switch (op) {
        .text => |text| for (text.runs) |run| {
            if (std.mem.indexOf(u8, run.text, "OVERFLOWGROUP") != null) label_scroll_clipped = text.scroll_clipped;
            saw_next = saw_next or std.mem.indexOf(u8, run.text, "next-title") != null;
        },
        else => {},
    };
    // 라벨은 emit되되 스크롤 소속으로 표시된다 — 잘라내는 일은 backend가 픽셀 단위로 한다.
    try std.testing.expectEqual(@as(?bool, true), label_scroll_clipped);
    // 뒤따르는 카드는 여전히 보여야 한다 — over-clipping도 결함이다.
    try std.testing.expect(saw_next);
    // component가 직접 만드는 pill quad는 published clip 밖으로 나가지 않는다.
    var saw_pill = false;
    for (out.ops) |op| switch (op) {
        .quad => |quad| if (quad.fill_role == .inset_bg) {
            saw_pill = true;
            const top: f32 = @floatFromInt(quad.rect.y);
            const bottom = top + @as(f32, @floatFromInt(quad.rect.h));
            try std.testing.expect(top >= clip_top);
            try std.testing.expect(bottom <= clip_bottom);
        },
        else => {},
    };
    try std.testing.expect(saw_pill);
}

// 사용자 보고 회귀: 그룹의 count pill이 행 아래로 밀려 카드 위에 걸쳐 보였다. 원인은 세로 중앙 계산의
// 괄호다 — `y + (h - pill/2)`는 중앙이 아니라 거의 바닥이다. 정답은 `y + (h - pill)/2`.
test "SessionDock group count pill is vertically centred in its row" {
    const props = types.Props{
        .viewport_px = .{ .width = 640, .height = 480 },
        .cell_width_px = 8,
        .cell_height_px = 16,
        .snapshot_generation = 1,
        .displayed_count = 1,
        .items = &.{.{ .group = .{ .identity = 1, .label = "workspace", .count = 11 } }},
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
    const tk = fixtureTokens();
    var ops: [64]draw.Op = undefined;
    var runs: [64]draw.Run = undefined;
    var text_bytes: [2048]u8 = undefined;
    const out = try view(props, frame, .{}, &tk, .{ .ops = &ops, .runs = &runs, .text_bytes = &text_bytes });
    const row = find(frame.tree, build.NodeIds.item(0)) orelse return error.TestUnexpectedResult;
    var pill: ?draw.Op.Quad = null;
    for (out.ops) |op| switch (op) {
        .quad => |quad| if (quad.fill_role == .inset_bg) {
            pill = quad;
        },
        else => {},
    };
    const found = pill orelse return error.TestUnexpectedResult;
    const row_top: f32 = row.rect.y;
    const row_bottom: f32 = row.rect.y + row.rect.height;
    const pill_top: f32 = @floatFromInt(found.rect.y);
    const pill_bottom: f32 = pill_top + @as(f32, @floatFromInt(found.rect.h));
    // pill 전체가 행 안에 있고, 위아래 여백이 1px 이내로 같아야 중앙이다.
    try std.testing.expect(pill_top >= row_top);
    try std.testing.expect(pill_bottom <= row_bottom);
    try std.testing.expect(@abs((pill_top - row_top) - (row_bottom - pill_bottom)) <= 1);
}

fn fixtureTokens() tokens.Tokens {
    return tokens.Tokens.rich(.{
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
}

fn originYFor(ops: []const draw.Op, needle: []const u8) ?i32 {
    for (ops) |op| switch (op) {
        .text => |text| for (text.runs) |run| {
            if (std.mem.indexOf(u8, run.text, needle) != null) return text.origin.y;
        },
        else => {},
    };
    return null;
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
    const expected_count_y = (count_pill_y orelse return error.TestUnexpectedResult) + @as(i32, @intCast((spacing.pointsPx(32, props.scale_milli) - typography.lineHeightPx(.control, props.scale_milli)) / 2));
    try std.testing.expectEqual(expected_count_y, count_y orelse return error.TestUnexpectedResult);
}

test "SessionDock action declares one worker-measured SVG icon and Korean label group" {
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
    var label_cols: ?u16 = null;
    var label_max_width: ?u32 = null;
    var label_placement: ?draw.TextPlacement = null;
    for (out.ops) |op| switch (op) {
        .text => |text| for (text.runs) |run| {
            if (std.mem.eql(u8, run.text, "터미널에서 이어하기")) {
                try std.testing.expect(!text.wide_icons);
                try std.testing.expectEqual(typography.ChromeTextRole.button_label, text.text_role);
                label_cols = text.max_cols;
                label_max_width = text.max_width_px;
                label_placement = text.placement;
            }
        },
        else => {},
    };
    const action_rect = find(frame.tree, build.NodeIds.resumeAction(0)) orelse return error.TestUnexpectedResult;
    const button = types.ButtonMetrics.resolve(props.scale_milli);
    const expected_content_width: u32 = @intFromFloat(@floor(action_rect.rect.width - @as(f32, @floatFromInt(button.content_inset_x_px * 2))));
    const expected_content_height: u32 = @intFromFloat(@floor(action_rect.rect.height - @as(f32, @floatFromInt(button.content_inset_y_px * 2))));
    try std.testing.expect((label_cols orelse 0) > 0);
    try std.testing.expectEqual(expected_content_width - button.leading_icon_extent_px - button.leading_icon_gap_px, label_max_width orelse return error.TestUnexpectedResult);
    switch (label_placement orelse return error.TestUnexpectedResult) {
        .leading_icon_group => |group| {
            try std.testing.expectEqual(@as(u21, 0xF000C), group.icon_codepoint);
            try std.testing.expectEqual(@as(u16, @intCast(button.leading_icon_extent_px)), group.icon_extent_px);
            try std.testing.expectEqual(@as(u16, @intCast(button.leading_icon_gap_px)), group.gap_px);
            try std.testing.expectEqual(expected_content_width, group.content_rect.w);
            try std.testing.expectEqual(expected_content_height, group.content_rect.h);
        },
        else => return error.TestUnexpectedResult,
    }
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
