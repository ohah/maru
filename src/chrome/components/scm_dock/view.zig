//! 완성된 소스 컨트롤 도크 rect tree의 semantic paint·텍스트 투영.
//!
//! 일반 UI painter가 카드 배경을 소유하고, 이 파일은 **컴포넌트가 소유한 글자와 호버 동작**만 더한다.
//! platform에 글리프 위치를 묻지 않으므로 backend는 계속 단방향 ChromeDraw lowerer로 남는다.

const std = @import("std");
const icons = @import("../../../icons.zig");
const draw = @import("../../draw.zig");
const tokens = @import("../../tokens.zig");
const interaction = @import("../../ui/interaction.zig");
const ui_paint = @import("../../ui/paint.zig");
const paint_style = @import("../../ui/paint_style.zig");
const text_layout = @import("../../text_layout.zig");
const tree = @import("../../ui/tree.zig");
const typography = @import("../../ui/typography.zig");
const build = @import("build.zig");
const types = @import("types.zig");

// 그룹 접힘 표시와 브랜치는 **등록된 SVG 아이콘**이다. `▸`·`⑂` 같은 텍스트 글리프는 폴백 폰트마다
// 모양·크기가 달라 chrome affordance의 광학 크기를 약속할 수 없다(Session Dock과 같은 규율).
const chevron_down_icon = icons.utf8Fit(.chevron_down, .tight);
const chevron_right_icon = icons.utf8Fit(.chevron_right, .tight);
const branch_icon = icons.utf8Fit(.git_branch, .standard);
// 행 동작은 글자 하나다 — `+`/`−`는 어떤 폰트에도 있고, 아이콘 슬롯을 하나 더 등록하지 않아도 된다.
const stage_glyph = "+";
const unstage_glyph = "−";

pub const Buffers = struct {
    ops: []draw.Op,
    runs: []draw.Run,
    text_bytes: []u8,
};

pub const ViewError = ui_paint.PaintError || error{ InsufficientRunBuffer, InsufficientTextBuffer, MissingRect };

pub fn view(
    props: types.Props,
    frame: build.Frame,
    state: interaction.InteractionState,
    tk: *const tokens.Tokens,
    /// 등폭 셀 폭(legacy cell 백엔드의 상한 계산에만 쓴다 — measured 경로는 `max_width_px`를 본다).
    cell_width_px: u32,
    buffers: Buffers,
) ViewError!draw.ChromeDraw {
    const painted = try ui_paint.paint(frame.tree, state, tk, .sidebar, .{ .ops = buffers.ops });
    var writer = Writer{
        .props = props,
        .cell_width_px = @max(cell_width_px, 1),
        .ops = buffers.ops,
        .op_count = painted.ops.len,
        .runs = buffers.runs,
        .text_bytes = buffers.text_bytes,
        .state = state,
        .tokens_ref = tk,
    };

    const m = types.DockMetrics.resolve(props.scale_milli);

    // ── 요약 줄: `+N -N`. 커밋 직전에 보는 숫자라 목록보다 위에 고정한다.
    if (frame.tree.find(build.NodeIds.summary)) |index| {
        const rect = frame.tree.entries[index];
        var buf: [48]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "+{d} -{d}", .{ props.summary.added, props.summary.removed }) catch "";
        try writer.line(rect, @floatFromInt(m.inset_x), text, .muted_fg, .supporting, false);
    }

    // ── 목록. 스크롤 영역 안이므로 backend가 "스크롤은 순수 평행이동"임을 쓸 수 있게 표시한다.
    const content_index = frame.tree.find(build.NodeIds.content) orelse return error.MissingRect;
    writer.container_clip = clipRectOf(frame.tree.entries[content_index]);
    writer.scroll_clipped = true;
    for (props.items, 0..) |item, index| {
        const row_index = frame.tree.find(build.NodeIds.item(index)) orelse continue;
        const row = frame.tree.entries[row_index];
        writer.active_clip = clipRectOf(row);
        switch (item) {
            .section => |section| try writer.sectionRow(row, section, m),
            .file => |file| try writer.fileRow(row, file, m),
            .more => |more| {
                var buf: [48]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "모두 보기 ({d}개 더)", .{more.hidden}) catch "모두 보기";
                try writer.line(row, @floatFromInt(m.inset_x + m.disclosure_extent), text, .focus_accent, .control, false);
            },
            // 안내는 상태 진술이라 강조색을 쓰지 않는다(빈 안내와 같은 톤).
            .notice => |text| try writer.line(row, @floatFromInt(m.inset_x + m.disclosure_extent), text, .muted_fg, .supporting, false),
        }
        // 호버한 행에만 동작 버튼의 글리프를 낸다. **히트 사각형은 항상 있고**(build), 보이는 것만
        // 호버를 따른다 — 사용자는 호버해야 누를 수 있으므로 이 둘이 어긋나지 않는다.
        if (frame.tree.find(build.NodeIds.itemAction(index))) |action_index| {
            const action_rect = frame.tree.entries[action_index];
            if (isHovered(state, row.id) or isHovered(state, action_rect.id)) {
                const glyph = switch (actionOf(item)) {
                    .stage => stage_glyph,
                    .unstage => unstage_glyph,
                    .none => "",
                };
                if (glyph.len > 0) try writer.centered(action_rect, glyph, .surface_fg, .control);
            }
        }
    }
    // 목록이 비었으면 그 자리에 한 줄 안내를 낸다. **빈 화면과 구별돼야 한다** — "변경 사항 없음"과
    // "읽는 중"과 "저장소가 아님"은 사용자에게 서로 다른 사실이다(§3.5 빈 상태 표).
    if (props.items.len == 0 and props.empty_notice.len > 0) {
        const content = frame.tree.entries[content_index];
        try writer.line(content, @floatFromInt(m.inset_x + m.disclosure_extent), props.empty_notice, .muted_fg, .supporting, false);
    }
    writer.scroll_clipped = false;
    writer.active_clip = null;
    writer.container_clip = null;

    // ── 브랜치 줄(목록 아래 고정). 저장소를 못 잡았으면 높이가 0이라 아무것도 그리지 않는다.
    if (props.branch.len > 0) {
        if (frame.tree.find(build.NodeIds.branch)) |index| {
            const rect = frame.tree.entries[index];
            try writer.icon(rect, @floatFromInt(m.inset_x), branch_icon, .muted_fg);
            try writer.line(rect, @floatFromInt(m.inset_x + m.disclosure_extent + m.gap), props.branch, .surface_fg, .control, true);
            if (props.has_ab) {
                var buf: [32]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "↑{d} ↓{d}", .{ props.ahead, props.behind }) catch "";
                try writer.trailing(rect, text, .muted_fg, .supporting, m.inset_x);
            }
        }
    }

    // `ChromeDraw`는 layer와 op 슬라이스만 든다 — run·text 바이트는 op이 빌려 가리키므로 호출자가
    // 준 버퍼의 수명이 곧 그 슬라이스의 수명이다(Session Dock과 같은 계약).
    return .{ .layer = painted.layer, .ops = writer.ops[0..writer.op_count] };
}

/// 그룹 제목. **컴포넌트가 소유한다** — platform이 문자열을 넘기면 같은 목록의 제목이 창마다 갈릴 수 있다.
fn sectionTitle(section: types.Section) []const u8 {
    return switch (section) {
        .staged => "스테이지된 변경",
        .changes => "변경 사항",
    };
}

fn actionOf(item: types.Item) types.RowAction {
    return switch (item) {
        .section => |section| section.action,
        .file => |file| file.action,
        .more, .notice => .none,
    };
}

fn isHovered(state: interaction.InteractionState, id: tree.UiId) bool {
    const hovered = state.hovered orelse return false;
    return hovered == id;
}

fn clipRectOf(entry: tree.RectEntry) draw.Rect {
    return .{
        .x = @intFromFloat(@floor(entry.rect.x)),
        .y = @intFromFloat(@floor(entry.rect.y)),
        .w = @intFromFloat(@floor(entry.rect.width)),
        .h = @intFromFloat(@floor(entry.rect.height)),
    };
}

/// 상태 문자의 색. **모양(글자)과 함께** 쓰는 보조 신호라 색만으로 구분하지 않는다(§3.5.2).
fn statusRole(status: types.StatusKind) tokens.ColorRole {
    return switch (status) {
        .modified => .git_modified_fg,
        .added => .git_added_fg,
        .deleted => .git_deleted_fg,
        // 충돌은 "고쳐야 하는 것"이라 삭제와 같은 위험 계열을 쓴다 — 동작이 없다는 사실은 버튼의
        // 부재가 말한다.
        .conflicted => .git_deleted_fg,
    };
}

const Writer = struct {
    props: types.Props,
    cell_width_px: u32,
    ops: []draw.Op,
    op_count: usize,
    runs: []draw.Run,
    run_count: usize = 0,
    text_bytes: []u8,
    text_count: usize = 0,
    state: interaction.InteractionState,
    tokens_ref: *const tokens.Tokens,
    scroll_clipped: bool = false,
    active_clip: ?draw.Rect = null,
    container_clip: ?draw.Rect = null,

    /// 그룹 헤더: `접힘표시 제목 · 개수`. 개수는 오른쪽 끝에 고정한다 — 제목이 길어져도 밀려 사라지지 않는다.
    fn sectionRow(self: *Writer, rect: tree.RectEntry, section: types.SectionItem, m: types.DockMetrics) ViewError!void {
        const inset: f32 = @floatFromInt(m.inset_x);
        try self.icon(rect, inset, if (section.collapsed) chevron_right_icon else chevron_down_icon, .muted_fg);
        try self.line(rect, inset + @as(f32, @floatFromInt(m.disclosure_extent + m.gap)), sectionTitle(section.section), .surface_fg, .control, true);
        var buf: [16]u8 = undefined;
        const count = std.fmt.bufPrint(&buf, "{d}", .{section.count}) catch "";
        // 개수는 동작 버튼 자리를 피해 그 왼쪽에 앉는다(호버 때 버튼이 떠도 숫자가 가리지 않는다).
        try self.trailing(rect, count, .muted_fg, .supporting, m.inset_x + m.action_extent + m.gap);
    }

    /// 파일 행: `이름 · 흐린 경로 … +N -N · 상태 문자`. 폭이 좁아지면 **경로가 먼저** 줄어든다.
    fn fileRow(self: *Writer, rect: tree.RectEntry, file: types.FileItem, m: types.DockMetrics) ViewError!void {
        const inset: f32 = @floatFromInt(m.inset_x + m.disclosure_extent + m.gap);
        // 상태 문자는 오른쪽 끝(VS Code 배치). 색은 종류가 정하고, 글자는 그대로 그린다.
        var letter_buf: [1]u8 = .{file.letter};
        try self.trailing(rect, letter_buf[0..], statusRole(file.status), .control, m.inset_x);

        var delta_buf: [32]u8 = undefined;
        const delta: []const u8 = if (file.binary)
            "bin"
        else if (file.has_delta)
            std.fmt.bufPrint(&delta_buf, "+{d} -{d}", .{ file.added, file.removed }) catch ""
        else
            "";
        if (delta.len > 0) try self.trailing(rect, delta, .muted_fg, .supporting, m.inset_x + m.status_extent + m.gap);

        // 이름은 굵게, 경로는 흐리게. 이름 뒤에 경로를 이어 그리되 폭 예산은 **이름 우선**이다.
        try self.line(rect, inset, file.name, if (file.selected) .focus_accent else .surface_fg, .control, true);
        if (file.dir.len > 0) {
            const name_px = self.measureBudget(file.name);
            try self.line(rect, inset + name_px + @as(f32, @floatFromInt(m.gap)), file.dir, .muted_fg, .supporting, false);
        }
    }

    /// 글자 하나의 대략 폭. **정확한 advance는 backend가 안다** — 여기서는 경로를 이름 뒤에 놓기 위한
    /// 보수적 추정만 하고, 겹치면 backend의 `max_width_px` 예산이 자른다.
    fn measureBudget(self: *Writer, source: []const u8) f32 {
        const cols = text_layout.displayCols(source, null);
        return @floatFromInt(cols * self.cell_width_px);
    }

    /// 행 안의 한 줄. **행 높이 안에서 세로 중앙**이다 — 목록 rect처럼 큰 상자에서 부르면 글자가
    /// 한가운데로 내려가므로, 그런 자리는 `topLine`을 쓴다.
    fn line(self: *Writer, rect: tree.RectEntry, x_offset: f32, source: []const u8, role: tokens.ColorRole, text_role: typography.ChromeTextRole, bold: bool) ViewError!void {
        const line_h: f32 = @floatFromInt(typography.lineHeightPx(text_role, effectiveScale(self.props.scale_milli)));
        if (rect.rect.height < line_h or rect.rect.width <= x_offset) return;
        const width = rect.rect.width - x_offset;
        // 큰 상자(목록 content)에서는 중앙이 아니라 위에 붙인다 — 안내가 화면 한가운데 떠 있으면
        // 목록이 있다가 사라진 것처럼 보인다.
        const y = if (rect.rect.height > line_h * 3) rect.rect.y + line_h / 2 else rect.rect.y + (rect.rect.height - line_h) / 2;
        try self.emit(
            rect.rect.x + x_offset,
            y,
            source,
            self.colsFor(width),
            role,
            text_role,
            bold,
            @intFromFloat(@max(width, 0)),
            .origin,
        );
    }

    /// 오른쪽 끝에서 `right_inset`만큼 안쪽에 놓는 글자(개수·증감·상태 문자).
    fn trailing(self: *Writer, rect: tree.RectEntry, source: []const u8, role: tokens.ColorRole, text_role: typography.ChromeTextRole, right_inset: u32) ViewError!void {
        const line_h: f32 = @floatFromInt(typography.lineHeightPx(text_role, effectiveScale(self.props.scale_milli)));
        if (rect.rect.height < line_h or rect.rect.width <= 0) return;
        const width = self.measureBudget(source);
        const x = rect.rect.x + rect.rect.width - @as(f32, @floatFromInt(right_inset)) - width;
        if (x < rect.rect.x) return;
        try self.emit(
            x,
            rect.rect.y + (rect.rect.height - line_h) / 2,
            source,
            self.colsFor(width),
            role,
            text_role,
            false,
            @intFromFloat(@max(width, 0)),
            .origin,
        );
    }

    /// rect 안에서 가로·세로 중앙에 놓는 글자(행 동작 버튼).
    fn centered(self: *Writer, rect: tree.RectEntry, source: []const u8, role: tokens.ColorRole, text_role: typography.ChromeTextRole) ViewError!void {
        const line_h = typography.lineHeightPx(text_role, effectiveScale(self.props.scale_milli));
        if (rect.rect.height < @as(f32, @floatFromInt(line_h)) or rect.rect.width <= 0) return;
        const box = draw.Rect{
            .x = @intFromFloat(@floor(rect.rect.x)),
            .y = @intFromFloat(@floor(rect.rect.y + (rect.rect.height - @as(f32, @floatFromInt(line_h))) / 2)),
            .w = @intFromFloat(@floor(rect.rect.width)),
            .h = line_h,
        };
        if (box.w == 0) return;
        // 전경은 quad를 칠한 그 함수에서 받는다 — variant만 보면 hover/press에서 배경색 글자가 배경 위에 얹힌다.
        const foreground: tokens.ColorRole = switch (rect.visual) {
            .button => |visual| paint_style.resolveButton(rect.id, visual, rect.action, self.state, self.tokens_ref).foreground,
            else => role,
        };
        try self.emitPlaced(
            @floatFromInt(box.x),
            @floatFromInt(box.y),
            source,
            self.colsFor(@floatFromInt(box.w)),
            foreground,
            text_role,
            false,
            box.w,
            .{ .center_in_rect = box },
            false,
        );
    }

    /// 등록 SVG 아이콘 하나. 셀 두 칸 슬롯을 쓰므로 `wide_icons`를 켠다.
    fn icon(self: *Writer, rect: tree.RectEntry, x_offset: f32, glyph: []const u8, role: tokens.ColorRole) ViewError!void {
        if (rect.rect.width <= x_offset) return;
        const line_h: f32 = @floatFromInt(typography.lineHeightPx(.control, effectiveScale(self.props.scale_milli)));
        try self.emitPlaced(
            rect.rect.x + x_offset,
            rect.rect.y + (rect.rect.height - line_h) / 2,
            glyph,
            2,
            role,
            .control,
            true,
            null,
            .origin,
            false,
        );
    }

    fn colsFor(self: *Writer, width_px: f32) u16 {
        const cols = @floor(width_px / @as(f32, @floatFromInt(self.cell_width_px)));
        return @intFromFloat(@min(@max(cols, 1), @as(f32, @floatFromInt(std.math.maxInt(u16)))));
    }

    fn emit(
        self: *Writer,
        x: f32,
        y: f32,
        source: []const u8,
        cols: u16,
        role: tokens.ColorRole,
        text_role: typography.ChromeTextRole,
        bold: bool,
        max_width_px: ?u32,
        placement: draw.TextPlacement,
    ) ViewError!void {
        return self.emitPlaced(x, y, source, cols, role, text_role, false, max_width_px, placement, bold);
    }

    fn emitPlaced(
        self: *Writer,
        x: f32,
        y: f32,
        source: []const u8,
        cols: u16,
        role: tokens.ColorRole,
        text_role: typography.ChromeTextRole,
        wide_icons: bool,
        max_width_px: ?u32,
        placement: draw.TextPlacement,
        bold: bool,
    ) ViewError!void {
        if (cols == 0 or source.len == 0) return;
        if (self.op_count == self.ops.len) return error.InsufficientTextBuffer;
        if (self.run_count == self.runs.len) return error.InsufficientRunBuffer;
        // 원문을 그대로 넘긴다 — 말줄임은 실제 advance를 아는 backend가 정한다(여기서 미리 자르면
        // 그 정보가 사라져 두 렌더러가 다른 글자를 그린다).
        const start = self.text_count;
        if (source.len > self.text_bytes.len -| self.text_count) return error.InsufficientTextBuffer;
        @memcpy(self.text_bytes[self.text_count..][0..source.len], source);
        self.text_count += source.len;
        self.runs[self.run_count] = .{ .text = self.text_bytes[start..self.text_count], .bold = bold };
        self.ops[self.op_count] = .{ .text = .{
            .origin = .{ .x = @intFromFloat(@floor(x)), .y = @intFromFloat(@floor(y)) },
            .runs = self.runs[self.run_count .. self.run_count + 1],
            .role = role,
            .text_role = text_role,
            .max_cols = cols,
            .anchor = .head,
            .wide_icons = wide_icons,
            .max_width_px = max_width_px,
            .placement = placement,
            .scroll_clipped = self.scroll_clipped,
            .clip = self.active_clip orelse self.container_clip,
        } };
        self.run_count += 1;
        self.op_count += 1;
    }
};

fn effectiveScale(scale_milli: u32) u32 {
    return if (scale_milli == 0) 1000 else scale_milli;
}

const testing = std.testing;

fn countTextOps(draws: draw.ChromeDraw) usize {
    var count: usize = 0;
    for (draws.ops) |op| switch (op) {
        .text => count += 1,
        else => {},
    };
    return count;
}

/// **정확히 그 글자만** 담은 text op. 부분 일치로 찾으면 요약 줄의 `+12 -3`이 행 동작의 `+`로 오인된다
/// (적대적 검증에서 이 테스트가 실제로 그렇게 통과할 뻔했다).
fn findExactText(draws: draw.ChromeDraw, needle: []const u8) ?draw.Op.Text {
    for (draws.ops) |op| switch (op) {
        .text => |text| {
            for (text.runs) |run| {
                if (std.mem.eql(u8, run.text, needle)) return text;
            }
        },
        else => {},
    };
    return null;
}

fn findText(draws: draw.ChromeDraw, needle: []const u8) ?draw.Op.Text {
    for (draws.ops) |op| switch (op) {
        .text => |text| {
            for (text.runs) |run| {
                if (std.mem.indexOf(u8, run.text, needle) != null) return text;
            }
        },
        else => {},
    };
    return null;
}

const TestStorage = struct {
    nodes: [32]tree.UiNode = undefined,
    entries: [40]tree.RectEntry = undefined,
    layout_items: [40]@import("../../ui/layout.zig").Item = undefined,
    flex_scratch: [40]@import("../../ui/layout.zig").FlexScratch = undefined,
    child_rects: [40]@import("../../ui/layout.zig").UiRect = undefined,
    actions: [40]@import("ids.zig").Entry = undefined,
    ops: [128]draw.Op = undefined,
    runs: [64]draw.Run = undefined,
    text_bytes: [2048]u8 = undefined,
};

fn testTokens() tokens.Tokens {
    return tokens.Tokens.tui(.{
        .foreground = .{ .r = 200, .g = 200, .b = 200 },
        .sidebar_background = .{ .r = 30, .g = 30, .b = 30 },
        .sidebar_foreground = .{ .r = 200, .g = 200, .b = 200 },
        .sidebar_active = .{ .r = 60, .g = 60, .b = 60 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 13, .g = 14, .b = 15 },
        .accent = .{ .r = 221, .g = 161, .b = 94 },
    });
}

fn renderFixture(storage: *TestStorage, state: interaction.InteractionState, items: []const types.Item) !draw.ChromeDraw {
    const props: types.Props = .{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 400 },
        .items = items,
        .branch = "main",
        .has_ab = true,
        .ahead = 2,
        .summary = .{ .added = 12, .removed = 3 },
    };
    const frame = try build.build(props, .{
        .nodes = &storage.nodes,
        .entries = &storage.entries,
        .layout_items = &storage.layout_items,
        .flex_scratch = &storage.flex_scratch,
        .child_rects = &storage.child_rects,
        .actions = &storage.actions,
    });
    const tk = testTokens();
    return view(props, frame, state, &tk, 8, .{
        .ops = &storage.ops,
        .runs = &storage.runs,
        .text_bytes = &storage.text_bytes,
    });
}

test "행 글자와 요약·브랜치가 한 번에 나온다" {
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .section = .{ .section = .changes, .count = 2, .collapsed = false, .action = .stage } },
        .{ .file = .{ .name = "scm_view.zig", .dir = "src/session/", .status = .modified, .letter = 'M', .added = 4, .removed = 2, .has_delta = true, .action = .stage } },
    };
    const draws = try renderFixture(&storage, .{}, &items);
    try testing.expect(findText(draws, "변경 사항") != null); // 그룹 제목
    try testing.expect(findText(draws, "scm_view.zig") != null);
    try testing.expect(findText(draws, "src/session/") != null);
    try testing.expect(findText(draws, "+4 -2") != null);
    try testing.expect(findText(draws, "+12 -3") != null); // 요약 줄
    try testing.expect(findText(draws, "main") != null); // 브랜치 줄
    try testing.expect(findText(draws, "↑2") != null);
}

test "상태 문자는 종류마다 다른 색 역할로 나온다(색만으로 구분하지 않되, 색은 다르다)" {
    var storage: TestStorage = .{};
    const items = [_]types.Item{
        .{ .file = .{ .name = "a", .dir = "", .status = .modified, .letter = 'M', .action = .stage } },
    };
    const modified = try renderFixture(&storage, .{}, &items);
    try testing.expectEqual(tokens.ColorRole.git_modified_fg, findExactText(modified, "M").?.role);

    var storage2: TestStorage = .{};
    const added_items = [_]types.Item{
        .{ .file = .{ .name = "b", .dir = "", .status = .added, .letter = 'A', .action = .stage } },
    };
    const added = try renderFixture(&storage2, .{}, &added_items);
    try testing.expectEqual(tokens.ColorRole.git_added_fg, findExactText(added, "A").?.role);

    var storage3: TestStorage = .{};
    const deleted_items = [_]types.Item{
        .{ .file = .{ .name = "c", .dir = "", .status = .deleted, .letter = 'D', .action = .stage } },
    };
    const deleted = try renderFixture(&storage3, .{}, &deleted_items);
    try testing.expectEqual(tokens.ColorRole.git_deleted_fg, findExactText(deleted, "D").?.role);
}

test "행 동작은 호버할 때만 보인다(히트 사각형은 항상 있다)" {
    const items = [_]types.Item{
        .{ .file = .{ .name = "a.zig", .dir = "", .status = .modified, .letter = 'M', .action = .stage } },
    };
    var idle_storage: TestStorage = .{};
    const idle = try renderFixture(&idle_storage, .{}, &items);
    try testing.expect(findExactText(idle, "+") == null);

    var hover_storage: TestStorage = .{};
    const hovered = try renderFixture(&hover_storage, .{ .hovered = build.NodeIds.item(0) }, &items);
    try testing.expect(findExactText(hovered, "+") != null);
}

test "언스테이지 행은 `−`를 낸다(같은 자리, 다른 방향)" {
    const items = [_]types.Item{
        .{ .file = .{ .name = "a.zig", .dir = "", .status = .modified, .letter = 'M', .action = .unstage } },
    };
    var storage: TestStorage = .{};
    const hovered = try renderFixture(&storage, .{ .hovered = build.NodeIds.item(0) }, &items);
    try testing.expect(findExactText(hovered, "−") != null);
    try testing.expect(findExactText(hovered, "+") == null);
}

test "안내 행은 강조색을 쓰지 않는다(상태 진술이지 컨트롤이 아니다)" {
    const items = [_]types.Item{
        .{ .notice = "git 출력이 너무 커서 목록이 잘렸습니다" },
    };
    var storage: TestStorage = .{};
    const draws = try renderFixture(&storage, .{}, &items);
    const text = findText(draws, "잘렸습니다") orelse return error.MissingNotice;
    try testing.expectEqual(tokens.ColorRole.muted_fg, text.role);
}

test "빈 목록은 안내 한 줄을 낸다(빈 화면과 구별한다)" {
    var storage: TestStorage = .{};
    const props: types.Props = .{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 400 },
        .items = &.{},
        .branch = "main",
        .empty_notice = "변경 사항 없음",
    };
    const frame = try build.build(props, .{
        .nodes = &storage.nodes,
        .entries = &storage.entries,
        .layout_items = &storage.layout_items,
        .flex_scratch = &storage.flex_scratch,
        .child_rects = &storage.child_rects,
        .actions = &storage.actions,
    });
    const tk = testTokens();
    const draws = try view(props, frame, .{}, &tk, 8, .{
        .ops = &storage.ops,
        .runs = &storage.runs,
        .text_bytes = &storage.text_bytes,
    });
    const text = findText(draws, "변경 사항 없음") orelse return error.MissingNotice;
    try testing.expectEqual(tokens.ColorRole.muted_fg, text.role);
    // 브랜치 줄은 그대로 남는다 — 변경이 없다는 것과 저장소를 못 잡은 것은 다르다.
    try testing.expect(findText(draws, "main") != null);
}
