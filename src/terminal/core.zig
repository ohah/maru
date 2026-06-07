const std = @import("std");
const input = @import("input.zig");
const types = @import("types.zig");
const width = @import("width.zig");

pub const TerminalCore = struct {
    allocator: std.mem.Allocator,
    size: types.Size,
    cursor: types.Cursor = .{},
    cells: []types.Cell,
    dirty: ?types.DirtyRegion = null,
    utf8_tail: [4]u8 = undefined,
    utf8_tail_len: usize = 0,
    // The cell that received the most recent printable codepoint, so a
    // following zero-width combining mark attaches to the real base glyph
    // instead of being guessed from the cursor. The cursor is ambiguous: it
    // advances past the base normally, but parks *on* the base at the last
    // column (no autowrap) and moves to a fresh row after a line feed. Reset
    // by anything that ends the current grapheme run (CR/LF/backspace/resize).
    last_print: ?struct { row: u16, col: u16 } = null,

    pub fn init(allocator: std.mem.Allocator, size: types.Size) !TerminalCore {
        const cells = try allocator.alloc(types.Cell, cellCount(size));
        @memset(cells, .{});

        return .{
            .allocator = allocator,
            .size = size,
            .cells = cells,
            .dirty = fullDirty(size),
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
        var index_: usize = 0;
        while (index_ < bytes.len) {
            if (self.utf8_tail_len != 0) {
                index_ = try self.completePendingUtf8(bytes, index_);
                continue;
            }

            const sequence_len = utf8SequenceLength(bytes[index_]) catch return error.InvalidUtf8;
            const end = index_ + sequence_len;
            if (end > bytes.len) {
                self.storePendingUtf8(bytes[index_..]);
                return;
            }

            const codepoint = decodeUtf8(bytes[index_..end]) catch return error.InvalidUtf8;
            self.writeCodepoint(codepoint);
            index_ = end;
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
        self.dirty = fullDirty(next_size);
        // The new buffer invalidates any remembered print position, and a
        // partial UTF-8 tail captured against the old grid must not leak into
        // the first write after a resize.
        self.last_print = null;
        self.utf8_tail_len = 0;
    }

    pub fn snapshot(self: *const TerminalCore) types.RenderSnapshot {
        return .{
            .size = self.size,
            .cursor = self.cursor,
            .cells = self.cells,
            .dirty = self.dirty,
        };
    }

    pub fn takeDirty(self: *TerminalCore) ?types.DirtyRegion {
        // renderer에는 "이번 변경 범위를 소비했다"는 명시적인 지점이 필요하다.
        // 이 함수가 없으면 모든 snapshot이 영원히 dirty처럼 보여서, dirty redraw
        // 테스트가 한 프레임의 변경 소비 여부를 증명할 수 없다.
        const region = self.dirty;
        self.dirty = null;
        return region;
    }

    pub fn clearDirty(self: *TerminalCore) void {
        // 테스트와 향후 renderer가 "이미 그린 상태"를 만들 때 쓴다.
        // dirty bookkeeping을 TerminalCore 안에 두면 renderer가 내부 상태를
        // 직접 고치는 구조로 새는 것을 막을 수 있다.
        self.dirty = null;
    }

    pub fn encodeKey(self: *const TerminalCore, event: input.KeyEvent, buffer: *[input.encoded_key_buffer_len]u8) ![]const u8 {
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
            const row_start = self.index(row, 0);
            var codepoints: types.RowCodepoints = .{ .cells = self.cells[row_start..][0..self.size.cols] };
            while (codepoints.next()) |codepoint| {
                var buffer: [4]u8 = undefined;
                const len = try std.unicode.utf8Encode(codepoint, &buffer);
                try output.appendSlice(allocator, buffer[0..len]);
            }
        }

        return output.toOwnedSlice(allocator);
    }

    fn writeCodepoint(self: *TerminalCore, codepoint: u21) void {
        switch (codepoint) {
            '\r' => {
                const old_cursor = self.cursor;
                self.cursor.col = 0;
                self.markCursorMoveDirty(old_cursor, self.cursor);
                self.last_print = null;
            },
            '\n' => {
                self.lineFeed();
                self.last_print = null;
            },
            '\t' => self.writeTab(),
            0x08 => {
                const old_cursor = self.cursor;
                if (self.cursor.col > 0) self.cursor.col -= 1;
                // Stepping onto a wide glyph's continuation cell would strand
                // the cursor inside the glyph, so a following write would clear
                // its leading half and leave a gap. Move to the leading cell so
                // the next write replaces the whole glyph cleanly.
                if (self.cursor.col > 0 and
                    self.cells[self.index(self.cursor.row, self.cursor.col)].continuation)
                {
                    self.cursor.col -= 1;
                }
                self.markCursorMoveDirty(old_cursor, self.cursor);
                self.last_print = null;
            },
            else => {
                if (codepoint < 0x20) return;
                if (width.cellWidth(codepoint) == 0) {
                    self.attachCombiningMark(codepoint);
                    return;
                }
                self.putCell(codepoint);
            },
        }
    }

    fn completePendingUtf8(self: *TerminalCore, bytes: []const u8, index_: usize) !usize {
        const sequence_len = utf8SequenceLength(self.utf8_tail[0]) catch {
            self.utf8_tail_len = 0;
            return error.InvalidUtf8;
        };
        const needed = sequence_len - self.utf8_tail_len;
        const available = bytes.len - index_;
        const take = @min(needed, available);

        @memcpy(
            self.utf8_tail[self.utf8_tail_len .. self.utf8_tail_len + take],
            bytes[index_ .. index_ + take],
        );
        self.utf8_tail_len += take;

        if (self.utf8_tail_len < sequence_len) return bytes.len;

        const codepoint = decodeUtf8(self.utf8_tail[0..sequence_len]) catch {
            self.utf8_tail_len = 0;
            return error.InvalidUtf8;
        };
        self.utf8_tail_len = 0;
        self.writeCodepoint(codepoint);
        return index_ + take;
    }

    fn storePendingUtf8(self: *TerminalCore, bytes: []const u8) void {
        // PTY reads can stop in the middle of a codepoint. Keeping the partial
        // bytes inside TerminalCore preserves the layer boundary: PTY remains a
        // byte transport and does not need text-decoding logic.
        @memcpy(self.utf8_tail[0..bytes.len], bytes);
        self.utf8_tail_len = bytes.len;
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

        const row = self.cursor.row;
        const col = self.cursor.col;
        const requested_width = width.cellWidth(codepoint);
        // Without DECAWM/autowrap, a wide glyph cannot be represented at the
        // last column. For this early core stage we degrade that edge case to a
        // single visible cell instead of writing past the row. Normal in-row
        // wide glyphs still get a continuation cell.
        const cell_width: u2 = if (requested_width == 2 and col + 1 >= self.size.cols) 1 else requested_width;

        self.clearCellForWrite(row, col);
        if (cell_width == 2) self.clearCellForWrite(row, col + 1);

        self.cells[self.index(row, col)] = .{
            .codepoint = codepoint,
            .width = cell_width,
        };
        if (cell_width == 2) {
            self.cells[self.index(row, col + 1)] = .{
                .width = 0,
                .continuation = true,
            };
        }
        self.last_print = .{ .row = row, .col = col };
        self.markDirty(self.cursor.row);

        if (self.cursor.col + cell_width < self.size.cols) {
            self.cursor.col += cell_width;
        } else {
            self.cursor.col = self.size.cols - 1;
        }
    }

    fn attachCombiningMark(self: *TerminalCore, codepoint: u21) void {
        // A combining mark is zero-width and belongs to the most recently
        // printed base cell, wherever the cursor ended up. Deriving the base
        // from the cursor was wrong at the last column (cursor parks on the
        // base, so cursor-1 pointed at the previous glyph) and after a line
        // feed (cursor sat over a blank cell on the new row). With no base on
        // the current run (stream start, or right after CR/LF), the mark has
        // nothing to attach to and is dropped.
        const last = self.last_print orelse return;
        self.cells[self.index(last.row, last.col)].combining = codepoint;
        self.markDirty(last.row);
    }

    fn clearCellForWrite(self: *TerminalCore, row: u16, col: u16) void {
        const cell_index = self.index(row, col);
        const cell = self.cells[cell_index];
        if (cell.continuation and col > 0) {
            const previous_index = self.index(row, col - 1);
            if (self.cells[previous_index].width == 2) {
                self.cells[previous_index] = .{};
            }
        }
        if (cell.width == 2 and col + 1 < self.size.cols) {
            self.cells[self.index(row, col + 1)] = .{};
        }
        self.cells[cell_index] = .{};
    }

    fn lineFeed(self: *TerminalCore) void {
        if (self.size.rows == 0) return;
        if (self.cursor.row + 1 < self.size.rows) {
            const old_cursor = self.cursor;
            self.cursor.row += 1;
            self.markCursorMoveDirty(old_cursor, self.cursor);
            return;
        }

        // The scroll path repaints every row via fullDirty, so the bottom-row
        // cursor is already covered without a cursor-move diff.
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
        self.dirty = fullDirty(self.size);
    }

    fn markDirty(self: *TerminalCore, row: u16) void {
        if (self.dirty) |*dirty| {
            if (row < dirty.start_row) dirty.start_row = row;
            if (row > dirty.end_row) dirty.end_row = row;
            return;
        }

        self.dirty = .{ .start_row = row, .end_row = row };
    }

    fn markCursorMoveDirty(self: *TerminalCore, old_cursor: types.Cursor, new_cursor: types.Cursor) void {
        // Cursor is drawn as an overlay, not as part of the cell glyph bitmap.
        // Moving it still changes pixels: the old cursor cell must be erased
        // and the new cursor cell must be drawn. Keeping that dirty decision in
        // TerminalCore prevents a future renderer from guessing dirty rows by
        // comparing snapshots on its own.
        if (old_cursor.row == new_cursor.row and
            old_cursor.col == new_cursor.col and
            old_cursor.visible == new_cursor.visible)
        {
            return;
        }

        if (old_cursor.visible) self.markCursorRowDirty(old_cursor.row);
        if (new_cursor.visible) self.markCursorRowDirty(new_cursor.row);
    }

    fn markCursorRowDirty(self: *TerminalCore, row: u16) void {
        if (self.size.rows == 0) return;
        self.markDirty(@min(row, self.size.rows - 1));
    }

    fn index(self: *const TerminalCore, row: usize, col: usize) usize {
        return row * self.size.cols + col;
    }
};

fn utf8SequenceLength(first_byte: u8) !usize {
    return std.unicode.utf8ByteSequenceLength(first_byte) catch error.InvalidUtf8;
}

fn decodeUtf8(bytes: []const u8) !u21 {
    return std.unicode.utf8Decode(bytes) catch error.InvalidUtf8;
}

fn cellCount(size: types.Size) usize {
    return @as(usize, size.cols) * @as(usize, size.rows);
}

fn fullDirty(size: types.Size) ?types.DirtyRegion {
    if (size.rows == 0 or size.cols == 0) return null;
    return .{ .start_row = 0, .end_row = size.rows - 1 };
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

test "terminal core preserves UTF-8 split across process read boundaries" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 12, .rows = 2 });
    defer core.deinit();

    // PTY reads are byte streams, not UTF-8 string messages. A Korean
    // character can arrive as one byte in one read and the remaining bytes in
    // the next read; TerminalCore owns this tail buffering so PTY code does
    // not need to understand text encoding.
    const korean = "한";
    try core.write(korean[0..1]);
    try std.testing.expectEqual(@as(u16, 0), core.snapshot().cursor.col);

    try core.write(korean[1..]);
    try core.write("글");

    const text = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "한글") != null);
    try std.testing.expectEqual(@as(u16, 0), core.snapshot().cursor.row);
    try std.testing.expectEqual(@as(u16, 4), core.snapshot().cursor.col);
}

test "terminal core preserves four-byte UTF-8 split across multiple writes" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 12, .rows = 2 });
    defer core.deinit();

    const rocket = "🚀";
    try core.write("go ");
    try core.write(rocket[0..1]);
    try core.write(rocket[1..3]);
    try core.write(rocket[3..]);

    const text = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "go 🚀") != null);
    try std.testing.expectEqual(@as(u16, 5), core.snapshot().cursor.col);
}

test "terminal core stores wide characters with continuation cells" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 1 });
    defer core.deinit();

    // A terminal grid advances by cells, not by UTF-8 byte length or font
    // advance. Korean/CJK characters occupy two cells, and the second cell
    // must be marked as a continuation so cursor movement, snapshots, and the
    // future renderer do not treat it as a separate printable character.
    try core.write("A한B");

    const snapshot = core.snapshot();
    try std.testing.expectEqual(@as(u16, 4), snapshot.cursor.col);
    try std.testing.expectEqual(@as(u21, 'A'), snapshot.cells[0].codepoint);
    try std.testing.expectEqual(@as(u2, 1), snapshot.cells[0].width);
    try std.testing.expect(!snapshot.cells[0].continuation);
    try std.testing.expectEqual(@as(u21, '한'), snapshot.cells[1].codepoint);
    try std.testing.expectEqual(@as(u2, 2), snapshot.cells[1].width);
    try std.testing.expect(!snapshot.cells[1].continuation);
    try std.testing.expect(snapshot.cells[2].continuation);
    try std.testing.expectEqual(@as(u2, 0), snapshot.cells[2].width);
    try std.testing.expectEqual(@as(u21, 'B'), snapshot.cells[3].codepoint);

    const text = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "A한B") != null);
}

test "terminal core attaches a combining mark without advancing the cursor" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // Combining marks are zero-width. They belong to the previous printable
    // cell and must not move the cursor, otherwise prompts and editor grids
    // drift when accents or other marks appear.
    try core.write("e\u{0301}x");

    const snapshot = core.snapshot();
    try std.testing.expectEqual(@as(u16, 2), snapshot.cursor.col);
    try std.testing.expectEqual(@as(u21, 'e'), snapshot.cells[0].codepoint);
    try std.testing.expectEqual(@as(u21, 0x0301), snapshot.cells[0].combining.?);
    try std.testing.expectEqual(@as(u21, 'x'), snapshot.cells[1].codepoint);

    const text = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "e\u{0301}x") != null);
}

test "terminal core attaches a combining mark to a base char in the last column" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 3, .rows = 1 });
    defer core.deinit();

    // Without autowrap the cursor parks *on* the base glyph when it lands in
    // the last column, so deriving the base from cursor-1 attached the accent
    // to the previous cell. The mark must land on the actual last-printed cell.
    try core.write("abe\u{0301}");

    const snapshot = core.snapshot();
    try std.testing.expectEqual(@as(u21, 'b'), snapshot.cells[1].codepoint);
    try std.testing.expect(snapshot.cells[1].combining == null);
    try std.testing.expectEqual(@as(u21, 'e'), snapshot.cells[2].codepoint);
    try std.testing.expectEqual(@as(u21, 0x0301), snapshot.cells[2].combining.?);

    const text = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "abe\u{0301}") != null);
}

test "terminal core drops a combining mark with no base on the current row" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();

    // A line feed ends the grapheme run and does not reset the column, so the
    // cursor sits over a blank cell on the new row. A combining mark there has
    // no base and must be dropped instead of accenting that blank cell.
    try core.write("A\n\u{0301}");

    const snapshot = core.snapshot();
    try std.testing.expectEqual(@as(u21, 'A'), snapshot.cells[0].codepoint);
    try std.testing.expect(snapshot.cells[0].combining == null);
    for (snapshot.cells) |cell| try std.testing.expect(cell.combining == null);
}

test "terminal core backspaces over a wide glyph onto its leading cell" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // Backspace lands one column left, which is a wide glyph's continuation
    // cell. Parking there would make the next write clear the leading half and
    // leave a gap; instead the cursor steps to the leading cell so the write
    // replaces the whole glyph cleanly.
    try core.write("한\u{08}X");

    const snapshot = core.snapshot();
    try std.testing.expectEqual(@as(u21, 'X'), snapshot.cells[0].codepoint);
    try std.testing.expect(!snapshot.cells[0].continuation);
    try std.testing.expect(!snapshot.cells[1].continuation);
    try std.testing.expectEqual(@as(u16, 1), snapshot.cursor.col);

    const text = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "한") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "X") != null);
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

test "terminal core lets renderer consume dirty region once" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();

    const initial_dirty = core.takeDirty().?;
    try std.testing.expectEqual(@as(u16, 0), initial_dirty.start_row);
    try std.testing.expectEqual(@as(u16, 1), initial_dirty.end_row);
    try std.testing.expect(core.takeDirty() == null);

    try core.write("x");

    const next_dirty = core.takeDirty().?;
    try std.testing.expectEqual(@as(u16, 0), next_dirty.start_row);
    try std.testing.expectEqual(@as(u16, 0), next_dirty.end_row);
    try std.testing.expect(core.snapshot().dirty == null);
}

test "terminal core leaves frame clean when a cursor-only control does not move" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // At column 0 a carriage return and a backspace change nothing: the cursor
    // is already there. markCursorMoveDirty must early-return so the renderer
    // does not redraw a row whose pixels are unchanged.
    core.clearDirty();
    try core.write("\r");
    try std.testing.expect(core.takeDirty() == null);

    core.clearDirty();
    try core.write("\x08");
    try std.testing.expect(core.takeDirty() == null);
}

test "terminal core marks cursor-only movement dirty for cursor overlay redraw" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();

    // Carriage return changes only the cursor position. It still needs a
    // dirty row because the renderer must erase the old cursor overlay and
    // draw the new one even when no cell text changed.
    try core.write("AB");
    core.clearDirty();
    try core.write("\r");

    const cr_dirty = core.takeDirty().?;
    try std.testing.expectEqual(@as(u16, 0), cr_dirty.start_row);
    try std.testing.expectEqual(@as(u16, 0), cr_dirty.end_row);
    try std.testing.expectEqual(@as(u16, 0), core.snapshot().cursor.col);

    // Backspace is the same class of visual change: the glyph grid can stay
    // intact while the cursor overlay moves one cell left.
    try core.write("AB");
    core.clearDirty();
    try core.write("\x08");

    const bs_dirty = core.takeDirty().?;
    try std.testing.expectEqual(@as(u16, 0), bs_dirty.start_row);
    try std.testing.expectEqual(@as(u16, 0), bs_dirty.end_row);
    try std.testing.expectEqual(@as(u16, 1), core.snapshot().cursor.col);
}

test "terminal core marks old and new cursor rows dirty across line feed" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();

    // A line feed moves the cursor to a different row without necessarily
    // changing cell text. Both rows are dirty because one loses the cursor
    // overlay and the other gains it.
    try core.write("A");
    core.clearDirty();
    try core.write("\n");

    const dirty = core.takeDirty().?;
    try std.testing.expectEqual(@as(u16, 0), dirty.start_row);
    try std.testing.expectEqual(@as(u16, 1), dirty.end_row);
    try std.testing.expectEqual(@as(u16, 1), core.snapshot().cursor.row);
}
