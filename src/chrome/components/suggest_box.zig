//! 자동완성 목록 상자(docs/editor-surface-tooling.md §8.2g · native-editor-ui §8.2) — 낱말 첫 글자 셀 **아래**(안 들어가면 위)에 뜨는
//! 창 행 목록. 기하는 `popup_box`(호버 상자와 같은 규율), 이 모듈은 **행 배치·창(상한 10행)·선택 강조·두 열(label·detail)** 만 안다.
//! 항목은 platform 이 만든다(필터·정렬은 `session/lsp/completion`).
//!
//! 키는 여기서 가로채지 않는다 — 규칙 3(ui §8: `↑↓`/`Enter`/`Tab`/`Esc` 만 소비, 나머지는 편집기로)은 platform 의 편집기 키 경로가 든다.
//! `modalInputRole` 에는 `.not_an_overlay` 로 선다(호버 상자와 같은 자리).
//!
//! 행은 **불투명**하게 그린다(`dropdown` 팝업과 같은 이유 — 모달 raster 는 배경만 칠하면 뒤 글리프가 비친다): 행마다 surface_bg 가 아닌
//! 배경색 + 상자 폭까지 공백으로 채운 글.

const std = @import("std");
const draw = @import("../draw.zig");
const props = @import("../props.zig");
const tokens = @import("../tokens.zig");
const popup_box = @import("popup_box.zig");
const overlay_input = @import("overlay_input.zig");

pub const layer = draw.Layer.modal;

/// 창 높이 상한(행) — VS Code 기본 12 와 같은 자릿수.
pub const max_rows: u32 = 10;
/// 폭 상한(칸).
pub const max_cols: u32 = 60;
/// label 과 detail 사이 최소 간격(칸).
pub const gap_cols: u32 = 2;

pub const Row = struct {
    label: []const u8,
    detail: []const u8 = "",
    /// kind 한 글자(§8.2g-b) — label 앞 열. 공백이면 빈 칸.
    kind: u8 = ' ',
};

pub const State = struct {
    open: bool = false,
    anchor_x: i32 = 0,
    anchor_y: i32 = 0,
    anchor_h: u32 = 0,
    selected: usize = 0,
    /// 창의 첫 행 — `windowStart` 로 선택을 따른다.
    scroll: usize = 0,

    pub fn show(self: *State, x: i32, y: i32, h: u32) void {
        self.* = .{ .open = true, .anchor_x = x, .anchor_y = y, .anchor_h = h };
    }

    pub fn hide(self: *State) void {
        self.open = false;
        self.selected = 0;
        self.scroll = 0;
    }

    /// 앵커만 갱신(프레임마다 다시 잰다 — 스크롤·랩이 바뀌면 자리가 바뀐다).
    pub fn moveAnchor(self: *State, x: i32, y: i32, h: u32) void {
        self.anchor_x = x;
        self.anchor_y = y;
        self.anchor_h = h;
    }

    /// 선택 이동 — **wrap 한다**(VS Code 의 suggest 목록은 끝에서 처음으로 돈다 — `editor.suggest` 는 `loop` 기본). 창은 따라온다.
    pub fn move(self: *State, delta: i64, count: usize) void {
        if (count == 0) return;
        const n: i64 = @intCast(count);
        const cur: i64 = @intCast(@min(self.selected, count - 1));
        self.selected = @intCast(@mod(cur + delta, n));
        self.scroll = overlay_input.windowStart(count, max_rows, self.selected, self.scroll);
    }

    /// 목록이 갈아 끼워졌다 — 선택을 `sel` 로 두고 창을 다시 맞춘다.
    pub fn reset(self: *State, sel: usize, count: usize) void {
        self.selected = if (count == 0) 0 else @min(sel, count - 1);
        self.scroll = overlay_input.windowStart(count, max_rows, self.selected, 0);
    }
};

pub const Size = struct { cols: u32, rows: u32, label_cols: u32 };

/// 폭 = 좌패딩 1 + 가장 긴 label + (detail 이 있으면 간격 2 + 가장 긴 detail) + 우패딩 1, 상한 `max_cols`; 높이 = min(행 수, 10).
pub fn size(rows: []const Row) ?Size {
    if (rows.len == 0) return null;
    var label_w: u32 = 0;
    var detail_w: u32 = 0;
    for (rows) |r| {
        label_w = @max(label_w, overlay_input.displayCols(r.label));
        detail_w = @max(detail_w, overlay_input.displayCols(r.detail));
    }
    // 좌패딩 1 + kind 1 + 간격 1 + label + (간격 2 + detail) + 우패딩 1.
    const want: u64 = @as(u64, label_w) + 4 + (if (detail_w > 0) @as(u64, gap_cols + detail_w) else 0);
    return .{ .cols = @intCast(@min(want, @as(u64, max_cols))), .rows = @intCast(@min(rows.len, max_rows)), .label_cols = label_w };
}

pub fn boxRect(state: *const State, rows: []const Row, p: props.ChromeProps) ?draw.Rect {
    if (!state.open) return null;
    const sz = size(rows) orelse return null;
    const m = p.metrics;
    const cw = @max(m.cell_width_px, 1);
    const ch = @max(m.cell_height_px, 1);
    const w_wide: u64 = @as(u64, sz.cols) * @as(u64, cw);
    const h_wide: u64 = @as(u64, sz.rows) * @as(u64, ch);
    const box_w: u32 = @intCast(@min(w_wide, @as(u64, std.math.maxInt(u32))));
    const box_h: u32 = @intCast(@min(h_wide, @as(u64, std.math.maxInt(u32))));
    const placed = popup_box.place(box_w, box_h, .{
        .anchor = .{ .x = state.anchor_x, .y = state.anchor_y, .w = 0, .h = state.anchor_h },
        .vertical = .below_flip_up,
        .gap_px = p.shape.modal_padding_px,
    }, p) orelse return null;
    return .{ .x = placed.rect.x, .y = placed.rect.y, .w = box_w, .h = box_h };
}

/// 창에 보이는 행들 — `[scroll, scroll+rows)`.
pub fn visible(state: *const State, rows: []const Row) []const Row {
    const n: usize = @min(rows.len, max_rows);
    const start = @min(state.scroll, rows.len -| n);
    return rows[start .. start + n];
}

pub fn view(state: *const State, rows: []const Row, p: props.ChromeProps, _: *const tokens.Tokens, arena: std.mem.Allocator, out: *std.ArrayList(draw.Op)) !void {
    const rect = boxRect(state, rows, p) orelse return;
    const sz = size(rows) orelse return;
    const cw = @max(p.metrics.cell_width_px, 1);
    const ch = @max(p.metrics.cell_height_px, 1);
    const box_cols: u32 = rect.w / cw;
    const start = @min(state.scroll, rows.len -| sz.rows);
    for (visible(state, rows), 0..) |r, i| {
        const abs = start + i;
        const row_y = rect.y + @as(i32, @intCast(i)) * @as(i32, @intCast(ch));
        const bg_role: tokens.ColorRole = if (abs == state.selected) .tab_active_bg else .tab_hover_bg;
        try out.append(arena, .{ .fill = .{ .rect = .{ .x = rect.x, .y = row_y, .w = rect.w, .h = ch }, .role = bg_role } });
        // " " + kind + " " + label(폭 상한에서 자름) + 간격 + detail(남는 칸에 우측 정렬) + 우패딩 — 행 전체 셀에 글리프.
        var line: std.ArrayList(u8) = .empty;
        try line.append(arena, ' ');
        try line.append(arena, r.kind);
        try line.append(arena, ' ');
        const label_budget = box_cols -| 4;
        const label = (try overlay_input.truncateToCols(arena, r.label, label_budget));
        try line.appendSlice(arena, label);
        var used: u32 = 3 + overlay_input.displayCols(label);
        if (r.detail.len > 0 and box_cols > used + gap_cols + 1) {
            const room = box_cols - used - gap_cols - 1;
            const detail = try overlay_input.truncateToCols(arena, r.detail, room);
            const dcols = overlay_input.displayCols(detail);
            var pad = box_cols - used - 1 - dcols; // detail 을 우측에 붙인다
            while (pad > 0) : (pad -= 1) try line.append(arena, ' ');
            try line.appendSlice(arena, detail);
            used = box_cols - 1;
        }
        var tail: u32 = box_cols -| used;
        while (tail > 0) : (tail -= 1) try line.append(arena, ' ');
        const runs = try arena.alloc(draw.Run, 1);
        runs[0] = .{ .text = line.items };
        try out.append(arena, .{ .text = .{ .origin = .{ .x = rect.x, .y = row_y }, .runs = runs, .role = .surface_fg } });
    }
}

// ── 판정 ────────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn testProps() props.ChromeProps {
    return .{ .metrics = .{ .cell_width_px = 10, .cell_height_px = 20, .sidebar_width_px = 0, .backing_width_px = 1200, .backing_height_px = 800 } };
}

fn testTokens() tokens.Tokens {
    const Rgb = @import("../../color.zig").Rgb;
    return .{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
}

test "SGB1 크기·창 — 폭은 label+detail(상한 60), 높이는 min(행, 10), 선택이 창을 따라 굴러가고 wrap 한다 (§8.2g)" {
    var rows: [25]Row = undefined;
    for (&rows, 0..) |*r, i| r.* = .{ .label = if (i % 2 == 0) "printf" else "puts", .detail = "int" };
    const sz = size(&rows).?;
    try testing.expectEqual(@as(u32, 6 + 4 + 2 + 3), sz.cols);
    try testing.expectEqual(@as(u32, 10), sz.rows);
    var st = State{};
    st.show(100, 200, 20);
    st.reset(0, rows.len);
    try testing.expectEqual(@as(usize, 0), st.scroll);
    st.move(-1, rows.len); // wrap → 24, 창은 끝
    try testing.expectEqual(@as(usize, 24), st.selected);
    try testing.expectEqual(@as(usize, 15), st.scroll);
    st.move(1, rows.len); // wrap → 0
    try testing.expectEqual(@as(usize, 0), st.selected);
    try testing.expectEqual(@as(usize, 0), st.scroll);
    for (0..12) |_| st.move(1, rows.len);
    try testing.expectEqual(@as(usize, 12), st.selected);
    try testing.expectEqual(@as(usize, 3), st.scroll); // 12 가 창 마지막 행
    try testing.expectEqual(@as(usize, 10), visible(&st, &rows).len);
    try testing.expect(size(&.{}) == null);
    st.reset(5, 3); // 목록이 줄면 clamp
    try testing.expectEqual(@as(usize, 2), st.selected);
    st.move(1, 0); // 빈 목록은 무동작
}

test "SGB2 그리기 — 닫히면 무동작; 열리면 앵커 아래에 창 행만(선택 행은 강조 배경), 행은 폭까지 채워 불투명, detail 은 우측 (§8.2g)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = testProps();
    const tk = testTokens();
    const rows = [_]Row{ .{ .label = "add", .detail = "int" }, .{ .label = "add_x", .kind = 'f' }, .{ .label = "printf", .detail = "int (const char *, ...)" } };
    var st = State{};
    var out: std.ArrayList(draw.Op) = .empty;
    try view(&st, &rows, p, &tk, arena, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    st.show(300, 100, 20);
    st.reset(1, rows.len);
    const r = boxRect(&st, &rows, p).?;
    try testing.expect(r.y >= 120);
    try testing.expectEqual(@as(u32, 3 * 20), r.h);
    try view(&st, &rows, p, &tk, arena, &out);
    try testing.expectEqual(@as(usize, 6), out.items.len); // 행마다 fill + text
    try testing.expectEqual(tokens.ColorRole.tab_hover_bg, out.items[0].fill.role);
    try testing.expectEqual(tokens.ColorRole.tab_active_bg, out.items[2].fill.role); // 선택 행(1)
    const line0 = out.items[1].text.runs[0].text;
    try testing.expectEqual(@as(usize, r.w / 10), overlay_input.displayCols(line0)); // 폭까지 채웠다
    try testing.expect(std.mem.startsWith(u8, line0, "   add")); // 공백 · kind(없음) · 공백 · label
    try testing.expect(std.mem.endsWith(u8, line0, "int ")); // detail 우측 + 우패딩
    try testing.expect(std.mem.startsWith(u8, out.items[3].text.runs[0].text, " f add_x")); // kind 열 · `_` 는 그대로다(dropdown 과 다르다)
    // 위로 뒤집힘 — 아래에 자리가 없으면 앵커 위.
    st.moveAnchor(300, 780, 20);
    const up = boxRect(&st, &rows, p).?;
    try testing.expect(up.y + @as(i32, @intCast(up.h)) <= 780);
}
