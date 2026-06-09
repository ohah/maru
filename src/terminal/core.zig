const std = @import("std");
const input = @import("input.zig");
const types = @import("types.zig");
const width = @import("width.zig");

/// DECSC/DECRC(ESC 7/8)·DECSET 1048/1049가 쓰는 저장 커서 상태. 화면(primary/alt)마다 하나씩 둔다.
pub const SavedCursor = struct {
    cursor: types.Cursor = .{},
    pen: types.Style = .{},
    pending_wrap: bool = false,
};

/// 저장 커서를 새 grid 안으로 clamp한다. col이 잘려 더는 마지막 칸이 아니면 pending_wrap도 끈다
/// (deferred wrap은 "마지막 칸에 머무는 중"일 때만 유효한 상태다).
fn clampSavedCursor(slot: *SavedCursor, size: types.Size) void {
    const clamped_col = @min(slot.cursor.col, size.cols - 1);
    if (clamped_col != slot.cursor.col) slot.pending_wrap = false;
    slot.cursor.row = @min(slot.cursor.row, size.rows - 1);
    slot.cursor.col = clamped_col;
}

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
    // CSI의 private marker 바이트(0x3c-0x3f: '<','=','>','?'). 0이면 없음. xterm은 marker별로
    // 의미가 다르다 — DECSET/DECRST는 '?' 전용이고 '>'는 DA2/XTVERSION 등 별도 명령이다.
    csi_marker: u8 = 0,
    // CSI intermediate 바이트(0x20-0x2f, 예: DECSCUSR의 ' ', DECCARA의 '$'). 0이면 없음.
    // intermediate가 붙은 시퀀스는 같은 final이라도 다른 명령이므로 (intermediate, final) 튜플로
    // dispatch하고, 모르는 조합은 소비한다(VT500 파서 의미). 여러 개면 마지막 것만 기억한다
    // (실사용 시퀀스는 intermediate 1개).
    csi_intermediate: u8 = 0,
    csi_overflow: bool = false,
    // deferred autowrap(DECAWM, 기본 켜짐). 마지막 칸을 채운 직후 커서는 그 칸에 머물고 이 플래그가
    // 선다. 다음 printable 글자가 먼저 다음 줄 첫 칸으로 넘어간 뒤 그려진다. 마지막 칸이 그 줄의
    // 끝 글자면 wrap하지 않으려고(끝 글자마다 빈 줄이 끼지 않게) 즉시가 아니라 "다음 글자에서"
    // 넘긴다. 명시적 커서 이동(CR/LF/backspace/커서 위치 지정/resize)은 이 상태를 무효화한다.
    pending_wrap: bool = false,
    // DECSTBM scroll region(top/bottom margin, 0-indexed inclusive). LF/IND/RI 스크롤은 이 구간
    // 안에서만 일어난다. 기본은 화면 전체 [0, rows-1]. init/resize에서 전체로 리셋한다. less/vim
    // 등이 상태줄을 고정하고 본문만 스크롤하는 데 쓴다.
    scroll_top: u16 = 0,
    scroll_bottom: u16 = 0,
    // alternate screen(DECSET 1049/47/1047). vim·less 같은 TUI가 전체 화면을 쓰고 종료 시 원래
    // 셸 화면을 복원하는 보조 버퍼다. 활성이면 saved_*에 primary 그리드가 보관돼 있고, alt 출력은
    // 스크롤백에 쌓이지 않으며 스크롤백 뷰포트도 잠긴다(표준 xterm 동작).
    alt_active: bool = false,
    // DECCKM(CSI ?1 h/l, application cursor keys). vim/less가 켜면 화살표 입력이 SS3(`ESC O A`)로
    // 인코딩돼야 한다. core는 모드만 추적하고, 인코딩은 input.encodeKey가 EncodeOptions로 받는다.
    application_cursor_keys: bool = false,
    // alternate scroll(xterm DECSET 1007): alt screen에서 휠/트랙패드 스크롤을 화살표 키로 변환해
    // 프로그램에 보낸다(less/vim이 자체 스크롤). 스크롤백이 잠긴 alt에서 스크롤이 무반응이 되지
    // 않게 하는 표준 장치로, iTerm2/Terminal.app처럼 기본 켠다(프로그램이 ?1007l로 끌 수 있음).
    alternate_scroll: bool = true,
    // bracketed paste(DECSET 2004): 켜져 있으면 붙여넣기를 ESC[200~ ... ESC[201~로 감싸 보낸다.
    // zsh/vim/claude가 켜며, 붙여넣은 텍스트를 타이핑과 구분해(자동 들여쓰기·즉시 실행 방지) 처리한다.
    bracketed_paste: bool = false,
    // DECTCEM(CSI ?25 h/l): 커서 표시. TUI가 화면을 그리는 동안 커서 깜빡임/잔상을 숨기려고 끈다.
    // snapshot/renderSnapshot이 내보내는 cursor.visible에 합성된다(내부 self.cursor.visible은 불변).
    cursor_visible: bool = true,
    // DECSCUSR(CSI Ps SP q): 커서 모양과 깜빡임. vim이 모드별로 bar/block을 전환하는 표준 수단.
    cursor_shape: types.CursorShape = .block,
    cursor_blink: bool = true,
    saved_cells: []types.Cell = &.{},
    saved_wrapped: []bool = &.{},
    // DECSC/DECRC + 1048/1049가 쓰는 저장 커서. xterm처럼 화면(primary/alt)마다 별도 슬롯을 둔다 —
    // 한 슬롯을 공유하면 TUI가 alt 안에서 ESC 7/8을 쓸 때 1049가 저장한 셸 커서가 덮여, 종료 시
    // 프롬프트가 엉뚱한 위치(예: 화면 맨 위)로 복원된다.
    saved_cursor_primary: SavedCursor = .{},
    saved_cursor_alt: SavedCursor = .{},
    // 각 CSI 파라미터가 ';'(새 파라미터)가 아니라 ':'(sub-parameter)로 들어왔는지 표시한다.
    // ITU colon 형식 38:2:colorspace:r:g:b는 38;2;r;g;b와 달리 colorspace 컴포넌트가 하나 더
    // 있어, 이 구분 없이는 RGB가 한 칸 밀린다.
    csi_subparam: [max_csi_params]bool = [_]bool{false} ** max_csi_params,
    // 활성 화면의 soft-wrap 추적. wrapped[r]==true는 "행 r이 autowrap으로 행 r+1로 이어진다"는
    // r↔r+1 경계의 속성이다(내용이 아니라 경계). hard 줄끝(LF, 또는 셸이 그린 뒤 CR/LF/CUP로 떠난
    // 줄)은 wrapped[r]=false다. autowrap(마지막 칸 넘침)일 때만 true가 되고, 그 행에 새로 쓰면 다시
    // false로 리셋된다(redraw가 스스로 교정됨). resize 시 reflow가 이 플래그로 논리 줄을 잇는다.
    // 길이는 항상 size.rows.
    wrapped: []bool = &.{},
    // 스크롤백: 화면 위로 밀려난(scroll된) 맨 윗줄을 보관한다. ring buffer로, 가장 오래된 행이
    // sb_head, 보관 개수가 sb_count다. 슬롯 버퍼를 재사용해 scroll마다 alloc 없이 memcpy만 하므로
    // 출력 hot path(매 줄 scroll)를 느리게 하지 않는다. 과거를 스크롤해서 보는 뷰포트와 reflow는
    // 이 저장 위에 올린다(다음 단계). 첫 scroll에서 max_scrollback 크기로 lazy 할당한다.
    scrollback: []?[]types.Cell = &.{},
    // 각 스크롤백 행의 soft-wrap 플래그. scrollback과 병렬 ring(같은 max_scrollback 길이, 같은
    // (sb_head+i)%len 인덱싱). 슬롯 cell 버퍼 재사용 경로를 건드리지 않는 평평한 []bool이다.
    sb_wrapped: []bool = &.{},
    sb_head: usize = 0,
    sb_count: usize = 0,
    max_scrollback: usize = default_max_scrollback,
    // 뷰포트: 바닥(0=활성 화면)에서 위로 스크롤한 줄 수. [0, sb_count] 범위. >0이면 화면 윗부분에
    // 스크롤백(과거)이 보이고 활성 화면 아랫부분은 가려진다. 과거를 보는 중 새 출력이 scroll되면
    // 같은 내용을 계속 보도록 함께 올린다(scroll-lock).
    view_offset: usize = 0,
    // 스크롤백 재-wrap 지연 마크. resize는 비싼 ring 재구성(행 1000개 재할당)을 즉시 하지 않고
    // 이 플래그만 세우고, 사용자가 실제로 과거를 보는 순간(scrollViewport/renderSnapshot)에 현재
    // 폭으로 1회 수행한다 — 연속 드래그 resize가 와도 마지막 폭으로 한 번만 재-wrap된다.
    sb_rewrap_pending: bool = false,
    // 마우스 드래그 선택(anchor=누른 곳, head=현재 끝). 절대 행 좌표라 스크롤해도 내용을 따라간다.
    // 스크롤백 eviction(가득 찬 ring)·재-wrap·clear 때 보정/해제된다.
    selection_anchor: ?types.SelectionPoint = null,
    selection_head: ?types.SelectionPoint = null,
    // 스크롤된(view_offset>0) 상태의 렌더용 합성 버퍼(rows×cols). renderSnapshot이 뷰포트 윈도를
    // 여기에 합성한다. view_offset==0이면 안 쓰므로 lazy 할당한다(스크롤할 때만 메모리 사용).
    viewport_cells: []types.Cell = &.{},
    // resize reflow가 출력 행을 누적하는 재사용 스크래치(grow-only, rows×cols). 매 resize에
    // ArrayList를 새로 키우지 않도록 struct에 들고 다닌다 — core_resize_loop perf 예산을 지키려면
    // alloc churn을 없애야 한다(되돌린 구현이 ArrayList realloc으로 예산을 깼다).
    reflow_cells: []types.Cell = &.{},
    reflow_wrapped: []bool = &.{},
    // 터미널이 호스트로 돌려보낼 응답(CPR 커서 위치 보고, DSR 상태 등). write() 중 query를 만나면
    // 여기에 쌓이고, app 레이어가 매 write 후 drain해 PTY로 되쓴다(프로그램이 입력처럼 읽는다).
    // zsh 등은 SIGWINCH redraw 때 CSI 6n으로 커서를 묻는데, 응답이 없으면 redraw가 어긋난다.
    response: std.ArrayList(u8) = .empty,

    pub const ParserState = enum { ground, escape, escape_intermediate, csi, osc, osc_escape };

    const max_csi_params = 16;
    const default_max_scrollback = 1000;

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
            .scroll_bottom = grid.rows - 1,
        };
    }

    pub fn deinit(self: *TerminalCore) void {
        self.allocator.free(self.cells);
        if (self.wrapped.len > 0) self.allocator.free(self.wrapped);
        if (self.saved_cells.len > 0) self.allocator.free(self.saved_cells);
        if (self.saved_wrapped.len > 0) self.allocator.free(self.saved_wrapped);
        for (self.scrollback) |slot| {
            if (slot) |cells| self.allocator.free(cells);
        }
        if (self.scrollback.len > 0) self.allocator.free(self.scrollback);
        if (self.sb_wrapped.len > 0) self.allocator.free(self.sb_wrapped);
        if (self.viewport_cells.len > 0) self.allocator.free(self.viewport_cells);
        if (self.reflow_cells.len > 0) self.allocator.free(self.reflow_cells);
        if (self.reflow_wrapped.len > 0) self.allocator.free(self.reflow_wrapped);
        self.response.deinit(self.allocator);
        self.* = undefined;
    }

    /// 스크롤백에 보관된 행 수.
    pub fn scrollbackLen(self: *const TerminalCore) usize {
        return self.sb_count;
    }

    /// i=0이 가장 오래된 스크롤백 행. 범위 밖이거나 OOM으로 비어 있으면 null.
    pub fn scrollbackRow(self: *const TerminalCore, i: usize) ?[]const types.Cell {
        if (i >= self.sb_count) return null;
        return self.scrollback[(self.sb_head + i) % self.scrollback.len];
    }

    /// 뷰포트를 delta_up줄만큼 위(과거, 양수)/아래(현재, 음수)로 스크롤한다. [0, sb_count]로 clamp.
    /// 뷰가 바뀌면 화면 전체를 dirty로 표시한다(렌더가 새 윈도를 다시 그리도록).
    pub fn scrollViewport(self: *TerminalCore, delta_up: isize) void {
        // alt screen에서는 스크롤백 뷰가 잠긴다(xterm 동작) — TUI 화면 위로 history가 겹치지 않게.
        if (self.alt_active) return;
        // 지연된 재-wrap을 먼저 수행한다 — sb_count(스크롤 범위)가 재-wrap으로 바뀔 수 있다.
        self.ensureScrollbackRewrapped();
        const max_off: isize = @intCast(self.sb_count);
        var off: isize = @as(isize, @intCast(self.view_offset)) + delta_up;
        if (off < 0) off = 0;
        if (off > max_off) off = max_off;
        const new_off: usize = @intCast(off);
        if (new_off != self.view_offset) {
            self.view_offset = new_off;
            self.dirty = fullDirty(self.size);
        }
    }

    /// 뷰포트를 바닥(활성 화면)으로 되돌린다.
    pub fn scrollToBottom(self: *TerminalCore) void {
        if (self.view_offset != 0) {
            self.view_offset = 0;
            self.dirty = fullDirty(self.size);
        }
    }

    /// 현재 위로 스크롤한 줄 수(0=바닥).
    pub fn viewOffset(self: *const TerminalCore) usize {
        return self.view_offset;
    }

    /// 보이는 행 r(0..rows-1)의 cells. view_offset만큼 [스크롤백 ++ 활성]을 위로 본 윈도다. 윗부분
    /// view_offset줄은 가장 최근 스크롤백, 나머지는 활성 화면 윗부분이다. 스크롤백 행이 비었으면(OOM)
    /// 빈 슬라이스를 준다. resize로 폭이 달라진 스크롤백 행은 저장된 폭 그대로 — 렌더가 clamp/pad한다.
    pub fn viewportRow(self: *const TerminalCore, r: u16) []const types.Cell {
        const ci = self.sb_count - self.view_offset + r; // content index (sb_count>=view_offset 보장)
        if (ci < self.sb_count) {
            return self.scrollbackRow(ci) orelse &.{};
        }
        const active_row = ci - self.sb_count;
        const start = active_row * self.size.cols;
        return self.cells[start .. start + self.size.cols];
    }

    /// scroll로 위로 밀려나는 맨 윗줄을 스크롤백 ring에 보관한다. 슬롯 버퍼를 재사용해(같은 길이면
    /// memcpy만) 매 scroll에 alloc하지 않는다. OOM이면 그 행은 보관하지 않고 넘어간다(best-effort).
    /// i=0이 가장 오래된 스크롤백 행의 soft-wrap 플래그.
    pub fn scrollbackRowWrapped(self: *const TerminalCore, i: usize) bool {
        if (i >= self.sb_count or self.sb_wrapped.len == 0) return false;
        return self.sb_wrapped[(self.sb_head + i) % self.sb_wrapped.len];
    }

    /// 붙여넣기 바이트를 PTY 입력으로 인코딩한다: 개행을 CR로 정규화(\r\n/\n -> \r — 셸 입력의
    /// 줄바꿈 관례)하고, 프로그램이 bracketed paste(DECSET 2004)를 켰으면 ESC[200~ ... ESC[201~로
    /// 감싼다(타이핑과 구분돼 자동 들여쓰기/즉시 실행 방지). 호출자가 free한다.
    pub fn encodePaste(self: *const TerminalCore, allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        if (self.bracketed_paste) try out.appendSlice(allocator, "\x1b[200~");
        var i: usize = 0;
        while (i < bytes.len) : (i += 1) {
            const b = bytes[i];
            if (b == '\r' or b == '\n') {
                try out.append(allocator, '\r');
                if (b == '\r' and i + 1 < bytes.len and bytes[i + 1] == '\n') i += 1; // CRLF는 한 번만
            } else {
                try out.append(allocator, b);
            }
        }
        if (self.bracketed_paste) try out.appendSlice(allocator, "\x1b[201~");
        return try out.toOwnedSlice(allocator);
    }

    /// 선택 시작(마우스 다운). 뷰포트 행/열을 받아 절대 행으로 저장한다.
    pub fn selectionStart(self: *TerminalCore, viewport_row: u16, col: u16) void {
        const abs = self.absRowFromViewport(viewport_row);
        self.selection_anchor = .{ .row = abs, .col = @min(col, self.size.cols -| 1) };
        self.selection_head = self.selection_anchor;
        self.dirty = fullDirty(self.size);
    }

    /// 선택 확장(드래그). anchor가 없으면 무시.
    pub fn selectionExtend(self: *TerminalCore, viewport_row: u16, col: u16) void {
        if (self.selection_anchor == null) return;
        self.selection_head = .{ .row = self.absRowFromViewport(viewport_row), .col = @min(col, self.size.cols -| 1) };
        self.dirty = fullDirty(self.size);
    }

    /// 더블클릭 단어 선택: 클릭한 셀이 속한 비공백 run을 좌우로 확장한다. soft-wrap 경계는
    /// 논리 줄로 이어지므로 행을 넘어 계속 확장한다(wrap된 긴 URL을 통째로 선택). 공백을
    /// 클릭하면 선택하지 않는다(해제).
    pub fn selectWordAt(self: *TerminalCore, viewport_row: u16, col: u16) void {
        const bounds = self.wordBoundsAt(viewport_row, col) orelse {
            self.selectionClear();
            return;
        };
        self.selection_anchor = bounds.start;
        self.selection_head = bounds.end;
        self.dirty = fullDirty(self.size);
    }

    /// 클릭 위치가 속한 비공백 run(단어)의 절대 좌표 경계. soft-wrap을 넘어 확장한다.
    /// 공백 위치면 null.
    fn wordBoundsAt(self: *const TerminalCore, viewport_row: u16, col: u16) ?struct { start: types.SelectionPoint, end: types.SelectionPoint } {
        const abs = self.absRowFromViewport(viewport_row);
        const row_cells = self.absRow(abs) orelse return null;
        const c = @min(col, @as(u16, @intCast(row_cells.len -| 1)));
        if (isBlankCell(row_cells[c])) return null;

        // 왼쪽 경계: 행 안에서 공백까지, 행 시작에 닿으면 이전 행이 soft-wrap으로 이어질 때 계속.
        var start_row = abs;
        var start_col: u16 = c;
        outer_left: while (true) {
            const cells_row = self.absRow(start_row) orelse break;
            while (start_col > 0) {
                if (isBlankCell(cells_row[start_col - 1])) break :outer_left;
                start_col -= 1;
            }
            if (start_row == 0 or !self.absRowWrapped(start_row - 1)) break;
            const prev = self.absRow(start_row - 1) orelse break;
            if (prev.len == 0 or isBlankCell(prev[prev.len - 1])) break;
            start_row -= 1;
            start_col = @intCast(prev.len - 1);
        }

        // 오른쪽 경계: 대칭 — 행 끝에 닿으면 이 행이 soft-wrap일 때 다음 행으로 계속.
        var end_row = abs;
        var end_col: u16 = c;
        outer_right: while (true) {
            const cells_row = self.absRow(end_row) orelse break;
            while (end_col + 1 < cells_row.len) {
                if (isBlankCell(cells_row[end_col + 1])) break :outer_right;
                end_col += 1;
            }
            if (!self.absRowWrapped(end_row)) break;
            const next = self.absRow(end_row + 1) orelse break;
            if (next.len == 0 or isBlankCell(next[0])) break;
            end_row += 1;
            end_col = 0;
        }

        return .{ .start = .{ .row = start_row, .col = start_col }, .end = .{ .row = end_row, .col = end_col } };
    }

    /// Cmd+클릭 위치의 URL을 추출한다(없으면 null). 클릭 셀이 속한 비공백 run(soft-wrap 포함)
    /// 안에서 http:// 또는 https:// 부터 run 끝까지를 URL로 보고, 끝에 붙은 문장 부호(괄호/마침표
    /// 등)는 다듬는다. 호출자가 free한다.
    pub fn extractUrlAt(self: *const TerminalCore, allocator: std.mem.Allocator, viewport_row: u16, col: u16) !?[]u8 {
        const bounds = self.wordBoundsAt(viewport_row, col) orelse return null;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var abs = bounds.start.row;
        while (abs <= bounds.end.row) : (abs += 1) {
            const row_cells = self.absRow(abs) orelse break;
            const from: usize = if (abs == bounds.start.row) bounds.start.col else 0;
            const to: usize = if (abs == bounds.end.row) @min(@as(usize, bounds.end.col) + 1, row_cells.len) else row_cells.len;
            var c = from;
            while (c < to) : (c += 1) {
                const cell = row_cells[c];
                if (cell.continuation) continue;
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cell.codepoint, &buf) catch continue;
                try out.appendSlice(allocator, buf[0..n]);
            }
        }
        const word = out.items;
        const start_http = std.mem.indexOf(u8, word, "https://") orelse std.mem.indexOf(u8, word, "http://") orelse {
            out.deinit(allocator);
            return null;
        };
        // 끝의 흔한 마무리 문장 부호를 다듬는다(예: "(...url)." 같은 산문 속 URL).
        var end_idx = word.len;
        while (end_idx > start_http) : (end_idx -= 1) {
            const ch = word[end_idx - 1];
            if (ch == '.' or ch == ',' or ch == ')' or ch == ']' or ch == '>' or ch == ';' or ch == '\'' or ch == '"') continue;
            break;
        }
        if (end_idx <= start_http + "http://".len) {
            out.deinit(allocator);
            return null; // 스킴만 있고 본문이 없다
        }
        const url = try allocator.dupe(u8, word[start_http..end_idx]);
        out.deinit(allocator);
        return url;
    }

    /// 트리플클릭 줄 선택: 클릭한 행이 속한 논리 줄 전체(soft-wrap된 행들 포함)를 선택한다.
    pub fn selectLineAt(self: *TerminalCore, viewport_row: u16) void {
        const abs = self.absRowFromViewport(viewport_row);
        if (self.absRow(abs) == null) return;
        var start_row = abs;
        while (start_row > 0 and self.absRowWrapped(start_row - 1)) start_row -= 1;
        var end_row = abs;
        while (self.absRowWrapped(end_row) and self.absRow(end_row + 1) != null) end_row += 1;
        const end_cells = self.absRow(end_row) orelse return;
        self.selection_anchor = .{ .row = start_row, .col = 0 };
        self.selection_head = .{ .row = end_row, .col = @intCast(end_cells.len -| 1) };
        self.dirty = fullDirty(self.size);
    }

    pub fn selectionClear(self: *TerminalCore) void {
        if (self.selection_anchor == null) return;
        self.selection_anchor = null;
        self.selection_head = null;
        self.dirty = fullDirty(self.size);
    }

    fn shiftSelectionForEviction(self: *TerminalCore) void {
        if (self.selection_anchor == null) return;
        const a = &self.selection_anchor.?;
        const h = &self.selection_head.?;
        if (a.row == 0 or h.row == 0) {
            self.selectionClear();
            return;
        }
        a.row -= 1;
        h.row -= 1;
    }

    fn absRowFromViewport(self: *const TerminalCore, viewport_row: u16) usize {
        // 절대 행 = 스크롤백 시작 기준. 뷰포트 첫 행은 sb_count - view_offset.
        return self.sb_count - @min(self.view_offset, self.sb_count) + viewport_row;
    }

    /// 정규화된 선택(start <= end). 없으면 null.
    fn normalizedSelection(self: *const TerminalCore) ?struct { start: types.SelectionPoint, end: types.SelectionPoint } {
        const a = self.selection_anchor orelse return null;
        const h = self.selection_head orelse return null;
        if (a.row < h.row or (a.row == h.row and a.col <= h.col)) return .{ .start = a, .end = h };
        return .{ .start = h, .end = a };
    }

    /// 현재 뷰포트에 보이는 선택 범위(렌더용). 화면 밖이면 null.
    pub fn selectionViewportSpan(self: *const TerminalCore) ?types.SelectionSpan {
        const sel = self.normalizedSelection() orelse return null;
        const top_abs = self.sb_count - @min(self.view_offset, self.sb_count);
        const bottom_abs = top_abs + self.size.rows - 1;
        if (sel.end.row < top_abs or sel.start.row > bottom_abs) return null;
        // 뷰포트로 클립: 화면 위로 나가면 (0,0)부터, 아래로 나가면 마지막 행 끝까지.
        const start_row: u16 = if (sel.start.row < top_abs) 0 else @intCast(sel.start.row - top_abs);
        const start_col: u16 = if (sel.start.row < top_abs) 0 else sel.start.col;
        const end_row: u16 = if (sel.end.row > bottom_abs) self.size.rows - 1 else @intCast(sel.end.row - top_abs);
        const end_col: u16 = if (sel.end.row > bottom_abs) self.size.cols - 1 else sel.end.col;
        return .{ .start = .{ .row = start_row, .col = start_col }, .end = .{ .row = end_row, .col = end_col } };
    }

    /// 선택된 텍스트를 추출한다(클립보드 복사용). 행 단위 선형 선택 — soft-wrap으로 이어진 행은
    /// 줄바꿈 없이 잇고, hard 줄끝에서만 \n을 넣는다. 각 행은 뒤 빈칸을 trim한다(soft 행 제외).
    pub fn extractSelection(self: *const TerminalCore, allocator: std.mem.Allocator) !?[]u8 {
        const sel = self.normalizedSelection() orelse return null;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        var abs = sel.start.row;
        while (abs <= sel.end.row) : (abs += 1) {
            const row_cells = self.absRow(abs) orelse continue;
            const wrapped_flag = self.absRowWrapped(abs);
            const from: usize = if (abs == sel.start.row) sel.start.col else 0;
            const full_to: usize = if (abs == sel.end.row) @min(@as(usize, sel.end.col) + 1, row_cells.len) else row_cells.len;
            // hard 줄끝(또는 선택 끝 행)은 뒤 빈칸을 잘라 복사한다 — 패딩이 텍스트로 들어가지 않게.
            const to: usize = if (wrapped_flag and abs != sel.end.row) full_to else @max(from, @min(full_to, trimmedLen(row_cells)));
            var c: usize = from;
            while (c < to) : (c += 1) {
                const cell = row_cells[c];
                if (cell.continuation) continue; // wide glyph 두 번째 칸은 base가 이미 실었다
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cell.codepoint, &buf) catch continue;
                try out.appendSlice(allocator, buf[0..n]);
                if (cell.combining) |mark| {
                    const m = std.unicode.utf8Encode(mark, &buf) catch 0;
                    if (m > 0) try out.appendSlice(allocator, buf[0..m]);
                }
            }
            if (abs != sel.end.row and !wrapped_flag) try out.append(allocator, '\n');
        }
        return try out.toOwnedSlice(allocator);
    }

    /// 절대 행 -> 셀(스크롤백 또는 활성 화면). 범위 밖이면 null.
    fn absRow(self: *const TerminalCore, abs: usize) ?[]const types.Cell {
        if (abs < self.sb_count) return self.scrollbackRow(abs);
        const active = abs - self.sb_count;
        if (active >= self.size.rows) return null;
        const start = @as(usize, @intCast(active)) * self.size.cols;
        return self.cells[start .. start + self.size.cols];
    }

    fn absRowWrapped(self: *const TerminalCore, abs: usize) bool {
        if (abs < self.sb_count) return self.scrollbackRowWrapped(abs);
        const active = abs - self.sb_count;
        if (active >= self.size.rows) return false;
        return self.wrapped[active];
    }

    /// 스크롤백을 비운다(ED 3). 행 버퍼는 해제하고 ring 슬롯 배열은 유지해 다음 push가 재할당
    /// 없이 다시 쓴다. 뷰포트는 바닥으로 스냅한다(지워진 과거를 보고 있을 수 없으니).
    fn clearScrollback(self: *TerminalCore) void {
        for (self.scrollback) |*slot| {
            if (slot.*) |cells_row| {
                self.allocator.free(cells_row);
                slot.* = null;
            }
        }
        self.sb_head = 0;
        self.sb_count = 0;
        self.view_offset = 0;
    }

    /// 스크롤백 전체를 새 폭으로 재-wrap한다(resize 시). 활성 화면 reflow와 같은 규칙을 ring에
    /// 적용한다: sb_wrapped로 논리 줄을 복원해 새 폭에 다시 자르고(hard 행 끝 빈칸은 trim, soft
    /// 행은 저장 폭 전체가 내용), wide glyph base가 행 끝에 안 들어가면 먼저 줄을 넘긴다. 재-wrap
    /// 행 수가 cap을 넘으면 가장 오래된 것부터 버린다. OOM이면 통째로 포기하고 기존 ring을
    /// 유지한다(best-effort — 잘못된 절반 상태보다 옛 폭 표시가 낫다).
    /// 지연된 스크롤백 재-wrap을 지금 수행한다(있다면). 과거를 보는 경로(scrollViewport/
    /// renderSnapshot)가 진입할 때 불러, 뷰가 항상 현재 폭 기준의 행 수/내용을 보게 한다.
    fn ensureScrollbackRewrapped(self: *TerminalCore) void {
        if (!self.sb_rewrap_pending) return;
        self.sb_rewrap_pending = false;
        self.rewrapScrollback(self.size.cols);
    }

    fn rewrapScrollback(self: *TerminalCore, new_cols: u16) void {
        if (self.sb_count == 0 or new_cols == 0) return;
        self.selectionClear(); // 행 좌표가 재배치된다 — 선택은 해제가 안전(다른 터미널도 동일)
        _ = self.rewrapScrollbackInner(new_cols, null) catch null;
    }

    /// 보던 위치(옛 스크롤백 행 anchor)를 유지하며 재-wrap한다. 과거를 보는 중 resize가 오면
    /// 바닥으로 튕기지 않고, 그 행이 재-wrap 후 어느 행이 됐는지로 view_offset을 재계산한다
    /// (Ghostty/iTerm2처럼 보던 내용이 그대로 보이게).
    fn rewrapScrollbackAnchored(self: *TerminalCore, new_cols: u16, anchor_row: usize) void {
        if (self.sb_count == 0 or new_cols == 0) return;
        self.selectionClear(); // rewrapScrollback과 동일 — 좌표 재배치

        const new_anchor = self.rewrapScrollbackInner(new_cols, anchor_row) catch {
            // 재-wrap 실패(OOM): ring이 그대로이므로 offset도 그대로 유효하다.
            return;
        };
        if (new_anchor) |row_index| {
            // 뷰 최상단이 그 행을 다시 가리키게: viewportRow(0) = sb_count - view_offset.
            self.view_offset = @min(self.sb_count - @min(row_index, self.sb_count), self.sb_count);
        } else {
            // 앵커 행이 cap 드랍으로 사라졌다 — 남은 가장 오래된 행(맨 위)으로.
            self.view_offset = self.sb_count;
        }
    }

    fn rewrapScrollbackInner(self: *TerminalCore, new_cols: u16, anchor_row: ?usize) !?usize {
        // 1차 패스: 출력 행 수만 센다(할당/복사 없음). cap을 넘는 앞쪽(가장 오래된) 행들은 어차피
        // 버려지므로 2차 패스에서 아예 생성하지 않는다 — 좁힘 재-wrap의 alloc 비용을 절반 가까이
        // 줄인다(perf 게이트 scrollback_rewrap이 1회 비용을 잰다).
        var total_out: usize = 0;
        {
            var i: usize = 0;
            while (i < self.sb_count) {
                var j = i;
                while (j + 1 < self.sb_count and self.scrollbackRowWrapped(j)) j += 1;
                total_out += self.countRewrapRows(i, j, new_cols);
                i = j + 1;
            }
        }
        const keep = @min(total_out, self.max_scrollback);
        const skip = total_out - keep; // 생성 없이 건너뛸 산출 행 수(가장 오래된 쪽)

        var rows: std.ArrayList([]types.Cell) = .empty;
        var wraps: std.ArrayList(bool) = .empty;
        // 성공 경로에선 행 소유권이 ring으로 넘어가므로(items.len = 0으로 비움), 이 defer는
        // 실패 경로에서만 만든 행들을 해제한다.
        defer {
            for (rows.items) |r| self.allocator.free(r);
            rows.deinit(self.allocator);
            wraps.deinit(self.allocator);
        }
        try rows.ensureTotalCapacity(self.allocator, keep);
        try wraps.ensureTotalCapacity(self.allocator, keep);

        var emitted: usize = 0; // 전체 산출 행 인덱스(skip 비교용)
        var anchor_out: ?usize = null; // anchor_row(옛 행)가 떨어진 새 행 인덱스(skip 반영 전)
        var i: usize = 0;
        while (i < self.sb_count) {
            // 논리 줄 [i, j]: 연속된 soft-wrap 행 + 마지막 행.
            var j = i;
            while (j + 1 < self.sb_count and self.scrollbackRowWrapped(j)) j += 1;
            // 줄의 마지막 산출 행이 물려받을 wrap 플래그: 논리 줄이 스크롤백의 끝을 넘어 활성
            // 화면으로 이어지면(마지막 행의 sb_wrapped=true) 그 경계 연속성을 보존한다.
            const tail_wrap = self.scrollbackRowWrapped(j);

            var cur: ?[]types.Cell = null;
            errdefer if (cur) |c| self.allocator.free(c);
            var oc: u16 = 0;

            var r = i;
            while (r <= j) : (r += 1) {
                // 앵커 옛 행이 시작되는 시점의 산출 행이 "보던 줄"의 새 위치다(셀 단위 정밀도까지는
                // 불필요 — 행 단위면 보던 내용이 화면 안에 유지된다).
                if (anchor_row != null and r == anchor_row.?) anchor_out = emitted;
                const src = self.scrollbackRow(r) orelse continue;
                // soft 행은 저장 폭 전체가 내용(꽉 찼다는 뜻), hard(마지막) 행은 뒤 빈칸 trim.
                const contrib: usize = if (r < j) src.len else trimmedLen(src);
                var c: usize = 0;
                while (c < contrib) : (c += 1) {
                    const cell = src[c];
                    const needs: u16 = if (cell.width == 2) 2 else 1;
                    if (oc + needs > new_cols) {
                        if (cur) |full| {
                            rows.appendAssumeCapacity(full);
                            wraps.appendAssumeCapacity(true);
                            cur = null;
                        }
                        emitted += 1;
                        oc = 0;
                    }
                    // skip 범위를 지나서야 행 버퍼를 만든다(버려질 행은 셀 스캔만 하고 할당 생략).
                    if (cur == null and emitted >= skip) {
                        cur = try self.allocator.alloc(types.Cell, new_cols);
                        @memset(cur.?, .{});
                    }
                    if (cur) |dst| dst[oc] = cell;
                    oc += 1;
                }
            }
            // 논리 줄의 마지막 행을 닫는다(내용이 전혀 없던 빈 줄도 한 행으로 보존).
            if (cur == null and emitted >= skip) {
                cur = try self.allocator.alloc(types.Cell, new_cols);
                @memset(cur.?, .{});
            }
            if (cur) |last| {
                rows.appendAssumeCapacity(last);
                wraps.appendAssumeCapacity(tail_wrap);
                cur = null;
            }
            emitted += 1;
            i = j + 1;
        }

        // 기존 ring 행을 비우고(슬롯 배열은 재사용) 새 행으로 채운다. ring이 아직 lazy 미할당이면
        // sb_count==0이라 여기 못 온다(가드).
        for (self.scrollback) |*slot| {
            if (slot.*) |old_row| {
                self.allocator.free(old_row);
                slot.* = null;
            }
        }
        for (rows.items, 0..) |row_cells, k| {
            self.scrollback[k] = row_cells;
            self.sb_wrapped[k] = wraps.items[k];
        }
        self.sb_head = 0;
        self.sb_count = rows.items.len;
        // 소유권 이전 완료 — defer가 이중 해제하지 않게 목록을 비운다.
        rows.items.len = 0;

        if (anchor_out) |a| {
            if (a >= skip) return a - skip; // cap 드랍을 반영한 새 행 인덱스
            return null; // 보던 행이 드랍됨
        }
        return null;
    }

    /// 논리 줄 [first, last]가 new_cols로 재-wrap될 때의 산출 행 수(할당/복사 없는 시뮬레이션).
    fn countRewrapRows(self: *const TerminalCore, first: usize, last: usize, new_cols: u16) usize {
        var count: usize = 0;
        var oc: u16 = 0;
        var r = first;
        while (r <= last) : (r += 1) {
            const src = self.scrollbackRow(r) orelse continue;
            const contrib: usize = if (r < last) src.len else trimmedLen(src);
            var c: usize = 0;
            while (c < contrib) : (c += 1) {
                const needs: u16 = if (src[c].width == 2) 2 else 1;
                if (oc + needs > new_cols) {
                    count += 1;
                    oc = 0;
                }
                oc += 1;
            }
        }
        return count + 1; // 마지막(열린) 행
    }

    /// 행 슬라이스의 내용 길이(뒤 빈칸 trim). 활성 화면의 trimmedRowLen과 같은 기준을 스크롤백
    /// 행(저장 폭이 현재와 다를 수 있음)에 적용한다.
    fn trimmedLen(row: []const types.Cell) usize {
        var len: usize = row.len;
        while (len > 0) : (len -= 1) {
            if (!isBlankCell(row[len - 1])) break;
        }
        return len;
    }

    /// 행을 스크롤백에 보관한다. OOM 등으로 실제 보관에 실패하면 false — 호출자(scroll-lock)는
    /// 보관된 경우에만 view_offset을 보정해야 보던 위치가 어긋나지 않는다.
    fn pushScrollback(self: *TerminalCore, row_cells: []const types.Cell, wrapped_flag: bool) bool {
        if (self.max_scrollback == 0) return false;
        if (self.scrollback.len == 0) {
            const ring = self.allocator.alloc(?[]types.Cell, self.max_scrollback) catch return false;
            @memset(ring, null);
            // wrap 병렬 ring도 함께 할당한다. 실패하면 둘 다 포기해 두 ring 길이를 항상 같게 유지한다.
            const wring = self.allocator.alloc(bool, self.max_scrollback) catch {
                self.allocator.free(ring);
                return false;
            };
            @memset(wring, false);
            self.scrollback = ring;
            self.sb_wrapped = wring;
        }
        const cap = self.scrollback.len;
        // 가득 차면 (sb_head+sb_count)%cap == sb_head라, 가장 오래된 슬롯을 재사용해 덮어쓴다.
        const idx = (self.sb_head + self.sb_count) % cap;
        if (self.scrollback[idx]) |existing| {
            if (existing.len == row_cells.len) {
                @memcpy(existing, row_cells);
            } else {
                const dup = self.allocator.dupe(types.Cell, row_cells) catch return false; // OOM이면 옛 행 유지
                self.allocator.free(existing);
                self.scrollback[idx] = dup;
            }
        } else {
            self.scrollback[idx] = self.allocator.dupe(types.Cell, row_cells) catch return false;
        }
        self.sb_wrapped[idx] = wrapped_flag;
        if (self.sb_count == cap) {
            self.sb_head = (self.sb_head + 1) % cap;
            // ring이 가득 차 가장 오래된 행이 밀려나면 절대 행 좌표가 한 칸 당겨진다 — 선택도
            // 따라 보정하고, 선택이 밀려난 행을 포함했으면 해제한다.
            self.shiftSelectionForEviction();
        } else {
            self.sb_count += 1;
        }
        return true;
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
            // IND(ESC D): index. CR 없이 한 줄 내림 + 하단 margin이면 scroll region을 위로 민다(LF와 동일).
            'D' => {
                self.lineFeed();
                self.parser = .ground;
            },
            // RI(ESC M): reverse index. 한 줄 올림 + 상단 margin이면 scroll region을 아래로 민다.
            'M' => {
                self.reverseIndex();
                self.parser = .ground;
            },
            // DECSC(ESC 7)/DECRC(ESC 8): 커서(위치+pen+pending_wrap) 저장/복원. claude CLI 등이
            // 시작 시 `ESC 7, CSI r, ESC 8`로 scroll region을 리셋하는데, CSI r의 부수효과(커서
            // home)를 ESC 8이 되돌린다 — 복원이 없으면 커서가 (0,0)에 남아 UI가 기존 화면 맨 위를
            // 덮는다. DECSET 1048과 같은 저장 슬롯을 쓴다(xterm 동일).
            '7' => {
                self.saveCursorState();
                self.parser = .ground;
            },
            '8' => {
                self.restoreCursorState();
                self.parser = .ground;
            },
            // ESC <intermediate>(0x20..0x2f) <final>: charset designation 등 2바이트 시퀀스.
            0x20...0x2f => self.parser = .escape_intermediate,
            // 그 밖의 ESC <final>(RIS, NEL 등)은 A1에서 소비만 한다.
            else => self.parser = .ground,
        }
    }

    fn beginCsi(self: *TerminalCore) void {
        self.csi_params = [_]u16{0} ** max_csi_params;
        self.csi_subparam = [_]bool{false} ** max_csi_params;
        // 항상 최소 1개의 (비어 있을 수도 있는) 파라미터가 있다고 본다.
        self.csi_param_count = 1;
        self.csi_has_digit = false;
        self.csi_marker = 0;
        self.csi_intermediate = 0;
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
            // private/marker bytes: < = > ? (예: CSI ? 25 h). 어떤 marker였는지 기억한다.
            0x3c...0x3f => self.csi_marker = byte,
            // intermediate bytes(공백~/): 같은 final이라도 다른 명령이 된다 — 바이트를 기억해
            // (intermediate, final) 튜플로 dispatch한다(아래 dispatchCsi).
            0x20...0x2f => self.csi_intermediate = byte,
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
        // intermediate가 붙은 시퀀스는 bare final과 다른 명령이다 — 아는 (intermediate, final)
        // 조합만 dispatch하고 나머지는 소비한다(Williams VT500 파서의 튜플 dispatch 의미).
        if (self.csi_intermediate != 0) {
            switch (self.csi_intermediate) {
                ' ' => switch (final) {
                    'q' => self.setCursorStyle(self.csiRawParam(0)), // DECSCUSR
                    else => {},
                },
                else => {}, // `$r`(DECCARA) 등 미지원 조합은 무시
            }
            return;
        }
        // marker별 처리: '?'는 DEC private mode(DECSET/DECRST), '>'는 secondary DA. 그 외 marker
        // 시퀀스(>m modifyOtherKeys, <u kitty 등)는 소비만 한다 — bare final로 흘리면 SGR 등을
        // 오염시킨다.
        if (self.csi_marker != 0) {
            switch (self.csi_marker) {
                '?' => switch (final) {
                    'h' => self.setPrivateModes(true),
                    'l' => self.setPrivateModes(false),
                    else => {},
                },
                '>' => switch (final) {
                    // DA2(CSI > c): 단말 버전 식별. DA1만 답하고 침묵하면 vim 등이 DA2 응답을
                    // 타임아웃까지 기다린다. VT220급(1), 버전 10, ROM 0으로 답한다.
                    'c' => if (self.csiRawParam(0) == 0) self.appendResponse("\x1b[>1;10;0c"),
                    else => {},
                },
                else => {},
            }
            return;
        }
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
            'n' => self.deviceStatusReport(),
            'r' => self.setScrollRegion(),
            'L' => self.insertLines(self.csiParam(0, 1)),
            'M' => self.deleteLines(self.csiParam(0, 1)),
            // DA1(CSI c / CSI 0 c): 터미널 식별 질의. 프로그램(claude CLI 등)이 시작 시 기능 협상
            // 으로 보내며, 응답이 없으면 타임아웃을 기다리거나 기능을 보수적으로 끈다. VT102로
            // 식별한다(CSI ?6c) — 현재 구현 수준(커서/erase/scroll region/IL/DL)과 부합.
            'c' => if (self.csiRawParam(0) == 0) self.appendResponse("\x1b[?6c"),
            else => {},
        }
    }

    /// DECSET(h)/DECRST(l)의 alternate-screen 계열 모드를 적용한다. 파라미터가 여러 개면 각각 적용.
    /// 47/1047=alt 전환만(둘의 차이인 "1047은 나갈 때 alt clear"는 alt 버퍼를 해제하는 현 구현에선
    /// 구분이 무의미하다), 1048=커서 저장/복원만, 1049=결합(들어갈 때 커서 저장+빈 alt, 나갈 때
    /// 커서 복원) — vim/less가 쓰는 표준 조합이다.
    fn setPrivateModes(self: *TerminalCore, set: bool) void {
        var i: usize = 0;
        while (i < self.csi_param_count) : (i += 1) {
            switch (self.csiRawParam(i)) {
                1 => self.application_cursor_keys = set, // DECCKM: 화살표 SS3/CSI 인코딩 전환
                25 => { // DECTCEM: 커서 표시/숨김. 커서 행만 다시 그리면 된다.
                    self.cursor_visible = set;
                    self.markDirty(self.cursor.row);
                },
                1007 => self.alternate_scroll = set, // alt screen 휠 -> 화살표 변환 on/off
                2004 => self.bracketed_paste = set, // bracketed paste(붙여넣기 감싸기)
                47, 1047 => if (set) self.enterAltScreen(false) else self.leaveAltScreen(false),
                1048 => if (set) self.saveCursorState() else self.restoreCursorState(),
                1049 => if (set) self.enterAltScreen(true) else self.leaveAltScreen(true),
                else => {}, // 그 외 private 모드(25 커서 표시 등)는 아직 소비만 한다.
            }
        }
    }

    /// 현재 활성 화면의 DECSC 저장 슬롯. ESC 7/8과 1048은 항상 "지금 보이는 화면"의 슬롯을 쓴다
    /// (xterm 동일). 1049의 enter(저장)/leave(복원)는 primary 슬롯을 쓴다 — 셸 커서를 보관했다가
    /// TUI 종료 시 되돌리는 용도라서다.
    fn activeSavedCursor(self: *TerminalCore) *SavedCursor {
        return if (self.alt_active) &self.saved_cursor_alt else &self.saved_cursor_primary;
    }

    fn saveCursorState(self: *TerminalCore) void {
        self.activeSavedCursor().* = .{
            .cursor = self.cursor,
            .pen = self.pen,
            .pending_wrap = self.pending_wrap,
        };
    }

    fn restoreCursorState(self: *TerminalCore) void {
        self.restoreFromSlot(self.activeSavedCursor().*);
    }

    fn restoreFromSlot(self: *TerminalCore, slot: SavedCursor) void {
        const old_cursor = self.cursor;
        self.cursor = .{
            .row = @min(slot.cursor.row, self.size.rows - 1),
            .col = @min(slot.cursor.col, self.size.cols - 1),
        };
        self.pen = slot.pen;
        self.pending_wrap = slot.pending_wrap;
        self.markCursorMoveDirty(old_cursor, self.cursor);
        self.last_print = null;
    }

    /// alt screen으로 전환한다. primary 그리드(cells/wrapped)를 saved_*로 옮기고 빈 alt 버퍼를
    /// 만든다(1049는 들어가며 clear — TUI가 어차피 전체를 그린다). 할당 실패면 전환하지 않는다
    /// (primary 유지가 안전 — 커서 저장도 두 할당이 성공한 뒤에 해 실패가 부작용 없게 한다).
    /// 1049의 커서 저장은 이미 alt여도 수행한다(xterm: "unconditionally saves the cursor").
    fn enterAltScreen(self: *TerminalCore, save_cursor: bool) void {
        if (self.alt_active) {
            // 화면은 이미 alt지만 1049h의 커서 저장 의미는 유지한다(중첩 tmux/SIGCONT 재초기화).
            if (save_cursor) self.saveCursorState();
            return;
        }

        const alt_cells = self.allocator.alloc(types.Cell, cellCount(self.size)) catch return;
        @memset(alt_cells, .{});
        const alt_wrapped = self.allocator.alloc(bool, self.size.rows) catch {
            self.allocator.free(alt_cells);
            return;
        };
        @memset(alt_wrapped, false);

        // 두 할당이 성공한 뒤에야 상태를 바꾼다(OOM 경로가 저장 슬롯을 오염시키지 않게).
        if (save_cursor) self.saveCursorState(); // primary 슬롯(아직 alt_active=false)
        self.saved_cells = self.cells;
        self.saved_wrapped = self.wrapped;
        self.cells = alt_cells;
        self.wrapped = alt_wrapped;
        self.alt_active = true;
        // alt에서 스크롤백 뷰는 잠긴다 — 보고 있던 과거는 닫는다.
        self.view_offset = 0;
        self.pending_wrap = false;
        self.last_print = null;
        self.dirty = fullDirty(self.size);
    }

    /// primary screen으로 복귀한다. alt 버퍼를 버리고 saved 그리드를 복원한다. 1049는 커서도
    /// primary 슬롯에서 복원해 vim 종료 시 프롬프트가 원래 자리로 돌아온다 — alt 안에서 TUI가
    /// ESC 7/8을 써도(alt 슬롯) 셸 커서는 안전하다. 1049l의 커서 복원은 이미 primary여도
    /// 수행한다(xterm 동작 — 방어적 `\e[?1049l` 정리 스크립트 호환).
    fn leaveAltScreen(self: *TerminalCore, restore_cursor: bool) void {
        if (!self.alt_active) {
            if (restore_cursor) self.restoreFromSlot(self.saved_cursor_primary);
            return;
        }
        self.allocator.free(self.cells);
        self.allocator.free(self.wrapped);
        self.cells = self.saved_cells;
        self.wrapped = self.saved_wrapped;
        self.saved_cells = &.{};
        self.saved_wrapped = &.{};
        self.alt_active = false;
        self.pending_wrap = false;
        self.last_print = null;
        if (restore_cursor) self.restoreFromSlot(self.saved_cursor_primary);
        self.dirty = fullDirty(self.size);
    }

    /// DECSCUSR(CSI Ps SP q): 커서 모양/깜빡임. 0|1=깜빡 block, 2=고정 block, 3=깜빡 underline,
    /// 4=고정 underline, 5=깜빡 bar, 6=고정 bar. 모르는 값은 무시한다. vim이 모드 전환마다 보낸다.
    fn setCursorStyle(self: *TerminalCore, param: u16) void {
        switch (param) {
            0, 1 => {
                self.cursor_shape = .block;
                self.cursor_blink = true;
            },
            2 => {
                self.cursor_shape = .block;
                self.cursor_blink = false;
            },
            3 => {
                self.cursor_shape = .underline;
                self.cursor_blink = true;
            },
            4 => {
                self.cursor_shape = .underline;
                self.cursor_blink = false;
            },
            5 => {
                self.cursor_shape = .bar;
                self.cursor_blink = true;
            },
            6 => {
                self.cursor_shape = .bar;
                self.cursor_blink = false;
            },
            else => return,
        }
        self.markDirty(self.cursor.row); // 모양이 바뀐 커서 칸을 다시 그린다
    }

    /// DSR(CSI Ps n): 호스트의 상태 질의에 응답한다. 응답은 response 버퍼에 쌓이고 app이 PTY로 되쓴다.
    /// 5n=터미널 OK(CSI 0n), 6n=커서 위치 보고(CPR, CSI row;col R, 1-indexed). zsh가 SIGWINCH
    /// redraw 때 6n으로 커서를 물으므로 응답이 없으면 redraw가 어긋난다(프롬프트 중복 등).
    fn deviceStatusReport(self: *TerminalCore) void {
        switch (self.csiRawParam(0)) {
            5 => self.appendResponse("\x1b[0n"),
            6 => {
                var buf: [40]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "\x1b[{d};{d}R", .{
                    self.cursor.row + 1,
                    self.cursor.col + 1,
                }) catch return;
                self.appendResponse(s);
            },
            else => {},
        }
    }

    fn appendResponse(self: *TerminalCore, bytes: []const u8) void {
        self.response.appendSlice(self.allocator, bytes) catch {}; // best-effort(OOM이면 응답 생략)
    }

    /// 아직 호스트(PTY)로 안 보낸 터미널 응답 바이트. app이 매 write 후 이걸 PTY로 쓰고 clearResponse한다.
    pub fn pendingResponse(self: *const TerminalCore) []const u8 {
        return self.response.items;
    }

    pub fn clearResponse(self: *TerminalCore) void {
        self.response.clearRetainingCapacity();
    }

    fn applySgr(self: *TerminalCore) void {
        const count = @min(self.csi_param_count, max_csi_params);
        var i: usize = 0;
        while (i < count) {
            const p = self.csi_params[i];
            switch (p) {
                0 => self.pen = .{},
                7 => self.pen.reverse = true,
                27 => self.pen.reverse = false,
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
        // 행의 오른쪽 끝을 지우면(mode 0=커서~끝, mode 2=전체) soft-wrap 연속성이 끊긴다. mode 1
        // (시작~커서)은 오른쪽 끝이 멀쩡해 줄이 여전히 다음 행으로 이어질 수 있으므로 wrapped를 끄지
        // 않는다 — 안 그러면 reflow가 한 논리 줄을 둘로 쪼갠다.
        if (mode != 1) self.wrapped[row] = false;
        self.markDirty(row);
        // 모든 EL 모드는 deferred autowrap을 무효화한다(xterm/Ghostty 동작). 안 끄면 마지막 칸
        // 출력(pending) 후 EL+글자 시퀀스가 한 줄 일찍 wrap돼 상대 커서 이동이 어긋난다.
        self.pending_wrap = false;
        // 다른 cursor/erase op과 같이 grapheme run을 끝낸다. 안 하면 CSI K 뒤 combining mark가
        // 방금 지운 셀에 붙는다.
        self.last_print = null;
    }

    fn eraseInDisplay(self: *TerminalCore, mode: u16) void {
        if (self.size.rows == 0 or self.size.cols == 0) return;
        // 모든 ED 모드는 deferred autowrap을 무효화한다(EL과 동일한 이유, xterm/Ghostty 동작).
        self.pending_wrap = false;
        const blank: types.Cell = .{ .style = self.pen };
        switch (mode) {
            // 2/3: 화면 전체. 3(xterm E3)은 저장된 줄(스크롤백)까지 지운다 — `clear`가 보내는
            // \e[3J의 핵심 의미로, 비밀 출력 후 history를 비우는 용도다.
            2, 3 => {
                @memset(self.cells, blank);
                @memset(self.wrapped, false);
                if (mode == 3) self.clearScrollback();
                self.dirty = fullDirty(self.size);
            },
            // 1: 화면 시작 ~ 커서까지.
            1 => {
                const cursor_index = self.index(self.cursor.row, self.cursor.col);
                var i: usize = 0;
                while (i <= cursor_index and i < self.cells.len) : (i += 1) self.cells[i] = blank;
                for (0..@min(@as(usize, self.cursor.row) + 1, self.wrapped.len)) |r| self.wrapped[r] = false;
                self.repairWideGlyphEdges(self.cursor.row, 0, @min(self.cursor.col + 1, self.size.cols));
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
                for (self.cursor.row..self.size.rows) |r| self.wrapped[r] = false;
                self.repairWideGlyphEdges(self.cursor.row, self.cursor.col, self.size.cols);
                self.markDirty(self.cursor.row);
                self.markDirty(self.size.rows - 1);
            },
        }
        self.last_print = null;
    }

    /// 행 끝의 빈 칸을 잘라낸 내용 길이.
    fn trimmedRowLen(self: *const TerminalCore, row: u16) u16 {
        var len: u16 = self.size.cols;
        while (len > 0) : (len -= 1) {
            if (!isBlankCell(self.cells[self.index(row, len - 1)])) break;
        }
        return len;
    }

    /// 기본 배경의 빈 공백 셀인지(reflow trim 기준). continuation/combining/배경색이 있으면 내용이다.
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

    /// 폭이 줄어 행 마지막 칸에 wide glyph base(width 2)만 남고 continuation이 잘렸으면 그 base를
    /// 비운다(한 칸 공간에 2칸 폭 half-glyph가 렌더되는 것 방지). 폭 축소로 내용을 clip하는 모든
    /// 경로(resize 커서 줄 verbatim, renderSnapshot 스크롤백 합성)가 공유한다.
    fn clearTruncatedWideBase(row: []types.Cell) void {
        if (row.len > 0 and row[row.len - 1].width == 2) row[row.len - 1] = .{};
    }

    /// reflow 출력 스크래치를 cap_rows×cols 이상으로 키운다(grow-only, 내용 보존 안 함).
    fn ensureReflowScratch(self: *TerminalCore, cap_rows: usize, cols: u16) !void {
        const need_cells = cap_rows * @as(usize, cols);
        if (self.reflow_cells.len < need_cells) {
            if (self.reflow_cells.len > 0) self.allocator.free(self.reflow_cells);
            self.reflow_cells = try self.allocator.alloc(types.Cell, need_cells);
        }
        if (self.reflow_wrapped.len < cap_rows) {
            if (self.reflow_wrapped.len > 0) self.allocator.free(self.reflow_wrapped);
            self.reflow_wrapped = try self.allocator.alloc(bool, cap_rows);
        }
    }

    /// 그리드를 reflow 없이 새 크기로 clip/pad해 복사한다(왼쪽 위 기준, 넘치는 내용은 버림).
    /// alt screen resize 등 재배치가 의미 없는 경로가 쓴다. 잘린 wide glyph base는 정리한다.
    fn copyRegionResize(
        allocator: std.mem.Allocator,
        src: []const types.Cell,
        old_rows: u16,
        old_cols: u16,
        next_size: types.Size,
    ) ![]types.Cell {
        const dst = try allocator.alloc(types.Cell, cellCount(next_size));
        @memset(dst, .{});
        const copy_rows = @min(old_rows, next_size.rows);
        const copy_cols = @min(old_cols, next_size.cols);
        var r: u16 = 0;
        while (r < copy_rows) : (r += 1) {
            const row_dst = dst[@as(usize, r) * next_size.cols ..][0..next_size.cols];
            @memcpy(row_dst[0..copy_cols], src[@as(usize, r) * old_cols ..][0..copy_cols]);
            clearTruncatedWideBase(row_dst);
        }
        return dst;
    }

    pub fn resize(self: *TerminalCore, cols_in: u16, rows_in: u16) !void {
        // grid를 최소 2칸×1행으로 맞춘다(clampGridSize 참고).
        const next_size = clampGridSize(.{ .cols = cols_in, .rows = rows_in });
        const new_cols = next_size.cols;
        const new_rows = next_size.rows;
        const old_rows = self.size.rows;
        const old_cols = self.size.cols;

        // alt screen 중 resize: reflow/스크롤백 없이 두 그리드(활성 alt + 저장된 primary)를 단순
        // clip/pad한다. TUI는 SIGWINCH로 전체를 다시 그리므로 alt 내용 재배치는 의미가 없고, 저장된
        // primary는 복귀 시 크기가 맞아야 한다(복귀 후 첫 resize부터 다시 reflow).
        if (self.alt_active) {
            const new_alt = try copyRegionResize(self.allocator, self.cells, old_rows, old_cols, next_size);
            errdefer self.allocator.free(new_alt);
            const new_saved = try copyRegionResize(self.allocator, self.saved_cells, old_rows, old_cols, next_size);
            errdefer self.allocator.free(new_saved);
            const new_wrapped = try self.allocator.alloc(bool, new_rows);
            errdefer self.allocator.free(new_wrapped);
            @memset(new_wrapped, false);
            const new_saved_wrapped = try self.allocator.alloc(bool, new_rows);
            @memset(new_saved_wrapped, false);
            // 살아남는 행의 soft-wrap 플래그는 보존한다. 특히 saved primary의 것을 버리면 복귀 후
            // 리사이즈에서 긴 wrap 줄이 영영 재합쳐지지 않는다(alt 것은 TUI가 다시 그리지만 동일
            // 규칙로 보존). 폭이 줄어 행이 clip돼도 논리 연속성 자체는 유지된다.
            const keep_rows = @min(old_rows, new_rows);
            @memcpy(new_wrapped[0..keep_rows], self.wrapped[0..keep_rows]);
            @memcpy(new_saved_wrapped[0..keep_rows], self.saved_wrapped[0..keep_rows]);

            self.allocator.free(self.cells);
            self.allocator.free(self.saved_cells);
            if (self.wrapped.len > 0) self.allocator.free(self.wrapped);
            if (self.saved_wrapped.len > 0) self.allocator.free(self.saved_wrapped);
            self.cells = new_alt;
            self.saved_cells = new_saved;
            self.wrapped = new_wrapped;
            self.saved_wrapped = new_saved_wrapped;
            self.size = next_size;
            self.scroll_top = 0;
            self.scroll_bottom = new_rows - 1;
            self.cursor.row = @min(self.cursor.row, new_rows - 1);
            self.cursor.col = @min(self.cursor.col, new_cols - 1);
            clampSavedCursor(&self.saved_cursor_primary, next_size);
            clampSavedCursor(&self.saved_cursor_alt, next_size);
            self.pending_wrap = false;
            self.last_print = null;
            // CSI 파서 상태/UTF-8 꼬리는 유지(아래 일반 경로와 동일한 이유).
            self.dirty = fullDirty(next_size);
            return;
        }

        // 스크롤백 재-wrap은 보통 지연 마크만 한다(폭이 그대로면 불변이라 생략). 즉시 하면 resize
        // 마다 O(스크롤백) 재할당이라 perf 예산(core_resize_loop)을 수십 배 넘는다 — 실제 재-wrap은
        // 사용자가 과거를 보는 순간(scrollViewport/renderSnapshot) 1회만 일어난다. 그 사이에 활성
        // reflow가 밀어내는 새 폭 행이 ring에 섞여도, 재-wrap은 행별 저장 폭 기준이라 혼재가 안전하다.
        // 단 지금 과거를 보는 중(view_offset>0)이면 즉시 재-wrap하면서 보던 행을 앵커로 offset을
        // 재계산한다 — 바닥으로 튕기지 않고 보던 내용이 유지된다(드물어서 1회 비용 수용).
        if (new_cols != old_cols and self.sb_count > 0) {
            if (self.view_offset > 0) {
                const anchor = self.sb_count - @min(self.view_offset, self.sb_count);
                self.rewrapScrollbackAnchored(new_cols, anchor);
                self.sb_rewrap_pending = false;
            } else {
                self.sb_rewrap_pending = true;
            }
        }

        // reflow: soft-wrap 플래그(wrapped)로 연속 줄(논리 줄)을 합쳐 새 폭에 다시 wrap한다. 넘치는
        // 위쪽 행은 스크롤백으로 밀어낸다. 핵심: 커서 위치는 어떤 셀이 나가는지/행이 soft인지를 절대
        // 바꾸지 않는다(hard 줄끝은 항상 hard로 남아 reflow가 프롬프트를 합치지 않는다 — 라이브 garble
        // 회귀의 근본 원인 차단). 커서의 trailing-blank는 내용을 늘리지 않고 좌표로만 환산한다.

        // 출력 행 상한을 계산해 스크래치를 확보한다(ArrayList realloc churn 제거).
        var total_content: usize = 0;
        {
            var r: u16 = 0;
            while (r < old_rows) : (r += 1) {
                total_content += if (self.wrapped[r]) old_cols else self.trimmedRowLen(r);
            }
        }
        // 출력 행 상한. soft-flush마다 행에 들어가는 최소 내용은 new_cols-1(줄 끝에서 wide glyph가
        // 한 칸을 못 채우고 넘어가는 경우)이므로 재배치 행 수는 total_content/(new_cols-1)로 막힌다.
        // (이전엔 /new_cols로 나눠 wide glyph의 열 낭비를 과소 계산 → 좁은 폭에서 스크래치 OOB였다.)
        // 2*old_rows는 verbatim 커서 줄(≤old_rows)+hard-flush 빈 행(≤old_rows)을, +4는 ceil/열린 행/
        // 방어 flush 여유다. new_cols>=2(clampGridSize)라 new_cols-1>=1.
        const cap_rows: usize = 2 * @as(usize, old_rows) + total_content / (new_cols - 1) + 4;
        try self.ensureReflowScratch(cap_rows, new_cols);
        const scratch = self.reflow_cells;
        const swrap = self.reflow_wrapped;
        const blank: types.Cell = .{};

        var out_rows: usize = 0;
        var oc: u16 = 0;
        @memset(scratch[0..new_cols], blank); // 열린 출력 행 0
        var cursor_out_row: ?usize = null;
        var cursor_out_col: u16 = 0;

        // 커서가 있는 논리 줄(wrapped run)의 범위. 이 줄은 reflow하지 않고 그대로 둔다 — 셸이
        // SIGWINCH로 직접 다시 그린다(xterm.js의 reflowCursorLine=false 기본 동작). 커서가 있는 줄을
        // 재배치하면 커서가 옮겨져, 옛 폭 기준으로 상대 이동(\e[A)하는 셸 redraw가 어긋나 프롬프트가
        // 중복된다. 그 줄은 셸이 알아서 새 폭으로 다시 그리므로 건드리지 않는 게 안전하다.
        var cur_start: u16 = self.cursor.row;
        while (cur_start > 0 and self.wrapped[cur_start - 1]) cur_start -= 1;
        var cur_end: u16 = self.cursor.row;
        while (cur_end + 1 < old_rows and self.wrapped[cur_end]) cur_end += 1;

        var old_r: u16 = 0;
        while (old_r < old_rows) {
            // 커서 줄: reflow 없이 각 옛 행을 그대로(새 폭으로 clip/pad) 출력한다. cur_start는 논리
            // 줄 시작이라 직전 줄이 닫혀 oc==0이다.
            if (old_r == cur_start) {
                var r: u16 = cur_start;
                while (r <= cur_end) : (r += 1) {
                    const dst0 = out_rows * new_cols;
                    @memset(scratch[dst0..][0..new_cols], blank);
                    const n = @min(old_cols, new_cols);
                    @memcpy(scratch[dst0..][0..n], self.cells[self.index(r, 0)..][0..n]);
                    clearTruncatedWideBase(scratch[dst0..][0..new_cols]);
                    swrap[out_rows] = self.wrapped[r];
                    if (r == self.cursor.row) {
                        cursor_out_row = out_rows;
                        cursor_out_col = @min(self.cursor.col, new_cols - 1);
                    }
                    out_rows += 1;
                }
                @memset(scratch[out_rows * new_cols ..][0..new_cols], blank);
                oc = 0;
                old_r = cur_end + 1;
                continue;
            }

            // 그 외 논리 줄은 새 폭으로 다시 wrap한다(이 줄엔 커서가 없다).
            const soft = self.wrapped[old_r];
            // 기여 길이: soft 행은 꽉 찼으므로 전체, hard 행은 뒤 빈칸을 잘라낸 길이.
            const contrib: u16 = if (soft) old_cols else self.trimmedRowLen(old_r);

            var c: u16 = 0;
            while (c < contrib) : (c += 1) {
                const cell = self.cells[self.index(old_r, c)];
                // wide glyph base가 출력 행 끝에 안 들어가면(continuation과 분리 방지) 먼저 soft flush.
                const needs: u16 = if (cell.width == 2) 2 else 1;
                if (oc + needs > new_cols) {
                    swrap[out_rows] = true;
                    out_rows += 1;
                    oc = 0;
                    @memset(scratch[out_rows * new_cols ..][0..new_cols], blank);
                }
                scratch[out_rows * new_cols + oc] = cell;
                oc += 1;
            }
            if (!soft) {
                // 논리 줄 끝: 부분 출력 행을 hard(wrapped=false)로 닫는다.
                swrap[out_rows] = false;
                out_rows += 1;
                oc = 0;
                @memset(scratch[out_rows * new_cols ..][0..new_cols], blank);
            }
            old_r += 1;
        }
        if (oc > 0) { // soft로 끝났는데 더 옛 행이 없음(방어)
            swrap[out_rows] = false;
            out_rows += 1;
        }

        // 콘텐츠 아래 빈 출력 행(빈 옛 행에서 나온 것)을 잘라낸다. 단 커서 행까지는 남긴다.
        var content_len = out_rows;
        while (content_len > 0) {
            const r = content_len - 1;
            if (cursor_out_row) |cr| {
                if (r <= cr) break;
            }
            if (swrap[r]) break;
            if (!outputRowBlank(scratch, r, new_cols)) break;
            content_len -= 1;
        }

        // 그리드보다 높으면 위(오래된)를 스크롤백으로 밀어낸다. 커서가 콘텐츠 아래면 그 행까지 포함.
        const occupied = if (cursor_out_row) |cr| @max(content_len, cr + 1) else content_len;
        const drop: usize = if (occupied > new_rows) occupied - new_rows else 0;
        const push_count = @min(drop, content_len);

        const next_cells = try self.allocator.alloc(types.Cell, cellCount(next_size));
        errdefer self.allocator.free(next_cells);
        @memset(next_cells, .{});
        const next_wrapped = try self.allocator.alloc(bool, new_rows);
        @memset(next_wrapped, false);

        // 밀려나는 위쪽 콘텐츠 행을 그 wrap 플래그와 함께 스크롤백으로(가장 오래된 것부터). 빈 행은
        // 스크롤백을 오염시키므로 보관하지 않는다(빈 화면 resize 등).
        var pr: usize = 0;
        while (pr < push_count) : (pr += 1) {
            if (!outputRowBlank(scratch, pr, new_cols)) {
                const pushed = self.pushScrollback(scratch[pr * new_cols ..][0..new_cols], swrap[pr]);
                // 과거를 보는 중이면 새로 밀려든 행만큼 offset도 올린다(scroll-lock — 보던 내용 유지).
                if (pushed and self.view_offset > 0) self.view_offset = @min(self.view_offset + 1, self.sb_count);
            }
        }

        // 남은 콘텐츠 행을 새 그리드 위쪽에 채운다.
        var dst: usize = 0;
        var src: usize = drop;
        while (src < content_len and dst < new_rows) {
            @memcpy(next_cells[dst * new_cols ..][0..new_cols], scratch[src * new_cols ..][0..new_cols]);
            next_wrapped[dst] = swrap[src];
            dst += 1;
            src += 1;
        }

        self.allocator.free(self.cells);
        if (self.wrapped.len > 0) self.allocator.free(self.wrapped);
        self.size = next_size;
        self.cells = next_cells;
        self.wrapped = next_wrapped;
        // scroll region margin은 화면 크기에 묶이므로 resize 때 전체로 리셋한다(xterm 동작).
        self.scroll_top = 0;
        self.scroll_bottom = new_rows - 1;

        // 커서 재배치: 기록한 출력 위치에서 스크롤아웃된 행 수를 빼고 grid 안으로 clamp.
        if (cursor_out_row) |cr_raw| {
            const r = cr_raw -| drop;
            self.cursor.row = @intCast(@min(r, @as(usize, new_rows - 1)));
            self.cursor.col = @min(cursor_out_col, new_cols - 1);
        } else {
            self.cursor.row = @min(self.cursor.row, new_rows - 1);
            self.cursor.col = @min(self.cursor.col, new_cols - 1);
        }

        // 스크롤 위치는 유지한다(과거를 보는 중이었으면 위의 anchored 재-wrap이 offset을 새 행
        // 수 기준으로 보정했고, 아래 overflow push의 scroll-lock 보정이 이어진다). 범위만 방어.
        self.view_offset = @min(self.view_offset, self.sb_count);
        self.dirty = fullDirty(next_size);
        // 옛 grid 좌표에 묶인 상태(grapheme run, deferred wrap)만 끊는다. CSI 파서 상태와
        // partial UTF-8 꼬리는 grid와 무관한 바이트 스트림 상태라 유지한다 — 리셋하면 PTY read
        // 경계로 쪼개진 시퀀스 한가운데에 resize가 끼었을 때 꼬리 바이트가 글자로 새고 SGR이
        // 유실된다(xterm도 resize에 파서를 리셋하지 않는다).
        self.last_print = null;
        self.pending_wrap = false;
    }

    pub fn snapshot(self: *const TerminalCore) types.RenderSnapshot {
        var cursor = self.cursor;
        cursor.visible = cursor.visible and self.cursor_visible; // DECTCEM(?25l)이면 숨김
        return .{
            .size = self.size,
            .cursor = cursor,
            .cursor_shape = self.cursor_shape,
            .cursor_blink = self.cursor_blink,
            .cells = self.cells,
            .dirty = self.dirty,
        };
    }

    /// 렌더용 snapshot. 바닥(view_offset==0)이면 snapshot()과 같다(합성 없음 — 일반 경로). 위로
    /// 스크롤한 상태면 뷰포트 윈도([스크롤백 ++ 활성])를 viewport_cells에 합성해 돌려준다. 스크롤백
    /// 행이 현재 폭과 다르면(resize) 폭에 맞춰 clamp/pad한다. 과거를 보는 중엔 커서를 숨긴다.
    /// 합성 버퍼는 스크롤 중에만 lazy 할당하므로 일반(바닥) 렌더 경로는 추가 비용이 없다.
    pub fn renderSnapshot(self: *TerminalCore) types.RenderSnapshot {
        if (self.view_offset == 0) return self.snapshot();
        self.ensureScrollbackRewrapped(); // 과거가 보이는 합성 직전, 행들을 현재 폭으로

        const needed = cellCount(self.size);
        if (self.viewport_cells.len != needed) {
            if (self.viewport_cells.len > 0) self.allocator.free(self.viewport_cells);
            self.viewport_cells = self.allocator.alloc(types.Cell, needed) catch {
                self.viewport_cells = &.{};
                return self.snapshot(); // OOM이면 활성 화면으로 폴백(스크롤 뷰 포기)
            };
        }

        const cols = self.size.cols;
        var r: u16 = 0;
        while (r < self.size.rows) : (r += 1) {
            const src = self.viewportRow(r);
            const dst = self.viewport_cells[@as(usize, r) * cols ..][0..cols];
            const n = @min(src.len, cols);
            @memcpy(dst[0..n], src[0..n]);
            if (n < cols) @memset(dst[n..cols], .{});
            // 스크롤백 행이 현재 폭보다 넓게 저장돼 clip되면 마지막 칸의 wide glyph base가 잘려
            // half-glyph로 렌더될 수 있다 — resize 경로와 같은 정리를 적용한다.
            clearTruncatedWideBase(dst);
        }

        return .{
            .size = self.size,
            // 과거를 보는 중엔 활성 커서가 화면 밖(아래)에 가려져 있으므로 커서를 숨긴다.
            .cursor = .{ .row = 0, .col = 0, .visible = false },
            .cells = self.viewport_cells,
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
        return input.encodeKey(event, buffer, self.encodeOptions());
    }

    /// 이 surface의 현재 입력 인코딩 모드. 키를 인코딩하는 쪽(keybinding resolver 경유 포함)이
    /// 매 키마다 읽어 전달한다 — DECCKM은 프로그램이 수시로 켜고 끈다(vim 진입/이탈).
    pub fn encodeOptions(self: *const TerminalCore) input.EncodeOptions {
        return .{ .application_cursor_keys = self.application_cursor_keys };
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
            // 다음 줄로 넘긴다. lineFeed가 pending_wrap을 끄므로 여기서 따로 끄지 않는다.
            // 이 행은 autowrap으로 다음 줄로 이어지는 soft-wrap이다(reflow가 이 플래그로 잇는다).
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
            // wide glyph를 통째로 다음 줄로 넘긴다 — 이 행은 soft-wrap으로 이어진다.
            self.wrapped[self.cursor.row] = true;
            self.cursor.col = 0;
            self.lineFeed();
        }

        const row = self.cursor.row;
        const col = self.cursor.col;
        // 이 행에 새로 쓰므로 wrap 상태를 리셋한다. 다시 채워 마지막 칸을 넘기면 위 autowrap 분기가
        // true로 재설정한다. 덕분에 셸이 한 줄을 다시 그리면(redraw) wrap 플래그가 스스로 교정된다.
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
        // LF(및 IND)는 deferred autowrap을 무효화한다. 비-scroll 분기는 markCursorMoveDirty가
        // 끄지만, scroll 분기(scrollRegionUp)는 그걸 안 거치므로 여기서 한 번에 끈다. 안 그러면
        // 마지막 행이 꽉 찬(pending_wrap) 상태에서 bare LF가 와도 플래그가 남아, 다음 printable
        // 글자가 또 한 줄 내려가(scroll) 직전 줄을 잃는다(이중 스크롤).
        self.pending_wrap = false;
        // 스크롤/이동으로 grapheme run이 끝난다 — 다음 combining mark가 옮겨진 셀에 붙지 않게.
        // (\n 경로는 writeCodepoint가 이미 끊지만 ESC D(IND)는 이 함수로 직행한다.)
        self.last_print = null;
        // 커서가 scroll region 하단 margin이면 region을 위로 스크롤(커서는 그대로). 그 외엔 화면
        // 끝 전까지 한 줄 내려간다(region 위/아래 모두 동일). scrollRegionUp의 fullDirty가 커서
        // 행까지 다시 칠하므로 scroll 분기는 cursor-move diff가 따로 필요 없다.
        if (self.cursor.row == self.scroll_bottom) {
            self.scrollRegionUp();
            return;
        }
        if (self.cursor.row + 1 < self.size.rows) {
            const old_cursor = self.cursor;
            self.cursor.row += 1;
            self.markCursorMoveDirty(old_cursor, self.cursor);
        }
    }

    /// RI(ESC M): 커서를 한 줄 올리고, scroll region 상단 margin이면 region을 아래로 스크롤한다.
    fn reverseIndex(self: *TerminalCore) void {
        if (self.size.rows == 0) return;
        self.pending_wrap = false;
        self.last_print = null; // IND와 동일 — 스크롤/이동으로 grapheme run 종료
        if (self.cursor.row == self.scroll_top) {
            self.scrollRegionDown();
            return;
        }
        if (self.cursor.row > 0) {
            const old_cursor = self.cursor;
            self.cursor.row -= 1;
            self.markCursorMoveDirty(old_cursor, self.cursor);
        }
    }

    /// scroll region [top, bottom]을 위로 한 줄 민다. top==0(화면 최상단)일 때만 밀려나는 줄을
    /// 스크롤백에 보관한다 — 화면 위로 나가는 줄만 history다. 부분 region(top>0)의 스크롤아웃은
    /// 버린다(xterm 동작). 기본 region [0, rows-1]이면 전체 화면 스크롤과 같다.
    fn scrollRegionUp(self: *TerminalCore) void {
        // alt screen의 출력은 history가 아니다(vim 화면이 스크롤백을 오염시키지 않게).
        const push = self.scroll_top == 0 and !self.alt_active;
        self.scrollRangeUp(self.scroll_top, self.scroll_bottom, 1, push);
    }

    fn scrollRegionDown(self: *TerminalCore) void {
        self.scrollRangeDown(self.scroll_top, self.scroll_bottom, 1);
    }

    /// [top, bottom] 범위를 위로 n줄 민다(아래쪽에 빈 줄 n개). push_history면 밀려나는 행들을
    /// 스크롤백에 보관한다 — LF 스크롤만 history고, DL(줄 삭제) 같은 편집 연산은 보관하지 않는다
    /// (xterm 동작). n줄을 한 번의 블록 이동으로 처리해 IL/DL n이 O(범위)다(줄당 반복 아님).
    fn scrollRangeUp(self: *TerminalCore, top: u16, bottom: u16, count: u16, push_history: bool) void {
        if (self.size.cols == 0 or self.size.rows == 0 or count == 0) return;
        // bottom == top(한 줄 범위)도 허용한다 — IL/DL이 region 마지막 행에서 그 행만 비운다.
        if (bottom < top or bottom >= self.size.rows) return;
        const span: u16 = bottom - top + 1;
        const n = @min(count, span);

        if (push_history) {
            var pr: u16 = 0;
            while (pr < n) : (pr += 1) {
                const pushed = self.pushScrollback(self.cells[self.index(top + pr, 0)..][0..self.size.cols], self.wrapped[top + pr]);
                // 과거를 보는 중(view_offset>0)이면 같은 내용을 계속 보도록 offset도 올린다
                // (scroll-lock). 보관 실패(OOM) 시엔 보정하지 않는다 — 뷰가 내용과 어긋나지 않게.
                if (pushed and self.view_offset > 0) self.view_offset = @min(self.view_offset + 1, self.sb_count);
            }
        }

        var row: u16 = top + n;
        while (row <= bottom) : (row += 1) {
            const dst_start = self.index(row - n, 0);
            const src_start = self.index(row, 0);
            @memcpy(
                self.cells[dst_start .. dst_start + self.size.cols],
                self.cells[src_start .. src_start + self.size.cols],
            );
            self.wrapped[row - n] = self.wrapped[row];
        }

        var blank_row: u16 = bottom + 1 - n;
        while (blank_row <= bottom) : (blank_row += 1) {
            const blank_start = self.index(blank_row, 0);
            @memset(self.cells[blank_start .. blank_start + self.size.cols], .{});
            self.wrapped[blank_row] = false;
        }
        // 범위 경계의 wrap 정합: shift가 old wrapped[bottom]("old bottom ↔ bottom+1" — 범위 밖과의
        // 연속)을 bottom-n으로 끌어왔는데, bottom+1은 안 움직였으니 그 연속은 깨졌다. 마찬가지로
        // 범위 위 행(top-1)이 주장하던 "top으로의 연속"도 top 내용이 바뀌어 깨졌다. 안 끊으면
        // 다음 resize reflow가 무관한 줄(상태줄 등)을 한 논리 줄로 합친다.
        if (bottom + 1 >= n and bottom + 1 - n > top) self.wrapped[bottom - n] = false;
        if (top > 0) self.wrapped[top - 1] = false;
        self.dirty = fullDirty(self.size);
    }

    /// [top, bottom] 범위를 아래로 n줄 민다(top쪽에 빈 줄 n개 삽입). 아래로 밀려나는 줄은
    /// history가 아니므로 버린다(스크롤백에 안 넣는다).
    fn scrollRangeDown(self: *TerminalCore, top: u16, bottom: u16, count: u16) void {
        if (self.size.cols == 0 or self.size.rows == 0 or count == 0) return;
        // bottom == top(한 줄 범위)도 허용한다(scrollRangeUp과 동일한 이유).
        if (bottom < top or bottom >= self.size.rows) return;
        const span: u16 = bottom - top + 1;
        const n = @min(count, span);

        var row: u16 = bottom;
        while (row >= top + n) : (row -= 1) {
            const dst_start = self.index(row, 0);
            const src_start = self.index(row - n, 0);
            @memcpy(
                self.cells[dst_start .. dst_start + self.size.cols],
                self.cells[src_start .. src_start + self.size.cols],
            );
            self.wrapped[row] = self.wrapped[row - n];
        }

        var blank_row: u16 = top;
        while (blank_row < top + n) : (blank_row += 1) {
            const blank_start = self.index(blank_row, 0);
            @memset(self.cells[blank_start .. blank_start + self.size.cols], .{});
            self.wrapped[blank_row] = false;
        }
        // 범위 경계의 wrap 정합(scrollRangeUp과 대칭): 새 bottom 행(=old bottom-n 내용)이 범위 밖
        // bottom+1로 이어진다는 플래그는 거짓이고, top-1 행의 "top으로의 연속"도 top이 빈 줄이 돼
        // 깨졌다.
        self.wrapped[bottom] = false;
        if (top > 0) self.wrapped[top - 1] = false;
        self.dirty = fullDirty(self.size);
    }

    /// IL(CSI Ps L): 커서 행에 빈 줄 n개를 삽입한다. 커서 행~region 하단이 아래로 밀리고 넘치는
    /// 줄은 버려진다. 커서가 scroll region 밖이면 무시. 후처리로 커서를 행 첫 칸으로 옮긴다(CR —
    /// xterm/DEC 동작). vim이 줄 열기/삭제를 전체 redraw 없이 하는 핵심 시퀀스.
    fn insertLines(self: *TerminalCore, count: u16) void {
        if (self.cursor.row < self.scroll_top or self.cursor.row > self.scroll_bottom) return;
        self.scrollRangeDown(self.cursor.row, self.scroll_bottom, count);
        self.pending_wrap = false;
        self.cursor.col = 0;
        self.last_print = null;
    }

    /// DL(CSI Ps M): 커서 행부터 n줄을 삭제한다. 아래 줄들이 올라오고 region 하단에 빈 줄이 생긴다.
    /// 삭제된 줄은 history가 아니다(스크롤백에 안 넣음). 커서가 region 밖이면 무시, 후처리 CR.
    fn deleteLines(self: *TerminalCore, count: u16) void {
        if (self.cursor.row < self.scroll_top or self.cursor.row > self.scroll_bottom) return;
        self.scrollRangeUp(self.cursor.row, self.scroll_bottom, count, false);
        self.pending_wrap = false;
        self.cursor.col = 0;
        self.last_print = null;
    }

    /// DECSTBM(CSI Pt ; Pb r): scroll region을 설정한다. 1-indexed, 기본 Pt=1·Pb=rows. region 안으로
    /// clamp하고 최소 2행이 아니면 무시한다. 설정 후 커서를 home(0,0)으로 옮긴다(DECOM off 기준).
    fn setScrollRegion(self: *TerminalCore) void {
        const rows = self.size.rows;
        if (rows == 0) return;
        const top: u16 = self.csiParam(0, 1) - 1;
        const bottom: u16 = @min(self.csiParam(1, rows), rows) - 1;
        if (top >= bottom or bottom >= rows) return; // 2행 미만이면 무시
        self.scroll_top = top;
        self.scroll_bottom = bottom;
        const old_cursor = self.cursor;
        self.cursor = .{ .row = 0, .col = 0 };
        self.pending_wrap = false;
        self.markCursorMoveDirty(old_cursor, self.cursor);
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

test "resize leaves the cursor's line verbatim when shrinking (shell redraws it)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 5, .rows = 1 });
    defer core.deinit();

    try core.write("hello");
    try core.resize(3, 1);

    // "hello"는 커서가 있는 줄이므로 reflow하지 않고 그대로 둔다(xterm.js 방식 — 셸이 SIGWINCH로
    // 다시 그린다). 새 폭(3)으로 clip돼 "hel"이 남고, 커서는 폭 안으로 clamp된다. 스크롤백 push 없음.
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("hel", dump);
    try std.testing.expectEqual(@as(usize, 0), core.scrollbackLen());
    try std.testing.expectEqual(@as(u16, 0), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 2), core.cursor.col); // col 4 -> clamp 2
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

test "resize clamps the cursor into the new bounds instead of resetting it" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 5, .rows = 3 });
    defer core.deinit();

    try core.write("\x1b[3;5H");
    try std.testing.expectEqual(@as(u16, 2), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 4), core.cursor.col);

    try core.resize(2, 2);
    try std.testing.expectEqual(@as(u16, 1), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 1), core.cursor.col);
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
    try core.write("\n"); // 바닥 bare LF -> scrollRegionUp 한 번(ABCD -> row 0), 컬럼은 보존
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

test "scrollback keeps rows that scroll off the top" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    // rows=2. 각 줄이 바닥에서 scroll될 때 맨 윗줄이 스크롤백으로 들어간다.
    try core.write("a\r\nb\r\nc\r\nd");
    // 'a' 줄과 'b' 줄이 밀려났다. 화면엔 c/d가 남는다.
    try std.testing.expectEqual(@as(usize, 2), core.scrollbackLen());
    try std.testing.expectEqual(@as(u21, 'a'), core.scrollbackRow(0).?[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), core.scrollbackRow(1).?[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'c'), core.cells[core.index(0, 0)].codepoint);
    try std.testing.expectEqual(@as(u21, 'd'), core.cells[core.index(1, 0)].codepoint);
}

test "scrollback ring drops the oldest rows past max_scrollback" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    core.max_scrollback = 2; // 첫 scroll 전에 cap을 작게 둔다(lazy 할당이 이 값을 쓴다).
    // a,b,c가 차례로 밀려난다(d/e는 화면에 남음). cap=2라 가장 최근 2개(b,c)만 남는다.
    try core.write("a\r\nb\r\nc\r\nd\r\ne");
    try std.testing.expectEqual(@as(usize, 2), core.scrollbackLen());
    try std.testing.expectEqual(@as(u21, 'b'), core.scrollbackRow(0).?[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'c'), core.scrollbackRow(1).?[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'd'), core.cells[core.index(0, 0)].codepoint);
    try std.testing.expectEqual(@as(u21, 'e'), core.cells[core.index(1, 0)].codepoint);
}

test "scrollback disabled when max_scrollback is zero" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    core.max_scrollback = 0;
    try core.write("a\r\nb\r\nc\r\nd");
    try std.testing.expectEqual(@as(usize, 0), core.scrollbackLen());
}

test "scrollViewport reveals scrollback at the top and scrollToBottom returns to active" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc\r\nd"); // 스크롤백=[a,b], 활성=[c,d]
    // 바닥(0): 활성 화면이 보인다.
    try std.testing.expectEqual(@as(u21, 'c'), core.viewportRow(0)[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'd'), core.viewportRow(1)[0].codepoint);
    // 1줄 위로: 윗줄에 가장 최근 스크롤백('b'), 아랫줄에 활성 첫 줄('c'). 'd'는 가려진다.
    core.scrollViewport(1);
    try std.testing.expectEqual(@as(usize, 1), core.viewOffset());
    try std.testing.expectEqual(@as(u21, 'b'), core.viewportRow(0)[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'c'), core.viewportRow(1)[0].codepoint);
    // 더 위로: 스크롤백 맨 위(a,b). 범위를 넘겨도 sb_count(2)로 clamp.
    core.scrollViewport(5);
    try std.testing.expectEqual(@as(usize, 2), core.viewOffset());
    try std.testing.expectEqual(@as(u21, 'a'), core.viewportRow(0)[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), core.viewportRow(1)[0].codepoint);
    // 바닥으로: 다시 활성.
    core.scrollToBottom();
    try std.testing.expectEqual(@as(usize, 0), core.viewOffset());
    try std.testing.expectEqual(@as(u21, 'c'), core.viewportRow(0)[0].codepoint);
}

test "scroll-lock keeps the viewport on the same content as new output scrolls in" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc"); // 스크롤백=[a], 활성=[b,c]
    core.scrollViewport(1); // 위로 -> 뷰는 'a','b'
    try std.testing.expectEqual(@as(u21, 'a'), core.viewportRow(0)[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), core.viewportRow(1)[0].codepoint);
    // 새 출력이 scroll돼 들어와도(b가 스크롤백으로), 뷰는 같은 'a','b'를 계속 보여준다(scroll-lock).
    try core.write("\r\nd");
    try std.testing.expectEqual(@as(usize, 2), core.viewOffset()); // offset이 함께 올라감
    try std.testing.expectEqual(@as(u21, 'a'), core.viewportRow(0)[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), core.viewportRow(1)[0].codepoint);
}

test "renderSnapshot shows active at bottom and composes the viewport (cursor hidden) when scrolled" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc\r\nd"); // 스크롤백=[a,b], 활성=[c,d], 커서 (1,1)

    // 바닥: 활성 화면 그대로 + 실제 커서(보임).
    const at_bottom = core.renderSnapshot();
    try std.testing.expectEqual(@as(u21, 'c'), at_bottom.cells[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'd'), at_bottom.cells[core.index(1, 0)].codepoint);
    try std.testing.expect(at_bottom.cursor.visible);

    // 맨 위로 스크롤: 뷰포트가 스크롤백(a,b)을 합성, 커서 숨김.
    core.scrollViewport(2);
    const scrolled = core.renderSnapshot();
    try std.testing.expectEqual(@as(u21, 'a'), scrolled.cells[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), scrolled.cells[core.index(1, 0)].codepoint);
    try std.testing.expect(!scrolled.cursor.visible);
}

test "wrapped flag: autowrap sets it, rewriting the row clears it" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("abcde"); // abcd가 row0를 채우고 'e'가 autowrap으로 row1로 넘어간다
    try std.testing.expect(core.wrapped[0]); // row0는 soft-wrap
    try std.testing.expect(!core.wrapped[1]); // row1은 아직 wrap 아님
    try core.write("\x1b[1;1Hxy"); // CUP (0,0) 후 짧게 다시 그림 -> wrapped[0] 리셋
    try std.testing.expect(!core.wrapped[0]);
}

test "wrapped flag: a wide glyph pushed whole to the next row marks soft-wrap" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("abc한"); // abc가 0..2를 채우고 한(width2)이 col3에 안 들어가 통째로 row1로
    try std.testing.expect(core.wrapped[0]);
}

test "wrapped flag: a hard line-end stays false even with the cursor parked past content" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 3 });
    defer core.deinit();
    try core.write("ab\r"); // 줄을 안 채운 프롬프트 + CR -> 커서 (0,0). row0는 hard 줄끝
    try std.testing.expect(!core.wrapped[0]);
    try core.write("\x1b[1;6H"); // 커서를 내용 너머(col5)로 이동 -> wrap은 안 변함
    try std.testing.expect(!core.wrapped[0]);
}

test "wrapped flag: scrolled-off soft-wrapped row carries its flag into scrollback" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("abcde"); // wrapped[0]=true (abcd가 'e'로 soft-wrap)
    try std.testing.expect(core.wrapped[0]);
    try core.write("\r\nfg"); // 바닥에서 scroll -> abcd(wrapped=true)가 스크롤백으로
    try std.testing.expectEqual(@as(usize, 1), core.scrollbackLen());
    try std.testing.expect(core.scrollbackRowWrapped(0));
}

test "wrapped flag: erase-in-display mode 2 clears all wrap flags" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("abcde"); // wrapped[0]=true
    try std.testing.expect(core.wrapped[0]);
    try core.write("\x1b[2J"); // 화면 전체 지움 -> 모든 wrap 플래그 false
    try std.testing.expect(!core.wrapped[0]);
}

test "reflow: the cursor's wrapped line is left unchanged, not re-wrapped" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("abcdef"); // 4칸에서 abcd|ef로 soft-wrap, 커서 (1,2)
    try std.testing.expect(core.wrapped[0]);
    try core.resize(8, 3); // 넓혀도 커서 줄이라 합치지 않고 그대로 둔다(셸이 다시 그림)
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("abcd    \nef      \n        ", dump);
    try std.testing.expect(core.wrapped[0]); // verbatim이라 wrap 플래그 유지
    try std.testing.expectEqual(@as(u16, 1), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 2), core.cursor.col);
}

test "reflow: a non-cursor wrapped line IS reflowed (joined on widen)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("abcdef\r\n"); // abcd|ef(행0~1)는 wrap, \r\n으로 커서를 행2로 -> abcdef는 커서 줄 아님
    try std.testing.expect(core.wrapped[0]);
    try std.testing.expectEqual(@as(u16, 2), core.cursor.row);
    try core.resize(8, 3); // 커서가 다른 줄이라 abcdef는 reflow돼 한 줄로 합쳐진다
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("abcdef  \n        \n        ", dump);
    try std.testing.expect(!core.wrapped[0]); // 합쳐져 더는 wrap 아님
    try std.testing.expectEqual(@as(u16, 1), core.cursor.row); // 커서(빈 줄)는 한 칸 위로
}

test "reflow: a cursor parked past content on its line clamps (line not reflowed)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 12, .rows = 3 });
    defer core.deinit();
    try core.write("abc\x1b[1;7H"); // "abc" 후 커서를 (0,6)로(내용 너머) — 커서 줄
    try std.testing.expectEqual(@as(u16, 6), core.cursor.col);
    try core.resize(4, 3); // 커서 줄이라 reflow 안 함. 커서는 새 폭으로 clamp(6 -> 3).
    try std.testing.expectEqual(@as(u16, 0), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 3), core.cursor.col);
    try std.testing.expect(!core.wrapped[0]);
}

test "reflow: a hard prompt line never merges into the next across repeated resizes (no cascade)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 4 });
    defer core.deinit();
    try core.write("ok\r\n"); // hard 프롬프트 줄
    try core.write("abcdefghij"); // 다음 줄부터 soft-wrap되는 긴 명령
    // 폭을 왕복해도 프롬프트는 항상 hard 줄로 남고 명령과 합쳐지지 않는다.
    try core.resize(4, 4);
    try core.resize(12, 4);
    try core.resize(6, 4);
    try std.testing.expect(!core.wrapped[0]); // 프롬프트 줄은 hard 유지(cascade 없음)
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expect(std.mem.startsWith(u8, dump, "ok")); // 첫 줄은 여전히 프롬프트
    try std.testing.expect(std.mem.indexOf(u8, dump, "okabc") == null); // 프롬프트에 명령이 안 붙음
}

test "DSR: CSI 6n replies with the cursor position (CPR, 1-indexed)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 5 });
    defer core.deinit();
    try core.write("\x1b[3;5H"); // 커서 (2,4) 0-indexed
    try core.write("\x1b[6n"); // CPR 질의
    try std.testing.expectEqualStrings("\x1b[3;5R", core.pendingResponse());
    core.clearResponse();
    try std.testing.expectEqual(@as(usize, 0), core.pendingResponse().len);
}

test "DSR: CSI 5n replies terminal-OK" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 3 });
    defer core.deinit();
    try core.write("\x1b[5n");
    try std.testing.expectEqualStrings("\x1b[0n", core.pendingResponse());
}

test "DSR: CPR reports the parked-cursor column at the last column" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("abcd"); // 마지막 칸을 채워 parked(pending_wrap), 커서 (0,3)
    try core.write("\x1b[6n");
    try std.testing.expectEqualStrings("\x1b[1;4R", core.pendingResponse()); // row1 col4(1-indexed)
}

test "reflow: many wide glyphs shrunk to a narrow width does not overflow the scratch" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 12 });
    defer core.deinit();
    // 비-커서 줄을 wide glyph로 가득 채운다(soft-wrap). 좁은 폭에서 wide glyph는 줄 끝 한 칸을
    // 낭비하며 wrap돼, 재배치 행 수가 옛 cap_rows(total_content/new_cols) 추정을 초과한다(힙 OOB였음).
    try core.write("한" ** 80); // 160칸 = 8행의 한(rows 0-7, soft-wrap)
    try core.write("\r\nx"); // 커서를 짧은 줄(아래)로 옮겨 한 줄이 비-커서가 되게 함
    try core.resize(3, 12); // 3칸으로 축소: 한 1개/행 -> ~80행 -> 옛 cap 초과(크래시 없어야)
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expect(dump.len > 0); // 크래시 없이 통과 + 내용 보존
    try std.testing.expect(core.scrollbackLen() > 0 or std.mem.indexOf(u8, dump, "한") != null);
}

test "eraseInLine mode 1 (erase to cursor) keeps the row's soft-wrap flag" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("abcde"); // abcd|e: wrapped[0]=true
    try std.testing.expect(core.wrapped[0]);
    try core.write("\x1b[1;2H\x1b[1K"); // CUP (0,1) 후 CSI 1K(시작~커서 지움) — 오른쪽 끝은 멀쩡
    try std.testing.expect(core.wrapped[0]); // mode 1은 wrap 연속성을 안 끊는다
}

test "renderSnapshot clears a wide-glyph base truncated by narrowing in a scrollback row" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 2 });
    defer core.deinit();
    try core.write("ab한c\r\nX\r\nY"); // "ab한c"(한 at cols 2-3)이 scroll돼 스크롤백으로
    try std.testing.expect(core.scrollbackLen() >= 1);
    try core.resize(3, 2); // 3칸: 스크롤백 행은 그대로 저장되나, 보일 땐 col 2의 한 base가 잘린다
    core.scrollViewport(@as(isize, @intCast(core.scrollbackLen()))); // 맨 위로
    const snap = core.renderSnapshot();
    // 잘린 한 base(width 2)가 마지막 칸에 남으면 half-glyph가 렌더된다 — 정리됐는지 확인.
    try std.testing.expect(snap.cells[2].width != 2);
}

test "DECSTBM confines scrolling to the region; partial region discards the scrolled-off line" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 4 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc\r\nd"); // 행0~3 = a,b,c,d
    try core.write("\x1b[2;3r"); // DECSTBM region = 행1~2(1-indexed 2;3), 커서 home으로
    try std.testing.expectEqual(@as(u16, 1), core.scroll_top);
    try std.testing.expectEqual(@as(u16, 2), core.scroll_bottom);
    try std.testing.expectEqual(@as(u16, 0), core.cursor.row); // DECSTBM은 커서를 home으로
    try core.write("\x1b[3;1H"); // 커서를 하단 margin(행2)로
    try core.write("\n"); // region [1,2] 위로 스크롤: b 버려지고 c가 행1로, 행2는 빈칸
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("a \nc \n  \nd ", dump); // 행0(a)·행3(d)는 그대로
    try std.testing.expectEqual(@as(usize, 0), core.scrollbackLen()); // top>0라 스크롤백 보관 안 함
    try std.testing.expectEqual(@as(u16, 2), core.cursor.row); // 커서는 하단 margin 유지
}

test "DECSTBM region at screen top pushes the evicted line to scrollback" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 4 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc\r\nd");
    try core.write("\x1b[1;3r"); // region = 행0~2(top==0), 커서 home
    try core.write("\x1b[3;1H"); // 하단 margin(행2)
    try core.write("\n"); // region [0,2] 위로: a는 화면 최상단에서 밀려나므로 스크롤백으로
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("b \nc \n  \nd ", dump);
    try std.testing.expectEqual(@as(usize, 1), core.scrollbackLen());
}

test "RI scrolls the region down when the cursor is at the top margin" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 4 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc\r\nd");
    try core.write("\x1b[1;3r"); // region 행0~2, 커서 home(행0=상단 margin)
    try core.write("\x1bM"); // RI: 상단 margin이라 region을 아래로 — 행0 빈칸, a->행1, b->행2
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("  \na \nb \nd ", dump); // 행3(d)는 region 밖이라 그대로
}

test "DECSTBM ignores an invalid (top>=bottom) region and keeps the prior one" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 4 });
    defer core.deinit();
    try core.write("\x1b[2;3r"); // region 행1~2 설정
    try core.write("\x1b[4;2r"); // top(3)>=bottom(1) -> 무시
    try std.testing.expectEqual(@as(u16, 1), core.scroll_top);
    try std.testing.expectEqual(@as(u16, 2), core.scroll_bottom);
}

test "resize resets the scroll region to full screen" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 4 });
    defer core.deinit();
    try core.write("\x1b[2;3r"); // region 행1~2
    try core.resize(2, 6);
    try std.testing.expectEqual(@as(u16, 0), core.scroll_top);
    try std.testing.expectEqual(@as(u16, 5), core.scroll_bottom); // 새 rows-1
}

test "DECSET 1049 switches to a cleared alt screen and restores primary + cursor on exit" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 3 });
    defer core.deinit();
    try core.write("one\r\ntwo");
    try std.testing.expectEqual(@as(u16, 1), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 3), core.cursor.col);

    try core.write("\x1b[?1049h"); // alt 진입: 커서 저장 + 빈 화면
    try std.testing.expect(core.alt_active);
    {
        const dump = try core.dumpUtf8(std.testing.allocator);
        defer std.testing.allocator.free(dump);
        try std.testing.expectEqualStrings("        \n        \n        ", dump);
    }
    try core.write("\x1b[1;1HALT"); // alt에 그리기

    try core.write("\x1b[?1049l"); // 복귀: primary 내용 + 커서 복원
    try std.testing.expect(!core.alt_active);
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("one     \ntwo     \n        ", dump);
    try std.testing.expectEqual(@as(u16, 1), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 3), core.cursor.col);
}

test "alt screen output never reaches the scrollback and the viewport is locked" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc"); // primary에서 한 줄 스크롤 -> 스크롤백 1
    try std.testing.expectEqual(@as(usize, 1), core.scrollbackLen());

    try core.write("\x1b[?1049h");
    try core.write("1\r\n2\r\n3\r\n4\r\n5"); // alt에서 여러 줄 스크롤
    try std.testing.expectEqual(@as(usize, 1), core.scrollbackLen()); // 그대로
    core.scrollViewport(1); // alt에선 잠김
    try std.testing.expectEqual(@as(usize, 0), core.view_offset);

    try core.write("\x1b[?1049l");
    core.scrollViewport(1); // primary 복귀 후엔 다시 동작
    try std.testing.expectEqual(@as(usize, 1), core.view_offset);
}

test "DECSET 47 switches screens without saving the cursor" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("hi"); // 커서 (0,2)
    try core.write("\x1b[?47h\x1b[2;5H"); // alt에서 커서 (1,4)로 이동
    try core.write("\x1b[?47l"); // 복귀: 1049와 달리 커서 비복원
    try std.testing.expect(!core.alt_active);
    try std.testing.expectEqual(@as(u16, 1), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 4), core.cursor.col);
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("hi      \n        ", dump); // primary 내용은 복원
}

test "DECSET 1048 saves and restores the cursor without switching screens" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("ab\x1b[?1048h"); // (0,2) 저장
    try core.write("\x1b[2;6H"); // (1,5)로 이동
    try core.write("\x1b[?1048l"); // 복원
    try std.testing.expect(!core.alt_active);
    try std.testing.expectEqual(@as(u16, 0), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 2), core.cursor.col);
}

test "resize while in the alt screen clips both grids and restores a matching primary" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 3 });
    defer core.deinit();
    try core.write("hello\r\nworld");
    try core.write("\x1b[?1049h\x1b[1;1HALTALT");
    try core.resize(4, 2); // alt 중 축소: 둘 다 clip/pad, 스크롤백 push 없음
    try std.testing.expectEqual(@as(usize, 0), core.scrollbackLen());
    {
        const dump = try core.dumpUtf8(std.testing.allocator);
        defer std.testing.allocator.free(dump);
        try std.testing.expectEqualStrings("ALTA\n    ", dump); // alt 잘림
    }
    try core.write("\x1b[?1049l"); // 복귀: 잘린 primary
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("hell\nworl", dump);
}

test "entering the alt screen twice is a no-op (no buffer leak/overwrite)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("ok");
    try core.write("\x1b[?1049h\x1b[?47h"); // 두 번째 enter는 무시
    try std.testing.expect(core.alt_active);
    try core.write("\x1b[?1049l");
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("ok  \n    ", dump);
}

test "CSI ?1h/l (DECCKM) flips arrow encoding between SS3 and CSI" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    var buffer: [input.encoded_key_buffer_len]u8 = undefined;
    // 기본(normal): CSI 형식
    try std.testing.expectEqualStrings("\x1b[A", try core.encodeKey(.{ .key = .arrow_up }, &buffer));
    try core.write("\x1b[?1h"); // vim이 켜는 application cursor mode
    try std.testing.expect(core.application_cursor_keys);
    try std.testing.expectEqualStrings("\x1bOA", try core.encodeKey(.{ .key = .arrow_up }, &buffer));
    try core.write("\x1b[?1l"); // 끄면 다시 normal
    try std.testing.expectEqualStrings("\x1b[A", try core.encodeKey(.{ .key = .arrow_up }, &buffer));
}

test "DECCKM combined with alt screen (vim startup sequence) round-trips" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    var buffer: [input.encoded_key_buffer_len]u8 = undefined;
    try core.write("\x1b[?1049h\x1b[?1h"); // vim 진입: alt screen + DECCKM
    try std.testing.expect(core.alt_active);
    try std.testing.expectEqualStrings("\x1bOB", try core.encodeKey(.{ .key = .arrow_down }, &buffer));
    try core.write("\x1b[?1l\x1b[?1049l"); // vim 종료
    try std.testing.expect(!core.alt_active);
    try std.testing.expectEqualStrings("\x1b[B", try core.encodeKey(.{ .key = .arrow_down }, &buffer));
}

test "CSI ?1007h/l toggles alternate scroll (default on)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try std.testing.expect(core.alternate_scroll); // iTerm2/Terminal.app처럼 기본 on
    try core.write("\x1b[?1007l");
    try std.testing.expect(!core.alternate_scroll);
    try core.write("\x1b[?1007h");
    try std.testing.expect(core.alternate_scroll);
}

test "IL inserts blank lines at the cursor, pushing rows down within the scroll region" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 4 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc\r\nd");
    try core.write("\x1b[2;1H\x1b[L"); // 커서 행1, IL 1: b/c가 내려가고 d는 밀려나감
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("a \n  \nb \nc ", dump);
    try std.testing.expectEqual(@as(u16, 0), core.cursor.col); // IL 후 CR
    try std.testing.expectEqual(@as(usize, 0), core.scrollbackLen()); // 편집 연산은 history 아님
}

test "DL deletes lines at the cursor, pulling rows up; scroll region confines both" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 4 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc\r\nd");
    try core.write("\x1b[2;1H\x1b[M"); // DL 1: b 삭제, c/d가 올라오고 바닥 빈 줄
    {
        const dump = try core.dumpUtf8(std.testing.allocator);
        defer std.testing.allocator.free(dump);
        try std.testing.expectEqualStrings("a \nc \nd \n  ", dump);
    }
    try std.testing.expectEqual(@as(usize, 0), core.scrollbackLen());

    // scroll region [1,2]에서 DL: region 밖(행0/3)은 불변, region 하단에만 빈 줄.
    try core.write("\x1b[1;1Ha\r\nb\r\nc\r\nd"); // 화면 재구성 a/b/c/d... 행0부터 덮어씀
    try core.write("\x1b[2;3r\x1b[2;1H\x1b[M"); // region 1~2, 커서 행1, DL
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("a \nc \n  \nd ", dump);
}

test "IL/DL are ignored when the cursor is outside the scroll region" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 4 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc\r\nd");
    try core.write("\x1b[2;3r"); // region 1~2
    try core.write("\x1b[4;1H\x1b[L\x1b[M"); // 커서 행3(밖): 둘 다 무시
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("a \nb \nc \nd ", dump);
}

test "DECTCEM (CSI ?25 l/h) hides and shows the cursor in snapshots" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try std.testing.expect(core.snapshot().cursor.visible);
    try core.write("\x1b[?25l");
    try std.testing.expect(!core.snapshot().cursor.visible);
    try std.testing.expect(!core.renderSnapshot().cursor.visible);
    try core.write("\x1b[?25h");
    try std.testing.expect(core.snapshot().cursor.visible);
}

test "SGR 7/27 set and clear reverse video on the pen (0 resets it too)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();
    try core.write("\x1b[7mX");
    try std.testing.expect(core.cells[0].style.reverse);
    try core.write("\x1b[27mY");
    try std.testing.expect(!core.cells[1].style.reverse);
    try core.write("\x1b[7m\x1b[0mZ"); // SGR 0이 reverse도 리셋
    try std.testing.expect(!core.cells[2].style.reverse);
}

test "DECSC/DECRC (ESC 7/8) save and restore the cursor around a DECSTBM reset (claude CLI startup)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 4 });
    defer core.deinit();
    try core.write("one\r\ntwo");
    // claude CLI 시작 시퀀스: ESC 7(저장), CSI r(region 리셋 — 부수효과로 커서 home), ESC 8(복원).
    try core.write("\x1b7\x1b[r\x1b8!");
    try std.testing.expectEqual(@as(u16, 1), core.cursor.row); // 복원돼 (1,3)에서 이어 그림
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("one     \ntwo!    \n        \n        ", dump);
}

test "DECRC restores the pen and clamps a cursor saved on a larger screen" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 4 });
    defer core.deinit();
    try core.write("\x1b[31m\x1b[3;5H\x1b7"); // 빨강 pen + (2,4) 저장
    try core.write("\x1b[0m\x1b[1;1H"); // pen 리셋 + 이동
    try core.write("\x1b8"); // 복원
    try std.testing.expectEqual(@as(u16, 2), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 4), core.cursor.col);
    try std.testing.expectEqual(types.Color{ .indexed = 1 }, core.pen.foreground);
    try core.resize(4, 2); // 저장 좌표보다 작은 화면으로
    try core.write("\x1b8"); // clamp돼 grid 안
    try std.testing.expect(core.cursor.row < 2 and core.cursor.col < 4);
}

test "DA1 (CSI c) answers with a VT102 identification over the response path" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b[c");
    try std.testing.expectEqualStrings("\x1b[?6c", core.pendingResponse());
    core.clearResponse();
    try core.write("\x1b[0c"); // 명시적 0도 동일
    try std.testing.expectEqualStrings("\x1b[?6c", core.pendingResponse());
}

test "DECSC inside the alt screen does not clobber the cursor saved by 1049 (per-screen slots)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 4 });
    defer core.deinit();
    try core.write("one\r\ntwo"); // 셸 커서 (1,3)
    try core.write("\x1b[?1049h"); // 셸 커서를 primary 슬롯에 저장
    try core.write("\x1b[3;5H\x1b7\x1b[1;1H\x1b8"); // alt 안에서 ESC 7/8 사용(claude 패턴)
    try std.testing.expectEqual(@as(u16, 2), core.cursor.row); // alt 슬롯 복원 동작
    try core.write("\x1b[?1049l!"); // 종료: primary 슬롯에서 셸 커서 복원
    try std.testing.expectEqual(@as(u16, 1), core.cursor.row);
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("one     \ntwo!    \n        \n        ", dump);
}

test "1049l on the primary screen still restores the saved cursor (xterm unconditional restore)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 3 });
    defer core.deinit();
    try core.write("ab\x1b[?1049h\x1b[?47l"); // 1049 진입 후 47로 이탈(커서 비복원 leave)
    try core.write("\x1b[3;7H"); // 커서를 멀리
    try core.write("\x1b[?1049l"); // 방어적 정리: primary지만 저장 커서 복원해야 한다
    try std.testing.expectEqual(@as(u16, 0), core.cursor.row);
    try std.testing.expectEqual(@as(u16, 2), core.cursor.col);
}

test "resize while in the alt screen preserves the saved primary's soft-wrap flags" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 4 });
    defer core.deinit();
    try core.write("abcdef"); // abcd|ef soft-wrap: wrapped[0]=true
    try std.testing.expect(core.wrapped[0]);
    try core.write("\x1b[?1049h");
    try core.resize(4, 3); // alt 중 행 수만 축소
    try core.write("\x1b[?1049l");
    try std.testing.expect(core.wrapped[0]); // primary 복원 후에도 wrap 메타데이터 생존
}

test "region scrolls break stale soft-wrap links at the range boundaries" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 4 });
    defer core.deinit();
    // 행2-3에 걸친 soft-wrap 줄을 만든다: 행0/1 채우고 "abcdef"(행2 abcd|행3 ef).
    try core.write("x\r\ny\r\nabcdef");
    try std.testing.expect(core.wrapped[2]);
    // 커서 행3에서 IL: 행3이 비고 wrapped[2]의 연속 주장은 깨져야 한다.
    try core.write("\x1b[L");
    try std.testing.expect(!core.wrapped[2]);
    // resize가 빈 행을 이전 줄에 합치지 않는다.
    try core.resize(8, 4);
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("x       \ny       \nabcd    \n        ", dump);
}

test "EL and ED clear the deferred-autowrap state (xterm behavior)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("abcd"); // 마지막 칸 채움 -> pending_wrap
    try std.testing.expect(core.pending_wrap);
    try core.write("\x1b[K!"); // EL 0 후 글자: wrap 없이 같은 행에 찍혀야 한다
    try std.testing.expectEqual(@as(u16, 0), core.cursor.row);
    try core.write("\x1b[2J");
    try std.testing.expect(!core.pending_wrap); // ED도 동일
}

test "a CSI split across writes survives a resize in between (parser state kept)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b[31"); // SGR 빨강의 앞부분(쪼개진 read)
    try core.resize(10, 3); // 시퀀스 한가운데 resize
    try core.write("mX"); // 꼬리 도착: 'm'은 글자가 아니라 SGR 완성이어야 한다
    try std.testing.expectEqual(@as(u21, 'X'), core.cells[0].codepoint);
    try std.testing.expectEqual(types.Color{ .indexed = 1 }, core.cells[0].style.foreground);
}

test "CSI sequences with intermediates are consumed, not dispatched as their bare final" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 4 });
    defer core.deinit();
    try core.write("\x1b[2;3r"); // region [1,2]
    try core.write("\x1b[1;1;2;2$r"); // DECCARA($r) — DECSTBM으로 오발동하면 region이 바뀐다
    try std.testing.expectEqual(@as(u16, 1), core.scroll_top);
    try std.testing.expectEqual(@as(u16, 2), core.scroll_bottom);
}

test "DA2 (CSI > c) is answered and '>'-marked sequences never leak into SGR" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b[>c");
    try std.testing.expectEqualStrings("\x1b[>1;10;0c", core.pendingResponse());
    core.clearResponse();
    try core.write("\x1b[>4;2m"); // modifyOtherKeys — SGR(4;2=underline)로 새면 안 된다
    try core.write("X");
    try std.testing.expect(!core.cells[0].style.underline);
}

test "ED 3 (CSI 3J) clears the scrollback while ED 2 keeps it" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc\r\nd"); // 스크롤백 2줄 생성
    try std.testing.expectEqual(@as(usize, 2), core.scrollbackLen());
    try core.write("\x1b[2J");
    try std.testing.expectEqual(@as(usize, 2), core.scrollbackLen()); // ED 2는 화면만
    core.scrollViewport(1);
    try std.testing.expectEqual(@as(usize, 1), core.view_offset);
    try core.write("\x1b[3J"); // E3: history까지 비우고 뷰포트도 바닥으로
    try std.testing.expectEqual(@as(usize, 0), core.scrollbackLen());
    try std.testing.expectEqual(@as(usize, 0), core.view_offset);
    try core.write("x\r\ny\r\nz"); // 비운 뒤 ring 재사용이 정상인지(커서가 바닥이라 2회 스크롤)
    try std.testing.expectEqual(@as(usize, 2), core.scrollbackLen());
}

test "IL/DL with count > 1 move the block once (CSI 2L / CSI 2M)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 4 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc\r\nd");
    try core.write("\x1b[1;1H\x1b[2L"); // 행0에 빈 줄 2개 삽입: _,_,a,b
    {
        const dump = try core.dumpUtf8(std.testing.allocator);
        defer std.testing.allocator.free(dump);
        try std.testing.expectEqualStrings("  \n  \na \nb ", dump);
    }
    try core.write("\x1b[2M"); // 행0부터 2줄 삭제: a,b,_,_
    const dump = try core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings("a \nb \n  \n  ", dump);
    try std.testing.expectEqual(@as(usize, 0), core.scrollbackLen());
}

test "scrollback rows re-wrap to the new width when the user scrolls back after a resize" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    // "abcdefgh" 한 줄(8칸 꽉 참 — hard)과 "xy"가 스크롤백으로 밀린다.
    try core.write("abcdefgh\r\nxy\r\n1\r\n2");
    try std.testing.expectEqual(@as(usize, 2), core.scrollbackLen());

    try core.resize(4, 2); // 좁힘: 스크롤백의 "abcdefgh"는 4칸 두 행이 되어야 한다
    core.scrollViewport(10); // 과거 보기(여기서 지연 재-wrap 수행) — 맨 위로
    try std.testing.expectEqual(@as(usize, 3), core.scrollbackLen()); // abcd|efgh|xy
    try std.testing.expectEqualSlices(u8, "abcd", &cellsText4(core.scrollbackRow(0).?));
    try std.testing.expectEqualSlices(u8, "efgh", &cellsText4(core.scrollbackRow(1).?));
    try std.testing.expect(core.scrollbackRowWrapped(0)); // abcd -> efgh 연속
    try std.testing.expect(!core.scrollbackRowWrapped(1)); // efgh는 hard 끝

    try core.resize(8, 2); // 다시 넓힘: 쪼개졌던 행이 한 행으로 합쳐져야 한다
    core.scrollViewport(10);
    try std.testing.expectEqual(@as(usize, 2), core.scrollbackLen());
    const joined = core.scrollbackRow(0).?;
    try std.testing.expectEqual(@as(u21, 'a'), joined[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'h'), joined[7].codepoint);
}

fn cellsText4(row: []const types.Cell) [4]u8 {
    var out: [4]u8 = .{ ' ', ' ', ' ', ' ' };
    for (row[0..@min(row.len, 4)], 0..) |cell, k| out[k] = @intCast(cell.codepoint);
    return out;
}

test "scrollback re-wrap keeps hard line boundaries separate and drops oldest rows past the cap" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    core.max_scrollback = 4; // 작은 cap으로 드랍 검증
    try core.write("aaaa\r\nbb\r\ncccc\r\ndd\r\n1\r\n2"); // 4줄이 스크롤백(각각 hard)
    try std.testing.expectEqual(@as(usize, 4), core.scrollbackLen());

    try core.resize(2, 2); // 2칸: aaaa->aa|aa, bb->bb, cccc->cc|cc, dd->dd = 6행 > cap 4
    core.scrollViewport(10);
    try std.testing.expectEqual(@as(usize, 4), core.scrollbackLen()); // 오래된 2행 드랍
    // 남은 것은 최신 4행: cc, cc, dd 쪽이 보존되고 hard 경계(bb/cccc 사이 등)는 안 합쳐졌다.
    const last = core.scrollbackRow(3).?;
    try std.testing.expectEqual(@as(u21, 'd'), last[0].codepoint);
    try std.testing.expect(!core.scrollbackRowWrapped(3));
}

test "scrollback re-wrap is deferred until the scrollback is actually viewed" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("abcdefgh\r\n1\r\n2");
    try std.testing.expectEqual(@as(usize, 1), core.scrollbackLen());
    try core.resize(4, 2);
    // 아직 안 봤으니 ring은 옛 폭 그대로(지연) — 행 수 불변.
    try std.testing.expect(core.sb_rewrap_pending);
    try std.testing.expectEqual(@as(usize, 1), core.scrollbackLen());
    core.scrollViewport(1); // 보는 순간 재-wrap
    try std.testing.expect(!core.sb_rewrap_pending);
    try std.testing.expectEqual(@as(usize, 2), core.scrollbackLen());
}

test "resize while scrolled back keeps the viewed scrollback row anchored (Ghostty tracked-pin semantics)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    // 스크롤백 4행: aaaa / abcdefgh / cccc / dddd (모두 hard).
    try core.write("aaaa\r\nabcdefgh\r\ncccc\r\ndddd\r\n1\r\n2");
    try std.testing.expectEqual(@as(usize, 4), core.scrollbackLen());
    core.scrollViewport(3); // 뷰 최상단 = 스크롤백 행1("abcdefgh")
    try std.testing.expectEqual(@as(u21, 'a'), core.viewportRow(0)[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), core.viewportRow(0)[1].codepoint);

    try core.resize(4, 2); // 좁힘: abcdefgh -> abcd|efgh. 보던 행("abcd...")이 그대로 보여야 한다.
    try std.testing.expect(core.view_offset > 0); // 바닥으로 안 튕김
    const top = core.viewportRow(0);
    try std.testing.expectEqual(@as(u21, 'a'), top[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), top[1].codepoint);

    try core.resize(8, 2); // 다시 넓힘(행 합쳐져 sb_count 감소): 여전히 같은 내용이 보인다.
    const top2 = core.viewportRow(0);
    try std.testing.expectEqual(@as(u21, 'a'), top2[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), top2[1].codepoint);
    try std.testing.expect(core.view_offset <= core.scrollbackLen()); // Ghostty 회귀 클래스(범위 초과) 방어
}

test "resize overflow pushed to scrollback keeps the scrolled view in place (scroll-lock)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 4 });
    defer core.deinit();
    try core.write("aa\r\nbb\r\ncc\r\ndd\r\nee\r\nff"); // 스크롤백 2(aa,bb) + 화면 cc,dd,ee,ff
    core.scrollViewport(2); // 맨 위(aa)를 본다
    try std.testing.expectEqual(@as(u21, 'a'), core.viewportRow(0)[0].codepoint);
    try core.resize(4, 2); // 행 수 축소: 화면 위쪽이 스크롤백으로 밀린다(overflow push)
    // 보던 행(aa)이 여전히 뷰 최상단이어야 한다 — push마다 offset이 같이 올라갔어야(scroll-lock).
    try std.testing.expectEqual(@as(u21, 'a'), core.viewportRow(0)[0].codepoint);
}

test "DECSCUSR (CSI Ps SP q) sets the cursor shape and blink" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try std.testing.expectEqual(types.CursorShape.block, core.cursor_shape); // 기본 blink block
    try std.testing.expect(core.cursor_blink);
    try core.write("\x1b[5 q"); // 깜빡 bar(vim 삽입 모드가 흔히 씀)
    try std.testing.expectEqual(types.CursorShape.bar, core.cursor_shape);
    try std.testing.expect(core.cursor_blink);
    try core.write("\x1b[4 q"); // 고정 underline
    try std.testing.expectEqual(types.CursorShape.underline, core.cursor_shape);
    try std.testing.expect(!core.cursor_blink);
    try core.write("\x1b[0 q"); // 0 -> 기본(깜빡 block)
    try std.testing.expectEqual(types.CursorShape.block, core.cursor_shape);
    try std.testing.expect(core.snapshot().cursor_shape == .block);
    try core.write("\x1b[9 q"); // 모르는 값은 무시
    try std.testing.expectEqual(types.CursorShape.block, core.cursor_shape);
}

test "selection extracts text across soft-wrapped and hard rows (scrollback + active)" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    // "abcdef"(abcd|ef soft-wrap) + "hi" — abcd가 스크롤백으로 밀린 상태를 만든다.
    try core.write("abcdef\r\nhi\r\nx");
    try std.testing.expectEqual(@as(usize, 2), core.scrollbackLen()); // abcd, ef

    // 스크롤백 행0(abcd)부터 활성 행0(x 이전의 hi... 레이아웃: sb=[abcd,ef], 화면=[hi, x])
    core.scrollViewport(2); // 맨 위 — 뷰포트 [abcd, ef]
    core.selectionStart(0, 0); // abs 0 (abcd 시작)
    core.selectionExtend(1, 3); // abs 1 (ef 행 끝)
    const text = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(text);
    // soft-wrap 경계는 줄바꿈 없이 이어진다: "abcdef"
    try std.testing.expectEqualStrings("abcdef", text);

    // hard 경계를 포함한 선택: ef(abs1) ~ hi(abs2, 활성 행0)
    core.selectionStart(1, 0);
    core.scrollToBottom(); // 선택은 절대 좌표라 스크롤해도 유지
    core.selectionExtend(0, 3); // 바닥 뷰포트 행0 = abs2(hi)
    const text2 = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(text2);
    try std.testing.expectEqualStrings("ef\nhi", text2);
}

test "selection span clips to the viewport and follows scrolling" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc\r\nd"); // sb=[a,b], 화면=[c,d]
    core.selectionStart(0, 0); // abs 2(c)
    core.selectionExtend(1, 1); // abs 3(d)
    const span = core.selectionViewportSpan().?;
    try std.testing.expectEqual(@as(u16, 0), span.start.row);
    try std.testing.expectEqual(@as(u16, 1), span.end.row);

    core.scrollViewport(2); // 위로 — 선택(c,d)은 화면 밖
    try std.testing.expect(core.selectionViewportSpan() == null);
    core.scrollViewport(-1); // 한 줄 내림 — 뷰포트 [b, c]: 선택 시작(c)이 행1에 보인다
    const span2 = core.selectionViewportSpan().?;
    try std.testing.expectEqual(@as(u16, 1), span2.start.row);
    try std.testing.expectEqual(@as(u16, 1), span2.end.row); // d는 아래로 클립
    try std.testing.expectEqual(@as(u16, 3), span2.end.col);
}

test "selection survives new output until eviction shifts it off the ring" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    core.max_scrollback = 2;
    try core.write("a\r\nb\r\nc"); // sb=[a], 화면=[b,c]
    core.selectionStart(0, 0);
    core.selectionExtend(0, 0); // abs 0 = "a"(스크롤백 첫 행 — 화면 첫 행 b가 아님? 뷰포트 행0=b... )
    // 주: 바닥 뷰포트 행0 = abs sb_count(1)=b. 위 선택은 b를 가리킨다.
    try core.write("\r\nd"); // 스크롤 1회: sb=[a,b] (cap 2, eviction 없음) — 선택 abs는 불변(내용 b 유지)
    const t1 = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(t1);
    try std.testing.expectEqualStrings("b", t1);
    try core.write("\r\ne"); // 또 스크롤: cap 도달, a가 evict — 선택(b)은 -1 보정돼 유지
    const t2 = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(t2);
    try std.testing.expectEqualStrings("b", t2);
    try core.write("\r\nf"); // b도 evict — 선택이 ring 밖으로: 해제
    try std.testing.expect(core.selection_anchor == null);
}

test "double-click selects the word run, extending across a soft-wrap boundary" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 3 });
    defer core.deinit();
    try core.write("ab cdefghij kl"); // 8칸: "ab cdefg"|"hij kl" — 단어 cdefghij가 wrap을 넘는다
    try std.testing.expect(core.wrapped[0]);

    core.selectWordAt(0, 4); // 행0 col4('e') 더블클릭
    const text = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("cdefghij", text); // wrap 경계 너머까지 한 단어

    core.selectWordAt(1, 4); // 행1 col4 ('k') — 같은 행 안 단어
    const text2 = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(text2);
    try std.testing.expectEqualStrings("kl", text2);

    core.selectWordAt(0, 2); // 공백 더블클릭 -> 해제
    try std.testing.expect(core.selection_anchor == null);
}

test "triple-click selects the whole logical line including wrapped rows" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 3 });
    defer core.deinit();
    try core.write("abcdef\r\nxy"); // abcd|ef(논리 한 줄) + xy
    core.selectLineAt(1); // wrap된 두 번째 행을 트리플클릭해도 논리 줄 전체
    const text = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("abcdef", text);
}

test "encodePaste normalizes newlines and wraps with bracketed paste when DECSET 2004 is on" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    // 기본(비-bracketed): \r\n/\n -> \r 정규화만.
    const plain = try core.encodePaste(std.testing.allocator, "a\r\nb\nc");
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("a\rb\rc", plain);

    try core.write("\x1b[?2004h"); // zsh/claude가 켜는 bracketed paste
    const wrapped_paste = try core.encodePaste(std.testing.allocator, "ls\n");
    defer std.testing.allocator.free(wrapped_paste);
    try std.testing.expectEqualStrings("\x1b[200~ls\r\x1b[201~", wrapped_paste);

    try core.write("\x1b[?2004l");
    try std.testing.expect(!core.bracketed_paste);
}

test "extractUrlAt finds an http(s) URL in the clicked word, across soft-wrap, trimming punctuation" {
    var core = try TerminalCore.init(std.testing.allocator, .{ .cols = 12, .rows = 3 });
    defer core.deinit();
    try core.write("see (https://a.bc/dpath)."); // 12칸 wrap: "see (https:/"|"/a.bc/dpath)"|"."
    try std.testing.expect(core.wrapped[0]);

    // wrap된 URL의 두 번째 행을 Cmd+클릭해도 전체 URL이 나오고, 끝 ")."는 다듬어진다.
    const url = (try core.extractUrlAt(std.testing.allocator, 1, 3)).?;
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://a.bc/dpath", url);

    // URL이 아닌 단어는 null.
    try std.testing.expect((try core.extractUrlAt(std.testing.allocator, 0, 0)) == null);
    // 공백도 null.
    try std.testing.expect((try core.extractUrlAt(std.testing.allocator, 0, 3)) == null);
}
