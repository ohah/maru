const std = @import("std");

pub const Size = struct {
    cols: u16,
    rows: u16,

    pub const default: Size = .{ .cols = 80, .rows = 24 };
};

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const Color = union(enum) {
    default,
    indexed: u8,
    rgb: Rgb,
};

pub const Style = struct {
    foreground: Color = .default,
    background: Color = .default,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
};

pub const Cell = struct {
    codepoint: u21 = ' ',
    style: Style = .{},
};

pub const Cursor = struct {
    row: u16 = 0,
    col: u16 = 0,
    visible: bool = true,
};

pub const DirtyRegion = struct {
    start_row: u16 = 0,
    end_row: u16 = 0,
};

pub const RenderSnapshot = struct {
    size: Size,
    cursor: Cursor = .{},
    cells: []const Cell = &.{},
    dirty: DirtyRegion = .{},
};

pub const ModifierSet = packed struct {
    shift: bool = false,
    control: bool = false,
    option: bool = false,
    command: bool = false,
};

pub const Key = union(enum) {
    char: u21,
    enter,
    escape,
    tab,
    backspace,
    arrow_up,
    arrow_down,
    arrow_left,
    arrow_right,
};

pub const KeyEvent = struct {
    key: Key,
    modifiers: ModifierSet = .{},
};

pub const TerminalCore = struct {
    allocator: std.mem.Allocator,
    size: Size,
    cursor: Cursor = .{},
    cells: []Cell,
    dirty: DirtyRegion = .{},

    pub fn init(allocator: std.mem.Allocator, size: Size) !TerminalCore {
        const cells = try allocator.alloc(Cell, cellCount(size));
        @memset(cells, .{});

        return .{
            .allocator = allocator,
            .size = size,
            .cells = cells,
            .dirty = .{ .start_row = 0, .end_row = if (size.rows == 0) 0 else size.rows - 1 },
        };
    }

    pub fn deinit(self: *TerminalCore) void {
        self.allocator.free(self.cells);
        self.* = undefined;
    }

    pub fn write(self: *TerminalCore, bytes: []const u8) !void {
        // The first clean-room core step is intentionally small: convert real
        // UTF-8 process output into cells. Escape-sequence parsing will sit on
        // top of this path later, so E2E tests can start before the full VT
        // state machine exists.
        const view = try std.unicode.Utf8View.init(bytes);
        var iterator = view.iterator();
        while (iterator.nextCodepoint()) |codepoint| {
            self.writeCodepoint(codepoint);
        }
    }

    pub fn resize(self: *TerminalCore, cols: u16, rows: u16) !void {
        const next_size: Size = .{ .cols = cols, .rows = rows };
        const next_cells = try self.allocator.alloc(Cell, cellCount(next_size));
        @memset(next_cells, .{});

        self.allocator.free(self.cells);
        self.size = .{ .cols = cols, .rows = rows };
        self.cells = next_cells;
        self.cursor = .{};
        self.dirty = .{ .start_row = 0, .end_row = if (rows == 0) 0 else rows - 1 };
    }

    pub fn snapshot(self: *const TerminalCore) RenderSnapshot {
        return .{
            .size = self.size,
            .cursor = self.cursor,
            .cells = self.cells,
            .dirty = self.dirty,
        };
    }

    pub fn encodeKey(self: *const TerminalCore, event: KeyEvent, buffer: *[4]u8) ![]const u8 {
        _ = self;
        return switch (event.key) {
            .char => |codepoint| blk: {
                const len = try std.unicode.utf8Encode(codepoint, buffer);
                break :blk buffer[0..len];
            },
            .enter => "\r",
            .escape => "\x1b",
            .tab => "\t",
            .backspace => "\x7f",
            .arrow_up => "\x1b[A",
            .arrow_down => "\x1b[B",
            .arrow_right => "\x1b[C",
            .arrow_left => "\x1b[D",
        };
    }

    pub fn dumpUtf8(self: *const TerminalCore, allocator: std.mem.Allocator) ![]u8 {
        // E2E assertions need a beginner-friendly way to inspect the screen.
        // This helper is deliberately not a renderer; it serializes cells into
        // plain text so tests can say "the screen contains hello" without
        // needing Metal, fonts, or screenshots.
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);

        for (0..self.size.rows) |row| {
            if (row != 0) try output.append(allocator, '\n');
            for (0..self.size.cols) |col| {
                var buffer: [4]u8 = undefined;
                const cell = self.cells[self.index(row, col)];
                const len = try std.unicode.utf8Encode(cell.codepoint, &buffer);
                try output.appendSlice(allocator, buffer[0..len]);
            }
        }

        return output.toOwnedSlice(allocator);
    }

    fn writeCodepoint(self: *TerminalCore, codepoint: u21) void {
        switch (codepoint) {
            '\r' => self.cursor.col = 0,
            '\n' => self.lineFeed(),
            '\t' => self.writeTab(),
            0x08 => {
                if (self.cursor.col > 0) self.cursor.col -= 1;
            },
            else => {
                if (codepoint < 0x20) return;
                self.putCell(codepoint);
            },
        }
    }

    fn writeTab(self: *TerminalCore) void {
        const next_tab = @min(self.size.cols, ((self.cursor.col / 8) + 1) * 8);
        while (self.cursor.col < next_tab) {
            self.putCell(' ');
        }
    }

    fn putCell(self: *TerminalCore, codepoint: u21) void {
        if (self.size.cols == 0 or self.size.rows == 0) return;
        if (self.cursor.col >= self.size.cols) self.cursor.col = self.size.cols - 1;
        if (self.cursor.row >= self.size.rows) self.cursor.row = self.size.rows - 1;

        self.cells[self.index(self.cursor.row, self.cursor.col)] = .{ .codepoint = codepoint };
        self.markDirty(self.cursor.row);

        if (self.cursor.col + 1 < self.size.cols) {
            self.cursor.col += 1;
        }
    }

    fn lineFeed(self: *TerminalCore) void {
        if (self.size.rows == 0) return;
        if (self.cursor.row + 1 < self.size.rows) {
            self.cursor.row += 1;
            self.markDirty(self.cursor.row);
            return;
        }

        self.scrollUpOneLine();
    }

    fn scrollUpOneLine(self: *TerminalCore) void {
        if (self.size.cols == 0 or self.size.rows == 0) return;

        for (1..self.size.rows) |row| {
            const dst_start = self.index(row - 1, 0);
            const src_start = self.index(row, 0);
            @memcpy(
                self.cells[dst_start .. dst_start + self.size.cols],
                self.cells[src_start .. src_start + self.size.cols],
            );
        }

        const last_start = self.index(self.size.rows - 1, 0);
        @memset(self.cells[last_start .. last_start + self.size.cols], .{});
        self.dirty = .{ .start_row = 0, .end_row = self.size.rows - 1 };
    }

    fn markDirty(self: *TerminalCore, row: u16) void {
        if (row < self.dirty.start_row) self.dirty.start_row = row;
        if (row > self.dirty.end_row) self.dirty.end_row = row;
    }

    fn index(self: *const TerminalCore, row: usize, col: usize) usize {
        return row * self.size.cols + col;
    }
};

fn cellCount(size: Size) usize {
    return @as(usize, size.cols) * @as(usize, size.rows);
}

test "terminal core stores size and resizes" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 100, .rows = 30 });
    defer core.deinit();

    try std.testing.expectEqual(@as(u16, 100), core.snapshot().size.cols);

    try core.resize(120, 40);
    const snapshot = core.snapshot();
    try std.testing.expectEqual(@as(u16, 120), snapshot.size.cols);
    try std.testing.expectEqual(@as(u16, 40), snapshot.size.rows);
    try std.testing.expectEqual(@as(usize, 120 * 40), snapshot.cells.len);
}

test "terminal core encodes basic control keys" {
    var core = try TerminalCore.init(std.testing.allocator, Size.default);
    defer core.deinit();

    var buffer: [4]u8 = undefined;

    try std.testing.expectEqualStrings("\r", try core.encodeKey(.{ .key = .enter }, &buffer));
    try std.testing.expectEqualStrings("\x1b[A", try core.encodeKey(.{ .key = .arrow_up }, &buffer));
    try std.testing.expectEqualStrings("\x7f", try core.encodeKey(.{ .key = .backspace }, &buffer));
}

test "terminal core encodes character keys as UTF-8" {
    var core = try TerminalCore.init(std.testing.allocator, Size.default);
    defer core.deinit();

    var buffer: [4]u8 = undefined;

    try std.testing.expectEqualStrings("a", try core.encodeKey(.{ .key = .{ .char = 'a' } }, &buffer));
    try std.testing.expectEqualStrings("한", try core.encodeKey(.{ .key = .{ .char = '한' } }, &buffer));
}

test "terminal core writes process-like text into cells" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 12, .rows = 3 });
    defer core.deinit();

    try core.write("hello\nmaru");

    const text = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "maru") != null);
    try std.testing.expectEqual(@as(u16, 1), core.snapshot().cursor.row);
}
