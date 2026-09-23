//! sticky scroll — 제품 배선(docs/native-editor-visual-mapping.md §4.1i).
//!
//! 프레임마다 ① 스코프 출처를 고르고(심볼 2층 → 심볼 1층 → 접힘 범위, 앞이 비었을 때만 다음) ② 줄 → 화면 행 두 함수(접힘·줄바꿈을 안다)를
//! 만들어 순수 층(`session.editor.sticky.select`)에 넘기고 ③ caret 이 덮일 칸부터 걷은 뒤 ④ 머리줄의 글자·구문 색을 모아 프레임에 싣는다.
//! 그린 줄은 기억해 두었다가 클릭·호버가 읽는다(그 행은 본문이 아니라 머리줄이다).
const std = @import("std");
const maru = @import("maru");
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const Term = app_session_mod.Term;
const editor_ops = @import("editor.zig");
const editor_syntax = @import("editor_syntax.zig");
const chrome_editor = maru.chrome.components.editor_view;
const frame = chrome_editor.frame;
const sticky = maru.session.editor.sticky;
const Symbol = editor_syntax.syntax.Provider.Symbol;
const ColorSpan = chrome_editor.content.ColorSpan;

/// 지금 스코프를 낸 출처(§4.1i). 관측·판정자가 읽는다.
pub const Source = enum { none, lsp, syntax, fold };

pub const State = struct {
    /// 스코프(머리줄 오름차순 · 같으면 끝 내림차순). 키가 같으면 다시 안 만든다.
    scopes: std.ArrayList(sticky.Scope) = .empty,
    source: Source = .none,
    key: Key = .{},
    /// 1층 심볼(tree-sitter) — 키가 바뀔 때만 다시 센다(트리를 걷는 값이 싸지 않다).
    tree_symbols: std.ArrayList(Symbol) = .empty,
    tree_key_version: u64 = std.math.maxInt(u64),
    tree_key_pending: bool = true,
    picks: std.ArrayList(u32) = .empty,
    lines: [frame.sticky_max_rows]frame.StickyLine = undefined,
    color_store: std.ArrayList(ColorSpan) = .empty,
    bufs: editor_syntax.ColorBufs = .{},
    /// 지난 프레임에 **그린** 머리줄(문서 줄, 바깥부터). 클릭·호버가 읽는다.
    drawn: [frame.sticky_max_rows]u32 = undefined,
    drawn_len: usize = 0,

    const Key = struct { source: Source = .none, version: u64 = 0, ptr: usize = 0, len: usize = 0 };

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.scopes.deinit(allocator);
        self.tree_symbols.deinit(allocator);
        self.picks.deinit(allocator);
        self.color_store.deinit(allocator);
        self.bufs.deinit(allocator);
        self.* = .{};
    }
};

/// 이번 프레임의 머리줄(바깥부터). 꺼져 있거나 설 것이 없으면 빈 목록 — 그때도 `drawn_len` 은 0 으로 맞춘다.
pub fn compute(self: *AppSession, term: *Term, pane_rect: maru.chrome.draw.Rect, wrap: bool) []const frame.StickyLine {
    const st = &term.rt.editor_sticky;
    st.drawn_len = 0;
    const cfg = self.loaded_config.config.editor;
    if (!cfg.sticky_scroll) return &.{};
    // 비교 뷰·병합 판(§4.1i). **오늘 등가다**(적대적 1회차 P3) — 이 함수를 부르는 자리(`appendPaneFrame` 의 단일 편집기 갈래)가 그 뷰에서는
    // 안 돈다. 그래서 `drawn_len` 이 남는 문제는 `rowAt` 이 따로 막는다.
    if (term.rt.editor_diff != null or term.rt.editor_merge != null) return &.{};
    const doc = term.rt.editor_doc orelse return &.{};
    const ch: u32 = @max(self.cell_height_px, 1);
    const visible_rows: usize = pane_rect.h / ch;
    const max = sticky.maxLines(cfg.sticky_scroll_max_lines, visible_rows);
    if (max == 0) return &.{};
    refreshScopes(self, term) catch return &.{};
    if (st.scopes.items.len == 0) return &.{};

    const rows = Rows.of(term, wrap);
    sticky.select(self.allocator, st.scopes.items, rows, max, &st.picks) catch return &.{};
    var n = st.picks.items.len;
    // **caret 을 덮지 않는다**(§4.1i 「다른 점」 ①) — caret 이 칸 k 에 있으면 k 부터 아래는 안 그린다.
    if (term.rt.editor_selection) |sel| {
        const focus = @min(sel.focus, doc.file.content.len);
        const caret_line: u32 = @intCast(doc.file.lines.lineAt(focus));
        if (rows.headRow(caret_line)) |r| {
            if (r >= 0 and r < @as(i64, @intCast(n))) n = @intCast(r);
        }
    }
    if (n == 0) return &.{};

    // 머리줄의 글자·구문 색(1층·2층 — 인레이 없이: 고정 행은 힌트를 안 그린다).
    st.color_store.clearRetainingCapacity();
    var spans: [frame.sticky_max_rows]struct { lo: usize, hi: usize } = undefined;
    const visible_lines = term.rt.editor_lines;
    var k: usize = 0;
    for (st.picks.items[0..n]) |line| {
        const v = visibleOf(term.rt.editor_visible_numbers, line, visible_lines.len) orelse continue;
        const per_line = editor_syntax.lineColorsInto(
            &term.rt.editor_syntax,
            &st.bufs,
            self.allocator,
            doc.file.content,
            doc.file.lines,
            v,
            1,
            term.rt.editor_tab_width,
            term.rt.editor_visible_numbers,
            .inherit,
            editor_ops.semantic_client.spans(term),
            &.{},
        );
        const lo = st.color_store.items.len;
        if (v < per_line.len) st.color_store.appendSlice(self.allocator, per_line[v]) catch {};
        spans[k] = .{ .lo = lo, .hi = st.color_store.items.len };
        st.lines[k] = .{ .number = @as(usize, line) + 1, .bytes = visible_lines[v] };
        st.drawn[k] = line;
        k += 1;
    }
    for (0..k) |i| st.lines[i].colors = st.color_store.items[spans[i].lo..spans[i].hi];
    st.drawn_len = k;
    return st.lines[0..k];
}

/// 스코프 출처를 고르고(키가 바뀌었을 때만) 목록을 다시 만든다.
fn refreshScopes(self: *AppSession, term: *Term) error{OutOfMemory}!void {
    const st = &term.rt.editor_sticky;
    const doc = term.rt.editor_doc orelse return;
    const version = term.rt.editor_lsp_version;
    // ① 심볼 2층.
    if (editor_ops.symbols_client.list(term)) |l| {
        if (l.len > 0) {
            const key: State.Key = .{ .source = .lsp, .version = version, .ptr = @intFromPtr(l.ptr), .len = l.len };
            if (!std.meta.eql(key, st.key)) try fromSymbols(self, st, doc, l, key);
            return;
        }
    }
    // ② 심볼 1층 — 트리가 있고 이어 파는 중이 아닐 때만(§2.1a).
    if (!term.rt.editor_syntax.pending) {
        if (term.rt.editor_syntax.provider) |*prov| {
            if (st.tree_key_version != version or st.tree_key_pending) {
                prov.symbols(self.allocator, &st.tree_symbols);
                st.tree_key_version = version;
                st.tree_key_pending = false;
            }
            if (st.tree_symbols.items.len > 0) {
                const key: State.Key = .{ .source = .syntax, .version = version, .ptr = @intFromPtr(st.tree_symbols.items.ptr), .len = st.tree_symbols.items.len };
                if (!std.meta.eql(key, st.key)) try fromSymbols(self, st, doc, st.tree_symbols.items, key);
                return;
            }
        }
    } else st.tree_key_pending = true;
    // ③ 접힘 범위(지금 선 층 — LSP · tree-sitter · 들여쓰기).
    const folds = term.rt.editor_fold_ranges;
    const key: State.Key = .{ .source = .fold, .version = version, .ptr = @intFromPtr(folds.ptr), .len = folds.len };
    if (std.meta.eql(key, st.key)) return;
    st.scopes.clearRetainingCapacity();
    for (folds) |r| try st.scopes.append(self.allocator, .{ .head = r.head, .end = r.last_hidden +| 1 }); // 끝 = 닫는 줄(VS Code 와 같다)
    sticky.sortScopes(st.scopes.items);
    st.source = if (folds.len > 0) .fold else .none;
    st.key = key;
}

/// 심볼 → 스코프 — 머리줄은 **이름 줄**(`name_start`), 끝은 `end − 1` 의 줄(닫는 줄).
fn fromSymbols(self: *AppSession, st: *State, doc: anytype, list: []const Symbol, key: State.Key) error{OutOfMemory}!void {
    st.scopes.clearRetainingCapacity();
    for (list) |sym| {
        const sc = symbolScope(doc.file.lines, doc.file.content.len, sym) orelse continue;
        try st.scopes.append(self.allocator, sc);
    }
    sticky.sortScopes(st.scopes.items);
    st.source = key.source;
    st.key = key;
}

/// 심볼 하나 → 스코프(§4.1i). 머리줄은 **이름 줄**(`name_start` — 데코레이터·주석이 아니라), 끝은 **`end − 1` 의 줄**(`end` 는 배타 — 다음
/// 줄 0 열에서 끝나는 범위도 닫는 줄에서 끝난다). 빈 범위·뒤집힌 범위는 `null`.
pub fn symbolScope(lines: maru.session.editor.line_index.LineIndex, content_len: usize, sym: Symbol) ?sticky.Scope {
    if (sym.end <= sym.start) return null;
    const head: u32 = @intCast(lines.lineAt(@min(sym.name_start, content_len)));
    const end: u32 = @intCast(lines.lineAt(@min(sym.end - 1, content_len)));
    if (end < head) return null;
    return .{ .head = head, .end = end };
}

/// 줄 → 화면 행(§4.1i). 접힘은 `editor_visible_numbers`, 줄바꿈은 렌더와 같은 `piecesOfLine` 이 안다.
const Rows = struct {
    term: *Term,
    first: usize,
    first_piece: u32,
    wrap: bool,
    cols: u16,
    axis_len: usize,

    fn of(term: *Term, wrap: bool) Rows {
        const cols = term.rt.editor_hit_geom.content_width;
        return .{
            .term = term,
            .first = term.rt.editor_first_line,
            .first_piece = if (wrap) term.rt.editor_first_piece else 0,
            .wrap = wrap and cols > 0,
            .cols = cols,
            .axis_len = term.rt.editor_lines.len,
        };
    }

    pub fn headRow(self: Rows, line: u32) ?i64 {
        const v = visibleOf(self.term.rt.editor_visible_numbers, line, self.axis_len) orelse return null;
        return self.rowOf(v);
    }

    pub fn lastRow(self: Rows, line: u32) ?i64 {
        const v = lastVisibleAtOrBefore(self.term.rt.editor_visible_numbers, line, self.axis_len) orelse return null;
        return self.rowOf(v) + @as(i64, self.pieces(v)) - 1;
    }

    fn pieces(self: Rows, v: usize) u32 {
        if (!self.wrap) return 1;
        return editor_ops.piecesOfLine(self.term, v, self.cols);
    }

    /// 보이는 줄 `v` 의 첫 조각의 화면 행. 위로 올라간 줄은 음수(크기는 대략 — 칸 비교에는 부호만 쓰인다), 화면 아래로 멀리 간 줄은
    /// 하한만 준다(각 줄이 한 행 이상이라 `v − first` 이상이다 — 칸이 10 을 안 넘으므로 그것으로 충분하다).
    fn rowOf(self: Rows, v: usize) i64 {
        if (v < self.first) return -@as(i64, @intCast(self.first - v));
        const dist: i64 = @intCast(v - self.first);
        if (!self.wrap) return dist;
        if (v == self.first) return -@as(i64, self.first_piece);
        if (dist > @as(i64, frame.sticky_max_rows) + 2) return dist;
        var r: i64 = @as(i64, self.pieces(self.first)) - @as(i64, self.first_piece);
        var i = self.first + 1;
        while (i < v) : (i += 1) r += self.pieces(i);
        return r;
    }
};

/// 문서 줄 → 보이는 줄(접혀 숨으면 `null`). `numbers` 는 보이는 줄마다의 1-based 문서 줄(오름차순, 드물게 `null`) — 이분 탐색.
pub fn visibleOf(numbers: []const ?u32, doc_line: u32, axis_len: usize) ?usize {
    if (numbers.len == 0) return if (doc_line < axis_len) doc_line else null;
    const k = lowerBound(numbers, doc_line + 1) orelse return null;
    return if (numbers[k] != null and numbers[k].? == doc_line + 1) k else null;
}

/// 문서 줄 이하에서 마지막으로 보이는 줄.
pub fn lastVisibleAtOrBefore(numbers: []const ?u32, doc_line: u32, axis_len: usize) ?usize {
    if (numbers.len == 0) return if (axis_len == 0) null else @min(doc_line, axis_len - 1);
    const want = doc_line + 1;
    // 첫 `> want` 자리 바로 앞의 값 있는 칸.
    var k: usize = lowerBound(numbers, want + 1) orelse numbers.len;
    while (k > 0) {
        k -= 1;
        if (numbers[k]) |n| {
            if (n <= want) return k;
        }
    }
    return null;
}

/// 값이 `want` 이상인 첫 칸(값 없는 칸은 앞으로 건너뛰며 본다). 없으면 `null`.
fn lowerBound(numbers: []const ?u32, want: u32) ?usize {
    var lo: usize = 0;
    var hi: usize = numbers.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        var m = mid;
        while (m < hi and numbers[m] == null) m += 1;
        if (m == hi) {
            hi = mid;
            continue;
        }
        if (numbers[m].? < want) lo = m + 1 else hi = mid;
    }
    var k = lo;
    while (k < numbers.len and numbers[k] == null) k += 1;
    return if (k < numbers.len) k else null;
}

/// 창 좌표 → 지난 프레임에 그린 머리줄의 칸(`null` 이면 고정 행이 아니다). 클릭·호버의 첫 판정.
pub fn rowAt(term: *Term, y_px: f64) ?usize {
    const st = &term.rt.editor_sticky;
    if (st.drawn_len == 0) return null;
    // **비교 뷰·병합 판에서는 고정 행이 없다** — 그 뷰는 `compute` 를 안 부르므로 `drawn_len` 이 마지막 단일 편집기 프레임의 값으로 남는다.
    // 이 줄이 없으면 같은 Term 을 비교 뷰로 바꾼 뒤 위쪽 행의 클릭·호버·⌘클릭이 옛 머리줄로 가로채였다(적대적 1회차 P3 을 따지다 발견 — STK11).
    if (term.rt.editor_diff != null or term.rt.editor_merge != null) return null;
    if (!std.math.isFinite(y_px)) return null;
    const geom = term.rt.editor_hit_geom;
    if (geom.cell_h_px == 0) return null;
    const rel = y_px - @as(f64, @floatFromInt(geom.body_y));
    if (rel < 0) return null;
    const row: usize = @intFromFloat(@floor(rel / @as(f64, @floatFromInt(geom.cell_h_px))));
    return if (row < st.drawn_len) row else null;
}

/// 고정 행 클릭(§4.1i) — 그 줄·누른 열에 caret(선택 없음)을 두고, 그 줄이 **자기 칸 행**에 오게 스크롤한다(부모 고정 줄 아래에 보인다).
/// 소비했으면 `true`.
pub fn click(self: *AppSession, term: *Term, x_px: f64, y_px: f64) bool {
    const row = rowAt(term, y_px) orelse return false;
    const st = &term.rt.editor_sticky;
    const doc = term.rt.editor_doc orelse return false;
    const line_no = st.drawn[row];
    const line = doc.file.lines.line(line_no) orelse return false;
    const text = doc.file.content[line.start..line.contentEnd()];
    const geom = term.rt.editor_hit_geom;
    const rel_x: i64 = @as(i64, @intFromFloat(@floor(x_px))) - @as(i64, geom.body_x) - @as(i64, geom.content_left_px);
    const byte: usize = if (rel_x < 0) 0 else chrome_editor.content.byteAtPointWith(
        text,
        geom.tab_width,
        0,
        0,
        term.rt.editor_first_col,
        geom.content_width,
        @intCast(rel_x),
        geom.cell_w_px,
        &.{},
    );
    // caret — 여분 커서는 정리한다(본문 클릭과 같은 규칙, §9.1).
    if (term.rt.editor_extra_selections.len > 0) self.allocator.free(term.rt.editor_extra_selections);
    term.rt.editor_extra_selections = &.{};
    term.rt.editor_selection = maru.session.editor.selection.Selection.at(line.start + @min(byte, text.len));
    editor_ops.breakUndoGroup(term);
    // 스크롤 — 그 줄이 행 `row` 에 오게(위로 올라가 있던 줄이다).
    if (visibleOf(term.rt.editor_visible_numbers, line_no, term.rt.editor_lines.len)) |v| {
        term.rt.editor_first_line = v -| row;
        term.rt.editor_first_piece = 0;
    }
    self.metal_dirty = true;
    return true;
}

const testing = std.testing;

test "STK10 보이는 줄 찾기 — 접힌 줄은 없고, 값 없는 칸(정렬로 끼운 빈 줄)은 건너뛰며, 「이하의 마지막 보이는 줄」 (§4.1i)" {
    // 문서 줄 0·1·2 가 보이고 3..9 가 접혔으며(머리 2) 10·11 이 보인다. 값 없는 칸이 하나 끼었다. 1-based.
    const numbers = [_]?u32{ 1, 2, 3, null, 11, 12 };
    try testing.expectEqual(@as(?usize, 0), visibleOf(&numbers, 0, numbers.len));
    try testing.expectEqual(@as(?usize, 2), visibleOf(&numbers, 2, numbers.len));
    try testing.expectEqual(@as(?usize, null), visibleOf(&numbers, 5, numbers.len)); // 접혔다
    try testing.expectEqual(@as(?usize, 4), visibleOf(&numbers, 10, numbers.len)); // 값 없는 칸 뒤
    try testing.expectEqual(@as(?usize, 5), visibleOf(&numbers, 11, numbers.len));
    try testing.expectEqual(@as(?usize, null), visibleOf(&numbers, 12, numbers.len)); // 문서 밖
    // 이하의 마지막 보이는 줄.
    try testing.expectEqual(@as(?usize, 2), lastVisibleAtOrBefore(&numbers, 7, numbers.len)); // 접힌 줄 → 머리
    try testing.expectEqual(@as(?usize, 4), lastVisibleAtOrBefore(&numbers, 10, numbers.len));
    try testing.expectEqual(@as(?usize, 5), lastVisibleAtOrBefore(&numbers, 40, numbers.len));
    try testing.expectEqual(@as(?usize, 0), lastVisibleAtOrBefore(&numbers, 0, numbers.len));
    // 접힘이 없으면 두 축이 같다.
    try testing.expectEqual(@as(?usize, 7), visibleOf(&.{}, 7, 20));
    try testing.expectEqual(@as(?usize, null), visibleOf(&.{}, 20, 20));
    try testing.expectEqual(@as(?usize, 19), lastVisibleAtOrBefore(&.{}, 50, 20));
}

test "STK13 심볼 → 스코프 — 머리줄은 이름 줄(데코레이터가 아니라), 끝은 end−1 의 줄(다음 줄 0 열에서 끝나도 닫는 줄) (§4.1i)" {
    const content = "@dec\nclass A {\n  x\n}\nnext\n";
    var lines = try maru.session.editor.line_index.build(testing.allocator, content);
    defer lines.deinit();
    const name: u32 = @intCast(std.mem.indexOf(u8, content, "A {").?);
    const close_nl: u32 = @intCast(std.mem.indexOf(u8, content, "}").? + 1); // `}` 다음(개행)
    const next: u32 = @intCast(std.mem.indexOf(u8, content, "next").?); // 다음 줄 0 열
    const base: Symbol = .{ .name_start = name, .name_end = name + 1, .start = 0, .end = close_nl, .start_row = 0, .depth = 0, .kind = "class_declaration" };
    const a = symbolScope(lines, content.len, base).?;
    try testing.expectEqual(@as(u32, 1), a.head); // 이름 줄(0 번 줄 `@dec` 가 아니다)
    try testing.expectEqual(@as(u32, 3), a.end);
    var to_next = base;
    to_next.end = next; // 범위가 다음 줄 0 열에서 끝난다(서버가 그렇게 내기도 한다)
    try testing.expectEqual(@as(u32, 3), symbolScope(lines, content.len, to_next).?.end);
    var empty = base;
    empty.end = empty.start;
    try testing.expect(symbolScope(lines, content.len, empty) == null);
}
