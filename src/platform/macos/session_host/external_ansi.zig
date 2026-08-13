//! P5c3b 외부 attach ANSI projector.
//!
//! 외부 터미널은 host의 PTY byte stream을 다시 해석하지 않는다. GUI와 같은 중립 `RenderSnapshot`
//! 하나를 `ScreenSource` lock 안에서 읽어 immutable full repaint로 만든다. 이 파일은
//! `RemoteScreen`/screen assembler의 private storage를 import하지 않는다.

const std = @import("std");
const maru = @import("maru");
const terminal = maru.terminal;
const ScreenSource = maru.session.surface.ScreenSource;

// xterm ctlseqs가 정의한 private 1049 alternate-screen mode를 Terminal.app/iTerm2/Ghostty가
// 공통 지원한다. caller 화면+cursor를 함께 저장/복원하므로 DECSC/DECRC를 별도로 섞지 않는다.
pub const enter_bytes = "\x1b[?1049h\x1b[?25l";
pub const leave_bytes = "\x1b[0m\x1b[?25h\x1b[?1049l";
pub const max_repaint_bytes: usize = 32 * 1024 * 1024;
pub const max_resident_bytes: usize = max_repaint_bytes * 2;
pub const max_viewport_cells: usize = 1_048_576;
pub const max_grapheme_codepoints: usize = max_repaint_bytes / @sizeOf(u21);

comptime {
    if (enter_bytes.len > 64 or leave_bytes.len > 64)
        @compileError("external ANSI enter/leave cleanup reserve exceeds 64 bytes");
    if (max_resident_bytes != max_repaint_bytes * 2)
        @compileError("external ANSI resident budget must hold exactly current plus latest");
}

pub const ProjectError = error{
    ProtocolError,
    FrameTooLarge,
    OutOfMemory,
};

pub const Frame = struct {
    projection_sequence: u64 = 0,
    bytes: []const u8,
    storage: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Frame) void {
        self.allocator.free(self.storage);
        self.* = undefined;
    }
};

pub const RepaintQueue = struct {
    allocator: std.mem.Allocator,
    current: ?Frame = null,
    latest: ?Frame = null,
    newest_projection_sequence: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator) RepaintQueue {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *RepaintQueue) void {
        if (self.current) |*frame| frame.deinit();
        if (self.latest) |*frame| frame.deinit();
        self.* = undefined;
    }

    /// current는 write offset이 붙을 P5c3c의 active frame, latest는 아직 0 byte인 교체 가능 frame이다.
    /// queue가 projection까지 소유하고 기존 latest를 먼저 회수하므로 frame builder를 포함한 resident 합도
    /// current 32 MiB + building/latest 32 MiB를 넘지 않는다. 실패하면 current는 보존하되 latest는 비운다.
    pub fn replaceLatest(
        self: *RepaintQueue,
        source: ScreenSource,
        local_size: terminal.Size,
        io: std.Io,
        projection_sequence: u64,
    ) (ProjectError || error{StaleFrame})!void {
        return self.replaceLatestWithLimit(
            source,
            local_size,
            io,
            projection_sequence,
            max_repaint_bytes,
        );
    }

    fn replaceLatestWithLimit(
        self: *RepaintQueue,
        source: ScreenSource,
        local_size: terminal.Size,
        io: std.Io,
        projection_sequence: u64,
        limit: usize,
    ) (ProjectError || error{StaleFrame})!void {
        // Host generation은 local resize repaint 사이에 같을 수 있다. 한 event-loop owner가
        // dequeue 순서대로 부여하는 projection_sequence만 publish ordering의 SSOT로 쓴다.
        if (self.newest_projection_sequence) |newest| {
            if (projection_sequence <= newest) return error.StaleFrame;
        }
        if (self.latest) |*old| old.deinit();
        self.latest = null;

        var frame = try projectWithLimit(self.allocator, source, local_size, io, limit);
        frame.projection_sequence = projection_sequence;
        if (self.current == null) {
            self.current = frame;
            self.newest_projection_sequence = projection_sequence;
            return;
        }
        self.latest = frame;
        self.newest_projection_sequence = projection_sequence;
    }

    /// active frame이 전부 출력된 뒤에만 호출한다. partial current를 latest와 섞지 않고
    /// current를 회수한 다음 가장 최근 full repaint를 다음 active frame으로 승격한다.
    pub fn completeCurrent(self: *RepaintQueue) void {
        if (self.current) |*done| done.deinit();
        self.current = self.latest;
        self.latest = null;
    }
};

fn project(
    allocator: std.mem.Allocator,
    source: ScreenSource,
    local_size: terminal.Size,
    io: std.Io,
) ProjectError!Frame {
    return projectWithLimit(allocator, source, local_size, io, max_repaint_bytes);
}

fn projectWithLimit(
    allocator: std.mem.Allocator,
    source: ScreenSource,
    local_size: terminal.Size,
    io: std.Io,
    limit: usize,
) ProjectError!Frame {
    const local_cells = std.math.mul(usize, local_size.cols, local_size.rows) catch
        return error.ProtocolError;
    if (local_cells > max_viewport_cells) return error.ProtocolError;

    source.vtable.lock(source.ctx, io);
    defer source.vtable.unlock(source.ctx, io);
    const snapshot = source.vtable.render_snapshot(source.ctx);

    const host_cells = std.math.mul(usize, snapshot.size.cols, snapshot.size.rows) catch
        return error.ProtocolError;
    if (host_cells != snapshot.cells.len or host_cells > max_viewport_cells)
        return error.ProtocolError;
    try validateCells(snapshot);

    // 첫 pass는 allocation 없이 exact encoded length만 계산한다. 둘째 pass는 그 길이 하나만
    // 할당해 같은 encoder를 재실행하므로 geometric growth/shrink-copy/32 MiB hard reservation이 없다.
    var sizing = Encoder{ .limit = limit };
    try encodeSnapshot(snapshot, local_size, &sizing);
    const storage = allocator.alloc(u8, sizing.len) catch return error.OutOfMemory;
    errdefer allocator.free(storage);
    var out = Encoder{ .limit = limit, .storage = storage };
    try encodeSnapshot(snapshot, local_size, &out);
    std.debug.assert(out.len == sizing.len);
    return .{
        .bytes = storage[0..out.len],
        .storage = storage,
        .allocator = allocator,
    };
}

const Encoder = struct {
    limit: usize,
    storage: ?[]u8 = null,
    len: usize = 0,

    fn append(self: *Encoder, bytes: []const u8) ProjectError!void {
        const end = std.math.add(usize, self.len, bytes.len) catch
            return error.FrameTooLarge;
        if (end > self.limit) return error.FrameTooLarge;
        if (self.storage) |storage| {
            if (end > storage.len) return error.ProtocolError;
            @memcpy(storage[self.len..end], bytes);
        }
        self.len = end;
    }
};

fn encodeSnapshot(
    snapshot: terminal.RenderSnapshot,
    local_size: terminal.Size,
    out: *Encoder,
) ProjectError!void {
    // 이전 repaint가 cursor를 보였을 수 있으므로 partial stdout에서도 clear 전에 먼저 숨긴다.
    try out.append("\x1b[?25l\x1b[0m\x1b[2J");

    const rows = @min(snapshot.size.rows, local_size.rows);
    const cols = @min(snapshot.size.cols, local_size.cols);
    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        var col: u16 = 0;
        while (col < cols) : (col += 1) {
            const index = @as(usize, row) * snapshot.size.cols + col;
            const cell = snapshot.cells[index];
            if (cell.continuation) {
                if (cell.width != 0) return error.ProtocolError;
                continue;
            }
            if (cell.width != 1 and cell.width != 2) return error.ProtocolError;
            if (cell.width == 2 and (@as(usize, col) + 1 >= cols)) continue;
            if (cell.grapheme_id > snapshot.graphemes.len) return error.ProtocolError;
            if (styleIsUnsupported(cell.style)) return error.ProtocolError;
            if (cellIsClearedBlank(cell)) continue;

            try appendCup(out, row, col);
            try appendStyle(out, cell.style);
            const at_bottom_right = row + 1 == local_size.rows and
                @as(usize, col) + cell.width >= local_size.cols;
            const safe_bottom_right = cell.codepoint >= 0x20 and
                cell.codepoint <= 0x7e and
                cell.grapheme_id == 0;
            // 외부 terminal의 EAW/emoji width policy는 협상할 수 없다. 우하단에서 local-wide로
            // 해석된 glyph는 출력 자체가 먼저 scroll할 수 있으므로 그 한 anchor만 ASCII '?'로
            // 대체한다. 나머지 anchor는 후속 CUP가 local width 차이의 누적을 제거한다.
            if (at_bottom_right and !safe_bottom_right) {
                try appendCodepoint(out, '?');
            } else {
                try appendCodepoint(out, sanitizeCodepoint(cell.codepoint));
            }
            if (cell.grapheme_id != 0 and !(at_bottom_right and !safe_bottom_right)) {
                for (snapshot.graphemes[cell.grapheme_id - 1]) |cp| {
                    try appendCodepoint(out, sanitizeCodepoint(cp));
                }
            }
            // 마지막 셀 출력은 wrap-pending을 만들 수 있다. 같은 위치의 CUP는 cell을 지우지 않고
            // pending wrap만 취소해 다음 repaint/leave가 의도치 않은 scroll을 만들지 않게 한다.
            if (row + 1 == local_size.rows and @as(usize, col) + cell.width >= local_size.cols)
                try appendCup(out, row, col);
        }
    }

    if (snapshot.cursor.visible and
        snapshot.cursor.row < rows and
        snapshot.cursor.col < cols)
    {
        try appendCup(out, snapshot.cursor.row, snapshot.cursor.col);
        try out.append("\x1b[?25h");
    } else {
        try out.append("\x1b[?25l");
    }
}

fn appendCup(
    out: *Encoder,
    row: u16,
    col: u16,
) ProjectError!void {
    var buf: [32]u8 = undefined;
    const bytes = std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{
        @as(u32, row) + 1,
        @as(u32, col) + 1,
    }) catch return error.ProtocolError;
    try out.append(bytes);
}

fn appendStyle(
    out: *Encoder,
    style: terminal.Style,
) ProjectError!void {
    var buf: [192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    writer.writeAll("\x1b[0") catch return error.ProtocolError;
    if (style.bold) writer.writeAll(";1") catch return error.ProtocolError;
    if (style.dim) writer.writeAll(";2") catch return error.ProtocolError;
    if (style.italic) writer.writeAll(";3") catch return error.ProtocolError;
    if (style.underline_double)
        writer.writeAll(";21") catch return error.ProtocolError
    else if (style.underline)
        writer.writeAll(";4") catch return error.ProtocolError;
    if (style.blink) writer.writeAll(";5") catch return error.ProtocolError;
    if (style.reverse) writer.writeAll(";7") catch return error.ProtocolError;
    if (style.conceal) writer.writeAll(";8") catch return error.ProtocolError;
    if (style.strikethrough) writer.writeAll(";9") catch return error.ProtocolError;
    try appendColor(&writer, 38, style.foreground);
    try appendColor(&writer, 48, style.background);
    try appendColor(&writer, 58, style.underline_color);
    writer.writeAll("m") catch return error.ProtocolError;
    try out.append(writer.buffered());
}

fn appendColor(writer: *std.Io.Writer, base: u8, value: terminal.Color) ProjectError!void {
    switch (value) {
        .default => {},
        .indexed => |index| writer.print(";{d};5;{d}", .{ base, index }) catch
            return error.ProtocolError,
        .rgb => |rgb| writer.print(";{d};2;{d};{d};{d}", .{ base, rgb.r, rgb.g, rgb.b }) catch
            return error.ProtocolError,
    }
}

fn appendCodepoint(
    out: *Encoder,
    cp: u21,
) ProjectError!void {
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &buf) catch return error.ProtocolError;
    try out.append(buf[0..len]);
}

fn sanitizeCodepoint(cp: u21) u21 {
    if (cp <= 0x1f or (cp >= 0x7f and cp <= 0x9f)) return 0xfffd;
    return cp;
}

fn validateCells(snapshot: terminal.RenderSnapshot) ProjectError!void {
    try validateGraphemeEntryCount(snapshot.graphemes.len);
    var grapheme_codepoints: usize = 0;
    for (snapshot.graphemes) |cluster| {
        grapheme_codepoints = std.math.add(usize, grapheme_codepoints, cluster.len) catch
            return error.ProtocolError;
        if (grapheme_codepoints > max_grapheme_codepoints) return error.ProtocolError;
    }
    for (snapshot.graphemes) |cluster| {
        for (cluster) |cp| {
            if (!isUnicodeScalar(cp)) return error.ProtocolError;
        }
    }
    var row: u16 = 0;
    while (row < snapshot.size.rows) : (row += 1) {
        var col: u16 = 0;
        while (col < snapshot.size.cols) : (col += 1) {
            const index = @as(usize, row) * snapshot.size.cols + col;
            const cell = snapshot.cells[index];
            if (!isUnicodeScalar(cell.codepoint)) return error.ProtocolError;
            if (styleIsUnsupported(cell.style)) return error.ProtocolError;
            if (cell.grapheme_id > snapshot.graphemes.len) return error.ProtocolError;
            if (cell.style.underline_double and !cell.style.underline)
                return error.ProtocolError;
            if (cell.continuation) {
                if (cell.width != 0 or cell.grapheme_id != 0 or col == 0)
                    return error.ProtocolError;
                const previous = snapshot.cells[index - 1];
                if (previous.continuation or previous.width != 2) return error.ProtocolError;
                continue;
            }
            if (cell.width != 1 and cell.width != 2) return error.ProtocolError;
            if (cell.width == 2) {
                if (@as(usize, col) + 1 >= snapshot.size.cols) return error.ProtocolError;
                const continuation = snapshot.cells[index + 1];
                if (!continuation.continuation or continuation.width != 0)
                    return error.ProtocolError;
            }
        }
    }
}

fn validateGraphemeEntryCount(count: usize) ProjectError!void {
    if (count > max_viewport_cells) return error.ProtocolError;
}

fn isUnicodeScalar(cp: u21) bool {
    return cp <= 0x10ffff and !(cp >= 0xd800 and cp <= 0xdfff);
}

fn styleIsUnsupported(style: terminal.Style) bool {
    // P5c3의 허용 SGR 표에 없는 overline은 조용히 손실하지 않는다. 새 Style 필드가 생기면
    // 아래 comptime 분류가 빌드를 깨 projector의 명시적 결정 없이는 외부 출력에 열리지 않는다.
    comptime {
        const classified = [_][]const u8{
            "foreground",       "background",    "bold",
            "dim",              "italic",        "underline",
            "underline_double", "strikethrough", "overline",
            "reverse",          "blink",         "conceal",
            "underline_color",
        };
        for (@typeInfo(terminal.Style).@"struct".fields) |field| {
            var found = false;
            for (classified) |name| {
                if (std.mem.eql(u8, field.name, name)) found = true;
            }
            if (!found) @compileError("external ANSI projector must classify Style." ++ field.name);
        }
    }
    return style.overline;
}

fn cellIsClearedBlank(cell: terminal.Cell) bool {
    return (cell.codepoint == ' ' or cell.codepoint == 0) and
        cell.grapheme_id == 0 and
        cell.width == 1 and
        std.meta.eql(cell.style, terminal.Style{});
}

const FakeSource = struct {
    snapshot: terminal.RenderSnapshot,
    locks: usize = 0,
    unlocks: usize = 0,

    const vtable = ScreenSource.VTable{
        .render_snapshot = render,
        .lock = lock,
        .unlock = unlock,
    };

    fn source(self: *FakeSource) ScreenSource {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn render(ctx: *anyopaque) terminal.RenderSnapshot {
        const self: *FakeSource = @ptrCast(@alignCast(ctx));
        return self.snapshot;
    }

    fn lock(ctx: *anyopaque, _: std.Io) void {
        const self: *FakeSource = @ptrCast(@alignCast(ctx));
        self.locks += 1;
    }

    fn unlock(ctx: *anyopaque, _: std.Io) void {
        const self: *FakeSource = @ptrCast(@alignCast(ctx));
        self.unlocks += 1;
    }
};

test "external ansi exact enter leave and blank repaint use ScreenSource lock" {
    const cells = [_]terminal.Cell{ .{}, .{} };
    var source = FakeSource{ .snapshot = .{
        .size = .{ .cols = 2, .rows = 1 },
        .cells = &cells,
        .cursor = .{ .visible = false },
    } };
    var frame = try project(std.testing.allocator, source.source(), .{ .cols = 3, .rows = 1 }, std.testing.io);
    defer frame.deinit();
    try std.testing.expectEqualStrings("\x1b[?25l\x1b[0m\x1b[2J\x1b[?25l", frame.bytes);
    try std.testing.expectEqual(@as(usize, 1), source.locks);
    try std.testing.expectEqual(@as(usize, 1), source.unlocks);
    try std.testing.expectEqualStrings("\x1b[?1049h\x1b[?25l", enter_bytes);
    try std.testing.expectEqualStrings("\x1b[0m\x1b[?25h\x1b[?1049l", leave_bytes);
}

test "external ansi projects grapheme anchors styles crop and control bytes safely" {
    const cells = [_]terminal.Cell{
        .{ .codepoint = 'A', .style = .{ .foreground = .{ .indexed = 2 }, .bold = true } },
        .{ .codepoint = 0x1b },
        .{ .codepoint = 0xD55C, .width = 2, .grapheme_id = 1 },
        .{ .width = 0, .continuation = true },
        .{ .codepoint = 'X' },
        .{ .codepoint = 'Y', .style = .{ .background = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } }, .italic = true, .underline = true, .strikethrough = true } },
        .{},
        .{},
    };
    const cluster = [_]u21{0x1161};
    const graphemes = [_][]const u21{&cluster};
    var source = FakeSource{ .snapshot = .{
        .size = .{ .cols = 4, .rows = 2 },
        .cells = &cells,
        .graphemes = &graphemes,
        .cursor = .{ .row = 1, .col = 1, .visible = true },
    } };
    var frame = try project(std.testing.allocator, source.source(), .{ .cols = 3, .rows = 2 }, std.testing.io);
    defer frame.deinit();

    try std.testing.expect(std.mem.indexOf(u8, frame.bytes, "\x1b[1;1H\x1b[0;1;38;5;2mA") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame.bytes, "\x1b[1;2H\x1b[0m\xef\xbf\xbd") != null);
    // wide anchor at host col 3 is cropped because local col 3 is the right edge; its continuation is never emitted.
    try std.testing.expect(std.mem.indexOf(u8, frame.bytes, "\xed\x95\x9c") == null);
    try std.testing.expect(std.mem.indexOf(u8, frame.bytes, "\x1b[2;2H\x1b[0;3;4;9;48;2;1;2;3mY") != null);
    try std.testing.expect(std.mem.endsWith(u8, frame.bytes, "\x1b[2;2H\x1b[?25h"));
}

test "external ansi emits complete wide grapheme and hides out of viewport cursor" {
    const cells = [_]terminal.Cell{
        .{ .codepoint = 0xD55C, .width = 2, .grapheme_id = 1 },
        .{ .width = 0, .continuation = true },
    };
    const cluster = [_]u21{0x1161};
    const graphemes = [_][]const u21{&cluster};
    var source = FakeSource{ .snapshot = .{
        .size = .{ .cols = 2, .rows = 1 },
        .cells = &cells,
        .graphemes = &graphemes,
        .cursor = .{ .row = 4, .col = 4, .visible = true },
    } };
    var frame = try project(std.testing.allocator, source.source(), .{ .cols = 3, .rows = 1 }, std.testing.io);
    defer frame.deinit();
    try std.testing.expect(std.mem.indexOf(u8, frame.bytes, "\xed\x95\x9c\xe1\x85\xa1") != null);
    try std.testing.expect(std.mem.endsWith(u8, frame.bytes, "\x1b[?25l"));
}

test "external ansi maps the complete allowed SGR style and color table" {
    const cells = [_]terminal.Cell{.{
        .codepoint = 'S',
        .style = .{
            .foreground = .{ .rgb = .{ .r = 10, .g = 20, .b = 30 } },
            .background = .{ .indexed = 200 },
            .bold = true,
            .dim = true,
            .italic = true,
            .underline = true,
            .underline_double = true,
            .strikethrough = true,
            .reverse = true,
            .blink = true,
            .conceal = true,
            .underline_color = .{ .indexed = 7 },
        },
    }};
    var source = FakeSource{ .snapshot = .{
        .size = .{ .cols = 1, .rows = 1 },
        .cells = &cells,
        .cursor = .{ .visible = false },
    } };
    var frame = try project(std.testing.allocator, source.source(), .{ .cols = 1, .rows = 1 }, std.testing.io);
    defer frame.deinit();
    try std.testing.expect(std.mem.indexOf(
        u8,
        frame.bytes,
        "\x1b[0;1;2;3;21;5;7;8;9;38;2;10;20;30;48;5;200;58;5;7mS",
    ) != null);
}

test "external ansi replaces every C0 C1 and DEL text codepoint" {
    var cells: [65]terminal.Cell = undefined;
    var index: usize = 0;
    var cp: u21 = 0;
    while (cp <= 0x1f) : (cp += 1) {
        cells[index] = .{ .codepoint = cp };
        index += 1;
    }
    cells[index] = .{ .codepoint = 0x7f };
    index += 1;
    cp = 0x80;
    while (cp <= 0x9f) : (cp += 1) {
        cells[index] = .{ .codepoint = cp };
        index += 1;
    }
    try std.testing.expectEqual(cells.len, index);
    var source = FakeSource{ .snapshot = .{
        .size = .{ .cols = @intCast(cells.len), .rows = 1 },
        .cells = &cells,
        .cursor = .{ .visible = false },
    } };
    // 한 칸 넓은 local viewport로 우하단 placeholder 정책과 독립해 C0/C1/DEL 전수만 검증한다.
    var frame = try project(std.testing.allocator, source.source(), .{ .cols = @intCast(cells.len + 1), .rows = 1 }, std.testing.io);
    defer frame.deinit();
    // NUL(0x00)만 예외다: 코어는 `codepoint < 0x20`을 셀에 쓰지 않으므로(screen.zig) **쓴 NUL은
    // 존재할 수 없고**, 셀의 0은 "아무도 안 쓴 칸"을 뜻한다(types.Cell). 그래서 공백으로 나가고
    // 나머지 64개(C0 0x01~0x1f·DEL·C1)만 U+FFFD로 치환된다 — 제어 바이트가 새는 일은 없다.
    try std.testing.expectEqual(@as(usize, 64), std.mem.count(u8, frame.bytes, "\xef\xbf\xbd"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, frame.bytes, "\x00")); // NUL 은 어떤 형태로도 안 샌다
}

test "external ansi rejects malformed snapshot and unsupported style without publishing" {
    const malformed = [_]terminal.Cell{.{ .codepoint = 'x' }};
    var source = FakeSource{ .snapshot = .{
        .size = .{ .cols = 2, .rows = 1 },
        .cells = &malformed,
    } };
    try std.testing.expectError(
        error.ProtocolError,
        project(std.testing.allocator, source.source(), .{ .cols = 2, .rows = 1 }, std.testing.io),
    );

    const unsupported = [_]terminal.Cell{.{ .codepoint = 'x', .style = .{ .overline = true } }};
    source.snapshot = .{ .size = .{ .cols = 1, .rows = 1 }, .cells = &unsupported };
    try std.testing.expectError(
        error.ProtocolError,
        project(std.testing.allocator, source.source(), .{ .cols = 1, .rows = 1 }, std.testing.io),
    );

    const orphan = [_]terminal.Cell{.{ .width = 0, .continuation = true }};
    source.snapshot = .{ .size = .{ .cols = 1, .rows = 1 }, .cells = &orphan };
    try std.testing.expectError(
        error.ProtocolError,
        project(std.testing.allocator, source.source(), .{ .cols = 1, .rows = 1 }, std.testing.io),
    );

    const invalid_double = [_]terminal.Cell{.{ .codepoint = 'x', .style = .{ .underline_double = true } }};
    source.snapshot = .{ .size = .{ .cols = 1, .rows = 1 }, .cells = &invalid_double };
    try std.testing.expectError(
        error.ProtocolError,
        project(std.testing.allocator, source.source(), .{ .cols = 1, .rows = 1 }, std.testing.io),
    );

    const invalid_scalar = [_]terminal.Cell{.{ .codepoint = 0xd800 }};
    source.snapshot = .{ .size = .{ .cols = 1, .rows = 1 }, .cells = &invalid_scalar };
    try std.testing.expectError(
        error.ProtocolError,
        project(std.testing.allocator, source.source(), .{ .cols = 1, .rows = 1 }, std.testing.io),
    );

    const invalid_cluster = [_]u21{0xdfff};
    const invalid_graphemes = [_][]const u21{&invalid_cluster};
    const cropped_invalid = [_]terminal.Cell{
        .{ .codepoint = 'x' },
        .{ .codepoint = 'y', .grapheme_id = 1 },
    };
    source.snapshot = .{
        .size = .{ .cols = 2, .rows = 1 },
        .cells = &cropped_invalid,
        .graphemes = &invalid_graphemes,
    };
    try std.testing.expectError(
        error.ProtocolError,
        project(std.testing.allocator, source.source(), .{ .cols = 1, .rows = 1 }, std.testing.io),
    );

    const cropped_style = [_]terminal.Cell{
        .{ .codepoint = 'x' },
        .{ .codepoint = 'y', .style = .{ .overline = true } },
    };
    source.snapshot = .{ .size = .{ .cols = 2, .rows = 1 }, .cells = &cropped_style };
    try std.testing.expectError(
        error.ProtocolError,
        project(std.testing.allocator, source.source(), .{ .cols = 1, .rows = 1 }, std.testing.io),
    );

    const continuation_style = [_]terminal.Cell{
        .{ .codepoint = '한', .width = 2 },
        .{ .width = 0, .continuation = true, .style = .{ .overline = true } },
    };
    source.snapshot = .{ .size = .{ .cols = 2, .rows = 1 }, .cells = &continuation_style };
    try std.testing.expectError(
        error.ProtocolError,
        project(std.testing.allocator, source.source(), .{ .cols = 2, .rows = 1 }, std.testing.io),
    );

    const continuation_bad_fields = [_]terminal.Cell{
        .{ .codepoint = '한', .width = 2 },
        .{
            .width = 0,
            .continuation = true,
            .grapheme_id = std.math.maxInt(u32),
        },
    };
    source.snapshot = .{
        .size = .{ .cols = 2, .rows = 1 },
        .cells = &continuation_bad_fields,
    };
    try std.testing.expectError(
        error.ProtocolError,
        project(std.testing.allocator, source.source(), .{ .cols = 2, .rows = 1 }, std.testing.io),
    );

    const continuation_grapheme = [_]u21{0x301};
    const continuation_graphemes = [_][]const u21{&continuation_grapheme};
    const continuation_nonzero_id = [_]terminal.Cell{
        .{ .codepoint = '한', .width = 2 },
        .{ .width = 0, .continuation = true, .grapheme_id = 1 },
    };
    source.snapshot = .{
        .size = .{ .cols = 2, .rows = 1 },
        .cells = &continuation_nonzero_id,
        .graphemes = &continuation_graphemes,
    };
    try std.testing.expectError(
        error.ProtocolError,
        project(std.testing.allocator, source.source(), .{ .cols = 2, .rows = 1 }, std.testing.io),
    );

    const continuation_bad_style = [_]terminal.Cell{
        .{ .codepoint = '한', .width = 2 },
        .{
            .width = 0,
            .continuation = true,
            .style = .{ .underline_double = true },
        },
    };
    source.snapshot.cells = &continuation_bad_style;
    try std.testing.expectError(
        error.ProtocolError,
        project(std.testing.allocator, source.source(), .{ .cols = 2, .rows = 1 }, std.testing.io),
    );

    // local viewport admission is checked before borrowing the ScreenSource.
    const locks_before = source.locks;
    try std.testing.expectError(
        error.ProtocolError,
        project(std.testing.allocator, source.source(), .{ .cols = 65_535, .rows = 17 }, std.testing.io),
    );
    try std.testing.expectEqual(locks_before, source.locks);
}

test "external ansi bottom right uses ASCII placeholder for caller-width-independent repaint" {
    const graphemes = [_][]const u21{&.{0xfe0f}};
    const cells = [_]terminal.Cell{.{
        .codepoint = 0x2764,
        .width = 1,
        .grapheme_id = 1,
    }};
    var source = FakeSource{ .snapshot = .{
        .size = .{ .cols = 1, .rows = 1 },
        .cells = &cells,
        .graphemes = &graphemes,
    } };
    var frame = try project(
        std.testing.allocator,
        source.source(),
        .{ .cols = 1, .rows = 1 },
        std.testing.io,
    );
    defer frame.deinit();
    try std.testing.expect(std.mem.indexOf(u8, frame.bytes, "\xe2\x9d\xa4") == null);
    try std.testing.expect(std.mem.indexOf(u8, frame.bytes, "\xef\xb8\x8f") == null);
    try std.testing.expect(std.mem.indexOf(u8, frame.bytes, "?") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame.bytes, "?\x1b[1;1H") != null);

    const wide_graphemes = [_][]const u21{&.{ 0x200d, 0x1f469 }};
    const wide_cells = [_]terminal.Cell{
        .{ .codepoint = 0x1f468, .width = 2, .grapheme_id = 1 },
        .{ .width = 0, .continuation = true },
    };
    source.snapshot = .{
        .size = .{ .cols = 2, .rows = 1 },
        .cells = &wide_cells,
        .graphemes = &wide_graphemes,
    };
    var wide_frame = try project(
        std.testing.allocator,
        source.source(),
        .{ .cols = 2, .rows = 1 },
        std.testing.io,
    );
    defer wide_frame.deinit();
    try std.testing.expect(std.mem.indexOf(u8, wide_frame.bytes, "\xf0\x9f\x91\xa8") == null);
    try std.testing.expect(std.mem.indexOf(u8, wide_frame.bytes, "\xf0\x9f\x91\xa9") == null);
    try std.testing.expect(std.mem.indexOf(u8, wide_frame.bytes, "?\x1b[1;1H") != null);
}

test "external ansi grapheme aggregate exact cap succeeds cap plus one unlocks before encode" {
    const codepoints = try std.testing.allocator.alloc(u21, max_grapheme_codepoints + 1);
    defer std.testing.allocator.free(codepoints);
    @memset(codepoints, 'x');
    const cells = [_]terminal.Cell{.{ .codepoint = 'x' }};
    var graphemes = [_][]const u21{codepoints[0..max_grapheme_codepoints]};
    var source = FakeSource{
        .snapshot = .{
            .size = .{ .cols = 1, .rows = 1 },
            .cells = &cells,
            // Unreferenced store도 full DTO validation 대상이다.
            .graphemes = &graphemes,
        },
    };
    var frame = try project(
        std.testing.allocator,
        source.source(),
        .{ .cols = 1, .rows = 1 },
        std.testing.io,
    );
    frame.deinit();
    try std.testing.expectEqual(@as(usize, 1), source.locks);
    try std.testing.expectEqual(@as(usize, 1), source.unlocks);

    graphemes[0] = codepoints;
    try std.testing.expectError(
        error.ProtocolError,
        project(
            std.testing.allocator,
            source.source(),
            .{ .cols = 1, .rows = 1 },
            std.testing.io,
        ),
    );
    try std.testing.expectEqual(@as(usize, 2), source.locks);
    try std.testing.expectEqual(@as(usize, 2), source.unlocks);
}

test "external ansi grapheme entry count exact cap succeeds cap plus one fails" {
    try validateGraphemeEntryCount(max_viewport_cells);
    try std.testing.expectError(
        error.ProtocolError,
        validateGraphemeEntryCount(max_viewport_cells + 1),
    );
}

test "external ansi bounded builder admits actual 32 MiB exact and rejects cap plus one" {
    const storage = try std.testing.allocator.alloc(u8, max_repaint_bytes);
    defer std.testing.allocator.free(storage);
    var out = Encoder{
        .limit = max_repaint_bytes,
        .storage = storage,
        .len = max_repaint_bytes - 1,
    };
    try out.append("x");
    try std.testing.expectEqual(max_repaint_bytes, out.len);
    try std.testing.expectError(
        error.FrameTooLarge,
        out.append("y"),
    );
    try std.testing.expectEqual(max_repaint_bytes, out.len);
}

test "external ansi exact frame cap succeeds cap plus one fails and queue owns at most two frames" {
    const cells = [_]terminal.Cell{.{ .codepoint = 'x' }};
    var source = FakeSource{ .snapshot = .{ .size = .{ .cols = 1, .rows = 1 }, .cells = &cells } };
    var baseline = try project(std.testing.allocator, source.source(), .{ .cols = 1, .rows = 1 }, std.testing.io);

    var exact = try projectWithLimit(
        std.testing.allocator,
        source.source(),
        .{ .cols = 1, .rows = 1 },
        std.testing.io,
        baseline.bytes.len,
    );
    try std.testing.expectEqual(baseline.bytes.len, exact.bytes.len);
    try std.testing.expectError(
        error.FrameTooLarge,
        projectWithLimit(
            std.testing.allocator,
            source.source(),
            .{ .cols = 1, .rows = 1 },
            std.testing.io,
            baseline.bytes.len - 1,
        ),
    );
    exact.deinit();
    baseline.deinit();

    var queue = RepaintQueue.init(std.testing.allocator);
    defer queue.deinit();
    var mutable_cells = [_]terminal.Cell{.{ .codepoint = 'a' }};
    source.snapshot = .{ .size = .{ .cols = 1, .rows = 1 }, .cells = &mutable_cells };
    try queue.replaceLatest(source.source(), .{ .cols = 1, .rows = 1 }, std.testing.io, 1);
    mutable_cells[0].codepoint = 'b';
    try queue.replaceLatest(source.source(), .{ .cols = 1, .rows = 1 }, std.testing.io, 2);
    mutable_cells[0].codepoint = 'c';
    try queue.replaceLatest(source.source(), .{ .cols = 1, .rows = 1 }, std.testing.io, 3);
    try std.testing.expect(std.mem.indexOfScalar(u8, queue.current.?.bytes, 'a') != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, queue.latest.?.bytes, 'c') != null);
    try std.testing.expectEqual(queue.current.?.bytes.len, queue.current.?.storage.len);
    try std.testing.expectEqual(queue.latest.?.bytes.len, queue.latest.?.storage.len);
    try std.testing.expect(queue.current.?.storage.len + queue.latest.?.storage.len <= max_resident_bytes);

    // Stale admission은 어떤 owned frame도 회수하거나 새 projection을 시작하지 않는다.
    const locks_before_stale = source.locks;
    try std.testing.expectError(
        error.StaleFrame,
        queue.replaceLatest(source.source(), .{ .cols = 1, .rows = 1 }, std.testing.io, 3),
    );
    try std.testing.expectEqual(locks_before_stale, source.locks);
    try std.testing.expect(std.mem.indexOfScalar(u8, queue.latest.?.bytes, 'c') != null);

    // 새 projection을 만들기 전에 replaceable latest를 먼저 회수한다. 이후 build가 실패해도
    // active current와 ordering sequence는 보존되고 resident에 세 번째 frame이 공존하지 않는다.
    source.snapshot.size.cols = 2;
    try std.testing.expectError(
        error.ProtocolError,
        queue.replaceLatest(source.source(), .{ .cols = 1, .rows = 1 }, std.testing.io, 4),
    );
    try std.testing.expect(queue.latest == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, queue.current.?.bytes, 'a') != null);
    try std.testing.expectEqual(@as(?u64, 3), queue.newest_projection_sequence);

    source.snapshot.size.cols = 1;
    mutable_cells[0].codepoint = 'd';
    try queue.replaceLatest(source.source(), .{ .cols = 1, .rows = 1 }, std.testing.io, 4);
    queue.completeCurrent();
    try std.testing.expect(std.mem.indexOfScalar(u8, queue.current.?.bytes, 'd') != null);
    try std.testing.expect(queue.latest == null);
    queue.completeCurrent();
    try std.testing.expect(queue.current == null);
}

test "external ansi queue OOM drops replaceable latest and preserves current ownership" {
    const cells = [_]terminal.Cell{.{ .codepoint = 'x' }};
    var source = FakeSource{ .snapshot = .{
        .size = .{ .cols = 1, .rows = 1 },
        .cells = &cells,
    } };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var queue = RepaintQueue.init(failing.allocator());
    defer queue.deinit();
    try queue.replaceLatest(source.source(), .{ .cols = 1, .rows = 1 }, std.testing.io, 1);
    try queue.replaceLatest(source.source(), .{ .cols = 1, .rows = 1 }, std.testing.io, 2);
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(
        error.OutOfMemory,
        queue.replaceLatest(source.source(), .{ .cols = 1, .rows = 1 }, std.testing.io, 3),
    );
    try std.testing.expect(queue.current != null);
    try std.testing.expect(queue.latest == null);
    try std.testing.expectEqual(@as(?u64, 2), queue.newest_projection_sequence);
    try std.testing.expectEqual(source.locks, source.unlocks);
}

test "external ansi every allocation failure unlocks source and publishes no partial frame" {
    const cells = [_]terminal.Cell{
        .{ .codepoint = 'a' },
        .{ .codepoint = 'b', .style = .{ .foreground = .{ .indexed = 2 } } },
        .{ .codepoint = 'c' },
    };
    var saw_failure = false;
    var saw_success = false;
    var fail_index: usize = 0;
    while (fail_index < 32) : (fail_index += 1) {
        var source = FakeSource{ .snapshot = .{
            .size = .{ .cols = @intCast(cells.len), .rows = 1 },
            .cells = &cells,
        } };
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        const result = project(
            failing.allocator(),
            source.source(),
            .{ .cols = @intCast(cells.len), .rows = 1 },
            std.testing.io,
        );
        if (result) |frame_value| {
            var frame = frame_value;
            frame.deinit();
            saw_success = true;
            try std.testing.expectEqual(@as(usize, 1), source.locks);
            try std.testing.expectEqual(@as(usize, 1), source.unlocks);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            saw_failure = true;
            try std.testing.expectEqual(@as(usize, 1), source.locks);
            try std.testing.expectEqual(@as(usize, 1), source.unlocks);
        }
    }
    try std.testing.expect(saw_failure);
    try std.testing.expect(saw_success);
}
