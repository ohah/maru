//! Semantic paint and text projection for a completed Session Dock rect tree.
//!
//! The generic UI painter owns card backgrounds; this file adds only component-owned text runs.
//! It never asks a platform for glyph positions, so the backend remains a one-way ChromeDraw lowerer.

const std = @import("std");
const icons = @import("../../../icons.zig");
const badge = @import("../../ui/badge.zig");
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
// Dock controls select shared semantic icons with `Fit.tight` rather than dock-specific names: all
// occupy the standard two-cell icon slot, and the tight assets fill it more (search tightens the view
// box, the chevrons keep it and thicken the stroke) so their optical size stays consistent with cards.
//
// fit을 **전부 명시**한다. `reset`·`search`·`chevron_*`는 변형이 실재하므로 fit을 빼면 **지금 당장** 다른
// 그림이 된다(`.tight`는 선택이 아니라 필수다). `host`는 지금 변형이 하나뿐이라 같은 값이지만, 나중에 다른
// fit이 등록되면 기본이 뒤집혀 도크가 조용히 다른 그림을 그린다(적대적 검증이 짚은 default flip).
const refresh_icon = icons.utf8Fit(.reset, .tight);
const search_icon = icons.utf8Fit(.search, .tight);
const chevron_down_icon = icons.utf8Fit(.chevron_down, .tight);
const chevron_right_icon = icons.utf8Fit(.chevron_right, .tight);
const host_icon = icons.utf8Fit(.host, .standard);
const resume_icon = icons.utf8(.recent);
const reveal_icon = icons.utf8(.document);
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

    // 목록 본문은 여기서부터다. scroll-area의 clip을 열어 두면 그 안에서 나온 장식 quad는 호출처가
    // 기억하지 않아도 전부 잘린다.
    const content_entry = find(frame.tree, build.NodeIds.content) orelse return error.MissingRect;
    writer.container_clip = clipRectOf(content_entry);

    if (props.loading and props.items.len == 0) {
        try writer.skeletons(content_entry);
    }

    // 여기부터가 스크롤 목록이다. 고정 chrome은 위에서 이미 emit됐다.
    writer.scroll_clipped = true;
    for (props.items, 0..) |item, index| {
        const rect = find(frame.tree, build.NodeIds.item(index)) orelse return error.MissingRect;
        // 이 행의 published clip을 op에 함께 싣는다. 배경 quad는 GPU가 픽셀 단위로 자르는데 셀 경로의
        // 글자만 그대로 남으면 배경 반쪽에 글자가 떠 있는 그림이 된다.
        writer.active_clip = clipRectOf(rect);
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
                try writer.textAtY(card_rect, dock_metrics.card_inset_x, dock_metrics.card_title_y, card.title, .surface_fg, .card_heading, false, dock_metrics.cardDisclosureReserve());
                try writer.textAtY(card_rect, dock_metrics.card_inset_x, dock_metrics.card_summary_y, card.summary, .muted_fg, .body, false, dock_metrics.cardDisclosureReserve());
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
    /// 지금 emit 중인 **행**의 published clip. 셀 격자로 lowering하는 backend(Lab·모달)는 뷰포트를 모르므로
    /// 이 rect로 자른다. measured 경로는 무시한다(위 bool과 backend 뷰포트를 쓴다).
    active_clip: ?draw.Rect = null,
    /// 지금 열려 있는 **컨테이너**(스크롤 영역, 펼친 카드의 detail surface)의 clip. 축이 `active_clip`과
    /// 다르다 — 저쪽은 행 하나이고 이쪽은 그 행들을 담는 상자다. 어느 행에도 속하지 않는 장식 quad
    /// (로딩 스켈레톤 등)가 이 값을 기본값으로 받는다. null은 "자를 컨테이너 없음"(고정 chrome)이다.
    container_clip: ?draw.Rect = null,

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
        const extent = metrics.group_disclosure_extent;
        // 우측 inset은 카드가 이미 소유한 logical content inset이다. 예전에는 terminal cell 폭을 썼는데,
        // 그러면 터미널 폰트를 바꾸는 것만으로 chevron이 좌우로 움직여 docs/agent-session-list.md §2.1.1의
        // "도크 기하는 terminal cell에서 결정하지 않는다"를 어긴다. 좌측 텍스트 inset과 같은 값을 써서
        // chevron의 우측 여백이 카드 좌측 여백과 시각적으로 맞도록 한다.
        const inset: f32 = @floatFromInt(metrics.card_inset_x);
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
    ///
    /// `trailing_reserve_px`는 이 줄이 절대 침범하면 안 되는 우측 영역(카드의 disclosure slot 등)이다.
    /// 최종 ellipsis는 worker가 measured advance로 정하지만, 그 예산에서 이 폭을 미리 빼 두지 않으면
    /// 잘린 텍스트가 우측 affordance에 그대로 맞닿는다.
    fn textAtY(self: *Writer, rect: tree.RectEntry, inset_x: u32, offset_y: u32, source: []const u8, role: tokens.ColorRole, text_role: typography.ChromeTextRole, bold: bool, trailing_reserve_px: u32) ViewError!void {
        const cw = self.props.cell_width_px;
        const ch = self.props.cell_height_px;
        if (cw == 0 or ch == 0) return;
        const x = rect.rect.x + @as(f32, @floatFromInt(inset_x));
        const y = rect.rect.y + @as(f32, @floatFromInt(offset_y));
        const available_px = rect.rect.width - @as(f32, @floatFromInt(inset_x + cw + trailing_reserve_px));
        if (available_px <= 0) return;
        const max_cols: u16 = @intFromFloat(@min(
            @floor(available_px / @as(f32, @floatFromInt(cw))),
            @as(f32, @floatFromInt(std.math.maxInt(u16))),
        ));
        try self.emit(x, y, source, max_cols, .head, role, text_role, false, bold);
    }

    fn cardMetadataAtY(self: *Writer, rect: tree.RectEntry, metrics: types.DockMetrics, provider: []const u8, metadata: []const u8) ViewError!void {
        try self.textAtY(rect, metrics.card_inset_x, metrics.card_metadata_y, provider, .surface_fg, .metadata, false, metrics.cardDisclosureReserve());
        const cw = self.props.cell_width_px;
        const ch = self.props.cell_height_px;
        if (cw == 0 or ch == 0) return;
        const provider_cols = plannedCols(provider, 24);
        const provider_width = @as(u32, provider_cols) * cw;
        const metadata_inset = metrics.card_inset_x + provider_width + spacing.px(.xs, effectiveScale(self.props.scale_milli));
        const x = rect.rect.x + @as(f32, @floatFromInt(metadata_inset));
        const y = rect.rect.y + @as(f32, @floatFromInt(metrics.card_metadata_y));
        // metadata는 카드에서 가장 오른쪽까지 뻗는 줄이라 chevron과 부딪히기 가장 쉽다. 제목·요약과
        // 정확히 같은 예약을 쓴다.
        const available_px = rect.rect.width - @as(f32, @floatFromInt(metadata_inset + cw + metrics.cardDisclosureReserve()));
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
        const count_cols = @max(plannedCols(count, 4), 1);
        const icon_slot = metrics.group_disclosure_extent + metrics.group_disclosure_label_gap;
        // 치수·자리·"안 들어가면 안 그린다"는 badge 프리미티브가 소유한다. 여기서 다시 풀면
        // 그 산수가 컴포넌트마다 갈린다(pill이 행 밖으로 내려간 회귀가 그 산수였다).
        const pill = badge.countPill(rect.rect, horizontal_inset, count_cols, cw, scale, icon_slot) orelse return;
        try self.appendQuadClippedBy(rect, .{
            .rect = pill.box,
            .fill_role = .inset_bg,
            .corner_radii = .{ pill.radius_px, pill.radius_px, pill.radius_px, pill.radius_px },
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
        const label_end = @as(f32, @floatFromInt(pill.box.x)) - @as(f32, @floatFromInt(spacing.px(.xs, scale)));
        if (label_end > label_x) {
            const max_cols: u16 = @intFromFloat(@floor((label_end - label_x) / @as(f32, @floatFromInt(cw))));
            const group_heading_h: f32 = @floatFromInt(typography.lineHeightPx(.group_heading, scale));
            if (max_cols > 0 and rect.rect.height >= group_heading_h)
                try self.emit(label_x, rect.rect.y + (rect.rect.height - group_heading_h) / 2, group.label, max_cols, .head, .surface_fg, .group_heading, false, true);
        }

        // 라벨이 상자보다 높으면 숫자만 생략한다 — pill·chevron·이름은 그대로 둔다.
        if (pill.label_fits)
            try self.emit(pill.label_x, pill.label_y, count, count_cols, .head, .surface_fg, .control, false, true);
    }

    /// **모든** 장식 quad는 이 한 곳을 지난다. clip을 명시하지 않은 quad에는 지금 열려 있는 컨테이너의
    /// clip을 자동으로 싣는다 — clip을 "그리는 쪽이 매번 기억해야 하는 opt-in"으로 두면 한 군데만 빠뜨려도
    /// 그 quad가 스크롤 영역 밖으로 새어 고정 chrome 위에 그려진다(사용자 보고: 로딩 스켈레톤 막대가
    /// 목록 밖까지 그려짐 — `skeletonLine`이 clip을 안 실었다). CSS로 치면 스크롤 컨테이너의
    /// `overflow: hidden`이 자식에게 자동으로 적용되는 것과 같은 자리다.
    fn appendQuad(self: *Writer, quad: draw.Op.Quad) ViewError!void {
        if (self.op_count == self.ops.len) return error.InsufficientTextBuffer;
        var owned = quad;
        if (owned.clip == null) owned.clip = self.container_clip;
        self.ops[self.op_count] = .{ .quad = owned };
        self.op_count += 1;
    }

    /// 장식 quad에 자기 published clip을 **실어서** 낸다. 교차를 여기서 계산하지 않는 것이 핵심이다 —
    /// 자르는 일은 backend 몫이라야 잘린 변의 radius/border 보정 같은 세부를 컴포넌트마다 반복하지 않고,
    /// 나중에 그 구현을 GPU로 옮길 때도 컴포넌트가 영향을 받지 않는다.
    fn appendQuadClippedBy(self: *Writer, rect: tree.RectEntry, quad: draw.Op.Quad) ViewError!void {
        var owned = quad;
        owned.clip = clipRectOf(rect) orelse self.container_clip;
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
        }, .surface_fg, .body, false, 0);
        switch (expanded_props.state) {
            .ready => {
                if (expanded_props.action_record_count > 0) {
                    var count: [80]u8 = undefined;
                    const label = std.fmt.bufPrint(&count, "도구/권한 관련 기록 {d}건", .{expanded_props.action_record_count}) catch "도구/권한 관련 기록";
                    try self.textAtY(detail, metrics.detail_inset_x, metrics.detail_record_y, label, .muted_fg, .metadata, false, 0);
                }
                for (expanded_props.turns, 0..) |turn, turn_index| {
                    const turn_y = metrics.detail_turn_y + @as(u32, @intCast(turn_index)) * metrics.detail_turn_step;
                    try self.textAtY(detail, metrics.detail_inset_x, turn_y, switch (turn.role) {
                        .user => "사용자",
                        .assistant => "에이전트",
                    }, .muted_fg, .overline, false, 0);
                    const body_y = turn_y + typography.lineHeightPx(.overline, effectiveScale(self.props.scale_milli)) + spacing.px(.xxs, effectiveScale(self.props.scale_milli));
                    try self.textAtY(detail, metrics.detail_inset_x, body_y, turn.text, .surface_fg, .body, false, 0);
                }
            },
            .loading => try self.skeletons(detail),
            .stale => try self.textAtY(detail, metrics.detail_inset_x, metrics.detail_turn_y, "안전하게 재개하거나 로그를 열 수 없습니다.", .muted_fg, .body, false, 0),
            .unavailable => try self.textAtY(detail, metrics.detail_inset_x, metrics.detail_turn_y, "원본을 읽을 수 없습니다.", .muted_fg, .body, false, 0),
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
            .clip = self.active_clip,
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
            .clip = self.active_clip,
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
    /// `content`는 스크롤 영역일 수도, 펼친 카드의 detail surface일 수도 있다. 어느 쪽이든 그 rect가
    /// 스켈레톤의 경계이므로 emit 동안 그 clip을 연다 — 바깥 clip(스크롤 영역)만 쓰면 detail 안의 막대가
    /// 이웃 카드 위로 넘칠 수 있다(막대 배치는 카드 높이 배수라 detail 바닥을 실제로 넘긴다).
    fn skeletons(self: *Writer, content: tree.RectEntry) ViewError!void {
        const outer_clip = self.container_clip;
        defer self.container_clip = outer_clip;
        self.container_clip = clipRectOf(content) orelse outer_clip;
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

    /// **`ops` 배열에 직접 쓰지 않는다.** 예전에는 여기서 직접 썼는데, 그러면 clip을 실어 주는 유일한
    /// 지점(`appendQuad`)을 우회해 스켈레톤 막대가 스크롤 영역 밖까지 그려졌다(사용자 보고). 장식 quad는
    /// 예외 없이 `appendQuad`를 지난다.
    /// **`ops`에 직접 쓰지 않는다.** 예전에는 여기서 직접 썼고, 그래서 clip을 실어 주는 유일한 지점을
    /// 통째로 우회해 로딩 스켈레톤 막대가 스크롤 영역 밖까지 그려졌다(사용자 보고). 장식 quad는 예외 없이
    /// `appendQuad`를 지난다 — 그 규율이 이 결함의 재발을 막는 유일한 장치다.
    fn skeletonLine(self: *Writer, x: f32, y: f32, width: f32, height: u32) ViewError!void {
        if (width <= 0 or height == 0) return;
        try self.appendQuad(.{
            .rect = .{
                .x = @intFromFloat(@floor(x)),
                .y = @intFromFloat(@floor(y)),
                .w = @intFromFloat(@floor(width)),
                .h = height,
            },
            .fill_role = .divider,
            .corner_radii = .{ self.corner_radius_px, self.corner_radius_px, self.corner_radius_px, self.corner_radius_px },
            .alpha = 0x90,
        });
    }
};

/// published clip을 semantic op에 실을 수 있는 정수 rect로 옮긴다. 자르지 않고 **전달만** 한다.
fn clipRectOf(entry: tree.RectEntry) ?draw.Rect {
    const clip = entry.effective_clip orelse return null;
    return .{
        .x = @intFromFloat(@ceil(clip.x)),
        .y = @intFromFloat(@ceil(clip.y)),
        .w = @intFromFloat(@max(@floor(clip.width), 0)),
        .h = @intFromFloat(@max(@floor(clip.height), 0)),
    };
}

fn effectiveScale(scale_milli: u32) u32 {
    return if (scale_milli == 0) 1000 else scale_milli;
}

/// 도크가 **자기 것으로 선언한** 아이콘인가 — 위 상수들이 실제로 고른 (아이콘, fit) 조합과 정확히 같은 집합이다.
///
/// fit까지 **전부** 본다. affordance는 tight를, 카드 라벨(recent·document)과 host는 standard를 쓰는데,
/// fit을 안 보면 나중에 다른 변형이 등록되는 순간 이 집합이 조용히 넓어져 그 셀이 width-2로 벌어진다
/// (적대적 검증 지적). 조합이 늘면 위 상수와 여기를 함께 고치는 것이 규약이다.
fn isSessionDockIcon(codepoint: u21) bool {
    const resolved = icons.fromCodepoint(codepoint) orelse return false;
    return switch (resolved.icon) {
        .recent, .document, .host => resolved.fit == .standard,
        .reset, .search, .chevron_down, .chevron_right => resolved.fit == .tight,
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
                    if (icon.icon_codepoint == icons.codepointFit(.reset, .tight)) refresh_placement = text.placement;
                    if (icon.icon_codepoint == icons.codepointFit(.search, .tight)) search_placement = text.placement;
                    // 카드의 disclosure도 같은 chevron codepoint를 같은 `icon_in_rect` 경로로 낸다.
                    // 목록에서 group이 먼저 나오므로 첫 매칭만 잡아 그룹 것을 본다.
                    if (icon.icon_codepoint == icons.codepointFit(.chevron_down, .tight) and group_chevron_placement == null) {
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
            try std.testing.expectEqual(icons.codepointFit(.search, .tight), icon.icon_codepoint);
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
            try std.testing.expectEqual(icons.codepoint(.host), group.icon_codepoint);
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
            try std.testing.expectEqual(icons.codepointFit(.reset, .tight), icon.icon_codepoint);
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
                if (icon.icon_codepoint == icons.codepointFit(.reset, .tight)) loading_refresh = text.placement;
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
        .leading_icon_group => |group| try std.testing.expectEqual(icons.codepoint(.recent), group.icon_codepoint),
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
    // component가 직접 만드는 pill quad는 **자기 published clip을 실어서** 낸다. 자르는 일은 backend
    // 몫이므로 여기서 rect가 잘려 있기를 기대하지 않는다 — 그걸 기대하면 컴포넌트마다 교차와 잘린 변
    // 모양 보정을 반복해야 하고, 새 스크롤 컴포넌트가 그 규칙을 모르면 조용히 같은 결함이 재발한다.
    var pill_clip: ?draw.Rect = null;
    for (out.ops) |op| switch (op) {
        .quad => |quad| if (quad.fill_role == .inset_bg) {
            pill_clip = quad.clip;
        },
        else => {},
    };
    // 실린 clip은 그룹 행의 published clip(= content 뷰포트 ∩ 행 rect)이므로, content 안에 들어 있고
    // 행이 위로 잘린 만큼 상단이 content 경계에 붙는다.
    const clip = pill_clip orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i32, @intFromFloat(@ceil(clip_top))), clip.y);
    try std.testing.expect(clip.y + @as(i32, @intCast(clip.h)) <= @as(i32, @intFromFloat(@floor(clip_bottom))));
    try std.testing.expect(clip.h > 0);
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
            try std.testing.expectEqual(icons.codepoint(.recent), group.icon_codepoint);
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

// 이 테스트가 증명하는 것: 카드의 제목·요약·metadata 폭 예산이 disclosure chevron slot과 겹치지 않는다.
//
// 왜 중요한가 — 최종 ellipsis는 platform worker가 measured advance로 정하지만, 그 worker에게 넘기는
// **폭 예산**은 component가 정한다. 예산이 chevron slot까지 덮고 있으면 잘린 텍스트의 말줄임표가
// 아이콘에 그대로 맞닿거나 그 아래로 흘러들어 둘이 한 덩어리로 보인다(사용자 보고 스크린샷).
// slot 위치와 텍스트 예산이 같은 `DockMetrics` 항에서 나오는지를 published op으로 직접 확인한다.
test "SessionDock card text budget never reaches the disclosure chevron slot" {
    const props = types.Props{
        .viewport_px = .{ .width = 640, .height = 480 },
        .cell_width_px = 8,
        .cell_height_px = 16,
        .scale_milli = 1000,
        .snapshot_generation = 31,
        .displayed_count = 1,
        .items = &.{
            .{
                .card = .{
                    .identity = 2,
                    .provider = .claude,
                    // 세 줄 모두 카드 폭을 넘겨 truncation 경로를 타게 한다 — 짧은 문자열은 예산을 다 쓰지
                    // 않으므로 이 회귀를 못 잡는다.
                    .title = "tool_use-id 처럼 아주 긴 제목이 카드 폭을 확실히 넘어가도록 충분히 길게 적는다",
                    .summary = "The messages below were generated by the user while running local commands",
                    .metadata = "메시지 4212개 · 방금 · claude-opus-4-1-20250805 (with 1M context) (default)",
                },
            },
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
    var ops: [48]draw.Op = undefined;
    var runs: [48]draw.Run = undefined;
    var text_bytes: [4096]u8 = undefined;
    const out = try view(props, frame, .{}, &tk, .{ .ops = &ops, .runs = &runs, .text_bytes = &text_bytes });

    const card = frame.tree.entries[frame.tree.find(build.NodeIds.item(0)).?];
    const metrics = types.DockMetrics.resolve(props.scale_milli);

    // chevron slot을 published op에서 그대로 읽는다 — 테스트가 좌표를 스스로 재구성하면 component가
    // slot을 옮긴 뒤에도 통과해 버린다. disclosure는 카드 텍스트보다 뒤에 emit되므로 먼저 한 번 훑는다.
    var chevron: ?draw.Rect = null;
    for (out.ops) |op| switch (op) {
        .text => |text| switch (text.placement) {
            .icon_in_rect => |icon| {
                if (icon.icon_codepoint == icons.codepointFit(.chevron_down, .tight) and chevron == null) chevron = icon.content_rect;
            },
            else => {},
        },
        else => {},
    };
    const slot = chevron orelse return error.TestUnexpectedResult;

    // chevron은 카드 우측 content inset 안에 놓인다 — 기준이 터미널 cell 폭이 아니라 logical inset이다.
    try std.testing.expectEqual(
        @as(i32, @intFromFloat(card.rect.x + card.rect.width)) - @as(i32, @intCast(metrics.card_inset_x + metrics.group_disclosure_extent)),
        slot.x,
    );

    var checked_lines: usize = 0;
    for (out.ops) |op| switch (op) {
        .text => |text| switch (text.placement) {
            .origin => {
                // 카드 본문 줄만 본다(고정 chrome은 카드 rect 밖이다).
                const y: f32 = @floatFromInt(text.origin.y);
                if (y < card.rect.y or y >= card.rect.y + card.rect.height) continue;
                // worker에 넘어가는 실제 폭 예산은 `max_cols * cell_width`다(`opMaxWidthPx`의 fallback).
                const budget_px = @as(u32, text.max_cols) * props.cell_width_px;
                const right = @as(f32, @floatFromInt(text.origin.x)) + @as(f32, @floatFromInt(budget_px));
                if (right > @as(f32, @floatFromInt(slot.x))) return error.CardTextReachesDisclosureSlot;
                checked_lines += 1;
            },
            else => {},
        },
        else => {},
    };
    // title·summary·provider·metadata 네 줄이 모두 검사됐다.
    try std.testing.expectEqual(@as(usize, 4), checked_lines);
}

// 이 테스트가 증명하는 것: 스크롤 목록 안에서 나온 장식 quad가 **호출처가 기억하지 않아도** clip을 싣는다.
//
// 왜 중요한가 — clip 없는 quad는 backend가 자르지 않으므로 고정 header/scope/search 위, 심하면 도크 밖까지
// 그려진다. 실제로 `skeletonLine`이 clip을 안 실어 로딩 중 스켈레톤 막대가 목록 밖으로 새어 나갔다
// (사용자 보고). clip을 그리는 쪽의 opt-in으로 두면 새 장식 quad가 추가될 때마다 같은 결함이 재발하므로,
// 여기서 고정하는 것은 "스켈레톤이 잘린다"가 아니라 **컨테이너가 clip을 소유한다**는 계약이다.
test "SessionDock scroll-area decoration quads inherit the container clip" {
    const props = types.Props{
        .viewport_px = .{ .width = 480, .height = 360 },
        .cell_width_px = 8,
        .cell_height_px = 16,
        .snapshot_generation = 12,
        .displayed_count = 0,
        // 첫 스캔 상태 = skeleton. 이 경로가 clip 없는 quad를 내던 그 경로다.
        .loading = true,
        .items = &.{},
    };
    var nodes: [8]tree.UiNode = undefined;
    var entries: [12]tree.RectEntry = undefined;
    var layout_items: [12]@import("../../ui/layout.zig").Item = undefined;
    var flex_scratch: [12]@import("../../ui/layout.zig").FlexScratch = undefined;
    var child_rects: [12]@import("../../ui/layout.zig").UiRect = undefined;
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
    var ops: [64]draw.Op = undefined;
    var runs: [64]draw.Run = undefined;
    var text_bytes: [2048]u8 = undefined;
    const out = try view(props, frame, .{}, &tk, .{ .ops = &ops, .runs = &runs, .text_bytes = &text_bytes });

    const content = frame.tree.entries[frame.tree.find(build.NodeIds.content).?];
    const expected = clipRectOf(content) orelse return error.TestUnexpectedResult;

    // skeleton 막대는 `divider` 색 + 0x90 alpha라는 고유 서명을 갖는다. 이 서명으로 골라야 fixed chrome의
    // paint quad(자기 rect 안에 있고 clip이 없는 것이 정상)와 섞이지 않는다.
    var skeletons: usize = 0;
    for (out.ops) |op| switch (op) {
        .quad => |quad| {
            if (quad.fill_role != .divider or quad.alpha != 0x90) continue;
            skeletons += 1;
            const clip = quad.clip orelse return error.SkeletonQuadHasNoClip;
            try std.testing.expectEqual(expected, clip);
        },
        else => {},
    };
    // 전제가 살아 있는지 확인한다 — skeleton이 하나도 안 나왔다면 위 단언이 공허하다.
    try std.testing.expect(skeletons >= 3);
}
