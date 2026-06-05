const std = @import("std");
const terminal = @import("../terminal.zig");

pub const DrawCell = struct {
    row: u16,
    col: u16,
    codepoint: u21,
    combining: ?u21 = null,
    width: u2 = 1,
    style: terminal.Style = .{},
};

pub const DrawList = struct {
    size: terminal.Size,
    cursor: terminal.Cursor,
    dirty: ?terminal.DirtyRegion,
    cells: []DrawCell,

    pub fn deinit(self: *DrawList, allocator: std.mem.Allocator) void {
        allocator.free(self.cells);
        self.* = undefined;
    }
};

pub fn buildDrawList(
    allocator: std.mem.Allocator,
    snapshot: terminal.RenderSnapshot,
) !DrawList {
    // DrawList는 GPU 명령이 아니라 renderer backend가 공유해서 소비할 중립 계약이다.
    // 여기서 PTY나 parser를 보지 않고 snapshot만 읽어야 Metal/WebGPU backend를
    // 나중에 바꿔도 terminal core를 다시 설계하지 않아도 된다.
    var cells: std.ArrayList(DrawCell) = .empty;
    errdefer cells.deinit(allocator);

    if (snapshot.dirty) |dirty| {
        const row_count: usize = snapshot.size.rows;
        const col_count: usize = snapshot.size.cols;
        if (row_count != 0 and col_count != 0) {
            const start_row = @min(@as(usize, dirty.start_row), row_count - 1);
            const end_row = @min(@as(usize, dirty.end_row), row_count - 1);

            if (start_row <= end_row) {
                for (start_row..end_row + 1) |row| {
                    for (0..col_count) |col| {
                        const cell = snapshot.cells[index(snapshot.size, row, col)];
                        if (cell.continuation) continue;

                        try cells.append(allocator, .{
                            .row = @intCast(row),
                            .col = @intCast(col),
                            .codepoint = cell.codepoint,
                            .combining = cell.combining,
                            .width = cell.width,
                            .style = cell.style,
                        });
                    }
                }
            }
        }
    }

    return .{
        .size = snapshot.size,
        .cursor = snapshot.cursor,
        .dirty = snapshot.dirty,
        .cells = try cells.toOwnedSlice(allocator),
    };
}

fn index(size: terminal.Size, row: usize, col: usize) usize {
    return row * size.cols + col;
}

test "draw list emits drawable cells from dirty rows only" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();

    // 이 테스트는 renderer가 전체 화면을 매번 그리지 않아도 되는 첫 계약을 고정한다.
    // 현재 core의 dirty는 row 범위이므로, 한 글자만 바뀌어도 해당 row의 셀만 DrawList에 들어간다.
    core.clearDirty();
    try core.write("A");

    var draw_list = try buildDrawList(std.testing.allocator, core.snapshot());
    defer draw_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 4), draw_list.size.cols);
    try std.testing.expectEqual(@as(usize, 4), draw_list.cells.len);
    try std.testing.expectEqual(@as(u16, 0), draw_list.cells[0].row);
    try std.testing.expectEqual(@as(u16, 0), draw_list.cells[0].col);
    try std.testing.expectEqual(@as(u21, 'A'), draw_list.cells[0].codepoint);
    try std.testing.expectEqual(@as(u16, 0), draw_list.dirty.?.start_row);
    try std.testing.expectEqual(@as(u16, 0), draw_list.dirty.?.end_row);
}

test "draw list emits no cells when snapshot is clean" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 3, .rows = 1 });
    defer core.deinit();

    // clean snapshot은 "renderer가 새로 그릴 셀이 없다"는 뜻이다.
    // 이 구분이 없으면 future frame loop가 불필요한 redraw를 계속 만들 수 있다.
    core.clearDirty();

    var draw_list = try buildDrawList(std.testing.allocator, core.snapshot());
    defer draw_list.deinit(std.testing.allocator);

    try std.testing.expect(draw_list.dirty == null);
    try std.testing.expectEqual(@as(usize, 0), draw_list.cells.len);
}

test "draw list keeps wide glyph metadata and skips continuation cells" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 5, .rows = 1 });
    defer core.deinit();

    // 한글/CJK처럼 2칸을 차지하는 glyph는 하나의 draw command여야 한다.
    // continuation cell까지 그리면 backend가 같은 glyph를 두 번 그릴 수 있다.
    try core.write("A한B");

    var draw_list = try buildDrawList(std.testing.allocator, core.snapshot());
    defer draw_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), draw_list.cells.len);
    try std.testing.expectEqual(@as(u16, 1), draw_list.cells[1].col);
    try std.testing.expectEqual(@as(u21, '한'), draw_list.cells[1].codepoint);
    try std.testing.expectEqual(@as(u2, 2), draw_list.cells[1].width);
    try std.testing.expectEqual(@as(u16, 3), draw_list.cells[2].col);
    try std.testing.expectEqual(@as(u21, 'B'), draw_list.cells[2].codepoint);
}

test "draw list carries style and combining mark for font layout" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 3, .rows = 1 });
    defer core.deinit();

    // DrawList는 나중에 glyph shaping과 atlas upload의 입력이 된다. 그래서 화면에
    // 보이는 글자뿐 아니라 style과 combining mark도 같이 이동해야 한다.
    try core.write("e\u{0301}");
    core.cells[0].style = .{
        .foreground = .{ .indexed = 2 },
        .background = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } },
        .underline = true,
    };

    var draw_list = try buildDrawList(std.testing.allocator, core.snapshot());
    defer draw_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u21, 'e'), draw_list.cells[0].codepoint);
    try std.testing.expectEqual(@as(?u21, 0x0301), draw_list.cells[0].combining);
    try std.testing.expectEqual(terminal.Color{ .indexed = 2 }, draw_list.cells[0].style.foreground);
    try std.testing.expectEqual(terminal.Color{ .rgb = .{ .r = 1, .g = 2, .b = 3 } }, draw_list.cells[0].style.background);
    try std.testing.expect(draw_list.cells[0].style.underline);
}
