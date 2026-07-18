//! 파일 패널 전역 도크의 순수 기하. 창 backing px에서 터미널·도크·divider·tab/header/content rect를 한 번에
//! 파생해 렌더·hit-test·WKWebView 전이가 같은 좌표를 소비하게 한다. AppKit/renderer/PTY 의존은 없다.

const std = @import("std");
const dock_panel = @import("dock_panel.zig");
const layout_math = @import("layout_math.zig");
const Rect = @import("split_tree.zig").Rect;

pub const default_right_pt: u32 = 420;
pub const default_bottom_pt: u32 = 300;
pub const min_right_pt: u32 = 240;
pub const min_bottom_pt: u32 = 160;
pub const default_tree_cols: u32 = 18;
pub const min_editor_cols: u32 = 12;

pub const Geometry = struct {
    terminal: Rect,
    dock: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    divider: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    tab_bar: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    header: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    tree: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    content: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    dock_size_px: u32 = 0,
};

pub const TabMetrics = struct {
    cols: u16,
    tab_cols: u16,
    tab_width: u16,
};

/// 헤더 우측의 읽기/소스 편집 토글+dirty 표시 영역. 경로는 이 rect 왼쪽까지만 그린다. 폭이 너무 좁으면
/// 최소 6칸으로 줄여도 토글 hit target은 유지한다.
pub const header_control_cols: u32 = 18;

pub fn headerControlRect(g: Geometry, cell_width_px: u32) ?Rect {
    if (cell_width_px == 0 or g.header.w < cell_width_px * 6) return null;
    const cols = @min(header_control_cols, g.header.w / cell_width_px);
    const width = cols * cell_width_px;
    return .{ .x = g.header.x + g.header.w - width, .y = g.header.y, .w = width, .h = g.header.h };
}

/// 헤더 draw-list의 external-change `!` 한 칸과 같은 rect. mode 토글의 넓은 control rect보다 먼저
/// hit-test해, 충돌 표식을 누르면 편집 모드가 바뀌는 대신 명시적 disk reload 확인으로 라우팅한다.
pub fn headerConflictRect(g: Geometry, cell_width_px: u32) ?Rect {
    if (cell_width_px == 0 or g.header.w < cell_width_px * 4) return null;
    return .{
        .x = g.header.x + g.header.w - cell_width_px * 4,
        .y = g.header.y,
        .w = cell_width_px,
        .h = g.header.h,
    };
}

pub fn tabMetrics(g: Geometry, cell_width_px: u32, entry_count: usize) ?TabMetrics {
    if (cell_width_px == 0 or entry_count == 0 or g.tab_bar.w == 0) return null;
    const cols: u16 = @intCast(@min(g.tab_bar.w / cell_width_px, @as(u32, std.math.maxInt(u16))));
    if (cols < 3) return null;
    const tab_cols = cols - 2; // 우측 2칸은 접기 버튼.
    const count: u16 = @intCast(@min(entry_count, std.math.maxInt(u16)));
    const tab_width = @max(@as(u16, 1), tab_cols / count);
    return .{ .cols = cols, .tab_cols = tab_cols, .tab_width = tab_width };
}

pub fn tabRect(g: Geometry, cell_width_px: u32, entry_count: usize, index: usize) ?Rect {
    const m = tabMetrics(g, cell_width_px, entry_count) orelse return null;
    const start = std.math.mul(u32, @intCast(index), m.tab_width) catch return null;
    if (start >= m.tab_cols) return null;
    const end = @min(start + m.tab_width, m.tab_cols);
    return .{ .x = g.tab_bar.x + start * cell_width_px, .y = g.tab_bar.y, .w = (end - start) * cell_width_px, .h = g.tab_bar.h };
}

pub fn tabIndexAt(g: Geometry, cell_width_px: u32, entry_count: usize, x_px: f64, y_px: f64) ?usize {
    if (!layout_math.pointInRect(x_px, y_px, g.tab_bar)) return null;
    const m = tabMetrics(g, cell_width_px, entry_count) orelse return null;
    const col: u32 = @intFromFloat((x_px - @as(f64, @floatFromInt(g.tab_bar.x))) / @as(f64, @floatFromInt(cell_width_px)));
    if (col >= m.tab_cols) return null;
    const index: usize = @intCast(col / m.tab_width);
    return if (index < entry_count) index else null;
}

pub fn collapseAt(g: Geometry, cell_width_px: u32, entry_count: usize, x_px: f64, y_px: f64) bool {
    if (!layout_math.pointInRect(x_px, y_px, g.tab_bar)) return false;
    const m = tabMetrics(g, cell_width_px, entry_count) orelse return false;
    const control_x = g.tab_bar.x + @as(u32, m.tab_cols) * cell_width_px;
    return x_px >= @as(f64, @floatFromInt(control_x));
}

pub const Input = struct {
    backing_width_px: u32,
    backing_height_px: u32,
    sidebar_width_px: u32,
    titlebar_height_px: u32,
    cell_width_px: u32,
    cell_height_px: u32,
    scale_milli: u32,
    divider_px: u32,
    side: dock_panel.Side,
    size_pt: u32,
    visible: bool,
};

pub fn compute(in: Input) Geometry {
    const available = Rect{
        .x = in.sidebar_width_px,
        .y = in.titlebar_height_px,
        .w = in.backing_width_px -| in.sidebar_width_px,
        .h = in.backing_height_px -| in.titlebar_height_px,
    };
    if (!in.visible or available.w == 0 or available.h == 0) return .{ .terminal = available };

    const scale = if (in.scale_milli == 0) 1000 else in.scale_milli;
    const requested_pt = if (in.size_pt != 0) in.size_pt else switch (in.side) {
        .right => default_right_pt,
        .bottom => default_bottom_pt,
    };
    const requested_px = layout_math.ptToPx(requested_pt, scale);
    const divider = @min(in.divider_px, switch (in.side) {
        .right => available.w,
        .bottom => available.h,
    });
    const chrome_h = @min(in.cell_height_px, available.h);

    return switch (in.side) {
        .right => right: {
            const min_dock = layout_math.ptToPx(min_right_pt, scale);
            const min_terminal = @max(2 * in.cell_width_px, layout_math.ptToPx(320, scale));
            const max_dock = available.w -| divider -| min_terminal;
            const dock_w = @min(@max(requested_px, @min(min_dock, max_dock)), max_dock);
            if (dock_w == 0) break :right .{ .terminal = available };
            const term_w = available.w -| divider -| dock_w;
            const dock_x = available.x + term_w + divider;
            const dock = Rect{ .x = dock_x, .y = available.y, .w = dock_w, .h = available.h };
            break :right fromDock(
                .{ .x = available.x, .y = available.y, .w = term_w, .h = available.h },
                dock,
                .{ .x = available.x + term_w, .y = available.y, .w = divider, .h = available.h },
                chrome_h,
                dock_w,
                in.cell_width_px,
            );
        },
        .bottom => bottom: {
            const min_dock = layout_math.ptToPx(min_bottom_pt, scale);
            const min_terminal = @max(2 * in.cell_height_px, layout_math.ptToPx(180, scale));
            const max_dock = available.h -| divider -| min_terminal;
            const dock_h = @min(@max(requested_px, @min(min_dock, max_dock)), max_dock);
            if (dock_h == 0) break :bottom .{ .terminal = available };
            const term_h = available.h -| divider -| dock_h;
            const dock_y = available.y + term_h + divider;
            const dock = Rect{ .x = available.x, .y = dock_y, .w = available.w, .h = dock_h };
            break :bottom fromDock(
                .{ .x = available.x, .y = available.y, .w = available.w, .h = term_h },
                dock,
                .{ .x = available.x, .y = available.y + term_h, .w = available.w, .h = divider },
                chrome_h,
                dock_h,
                in.cell_width_px,
            );
        },
    };
}

fn fromDock(terminal: Rect, dock: Rect, divider: Rect, chrome_h: u32, dock_size_px: u32, cell_width_px: u32) Geometry {
    const tab_h = @min(chrome_h, dock.h);
    const header_h = @min(chrome_h, dock.h -| tab_h);
    const body_y = dock.y + tab_h + header_h;
    const body_h = dock.h -| tab_h -| header_h;
    const max_tree_w = dock.w -| min_editor_cols * cell_width_px;
    const tree_w = @min(default_tree_cols * cell_width_px, max_tree_w);
    const content_w = dock.w -| tree_w;
    return .{
        .terminal = terminal,
        .dock = dock,
        .divider = divider,
        .tab_bar = .{ .x = dock.x, .y = dock.y, .w = dock.w, .h = tab_h },
        .header = .{ .x = dock.x, .y = dock.y + tab_h, .w = dock.w, .h = header_h },
        .tree = .{ .x = dock.x + content_w, .y = body_y, .w = tree_w, .h = body_h },
        .content = .{ .x = dock.x, .y = body_y, .w = content_w, .h = body_h },
        .dock_size_px = dock_size_px,
    };
}

pub fn sizePtForPointer(g: Geometry, side: dock_panel.Side, x_px: f64, y_px: f64, scale_milli: u32) ?u32 {
    if (!std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return null;
    const raw: f64 = switch (side) {
        .right => @as(f64, @floatFromInt(g.dock.x + g.dock.w)) - x_px,
        .bottom => @as(f64, @floatFromInt(g.dock.y + g.dock.h)) - y_px,
    };
    const px: u32 = if (raw <= 0) 0 else @intFromFloat(@min(raw, @as(f64, @floatFromInt(std.math.maxInt(u32)))));
    const scale = if (scale_milli == 0) 1000 else scale_milli;
    return @intCast((@as(u64, px) * 1000) / scale);
}

test "right and bottom dock geometry share terminal and chrome boundaries" {
    const base = Input{ .backing_width_px = 1600, .backing_height_px = 1000, .sidebar_width_px = 240, .titlebar_height_px = 40, .cell_width_px = 10, .cell_height_px = 20, .scale_milli = 2000, .divider_px = 4, .side = .right, .size_pt = 300, .visible = true };
    const right = compute(base);
    try std.testing.expectEqual(@as(u32, 600), right.dock.w);
    try std.testing.expectEqual(right.divider.x + right.divider.w, right.dock.x);
    try std.testing.expectEqual(right.tab_bar.y + right.tab_bar.h, right.header.y);
    try std.testing.expectEqual(right.header.y + right.header.h, right.content.y);
    try std.testing.expectEqual(@as(u32, 2 * 20), right.tab_bar.h + right.header.h);

    const bottom = compute(.{ .backing_width_px = base.backing_width_px, .backing_height_px = base.backing_height_px, .sidebar_width_px = base.sidebar_width_px, .titlebar_height_px = base.titlebar_height_px, .cell_width_px = base.cell_width_px, .cell_height_px = base.cell_height_px, .scale_milli = base.scale_milli, .divider_px = base.divider_px, .side = .bottom, .size_pt = 200, .visible = true });
    try std.testing.expectEqual(@as(u32, 400), bottom.dock.h);
    try std.testing.expectEqual(bottom.divider.y + bottom.divider.h, bottom.dock.y);
    try std.testing.expectEqual(base.sidebar_width_px, bottom.dock.x);
}

test "dock geometry collapses and clamps to leave a terminal floor" {
    const hidden = compute(.{ .backing_width_px = 800, .backing_height_px = 600, .sidebar_width_px = 200, .titlebar_height_px = 30, .cell_width_px = 8, .cell_height_px = 16, .scale_milli = 1000, .divider_px = 2, .side = .right, .size_pt = 700, .visible = false });
    try std.testing.expectEqual(@as(u32, 600), hidden.terminal.w);
    try std.testing.expectEqual(@as(u32, 0), hidden.dock.w);

    const clamped = compute(.{ .backing_width_px = 800, .backing_height_px = 600, .sidebar_width_px = 200, .titlebar_height_px = 30, .cell_width_px = 8, .cell_height_px = 16, .scale_milli = 1000, .divider_px = 2, .side = .right, .size_pt = 700, .visible = true });
    try std.testing.expect(clamped.terminal.w >= 320);
    try std.testing.expectEqual(clamped.terminal.w + clamped.divider.w + clamped.dock.w, hidden.terminal.w);

    const damaged = compute(.{ .backing_width_px = 800, .backing_height_px = 600, .sidebar_width_px = 200, .titlebar_height_px = 30, .cell_width_px = 8, .cell_height_px = 16, .scale_milli = 1000, .divider_px = 2, .side = .right, .size_pt = std.math.maxInt(u32), .visible = true });
    try std.testing.expect(damaged.terminal.w >= 320); // 손상 workspace의 u32 max도 overflow 없이 실효 크기로 clamp.
    try std.testing.expectEqual(damaged.terminal.w + damaged.divider.w + damaged.dock.w, hidden.terminal.w);
}

test "resize pointer maps backing pixels to persisted points and rejects non-finite" {
    const g = compute(.{ .backing_width_px = 1200, .backing_height_px = 800, .sidebar_width_px = 200, .titlebar_height_px = 40, .cell_width_px = 10, .cell_height_px = 20, .scale_milli = 2000, .divider_px = 2, .side = .right, .size_pt = 300, .visible = true });
    const expected_pt: u32 = @intCast((@as(u64, g.dock_size_px + 100) * 1000) / 2000);
    try std.testing.expectEqual(@as(?u32, expected_pt), sizePtForPointer(g, .right, @floatFromInt(g.dock.x - 100), 0, 2000));
    try std.testing.expectEqual(@as(?u32, null), sizePtForPointer(g, .right, std.math.nan(f64), 0, 2000));
}

test "dock tab metrics reserve a collapse control and share render hit rects" {
    const g = compute(.{ .backing_width_px = 1400, .backing_height_px = 900, .sidebar_width_px = 200, .titlebar_height_px = 40, .cell_width_px = 10, .cell_height_px = 20, .scale_milli = 1000, .divider_px = 2, .side = .right, .size_pt = 420, .visible = true });
    const second = tabRect(g, 10, 3, 1).?;
    try std.testing.expectEqual(@as(?usize, 1), tabIndexAt(g, 10, 3, @floatFromInt(second.x + 1), @floatFromInt(second.y + 1)));
    try std.testing.expect(collapseAt(g, 10, 3, @floatFromInt(g.tab_bar.x + g.tab_bar.w - 1), @floatFromInt(g.tab_bar.y + 1)));
}

test "dock header control rect is right-aligned and bounded on narrow docks" {
    const g = compute(.{ .backing_width_px = 1400, .backing_height_px = 900, .sidebar_width_px = 200, .titlebar_height_px = 40, .cell_width_px = 10, .cell_height_px = 20, .scale_milli = 1000, .divider_px = 2, .side = .right, .size_pt = 420, .visible = true });
    const control = headerControlRect(g, 10).?;
    try std.testing.expectEqual(g.header.x + g.header.w, control.x + control.w);
    try std.testing.expectEqual(@as(u32, header_control_cols * 10), control.w);
    const conflict = headerConflictRect(g, 10).?;
    try std.testing.expectEqual(g.header.x + g.header.w - 40, conflict.x);
    try std.testing.expectEqual(@as(u32, 10), conflict.w);
    try std.testing.expect(conflict.x >= control.x);
}
