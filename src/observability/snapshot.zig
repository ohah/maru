const std = @import("std");
const terminal = @import("../terminal.zig");

pub fn renderTerminalSnapshot(
    allocator: std.mem.Allocator,
    snapshot: terminal.RenderSnapshot,
) ![]u8 {
    // Tests, future replay, and a future inspector need one shared view of the
    // terminal state. Keeping this serializer in product code prevents each
    // test layer from inventing its own partial debug format.
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    try writeHeader(&output.writer, snapshot);
    try writeRows(&output.writer, snapshot);
    try writeStyledCells(&output.writer, snapshot);

    return output.toOwnedSlice();
}

fn writeHeader(writer: *std.Io.Writer, snapshot: terminal.RenderSnapshot) !void {
    try writer.writeAll("maru.snapshot.v2\n");
    try writer.print("size cols={d} rows={d}\n", .{ snapshot.size.cols, snapshot.size.rows });
    try writer.print(
        "cursor row={d} col={d} visible={}\n",
        .{ snapshot.cursor.row, snapshot.cursor.col, snapshot.cursor.visible },
    );
    if (snapshot.dirty) |dirty| {
        try writer.print(
            "dirty start_row={d} end_row={d}\n",
            .{ dirty.start_row, dirty.end_row },
        );
    } else {
        try writer.writeAll("dirty none\n");
    }
}

fn writeRows(writer: *std.Io.Writer, snapshot: terminal.RenderSnapshot) !void {
    try writer.writeAll("rows\n");

    for (0..snapshot.size.rows) |row| {
        try writer.print("row {d}: |", .{row});
        for (0..snapshot.size.cols) |col| {
            const cell = snapshot.cells[index(snapshot.size, row, col)];
            try writeCodepoint(writer, cell.codepoint);
        }
        try writer.writeAll("|\n");
    }
}

fn writeStyledCells(writer: *std.Io.Writer, snapshot: terminal.RenderSnapshot) !void {
    try writer.writeAll("styled-cells\n");

    var wrote_any = false;
    for (0..snapshot.size.rows) |row| {
        for (0..snapshot.size.cols) |col| {
            const cell = snapshot.cells[index(snapshot.size, row, col)];
            if (!hasNonDefaultStyle(cell.style)) continue;

            wrote_any = true;
            try writer.print(
                "cell row={d} col={d} codepoint=U+{X:0>4} ",
                .{ row, col, cell.codepoint },
            );
            try writeStyle(writer, cell.style);
            try writer.writeByte('\n');
        }
    }

    if (!wrote_any) try writer.writeAll("none\n");
}

fn writeStyle(writer: *std.Io.Writer, style: terminal.Style) !void {
    try writer.writeAll("fg=");
    try writeColor(writer, style.foreground);
    try writer.writeAll(" bg=");
    try writeColor(writer, style.background);
    try writer.print(
        " bold={} italic={} underline={}",
        .{ style.bold, style.italic, style.underline },
    );
}

fn writeColor(writer: *std.Io.Writer, color: terminal.Color) !void {
    switch (color) {
        .default => try writer.writeAll("default"),
        .indexed => |value| try writer.print("indexed({d})", .{value}),
        .rgb => |rgb| try writer.print("rgb({d},{d},{d})", .{ rgb.r, rgb.g, rgb.b }),
    }
}

fn writeCodepoint(writer: *std.Io.Writer, codepoint: u21) !void {
    switch (codepoint) {
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        '\\' => try writer.writeAll("\\\\"),
        '|' => try writer.writeAll("\\|"),
        else => try writer.print("{u}", .{codepoint}),
    }
}

fn hasNonDefaultStyle(style: terminal.Style) bool {
    return !isDefaultColor(style.foreground) or
        !isDefaultColor(style.background) or
        style.bold or
        style.italic or
        style.underline;
}

fn isDefaultColor(color: terminal.Color) bool {
    return switch (color) {
        .default => true,
        .indexed, .rgb => false,
    };
}

fn index(size: terminal.Size, row: usize, col: usize) usize {
    return row * size.cols + col;
}

test "terminal snapshot records state that plain text cannot prove" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 2 });
    defer core.deinit();

    // The snapshot test intentionally checks cursor and dirty metadata, not
    // only visible text. Terminal rendering bugs often hide in these fields
    // because the screen can look correct while incremental redraw state is
    // wrong.
    try core.write("hi\r\n!");

    const rendered = try renderTerminalSnapshot(std.testing.allocator, core.snapshot());
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "maru.snapshot.v2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "size cols=6 rows=2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "cursor row=1 col=1 visible=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "dirty start_row=0 end_row=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "row 0: |hi    |\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "row 1: |!     |\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "styled-cells\nnone\n") != null);
}

test "terminal snapshot records clean dirty state explicitly" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 1 });
    defer core.deinit();

    // 깨끗한 dirty 상태도 artifact에 보여야 한다. 그래야 renderer 테스트가
    // "아무 것도 안 바뀜"과 "첫 번째 cell이 바뀜"을 구분할 수 있다.
    core.clearDirty();

    const rendered = try renderTerminalSnapshot(std.testing.allocator, core.snapshot());
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "dirty none\n") != null);
}

test "terminal snapshot records styled cells separately from visible text" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 1 });
    defer core.deinit();

    // Style state is separated from row text because two screens can contain
    // the same characters while requiring different renderer output. This
    // protects future color/bold/underline work from becoming invisible to
    // snapshot tests.
    try core.write("A");
    core.cells[0].style = .{ .foreground = .{ .indexed = 2 }, .bold = true };

    const rendered = try renderTerminalSnapshot(std.testing.allocator, core.snapshot());
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "row 0: |A |\n") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        rendered,
        "cell row=0 col=0 codepoint=U+0041 fg=indexed(2) bg=default bold=true italic=false underline=false\n",
    ) != null);
}
