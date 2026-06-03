const std = @import("std");
const input = @import("input.zig");
const types = @import("types.zig");

pub const TerminalCore = struct {
    allocator: std.mem.Allocator,
    size: types.Size,
    cursor: types.Cursor = .{},
    cells: []types.Cell,
    dirty: types.DirtyRegion = .{},

    pub fn init(allocator: std.mem.Allocator, size: types.Size) !TerminalCore {
        const cells = try allocator.alloc(types.Cell, cellCount(size));
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
        const next_size: types.Size = .{ .cols = cols, .rows = rows };
        const next_cells = try self.allocator.alloc(types.Cell, cellCount(next_size));
        @memset(next_cells, .{});

        self.allocator.free(self.cells);
        self.size = .{ .cols = cols, .rows = rows };
        self.cells = next_cells;
        self.cursor = .{};
        self.dirty = .{ .start_row = 0, .end_row = if (rows == 0) 0 else rows - 1 };
    }

    pub fn snapshot(self: *const TerminalCore) types.RenderSnapshot {
        return .{
            .size = self.size,
            .cursor = self.cursor,
            .cells = self.cells,
            .dirty = self.dirty,
        };
    }

    pub fn encodeKey(self: *const TerminalCore, event: input.KeyEvent, buffer: *[4]u8) ![]const u8 {
        _ = self;
        return input.encodeKey(event, buffer);
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
            const before = self.cursor.col;
            self.putCell(' ');
            // The current MVP core does not implement automatic line wrapping
            // yet. When the cursor is already at the last column, putCell must
            // keep it there; this guard prevents tab expansion from looping
            // forever until full wrap semantics are designed and tested.
            if (self.cursor.col == before) break;
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

fn cellCount(size: types.Size) usize {
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

test "terminal core tab expansion stops at the row edge" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();

    // This test protects the root cause of a common terminal-core failure:
    // cursor movement that cannot advance must not leave a control sequence in
    // an infinite loop. Full wrap behavior will be specified separately.
    try core.write("a\t");

    const snapshot = core.snapshot();
    try std.testing.expectEqual(@as(u16, 0), snapshot.cursor.row);
    try std.testing.expectEqual(@as(u16, 7), snapshot.cursor.col);
}
