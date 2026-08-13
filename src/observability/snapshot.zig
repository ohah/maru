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
            if (cell.width == 1 and !cell.continuation and cell.grapheme_id == 0) continue;

            wrote_any = true;
            // grapheme=은 base 뒤 cluster 본체(store) 전체 — 악센트·VS16·NFD 한글 V/T·키캡을 무손실로
            // 적는다(grapheme_id==0이면 none). row text는 base+cluster를 합쳐 보여주지만, 메타데이터는
            // 폭/continuation/cluster를 분리 기록해 trace/replay가 그리드 상태를 재구성할 수 있게 한다.
            try writer.print(
                "cell row={d} col={d} codepoint=U+{X:0>4} width={d} continuation={} grapheme=",
                .{ row, col, cell.codepoint, cell.width, cell.continuation },
            );
            if (cell.grapheme_id != 0 and cell.grapheme_id <= snapshot.graphemes.len) {
                for (snapshot.graphemes[cell.grapheme_id - 1], 0..) |cp, i| {
                    if (i != 0) try writer.writeByte(',');
                    try writer.print("U+{X:0>4}", .{cp});
                }
            } else {
                try writer.writeAll("none");
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

// ── reader (역파싱) — docs/snapshot-versioning.md "v3 reader 규칙" ──────────────────────────────────────────
// writer가 낸 maru.snapshot.v3 텍스트를 구조로 되읽는다. **부분 복원**임에 유의 — writer가 직렬화하는 필드
// (size·cursor·dirty·행 텍스트·cell-metadata·styled-cells)만 채운다(cursor_shape·prompt_marks·kitty·나머지
// Style 플래그는 v3가 안 쓰므로 복원 대상 아님). round-trip은 "쓴 것을 되읽을 수 있다"를 증명한다(포맷 안정성·
// 구조화 오라클 비교·후속 inspector의 토대). v3 reader 규칙대로 첫 줄 schema 확인, `dirty none` 해석, 알 수 없는
// semantic section은 실패, `debug.` 접두 라인은 무시한다.

pub const ParseError = error{ BadHeader, BadLine, Truncated, UnknownSection } || std.mem.Allocator.Error;

/// cell-metadata 섹션 한 항목 — 폭/continuation/grapheme cluster 본체(none이면 빈 슬라이스).
pub const CellMeta = struct {
    row: u16,
    col: u16,
    codepoint: u21,
    width: u2,
    continuation: bool,
    grapheme: []const u21,
};

/// styled-cells 섹션 한 항목 — 색/굵기/기울임/밑줄(v3가 노출하는 style 부분집합).
pub const StyledCell = struct {
    row: u16,
    col: u16,
    codepoint: u21,
    fg: terminal.Color,
    bg: terminal.Color,
    bold: bool,
    italic: bool,
    underline: bool,
};

/// maru.snapshot.v3 텍스트를 되읽은 구조. rows/cell_metadata의 grapheme은 allocator 소유 — deinit로 해제한다.
pub const ParsedSnapshot = struct {
    size: terminal.Size,
    cursor: terminal.Cursor,
    dirty: ?terminal.DirtyRegion,
    rows: []const []const u8, // unescape된 행 텍스트, index=row
    cell_metadata: []const CellMeta,
    styled_cells: []const StyledCell,

    pub fn deinit(self: ParsedSnapshot, allocator: std.mem.Allocator) void {
        for (self.rows) |r| allocator.free(r);
        allocator.free(self.rows);
        for (self.cell_metadata) |cm| if (cm.grapheme.len > 0) allocator.free(cm.grapheme);
        allocator.free(self.cell_metadata);
        allocator.free(self.styled_cells);
    }
};

/// 빈 줄·`debug.` 접두(버전 bump 없이 추가 가능한 debug-only 라인)를 건너뛰며 다음 semantic 라인을 준다.
const LineReader = struct {
    it: std.mem.SplitIterator(u8, .scalar),
    fn next(self: *LineReader) ?[]const u8 {
        while (self.it.next()) |line| {
            if (line.len == 0) continue;
            if (std.mem.startsWith(u8, line, "debug.")) continue;
            return line;
        }
        return null;
    }
};

pub fn parseSnapshot(allocator: std.mem.Allocator, text: []const u8) ParseError!ParsedSnapshot {
    var lr = LineReader{ .it = std.mem.splitScalar(u8, text, '\n') };
    if (!eqOpt(lr.next(), "maru.snapshot.v3")) return error.BadHeader;

    const size_line = lr.next() orelse return error.Truncated;
    const size: terminal.Size = .{
        .cols = fieldUint(size_line, "cols", u16) orelse return error.BadLine,
        .rows = fieldUint(size_line, "rows", u16) orelse return error.BadLine,
    };
    const cur_line = lr.next() orelse return error.Truncated;
    const cursor: terminal.Cursor = .{
        .row = fieldUint(cur_line, "row", u16) orelse return error.BadLine,
        .col = fieldUint(cur_line, "col", u16) orelse return error.BadLine,
        .visible = fieldBool(cur_line, "visible") orelse return error.BadLine,
    };
    const dirty_line = lr.next() orelse return error.Truncated;
    const dirty: ?terminal.DirtyRegion = if (std.mem.eql(u8, dirty_line, "dirty none")) null else .{
        .start_row = fieldUint(dirty_line, "start_row", u16) orelse return error.BadLine,
        .end_row = fieldUint(dirty_line, "end_row", u16) orelse return error.BadLine,
    };

    // rows — 정확히 size.rows개의 "row N: |...|".
    if (!eqOpt(lr.next(), "rows")) return error.BadLine;
    const rows = try allocator.alloc([]const u8, size.rows);
    var rows_filled: usize = 0;
    errdefer {
        for (rows[0..rows_filled]) |r| allocator.free(r);
        allocator.free(rows);
    }
    for (0..size.rows) |r| {
        rows[r] = try parseRow(allocator, lr.next() orelse return error.Truncated);
        rows_filled += 1;
    }

    // cell-metadata — "none" 또는 cell 라인들, "styled-cells"에서 종료.
    if (!eqOpt(lr.next(), "cell-metadata")) return error.BadLine;
    var cm: std.ArrayList(CellMeta) = .empty;
    errdefer {
        for (cm.items) |c| if (c.grapheme.len > 0) allocator.free(c.grapheme);
        cm.deinit(allocator);
    }
    var line = lr.next() orelse return error.Truncated;
    if (!std.mem.eql(u8, line, "none")) {
        while (!std.mem.eql(u8, line, "styled-cells")) {
            const meta = try parseCellMeta(allocator, line);
            // append가 OOM하면 meta는 cm.items에 없어 errdefer가 못 잡는다 — 방금 파싱한 grapheme 슬라이스를 회수.
            cm.append(allocator, meta) catch |e| {
                if (meta.grapheme.len > 0) allocator.free(meta.grapheme);
                return e;
            };
            line = lr.next() orelse return error.Truncated;
        }
    } else {
        line = lr.next() orelse return error.Truncated; // "none" 뒤엔 "styled-cells"가 와야 한다
        if (!std.mem.eql(u8, line, "styled-cells")) return error.UnknownSection;
    }

    // styled-cells — "none"(뒤엔 EOF) 또는 cell 라인들(EOF까지).
    var sc: std.ArrayList(StyledCell) = .empty;
    errdefer sc.deinit(allocator);
    const sc_first = lr.next() orelse return error.Truncated;
    if (!std.mem.eql(u8, sc_first, "none")) {
        var sl: ?[]const u8 = sc_first;
        while (sl) |l| : (sl = lr.next()) try sc.append(allocator, try parseStyledCell(l));
    } else if (lr.next() != null) {
        return error.UnknownSection; // "none" 뒤에 또 다른 섹션 = 알 수 없는 semantic section
    }

    // cell_metadata를 먼저 확정하고 own한다 — 이후 styled_cells toOwnedSlice가 OOM하면 cm는 이미 비어 cm errdefer가
    // 못 잡으므로(옮겨진 슬라이스가 고아가 됨), 여기서 별도 errdefer로 커버한다.
    const cell_meta = try cm.toOwnedSlice(allocator);
    errdefer {
        for (cell_meta) |c| if (c.grapheme.len > 0) allocator.free(c.grapheme);
        allocator.free(cell_meta);
    }
    const styled = try sc.toOwnedSlice(allocator);
    return .{
        .size = size,
        .cursor = cursor,
        .dirty = dirty,
        .rows = rows,
        .cell_metadata = cell_meta,
        .styled_cells = styled,
    };
}

fn eqOpt(line: ?[]const u8, expected: []const u8) bool {
    return line != null and std.mem.eql(u8, line.?, expected);
}

/// 라인에서 토큰 경계의 `key=` 값을 다음 공백(또는 EOL)까지 돌려준다. word-boundary라 `row=`가 `start_row=`를
/// 오탐하지 않는다(앞 글자가 공백이거나 라인 시작이어야 매치). 없으면 null.
fn fieldValue(line: []const u8, comptime key: []const u8) ?[]const u8 {
    const marker = key ++ "=";
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, line, from, marker)) |pos| {
        if (pos == 0 or line[pos - 1] == ' ') {
            const vs = pos + marker.len;
            const ve = std.mem.indexOfScalarPos(u8, line, vs, ' ') orelse line.len;
            return line[vs..ve];
        }
        from = pos + 1;
    }
    return null;
}

fn fieldUint(line: []const u8, comptime key: []const u8, comptime T: type) ?T {
    const v = fieldValue(line, key) orelse return null;
    return std.fmt.parseInt(T, v, 10) catch null;
}

fn fieldBool(line: []const u8, comptime key: []const u8) ?bool {
    const v = fieldValue(line, key) orelse return null;
    if (std.mem.eql(u8, v, "true")) return true;
    if (std.mem.eql(u8, v, "false")) return false;
    return null;
}

fn parseCodepoint(s: []const u8) ?u21 {
    if (!std.mem.startsWith(u8, s, "U+")) return null;
    return std.fmt.parseInt(u21, s[2..], 16) catch null;
}

fn parseColor(s: []const u8) ?terminal.Color {
    if (std.mem.eql(u8, s, "default")) return .default;
    if (std.mem.startsWith(u8, s, "indexed(") and s[s.len - 1] == ')') {
        return .{ .indexed = std.fmt.parseInt(u8, s["indexed(".len .. s.len - 1], 10) catch return null };
    }
    if (std.mem.startsWith(u8, s, "rgb(") and s[s.len - 1] == ')') {
        var it = std.mem.splitScalar(u8, s["rgb(".len .. s.len - 1], ',');
        const r = std.fmt.parseInt(u8, it.next() orelse return null, 10) catch return null;
        const g = std.fmt.parseInt(u8, it.next() orelse return null, 10) catch return null;
        const b = std.fmt.parseInt(u8, it.next() orelse return null, 10) catch return null;
        if (it.next() != null) return null; // 3개 초과 = 손상
        return .{ .rgb = .{ .r = r, .g = g, .b = b } };
    }
    return null;
}

/// grapheme= 값("none" 또는 "U+XXXX,U+XXXX,...")을 cluster 본체로. none이면 빈 슬라이스(할당 없음).
fn parseGraphemeList(allocator: std.mem.Allocator, s: []const u8) ParseError![]const u21 {
    if (std.mem.eql(u8, s, "none")) return &.{};
    var list: std.ArrayList(u21) = .empty;
    errdefer list.deinit(allocator);
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |tok| try list.append(allocator, parseCodepoint(tok) orelse return error.BadLine);
    return list.toOwnedSlice(allocator);
}

/// "row N: |...|"에서 `|...|` 안을 snapshot escape(`\n \r \t \\ \|`) 해제해 행 텍스트로. writeCodepoint의 역연산.
fn parseRow(allocator: std.mem.Allocator, line: []const u8) ParseError![]u8 {
    if (!std.mem.startsWith(u8, line, "row ")) return error.BadLine;
    const bar1 = std.mem.indexOfScalar(u8, line, '|') orelse return error.BadLine;
    if (line.len == 0 or line[line.len - 1] != '|' or line.len - 1 <= bar1) return error.BadLine;
    const inner = line[bar1 + 1 .. line.len - 1];
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        if (inner[i] == '\\' and i + 1 < inner.len) {
            i += 1;
            out.writer.writeByte(switch (inner[i]) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => inner[i], // '\\'·'|'·그 외는 그 문자 그대로(backslash 제거)
            }) catch return error.OutOfMemory;
        } else if (inner[i] != '\\') {
            out.writer.writeByte(inner[i]) catch return error.OutOfMemory;
        }
    }
    return out.toOwnedSlice() catch error.OutOfMemory;
}

fn parseCellMeta(allocator: std.mem.Allocator, line: []const u8) ParseError!CellMeta {
    if (!std.mem.startsWith(u8, line, "cell ")) return error.BadLine;
    return .{
        .row = fieldUint(line, "row", u16) orelse return error.BadLine,
        .col = fieldUint(line, "col", u16) orelse return error.BadLine,
        .codepoint = parseCodepoint(fieldValue(line, "codepoint") orelse return error.BadLine) orelse return error.BadLine,
        .width = fieldUint(line, "width", u2) orelse return error.BadLine,
        .continuation = fieldBool(line, "continuation") orelse return error.BadLine,
        .grapheme = try parseGraphemeList(allocator, fieldValue(line, "grapheme") orelse return error.BadLine),
    };
}

fn parseStyledCell(line: []const u8) ParseError!StyledCell {
    if (!std.mem.startsWith(u8, line, "cell ")) return error.BadLine;
    return .{
        .row = fieldUint(line, "row", u16) orelse return error.BadLine,
        .col = fieldUint(line, "col", u16) orelse return error.BadLine,
        .codepoint = parseCodepoint(fieldValue(line, "codepoint") orelse return error.BadLine) orelse return error.BadLine,
        .fg = parseColor(fieldValue(line, "fg") orelse return error.BadLine) orelse return error.BadLine,
        .bg = parseColor(fieldValue(line, "bg") orelse return error.BadLine) orelse return error.BadLine,
        .bold = fieldBool(line, "bold") orelse return error.BadLine,
        .italic = fieldBool(line, "italic") orelse return error.BadLine,
        .underline = fieldBool(line, "underline") orelse return error.BadLine,
    };
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

test "terminal snapshot records wide and grapheme cluster cell metadata" {
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
        "cell row=0 col=1 codepoint=U+D55C width=2 continuation=false grapheme=none\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        rendered,
        // wide glyph의 둘째 슬롯은 글자를 담지 않는다 — 셀에 쓴 codepoint가 없으므로 U+0000이다
        // (안 쓴 칸과 같은 표현, types.Cell). 행 텍스트(`row 0:`)는 공백으로 보이는 것과 별개다.
        "cell row=0 col=2 codepoint=U+0000 width=0 continuation=true grapheme=none\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        rendered,
        "cell row=0 col=3 codepoint=U+0065 width=1 continuation=false grapheme=U+0301\n",
    ) != null);
}

test "terminal snapshot records an NFD Hangul cluster losslessly (grapheme store body)" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 1 });
    defer core.deinit();

    // NFD '한' = 초성 U+1112 + 중성 U+1161 + 종성 U+11AB. 한 셀(width 2)로 묶이고 중성·종성은
    // grapheme_store 본체에 담긴다 — 메타데이터가 grapheme=로 cluster 전체(중성·종성)를 적어야
    // trace/replay가 무손실이다.
    try core.write("\u{1112}\u{1161}\u{11AB}");

    const rendered = try renderTerminalSnapshot(std.testing.allocator, core.snapshot());
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(
        u8,
        rendered,
        "cell row=0 col=0 codepoint=U+1112 width=2 continuation=false grapheme=U+1161,U+11AB\n",
    ) != null);
}

// reader는 writer의 역연산 — 핵심 검증: writer가 낸 v3 텍스트를 되읽으면 **직렬화된 필드**(size·cursor·dirty·행
// 텍스트·wide/grapheme cell-metadata·styled-cells)가 구조로 복원된다(round-trip). 관측 가능성 원칙: 같은 도메인
// 데이터를 writer/reader가 공유해 포맷이 기계 판독 가능함을 증명하고 구조화 오라클/후속 inspector의 토대가 된다.
test "snapshot round-trip: parseSnapshot(renderTerminalSnapshot(...))가 직렬화된 필드를 복원한다" {
    const a = std.testing.allocator;
    var core = try terminal.TerminalCore.init(a, .{ .cols = 6, .rows = 2 });
    defer core.deinit();
    try core.write("A한e\u{0301}\r\n!"); // wide '한'(+continuation) + é(grapheme) + 2행
    core.screen.cells[0].style = .{ .foreground = .{ .indexed = 2 }, .bold = true }; // styled cell

    const text = try renderTerminalSnapshot(a, core.snapshot());
    defer a.free(text);
    const parsed = try parseSnapshot(a, text);
    defer parsed.deinit(a);

    const snap = core.snapshot();
    // 헤더 메타(size/cursor/dirty) 복원.
    try std.testing.expectEqual(snap.size.cols, parsed.size.cols);
    try std.testing.expectEqual(snap.size.rows, parsed.size.rows);
    try std.testing.expectEqual(snap.cursor.row, parsed.cursor.row);
    try std.testing.expectEqual(snap.cursor.col, parsed.cursor.col);
    try std.testing.expectEqual(snap.cursor.visible, parsed.cursor.visible);
    try std.testing.expectEqual(snap.dirty != null, parsed.dirty != null);
    if (snap.dirty) |d| {
        try std.testing.expectEqual(d.start_row, parsed.dirty.?.start_row);
        try std.testing.expectEqual(d.end_row, parsed.dirty.?.end_row);
    }
    // 행 텍스트 복원. é는 decomposed('e' + U+0301 결합)로 저장돼 RowCodepoints가 e·U+0301을 풀므로 그대로 복원된다
    // (precomposed U+00E9가 아니라 — grapheme store 무손실 직렬화). row 0 = "A한e◌́  "(6칸), row 1 = "!     ".
    try std.testing.expectEqual(@as(usize, 2), parsed.rows.len);
    try std.testing.expectEqualStrings("A한e\u{0301}  ", parsed.rows[0]);
    try std.testing.expectEqualStrings("!     ", parsed.rows[1]);
    // cell-metadata: wide '한'(width 2)·continuation·é의 grapheme(U+0301)이 복원된다.
    var saw_wide = false;
    var saw_cont = false;
    var saw_accent = false;
    for (parsed.cell_metadata) |cm| {
        if (cm.col == 1 and cm.codepoint == 0xD55C and cm.width == 2 and !cm.continuation) saw_wide = true;
        if (cm.col == 2 and cm.width == 0 and cm.continuation) saw_cont = true;
        if (cm.col == 3 and cm.codepoint == 0x65 and cm.grapheme.len == 1 and cm.grapheme[0] == 0x301) saw_accent = true;
    }
    try std.testing.expect(saw_wide and saw_cont and saw_accent);
    // styled-cells: fg=indexed(2)·bold 복원.
    try std.testing.expectEqual(@as(usize, 1), parsed.styled_cells.len);
    const s = parsed.styled_cells[0];
    try std.testing.expectEqual(@as(u16, 0), s.row);
    try std.testing.expectEqual(@as(u16, 0), s.col);
    try std.testing.expect(s.fg == .indexed and s.fg.indexed == 2);
    try std.testing.expect(s.bg == .default);
    try std.testing.expect(s.bold and !s.italic and !s.underline);
}

test "snapshot reader: v3 규칙 — 헤더/none/debug 무시/알 수 없는 섹션/rgb·escape 복원" {
    const a = std.testing.allocator;
    // 잘못된 헤더 → BadHeader.
    try std.testing.expectError(error.BadHeader, parseSnapshot(a, "not-a-snapshot\n"));
    // 최소 snapshot(none 섹션들) + debug. 라인 무시.
    {
        const text =
            "maru.snapshot.v3\n" ++
            "size cols=2 rows=1\n" ++
            "cursor row=0 col=0 visible=true\n" ++
            "dirty none\n" ++
            "debug.note ignored\n" ++ // debug. 접두는 무시
            "rows\n" ++
            "row 0: |ab|\n" ++
            "cell-metadata\n" ++
            "none\n" ++
            "styled-cells\n" ++
            "none\n";
        const parsed = try parseSnapshot(a, text);
        defer parsed.deinit(a);
        try std.testing.expectEqual(@as(u16, 2), parsed.size.cols);
        try std.testing.expectEqual(@as(?terminal.DirtyRegion, null), parsed.dirty);
        try std.testing.expectEqualStrings("ab", parsed.rows[0]);
        try std.testing.expectEqual(@as(usize, 0), parsed.cell_metadata.len);
        try std.testing.expectEqual(@as(usize, 0), parsed.styled_cells.len);
    }
    // 알 수 없는 semantic section(styled-cells none 뒤 낯선 라인) → UnknownSection.
    {
        const text = "maru.snapshot.v3\nsize cols=1 rows=1\ncursor row=0 col=0 visible=true\ndirty none\nrows\nrow 0: |x|\ncell-metadata\nnone\nstyled-cells\nnone\nweird-section\n";
        try std.testing.expectError(error.UnknownSection, parseSnapshot(a, text));
    }
    // rgb 색 + escape된 행 텍스트(파이프·백슬래시) 복원.
    {
        const text = "maru.snapshot.v3\nsize cols=2 rows=1\ncursor row=0 col=0 visible=true\ndirty start_row=0 end_row=0\nrows\nrow 0: |\\|\\\\|\ncell-metadata\nnone\nstyled-cells\ncell row=0 col=0 codepoint=U+0041 fg=rgb(10,20,30) bg=default bold=false italic=true underline=false\n";
        const parsed = try parseSnapshot(a, text);
        defer parsed.deinit(a);
        try std.testing.expectEqualStrings("|\\", parsed.rows[0]); // \| → |, \\ → \
        try std.testing.expect(parsed.dirty != null);
        try std.testing.expect(parsed.styled_cells[0].fg == .rgb);
        try std.testing.expectEqual(@as(u8, 20), parsed.styled_cells[0].fg.rgb.g);
        try std.testing.expect(parsed.styled_cells[0].italic);
    }
}

// OOM 경로 누수 회귀: rows·cell-metadata(grapheme 소유)·styled-cells를 파싱하는 도중 어느 할당이 실패해도 새지
// 않아야 한다 — cm.append 실패 시 방금 파싱한 grapheme, styled toOwnedSlice 실패 시 이미 옮긴 cell_metadata가
// errdefer 밖으로 새던 갭(code-review 회귀).
test "parseSnapshot: 모든 할당 실패 지점에서 누수 없음" {
    const text = "maru.snapshot.v3\n" ++
        "size cols=6 rows=2\n" ++
        "cursor row=0 col=0 visible=true\n" ++
        "dirty none\n" ++
        "rows\n" ++
        "row 0: |A\\|B  |\n" ++
        "row 1: |xy    |\n" ++
        "cell-metadata\n" ++
        "cell row=0 col=1 codepoint=U+0065 width=1 continuation=false grapheme=U+0301,U+0302\n" ++
        "styled-cells\n" ++
        "cell row=0 col=0 codepoint=U+0041 fg=rgb(1,2,3) bg=default bold=true italic=false underline=false\n";
    const Runner = struct {
        fn run(a: std.mem.Allocator, t: []const u8) !void {
            const parsed = try parseSnapshot(a, t);
            parsed.deinit(a);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Runner.run, .{text});
}
