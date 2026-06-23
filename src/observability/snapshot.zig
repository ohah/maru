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
    try writeCellMetadata(&output.writer, snapshot);
    try writeStyledCells(&output.writer, snapshot);

    return output.toOwnedSlice();
}

fn writeHeader(writer: *std.Io.Writer, snapshot: terminal.RenderSnapshot) !void {
    try writer.writeAll("maru.snapshot.v3\n");
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
        const row_start = index(snapshot.size, row, 0);
        var codepoints: terminal.RowCodepoints = .{
            .cells = snapshot.cells[row_start..][0..snapshot.size.cols],
            .graphemes = snapshot.graphemes, // cluster 본체(NFD 한글 등)를 무손실로 직렬화
        };
        while (codepoints.next()) |codepoint| try writeCodepoint(writer, codepoint);
        try writer.writeAll("|\n");
    }
}

fn writeCellMetadata(writer: *std.Io.Writer, snapshot: terminal.RenderSnapshot) !void {
    try writer.writeAll("cell-metadata\n");

    var wrote_any = false;
    for (0..snapshot.size.rows) |row| {
        for (0..snapshot.size.cols) |col| {
            const cell = snapshot.cells[index(snapshot.size, row, col)];
            if (cell.width == 1 and !cell.continuation and cell.combining == null) continue;

            wrote_any = true;
            try writer.print(
                "cell row={d} col={d} codepoint=U+{X:0>4} width={d} continuation={} combining=",
                .{ row, col, cell.codepoint, cell.width, cell.continuation },
            );
            if (cell.combining) |combining| {
                try writer.print("U+{X:0>4}", .{combining});
            } else {
                try writer.writeAll("none");
            }
            // 다중 코드포인트 cluster(NFD 한글 등)는 store 본체 전체를 추가로 적어 무손실로 만든다
            // (combining은 첫 extra의 그림자라 그것만으론 손실). grapheme_id가 0이면 줄을 안 바꿔
            // 단일-combining 메타데이터 포맷을 유지한다(기존 테스트 불변).
            if (cell.grapheme_id != 0 and cell.grapheme_id <= snapshot.graphemes.len) {
                try writer.writeAll(" grapheme=");
                for (snapshot.graphemes[cell.grapheme_id - 1], 0..) |cp, i| {
                    if (i != 0) try writer.writeByte(',');
                    try writer.print("U+{X:0>4}", .{cp});
                }
            }
            try writer.writeByte('\n');
        }
    }

    if (!wrote_any) try writer.writeAll("none\n");
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

    try std.testing.expect(std.mem.indexOf(u8, rendered, "maru.snapshot.v3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "size cols=6 rows=2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "cursor row=1 col=1 visible=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "dirty start_row=0 end_row=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "row 0: |hi    |\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "row 1: |!     |\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "cell-metadata\nnone\n") != null);
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
    core.screen.cells[0].style = .{ .foreground = .{ .indexed = 2 }, .bold = true };

    const rendered = try renderTerminalSnapshot(std.testing.allocator, core.snapshot());
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "row 0: |A |\n") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        rendered,
        "cell row=0 col=0 codepoint=U+0041 fg=indexed(2) bg=default bold=true italic=false underline=false\n",
    ) != null);
}

test "terminal snapshot records wide and combining cell metadata" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 1 });
    defer core.deinit();

    // Row text alone cannot prove that a wide glyph has a continuation cell or
    // that an accent did not advance the cursor. v3 records that metadata so
    // future replay and renderer tests can diagnose grid bugs without guessing.
    try core.write("A한e\u{0301}");

    const rendered = try renderTerminalSnapshot(std.testing.allocator, core.snapshot());
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "row 0: |A한é  |\n") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        rendered,
        "cell row=0 col=1 codepoint=U+D55C width=2 continuation=false combining=none\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        rendered,
        "cell row=0 col=2 codepoint=U+0020 width=0 continuation=true combining=none\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        rendered,
        "cell row=0 col=3 codepoint=U+0065 width=1 continuation=false combining=U+0301\n",
    ) != null);
}

test "terminal snapshot records an NFD Hangul cluster losslessly (grapheme store body)" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 1 });
    defer core.deinit();

    // NFD '한' = 초성 U+1112 + 중성 U+1161 + 종성 U+11AB. 한 셀(width 2)로 묶이고 중성·종성은
    // grapheme_store 본체에 담긴다 — combining(첫 extra 그림자)만 적으면 종성이 손실되므로,
    // 메타데이터가 grapheme=로 cluster 전체를 적어야 trace/replay가 무손실이다.
    try core.write("\u{1112}\u{1161}\u{11AB}");

    const rendered = try renderTerminalSnapshot(std.testing.allocator, core.snapshot());
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(
        u8,
        rendered,
        "cell row=0 col=0 codepoint=U+1112 width=2 continuation=false combining=U+1161 grapheme=U+1161,U+11AB\n",
    ) != null);
}
