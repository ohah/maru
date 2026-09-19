//! IME marked text의 client-local 화면 합성기.
//!
//! PTY/TerminalCore/원격 host 화면은 확정된 바이트만 소유한다. 조합 중인 marked text는 GUI
//! attachment마다 달라질 수 있는 일시 상태이므로 `session.Surface`가 이 타입을 하나씩 소유하고,
//! local/remote가 모두 같은 `RenderSnapshot` 합성 규칙을 쓴다. 합성은 canonical cell grid를
//! 바꾸지 않고 scratch에만 수행한다.

const std = @import("std");
const types = @import("types.zig");
const width = @import("../width.zig");

/// Admission 전 canonical cursor에서 복사한 값 타입. RenderSnapshot의 borrowed cell/grapheme
/// slices를 락 밖으로 가져갈 수 없게 타입 자체에서 제외한다.
pub const CommitBase = struct {
    size: types.Size,
    cursor: types.Cursor,
    viewport_scrolled: bool,
    viewport_scrolled_known: bool,
    ambiguous_wide: bool,

    pub fn fromSnapshot(snapshot: types.RenderSnapshot) CommitBase {
        return .{
            .size = snapshot.size,
            .cursor = snapshot.cursor,
            .viewport_scrolled = snapshot.viewport_scrolled,
            .viewport_scrolled_known = snapshot.viewport_scrolled_known,
            .ambiguous_wide = snapshot.ambiguous_wide,
        };
    }
};

pub const Overlay = struct {
    allocator: std.mem.Allocator,
    text: ?[]u8 = null,
    cells: []types.Cell = &.{},
    pending_advance_cells: u32 = 0,
    pending_anchor: ?Anchor = null,

    const Anchor = struct {
        cursor_linear: u32,
        cols: u16,
        rows: u16,
    };

    pub fn init(allocator: std.mem.Allocator) Overlay {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Overlay) void {
        if (self.text) |owned| self.allocator.free(owned);
        if (self.cells.len > 0) self.allocator.free(self.cells);
        self.* = undefined;
    }

    /// marked text를 교체한다. 새 값은 기존 값을 해제하기 전에 복사하므로 OOM이면 화면에
    /// 보이던 조합 상태가 그대로 남는다. 빈 값은 allocation 없이 즉시 clear한다.
    pub fn replace(self: *Overlay, bytes: []const u8) error{OutOfMemory}!void {
        if (bytes.len == 0) {
            if (self.text) |old| self.allocator.free(old);
            self.text = null;
            self.clearPendingAdvance();
            return;
        }
        const next = try self.allocator.dupe(u8, bytes);
        if (self.text) |old| self.allocator.free(old);
        self.text = next;
    }

    pub fn active(self: *const Overlay) bool {
        return self.text != null;
    }

    pub fn textBytes(self: *const Overlay) []const u8 {
        return self.text orelse "";
    }

    /// 현재 marked text의 소유권을 caller에게 넘기며 원자적으로 비운다. focus-loss 콜백이
    /// 중복되어도 첫 호출만 값을 얻으므로 확정 바이트를 정확히 한 번만 전송할 수 있다.
    pub fn take(self: *Overlay) ?Owned {
        const bytes = self.text orelse return null;
        self.text = null;
        self.clearPendingAdvance();
        return .{ .allocator = self.allocator, .bytes = bytes };
    }

    /// PTY ordered queue가 확정 문자열을 인수했지만 canonical cursor가 아직 움직이지 않았을 때,
    /// 다음 marked text가 방금 확정한 글자를 덮지 않도록 **폭만** 보존한다. 문자열은 저장하거나
    /// 그리지 않으므로 echo가 꺼진 프로그램에서도 입력 내용을 client overlay가 노출하지 않는다.
    pub fn noteCommitted(self: *Overlay, base: CommitBase, bytes: []const u8) void {
        if (!self.active()) return;
        if (!base.viewport_scrolled_known or base.viewport_scrolled or !validCursor(base.size, base.cursor)) {
            self.clearPendingAdvance();
            return;
        }
        _ = self.reconcilePendingAdvance(base.size, base.cursor);

        var advance: u32 = 0;
        var it = (std.unicode.Utf8View.init(bytes) catch {
            self.clearPendingAdvance();
            return;
        }).iterator();
        while (it.nextCodepoint()) |cp| {
            // Cursor motion cannot be inferred from line/control input. Keeping a guessed offset
            // across it would be worse than briefly falling back to the canonical cursor.
            if (cp < 0x20 or cp == 0x7f) {
                self.clearPendingAdvance();
                return;
            }
            advance +|= width.cellWidthAmbiguous(cp, base.ambiguous_wide);
        }
        if (advance == 0) return;

        if (self.pending_anchor == null) {
            self.pending_anchor = .{
                .cursor_linear = cursorLinear(base.size, base.cursor),
                .cols = base.size.cols,
                .rows = base.size.rows,
            };
        }
        self.pending_advance_cells +|= advance;
    }

    /// 최신 base snapshot 위에 marked text를 합성한다. OOM·손상 snapshot·잘못된 UTF-8이면
    /// canonical 화면을 그대로 반환하고 상태는 유지해 다음 frame에서 다시 시도한다.
    pub fn compose(self: *Overlay, base: types.RenderSnapshot) types.RenderSnapshot {
        const preedit_bytes = self.text orelse return base;
        // 스크롤백 뷰포트의 cursor는 live 입력 위치가 아니다. upstream screen source가 live를
        // 안전하게 증명하지 못한 unknown도 canonical 화면을 유지한다. AppSession은
        // known+scrolled일 때만 scroll-to-bottom을 요청한다.
        if (!base.viewport_scrolled_known or base.viewport_scrolled) return base;
        const cols = base.size.cols;
        const rows = base.size.rows;
        if (!validBaseCursor(base)) {
            self.clearPendingAdvance();
            return base;
        }

        const anchor_advance = self.reconcilePendingAdvance(base.size, base.cursor);
        const draw_linear = @as(u64, cursorLinear(base.size, base.cursor)) + @as(u64, anchor_advance);
        const viewport_cells = @as(u64, cols) * @as(u64, rows);
        if (draw_linear >= viewport_cells) return base;
        const row: u16 = @intCast(draw_linear / cols);
        const cursor_col: u16 = @intCast(draw_linear % cols);

        const needed = @as(usize, cols) * @as(usize, rows);
        if (base.cells.len < needed) return base;
        if (self.cells.len != needed) {
            const next = self.allocator.alloc(types.Cell, needed) catch return base;
            if (self.cells.len > 0) self.allocator.free(self.cells);
            self.cells = next;
        }
        @memcpy(self.cells, base.cells[0..needed]);

        var preedit_width: u32 = 0;
        {
            var view = std.unicode.Utf8View.init(preedit_bytes) catch return base;
            var it = view.iterator();
            while (it.nextCodepoint()) |cp| {
                preedit_width += width.cellWidthAmbiguous(cp, base.ambiguous_wide);
            }
        }
        if (preedit_width == 0) return base;

        const row_cells = self.cells[@as(usize, row) * cols ..][0..cols];

        const last_content: ?u16 = blk: {
            var found: ?u16 = null;
            var i: u16 = cursor_col;
            while (i < cols) : (i += 1) {
                if ((row_cells[i].codepoint != ' ' and row_cells[i].codepoint != 0) or row_cells[i].continuation) found = i;
            }
            break :blk found;
        };

        // SGR 2(faint)로만 된 후행 run은 shell/agent의 inline ghost로 취급해 덮어쓴다.
        // 일반 텍스트는 오른쪽으로 밀어 확정 뒤의 삽입 결과를 미리 보여준다.
        const trailing_is_ghost: bool = blk: {
            const lc = last_content orelse break :blk false;
            var saw_dim_content = false;
            var i: u16 = cursor_col;
            while (i <= lc) : (i += 1) {
                const c = row_cells[i];
                if (c.continuation or c.codepoint == ' ' or c.codepoint == 0) continue;
                if (!c.style.dim) break :blk false;
                saw_dim_content = true;
            }
            break :blk saw_dim_content;
        };

        const insert_ok = !trailing_is_ghost and
            @as(u32, cursor_col) + preedit_width <= @as(u32, cols) and
            (last_content == null or @as(u32, last_content.?) + preedit_width < @as(u32, cols));
        if (insert_ok) {
            if (last_content) |lc| {
                const shift: u16 = @intCast(preedit_width);
                @memmove(
                    row_cells[cursor_col + shift .. lc + 1 + shift],
                    row_cells[cursor_col .. lc + 1],
                );
            }
        }

        var style = cursorStyle(row_cells, cursor_col);
        style.reverse = true;
        style.conceal = false;
        var draw_col = cursor_col;
        drawCells(style, preedit_bytes, row_cells, &draw_col, base.ambiguous_wide);

        if (cursor_col > 0 and row_cells[cursor_col - 1].width == 2)
            row_cells[cursor_col - 1] = .{};
        if (draw_col < cols and row_cells[draw_col].continuation)
            row_cells[draw_col] = .{};
        clearTruncatedWideBase(row_cells);

        var composed = base;
        composed.cells = self.cells;
        composed.cursor = .{
            .row = row,
            .col = @min(draw_col, cols - 1),
            .visible = false,
        };
        composed.dirty = .{ .start_row = 0, .end_row = rows - 1 };
        return composed;
    }

    fn reconcilePendingAdvance(self: *Overlay, size: types.Size, cursor: types.Cursor) u32 {
        const anchor = self.pending_anchor orelse return 0;
        if (!validCursor(size, cursor) or anchor.cols != size.cols or anchor.rows != size.rows) {
            self.clearPendingAdvance();
            return 0;
        }
        const current = cursorLinear(size, cursor);
        if (current < anchor.cursor_linear) {
            self.clearPendingAdvance();
            return 0;
        }
        const consumed = current - anchor.cursor_linear;
        if (consumed >= self.pending_advance_cells) {
            self.clearPendingAdvance();
            return 0;
        }
        self.pending_advance_cells -= consumed;
        self.pending_anchor.?.cursor_linear = current;
        return self.pending_advance_cells;
    }

    fn clearPendingAdvance(self: *Overlay) void {
        self.pending_advance_cells = 0;
        self.pending_anchor = null;
    }
};

fn validBaseCursor(base: types.RenderSnapshot) bool {
    return validCursor(base.size, base.cursor);
}

fn validCursor(size: types.Size, cursor: types.Cursor) bool {
    return size.cols > 0 and size.rows > 0 and cursor.row < size.rows and cursor.col < size.cols;
}

fn cursorLinear(size: types.Size, cursor: types.Cursor) u32 {
    return @as(u32, cursor.row) * @as(u32, size.cols) + @as(u32, cursor.col);
}

/// Overlay/Surface 수명과 독립된 marked text 소유권. take 뒤 Surface가 이동·해제돼도 caller가
/// 저장된 allocator로 안전하게 해제할 수 있다.
pub const Owned = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,

    pub fn deinit(self: Owned) void {
        self.allocator.free(self.bytes);
    }
};

fn cursorStyle(row_cells: []const types.Cell, col: u16) types.Style {
    const cell = row_cells[col];
    if (cell.continuation and col > 0) return row_cells[col - 1].style;
    return cell.style;
}

fn drawCells(
    style: types.Style,
    preedit_bytes: []const u8,
    row_cells: []types.Cell,
    draw_col: *u16,
    ambiguous_wide: bool,
) void {
    const cols: u16 = @intCast(row_cells.len);
    var it = (std.unicode.Utf8View.init(preedit_bytes) catch return).iterator();
    while (it.nextCodepoint()) |cp| {
        const cell_width = width.cellWidthAmbiguous(cp, ambiguous_wide);
        if (cell_width == 0) continue;
        if (@as(u32, draw_col.*) + @as(u32, cell_width) > @as(u32, cols)) break;
        row_cells[draw_col.*] = .{ .codepoint = cp, .style = style, .width = cell_width };
        if (cell_width == 2)
            row_cells[draw_col.* + 1] = .{ .style = style, .width = 0, .continuation = true };
        draw_col.* += cell_width;
    }
}

fn clearTruncatedWideBase(row: []types.Cell) void {
    if (row.len == 0) return;
    const last = row.len - 1;
    if (row[last].width == 2 and !row[last].continuation) row[last] = .{};
    var i: usize = 0;
    while (i < row.len) : (i += 1) {
        if (!row[i].continuation) continue;
        if (i == 0 or row[i - 1].width != 2) row[i] = .{};
    }
}

fn baseSnapshot(cells: []const types.Cell, cols: u16, rows: u16, cursor: types.Cursor) types.RenderSnapshot {
    return .{
        .size = .{ .cols = cols, .rows = rows },
        .cursor = cursor,
        .cursor_shape = .bar,
        .cursor_blink = false,
        .cells = cells,
        .last_command_exit = 7,
    };
}

test "preedit overlay inserts Hangul without mutating base and preserves snapshot metadata" {
    var cells = [_]types.Cell{.{}} ** 8;
    cells[0].codepoint = 'a';
    cells[1].codepoint = 'b';
    cells[2].codepoint = 'c';
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    try overlay.replace("한");

    const base = baseSnapshot(&cells, 8, 1, .{ .row = 0, .col = 1 });
    const out = overlay.compose(base);
    try std.testing.expectEqual(@as(u21, 0xD55C), out.cells[1].codepoint);
    try std.testing.expectEqual(@as(u2, 2), out.cells[1].width);
    try std.testing.expect(out.cells[2].continuation);
    try std.testing.expectEqual(@as(u21, 'b'), out.cells[3].codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), cells[1].codepoint);
    try std.testing.expectEqual(types.CursorShape.bar, out.cursor_shape);
    try std.testing.expect(!out.cursor_blink);
    try std.testing.expectEqual(@as(?i32, 7), out.last_command_exit);
}

test "preedit overlay replaces all-dim ghost instead of shifting it" {
    var cells = [_]types.Cell{.{}} ** 6;
    cells[0].codepoint = '>';
    cells[1] = .{ .codepoint = 'g', .style = .{ .dim = true } };
    cells[2] = .{ .codepoint = 'h', .style = .{ .dim = true } };
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    try overlay.replace("x");

    const out = overlay.compose(baseSnapshot(&cells, 6, 1, .{ .row = 0, .col = 1 }));
    try std.testing.expectEqual(@as(u21, 'x'), out.cells[1].codepoint);
    try std.testing.expectEqual(@as(u21, 'h'), out.cells[2].codepoint);
}

test "preedit overlay take is allocation-free and exactly once" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    try overlay.replace("가");
    const owned = overlay.take().?;
    defer owned.deinit();
    try std.testing.expectEqualStrings("가", owned.bytes);
    try std.testing.expect(overlay.take() == null);
}

test "preedit overlay replace keeps the previous marked text on OOM" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var overlay = Overlay.init(failing.allocator());
    defer overlay.deinit();

    try overlay.replace("가");
    try std.testing.expectError(error.OutOfMemory, overlay.replace("나"));
    try std.testing.expectEqualStrings("가", overlay.textBytes());
}

test "preedit overlay compose returns canonical base and retains state on scratch OOM" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var overlay = Overlay.init(failing.allocator());
    defer overlay.deinit();
    try overlay.replace("한");

    var cells = [_]types.Cell{.{}} ** 4;
    cells[0].codepoint = 'a';
    const base = baseSnapshot(&cells, 4, 1, .{ .row = 0, .col = 1 });
    const out = overlay.compose(base);

    try std.testing.expectEqual(@intFromPtr(base.cells.ptr), @intFromPtr(out.cells.ptr));
    try std.testing.expectEqualStrings("한", overlay.textBytes());
}

test "preedit anchor keeps the next Hangul syllable after an admitted unreflected commit" {
    var cells = [_]types.Cell{.{}} ** 8;
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    try overlay.replace("글");

    const base = baseSnapshot(&cells, 8, 1, .{ .row = 0, .col = 0 });
    overlay.noteCommitted(CommitBase.fromSnapshot(base), "한");
    const out = overlay.compose(base);

    // The committed syllable belongs to the PTY and is deliberately not copied into the
    // client-local overlay. Only its two-cell advance positions the next marked syllable.
    try std.testing.expectEqual(@as(u21, 0), out.cells[0].codepoint);
    try std.testing.expectEqual(@as(u21, 0xAE00), out.cells[2].codepoint);
}

test "preedit anchor is consumed by partial and complete base cursor echo" {
    var cells = [_]types.Cell{.{}} ** 10;
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    try overlay.replace("x");

    const initial = baseSnapshot(&cells, 10, 1, .{ .row = 0, .col = 1 });
    overlay.noteCommitted(CommitBase.fromSnapshot(initial), "ab");

    const partial = overlay.compose(baseSnapshot(&cells, 10, 1, .{ .row = 0, .col = 2 }));
    try std.testing.expectEqual(@as(u21, 'x'), partial.cells[3].codepoint);

    const complete = overlay.compose(baseSnapshot(&cells, 10, 1, .{ .row = 0, .col = 3 }));
    try std.testing.expectEqual(@as(u21, 'x'), complete.cells[3].codepoint);
}

test "preedit anchor wraps to the next row" {
    var cells = [_]types.Cell{.{}} ** 8;
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    try overlay.replace("x");

    const base = baseSnapshot(&cells, 4, 2, .{ .row = 0, .col = 3 });
    overlay.noteCommitted(CommitBase.fromSnapshot(base), "ab");
    const out = overlay.compose(base);
    try std.testing.expectEqual(@as(u21, 'x'), out.cells[5].codepoint);
}

test "preedit anchor clears with composition and on non-monotonic cursor movement" {
    var cells = [_]types.Cell{.{}} ** 8;
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    try overlay.replace("x");

    const base = baseSnapshot(&cells, 8, 1, .{ .row = 0, .col = 2 });
    overlay.noteCommitted(CommitBase.fromSnapshot(base), "ab");
    const moved_back = overlay.compose(baseSnapshot(&cells, 8, 1, .{ .row = 0, .col = 1 }));
    try std.testing.expectEqual(@as(u21, 'x'), moved_back.cells[1].codepoint);

    overlay.noteCommitted(CommitBase.fromSnapshot(baseSnapshot(&cells, 8, 1, .{ .row = 0, .col = 2 })), "ab");
    try overlay.replace("");
    try overlay.replace("y");
    const after_clear = overlay.compose(base);
    try std.testing.expectEqual(@as(u21, 'y'), after_clear.cells[2].codepoint);
}

test "preedit anchor fails closed when geometry changes" {
    var cells8 = [_]types.Cell{.{}} ** 8;
    var cells6 = [_]types.Cell{.{}} ** 6;
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    try overlay.replace("x");

    const base = baseSnapshot(&cells8, 8, 1, .{ .row = 0, .col = 1 });
    overlay.noteCommitted(CommitBase.fromSnapshot(base), "ab");
    const resized = overlay.compose(baseSnapshot(&cells6, 6, 1, .{ .row = 0, .col = 1 }));
    try std.testing.expectEqual(@as(u21, 'x'), resized.cells[1].codepoint);
}

test "preedit anchor never survives an unproven live viewport" {
    var cells = [_]types.Cell{.{}} ** 8;
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    try overlay.replace("x");

    const live = baseSnapshot(&cells, 8, 1, .{ .row = 0, .col = 1 });
    overlay.noteCommitted(CommitBase.fromSnapshot(live), "ab");
    var scrolled = live;
    scrolled.viewport_scrolled = true;
    overlay.noteCommitted(CommitBase.fromSnapshot(scrolled), "cd");

    const returned_live = overlay.compose(live);
    try std.testing.expectEqual(@as(u21, 'x'), returned_live.cells[1].codepoint);
}
