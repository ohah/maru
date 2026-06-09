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

pub const CursorOverlay = struct {
    row: u16,
    col: u16,
    visible: bool = true,
    // DECSCUSR 모양. 렌더러가 block(반전)/underline(하단 바)/bar(좌측 세로 바)로 투영한다.
    shape: terminal.CursorShape = .block,
};

pub const UnderlineOverlay = struct {
    row: u16,
    col: u16,
    width: u2 = 1,
    color: terminal.Color = .default,
};

pub const DrawOverlay = union(enum) {
    cursor: CursorOverlay,
    underline: UnderlineOverlay,
};

pub const DrawList = struct {
    size: terminal.Size,
    cursor: terminal.Cursor,
    dirty: ?terminal.DirtyRegion,
    cells: []DrawCell,
    overlays: []DrawOverlay,

    pub fn deinit(self: *DrawList, allocator: std.mem.Allocator) void {
        allocator.free(self.cells);
        allocator.free(self.overlays);
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
    var overlays: std.ArrayList(DrawOverlay) = .empty;
    errdefer overlays.deinit(allocator);

    if (snapshot.dirty) |dirty| {
        const row_count: usize = snapshot.size.rows;
        const col_count: usize = snapshot.size.cols;
        if (row_count != 0 and col_count != 0) {
            // snapshot.cells는 size 그대로의 그리드를 담는다는 계약이다. dirty row를
            // size 기준으로 인덱싱하므로, 이 전제가 깨진 snapshot(size/cells 불일치)은
            // 조용히 엉뚱한 셀을 읽는 대신 여기서 바로 드러나야 한다.
            std.debug.assert(snapshot.cells.len >= row_count * col_count);

            const start_row = @min(@as(usize, dirty.start_row), row_count - 1);
            const end_row = @min(@as(usize, dirty.end_row), row_count - 1);

            if (start_row <= end_row) {
                // dirty row 전체를 그리므로 만들 cell 수의 상한이 정해져 있다. 미리
                // 한 번에 확보해 frame마다 append가 슬라이스를 반복 재할당하지 않게 한다.
                // continuation cell은 건너뛰므로 실제 개수는 이 상한 이하라 안전하다.
                try cells.ensureTotalCapacity(allocator, (end_row - start_row + 1) * col_count);
                // overlay도 같은 상한을 쓴다: cell마다 underline overlay가 최대 1개,
                // 루프 뒤에 cursor overlay가 최대 1개 더 붙으므로 +1이다. cells와 같은
                // 이유로 미리 확보해 per-frame 재할당을 없앤다.
                try overlays.ensureTotalCapacity(allocator, (end_row - start_row + 1) * col_count + 1);

                for (start_row..end_row + 1) |row| {
                    for (0..col_count) |col| {
                        const cell = snapshot.cells[index(snapshot.size, row, col)];
                        if (cell.continuation) continue;

                        cells.appendAssumeCapacity(.{
                            .row = @intCast(row),
                            .col = @intCast(col),
                            .codepoint = cell.codepoint,
                            .combining = cell.combining,
                            .width = cell.width,
                            .style = cell.style,
                        });

                        if (cell.style.underline) {
                            // Underline is a draw-time overlay. Keeping it
                            // outside the glyph cell command prevents the
                            // atlas from caching separate bitmaps for "A" and
                            // "underlined A".
                            overlays.appendAssumeCapacity(.{ .underline = .{
                                .row = @intCast(row),
                                .col = @intCast(col),
                                .width = cell.width,
                                .color = cell.style.foreground,
                            } });
                        }
                    }
                }
            }
        }

        if (cursorVisibleInSnapshot(snapshot) and dirtyIncludesRow(dirty, snapshot.cursor.row)) {
            // Cursor is also a draw-time overlay. TerminalCore owns the dirty
            // decision for cursor movement, so the renderer only consumes the
            // row range instead of comparing old/new snapshots itself.
            // rows/cols가 0이 아니면 위 dirty-row 블록이 반드시 실행돼 +1 자리를
            // 확보해 두므로 cursor overlay도 assumeCapacity로 붙일 수 있다.
            overlays.appendAssumeCapacity(.{ .cursor = .{
                .row = snapshot.cursor.row,
                .col = snapshot.cursor.col,
                .visible = snapshot.cursor.visible,
                .shape = snapshot.cursor_shape,
            } });
        }
    }

    return .{
        .size = snapshot.size,
        .cursor = snapshot.cursor,
        .dirty = snapshot.dirty,
        .cells = try cells.toOwnedSlice(allocator),
        .overlays = try overlays.toOwnedSlice(allocator),
    };
}

fn index(size: terminal.Size, row: usize, col: usize) usize {
    return row * size.cols + col;
}

fn cursorVisibleInSnapshot(snapshot: terminal.RenderSnapshot) bool {
    return snapshot.cursor.visible and
        snapshot.size.rows != 0 and
        snapshot.size.cols != 0 and
        snapshot.cursor.row < snapshot.size.rows and
        snapshot.cursor.col < snapshot.size.cols;
}

fn dirtyIncludesRow(dirty: terminal.DirtyRegion, row: u16) bool {
    return row >= dirty.start_row and row <= dirty.end_row;
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
    try std.testing.expectEqual(@as(usize, 1), draw_list.overlays.len);
    try std.testing.expectEqual(@as(u16, 0), draw_list.overlays[0].cursor.row);
    try std.testing.expectEqual(@as(u16, 1), draw_list.overlays[0].cursor.col);
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
    try std.testing.expectEqual(@as(usize, 0), draw_list.overlays.len);
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
    try std.testing.expectEqual(@as(usize, 2), draw_list.overlays.len);
    try std.testing.expectEqual(@as(u16, 0), draw_list.overlays[0].underline.row);
    try std.testing.expectEqual(@as(u16, 0), draw_list.overlays[0].underline.col);
    try std.testing.expectEqual(@as(u2, 1), draw_list.overlays[0].underline.width);
    try std.testing.expectEqual(terminal.Color{ .indexed = 2 }, draw_list.overlays[0].underline.color);
    // The cursor overlay is appended after the cell loop, so it trails the
    // underline. Pin its tag and position so a regression that drops or
    // misplaces it (e.g. a second underline instead of the cursor) fails here.
    try std.testing.expectEqual(@as(u16, 0), draw_list.overlays[1].cursor.row);
    try std.testing.expectEqual(@as(u16, 1), draw_list.overlays[1].cursor.col);
}

test "draw list suppresses cursor overlay when its row is outside the dirty range" {
    // renderer-strategy.md의 계약: cursor overlay는 dirty row에 cursor가 포함될
    // 때만 생성한다. TerminalCore는 cursor 이동 시 그 row를 항상 dirty로 만들지만,
    // 다른 row만 바뀐 frame에서 cursor를 다시 그리면 redraw가 낭비된다. core 경로로는
    // cursor row가 빠진 dirty를 만들 수 없어 snapshot을 직접 구성해 guard를 고정한다.
    var cells = [_]terminal.Cell{.{}} ** 4;
    const snapshot: terminal.RenderSnapshot = .{
        .size = .{ .cols = 2, .rows = 2 },
        .cursor = .{ .row = 1, .col = 0, .visible = true },
        .cells = &cells,
        .dirty = .{ .start_row = 0, .end_row = 0 },
    };

    var draw_list = try buildDrawList(std.testing.allocator, snapshot);
    defer draw_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), draw_list.cells.len);
    try std.testing.expectEqual(@as(usize, 0), draw_list.overlays.len);
}

test "draw list emits cursor overlay for cursor-only dirty movement" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // Carriage return does not change glyph cells, but it moves the cursor.
    // The DrawList must expose that as an overlay command so a future Metal
    // backend does not bake cursor pixels into glyph atlas entries.
    try core.write("AB");
    core.clearDirty();
    try core.write("\r");

    var draw_list = try buildDrawList(std.testing.allocator, core.snapshot());
    defer draw_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), draw_list.overlays.len);
    try std.testing.expectEqual(@as(u16, 0), draw_list.overlays[0].cursor.row);
    try std.testing.expectEqual(@as(u16, 0), draw_list.overlays[0].cursor.col);
}
