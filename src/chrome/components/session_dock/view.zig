//! 완성된 Session Dock rect tree의 semantic paint·text 투영이다.
//!
//! card 배경은 범용 UI painter가 소유하고, 이 파일은 component가 가진 text run만 얹는다. platform에
//! glyph 위치를 묻지 않으므로 backend는 단방향 ChromeDraw lowerer로 남는다.

const std = @import("std");
const icons = @import("../../../icons.zig");
const i18n = @import("../../../i18n.zig"); // 표시 문자열 단일 출처
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

// The dock owns these registered SVG icons. A text glyph such as `↻` varies by fallback font and
// cannot promise the size or optical centre of a Chrome header affordance.
// Dock controls select shared semantic icons with `Fit.tight` rather than dock-specific names: all
// lower through `iconInRect`/`leading_icon_group` into the same 18pt logical slot (never a terminal
// cell — agent-session-list-layout.md §2.1.1; `headerRefresh`'s `!wide_icon` fallback is the one dormant cell
// path and its only caller passes `true`), and the tight assets fill that slot more (`search`/`reset` tighten the view box,
// the chevrons keep it and thicken the stroke) so their optical size stays consistent with cards.
//
// 헤더·카드 affordance는 fit을 **전부 명시**한다. `reset`·`search`·`chevron_*`는 변형이 실재하므로 fit을 빼면
// **지금 당장** 다른 그림이 된다(`.tight`는 선택이 아니라 필수다). `host`는 변형이 하나뿐이라 같은 값이고,
// action 아이콘(`recent`·`document`)은 아직 fit 없는 접근자를 쓴다 — 변형이 등록되는 순간 기본이 뒤집히므로
// 그때 함께 명시해야 한다(적대적 검증이 짚은 default flip).
const refresh_icon = icons.utf8Fit(.reset, .tight);
const search_icon = icons.utf8Fit(.search, .tight);
const chevron_down_icon = icons.utf8Fit(.chevron_down, .tight);
const chevron_right_icon = icons.utf8Fit(.chevron_right, .tight);
const host_icon = icons.utf8Fit(.host, .standard);
const resume_icon = icons.utf8(.recent);
const reveal_icon = icons.utf8(.document);
const host_label_key: i18n.Key = .sd_host_local;

pub const Buffers = struct {
    ops: []draw.Op,
    runs: []draw.Run,
    text_bytes: []u8,
};

pub const ViewError = ui_paint.PaintError || error{ InsufficientRunBuffer, InsufficientTextBuffer, MissingRect };

pub fn view(props: types.Props, frame: build.Frame, state: interaction.InteractionState, tk: *const tokens.Tokens, buffers: Buffers) ViewError!draw.ChromeDraw {
    // 스크롤바 fade 는 **여기서** 얹는다 — tree(`frame`)는 alpha 를 모른 채 불변으로 남아야
    // 발행 경로의 동등 비교가 살아 있다(계약 §7).
    const scrollbar_alpha = [_]ui_paint.IdAlpha{
        .{ .id = build.NodeIds.scroll_track, .alpha = props.scrollbar_alpha },
        .{ .id = build.NodeIds.scroll_thumb, .alpha = props.scrollbar_alpha },
    };
    const painted = try ui_paint.paintWithAlphaOverrides(frame.tree, state, tk, .sidebar, .{ .ops = buffers.ops }, &scrollbar_alpha);
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
    // 현재 snapshot과 scan 상태를 **분리해** 말한다(docs/agent-session-list.md §4). 예전 문구는
    // `N개 표시 · 최근 500개`로 상한을 광고했는데, 실제로 목록을 자르는 것은 그 상한이 아니라 read
    // budget이라 "500개 중 N개"가 사실과 달랐다. 잘렸으면 잘렸다고 말하고, 아니면 개수만 말한다.
    var count_buf: [48]u8 = undefined;
    const count = if (props.loading or props.refreshing)
        // `loading`은 아직 보여 줄 record가 하나도 없는 첫 스캔이다. 이때 개수만 말하면 `0개 표시`가 되어
        // **세션이 없다는 뜻으로 읽힌다** — 스캔 중임을 말해야 한다(docs/agent-session-list.md §4).
        i18n.format(&count_buf, i18n.t(.sd_count_analyzing), &.{.{ .d = props.displayed_count }})
    else if (props.partial)
        i18n.format(&count_buf, i18n.t(.sd_count_partial), &.{.{ .d = props.displayed_count }})
    else
        i18n.format(&count_buf, i18n.t(.sd_count), &.{.{ .d = props.displayed_count }});
    // 정렬 토글은 좁은 도크에서 발행되지 않는다. published tree의 유무가 단일 출처다 — view가 폭을
    // 다시 판정하면 두 곳의 규칙이 어긋난다.
    const sort_rect = find(frame.tree, build.NodeIds.sort_toggle);
    try writer.headerStack(header, i18n.t(.sd_header), count, sort_rect != null);
    try writer.headerProvenance(header, i18n.t(host_label_key), sort_rect != null);
    // The in-flight state deliberately keeps the registered SVG at its idle optical size.  The
    // old Unicode clock frames were one terminal-cell glyphs, so clicking refresh made the
    // control visibly shrink even though its hit rect stayed 24pt.  Until component transforms
    // own SVG rotation, a muted registered refresh glyph is the truthful busy affordance.
    try writer.headerRefresh(header, refresh_icon, if (props.loading or props.refreshing) .muted_fg else .surface_fg, true);

    // 정렬 토글. published 자식 rect 안에 label을 중앙 정렬해 그린다 — 방향이 바뀌어도 slot 폭이
    // 고정이라 옆의 `로컬`과 refresh가 움직이지 않는다.
    if (sort_rect) |rect| try writer.centeredLabel(rect, props.sort_order.label());

    try writer.centeredLabel(find(frame.tree, build.NodeIds.scope_workspace) orelse return error.MissingRect, i18n.t(.sd_scope_workspace));
    try writer.centeredLabel(find(frame.tree, build.NodeIds.scope_project) orelse return error.MissingRect, i18n.t(.sd_scope_project));
    try writer.centeredLabel(find(frame.tree, build.NodeIds.scope_all) orelse return error.MissingRect, i18n.t(.sd_scope_all));
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
    // 고정 헤더의 바닥. 목록 글자는 이 선 위로 올라가지 못한다.
    const sticky_rect: ?tree.RectEntry = if (props.sticky_group != null)
        (find(frame.tree, build.NodeIds.sticky_group) orelse return error.MissingRect)
    else
        null;
    const sticky_bottom: i32 = if (sticky_rect) |entry|
        @intFromFloat(@floor(entry.rect.y + entry.rect.height))
    else
        std.math.minInt(i32);
    for (props.items, 0..) |item, index| {
        const rect = find(frame.tree, build.NodeIds.item(index)) orelse return error.MissingRect;
        // 이 행의 published clip을 op에 함께 싣는다. 배경 quad는 GPU가 픽셀 단위로 자르는데 셀 경로의
        // 글자만 그대로 남으면 배경 반쪽에 글자가 떠 있는 그림이 된다.
        writer.active_clip = clipBelow(clipRectOf(rect), sticky_bottom);
        switch (item) {
            .group => |group| {
                try writer.groupHeader(rect, group);
            },
            .card => |card| {
                const card_rect = if (card.expanded != null)
                    find(frame.tree, build.NodeIds.cardHeader(index)) orelse return error.MissingRect
                else
                    rect;
                // **"제목은 마지막까지 남는다"** — 파일 탐색기·소스 컨트롤과 같은 규칙이다
                // (`file_tree/types.zig` 의 `rowLayout`, `scm_dock/view.zig` 의 `fileRowLadder`).
                // 카드가 좁아지면 **disclosure 예약 → 메타데이터 줄 → 요약 줄** 순으로 버린다.
                //
                // 이 사다리가 없을 때 도크 하한(폭 104pt)에서 카드가 **통째로 비었다** — chevron 하나만
                // 남고 제목·요약·메타가 전부 사라졌다(Lab 캡처 실측 2026-08-25). `textAtY` 가 예산이
                // 0 이하면 조용히 돌아가기 때문이고, disclosure 예약(48pt)이 그 폭을 먼저 먹었다.
                const card_ladder = writer.cardLadder(card_rect, dock_metrics);
                // Card y offsets are DockMetrics values, not 1/3/5 terminal rows. This keeps
                // its three-line density and the disclosure hit rect stable across terminal
                // font zoom while the worker still owns actual glyph shaping and ellipsis.
                try writer.textAtY(card_rect, card_ladder.inset_x, dock_metrics.card_title_y, card.title, .surface_fg, .card_heading, false, card_ladder.trailing_reserve_px);
                if (card_ladder.show_summary) try writer.textAtY(card_rect, card_ladder.inset_x, dock_metrics.card_summary_y, card.summary, .muted_fg, .body, false, card_ladder.trailing_reserve_px);
                if (card_ladder.show_metadata) try writer.cardMetadataAtY(card_rect, dock_metrics, card.provider, card.metadata, card_ladder.inset_x);
                // The whole title card remains one disclosure action, but its trailing chevron
                // makes that interaction discoverable and shares the exact card rect used by
                // pointer/Enter. No separate tiny hit target is manufactured for the icon.
                if (card_ladder.show_disclosure) try writer.cardDisclosure(card_rect, dock_metrics);
                if (card.expanded) |expanded| try writer.expanded(frame.tree, index, expanded);
            },
        }
    }

    // 고정 헤더는 목록 **뒤**에 그린다 — 지나간 카드가 그 밑으로 흘러야 한다. 스크롤바보다 앞이지만
    // 그건 tree의 발행 순서가 정하는 것이고(§4.7), 여기서는 목록 위라는 것만 지킨다. 흐름 위의 그룹
    // 행과 같은 `groupHeader`를 쓴다 — 같은 헤더가 위치에 따라 다르게 생기면 두 물건이 된다.
    if (props.sticky_group) |head| {
        const rect = sticky_rect.?;
        // 헤더 자신은 스크롤 평행이동을 받지 않는다 — 그 y는 `tree.build`가 이번 offset에서 다시
        // 계산한 절대값이다. 대신 자기 rect로 잘려, 밀려 나가는 동안 고정 chrome 위로 새지 않는다.
        writer.scroll_clipped = false;
        writer.above_scroll = true;
        writer.active_clip = clipRectOf(rect);
        try writer.groupHeader(rect, head.group);
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
    /// 지금 emit 중인 op이 스크롤 콘텐츠 **위에 뜬** 것인지(상단 고정 헤더). `scroll_clipped`와 배타적이다 —
    /// 평행이동은 안 받되 잘리기는 한다. 자르는 rect는 `active_clip`이 그대로 싣는다.
    above_scroll: bool = false,
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

    /// weight는 폰트별 좌표 보정이 아니라 semantic 위계다. 선택된 face와 그 측정 advance는 이미
    /// backend가 소유하므로 제목/그룹 강조는 폰트가 바뀌어도 안전하다.
    fn textStrong(self: *Writer, rect: tree.RectEntry, line: u32, source: []const u8, role: tokens.ColorRole, text_role: typography.ChromeTextRole, line_count: u32, wide_icons: bool, centered: bool) ViewError!void {
        return self.textStyled(rect, line, source, role, text_role, line_count, wide_icons, centered, true);
    }

    /// dock 헤더는 terminal 셀 두 칸이 아니라 두 role로 이뤄진 진짜 타이포그래피 스택이다.
    /// heading/supporting line box를 함께 가운데 정렬해야, point size가 바뀌거나 2배 backing scale에서
    /// legacy 셀 경로처럼 개수가 heading에 달라붙지 않는다.
    fn headerStack(self: *Writer, rect: tree.RectEntry, heading: []const u8, supporting: []const u8, has_sort: bool) ViewError!void {
        const cw = self.props.cell_width_px;
        if (cw == 0) return;
        const metrics = types.DockMetrics.resolve(self.props.scale_milli);
        const reserved_utility = metrics.headerUtilityWidth(has_sort);
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

    /// scope 세그먼트와 정렬 토글의 label. 자기 slot 안에서 **measured로** 가로·세로 중앙에 놓는다.
    ///
    /// 예전 cell 경로(`textInsetStyled`)는 두 가지를 함께 틀렸다. 첫째, x가 `rect.x + cell_width`라 label이
    /// slot 왼쪽에 붙어 세그먼트가 실제보다 넓고 성글게 보였다. 둘째, 폭 예산을 `floor(available/cell_width)`
    /// cols로 양자화해 slot에 들어갈 글자까지 미리 잘랐다 — `오래된순`이 잘려 보인 사용자 보고가 그것이다.
    /// `center_in_rect`는 worker의 실제 advance로 중앙을 잡으므로 face가 바뀌어도 같은 자리에 앉는다.
    ///
    /// **전경은 quad를 칠한 그 함수에서 받는다**(`Writer.state` 주석의 규율). 예전에는 `.surface_fg`를
    /// 박아 두었는데, 도크는 워크스페이스/프로젝트 root가 없으면 그 scope를 실제로 비활성으로 발행한다
    /// (`agent_dock.zig`). 그때 `resolveCard`는 배경·전경을 disabled로 낮추지만 label만 밝게 남아, 누를 수
    /// 있어 보이는데 안 눌리는 세그먼트가 됐다. hover/press/selected도 같은 이유로 어긋난다.
    fn centeredLabel(self: *Writer, rect: tree.RectEntry, source: []const u8) ViewError!void {
        const cw = self.props.cell_width_px;
        if (cw == 0) return;
        const line_h = typography.lineHeightPx(.control, effectiveScale(self.props.scale_milli));
        if (rect.rect.height < @as(f32, @floatFromInt(line_h)) or rect.rect.width <= 0) return;
        const content = draw.Rect{
            .x = @intFromFloat(@floor(rect.rect.x)),
            .y = @intFromFloat(@floor(rect.rect.y + (rect.rect.height - @as(f32, @floatFromInt(line_h))) / 2)),
            .w = @intFromFloat(@floor(rect.rect.width)),
            .h = line_h,
        };
        if (content.w == 0) return;
        // 폭 예산의 단일 출처는 아래 `max_width_px`(정확한 slot 폭)다. lowering이 `max_width_px orelse
        // max_cols * cell_width`로 예산을 풀기 때문에(chrome_draw_lowering.zig `textWidthBudget`), 이 값을
        // 실은 순간 measured 경로는 cols를 아예 보지 않는다 — 예전 경로가 `max_width_px`를 안 실어 예산이
        // cell 배수로 깎였고, 그것이 `오래된순` 잘림의 실제 원인이었다.
        //
        // 따라서 cols는 **legacy cell 백엔드(Lab·폴백) 전용 상한**으로만 남고, 여기서는 보수적인 `floor`가
        // 맞다. `ceil`은 그 경로에서 라벨이 slot을 최대 1 cell 넘겨 이웃 세그먼트를 침범시킨다. slot이 한
        // 셀보다 좁으면 최소 1 cell은 준다 — 그 경우에도 measured 경로는 자기 예산으로 정확히 그린다.
        const cols: u16 = @intFromFloat(@min(
            @max(@floor(@as(f32, @floatFromInt(content.w)) / @as(f32, @floatFromInt(cw))), 1),
            @as(f32, @floatFromInt(std.math.maxInt(u16))),
        ));
        const foreground: tokens.ColorRole = switch (rect.visual) {
            .card => |visual| paint_style.resolveCard(rect.id, visual, rect.action, self.state, self.tokens_ref).foreground,
            .button => |visual| paint_style.resolveButton(rect.id, visual, rect.action, self.state, self.tokens_ref).foreground,
            // scope는 Card, 정렬 토글은 Button이다. 그 밖의 visual로 이 함수가 불린다면 published tree가
            // 예상과 다르다는 뜻이므로, 최소한 읽히는 색으로 그리고 넘어간다.
            else => .surface_fg,
        };
        try self.emitPlaced(@floatFromInt(content.x), @floatFromInt(content.y), source, cols, .head, foreground, .control, false, false, content.w, .{ .center_in_rect = content });
    }

    fn textStyled(self: *Writer, rect: tree.RectEntry, line: u32, source: []const u8, role: tokens.ColorRole, text_role: typography.ChromeTextRole, line_count: u32, wide_icons: bool, centered: bool, bold: bool) ViewError!void {
        return self.textInsetStyled(rect, line, source, role, text_role, line_count, wide_icons, centered, 1, bold);
    }

    /// 요청된 줄을 고르기 전에 줄 스택 전체를 완성된 rect 안에 배치한다. 그래야 scope/search/group
    /// label이 폰트별 픽셀 보정 없이도 시각적으로 가운데 정렬된다.
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
    /// 계약(docs/agent-session-list-layout.md §2.1.1)을 이 아이콘만 지키지 않고 legacy cell 경로(`wide_icons`)에
    /// 남아 있었다. 그 경로는 measured artifact를 타지 않아 어떤 clip도 닿지 않으므로, 카드가 스크롤로
    /// 목록 위를 벗어나면 chevron만 고정 chrome 위에 그려졌다. 다른 affordance(refresh·search·group
    /// chevron)와 같은 경로로 합류시켜 clip을 함께 받는다.
    fn cardDisclosure(self: *Writer, rect: tree.RectEntry, metrics: types.DockMetrics) ViewError!void {
        const extent = metrics.group_disclosure_extent;
        // 우측 inset은 카드가 이미 소유한 logical content inset이다. 예전에는 terminal cell 폭을 썼는데,
        // 그러면 터미널 폰트를 바꾸는 것만으로 chevron이 좌우로 움직여 docs/agent-session-list-layout.md §2.1.1의
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

    /// provenance는 측정된 host-SVG + label 묶음이다. 그 content rect, 형제인 refresh, 헤더 제목
    /// 예약은 모두 하나의 `DockMetrics` snapshot을 쓴다. terminal 셀은 실제 worker가 한글 label을
    /// 측정한 뒤 텍스트 잘라내기 상한으로만 쓰인다.
    fn headerProvenance(self: *Writer, rect: tree.RectEntry, source: []const u8, has_sort: bool) ViewError!void {
        const cw = self.props.cell_width_px;
        if (cw == 0) return;
        const metrics = types.DockMetrics.resolve(self.props.scale_milli);
        const utility_width = metrics.headerUtilityWidth(has_sort);
        if (rect.rect.width < @as(f32, @floatFromInt(metrics.header_content_inset_x + utility_width))) return;
        // 오른쪽에서부터: trailing inset · refresh · gap · 정렬 토글 · gap · host label.
        var from_right = metrics.header_trailing_inset + metrics.header_refresh_extent + metrics.header_utility_gap;
        if (has_sort) from_right += metrics.header_sort_extent + metrics.header_utility_gap;
        from_right += metrics.header_host_label_w;
        const x = rect.rect.x + rect.rect.width - @as(f32, @floatFromInt(from_right));
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

    /// idle과 busy refresh는 논리적으로 같은 후행 SVG 슬롯 하나를 쓴다. 그래서 terminal glyph 폭이 이
    /// 헤더 컨트롤을 provenance 묶음에서 떼어 내거나 도중에 줄이지 못한다.
    fn headerRefresh(self: *Writer, rect: tree.RectEntry, source: []const u8, role: tokens.ColorRole, wide_icon: bool) ViewError!void {
        const metrics = types.DockMetrics.resolve(self.props.scale_milli);
        if (rect.rect.width < @as(f32, @floatFromInt(metrics.header_content_inset_x + metrics.headerUtilityWidth(false)))) return;
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

    /// 검색 필드는 진짜 Chrome input이다 — SVG가 고정 광학 박스를 소유하고, 텍스트는 button이 쓰는
    /// 것과 같은 16/18/8pt content 묶음 뒤에서 시작한다. terminal 셀 아이콘 경로를 쓰면 안 된다. 그
    /// 경로는 측정된 input label과 baseline이 달랐다.
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
            return self.emit(x, y, i18n.t(.sd_search), max_cols, .head, .muted_fg, .control, false, false);
        }
        return self.emitJoined(x, y, self.props.search, self.props.search_preedit, if (show_caret) "|" else "", max_cols, if (empty) .muted_fg else .surface_fg);
    }

    /// 고정 Chrome 컴포넌트는 terminal 열을 보수적인 가로 잘라내기 예산으로만 쓸 수 있다. 세로
    /// 위계는 publish된 DockMetrics snapshot에서 와야 한다 — 아니면 terminal 확대가 안정된 카드/hit
    /// rect 안에서 텍스트를 움직인다.
    ///
    /// `trailing_reserve_px`는 이 줄이 절대 침범하면 안 되는 우측 영역(카드의 disclosure slot 등)이다.
    /// 최종 ellipsis는 worker가 measured advance로 정하지만, 그 예산에서 이 폭을 미리 빼 두지 않으면
    /// 잘린 텍스트가 우측 affordance에 그대로 맞닿는다.
    /// 카드가 이 폭에서 무엇을 남기는가. **제목이 불가침**이고, 좁아지면 이 순서로 버린다:
    /// **disclosure 예약 → 메타데이터 줄 → 요약 줄**.
    ///
    /// 제목이 카드의 신원이다 — 요약은 제목을 풀어 쓴 것이고, 메타(개수·시각·모델)는 세면 알 수 있으며,
    /// disclosure 는 카드 전체가 이미 하나의 action 이라 그 표시가 없어도 누를 수 있다.
    const CardLadder = struct {
        show_disclosure: bool,
        show_summary: bool,
        show_metadata: bool,
        trailing_reserve_px: u32,
        /// 좁은 구간에서는 카드 좌우 여백도 줄인다. 16pt 는 넉넉한 폭에서 카드를 카드답게 만드는 값인데,
        /// 폭이 100pt 남짓이면 그 여백 둘이 제목보다 넓어진다 — 그때는 여백이 장식이고 제목이 내용이다.
        inset_x: u32,
    };

    fn cardLadder(self: *Writer, rect: tree.RectEntry, m: types.DockMetrics) CardLadder {
        const cw = self.props.cell_width_px;
        const floor: f32 = 80; // 제목에게 주려는 최소 폭 — **목표이지 보장이 아니다**(탐색기와 같은 값)
        const left: f32 = @floatFromInt(m.card_inset_x + cw);
        const reserve: f32 = @floatFromInt(m.cardDisclosureReserve());
        const with_reserve = rect.rect.width - left - reserve;
        if (with_reserve >= floor) return .{
            .show_disclosure = true,
            .show_summary = true,
            .show_metadata = true,
            .trailing_reserve_px = m.cardDisclosureReserve(),
            .inset_x = m.card_inset_x,
        };
        // disclosure 를 내려놓아도 제목이 바닥에 못 미치면 아래 두 줄까지 버린다 — 그 폭에서는 세 줄이
        // 각자 `…` 하나로 끝나 카드가 잡음이 된다. 한 줄(제목)만 남기는 편이 읽힌다.
        // 여백을 줄여도 되는지 먼저 본다 — 줄여서 바닥을 넘기면 그쪽이 낫다(제목이 더 보인다).
        const tight_inset = spacing.px(.xs, effectiveScale(self.props.scale_milli));
        const bare_wide = rect.rect.width - left - @as(f32, @floatFromInt(m.card_inset_x));
        const bare_tight = rect.rect.width - @as(f32, @floatFromInt(tight_inset + cw)) - @as(f32, @floatFromInt(tight_inset));
        const use_tight = bare_wide < floor;
        const bare = if (use_tight) bare_tight else bare_wide;
        return .{
            .show_disclosure = false,
            .show_summary = bare >= floor,
            .show_metadata = bare >= floor,
            .trailing_reserve_px = if (use_tight) tight_inset else m.card_inset_x,
            .inset_x = if (use_tight) tight_inset else m.card_inset_x,
        };
    }

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

    /// 메타 줄은 `provider` 토큰과 그 뒤의 나머지 메타로 **두 번** 그린다. provider 만 색이 다르기
    /// 때문이다 — provider 는 `Provider.colorRole()`(토큰 층이 색을 소유), 나머지는 `muted_fg` 다.
    /// provider 를 값으로 받는 이유도 그것이다: label 과 색 역할을 같은 곳에서 꺼내야 둘이 어긋나지 않는다.
    fn cardMetadataAtY(self: *Writer, rect: tree.RectEntry, metrics: types.DockMetrics, provider_id: types.Provider, metadata: types.CardMetadata, inset_x: u32) ViewError!void {
        const provider = provider_id.label();
        try self.textAtY(rect, inset_x, metrics.card_metadata_y, provider, provider_id.colorRole(), .metadata, false, metrics.cardDisclosureReserve());
        const cw = self.props.cell_width_px;
        const ch = self.props.cell_height_px;
        if (cw == 0 or ch == 0) return;
        const provider_cols = plannedCols(provider, 24);
        // **셀 폭은 실제 advance 의 내림이라 열당 1px 을 더한다.** measured 텍스트는 셀에 스냅되지 않으므로
        // `cols * cell` 은 열마다 조금씩 모자라고(기본 JetBrains Mono 14pt: advance 8.4, 셀 8), 그 뒤에
        // 놓는 메타 글자가 provider 이름을 파고든다. SCM 파일 행에서는 같은 산술이 이름과 경로 꼬리를
        // 실제로 붙여 버렸다(`scm_dock/view.zig` 의 `measureBudget` 주석이 그 실측과 상한 증명을 소유).
        // 여기서는 아래 `xs` 여백 덕에 아직 겹치지 않았지만, 여백이 부족분을 가리고 있었을 뿐 산술은
        // 같은 것이라 같은 상한을 쓴다 — provider 가 길어지거나 자간이 넓은 face 가 와도 견딘다.
        const provider_width = @as(u32, provider_cols) * (cw + 1);
        // **제목과 같은 여백에서 시작한다** — 사다리가 좁은 구간에서 여백을 줄이는데(16 → 8pt) 여기만
        // 원래 값을 쓰면 메타 줄만 오른쪽으로 밀려 제목과 왼쪽 끝이 어긋난다(적대적 검증에서 잡았다:
        // 카드 폭 104~119pt 구간이 정확히 그 조합이다).
        const metadata_inset = inset_x + provider_width + spacing.px(.xs, effectiveScale(self.props.scale_milli));
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

        // 세 값의 **위계**를 색으로 준다(§3): 개수는 본문색으로 먼저 읽히고, 시각은 muted 로 물러나며,
        // 모델은 카드 좌상단 provider 라벨과 **같은 색**이라 "무엇이 돌렸는가"가 한 색으로 묶인다.
        // 구분자는 컴포넌트 소유다 — platform 이 문자열에 넣으면 빈 세그먼트가 생길 때 ` ·  · ` 처럼
        // 구분자만 남고, 그 손질을 platform·i18n 양쪽이 나눠 갖게 된다.
        //
        // **op 하나에 run 여럿**으로 낸다(`chrome.draw.Run`). 색마다 op 을 나누면 컴포넌트가 셀 격자로
        // x 를 추정해야 하는데, 실제 렌더는 비례 폰트라 구간 사이가 눈에 띄게 벌어진다(실측: 캡처에서
        // 구분자 양옆이 한 칸 넘게 떴다). run 으로 두면 platform 이 **측정된 advance** 로 잇는다.
        var segment_runs: [7]draw.Run = undefined;
        var segment_count: usize = 0;
        const ordered = [_]struct { text: []const u8, role: tokens.ColorRole }{
            .{ .text = metadata.messages, .role = .surface_fg },
            .{ .text = metadata.age, .role = .muted_fg },
            .{ .text = metadata.model, .role = provider_id.colorRole() },
            .{ .text = metadata.subagents, .role = .muted_fg },
        };
        for (ordered) |segment| {
            if (segment.text.len == 0) continue;
            if (segment_count > 0) {
                segment_runs[segment_count] = .{ .text = " · ", .role = .muted_fg };
                segment_count += 1;
            }
            segment_runs[segment_count] = .{ .text = segment.text, .role = segment.role };
            segment_count += 1;
        }
        if (segment_count == 0) return;
        try self.emitRuns(x, y, segment_runs[0..segment_count], max_cols, .metadata);
    }

    /// 한 줄 안에서 색만 바뀌는 텍스트를 **op 하나 + run 여럿**으로 낸다. `emit` 과 달리 텍스트를 여러
    /// 조각으로 실으므로, 이어 붙이는 일은 실측 advance 를 가진 platform 이 맡는다(`chrome.draw.Run`).
    fn emitRuns(self: *Writer, x: f32, y: f32, segments: []const draw.Run, cols: u16, text_role: typography.ChromeTextRole) ViewError!void {
        if (cols == 0 or segments.len == 0) return;
        if (self.op_count == self.ops.len) return error.InsufficientTextBuffer;
        if (self.run_count + segments.len > self.runs.len) return error.InsufficientRunBuffer;
        const first_run = self.run_count;
        for (segments) |segment| {
            const start = self.text_count;
            try self.appendBytes(segment.text);
            self.runs[self.run_count] = .{ .text = self.text_bytes[start..self.text_count], .role = segment.role };
            self.run_count += 1;
        }
        self.ops[self.op_count] = .{ .text = .{
            .origin = .{ .x = @intFromFloat(@floor(x)), .y = @intFromFloat(@floor(y)) },
            .runs = self.runs[first_run..self.run_count],
            .role = .muted_fg,
            .text_role = text_role,
            .max_cols = cols,
            .anchor = .head,
            .scroll_clipped = self.scroll_clipped,
            .above_scroll = self.above_scroll,
            .clip = self.active_clip,
        } };
        self.op_count += 1;
    }

    /// workspace 그룹에는 독립된 슬롯이 셋 있다 — disclosure affordance, 이름, 개수. 이를 terminal식
    /// 문자열 하나로 뭉치면 workspace 이름이 길 때 개수가 옆으로 밀려, 레퍼런스와 눈에 띄게 다르고
    /// 개수 pill이 놓일 안정된 자리도 없어진다. 완성된 tree에서 hit target은 여전히 그룹 행 하나뿐이며,
    /// pill은 paint 전용이라 경쟁하는 pointer 영역을 만들지 않는다.
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
        const pill = badge.countPill(rect.rect, .{ .inset_x = horizontal_inset, .label_cols = count_cols, .cell_width_px = cw, .scale_milli = scale, .reserved_x = icon_slot }) orelse return;
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
            .loading => i18n.t(.common_session_analyzing),
            .ready => i18n.t(.common_recent_conversation),
            .stale => i18n.t(.sd_detail_stale),
            .unavailable => i18n.t(.common_session_unavailable),
        }, .surface_fg, .body, false, 0);
        switch (expanded_props.state) {
            .ready => {
                if (expanded_props.action_record_count > 0) {
                    var count: [80]u8 = undefined;
                    const label = i18n.format(&count, i18n.t(.common_action_records), &.{.{ .d = expanded_props.action_record_count }});
                    try self.textAtY(detail, metrics.detail_inset_x, metrics.detail_record_y, label, .muted_fg, .metadata, false, 0);
                }
                for (expanded_props.turns, 0..) |turn, turn_index| {
                    const turn_y = metrics.detail_turn_y + @as(u32, @intCast(turn_index)) * metrics.detail_turn_step;
                    try self.textAtY(detail, metrics.detail_inset_x, turn_y, switch (turn.role) {
                        .user => i18n.t(.common_role_user),
                        .assistant => i18n.t(.common_role_assistant),
                    }, .muted_fg, .overline, false, 0);
                    const body_y = turn_y + typography.lineHeightPx(.overline, effectiveScale(self.props.scale_milli)) + spacing.px(.xxs, effectiveScale(self.props.scale_milli));
                    try self.textAtY(detail, metrics.detail_inset_x, body_y, turn.text, .surface_fg, .body, false, 0);
                }
            },
            .loading => try self.skeletons(detail),
            .stale => try self.textAtY(detail, metrics.detail_inset_x, metrics.detail_turn_y, i18n.t(.sd_stale_hint), .muted_fg, .body, false, 0),
            .unavailable => try self.textAtY(detail, metrics.detail_inset_x, metrics.detail_turn_y, i18n.t(.sd_unavailable_hint), .muted_fg, .body, false, 0),
        }
        try self.action(find(snapshot, build.NodeIds.resumeAction(index)) orelse return error.MissingRect, resume_icon, i18n.t(.sd_resume));
        try self.action(find(snapshot, build.NodeIds.reveal(index)) orelse return error.MissingRect, reveal_icon, i18n.t(.sd_reveal));
        if (expanded_props.focus_live_enabled)
            try self.action(find(snapshot, build.NodeIds.focusLive(index)) orelse return error.MissingRect, null, i18n.t(.common_focus_live));
    }

    /// button 텍스트는 하나의 semantic content 묶음이지, 셀 추정값이 우연히 측정 label 앞에 오는 아이콘
    /// op이 아니다. 분리된 worker가 반올림하지 않은 content rect를 받아, 실제 label advance와 등록 SVG
    /// 배치를 한 산출물에 함께 publish한다.
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

    /// 고정 폭 헤더 유틸리티 슬롯은 여전히 이 보수적인 표시-열 추정값을 쓴다. button content는
    /// 의도적으로 쓰지 않는다 — 그쪽 worker 정책은 위에서 픽셀을 받기 때문이다.
    fn plannedCols(source: []const u8, max_cols: u16) u16 {
        var plan = text_layout.plan(source, 0, max_cols, .head, isSessionDockIcon);
        while (plan.next()) |_| {}
        return plan.endCol();
    }

    fn emit(self: *Writer, x: f32, y: f32, source: []const u8, cols: u16, anchor: text_layout.Anchor, role: tokens.ColorRole, text_role: typography.ChromeTextRole, wide_icons: bool, bold: bool) ViewError!void {
        return self.emitPlaced(x, y, source, cols, anchor, role, text_role, wide_icons, bold, null, .origin);
    }

    /// 측정된 input run 하나로 두면 확정 질의·IME preedit·caret에 걸쳐 실제 system-font advance가
    /// 보존된다. 텍스트 op 셋으로 따로 내리면 같은 origin에서 다시 시작하거나, 그 사이에 terminal 셀
    /// advance 추정이 되살아난다.
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
            .above_scroll = self.above_scroll,
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
            .above_scroll = self.above_scroll,
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

    /// 첫 스캔 동안에는 보존할 완성 snapshot이 없다. 빈 archive를 완성된 결과인 척하는 대신 비활성
    /// 카드 자리표시자 셋을 그린다. 이 quad들은 의도적으로 rect tree나 action table에 들어가지 않으므로,
    /// 성급한 클릭이 stale하거나 존재하지 않는 세션 action으로 해석될 수 없다.
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
/// 고정 헤더 **아래**로만 남긴다. quad와 text는 서로 다른 레이어라, 나중에 그린 헤더 배경이 앞서
/// 그린 카드 **글자**를 덮지 못한다(Lab 캡처로 확인). 진짜 스크롤 컨테이너가 그렇듯 헤더 밑을 지나는
/// 글자 자체를 잘라 없앤다 — 밀려 나가는 동안 헤더 바닥이 올라가면 다음 헤더가 그만큼 드러난다.
fn clipBelow(rect: ?draw.Rect, min_y: i32) ?draw.Rect {
    const r = rect orelse return null;
    if (r.y >= min_y) return r;
    const trimmed = min_y - r.y;
    if (trimmed >= @as(i32, @intCast(r.h))) return .{ .x = r.x, .y = min_y, .w = r.w, .h = 0 };
    return .{ .x = r.x, .y = min_y, .w = r.w, .h = r.h - @as(u32, @intCast(trimmed)) };
}

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

// 헤더 부제는 **현재 snapshot과 scan 상태를 분리해** 말해야 한다(docs/agent-session-list.md §4).
// 예전 문구 `N개 표시 · 최근 500개`는 상한을 광고했지만, 실제로 목록을 자르는 것은 그 상한이 아니라
// read budget이라 "500개 중 N개"가 사실과 달랐다. 그리고 scanner가 `partial`을 세고 있었는데도 그 값이
// DTO에 없어 **잘렸다는 사실이 화면에 전혀 나타나지 않았다** — 사용자는 목록이 전부인 줄 알았다.
// **"제목은 마지막까지 남는다"** — 카드 사다리(파일 탐색기·소스 컨트롤과 같은 규칙).
//
// 이 사다리가 없을 때 도크 하한(폭 104pt)에서 카드가 **통째로 비었다**: chevron 하나만 남고 제목·요약·
// 메타가 전부 사라졌다(Lab 캡처 실측 2026-08-25). `textAtY` 가 예산 0 이하면 조용히 돌아가고,
// disclosure 예약(48pt)이 그 폭을 먼저 먹었기 때문이다.
fn cardLadderOps(width: u32, storage: *CardLadderStorage) ![]const draw.Op {
    const props = types.Props{
        .viewport_px = .{ .width = @floatFromInt(width), .height = 400 },
        .cell_width_px = 8,
        .cell_height_px = 16,
        .scale_milli = 1000,
        .snapshot_generation = 1,
        .displayed_count = 1,
        .items = &.{
            .{ .card = .{
                .identity = 1,
                .provider = .claude,
                .title = "Notion document root cause",
                .summary = "Check the original document",
                .metadata = .{ .messages = "94 messages", .age = "3m ago", .model = "claude-opus-5" },
            } },
        },
    };
    const frame = try build.build(props, .{
        .nodes = &storage.nodes,
        .entries = &storage.entries,
        .layout_items = &storage.items,
        .flex_scratch = &storage.flex,
        .child_rects = &storage.rects,
        .actions = &storage.actions,
    });
    const tk = fixtureTokens();
    const draws = try view(props, frame, .{}, &tk, .{
        .ops = &storage.ops,
        .runs = &storage.runs,
        .text_bytes = &storage.text_bytes,
    });
    return draws.ops;
}

const CardLadderStorage = struct {
    nodes: [64]tree.UiNode = undefined,
    entries: [64]tree.RectEntry = undefined,
    items: [64]@import("../../ui/layout.zig").Item = undefined,
    flex: [64]@import("../../ui/layout.zig").FlexScratch = undefined,
    rects: [64]@import("../../ui/layout.zig").UiRect = undefined,
    actions: [64]@import("ids.zig").Entry = undefined,
    ops: [512]draw.Op = undefined,
    runs: [512]draw.Run = undefined,
    text_bytes: [4096]u8 = undefined,
};

test "좁은 카드는 disclosure·메타·요약을 버리고 제목을 남긴다" {
    // ⑴ 넓으면 아무것도 안 버린다.
    var wide_storage: CardLadderStorage = .{};
    const wide = try cardLadderOps(480, &wide_storage);
    try std.testing.expect(originYFor(wide, "Notion") != null);
    try std.testing.expect(originYFor(wide, "Check") != null);
    try std.testing.expect(originYFor(wide, "94 messages") != null);

    // ⑵ 도크 하한 폭(104 = 도크 120 − 스크롤 거터 16)에서는 **제목만** 남는다 — 빈 카드가 아니다.
    var narrow_storage: CardLadderStorage = .{};
    const narrow = try cardLadderOps(104, &narrow_storage);
    try std.testing.expect(originYFor(narrow, "Notion") != null);
    try std.testing.expect(originYFor(narrow, "Check") == null);
    try std.testing.expect(originYFor(narrow, "94 messages") == null);
}

test "SessionDock 헤더는 잘림과 분석 중을 개수와 분리해 말한다" {
    // 기대값이 한국어 문장이다 — 이 테스트가 재는 것은 **어느 분기가 어느 문구를 내는가**이고,
    // 그 의미는 문장으로 봐야 드러난다(키 비교는 동어반복이 된다). 언어를 명시 고정해 두면 기본값이
    // 로케일을 따라가도 이 검증이 흔들리지 않는다.
    const lang_before = i18n.lang();
    defer i18n.setLang(lang_before);
    i18n.setLang(.ko);

    const Case = struct { loading: bool = false, partial: bool, refreshing: bool, want: []const u8 };
    const cases = [_]Case{
        // 완료 + 전부 훑음 → 개수만. 상한을 광고하지 않는다.
        .{ .partial = false, .refreshing = false, .want = "7개 표시" },
        // 완료 + 일부만 훑음 → 사용자가 목록을 전부로 오해하지 않게 말한다.
        .{ .partial = true, .refreshing = false, .want = "7개 표시 · 일부만 분석함" },
        // 진행 중이면 잘림 여부는 아직 확정이 아니다. 분석 중이 이긴다.
        .{ .partial = false, .refreshing = true, .want = "7개 표시 · 분석 중" },
        .{ .partial = true, .refreshing = true, .want = "7개 표시 · 분석 중" },
        // **첫 스캔**(보여 줄 record가 아직 0개)도 스캔 중임을 말해야 한다. 개수만 말하면 `0개 표시`가
        // 되어 "세션이 없다"로 읽힌다 — 첫 진입 스캔을 살리면서 실제로 이 상태가 생긴다.
        .{ .loading = true, .partial = false, .refreshing = false, .want = "0개 표시 · 분석 중" },
    };
    for (cases) |case| {
        const props = types.Props{
            .viewport_px = .{ .width = 320, .height = 480 },
            .cell_width_px = 8,
            .cell_height_px = 16,
            .snapshot_generation = 1,
            .displayed_count = if (case.loading) 0 else 7,
            .loading = case.loading,
            .partial = case.partial,
            .refreshing = case.refreshing,
            .items = &.{},
        };
        var nodes: [32]tree.UiNode = undefined;
        var entries: [32]tree.RectEntry = undefined;
        var layout_items: [32]@import("../../ui/layout.zig").Item = undefined;
        var flex_scratch: [32]@import("../../ui/layout.zig").FlexScratch = undefined;
        var child_rects: [32]@import("../../ui/layout.zig").UiRect = undefined;
        var actions: [32]@import("ids.zig").Entry = undefined;
        const frame = try build.build(props, .{
            .nodes = &nodes,
            .entries = &entries,
            .layout_items = &layout_items,
            .flex_scratch = &flex_scratch,
            .child_rects = &child_rects,
            .actions = &actions,
        });
        const tk = tokens.Tokens.rich(.{
            .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
            .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
            .foreground = .{ .r = 240, .g = 240, .b = 240 },
            .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
            .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
            .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
            .search_match = .{ .r = 1, .g = 2, .b = 3 },
            .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
            .selection = .{ .r = 7, .g = 8, .b = 9 },
            .cursor = .{ .r = 10, .g = 11, .b = 12 },
            .terminal_background = .{ .r = 10, .g = 11, .b = 12 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
            .accent = .{ .r = 13, .g = 14, .b = 15 },
        });
        var ops: [64]draw.Op = undefined;
        var runs: [64]draw.Run = undefined;
        var text_bytes: [2048]u8 = undefined;
        const out = try view(props, frame, .{}, &tk, .{ .ops = &ops, .runs = &runs, .text_bytes = &text_bytes });
        var saw = false;
        for (out.ops) |op| switch (op) {
            .text => |t| {
                for (t.runs) |run| {
                    if (std.mem.eql(u8, run.text, case.want)) saw = true;
                }
            },
            else => {},
        };
        try std.testing.expect(saw);
    }
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
            .{ .card = .{ .identity = 2, .provider = .claude, .title = "a title that intentionally exceeds a narrow card", .summary = "summary", .metadata = .{ .messages = "Claude", .age = "메시지 1개", .model = "claude-fixture" }, .selected = true } },
        },
    };
    var nodes: [32]tree.UiNode = undefined;
    var entries: [32]tree.RectEntry = undefined;
    var layout_items: [32]@import("../../ui/layout.zig").Item = undefined;
    var flex_scratch: [32]@import("../../ui/layout.zig").FlexScratch = undefined;
    var child_rects: [32]@import("../../ui/layout.zig").UiRect = undefined;
    var actions: [32]@import("ids.zig").Entry = undefined;
    const frame = try build.build(props, .{
        .nodes = &nodes,
        .entries = &entries,
        .layout_items = &layout_items,
        .flex_scratch = &flex_scratch,
        .child_rects = &child_rects,
        .actions = &actions,
    });
    const tk = tokens.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 10, .g = 11, .b = 12 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
        .accent = .{ .r = 13, .g = 14, .b = 15 },
    });
    var ops: [40]draw.Op = undefined;
    var runs: [40]draw.Run = undefined;
    var text_bytes: [1024]u8 = undefined;
    const out = try view(props, frame, .{}, &tk, .{ .ops = &ops, .runs = &runs, .text_bytes = &text_bytes });
    try std.testing.expect(out.ops.len > 8);
    var saw_quad = false;
    var saw_provider = false;
    var workspace_origin_y: ?i32 = null;
    var project_origin_y: ?i32 = null;
    var all_origin_y: ?i32 = null;
    var workspace_placement: ?draw.TextPlacement = null;
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
                if (std.mem.eql(u8, run.text, i18n.t(host_label_key))) {
                    host_label_max_cols = text.max_cols;
                    host_label_placement = text.placement;
                }
                if (std.mem.eql(u8, run.text, i18n.t(.sd_scope_workspace))) {
                    workspace_origin_y = text.origin.y;
                    workspace_placement = text.placement;
                }
                if (std.mem.eql(u8, run.text, i18n.t(.sd_scope_project))) project_origin_y = text.origin.y;
                if (std.mem.eql(u8, run.text, i18n.t(.sd_scope_all))) all_origin_y = text.origin.y;
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
    try std.testing.expect((host_label_max_cols orelse 0) > Writer.plannedCols(i18n.t(host_label_key), 16));
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
    // 세그먼트 label은 slot **가로 중앙**이기도 하다. cell 경로는 `rect.x + cell_width`로 왼쪽에 붙였고,
    // 그래서 세그먼트가 실제보다 넓고 성글게 보였다(사용자 보고). 중앙은 worker의 measured advance가 정하므로
    // 여기서는 slot 전체가 그 계산의 입력으로 실렸는지를 고정한다.
    switch (workspace_placement orelse return error.TestUnexpectedResult) {
        .center_in_rect => |content| {
            const scope = find(frame.tree, build.NodeIds.scope_workspace) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(i32, @intFromFloat(@floor(scope.rect.x))), content.x);
            try std.testing.expectEqual(@as(u32, @intFromFloat(@floor(scope.rect.width))), content.w);
            try std.testing.expectEqual(typography.lineHeightPx(.control, effectiveScale(props.scale_milli)), content.h);
        },
        else => return error.TestUnexpectedResult,
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
            .{ .card = .{ .identity = 1, .provider = .claude, .title = "partial-card-title", .summary = "visible-summary", .metadata = .{ .messages = "visible-meta" } } },
            .{ .card = .{ .identity = 2, .provider = .codex, .title = "next-card-title", .summary = "next-summary", .metadata = .{ .messages = "next-meta" } } },
        },
    };
    var nodes: [32]tree.UiNode = undefined;
    var entries: [32]tree.RectEntry = undefined;
    var layout_items: [32]@import("../../ui/layout.zig").Item = undefined;
    var flex_scratch: [32]@import("../../ui/layout.zig").FlexScratch = undefined;
    var child_rects: [32]@import("../../ui/layout.zig").UiRect = undefined;
    var actions: [32]@import("ids.zig").Entry = undefined;
    const frame = try build.build(props, .{
        .nodes = &nodes,
        .entries = &entries,
        .layout_items = &layout_items,
        .flex_scratch = &flex_scratch,
        .child_rects = &child_rects,
        .actions = &actions,
    });
    const tk = tokens.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 10, .g = 11, .b = 12 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
        .accent = .{ .r = 13, .g = 14, .b = 15 },
    });
    var ops: [40]draw.Op = undefined;
    var runs: [40]draw.Run = undefined;
    var text_bytes: [1024]u8 = undefined;
    const out = try view(props, frame, .{}, &tk, .{ .ops = &ops, .runs = &runs, .text_bytes = &text_bytes });
    var partial_title_scroll_clipped: ?bool = null;
    var next_title_scroll_clipped: ?bool = null;
    var header_scroll_clipped: ?bool = null;
    var partial_title_clip: ??draw.Rect = null;
    var header_clip: ??draw.Rect = null;
    for (out.ops) |op| switch (op) {
        .text => |text| for (text.runs) |run| {
            if (std.mem.indexOf(u8, run.text, "partial-card-title") != null) {
                partial_title_scroll_clipped = text.scroll_clipped;
                partial_title_clip = text.clip;
            }
            if (std.mem.indexOf(u8, run.text, "next-card-title") != null) next_title_scroll_clipped = text.scroll_clipped;
            if (std.mem.indexOf(u8, run.text, i18n.t(.sd_header)) != null) {
                header_scroll_clipped = text.scroll_clipped;
                header_clip = text.clip;
            }
        },
        else => {},
    };
    // 부분적으로 걸친 카드의 제목도 emit된다 — backend가 뷰포트로 자른다.
    try std.testing.expectEqual(@as(?bool, true), partial_title_scroll_clipped);
    try std.testing.expectEqual(@as(?bool, true), next_title_scroll_clipped);
    // 고정 chrome은 스크롤 대상이 아니다. 여기에 같은 표시가 붙으면 backend가 헤더까지 잘라 버린다.
    try std.testing.expectEqual(@as(?bool, false), header_scroll_clipped);

    // `scroll_clipped`는 **소속**만 말한다(캐시 키에 안전한 사실). 실제로 어디까지 보이는지는
    // `clip` rect가 나른다 — 셀 격자로 내리는 경로(Chrome Lab·모달)는 그 배선이 없어 이 값으로
    // 자르기 때문이다(draw.zig의 계약). 지금까지 판정자는 플래그만 봤고, 이 rect는 통째로 비워도
    // 단위 테스트도 골든도 통과했다.
    //
    // 계약은 "published `effective_clip`을 **그대로** 전달한다"이므로 그 tree 값과 대조한다.
    const partial_entry = frame.tree.entries[frame.tree.find(build.NodeIds.item(0)).?];
    const expected_clip = partial_entry.effective_clip orelse return error.TestUnexpectedResult;
    const actual_clip = (partial_title_clip orelse return error.TestUnexpectedResult) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i32, @intFromFloat(@ceil(expected_clip.x))), actual_clip.x);
    try std.testing.expectEqual(@as(i32, @intFromFloat(@ceil(expected_clip.y))), actual_clip.y);
    try std.testing.expectEqual(@as(u32, @intFromFloat(@max(@floor(expected_clip.width), 0))), actual_clip.w);
    try std.testing.expectEqual(@as(u32, @intFromFloat(@max(@floor(expected_clip.height), 0))), actual_clip.h);
    // 이 카드는 1px만 보이므로 clip이 카드 높이보다 훨씬 작아야 한다 — 카드 전체가 그대로 들어오면
    // 자를 것이 없다는 뜻이고 위 대조가 통과해도 무의미하다.
    try std.testing.expect(actual_clip.h < metrics.card_h);

    // 고정 chrome은 스크롤 clip을 받지 않는다. 여기에 스크롤 영역 rect가 실리면 헤더 글자가 잘린다.
    try std.testing.expectEqual(@as(??draw.Rect, @as(?draw.Rect, null)), header_clip);
}

// 사용자 보고 회귀: 목록을 스크롤하면 펼친 카드의 내용이 다른 카드 위에 겹쳐 보였다. rect tree 단언만으로는
// 부족하다 — 사용자가 보는 것은 여기서 나가는 text op의 origin이다.
//
// **한 tree 안에서의 단언은 이 결함을 못 잡는다**: 평행이동이 빠진 detail은 자기 rect도 함께 안 옮겨져
// "detail 글자는 detail rect 안"이 여전히 참이다(실제로 그 단언은 버그 코드에서도 통과했다). 그래서 같은
// 목록을 스크롤 전/후로 두 번 렌더해 **모든 run이 정확히 같은 양만큼 움직였는지**를 본다. 겹침은 곧
// "어떤 글자만 안 움직였다"이므로, 이 차분이 증상 그 자체를 고정한다.
test "SessionDock scrolling moves every emitted run by the same virtualization offset" {
    // 기대 문자열 중 하나가 보간 결과의 조각("61건")이라 **언어에 묶인다** — 영어면 "61 tool/permission
    // records"가 되어 못 찾는다. 이 테스트가 재는 것은 스크롤 오프셋이지 문구가 아니므로 언어를 고정한다.
    const lang_before = i18n.lang();
    defer i18n.setLang(lang_before);
    i18n.setLang(.ko);

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
                .metadata = .{ .messages = "expanded-meta" },
                .expanded = .{
                    .state = .ready,
                    .resume_enabled = true,
                    .reveal_enabled = true,
                    .action_record_count = 61,
                    .turns = &.{.{ .role = .user, .text = "detail-turn-text" }},
                },
            } },
            .{ .card = .{ .identity = 2, .provider = .codex, .title = "neighbour-card-title", .summary = "neighbour-summary", .metadata = .{ .messages = "neighbour-meta" } } },
        },
    };
    const tk = tokens.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 10, .g = 11, .b = 12 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
        .accent = .{ .r = 13, .g = 14, .b = 15 },
    });

    var nodes_a: [18]tree.UiNode = undefined;
    var entries_a: [22]tree.RectEntry = undefined;
    var layout_items_a: [20]@import("../../ui/layout.zig").Item = undefined;
    var flex_scratch_a: [20]@import("../../ui/layout.zig").FlexScratch = undefined;
    var child_rects_a: [20]@import("../../ui/layout.zig").UiRect = undefined;
    var actions_a: [15]@import("ids.zig").Entry = undefined;
    var ops_a: [80]draw.Op = undefined;
    var runs_a: [80]draw.Run = undefined;
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
    var nodes_b: [18]tree.UiNode = undefined;
    var entries_b: [22]tree.RectEntry = undefined;
    var layout_items_b: [20]@import("../../ui/layout.zig").Item = undefined;
    var flex_scratch_b: [20]@import("../../ui/layout.zig").FlexScratch = undefined;
    var child_rects_b: [20]@import("../../ui/layout.zig").UiRect = undefined;
    var actions_b: [15]@import("ids.zig").Entry = undefined;
    var ops_b: [80]draw.Op = undefined;
    var runs_b: [80]draw.Run = undefined;
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
        "expanded-card-title",               "expanded-summary",  "expanded-meta",
        i18n.t(.common_recent_conversation),
        "61건",
        "detail-turn-text",                  i18n.t(.sd_resume),  i18n.t(.sd_reveal),
        "neighbour-card-title",              "neighbour-summary", "neighbour-meta",
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
    inline for (.{ i18n.t(.common_recent_conversation), "61건", "detail-turn-text" }) |needle| {
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
                .metadata = .{ .messages = "expanded-meta" },
                .expanded = .{
                    .state = .ready,
                    .resume_enabled = true,
                    .reveal_enabled = true,
                    .turns = &.{.{ .role = .user, .text = "turn-text" }},
                },
            } },
            .{ .card = .{ .identity = 2, .provider = .codex, .title = "next-title", .summary = "next-summary", .metadata = .{ .messages = "next-meta" } } },
        },
    };
    var nodes: [32]tree.UiNode = undefined;
    var entries: [32]tree.RectEntry = undefined;
    var layout_items: [32]@import("../../ui/layout.zig").Item = undefined;
    var flex_scratch: [32]@import("../../ui/layout.zig").FlexScratch = undefined;
    var child_rects: [32]@import("../../ui/layout.zig").UiRect = undefined;
    var actions: [32]@import("ids.zig").Entry = undefined;
    const frame = try build.build(props, .{
        .nodes = &nodes,
        .entries = &entries,
        .layout_items = &layout_items,
        .flex_scratch = &flex_scratch,
        .child_rects = &child_rects,
        .actions = &actions,
    });
    const tk = fixtureTokens();
    var ops: [112]draw.Op = undefined;
    var runs: [112]draw.Run = undefined;
    var text_bytes: [4096]u8 = undefined;
    const out = try view(props, frame, .{}, &tk, .{ .ops = &ops, .runs = &runs, .text_bytes = &text_bytes });
    var resume_label: ?draw.TextPlacement = null;
    var reveal_label = false;
    for (out.ops) |op| switch (op) {
        .text => |text| for (text.runs) |run| {
            if (std.mem.eql(u8, run.text, i18n.t(.sd_resume))) resume_label = text.placement;
            reveal_label = reveal_label or std.mem.eql(u8, run.text, i18n.t(.sd_reveal));
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
            .{ .card = .{ .identity = 2, .provider = .claude, .title = "next-title", .summary = "next-summary", .metadata = .{ .messages = "next-meta" } } },
        },
    };
    var nodes: [32]tree.UiNode = undefined;
    var entries: [32]tree.RectEntry = undefined;
    var layout_items: [32]@import("../../ui/layout.zig").Item = undefined;
    var flex_scratch: [32]@import("../../ui/layout.zig").FlexScratch = undefined;
    var child_rects: [32]@import("../../ui/layout.zig").UiRect = undefined;
    var actions: [32]@import("ids.zig").Entry = undefined;
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
    var nodes: [32]tree.UiNode = undefined;
    var entries: [32]tree.RectEntry = undefined;
    var layout_items: [32]@import("../../ui/layout.zig").Item = undefined;
    var flex_scratch: [32]@import("../../ui/layout.zig").FlexScratch = undefined;
    var child_rects: [32]@import("../../ui/layout.zig").UiRect = undefined;
    var actions: [32]@import("ids.zig").Entry = undefined;
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
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 10, .g = 11, .b = 12 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
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
    var nodes: [32]tree.UiNode = undefined;
    var entries: [32]tree.RectEntry = undefined;
    var layout_items: [32]@import("../../ui/layout.zig").Item = undefined;
    var flex_scratch: [32]@import("../../ui/layout.zig").FlexScratch = undefined;
    var child_rects: [32]@import("../../ui/layout.zig").UiRect = undefined;
    var actions: [32]@import("ids.zig").Entry = undefined;
    const frame = try build.build(props, .{
        .nodes = &nodes,
        .entries = &entries,
        .layout_items = &layout_items,
        .flex_scratch = &flex_scratch,
        .child_rects = &child_rects,
        .actions = &actions,
    });
    const tk = tokens.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 28, .g = 28, .b = 28 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 82, .g = 82, .b = 82 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 10, .g = 11, .b = 12 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
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
            if (std.mem.eql(u8, run.text, i18n.t(.sd_scope_workspace))) workspace_y = text.origin.y;
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
            .metadata = .{ .messages = "metadata" },
            .expanded = .{ .state = .ready, .resume_enabled = true, .reveal_enabled = true },
        } }},
    };
    var nodes: [32]tree.UiNode = undefined;
    var entries: [32]tree.RectEntry = undefined;
    var layout_items: [32]@import("../../ui/layout.zig").Item = undefined;
    var flex_scratch: [32]@import("../../ui/layout.zig").FlexScratch = undefined;
    var child_rects: [32]@import("../../ui/layout.zig").UiRect = undefined;
    var actions: [32]@import("ids.zig").Entry = undefined;
    const frame = try build.build(props, .{
        .nodes = &nodes,
        .entries = &entries,
        .layout_items = &layout_items,
        .flex_scratch = &flex_scratch,
        .child_rects = &child_rects,
        .actions = &actions,
    });
    const tk = tokens.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 10, .g = 11, .b = 12 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
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
            if (std.mem.eql(u8, run.text, i18n.t(.sd_resume))) {
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
    var nodes: [32]tree.UiNode = undefined;
    var entries: [32]tree.RectEntry = undefined;
    var layout_items: [32]@import("../../ui/layout.zig").Item = undefined;
    var flex_scratch: [32]@import("../../ui/layout.zig").FlexScratch = undefined;
    var child_rects: [32]@import("../../ui/layout.zig").UiRect = undefined;
    var actions: [32]@import("ids.zig").Entry = undefined;
    const frame = try build.build(props, .{
        .nodes = &nodes,
        .entries = &entries,
        .layout_items = &layout_items,
        .flex_scratch = &flex_scratch,
        .child_rects = &child_rects,
        .actions = &actions,
    });
    const tk = tokens.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 10, .g = 11, .b = 12 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
        .accent = .{ .r = 13, .g = 14, .b = 15 },
    });
    var ops: [32]draw.Op = undefined;
    var runs: [10]draw.Run = undefined;
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
                    .metadata = .{ .messages = "메시지 4212개", .age = "방금", .model = "claude-opus-4-1-20250805 (with 1M context) (default)" },
                },
            },
        },
    };
    var nodes: [32]tree.UiNode = undefined;
    var entries: [32]tree.RectEntry = undefined;
    var layout_items: [32]@import("../../ui/layout.zig").Item = undefined;
    var flex_scratch: [32]@import("../../ui/layout.zig").FlexScratch = undefined;
    var child_rects: [32]@import("../../ui/layout.zig").UiRect = undefined;
    var actions: [32]@import("ids.zig").Entry = undefined;
    const frame = try build.build(props, .{
        .nodes = &nodes,
        .entries = &entries,
        .layout_items = &layout_items,
        .flex_scratch = &flex_scratch,
        .child_rects = &child_rects,
        .actions = &actions,
    });
    const tk = tokens.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 10, .g = 11, .b = 12 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
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
    // title·summary·provider·metadata 네 줄이 모두 검사됐다. 메타 줄은 색이 셋이지만 **op 은 하나**다
    // (run 여럿) — 그래서 이 개수는 색 위계가 생긴 뒤에도 4다. op 을 색마다 나누면 이 값이 늘고,
    // 그때는 컴포넌트가 x 를 셀 격자로 추정했다는 뜻이라 구간 사이가 벌어진다.
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
    var nodes: [32]tree.UiNode = undefined;
    var entries: [32]tree.RectEntry = undefined;
    var layout_items: [32]@import("../../ui/layout.zig").Item = undefined;
    var flex_scratch: [32]@import("../../ui/layout.zig").FlexScratch = undefined;
    var child_rects: [32]@import("../../ui/layout.zig").UiRect = undefined;
    var actions: [32]@import("ids.zig").Entry = undefined;
    const frame = try build.build(props, .{
        .nodes = &nodes,
        .entries = &entries,
        .layout_items = &layout_items,
        .flex_scratch = &flex_scratch,
        .child_rects = &child_rects,
        .actions = &actions,
    });
    const tk = tokens.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 10, .g = 11, .b = 12 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
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

// 사용자 보고 회귀(2026-08-11): 펼친 카드를 스크롤로 목록 위까지 올리면 그 카드 배경이 고정 header/scope
// **위에** 통째로 그려졌다. clip은 정확히 실려 있었지만 그 값이 면적 0이었고, backend quad 규약은 폭 0을
// "클립 없음"으로 읽는다(maru_metal_shader.h) — "한 픽셀도 안 보인다"가 "전부 보인다"로 뒤집힌 것이다.
//
// **단위 테스트만으로는 이 결함을 못 잡는다**: 면적 0 clip은 tree 계약상 정상 값이고(교차가 빈 것),
// `ui.paint`의 clip 전달도 정상이었다. 뒤집힘은 그 값이 backend 규약을 만나는 자리에서만 생긴다. 그래서
// 여기서는 **컴포넌트가 내보내는 op 자체**를 본다: 면적 0 clip을 든 quad가 하나라도 남아 있으면 그것이
// 화면에서 클립 없는 quad가 된다.
test "SessionDock never emits a quad whose clip has collapsed to zero area" {
    const metrics = types.DockMetrics.resolve(1000);
    const turns = [_]types.Turn{.{ .role = .assistant, .text = "펼친 카드의 본문" }};
    const props = types.Props{
        .viewport_px = .{ .width = 640, .height = 480 },
        .cell_width_px = 8,
        .cell_height_px = 16,
        .snapshot_generation = 11,
        .displayed_count = 2,
        .expanded_identity = 1,
        // 펼친 카드(header + detail + actions)를 **통째로** 스크롤 영역 위로 밀어낸다. 사용자가 겪은
        // 상태 그대로다 — 카드는 아직 가상화 창 안이지만 화면에는 한 픽셀도 남지 않는다.
        .content_first_item_origin_y_px = -@as(i32, @intCast(metrics.card_h + metrics.expanded_detail_h + metrics.expanded_actions_h + 40)),
        .items = &.{
            .{ .card = .{
                .identity = 1,
                .provider = .claude,
                .title = "밀려 올라간 펼친 카드",
                .summary = "요약",
                .metadata = .{ .messages = "메타" },
                .expanded = .{ .state = .ready, .turns = &turns, .resume_enabled = true, .reveal_enabled = true },
            } },
            .{ .card = .{ .identity = 2, .provider = .codex, .title = "다음 카드", .summary = "요약", .metadata = .{ .messages = "메타" } } },
        },
    };
    var nodes: [32]tree.UiNode = undefined;
    var entries: [32]tree.RectEntry = undefined;
    var layout_items: [32]@import("../../ui/layout.zig").Item = undefined;
    var flex_scratch: [32]@import("../../ui/layout.zig").FlexScratch = undefined;
    var child_rects: [32]@import("../../ui/layout.zig").UiRect = undefined;
    var actions: [32]@import("ids.zig").Entry = undefined;
    const frame = try build.build(props, .{
        .nodes = &nodes,
        .entries = &entries,
        .layout_items = &layout_items,
        .flex_scratch = &flex_scratch,
        .child_rects = &child_rects,
        .actions = &actions,
    });
    const tk = tokens.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 10, .g = 11, .b = 12 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
        .accent = .{ .r = 13, .g = 14, .b = 15 },
    });
    var ops: [64]draw.Op = undefined;
    var runs: [48]draw.Run = undefined;
    var text_bytes: [2048]u8 = undefined;
    const out = try view(props, frame, .{}, &tk, .{ .ops = &ops, .runs = &runs, .text_bytes = &text_bytes });

    // 이 시나리오가 실제로 면적 0 clip을 만드는지 먼저 확인한다. 안 만든다면 아래 단언은 아무것도
    // 증명하지 못하고 조용히 통과한다(회귀를 못 잡는 테스트가 되는 흔한 실패 방식).
    const collapsed_entry = frame.tree.entries[frame.tree.find(build.NodeIds.cardHeader(0)).?];
    const collapsed_clip = collapsed_entry.effective_clip orelse return error.TestUnexpectedResult;
    try std.testing.expect(collapsed_clip.width <= 0 or collapsed_clip.height <= 0);

    // 그런 entry의 quad는 한 개도 나가면 안 된다. 나가면 화면에서 클립 없는 quad가 된다.
    const content = frame.tree.entries[frame.tree.find(build.NodeIds.content).?];
    const content_top: i32 = @intFromFloat(@floor(content.rect.y));
    for (out.ops) |op| switch (op) {
        .quad => |quad| {
            if (quad.clip) |clip| {
                try std.testing.expect(clip.w > 0);
                try std.testing.expect(clip.h > 0);
            } else {
                // clip 없는 quad는 "안 자른다"는 뜻이므로 고정 chrome만 낼 수 있다. 목록 quad가 여기
                // 섞이면 그것이 정확히 헤더 위로 새는 경로다.
                try std.testing.expect(quad.rect.y >= 0);
                try std.testing.expect(quad.rect.y < content_top + @as(i32, @intFromFloat(@floor(content.rect.height))));
            }
        },
        else => {},
    };
}

// 사용자 보고 회귀(2026-08-11): 정렬 토글의 `오래된순`이 slot 안에 들어가는데도 `…`로 잘렸다.
//
// 원인은 slot 폭이 아니라 **폭 예산이 실리는 방식**이었다. lowering은 예산을 `max_width_px orelse
// max_cols * cell_width`로 푸는데(chrome_draw_lowering.zig `textWidthBudget`), 예전 cell 경로는
// `max_width_px`를 안 실어서 예산이 `floor(available/cell_width)` cell 배수로 깎였다. 그래서 slot에
// 실제로 들어가는 글자까지 worker가 보기 전에 사라졌다.
//
// slot 폭을 키우는 것만으로는 이 결함이 안 고쳐진다(양자화는 그대로다). 그래서 여기서 고정하는 것은
// 폭이 아니라 **계약**이다: 세그먼트·토글 label은 자기 slot 폭을 `max_width_px`로 그대로 싣는다.
test "SessionDock segment and sort labels carry the exact slot width as their measured budget" {
    // 슬롯 폭 예산은 라벨 폭에서 나온다 — 언어가 바뀌면 값이 달라진다. 이 테스트가 재는 것은
    // "발행한 폭 == 잰 폭"이라는 **일치**이므로 언어를 고정해 한 벌만 본다.
    const lang_before = i18n.lang();
    defer i18n.setLang(lang_before);
    i18n.setLang(.ko);

    const props = types.Props{
        .viewport_px = .{ .width = 640, .height = 480 },
        .cell_width_px = 8,
        .cell_height_px = 16,
        .snapshot_generation = 12,
        .displayed_count = 1,
        .sort_order = .oldest_first,
        .items = &.{
            .{ .card = .{ .identity = 1, .provider = .claude, .title = "제목", .summary = "요약", .metadata = .{ .messages = "메타" } } },
        },
    };
    var nodes: [32]tree.UiNode = undefined;
    var entries: [32]tree.RectEntry = undefined;
    var layout_items: [32]@import("../../ui/layout.zig").Item = undefined;
    var flex_scratch: [32]@import("../../ui/layout.zig").FlexScratch = undefined;
    var child_rects: [32]@import("../../ui/layout.zig").UiRect = undefined;
    var actions: [32]@import("ids.zig").Entry = undefined;
    const frame = try build.build(props, .{
        .nodes = &nodes,
        .entries = &entries,
        .layout_items = &layout_items,
        .flex_scratch = &flex_scratch,
        .child_rects = &child_rects,
        .actions = &actions,
    });
    const tk = tokens.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 10, .g = 11, .b = 12 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
        .accent = .{ .r = 13, .g = 14, .b = 15 },
    });
    var ops: [48]draw.Op = undefined;
    var runs: [32]draw.Run = undefined;
    var text_bytes: [1024]u8 = undefined;
    const out = try view(props, frame, .{}, &tk, .{ .ops = &ops, .runs = &runs, .text_bytes = &text_bytes });

    const cases = [_]struct { label: []const u8, id: u64 }{
        .{ .label = i18n.t(.sd_scope_workspace), .id = build.NodeIds.scope_workspace },
        .{ .label = i18n.t(.sd_scope_project), .id = build.NodeIds.scope_project },
        .{ .label = i18n.t(.sd_scope_all), .id = build.NodeIds.scope_all },
        .{ .label = i18n.t(.sd_sort_oldest), .id = build.NodeIds.sort_toggle },
    };
    for (cases) |case| {
        const slot = find(frame.tree, case.id) orelse return error.TestUnexpectedResult;
        const slot_w: u32 = @intFromFloat(@floor(slot.rect.width));
        var seen = false;
        for (out.ops) |op| switch (op) {
            .text => |text| for (text.runs) |run| {
                if (!std.mem.eql(u8, run.text, case.label)) continue;
                seen = true;
                // 예산은 slot 폭 **그대로**다. cell 배수로 깎이면 여기서 걸린다.
                try std.testing.expectEqual(@as(?u32, slot_w), text.max_width_px);
                // 중앙 정렬의 입력도 같은 slot이어야 한다 — 둘이 갈리면 라벨이 예산과 다른 곳에 앉는다.
                switch (text.placement) {
                    .center_in_rect => |rect| try std.testing.expectEqual(slot_w, rect.w),
                    else => return error.TestUnexpectedResult,
                }
                // cell 백엔드용 상한은 보수적이어야 한다: slot을 넘기면 이웃 세그먼트를 침범한다.
                try std.testing.expect(@as(u32, text.max_cols) * props.cell_width_px <= @max(slot_w, props.cell_width_px));
            },
            else => {},
        };
        try std.testing.expect(seen);
    }
}

// 적대적 검증에서 찾은 결함(2026-08-12): 도크는 워크스페이스/프로젝트 root가 없으면 그 scope를 실제로
// **비활성으로 발행한다**(`agent_dock.zig`의 `workspace_scope_enabled`/`project_scope_enabled`). 그때
// `resolveCard`는 배경과 전경을 함께 disabled로 낮추는데 label 색만 `.surface_fg`로 박혀 있어, 배경만
// 흐려지고 글자는 활성과 똑같이 밝은 세그먼트가 됐다 — 누를 수 있어 보이는데 안 눌린다.
//
// `Writer`는 이 규율을 이미 문서화해 두었다("label 전경은 quad와 **같은 함수**에서 나와야 한다"). 지금까지
// `action()`만 그것을 지켰다. 여기서 세그먼트·토글에도 같은 계약을 고정한다.
test "SessionDock segment labels take their foreground from the same resolver as their quad" {
    const props = types.Props{
        .viewport_px = .{ .width = 640, .height = 480 },
        .cell_width_px = 8,
        .cell_height_px = 16,
        .snapshot_generation = 13,
        .displayed_count = 1,
        // 실제 도크가 내는 상태: 워크스페이스 root가 없어 그 scope만 비활성이다.
        .workspace_scope_enabled = false,
        .project_scope_enabled = true,
        .scope = .all,
        .items = &.{
            .{ .card = .{ .identity = 1, .provider = .claude, .title = "제목", .summary = "요약", .metadata = .{ .messages = "메타" } } },
        },
    };
    var nodes: [32]tree.UiNode = undefined;
    var entries: [32]tree.RectEntry = undefined;
    var layout_items: [32]@import("../../ui/layout.zig").Item = undefined;
    var flex_scratch: [32]@import("../../ui/layout.zig").FlexScratch = undefined;
    var child_rects: [32]@import("../../ui/layout.zig").UiRect = undefined;
    var actions: [32]@import("ids.zig").Entry = undefined;
    const frame = try build.build(props, .{
        .nodes = &nodes,
        .entries = &entries,
        .layout_items = &layout_items,
        .flex_scratch = &flex_scratch,
        .child_rects = &child_rects,
        .actions = &actions,
    });
    const tk = tokens.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 10, .g = 11, .b = 12 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
        .accent = .{ .r = 13, .g = 14, .b = 15 },
    });
    var ops: [48]draw.Op = undefined;
    var runs: [32]draw.Run = undefined;
    var text_bytes: [1024]u8 = undefined;
    const out = try view(props, frame, .{}, &tk, .{ .ops = &ops, .runs = &runs, .text_bytes = &text_bytes });

    var disabled_role: ?tokens.ColorRole = null;
    var enabled_role: ?tokens.ColorRole = null;
    for (out.ops) |op| switch (op) {
        .text => |text| for (text.runs) |run| {
            if (std.mem.eql(u8, run.text, i18n.t(.sd_scope_workspace))) disabled_role = text.role;
            if (std.mem.eql(u8, run.text, i18n.t(.sd_scope_project))) enabled_role = text.role;
        },
        else => {},
    };

    // 전경의 단일 출처는 quad를 칠한 resolver다. 컴포넌트가 색을 따로 고르면 여기서 갈린다.
    const scope = find(frame.tree, build.NodeIds.scope_workspace) orelse return error.TestUnexpectedResult;
    const expected = paint_style.resolveCard(scope.id, scope.visual.card, scope.action, .{}, &tk).foreground;
    try std.testing.expectEqual(@as(?tokens.ColorRole, expected), disabled_role);
    // 그리고 그 값은 활성 세그먼트와 **달라야** 한다 — 같으면 비활성이 눈에 구분되지 않는다.
    try std.testing.expect(disabled_role != enabled_role);
}

// provider 색은 "목록을 훑어서 어느 에이전트인지 가른다"는 일을 돕는 보조 신호다(tokens 주석). 그래서
// 계약은 셋이다: ⑴ provider 토큰이 **provider별로 다른 role**을 받는다 ⑵ 그 role이 나머지 메타(`muted_fg`)와
// **다르다** — 같으면 메타 줄 전체가 한 덩어리로 읽혀 색을 준 이유가 사라진다 ⑶ 색 결정은 `Provider`가
// 소유한다(컴포넌트가 literal이나 자기 매핑을 들지 않는다).
test "SessionDock 메타 줄은 세 위계를 색으로 나눈다 — 개수=본문, 시각=muted, 모델=provider" {
    const props = types.Props{
        .viewport_px = .{ .width = 640, .height = 480 },
        .cell_width_px = 8,
        .cell_height_px = 16,
        .snapshot_generation = 21,
        .displayed_count = 2,
        .scope = .all,
        .items = &.{
            .{ .card = .{ .identity = 1, .provider = .claude, .title = "클로드 카드", .summary = "요약", .metadata = .{ .messages = "메시지 6개", .age = "20시간 전", .model = "claude-opus-5" } } },
            .{ .card = .{ .identity = 2, .provider = .codex, .title = "코덱스 카드", .summary = "요약", .metadata = .{ .messages = "메시지 9개", .age = "3일 전", .model = "gpt-5.6-sol" } } },
        },
    };
    var nodes: [48]tree.UiNode = undefined;
    var entries: [48]tree.RectEntry = undefined;
    var layout_items: [48]@import("../../ui/layout.zig").Item = undefined;
    var flex_scratch: [48]@import("../../ui/layout.zig").FlexScratch = undefined;
    var child_rects: [48]@import("../../ui/layout.zig").UiRect = undefined;
    var actions: [48]@import("ids.zig").Entry = undefined;
    const frame = try build.build(props, .{
        .nodes = &nodes,
        .entries = &entries,
        .layout_items = &layout_items,
        .flex_scratch = &flex_scratch,
        .child_rects = &child_rects,
        .actions = &actions,
    });
    const tk = tokens.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 },
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 10, .g = 11, .b = 12 },
        .accent = .{ .r = 13, .g = 14, .b = 15 },
    });
    var ops: [96]draw.Op = undefined;
    var runs: [64]draw.Run = undefined;
    var text_bytes: [2048]u8 = undefined;
    const out = try view(props, frame, .{}, &tk, .{ .ops = &ops, .runs = &runs, .text_bytes = &text_bytes });

    var claude_role: ?tokens.ColorRole = null;
    var codex_role: ?tokens.ColorRole = null;
    var messages_role: ?tokens.ColorRole = null;
    var age_role: ?tokens.ColorRole = null;
    var claude_model_role: ?tokens.ColorRole = null;
    var codex_model_role: ?tokens.ColorRole = null;
    // **run 의 색을 본다.** 메타 줄은 op 하나에 run 여럿이므로(구간이 실측 advance 로 이어지도록),
    // op 의 role 만 보면 세 위계가 한 색으로 보인다 — 실제 픽셀 색은 `run.role orelse text.role` 이다.
    for (out.ops) |op| switch (op) {
        .text => |text| for (text.runs) |run| {
            const role = run.role orelse text.role;
            if (std.mem.eql(u8, run.text, types.Provider.claude.label())) claude_role = role;
            if (std.mem.eql(u8, run.text, types.Provider.codex.label())) codex_role = role;
            if (std.mem.eql(u8, run.text, "메시지 6개")) messages_role = role;
            if (std.mem.eql(u8, run.text, "20시간 전")) age_role = role;
            if (std.mem.eql(u8, run.text, "claude-opus-5")) claude_model_role = role;
            if (std.mem.eql(u8, run.text, "gpt-5.6-sol")) codex_model_role = role;
        },
        else => {},
    };

    // ⑶ 색 결정의 주인은 `Provider`다 — 이 단언이 컴포넌트가 몰래 다른 role을 고르는 것을 막는다.
    try std.testing.expectEqual(@as(?tokens.ColorRole, types.Provider.claude.colorRole()), claude_role);
    try std.testing.expectEqual(@as(?tokens.ColorRole, types.Provider.codex.colorRole()), codex_role);
    // ⑴ provider끼리 다르다.
    try std.testing.expect(claude_role != codex_role);

    // ⑵ 메타 줄의 **세 위계**: 개수가 먼저 읽히고(본문색), 시각은 물러나며(muted), 모델은 좌상단 provider
    //    라벨과 같은 색으로 묶인다. 셋이 한 색이면(옛 동작) 이 단언이 셋 중 둘에서 깨진다.
    try std.testing.expectEqual(@as(?tokens.ColorRole, .surface_fg), messages_role);
    try std.testing.expectEqual(@as(?tokens.ColorRole, .muted_fg), age_role);
    try std.testing.expectEqual(claude_role, claude_model_role);
    try std.testing.expectEqual(codex_role, codex_model_role);
    // 그리고 세 위계가 실제로 서로 다른 role 이다 — 같은 값이 우연히 셋에 배정되는 것을 막는다.
    try std.testing.expect(messages_role != age_role);
    try std.testing.expect(messages_role != claude_model_role);
    try std.testing.expect(age_role != claude_model_role);
}

// 적대적 검증에서 찾은 결함(2026-08-12): `build`의 의도는 주석에 적혀 있다 — "utility control이 제목을
// 통째로 밀어내는 폭이 실제로 존재한다. 그 구간에서는 토글보다 무엇을 보고 있는지가 먼저다."
//
// 그런데 판정이 utility 폭만 봐서 **제목 폭 0을 허용**했다. 그러면 `headerStack`의 `available_px <= 0`
// (또는 `max_cols == 0`)에 걸려 제목도 개수도 안 그려진다 — 토글은 떠 있는데 무엇을 보고 있는지가
// 사라지는, 정확히 그 주석이 막으려던 상태다. 경계값 단언은 "왜 그 값인가"를 말해 주지 않으므로
// 계약 자체를 여기서 고정한다: **토글이 발행된 모든 폭에서 제목 run이 존재한다.**
test "SessionDock never publishes the sort toggle at a width that erases the header title" {
    const heading = i18n.t(.sd_header);
    // 이 루프가 **경계를 실제로 가로지르는지** 세어 둔다. 토글이 한 번도 발행되지 않는 구간만 훑으면
    // 아래 단언이 한 번도 실행되지 않은 채 통과한다 — 회귀를 못 잡는 테스트가 되는 흔한 방식이고,
    // utility 폭이 커져 경계가 480pt 위로 올라가면 **조용히** 그렇게 된다.
    var published: u32 = 0;
    var withheld: u32 = 0;
    const heading_check_start = 120; // dock_layout.zig의 최소 도크 폭
    var width: u32 = heading_check_start;
    while (width <= 480) : (width += 1) {
        const props = types.Props{
            .viewport_px = .{ .width = @floatFromInt(width), .height = 480 },
            .cell_width_px = 8,
            .cell_height_px = 16,
            .snapshot_generation = 14,
            .displayed_count = 3,
            .items = &.{
                .{ .card = .{ .identity = 1, .provider = .claude, .title = "제목", .summary = "요약", .metadata = .{ .messages = "메타" } } },
            },
        };
        var nodes: [32]tree.UiNode = undefined;
        var entries: [32]tree.RectEntry = undefined;
        var layout_items: [32]@import("../../ui/layout.zig").Item = undefined;
        var flex_scratch: [32]@import("../../ui/layout.zig").FlexScratch = undefined;
        var child_rects: [32]@import("../../ui/layout.zig").UiRect = undefined;
        var actions: [32]@import("ids.zig").Entry = undefined;
        const frame = build.build(props, .{
            .nodes = &nodes,
            .entries = &entries,
            .layout_items = &layout_items,
            .flex_scratch = &flex_scratch,
            .child_rects = &child_rects,
            .actions = &actions,
        }) catch continue; // 이 폭에서 tree가 안 서면 토글도 없다 — 판정할 것이 없다.
        if (frame.tree.find(build.NodeIds.sort_toggle) == null) {
            withheld += 1;
            continue;
        }
        published += 1;

        const tk = tokens.Tokens.rich(.{
            .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
            .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
            .foreground = .{ .r = 240, .g = 240, .b = 240 },
            .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
            .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
            .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
            .search_match = .{ .r = 1, .g = 2, .b = 3 },
            .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
            .selection = .{ .r = 7, .g = 8, .b = 9 },
            .cursor = .{ .r = 10, .g = 11, .b = 12 },
            .terminal_background = .{ .r = 10, .g = 11, .b = 12 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
            .accent = .{ .r = 13, .g = 14, .b = 15 },
        });
        var ops: [48]draw.Op = undefined;
        var runs: [32]draw.Run = undefined;
        var text_bytes: [1024]u8 = undefined;
        const out = try view(props, frame, .{}, &tk, .{ .ops = &ops, .runs = &runs, .text_bytes = &text_bytes });

        var saw_title = false;
        for (out.ops) |op| switch (op) {
            .text => |text| for (text.runs) |run| {
                if (std.mem.eql(u8, run.text, heading)) saw_title = true;
            },
            else => {},
        };
        if (!saw_title) {
            std.debug.print("토글은 발행됐는데 제목이 사라진 도크 폭: {d}pt\n", .{width});
            return error.TestUnexpectedResult;
        }
    }
    // 위 단언이 실제로 실행됐는가. 둘 다 0이 아니어야 이 루프가 경계를 가로지른 것이다.
    try std.testing.expect(published > 0);
    try std.testing.expect(withheld > 0);
}
