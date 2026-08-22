//! 파일 탐색기 트리 행의 semantic paint·text emission이다.
//!
//! `build`가 낸 행 rect 안에서 들여쓰기 가이드·chevron·종류 아이콘·라벨·상태 표시를 **로컬 좌표**로
//! 푼다. 좌표의 단일 출처는 `types.Metrics`이고 이 파일은 그 값을 더하기만 한다 — 여기서 다시 계산하면
//! 그리는 자리와 (FT2가 붙일) 누르는 자리가 갈라진다.
//!
//! 색은 값이 아니라 `ColorRole`이다. 실제 RGB는 `tokens.zig`가, 아이콘 분류는 중립
//! `chrome/file_tree_icon.zig`가 소유한다.

const std = @import("std");
const draw = @import("../../draw.zig");
const file_tree_icon = @import("../../file_tree_icon.zig");
const icons = @import("../../../icons.zig");
const tokens = @import("../../tokens.zig");
const interaction = @import("../../ui/interaction.zig");
const typography = @import("../../ui/typography.zig");
const ui_paint = @import("../../ui/paint.zig");
const ui_tree = @import("../../ui/tree.zig");
const build_mod = @import("build.zig");
const types = @import("types.zig");

/// 들여쓰기 가이드 선을 그릴 최대 depth. 깊은 트리에서 선이 행마다 수십 개가 되면 op 예산이 depth에
/// 비례해 늘어난다 — 눈으로도 그 이상은 선 묶음으로만 보여 도움이 되지 않는다.
pub const max_guide_depth: u16 = 8;

/// disclosure chevron. 등록 SVG glyph라 셀 폰트의 `>`/`v`와 달리 크기가 슬롯을 따른다.
const chevron_collapsed = icons.codepoint(.chevron_right);
const chevron_expanded = icons.codepoint(.chevron_down);

pub const Buffers = struct {
    ops: []draw.Op,
    runs: []draw.Run,
    text_bytes: []u8,
};

pub const ViewError = ui_paint.PaintError || error{ InsufficientOpBuffer, InsufficientRunBuffer, InsufficientTextBuffer };

/// 행 하나가 쓰는 op 최대 개수(가이드 선 + chevron + 아이콘 + 라벨 + 상태).
pub const max_ops_per_row: usize = @as(usize, max_guide_depth) + 4;

/// 호출자가 잡아야 할 버퍼 크기.
pub fn bufferSizes(row_count: usize) struct { ops: usize, runs: usize, text_bytes: usize } {
    // paint가 내는 밴드 quad는 행마다 최대 하나다(`build`가 선택·호버 행만 card로 낸다).
    return .{
        .ops = row_count * (max_ops_per_row + 1) + 2,
        .runs = row_count * 3 + 2,
        .text_bytes = row_count * 512 + 64,
    };
}

pub fn view(
    props: types.Props,
    frame: build_mod.Frame,
    state: interaction.InteractionState,
    tk: *const tokens.Tokens,
    buffers: Buffers,
) ViewError!draw.ChromeDraw {
    // 밴드(선택·호버)를 먼저 낸다 — chrome quad는 글자보다 **먼저** 그리는 층이라 순서가 곧 z다.
    const painted = try ui_paint.paint(frame.tree, state, tk, .pane_overlay, .{ .ops = buffers.ops });
    var w = Writer{
        .ops = buffers.ops,
        .op_count = painted.ops.len,
        .runs = buffers.runs,
        .text_bytes = buffers.text_bytes,
        .metrics = frame.metrics,
    };

    for (props.rows, 0..) |row, index| {
        const entry_index = frame.tree.find(build_mod.NodeIds.row(index)) orelse continue;
        const entry = frame.tree.entries[entry_index];
        try w.row(row, entry, props.selection_focused);
    }

    return .{ .layer = .pane_overlay, .ops = buffers.ops[0..w.op_count] };
}

const Writer = struct {
    ops: []draw.Op,
    op_count: usize,
    runs: []draw.Run,
    run_count: usize = 0,
    text_bytes: []u8,
    text_count: usize = 0,
    metrics: types.Metrics,

    fn row(self: *Writer, r: types.Row, entry: ui_tree.RectEntry, focused: bool) ViewError!void {
        const m = self.metrics;
        const rect = entry.rect;
        const clip: ?draw.Rect = if (entry.effective_clip) |c| rectOf(c) else null;
        const x0: i32 = @intFromFloat(@floor(rect.x));
        const y0: i32 = @intFromFloat(@floor(rect.y));
        const w_px: u32 = @intFromFloat(@max(@floor(rect.width), 0));

        // ── 포커스 표시자 ───────────────────────────────────────────────────────────────────
        // 선택된 행이 **키보드 포커스 안에** 있을 때만 왼쪽 끝에 accent 막대를 세운다. 면을 accent로
        // 칠하지 않는 이유는 `types.Metrics.focus_bar_w` 주석에 있다(글자 대비 role이 이 층에 없다).
        if (r.selected and focused) {
            const bar_r: u16 = @intCast(@min(m.focus_bar_w / 2, std.math.maxInt(u16)));
            try self.quad(
                .{ .x = x0, .y = y0, .w = m.focus_bar_w, .h = m.row_h },
                .accent_bar,
                .{ bar_r, 0, 0, bar_r },
                clip,
            );
        }

        // ── 들여쓰기 가이드 선 ────────────────────────────────────────────────────────────────
        // depth 축이 선으로 보여야 깊은 트리에서 부모를 눈으로 따라갈 수 있다. 선은 **자기 depth보다
        // 얕은 단**마다 하나씩이고, 행의 위아래로 이어져 세로로 연결돼 보인다.
        var level: u16 = 0;
        while (level < @min(r.depth, max_guide_depth)) : (level += 1) {
            const gx = x0 + @as(i32, @intCast(m.row_pad_x +| (m.indent_w *| level) +| m.chevron_extent / 2));
            try self.fill(.{ .x = gx, .y = y0, .w = m.guide_w, .h = m.row_h }, .divider, 0x80, clip);
        }

        // ── disclosure chevron ──────────────────────────────────────────────────────────────
        const content_x = x0 + @as(i32, @intCast(m.contentLocalX(r.depth)));
        const icon_y = y0 + @as(i32, @intCast((m.row_h -| m.icon_extent) / 2));
        if (r.expandable) {
            const cp: u21 = if (r.expanded) chevron_expanded else chevron_collapsed;
            const cy = y0 + @as(i32, @intCast((m.row_h -| m.chevron_extent) / 2));
            try self.icon(.{ .x = content_x, .y = cy, .w = m.chevron_extent, .h = m.chevron_extent }, cp, @intCast(m.chevron_extent), foregroundFor(r, .muted_fg), clip);
        }

        // ── 종류 아이콘 ─────────────────────────────────────────────────────────────────────
        const icon_x = content_x + @as(i32, @intCast(m.chevron_extent +| m.chevron_gap));
        if (file_tree_icon.codepointFromRaw(r.icon_kind)) |cp| {
            // 아이콘 종류색은 **선택·무시 행에서 죽는다.** 선택은 accent 위 대비색을 따라야 읽히고,
            // 무시된 행은 통째로 물러나야 한다 — 거기만 색이 살아 있으면 오히려 더 눈에 띈다.
            const role: tokens.ColorRole = if (r.selected or r.ignored)
                foregroundFor(r, .surface_fg)
            else
                file_tree_icon.colorRole(@enumFromInt(r.icon_kind)) orelse foregroundFor(r, .surface_fg);
            try self.icon(.{ .x = icon_x, .y = icon_y, .w = m.icon_extent, .h = m.icon_extent }, cp, @intCast(m.icon_extent), role, clip);
        }

        // ── 라벨 ────────────────────────────────────────────────────────────────────────────
        const has_state = r.dirty or r.external_change;
        const label_w = m.labelWidthPx(w_px, r.depth, has_state);
        if (label_w > 0 and r.label.len > 0) {
            const label_x = x0 + @as(i32, @intCast(m.labelLocalX(r.depth)));
            const label_y = y0 + @as(i32, @intCast((m.row_h -| m.label_line_h) / 2));
            try self.text(label_x, label_y, r.label, labelRole(r), label_w, isEmphasized(r), clip);
        }

        // ── 상태 표시 ───────────────────────────────────────────────────────────────────────
        // dirty는 **점**이다. 글리프가 아니라 quad라 폰트에 따라 크기·자리가 흔들리지 않는다.
        if (has_state) {
            const dot = @max(m.state_slot_w / 2, 2);
            const sx = x0 + @as(i32, @intCast(w_px -| m.row_pad_x -| m.state_slot_w +| (m.state_slot_w -| dot) / 2));
            const sy = y0 + @as(i32, @intCast((m.row_h -| dot) / 2));
            const radius: u16 = @intCast(@min(dot / 2, std.math.maxInt(u16)));
            try self.quad(.{ .x = sx, .y = sy, .w = dot, .h = dot }, if (r.external_change) .danger_fg else .accent_bar, .{ radius, radius, radius, radius }, clip);
        }
    }

    fn fill(self: *Writer, rect: draw.Rect, role: tokens.ColorRole, alpha: u8, clip: ?draw.Rect) ViewError!void {
        if (rect.w == 0 or rect.h == 0) return;
        if (self.op_count == self.ops.len) return error.InsufficientOpBuffer;
        self.ops[self.op_count] = .{ .quad = .{ .rect = rect, .fill_role = role, .alpha = alpha, .clip = clip } };
        self.op_count += 1;
    }

    fn quad(self: *Writer, rect: draw.Rect, role: tokens.ColorRole, radii: [4]u16, clip: ?draw.Rect) ViewError!void {
        if (rect.w == 0 or rect.h == 0) return;
        if (self.op_count == self.ops.len) return error.InsufficientOpBuffer;
        self.ops[self.op_count] = .{ .quad = .{ .rect = rect, .fill_role = role, .corner_radii = radii, .clip = clip } };
        self.op_count += 1;
    }

    /// 등록 SVG 아이콘. PUA 바이트를 run으로 함께 실어 아틀라스 요청의 입력 payload를 유지한다 —
    /// 빈 run은 legacy·retained 아틀라스 admission을 안정적으로 통과하지 못한다(Session Dock과 같은 규약).
    fn icon(self: *Writer, rect: draw.Rect, cp: u21, extent: u16, role: tokens.ColorRole, clip: ?draw.Rect) ViewError!void {
        var utf8: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &utf8) catch return;
        try self.emit(rect.x, rect.y, utf8[0..len], role, .control, rect.w, false, .{ .icon_in_rect = .{
            .content_rect = rect,
            .icon_codepoint = cp,
            .icon_extent_px = extent,
        } }, clip);
    }

    fn text(self: *Writer, x: i32, y: i32, value: []const u8, role: tokens.ColorRole, max_width_px: u32, bold: bool, clip: ?draw.Rect) ViewError!void {
        try self.emit(x, y, value, role, .list_row, max_width_px, bold, .origin, clip);
    }

    fn emit(
        self: *Writer,
        x: i32,
        y: i32,
        source: []const u8,
        role: tokens.ColorRole,
        text_role: typography.ChromeTextRole,
        max_width_px: u32,
        bold: bool,
        placement: draw.TextPlacement,
        clip: ?draw.Rect,
    ) ViewError!void {
        if (source.len == 0 or max_width_px == 0) return;
        if (self.op_count == self.ops.len) return error.InsufficientOpBuffer;
        if (self.run_count == self.runs.len) return error.InsufficientRunBuffer;
        if (source.len > self.text_bytes.len -| self.text_count) return error.InsufficientTextBuffer;
        const start = self.text_count;
        @memcpy(self.text_bytes[start..][0..source.len], source);
        self.text_count += source.len;
        // **원본을 그대로 넘긴다.** 여기서 미리 자르면 measured 경로가 실제 advance로 말줄임을
        // 정할 정보를 잃는다(Session Dock 주석과 같은 이유).
        self.runs[self.run_count] = .{ .text = self.text_bytes[start..self.text_count], .bold = bold };
        self.ops[self.op_count] = .{ .text = .{
            .origin = .{ .x = x, .y = y },
            .runs = self.runs[self.run_count .. self.run_count + 1],
            .role = role,
            .text_role = text_role,
            .anchor = .head,
            .max_width_px = max_width_px,
            .placement = placement,
            .clip = clip,
        } };
        self.run_count += 1;
        self.op_count += 1;
    }
};

/// 라벨 색. 무시된 행이 **가장 강한 규칙**이다 — 선택 행은 그 위를 다시 덮는다(밝은 accent 위에서
/// 흐린 색은 읽히지 않는다).
fn labelRole(r: types.Row) tokens.ColorRole {
    if (r.selected) return .surface_fg;
    if (r.ignored) return .muted_fg;
    return switch (r.kind) {
        .root, .recent_header => .surface_fg,
        .empty => .muted_fg,
        else => if (r.active) .accent_bar else .surface_fg,
    };
}

fn foregroundFor(r: types.Row, default: tokens.ColorRole) tokens.ColorRole {
    if (r.selected) return .surface_fg;
    if (r.ignored) return .muted_fg;
    return default;
}

/// root·최근 헤더·활성 파일만 굵게. 전부 굵으면 아무것도 강조되지 않는다.
fn isEmphasized(r: types.Row) bool {
    return switch (r.kind) {
        .root, .recent_header => true,
        else => r.active,
    };
}

fn rectOf(r: @import("../../ui/layout.zig").UiRect) draw.Rect {
    return .{
        .x = @intFromFloat(@floor(r.x)),
        .y = @intFromFloat(@floor(r.y)),
        .w = @intFromFloat(@max(@floor(r.width), 0)),
        .h = @intFromFloat(@max(@floor(r.height), 0)),
    };
}

// ── 테스트 ────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;
const layout = @import("../../ui/layout.zig");

fn testTokens() tokens.Tokens {
    return tokens.Tokens.rich(.{
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
}

const Harness = struct {
    nodes: [16]ui_tree.UiNode = undefined,
    entries: [16]ui_tree.RectEntry = undefined,
    items: [16]layout.Item = undefined,
    flex: [16]layout.FlexScratch = undefined,
    rects: [16]layout.UiRect = undefined,
    ops: [256]draw.Op = undefined,
    runs: [64]draw.Run = undefined,
    text_bytes: [2048]u8 = undefined,

    fn run(self: *Harness, rows: []const types.Row) !draw.ChromeDraw {
        const props = types.Props{ .viewport_px = .{ .width = 300, .height = 200 }, .rows = rows };
        const frame = try build_mod.build(props, .{
            .nodes = &self.nodes,
            .entries = &self.entries,
            .layout_items = &self.items,
            .flex_scratch = &self.flex,
            .child_rects = &self.rects,
        });
        const tk = testTokens();
        return view(props, frame, .{}, &tk, .{ .ops = &self.ops, .runs = &self.runs, .text_bytes = &self.text_bytes });
    }
};

fn countText(ops: []const draw.Op) usize {
    var n: usize = 0;
    for (ops) |op| if (op == .text) {
        n += 1;
    };
    return n;
}

fn countQuad(ops: []const draw.Op) usize {
    var n: usize = 0;
    for (ops) |op| if (op == .quad) {
        n += 1;
    };
    return n;
}

// 라벨은 **새 목록 role**로 나간다. 이 값이 `body`로 돌아가면 사용자가 요청한 크기(14pt)가 조용히
// 13pt로 되돌아가고, 화면 말고는 아무도 그것을 모른다.
test "라벨은 list_row role 로 나가고 아이콘은 control 이다" {
    var h = Harness{};
    const rows = [_]types.Row{.{ .kind = .file, .label = "build.zig", .icon_kind = 0 }};
    const painted = try h.run(&rows);
    var saw_label = false;
    for (painted.ops) |op| switch (op) {
        .text => |t| {
            if (t.placement == .origin) {
                try testing.expectEqual(typography.ChromeTextRole.list_row, t.text_role);
                saw_label = true;
            } else {
                try testing.expectEqual(typography.ChromeTextRole.control, t.text_role);
            }
        },
        else => {},
    };
    try testing.expect(saw_label);
}

// 들여쓰기 가이드 선은 **자기 depth 만큼**이고 상한에서 멈춘다. 상한이 없으면 깊은 트리에서 행마다
// 선이 수십 개가 되어 op 예산이 depth에 비례해 늘어난다.
test "가이드 선은 depth 만큼이고 상한에서 멈춘다" {
    var h = Harness{};
    const shallow = [_]types.Row{.{ .kind = .file, .label = "a", .depth = 3, .icon_kind = 0 }};
    const deep = [_]types.Row{.{ .kind = .file, .label = "a", .depth = max_guide_depth + 5, .icon_kind = 0 }};
    const a = try h.run(&shallow);
    const a_quads = countQuad(a.ops);
    var h2 = Harness{};
    const b = try h2.run(&deep);
    try testing.expectEqual(@as(usize, 3), a_quads);
    try testing.expectEqual(@as(usize, max_guide_depth), countQuad(b.ops));
}

// dirty는 **점**이다(글리프가 아니라 quad라 폰트에 흔들리지 않는다). conflict는 다른 색으로 같은 자리.
test "dirty·conflict 는 우측 슬롯의 둥근 점이고 라벨 폭을 뺀다" {
    var h = Harness{};
    const plain = [_]types.Row{.{ .kind = .file, .label = "a", .icon_kind = 0 }};
    const dirty = [_]types.Row{.{ .kind = .file, .label = "a", .icon_kind = 0, .dirty = true }};
    const p = try h.run(&plain);
    const p_quads = countQuad(p.ops);
    var h2 = Harness{};
    const d = try h2.run(&dirty);
    try testing.expectEqual(p_quads + 1, countQuad(d.ops));
    var dot: ?draw.Op.Quad = null;
    for (d.ops) |op| if (op == .quad) {
        dot = op.quad;
    };
    try testing.expect(dot != null);
    try testing.expect(dot.?.corner_radii[0] > 0); // 사각형이 아니라 점
    try testing.expectEqual(tokens.ColorRole.accent_bar, dot.?.fill_role);

    // 라벨 폭 예산이 그 슬롯을 뺀다 — 안 빼면 긴 이름이 점 위로 올라탄다.
    var label_plain: u32 = 0;
    var label_dirty: u32 = 0;
    for (p.ops) |op| if (op == .text and op.text.placement == .origin) {
        label_plain = op.text.max_width_px.?;
    };
    for (d.ops) |op| if (op == .text and op.text.placement == .origin) {
        label_dirty = op.text.max_width_px.?;
    };
    try testing.expect(label_dirty < label_plain);
}

// git이 무시하는 행은 **라벨도 아이콘도** 흐려진다. 아이콘만 종류색이 살아 있으면 오히려 더 눈에 띈다.
test "무시된 행은 라벨과 아이콘이 함께 흐려진다" {
    var h = Harness{};
    const rows = [_]types.Row{.{ .kind = .file, .label = "dist.js", .icon_kind = @intFromEnum(file_tree_icon.IconKind.js), .ignored = true }};
    const painted = try h.run(&rows);
    for (painted.ops) |op| if (op == .text) {
        try testing.expectEqual(tokens.ColorRole.muted_fg, op.text.role);
    };
}

// 선택 행은 accent 밴드 위에 놓이므로 **아이콘 종류색을 버린다** — 남기면 밝은 면에서 안 읽힌다.
test "선택 행은 종류색 대신 대비색을 따른다" {
    var h = Harness{};
    const rows = [_]types.Row{.{ .kind = .file, .label = "a.js", .icon_kind = @intFromEnum(file_tree_icon.IconKind.js), .selected = true }};
    const painted = try h.run(&rows);
    for (painted.ops) |op| if (op == .text) {
        try testing.expectEqual(tokens.ColorRole.surface_fg, op.text.role);
    };
    // 밴드가 글자보다 **먼저** 나온다 — chrome quad는 글자보다 앞 층이라 순서가 곧 z다.
    try testing.expect(painted.ops.len > 0);
    try testing.expect(painted.ops[0] == .quad);
}

// chevron은 펼침 상태로 갈리고, 접히는 행이 아니면 아예 없다.
test "chevron 은 expandable 행에만 나오고 상태로 갈린다" {
    var h = Harness{};
    const collapsed = [_]types.Row{.{ .kind = .directory, .label = "docs", .icon_kind = 0, .expandable = true }};
    const c = try h.run(&collapsed);
    var saw: ?u21 = null;
    for (c.ops) |op| if (op == .text and op.text.placement == .icon_in_rect) {
        if (saw == null) saw = op.text.placement.icon_in_rect.icon_codepoint;
    };
    try testing.expectEqual(@as(?u21, chevron_collapsed), saw);

    var h2 = Harness{};
    // `IconKind.none`(=0)은 "그릴 아이콘이 없다"라 종류 아이콘도 안 나온다 — 여기서는 실제 종류를 준다.
    const leaf = [_]types.Row{.{ .kind = .file, .label = "a", .icon_kind = @intFromEnum(file_tree_icon.IconKind.file) }};
    const l = try h2.run(&leaf);
    var icon_count: usize = 0;
    for (l.ops) |op| if (op == .text and op.text.placement == .icon_in_rect) {
        icon_count += 1;
    };
    try testing.expectEqual(@as(usize, 1), icon_count); // 종류 아이콘만
}

// 버퍼가 모자라면 **에러로 끝난다** — 조용히 덜 그리면 화면에서 행 일부가 사라진 것으로만 보인다.
test "op 버퍼가 모자라면 조용히 덜 그리지 않고 실패한다" {
    var h = Harness{};
    const rows = [_]types.Row{.{ .kind = .file, .label = "a", .depth = 4, .icon_kind = 0 }};
    const props = types.Props{ .viewport_px = .{ .width = 300, .height = 200 }, .rows = &rows };
    const frame = try build_mod.build(props, .{
        .nodes = &h.nodes,
        .entries = &h.entries,
        .layout_items = &h.items,
        .flex_scratch = &h.flex,
        .child_rects = &h.rects,
    });
    const tk = testTokens();
    var tiny: [2]draw.Op = undefined;
    try testing.expectError(error.InsufficientOpBuffer, view(props, frame, .{}, &tk, .{ .ops = &tiny, .runs = &h.runs, .text_bytes = &h.text_bytes }));
}
