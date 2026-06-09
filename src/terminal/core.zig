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
    // 현재 SGR 스타일(pen). printable cell을 쓸 때마다 stamp한다. CSI ... m 이 갱신한다.
    pen: types.Style = .{},
    // VT escape 파서 상태기계. ground 외 상태에서는 byte를 escape sequence로 소비한다.
    parser: ParserState = .ground,
    // CSI 파라미터 누적 버퍼. 대부분의 시퀀스는 파라미터가 적으므로 작은 고정 크기로 충분하고,
    // 넘치면 무시한다(악성/비정상 입력 방어).
    csi_params: [max_csi_params]u16 = [_]u16{0} ** max_csi_params,
    csi_param_count: usize = 0,
    csi_has_digit: bool = false,
    csi_private: bool = false,
    csi_overflow: bool = false,
    // deferred autowrap(DECAWM, 기본 켜짐). 마지막 칸을 채운 직후 커서는 그 칸에 머물고 이 플래그가
    // 선다. 다음 printable 글자가 먼저 다음 줄 첫 칸으로 넘어간 뒤 그려진다. 마지막 칸이 그 줄의
    // 끝 글자면 wrap하지 않으려고(끝 글자마다 빈 줄이 끼지 않게) 즉시가 아니라 "다음 글자에서"
    // 넘긴다. 명시적 커서 이동(CR/LF/backspace/커서 위치 지정/resize)은 이 상태를 무효화한다.
    pending_wrap: bool = false,
    // soft-wrap 추적: wrapped[r]=true면 행 r의 내용이 autowrap으로 행 r+1에 이어진다(논리적으로 한
    // 줄). resize reflow가 이 플래그로 연속 줄을 합쳐 새 폭에 다시 wrap한다. autowrap이 일어나면
    // 떠나는 행을 true로, 그 행에 글자를 쓰면(줄을 새로 그리면) false로 되돌린다. cells와 함께
    // 할당/해제되며 길이는 rows다.
    wrapped: []bool = &.{},
    // 각 CSI 파라미터가 ';'(새 파라미터)가 아니라 ':'(sub-parameter)로 들어왔는지 표시한다.
    // ITU colon 형식 38:2:colorspace:r:g:b는 38;2;r;g;b와 달리 colorspace 컴포넌트가 하나 더
    // 있어, 이 구분 없이는 RGB가 한 칸 밀린다.
    csi_subparam: [max_csi_params]bool = [_]bool{false} ** max_csi_params,

    pub const ParserState = enum { ground, escape, escape_intermediate, csi, osc, osc_escape };

    const max_csi_params = 16;

    pub fn init(allocator: std.mem.Allocator, size: types.Size) !TerminalCore {
        const grid = clampGridSize(size);
        const cells = try allocator.alloc(types.Cell, cellCount(grid));
        @memset(cells, .{});
        const wrapped = try allocator.alloc(bool, grid.rows);
        @memset(wrapped, false);

        return .{
            .allocator = allocator,
            .size = grid,
            .cells = cells,
            .wrapped = wrapped,
            .dirty = fullDirty(grid),
        };
    }

    pub fn deinit(self: *TerminalCore) void {
        self.allocator.free(self.cells);
        self.allocator.free(self.wrapped);
        self.* = undefined;
    }

    pub fn write(self: *TerminalCore, bytes: []const u8) !void {
        // Process output bytes through a small VT escape-sequence state machine
        // (planned in implementation-plan.md: expand the parser only as the
        // shell path needs). ground state still converts UTF-8 to cells; ESC
        // switches into escape/CSI/OSC handling so shell prompt color/cursor
        // sequences are interpreted instead of printed as literal text. State
        // persists across write() calls, so sequences split across PTY reads
        // are handled.
        var index_: usize = 0;
        while (index_ < bytes.len) {
            switch (self.parser) {
                .ground => {
                    if (self.utf8_tail_len != 0) {
                        index_ = try self.completePendingUtf8(bytes, index_);
                        continue;
                    }
                    const byte = bytes[index_];
                    if (byte == 0x1b) {
                        self.parser = .escape;
                        index_ += 1;
                        continue;
                    }

                    const sequence_len = utf8SequenceLength(byte) catch return error.InvalidUtf8;
                    const end = index_ + sequence_len;
                    if (end > bytes.len) {
                        self.storePendingUtf8(bytes[index_..]);
                        return;
                    }

                    const codepoint = decodeUtf8(bytes[index_..end]) catch return error.InvalidUtf8;
                    self.writeCodepoint(codepoint);
                    index_ = end;
                },
                .escape => {
                    self.handleEscapeByte(bytes[index_]);
                    index_ += 1;
                },
                .escape_intermediate => {
                    // ESC <intermediate> <final>: charset designators 등. final 1바이트를
                    // 소비하고 ground로 돌아간다(A1은 적용하지 않고 소비만 한다).
                    self.parser = .ground;
                    index_ += 1;
                },
                .csi => {
                    self.handleCsiByte(bytes[index_]);
                    index_ += 1;
                },
                .osc => {
                    const byte = bytes[index_];
                    // OSC string은 BEL(0x07) 또는 ST(ESC \)로 끝난다. A1은 내용(title 등)을
                    // 적용하지 않고 소비만 한다.
                    if (byte == 0x07) {
                        self.parser = .ground;
                    } else if (byte == 0x1b) {
                        self.parser = .osc_escape;
                    }
                    index_ += 1;
                },
                .osc_escape => {
                    // OSC 안에서 ESC 다음 바이트. ST(ESC \)든 아니든 OSC를 끝낸다(관대 처리).
                    self.parser = .ground;
                    index_ += 1;
                },
            }
        }
    }

    fn handleEscapeByte(self: *TerminalCore, byte: u8) void {
        switch (byte) {
            '[' => {
                self.beginCsi();
                self.parser = .csi;
            },
            ']' => self.parser = .osc,
            // ESC <intermediate>(0x20..0x2f) <final>: charset designation 등 2바이트 시퀀스.
            0x20...0x2f => self.parser = .escape_intermediate,
            // 그 밖의 ESC <final>(RIS, DECSC/DECRC, index 등)은 A1에서 소비만 한다.
            else => self.parser = .ground,
        }
    }

    fn beginCsi(self: *TerminalCore) void {
        self.csi_params = [_]u16{0} ** max_csi_params;
        self.csi_subparam = [_]bool{false} ** max_csi_params;
        // 항상 최소 1개의 (비어 있을 수도 있는) 파라미터가 있다고 본다.
        self.csi_param_count = 1;
        self.csi_has_digit = false;
        self.csi_private = false;
        self.csi_overflow = false;
    }

    /// ';'(is_sub=false)나 ':'(is_sub=true)로 다음 파라미터 슬롯을 연다. ':'로 연 슬롯은
    /// sub-parameter로 표시해, 38/48 확장 색의 colon 형식을 세미콜론 형식과 구분한다.
    fn csiNextParam(self: *TerminalCore, is_sub: bool) void {
        if (self.csi_param_count >= max_csi_params) {
            self.csi_overflow = true;
        } else {
            self.csi_param_count += 1;
            self.csi_subparam[self.csi_param_count - 1] = is_sub;
        }
        self.csi_has_digit = false;
    }

    fn handleCsiByte(self: *TerminalCore, byte: u8) void {
        switch (byte) {
            '0'...'9' => {
                self.csi_has_digit = true;
                // 파라미터가 max(16)를 넘으면(';'가 csi_overflow를 세움) 이후 자릿수는 버린다.
                // 안 그러면 17번째+ 파라미터의 숫자가 params[15]에 누적돼 마지막 파라미터를
                // 오염시킨다.
                if (self.csi_overflow) return;
                const slot = self.csi_param_count - 1;
                const digit: u16 = byte - '0';
                const value = self.csi_params[slot];
                // saturating: 손상/악성 입력이 u16을 넘기지 않게 한다.
                self.csi_params[slot] = if (value > (std.math.maxInt(u16) - digit) / 10)
                    std.math.maxInt(u16)
                else
                    value * 10 + digit;
            },
            // ';'는 파라미터 구분자, ':'는 sub-parameter 구분자다. 둘 다 다음 슬롯을 열되,
            // ':'로 연 슬롯은 sub-parameter로 표시해 colon 확장색 형식을 구분한다.
            ';' => self.csiNextParam(false),
            ':' => self.csiNextParam(true),
            // private/marker bytes: < = > ? (예: CSI ? 25 h). A1은 private 시퀀스를 소비만 한다.
            0x3c...0x3f => self.csi_private = true,
            // intermediate bytes(공백~/)는 A1에서 무시한다.
            0x20...0x2f => {},
            // final byte: 시퀀스를 dispatch하고 ground로 돌아간다.
            0x40...0x7e => {
                self.dispatchCsi(byte);
                self.parser = .ground;
            },
            // ESC는 진행 중인 CSI를 취소하고 새 escape를 시작한다(VT abort-and-restart). 안 하면
            // ESC[ ESC[31m 같은 입력에서 두 번째 시퀀스가 글자로 샌다.
            0x1b => self.parser = .escape,
            // CSI 안의 C0 control(ESC 제외)은 실행하고 CSI 파싱을 계속한다(VT spec). writeCodepoint가
            // CR/LF/Tab/BS를 처리하고 나머지 C0는 버린다. parser는 .csi로 유지된다.
            0x00...0x1a, 0x1c...0x1f => self.writeCodepoint(byte),
            // 그 밖(DEL/high byte)은 CSI를 중단하고 소비한다(관대 처리).
            else => self.parser = .ground,
        }
    }

    /// i번째 CSI 파라미터를 raw로 돌려준다(없으면 0). erase mode처럼 0이 유효값인 곳에 쓴다.
    fn csiRawParam(self: *const TerminalCore, i: usize) u16 {
        const count = @min(self.csi_param_count, max_csi_params);
        return if (i >= count) 0 else self.csi_params[i];
    }

    /// i번째 CSI 파라미터(없거나 0이면 default). cursor move처럼 0을 1로 보는 곳에 쓴다.
    fn csiParam(self: *const TerminalCore, i: usize, default: u16) u16 {
        const value = self.csiRawParam(i);
        return if (value == 0) default else value;
    }

    fn dispatchCsi(self: *TerminalCore, final: u8) void {
        // private 시퀀스(CSI ? ...: DECSET/DECRST 등)는 A1에서 적용하지 않고 소비만 한다.
        if (self.csi_private) return;
        switch (final) {
            'm' => self.applySgr(),
            'H', 'f' => self.cursorPosition(),
            'A' => self.cursorVertical(self.csiParam(0, 1), true),
            'B', 'e' => self.cursorVertical(self.csiParam(0, 1), false),
            'C', 'a' => self.cursorHorizontal(self.csiParam(0, 1), true),
            'D' => self.cursorHorizontal(self.csiParam(0, 1), false),
            'G', '`' => self.cursorToColumn(self.csiParam(0, 1)),
            'd' => self.cursorToRow(self.csiParam(0, 1)),
            'J' => self.eraseInDisplay(self.csiRawParam(0)),
            'K' => self.eraseInLine(self.csiRawParam(0)),
            else => {},
        }
    }

    fn applySgr(self: *TerminalCore) void {
        const count = @min(self.csi_param_count, max_csi_params);
        var i: usize = 0;
        while (i < count) {
            const p = self.csi_params[i];
            switch (p) {
                0 => self.pen = .{},
                1 => self.pen.bold = true,
                3 => self.pen.italic = true,
                4 => self.pen.underline = true,
                22 => self.pen.bold = false,
                23 => self.pen.italic = false,
                24 => self.pen.underline = false,
                30...37 => self.pen.foreground = .{ .indexed = @intCast(p - 30) },
                39 => self.pen.foreground = .default,
                40...47 => self.pen.background = .{ .indexed = @intCast(p - 40) },
                49 => self.pen.background = .default,
                90...97 => self.pen.foreground = .{ .indexed = @intCast(p - 90 + 8) },
                100...107 => self.pen.background = .{ .indexed = @intCast(p - 100 + 8) },
                38 => {
                    i = self.applyExtendedColor(i, true);
                    continue;
                },
                48 => {
                    i = self.applyExtendedColor(i, false);
                    continue;
                },
                else => {},
            }
            i += 1;
        }
    }

    /// 38/48 (확장 색)을 처리하고 다음으로 읽을 파라미터 인덱스를 돌려준다. 세미콜론
    /// (38;2;r;g;b, 38;5;n)과 colon sub-parameter(38:2:colorspace:r:g:b, 38:5:n)를 모두 지원한다.
    fn applyExtendedColor(self: *TerminalCore, start: usize, foreground: bool) usize {
        const count = @min(self.csi_param_count, max_csi_params);
        const mode = if (start + 1 < count) self.csi_params[start + 1] else 0;
        // mode가 ':'로 들어왔으면 colon 형식이다. colon mode 2는 r,g,b 앞에 colorspace
        // 컴포넌트가 하나 더 있다(빈 경우 '::'). mode 5는 두 형식 모두 n 위치가 같다.
        const colon_form = start + 1 < count and self.csi_subparam[start + 1];
        if (mode == 5 and start + 2 < count) {
            const color: types.Color = .{ .indexed = @intCast(@min(self.csi_params[start + 2], 255)) };
            if (foreground) self.pen.foreground = color else self.pen.background = color;
            return start + 3;
        }
        if (mode == 2) {
            if (colon_form) {
                // colon 형식은 mode 뒤의 colon sub-parameter가 [r,g,b](3개) 또는
                // [colorspace,r,g,b](4개, colorspace는 빈 '::'일 수 있음)다. colorspace가
                // 있는지 개수로 정해진 게 아니므로(38:2:r:g:b처럼 생략 가능) mode 뒤 colon
                // 컴포넌트 수를 세어, r,g,b는 항상 마지막 3개로 읽는다. 이전에는 colorspace가
                // 항상 있다고 가정해 38:2:r:g:b(5컴포넌트)를 통째로 버렸다.
                var n: usize = 0;
                while (start + 2 + n < count and self.csi_subparam[start + 2 + n]) : (n += 1) {}
                if (n >= 3) {
                    const rgb_start = start + 2 + (n - 3);
                    const color: types.Color = .{ .rgb = .{
                        .r = @intCast(@min(self.csi_params[rgb_start], 255)),
                        .g = @intCast(@min(self.csi_params[rgb_start + 1], 255)),
                        .b = @intCast(@min(self.csi_params[rgb_start + 2], 255)),
                    } };
                    if (foreground) self.pen.foreground = color else self.pen.background = color;
                    return start + 2 + n;
                }
            } else if (start + 4 < count) {
                // 세미콜론 형식 38;2;r;g;b — r,g,b가 mode 바로 뒤.
                const color: types.Color = .{ .rgb = .{
                    .r = @intCast(@min(self.csi_params[start + 2], 255)),
                    .g = @intCast(@min(self.csi_params[start + 3], 255)),
                    .b = @intCast(@min(self.csi_params[start + 4], 255)),
                } };
                if (foreground) self.pen.foreground = color else self.pen.background = color;
                return start + 5;
            }
        }
        // 형식이 안 맞으면 나머지 파라미터를 버린다.
        return count;
    }

    fn cursorPosition(self: *TerminalCore) void {
        if (self.size.rows == 0 or self.size.cols == 0) return;
        const old = self.cursor;
        const row = self.csiParam(0, 1);
        const col = self.csiParam(1, 1);
        self.cursor.row = @intCast(@min(@as(u32, row) - 1, @as(u32, self.size.rows) - 1));
        self.cursor.col = @intCast(@min(@as(u32, col) - 1, @as(u32, self.size.cols) - 1));
        self.markCursorMoveDirty(old, self.cursor);
        self.last_print = null;
    }

    fn cursorVertical(self: *TerminalCore, amount: u16, up: bool) void {
        if (self.size.rows == 0) return;
        const old = self.cursor;
        if (up) {
            self.cursor.row -|= amount;
        } else {
            const max_row = self.size.rows - 1;
            self.cursor.row = @intCast(@min(@as(u32, self.cursor.row) + amount, max_row));
        }
        self.markCursorMoveDirty(old, self.cursor);
        self.last_print = null;
    }

    fn cursorHorizontal(self: *TerminalCore, amount: u16, right: bool) void {
        if (self.size.cols == 0) return;
        const old = self.cursor;
        if (right) {
            const max_col = self.size.cols - 1;
            self.cursor.col = @intCast(@min(@as(u32, self.cursor.col) + amount, max_col));
        } else {
            self.cursor.col -|= amount;
        }
        self.markCursorMoveDirty(old, self.cursor);
        self.last_print = null;
    }

    fn cursorToColumn(self: *TerminalCore, col: u16) void {
        if (self.size.cols == 0) return;
        const old = self.cursor;
        self.cursor.col = @intCast(@min(@as(u32, col) - 1, @as(u32, self.size.cols) - 1));
        self.markCursorMoveDirty(old, self.cursor);
        self.last_print = null;
    }

    fn cursorToRow(self: *TerminalCore, row: u16) void {
        if (self.size.rows == 0) return;
        const old = self.cursor;
        self.cursor.row = @intCast(@min(@as(u32, row) - 1, @as(u32, self.size.rows) - 1));
        self.markCursorMoveDirty(old, self.cursor);
        self.last_print = null;
    }

    /// erase로 [start, end) 범위를 비울 때, 경계에 걸친 wide glyph(width=2)의 반쪽을 정리한다.
    /// clearCellForWrite가 쓰기 시 하던 짝 정리를 erase에도 적용해, 짝 잃은 base나 orphan
    /// continuation이 남아 half-glyph로 그려지는 것을 막는다.
    fn repairWideGlyphEdges(self: *TerminalCore, row: u16, start: u16, end: u16) void {
        const blank: types.Cell = .{ .style = self.pen };
        // 왼쪽 경계: start-1이 width=2 base면 그 continuation(start)이 지워졌으므로 base도 비운다.
        if (start > 0 and self.cells[self.index(row, start - 1)].width == 2) {
            self.cells[self.index(row, start - 1)] = blank;
        }
        // 오른쪽 경계: end가 continuation이면 그 base(end-1)가 지워졌으므로 continuation도 비운다.
        if (end < self.size.cols and self.cells[self.index(row, end)].continuation) {
            self.cells[self.index(row, end)] = blank;
        }
    }

    fn eraseInLine(self: *TerminalCore, mode: u16) void {
        const row = self.cursor.row;
        if (self.size.cols == 0 or row >= self.size.rows) return;
        const start: u16 = switch (mode) {
            1, 2 => 0,
            else => self.cursor.col,
        };
        const end: u16 = switch (mode) {
            1 => @min(self.cursor.col + 1, self.size.cols),
            else => self.size.cols,
        };
        var col = start;
        while (col < end) : (col += 1) {
            // erase는 현재 pen의 배경색으로 채워야 하므로 blank cell에 style만 남긴다.
            self.cells[self.index(row, col)] = .{ .style = self.pen };
        }
        self.repairWideGlyphEdges(row, start, end);
        // 줄을 지우거나 짧게 만들면 더는 soft-wrap이 아니다(reflow가 이 행에서 줄을 끊게).
        self.wrapped[row] = false;
        self.markDirty(row);
        // 다른 cursor/erase op과 같이 grapheme run을 끝낸다. 안 하면 CSI K 뒤 combining mark가
        // 방금 지운 셀에 붙는다.
        self.last_print = null;
    }

    fn eraseInDisplay(self: *TerminalCore, mode: u16) void {
        if (self.size.rows == 0 or self.size.cols == 0) return;
        const blank: types.Cell = .{ .style = self.pen };
        switch (mode) {
            // 2/3: 화면 전체.
            2, 3 => {
                @memset(self.cells, blank);
                @memset(self.wrapped, false);
                self.dirty = fullDirty(self.size);
            },
            // 1: 화면 시작 ~ 커서까지.
            1 => {
                const cursor_index = self.index(self.cursor.row, self.cursor.col);
                var i: usize = 0;
                while (i <= cursor_index and i < self.cells.len) : (i += 1) self.cells[i] = blank;
                self.repairWideGlyphEdges(self.cursor.row, 0, @min(self.cursor.col + 1, self.size.cols));
                // 지운 행(0..cursor.row)은 더는 soft-wrap이 아니다.
                var wr: u16 = 0;
                while (wr <= self.cursor.row and wr < self.size.rows) : (wr += 1) self.wrapped[wr] = false;
                // dirty를 덮어쓰지 않고 markDirty로 병합한다 — 같은 write()에서 앞서 dirty된 행
                // (예: 방금 출력한 아래쪽 행)을 잃어 렌더가 stale glyph를 남기지 않게 한다.
                self.markDirty(0);
                self.markDirty(self.cursor.row);
            },
            // 0(기본): 커서 ~ 화면 끝까지.
            else => {
                const cursor_index = self.index(self.cursor.row, self.cursor.col);
                var i: usize = cursor_index;
                while (i < self.cells.len) : (i += 1) self.cells[i] = blank;
                self.repairWideGlyphEdges(self.cursor.row, self.cursor.col, self.size.cols);
                // 지운 행(cursor.row..끝)은 더는 soft-wrap이 아니다.
                var wr: u16 = self.cursor.row;
                while (wr < self.size.rows) : (wr += 1) self.wrapped[wr] = false;
                self.markDirty(self.cursor.row);
                self.markDirty(self.size.rows - 1);
            },
        }
        self.last_print = null;
    }

    pub fn resize(self: *TerminalCore, cols_in: u16, rows_in: u16) !void {
        // grid를 최소 2칸×1행으로 맞춘다(clampGridSize 참고).
        const next_size = clampGridSize(.{ .cols = cols_in, .rows = rows_in });
        const new_cols = next_size.cols;
        const new_rows = next_size.rows;

        // reflow: soft-wrap 플래그(wrapped)로 연속 줄(논리 줄)을 합쳐 새 폭에 다시 wrap한다. 이전에는
        // 좌상단 영역만 복사해, 창 폭을 바꾸면 wrap된 줄이 새 폭에 안 맞아 어긋났다. 재배치 결과를
        // 행 단위로 누적하고(각 행 new_cols개), 넘치면 아래(최근) new_rows개만 남긴다(위가 스크롤아웃).
        var out_cells: std.ArrayList(types.Cell) = .empty;
        defer out_cells.deinit(self.allocator);
        var out_wrapped: std.ArrayList(bool) = .empty;
        defer out_wrapped.deinit(self.allocator);

        const line_buf = try self.allocator.alloc(types.Cell, new_cols);
        defer self.allocator.free(line_buf);
        @memset(line_buf, .{});
        var oc: u16 = 0; // 현재 만들고 있는 출력 행의 열

        // 옛 커서가 매핑될 출력 위치. 출력 행 인덱스 = 지금까지 flush된 행 수.
        var cursor_out_row: ?usize = null;
        var cursor_out_col: u16 = 0;

        var old_r: u16 = 0;
        while (old_r < self.size.rows) : (old_r += 1) {
            const soft = self.wrapped[old_r];
            // 기여 길이: soft 행은 꽉 찼으므로 전체, 마지막(non-soft) 행은 뒤 빈칸을 잘라낸 길이.
            var contrib: u16 = if (soft) self.size.cols else self.trimmedRowLen(old_r);
            // 단, 커서가 있는 행에서는 커서 앞 빈 칸까지 보존한다. zsh는 줄 끝을 PROMPT_SP 공백 +
            // 커서로 표시하는데, 그 trailing 공백을 잘라내면 reflow 후 커서 컬럼이 zsh의 기대와
            // 어긋나, SIGWINCH redraw가 기존 줄 위에 겹쳐 찍혀 프롬프트가 중복된다(실제 관측됨).
            if (old_r == self.cursor.row) contrib = @max(contrib, self.cursor.col);

            var c: u16 = 0;
            while (c < contrib) : (c += 1) {
                const cell = self.cells[self.index(old_r, c)];
                // wide glyph base가 현재 출력 행 끝에 안 들어가면(continuation과 분리 방지) 먼저 행을
                // soft-wrap으로 flush한다.
                const needs: u16 = if (cell.width == 2) 2 else 1;
                if (oc + needs > new_cols) {
                    @memset(line_buf[oc..new_cols], .{});
                    try out_cells.appendSlice(self.allocator, line_buf);
                    try out_wrapped.append(self.allocator, true);
                    @memset(line_buf, .{});
                    oc = 0;
                }
                if (old_r == self.cursor.row and c == self.cursor.col and cursor_out_row == null) {
                    cursor_out_row = out_wrapped.items.len;
                    cursor_out_col = oc;
                }
                line_buf[oc] = cell;
                oc += 1;
            }
            // 커서가 이 행의 기여 내용보다 뒤(빈 영역)에 있으면 현재 출력 위치에 둔다. oc가 new_cols
            // (행이 정확히 꽉 참)면 그대로 두고 — 최종 재배치에서 다음 행 col 0으로 넘긴다(clamp 아님).
            if (old_r == self.cursor.row and cursor_out_row == null) {
                cursor_out_row = out_wrapped.items.len;
                cursor_out_col = @min(oc + (self.cursor.col -| contrib), new_cols);
            }
            if (!soft) {
                // 논리 줄 끝: 부분 출력 행을 hard(wrapped=false)로 flush한다.
                @memset(line_buf[oc..new_cols], .{});
                try out_cells.appendSlice(self.allocator, line_buf);
                try out_wrapped.append(self.allocator, false);
                @memset(line_buf, .{});
                oc = 0;
            }
        }
        // soft로 끝났는데 더 옛 행이 없는 경우(방어) 부분 행 flush.
        if (oc > 0) {
            @memset(line_buf[oc..new_cols], .{});
            try out_cells.appendSlice(self.allocator, line_buf);
            try out_wrapped.append(self.allocator, false);
        }

        // 콘텐츠 아래의 빈 출력 행(빈 옛 행에서 나온 것)이 콘텐츠를 위로 밀어내지 않게 끝쪽 빈 행을
        // 잘라낸다. 단 커서가 있는 행까지는 남긴다(커서가 콘텐츠 아래 빈 줄에 있을 수 있다).
        var content_len = out_wrapped.items.len;
        while (content_len > 0) {
            const r = content_len - 1;
            if (cursor_out_row) |cr| {
                if (r <= cr) break;
            }
            if (out_wrapped.items[r]) break; // soft-wrap 행은 콘텐츠
            if (!outputRowBlank(out_cells.items, r, new_cols)) break;
            content_len -= 1;
        }
        const drop: usize = if (content_len > new_rows) content_len - new_rows else 0;

        const next_cells = try self.allocator.alloc(types.Cell, cellCount(next_size));
        errdefer self.allocator.free(next_cells);
        @memset(next_cells, .{});
        const next_wrapped = try self.allocator.alloc(bool, new_rows);
        @memset(next_wrapped, false);

        var dst: u16 = 0;
        var src: usize = drop;
        while (src < content_len and dst < new_rows) {
            @memcpy(
                next_cells[@as(usize, dst) * @as(usize, new_cols) ..][0..new_cols],
                out_cells.items[src * @as(usize, new_cols) ..][0..new_cols],
            );
            next_wrapped[dst] = out_wrapped.items[src];
            dst += 1;
            src += 1;
        }

        self.allocator.free(self.cells);
        self.allocator.free(self.wrapped);
        self.size = next_size;
        self.cells = next_cells;
        self.wrapped = next_wrapped;

        // 커서를 보존한 내용에 맞춰 재배치한다: 기록한 출력 위치에서 스크롤아웃된 행 수를 빼고 clamp.
        if (cursor_out_row) |cr_raw| {
            var cr = cr_raw;
            var cc = cursor_out_col;
            // 출력 행이 정확히 꽉 차 커서가 마지막 칸을 넘으면(exact-fill) 다음 행 col 0으로 간다.
            // 마지막 칸에 clamp하면 커서가 한 칸 뒤처져 셸 redraw와 어긋난다(Ghostty와 동일하게 처리).
            if (cc >= new_cols) {
                cr += 1;
                cc = 0;
            }
            const r = if (cr >= drop) cr - drop else 0;
            self.cursor.row = @intCast(@min(r, @as(usize, new_rows - 1)));
            self.cursor.col = @min(cc, new_cols - 1);
        } else {
            self.cursor.row = @min(self.cursor.row, new_rows - 1);
            self.cursor.col = @min(self.cursor.col, new_cols - 1);
        }
        self.dirty = fullDirty(next_size);
        // 옛 grid 기준의 partial UTF-8 tail/last_print/deferred wrap은 새 grid로 새면 안 된다.
        self.last_print = null;
        self.utf8_tail_len = 0;
        self.pending_wrap = false;
        // resize 경계에서 끊긴 escape sequence가 새 grid로 새지 않게 파서를 ground로 되돌린다.
        self.parser = .ground;
    }

    /// 행의 뒤쪽 빈 cell을 제외한 내용 길이. reflow가 마지막(non-soft) 행을 합칠 때 trailing 공백을
    /// 끌고 다니지 않게 한다. 배경색이 있는 공백(BCE)이나 wide glyph continuation은 내용으로 본다.
    fn trimmedRowLen(self: *const TerminalCore, row: u16) u16 {
        var len: u16 = self.size.cols;
        while (len > 0) : (len -= 1) {
            if (!isBlankCell(self.cells[self.index(row, len - 1)])) break;
        }
        return len;
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
        // 탭은 수평 이동이라 다음 줄로 wrap하지 않는다(끝 칸에 멈춘다). pending_wrap이 이미
        // 서 있어도 소비하지 않도록 먼저 끄고, putCell이 채우다 마지막 칸에서 다시 세운
        // pending_wrap도 끝나고 끈다(탭이 wrap을 남기지 않게).
        self.pending_wrap = false;
        // 다음 8-탭스톱. 포화 곱셈(*|)으로, cols가 maxInt(u16)까지 커도(거대 창) 마지막 탭에서
        // (col/8+1)*8이 u16을 넘겨 패닉하지 않게 한다. @min은 곱셈 뒤라 포화로 막아야 한다.
        const next_tab = @min(self.size.cols, ((self.cursor.col / 8) + 1) *| 8);
        while (self.cursor.col < next_tab and !self.pending_wrap) {
            const before = self.cursor.col;
            self.putCell(' ');
            if (self.cursor.col == before) break;
        }
        self.pending_wrap = false;
    }

    fn putCell(self: *TerminalCore, codepoint: u21) void {
        if (self.size.cols == 0 or self.size.rows == 0) return;
        // deferred autowrap: 직전 글자가 마지막 칸을 채웠으면(pending_wrap), 이 글자를 그리기
        // 전에 다음 줄 첫 칸으로 넘긴다(바닥이면 scroll). 이렇게 다음 글자 시점에 wrap해야 줄을
        // 정확히 채운 마지막 글자마다 빈 줄이 끼지 않는다(표준 VT 동작, zsh prompt 등이 의존).
        if (self.pending_wrap) {
            // autowrap: 떠나는 행은 다음 행으로 이어지는 soft-wrap이다(reflow가 합칠 수 있게 표시).
            // 다음 줄로 넘긴다. lineFeed가 pending_wrap을 끄므로 여기서 따로 끄지 않는다.
            self.wrapped[self.cursor.row] = true;
            self.cursor.col = 0;
            self.lineFeed();
        }
        if (self.cursor.col >= self.size.cols) self.cursor.col = self.size.cols - 1;
        if (self.cursor.row >= self.size.rows) self.cursor.row = self.size.rows - 1;

        const cell_width: u2 = width.cellWidth(codepoint);
        // wide glyph(2칸)가 줄 끝(마지막 칸, 1칸만 남음)에 안 들어가면 통째로 다음 줄로 넘긴다
        // (이전 줄 마지막 칸은 빈칸으로 남는다). grid는 항상 cols>=2라(clampGridSize) 넘긴 뒤엔
        // 반드시 들어가므로, 칸을 줄이는 degrade 없이 그대로 width 2로 쓴다.
        if (cell_width == 2 and self.cursor.col + 1 >= self.size.cols) {
            self.wrapped[self.cursor.row] = true; // wide glyph도 줄을 다음 행으로 이어간다
            self.cursor.col = 0;
            self.lineFeed();
        }

        const row = self.cursor.row;
        const col = self.cursor.col;
        // 이 행에 글자를 쓴다 = 이 행을 (다시) 그리는 중이다. soft-wrap 표시를 일단 끈다. 이 행이
        // 다시 꽉 차 다음 글자가 autowrap하면 위에서 true로 돌아간다.
        self.wrapped[row] = false;

        self.clearCellForWrite(row, col);
        if (cell_width == 2) self.clearCellForWrite(row, col + 1);

        self.cells[self.index(row, col)] = .{
            .codepoint = codepoint,
            .style = self.pen,
            .width = cell_width,
        };
        if (cell_width == 2) {
            self.cells[self.index(row, col + 1)] = .{
                .style = self.pen,
                .width = 0,
                .continuation = true,
            };
        }
        self.last_print = .{ .row = row, .col = col };
        self.markDirty(self.cursor.row);

        if (self.cursor.col + cell_width < self.size.cols) {
            self.cursor.col += cell_width;
        } else {
            // 마지막 칸을 채웠다. 커서는 마지막 칸에 두되 pending_wrap을 세워, 다음 printable
            // 글자가 먼저 다음 줄로 넘어가게 한다(deferred autowrap).
            self.cursor.col = self.size.cols - 1;
            self.pending_wrap = true;
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
        // LF는 deferred autowrap을 무효화한다. 비-scroll 분기는 markCursorMoveDirty가 끄지만,
        // scroll 분기(scrollUpOneLine)는 그걸 안 거치므로 여기서 한 번에 끈다. 안 그러면 마지막
        // 행이 꽉 찬(pending_wrap) 상태에서 bare LF가 와도 플래그가 남아, 다음 printable 글자가
        // 또 한 줄 내려가(scroll) 직전 줄을 잃는다(이중 스크롤).
        self.pending_wrap = false;
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
            // soft-wrap 플래그도 cell과 함께 위로 옮긴다.
            self.wrapped[row - 1] = self.wrapped[row];
        }

        const last_start = self.index(self.size.rows - 1, 0);
        @memset(self.cells[last_start .. last_start + self.size.cols], .{});
        self.wrapped[self.size.rows - 1] = false;
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
        // 명시적 커서 이동(CR/LF/backspace/CUP/CHA/VPA/CUU..CUB 등 이 함수를 거치는 모든 이동)은
        // deferred autowrap을 무효화한다. putCell의 cursor 전진은 이 함수를 거치지 않으므로
        // pending_wrap을 직접 관리한다. 위치가 안 바뀌는 이동(아래 early-return)도 wrap 의도는
        // 취소되므로 early-return 전에 끈다.
        self.pending_wrap = false;
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

/// reflow trim 판정: 그릴 ink도 배경도 없는 진짜 빈 cell인가. wide glyph continuation은 base와
/// 한 쌍이라 빈 칸으로 보지 않고, 배경색이 있는 공백(BCE)도 내용으로 본다.
fn isBlankCell(cell: types.Cell) bool {
    return cell.codepoint == ' ' and
        !cell.continuation and
        cell.combining == null and
        std.meta.activeTag(cell.style.background) == .default;
}

/// reflow가 누적한 출력 행(row-major, cols개)이 통째로 빈 행인지.
fn outputRowBlank(cells: []const types.Cell, row: usize, cols: u16) bool {
    var c: usize = 0;
    while (c < cols) : (c += 1) {
        if (!isBlankCell(cells[row * @as(usize, cols) + c])) return false;
    }
    return true;
}

/// grid를 최소 cols>=2, rows>=1로 맞춘다. 한 cell 글자 모델은 wide glyph(2칸)의 continuation을
/// 옆 칸에 쓰므로 1칸짜리 grid는 마지막 칸에서 col+1 OOB를 부른다. init/resize에서 항상 이 최소
/// 크기를 보장해 그 degenerate 입력을 원천 차단한다(1칸 터미널은 실사용도 없다). 그래서 putCell은
/// cols>=2를 가정하고 wide glyph가 줄 끝에 안 들어가면 단순히 다음 줄로 넘기면 된다. PTY winsize와
/// grid 계산(gridFromBacking)이 같은 최소 크기를 쓰도록 pub으로 노출해 불변식을 한 곳에 둔다.
pub fn clampGridSize(size: types.Size) types.Size {
    return .{ .cols = @max(size.cols, 2), .rows = @max(size.rows, 1) };
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

test "SGR escape sequences are interpreted, not printed as text" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 1 });
    defer core.deinit();

    // The shell prompt problem: color codes must not show as literal "[31m" text.
    try core.write("\x1b[31mhi\x1b[0m");

    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("hi        ", dump);
}

test "SGR sets the pen style stamped onto written cells" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    try core.write("\x1b[1;4;31mA");
    const cell = core.cells[core.index(0, 0)];
    try std.testing.expectEqual(@as(u21, 'A'), cell.codepoint);
    try std.testing.expect(cell.style.bold);
    try std.testing.expect(cell.style.underline);
    try std.testing.expectEqual(types.Color{ .indexed = 1 }, cell.style.foreground);
}

test "SGR reset returns the pen to default for following cells" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    try core.write("\x1b[1;31mA\x1b[0mB");
    const a = core.cells[core.index(0, 0)];
    const b = core.cells[core.index(0, 1)];
    try std.testing.expect(a.style.bold);
    try std.testing.expect(!b.style.bold);
    try std.testing.expectEqual(types.Color.default, b.style.foreground);
}

test "SGR 256-color and rgb extended forms set the foreground" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    try core.write("\x1b[38;5;200mA");
    try std.testing.expectEqual(types.Color{ .indexed = 200 }, core.cells[core.index(0, 0)].style.foreground);

    try core.write("\x1b[38;2;10;20;30mB");
    try std.testing.expectEqual(
        types.Color{ .rgb = .{ .r = 10, .g = 20, .b = 30 } },
        core.cells[core.index(0, 1)].style.foreground,
    );
}

test "CSI cursor position moves the cursor with 1-based params" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 5 });
    defer core.deinit();

    try core.write("\x1b[3;5H");
    try std.testing.expectEqual(@as(u16, 2), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 4), core.cursor.col);

    // A bare CSI H homes the cursor.
    try core.write("\x1b[H");
    try std.testing.expectEqual(@as(u16, 0), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 0), core.cursor.col);
}

test "CSI K erases from the cursor to the end of the line" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 5, .rows = 1 });
    defer core.deinit();

    try core.write("abcde");
    // Column 3 (1-based) is index 2, then erase to end of line.
    try core.write("\x1b[3G\x1b[K");

    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("ab   ", dump);
}

test "CSI 2J clears the whole screen" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 3, .rows = 2 });
    defer core.deinit();

    try core.write("ab\ncd");
    try core.write("\x1b[2J");

    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("   \n   ", dump);
}

test "escape sequence split across writes is parsed as one sequence" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // PTY reads can split a sequence; parser state must persist across write().
    try core.write("\x1b[3");
    try core.write("1mX");

    const cell = core.cells[core.index(0, 0)];
    try std.testing.expectEqual(@as(u21, 'X'), cell.codepoint);
    try std.testing.expectEqual(types.Color{ .indexed = 1 }, cell.style.foreground);
}

test "OSC sequence is consumed and does not print" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 1 });
    defer core.deinit();

    // OSC 0 sets the window title, terminated by BEL; the title text must not show.
    try core.write("\x1b]0;title\x07hi");

    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("hi      ", dump);
}

test "private CSI sequences are consumed without printing" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 1 });
    defer core.deinit();

    // Cursor visibility toggles (DECTCEM) must not leak as text.
    try core.write("\x1b[?25lhi\x1b[?25h");

    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("hi    ", dump);
}

test "resize preserves overlapping content when growing" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 5, .rows = 1 });
    defer core.deinit();

    try core.write("hello");
    try core.resize(8, 1);

    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("hello   ", dump);
}

test "resize reflows a long line when shrinking instead of truncating" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 5, .rows = 1 });
    defer core.deinit();

    // "hello"(5칸)를 3칸으로 줄이면 reflow가 "hel"/"lo"로 다시 wrap한다. 1행만 보이므로 커서가 있는
    // 아래 줄("lo")을 남긴다(이전 placeholder는 좌상단을 잘라 "hel"을 남겼다).
    try core.write("hello");
    try core.resize(3, 1);

    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("lo ", dump);
}

test "resize preserves content across multiple rows" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 3, .rows = 2 });
    defer core.deinit();

    try core.write("ab");
    try core.write("\x1b[2;1Hcd");
    try core.resize(4, 3);

    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("ab  \ncd  \n    ", dump);
}

test "resize keeps the cursor within bounds from a degenerate empty-grid position" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 5, .rows = 3 });
    defer core.deinit();

    try core.write("\x1b[3;5H"); // 빈 grid에서 CUP -> (2,4)
    try std.testing.expectEqual(@as(u16, 2), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 4), core.cursor.col);

    // 내용 없는 grid에서 far CUP 후 극소 축소는 degenerate(실사용 없음, libghostty-vt도 이 resize에서
    // 패닉해 오라클 비교 불가). 정확 위치는 정의가 모호하므로 reflow가 OOB 없이 새 경계 안에 두는지
    // (안전 불변식)만 보장한다. 커서가 실제 내용을 따라가는 검증은 widen/narrow reflow 테스트가 한다.
    try core.resize(2, 2);
    try std.testing.expect(core.cursor.row < 2);
    try std.testing.expect(core.cursor.col < 2);
}

test "eraseInDisplay merges dirty instead of dropping earlier-dirtied rows" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 3, .rows = 4 });
    defer core.deinit();
    core.clearDirty();

    // Print on the bottom row, then move the cursor up and erase start-to-cursor (mode 1).
    try core.write("\x1b[4;1HX");
    try core.write("\x1b[2;1H\x1b[1J");

    // The bottom row (3) where X was printed must remain dirty — not be dropped by the erase.
    const dirty = core.takeDirty().?;
    try std.testing.expectEqual(@as(u16, 0), dirty.start_row);
    try std.testing.expect(dirty.end_row >= 3);
}

test "ESC inside a CSI restarts as a new escape instead of leaking as text" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 1 });
    defer core.deinit();

    // CSI opened by '[', then ESC cancels it and a fresh CSI sets red and prints X.
    try core.write("\x1b[\x1b[31mX");

    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("X     ", dump);
    try std.testing.expectEqual(types.Color{ .indexed = 1 }, core.cells[core.index(0, 0)].style.foreground);
}

test "C0 control inside a CSI is executed and the CSI still completes" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // Backspace (0x08) embedded mid-CSI must not abort it: the SGR red still applies, X prints red.
    try core.write("\x1b[31\x08mX");

    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("X   ", dump);
    try std.testing.expectEqual(types.Color{ .indexed = 1 }, core.cells[core.index(0, 0)].style.foreground);
}

test "CSI with more than 16 parameters discards the overflow instead of corrupting param 15" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 1 });
    defer core.deinit();

    // 16 zero params fill the buffer; the 17th param (1 = bold) is past the cap and must be dropped,
    // not folded into params[15] (which the old guard did, applying spurious bold).
    try core.write("\x1b[0;0;0;0;0;0;0;0;0;0;0;0;0;0;0;0;1mA");
    try std.testing.expect(!core.cells[core.index(0, 0)].style.bold);
}

test "resize clears a wide glyph whose continuation is clipped at the new right edge" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    try core.write("A한");
    try std.testing.expectEqual(@as(u2, 2), core.cells[core.index(0, 1)].width);

    // Shrink so the wide glyph's continuation (col 2) is clipped; the dangling base must be cleared.
    try core.resize(2, 1);
    try std.testing.expect(core.cells[core.index(0, 1)].width != 2);
}

test "erasing the continuation half of a wide glyph clears its dangling base" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    try core.write("한X");
    try std.testing.expectEqual(@as(u2, 2), core.cells[core.index(0, 0)].width);

    // Cursor onto the continuation (col 1), erase cursor-to-end: the base at col 0 is now dangling.
    try core.write("\x1b[2G\x1b[K");
    try std.testing.expect(core.cells[core.index(0, 0)].width != 2);
}

test "eraseInLine ends the grapheme run so a later combining mark is dropped" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    try core.write("A");
    try core.write("\x1b[1G\x1b[K");
    try core.write("\u{0301}");

    try std.testing.expectEqual(@as(?u21, null), core.cells[core.index(0, 0)].combining);
}

test "SGR colon sub-parameter direct color (38:2:cs:r:g:b) reads RGB past the colorspace slot" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // ITU colon form with an empty colorspace slot: '::' inserts an extra component before r,g,b.
    // The parser must skip the colorspace and read 10/20/30 — not 0/10/20.
    try core.write("\x1b[38:2::10:20:30mA");
    try std.testing.expectEqual(
        types.Color{ .rgb = .{ .r = 10, .g = 20, .b = 30 } },
        core.cells[core.index(0, 0)].style.foreground,
    );

    // Colon 256-color form: n sits at the same offset as the semicolon form.
    try core.write("\x1b[38:5:200mB");
    try std.testing.expectEqual(types.Color{ .indexed = 200 }, core.cells[core.index(0, 1)].style.foreground);

    // Semicolon form must stay correct (no colorspace component).
    try core.write("\x1b[48;2;1;2;3mC");
    try std.testing.expectEqual(
        types.Color{ .rgb = .{ .r = 1, .g = 2, .b = 3 } },
        core.cells[core.index(0, 2)].style.background,
    );
}

test "printable characters auto-wrap to the next line at the right edge (DECAWM)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("ABCDE"); // ABCD fills row 0; E wraps to row 1
    try std.testing.expectEqual(@as(u21, 'A'), core.cells[core.index(0, 0)].codepoint);
    try std.testing.expectEqual(@as(u21, 'D'), core.cells[core.index(0, 3)].codepoint);
    try std.testing.expectEqual(@as(u21, 'E'), core.cells[core.index(1, 0)].codepoint);
    try std.testing.expectEqual(@as(u16, 1), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 1), core.cursor.col);
}

test "a line filled exactly then CR/LF does not insert a blank wrapped line" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    // ABCD가 row 0을 정확히 채워 pending_wrap이 서지만, \r\n이 그걸 무효화해 X는 row 1에 온다
    // (deferred wrap이 아니면 \n이 한 줄 더 내려가 X가 row 2에 떨어진다).
    try core.write("ABCD\r\nX");
    try std.testing.expectEqual(@as(u21, 'D'), core.cells[core.index(0, 3)].codepoint);
    try std.testing.expectEqual(@as(u21, 'X'), core.cells[core.index(1, 0)].codepoint);
    try std.testing.expectEqual(@as(u16, 1), core.cursor.row);
}

test "overflow fill wraps so a following prompt lands on a new line, not over the content" {
    // 사용자 실제 시나리오: 개행 없이 끝난 출력(파란 배경) 뒤에 zsh PROMPT_SP가 줄 끝을 넘겨
    // 공백을 채워 다음 줄로 wrap시키고 \r + 프롬프트를 그린다. autowrap이 있어야 프롬프트가
    // wrap된 줄(row 1)에 떨어지고 파란 줄(row 0)을 덮지 않는다.
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 4 });
    defer core.deinit();
    try core.write("\x1b[44mBLUE\x1b[0m"); // BLUE(파란 배경) at row 0, cursor (0,4)
    try core.write("            "); // 12 spaces: 4 fill row 0, wrap, 8 fill row 1
    try core.write("\rPROMPT"); // \r clears pending_wrap; PROMPT at row 1
    try std.testing.expectEqual(@as(u21, 'B'), core.cells[core.index(0, 0)].codepoint);
    try std.testing.expectEqual(types.Color{ .indexed = 4 }, core.cells[core.index(0, 0)].style.background);
    try std.testing.expectEqual(@as(u21, 'P'), core.cells[core.index(1, 0)].codepoint);
    try std.testing.expectEqual(@as(u16, 1), core.cursor.row);
}

test "cursor positioning cancels a pending wrap" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("ABCD"); // fills row 0, pending_wrap set
    try core.write("\x1b[1;1H"); // CUP to (0,0) cancels pending_wrap
    try core.write("X"); // X overwrites (0,0), does NOT wrap to row 1
    try std.testing.expectEqual(@as(u21, 'X'), core.cells[core.index(0, 0)].codepoint);
    try std.testing.expectEqual(@as(u16, 0), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 1), core.cursor.col);
}

test "a wide glyph with one column left wraps whole to the next line" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("ABC"); // A,B,C at cols 0,1,2; cursor (0,3) one column left
    try core.write("한"); // wide(2): doesn't fit in 1 col -> wraps to row 1
    try std.testing.expectEqual(@as(u21, '한'), core.cells[core.index(1, 0)].codepoint);
    try std.testing.expectEqual(@as(u2, 2), core.cells[core.index(1, 0)].width);
    try std.testing.expect(core.cells[core.index(1, 1)].continuation);
    try std.testing.expectEqual(@as(u16, 1), core.cursor.row);
}

test "the grid is clamped to at least 2 columns so wide glyphs never write out of bounds" {
    // 1칸 grid는 wide glyph(2칸) continuation에서 col+1 OOB를 부른다. init/resize가 최소 2칸으로
    // 맞춰 그 degenerate 입력을 원천 차단하므로, wide glyph는 degrade 없이 통째로 들어간다.
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 1, .rows = 1 });
    defer core.deinit();
    try std.testing.expectEqual(@as(u16, 2), core.size.cols);
    try std.testing.expectEqual(@as(u16, 1), core.size.rows);
    try core.write("한"); // wide(2)가 OOB/degrade 없이 2칸으로 들어간다
    try std.testing.expectEqual(@as(u21, '한'), core.cells[core.index(0, 0)].codepoint);
    try std.testing.expectEqual(@as(u2, 2), core.cells[core.index(0, 0)].width);
    try std.testing.expect(core.cells[core.index(0, 1)].continuation);
    // resize도 같은 최소 크기를 보장한다.
    try core.resize(1, 4);
    try std.testing.expectEqual(@as(u16, 2), core.size.cols);
}

test "a bottom-row line feed clears pending wrap so the next char does not double-scroll" {
    // 바닥 행이 꽉 차(pending_wrap) bare LF가 오면 scroll이 일어나는데, pending_wrap이 안 지워지면
    // 다음 printable 글자가 또 scroll해 직전 줄을 잃었다(이중 스크롤). lineFeed가 pending_wrap을
    // 끄므로 ABCD가 row 0에 보존되고 X가 row 1에 와야 한다.
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("\r\nABCD"); // row 1을 채움 -> pending_wrap at (1,3)
    try core.write("\n"); // 바닥 bare LF -> scrollUpOneLine 한 번(ABCD -> row 0), 컬럼은 보존
    try core.write("X"); // pending_wrap stale면 또 scroll돼 ABCD 유실. 고쳐지면 한 번만 scroll.
    // 핵심: ABCD가 row 0에 보존된다(버그면 두 번 scroll돼 row 0이 빈칸). bare LF는 컬럼을
    // 보존하므로 X는 (1,3)에 온다.
    try std.testing.expectEqual(@as(u21, 'A'), core.cells[core.index(0, 0)].codepoint);
    try std.testing.expectEqual(@as(u21, 'D'), core.cells[core.index(0, 3)].codepoint);
    try std.testing.expectEqual(@as(u21, 'X'), core.cells[core.index(1, 3)].codepoint);
}

test "SGR colon direct color without a colorspace component (38:2:r:g:b) sets RGB" {
    // ITU colon form은 colorspace 슬롯이 생략될 수 있다(38:2:r:g:b, 5컴포넌트). 이전엔 colorspace가
    // 항상 있다고 가정해 색을 통째로 버렸다. r,g,b는 colon 컴포넌트의 마지막 3개로 읽어야 한다.
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();
    try core.write("\x1b[38:2:10:20:30mA");
    try std.testing.expectEqual(
        types.Color{ .rgb = .{ .r = 10, .g = 20, .b = 30 } },
        core.cells[core.index(0, 0)].style.foreground,
    );
    // 빈 colorspace(38:2::r:g:b)와 colorspace 있는(38:2:1:r:g:b) 6컴포넌트도 여전히 정확.
    try core.write("\x1b[38:2::40:50:60mB");
    try std.testing.expectEqual(
        types.Color{ .rgb = .{ .r = 40, .g = 50, .b = 60 } },
        core.cells[core.index(0, 1)].style.foreground,
    );
}

test "a tab near the last column does not overflow the tab-stop arithmetic" {
    // cols가 maxInt(u16)까지 허용되므로(거대 창), 마지막 칸 근처 탭에서 (col/8+1)*8이 u16을 넘길 수
    // 있다. 포화 곱셈으로 패닉/OOB 없이 마지막 칸에 멈춰야 한다.
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 65535, .rows = 1 });
    defer core.deinit();
    try core.write("\x1b[65535G"); // CHA -> 마지막 칸(65534)으로 clamp
    try core.write("\t"); // 패닉하면 안 됨
    try std.testing.expectEqual(@as(u16, 65534), core.cursor.col);
}

test "backspace cancels a pending wrap so the next char does not wrap" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("ABCD"); // row 0을 채움 -> pending_wrap at (0,3)
    try core.write("\x08"); // backspace -> (0,2), markCursorMoveDirty가 pending_wrap을 끈다
    try core.write("X"); // (0,2)에 덮어쓰고 wrap하지 않는다
    try std.testing.expectEqual(@as(u21, 'X'), core.cells[core.index(0, 2)].codepoint);
    try std.testing.expectEqual(@as(u16, 0), core.cursor.row);
}

test "SGR colon background direct color (48:2:r:g:b) sets the cell background" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();
    // 전경(38)뿐 아니라 배경(48)도 colon 형식 + colorspace 생략을 처리해야 한다.
    try core.write("\x1b[48:2:10:20:30mA");
    try std.testing.expectEqual(
        types.Color{ .rgb = .{ .r = 10, .g = 20, .b = 30 } },
        core.cells[core.index(0, 0)].style.background,
    );
}

test "printable text wraps across multiple rows filling each line" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 3 });
    defer core.deinit();
    try core.write("ABCDEF"); // AB / CD / EF
    try std.testing.expectEqual(@as(u21, 'A'), core.cells[core.index(0, 0)].codepoint);
    try std.testing.expectEqual(@as(u21, 'B'), core.cells[core.index(0, 1)].codepoint);
    try std.testing.expectEqual(@as(u21, 'C'), core.cells[core.index(1, 0)].codepoint);
    try std.testing.expectEqual(@as(u21, 'D'), core.cells[core.index(1, 1)].codepoint);
    try std.testing.expectEqual(@as(u21, 'E'), core.cells[core.index(2, 0)].codepoint);
    try std.testing.expectEqual(@as(u21, 'F'), core.cells[core.index(2, 1)].codepoint);
}

test "a wide glyph filling the last two columns sets pending wrap and the next char wraps" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("AB"); // A(0,0) B(0,1), 커서 (0,2)
    try core.write("한"); // 마지막 두 칸(2,3)을 채움 -> 커서 (0,3) pending_wrap
    try core.write("X"); // 다음 줄로 wrap
    try std.testing.expectEqual(@as(u21, '한'), core.cells[core.index(0, 2)].codepoint);
    try std.testing.expect(core.cells[core.index(0, 3)].continuation);
    try std.testing.expectEqual(@as(u21, 'X'), core.cells[core.index(1, 0)].codepoint);
    try std.testing.expectEqual(@as(u16, 1), core.cursor.row);
}

test "clampGridSize enforces a minimum of 2 columns and 1 row" {
    try std.testing.expectEqual(types.Size{ .cols = 2, .rows = 5 }, clampGridSize(.{ .cols = 1, .rows = 5 }));
    try std.testing.expectEqual(types.Size{ .cols = 2, .rows = 1 }, clampGridSize(.{ .cols = 0, .rows = 0 }));
    try std.testing.expectEqual(types.Size{ .cols = 80, .rows = 24 }, clampGridSize(.{ .cols = 80, .rows = 24 }));
}

test "tab advances to the next 8-column stop mid-line" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 16, .rows = 1 });
    defer core.deinit();
    // 엣지(마지막 칸)가 아니라 일반 전진: 'a'(col 1) 뒤 tab은 다음 8-stop(col 8)으로 간다.
    try core.write("a\t");
    try std.testing.expectEqual(@as(u16, 8), core.cursor.col);
}

test "resize widening joins a soft-wrapped line and relocates the cursor" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("ABCDEF"); // ABCD(soft-wrap) / EF, 커서 (1,2)
    try std.testing.expect(core.wrapped[0]); // sanity: row 0이 soft-wrap
    try core.resize(8, 3);
    // 8칸으로 넓히면 ABCDEF가 한 줄로 합쳐지고 더는 wrap이 아니다.
    try std.testing.expectEqual(@as(u21, 'A'), core.cells[core.index(0, 0)].codepoint);
    try std.testing.expectEqual(@as(u21, 'F'), core.cells[core.index(0, 5)].codepoint);
    try std.testing.expect(!core.wrapped[0]);
    // 커서는 합쳐진 줄에서 F 다음(0,6)으로 따라온다.
    try std.testing.expectEqual(@as(u16, 0), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 6), core.cursor.col);
}

test "resize narrowing splits a long line and marks the wrap" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 3 });
    defer core.deinit();
    try core.write("ABCDEF"); // 8칸에 6글자, wrap 아님
    try std.testing.expect(!core.wrapped[0]);
    try core.resize(4, 3);
    // 4칸으로 줄이면 ABCD(soft-wrap) / EF로 나뉜다.
    try std.testing.expectEqual(@as(u21, 'D'), core.cells[core.index(0, 3)].codepoint);
    try std.testing.expect(core.wrapped[0]);
    try std.testing.expectEqual(@as(u21, 'E'), core.cells[core.index(1, 0)].codepoint);
    try std.testing.expectEqual(@as(u21, 'F'), core.cells[core.index(1, 1)].codepoint);
    try std.testing.expect(!core.wrapped[1]);
}

test "resize keeps hard-newline lines separate (does not join them)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("AB\r\nCD"); // 하드 개행(CR+LF)이라 wrap 아님 — 두 논리 줄
    try std.testing.expect(!core.wrapped[0]);
    try core.resize(8, 3);
    // 넓혀도 합쳐지지 않고 각자 자기 줄에 남는다.
    try std.testing.expectEqual(@as(u21, 'A'), core.cells[core.index(0, 0)].codepoint);
    try std.testing.expectEqual(@as(u21, 'B'), core.cells[core.index(0, 1)].codepoint);
    try std.testing.expectEqual(@as(u21, 'C'), core.cells[core.index(1, 0)].codepoint);
    try std.testing.expectEqual(@as(u21, 'D'), core.cells[core.index(1, 1)].codepoint);
}

test "resize narrowing wraps a wide glyph whole instead of splitting it" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("AB한"); // A,B,한(2칸) — 4칸을 정확히 채움
    try core.resize(3, 3);
    // 3칸으로 줄이면 한이 잘리지 않고 통째로 다음 줄로 간다: row0 "AB"(soft), row1 한(2칸).
    try std.testing.expectEqual(@as(u21, 'A'), core.cells[core.index(0, 0)].codepoint);
    try std.testing.expectEqual(@as(u21, 'B'), core.cells[core.index(0, 1)].codepoint);
    try std.testing.expect(core.wrapped[0]);
    try std.testing.expectEqual(@as(u21, '한'), core.cells[core.index(1, 0)].codepoint);
    try std.testing.expectEqual(@as(u2, 2), core.cells[core.index(1, 0)].width);
    try std.testing.expect(core.cells[core.index(1, 1)].continuation);
}

test "resize preserves the cursor column past trimmed trailing blanks (zsh PROMPT_SP)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    // "abc" 뒤 커서를 (0,6)으로 옮긴다 — content는 3칸인데 커서는 trailing 공백 뒤(6)에 있다
    // (zsh가 줄 끝을 공백+커서로 표시하는 상황의 일반형).
    try core.write("abc");
    try core.write("\x1b[1;7H"); // CUP -> (0,6)
    try std.testing.expectEqual(@as(u16, 6), core.cursor.col);
    // 4칸으로 줄이면 커서 앞 빈 칸까지 보존된 논리 줄("abc   ", 6칸)이 "abc "/"  "로 재배치되고,
    // 커서는 논리 offset 6 = (1,2)로 따라온다. trailing 공백을 잘랐다면 (0,3)에 잘못 박힌다.
    try core.resize(4, 2);
    try std.testing.expectEqual(@as(u16, 1), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 2), core.cursor.col);
}
