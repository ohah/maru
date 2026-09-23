//! 구조 기반 선택 확장 — 제품 배선(docs/editor-surface-tooling.md §8.2q).
//!
//! **첫 키에 서버에 묻고**(커서 전부의 자리를 한 요청에) 답이 오면 커서마다 사슬을 세워 한 걸음 옮긴다. 서버가 없거나, 답이
//! 오류거나, 500 ms 안에 안 오거나, 그 커서에 기준보다 넓은 범위를 안 주면 **1층**(tree-sitter — 트리가 있고 이어 파는 중이
//! 아닐 때만)으로 채운다. 낱말·줄·문서 단계는 늘 붙는다(`session.editor.smart_select`).
//!
//! **상태는 `Selection` 밖**(native-editor §12)이다 — 커서마다 사슬 + 인덱스, 그리고 **세운 뒤의 (`editor_lsp_version`, 선택들)**.
//! 다음 키에서 그 둘이 지금과 같을 때만 잇고, 아니면 지금 선택에서 새로 세운다. 그 한 대조가 「커서가 움직였다」와 「caret 을 안
//! 옮기는 편집」을 함께 잡는다 — `refreshAfterEdit` 가 version 을 조건 없이 올리기 때문이다.
const std = @import("std");
const maru = @import("maru");
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const Term = app_session_mod.Term;
const editor_lsp = @import("editor_lsp.zig");
const editor_ops = @import("editor.zig");
const pane_ops = @import("pane.zig");
const lsp = maru.session.editor.lsp;
const smart = maru.session.editor.smart_select;
const Range = smart.Range;
const sel_mod = maru.session.editor.selection;
const Selection = sel_mod.Selection;
const ByteRange = @import("editor_syntax.zig").syntax.Provider.ByteRange;

/// 서버 답을 기다리는 상한(§8.2q). 넘으면 1층으로 세우고 늦은 답은 버린다 — 서버가 멈춰도 키가 죽지 않는다.
pub const timeout_ms: u64 = 500;

pub const State = struct {
    /// 커서마다의 사슬 — 커서 `i` 는 `ranges[starts[i]..starts[i+1]]`, 지금 자리는 `index[i]`. 커서 순서는 문서 순서다.
    ranges: std.ArrayList(Range) = .empty,
    starts: std.ArrayList(u32) = .empty,
    index: std.ArrayList(u32) = .empty,
    /// 사슬이 유효한가 — 그리고 유효하다면 **세운 뒤의** 문서 version 과 선택들(문서 순서).
    has_state: bool = false,
    key_version: u64 = 0,
    key_sels: std.ArrayList(Selection) = .empty,
    /// 서버 답을 기다리는 중.
    waiting: bool = false,
    waiting_seq: u32 = 0,
    waiting_since_ms: u64 = 0,
    waiting_version: u64 = 0,
    waiting_sels: std.ArrayList(Selection) = .empty,
    /// 기다리는 동안 누른 키의 순 걸음(확장 +1 · 축소 −1). 답이 오면 한 번에 옮긴다.
    pending_steps: i32 = 0,
    /// 관측 카운터(§8.2q).
    sent: u64 = 0,
    applied: u64 = 0,
    dropped_stale: u64 = 0,
    dropped_error: u64 = 0,
    timeout_fallback: u64 = 0,
    layer1_only: u64 = 0,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.ranges.deinit(allocator);
        self.starts.deinit(allocator);
        self.index.deinit(allocator);
        self.key_sels.deinit(allocator);
        self.waiting_sels.deinit(allocator);
        self.* = .{};
    }

    fn chainCount(self: *const State) usize {
        return if (self.starts.items.len == 0) 0 else self.starts.items.len - 1;
    }
    fn chain(self: *const State, i: usize) []const Range {
        return self.ranges.items[self.starts.items[i]..self.starts.items[i + 1]];
    }
};

/// 활성 pane 의 편집기에서(키·팔레트 — `app_session.dispatchAppAction`).
pub fn runActive(self: *AppSession, forward: bool) bool {
    return run(self, pane_ops.activePane(self).activeTerm(), forward);
}

/// 확장(`forward`)·축소. 키를 **소비했으면** `true` — 편집기가 아니거나 비교 뷰거나 caret 이 없으면 `false`.
pub fn run(self: *AppSession, term: *Term, forward: bool) bool {
    if (term.kind != .editor) return false;
    if (term.rt.editor_diff != null) return false; // 비교 뷰는 축이 둘이다(visual-mapping §4.1g) — 이 기능 밖
    const doc = term.rt.editor_doc orelse return false;
    // 병합 판에 초점이 있으면 Result 에 선택이 없다(`editor_merge.focusedSide` 의 규칙) — 여기서 멈춘다.
    const primary = term.rt.editor_selection orelse return false;
    const st = &term.rt.editor_smart_select;
    const delta: i32 = if (forward) 1 else -1;

    if (st.waiting) {
        st.pending_steps += delta;
        return true;
    }

    var cur: std.ArrayList(Selection) = .empty;
    defer cur.deinit(self.allocator);
    const primary_pos = canonical(self.allocator, primary, term.rt.editor_extra_selections, &cur) catch return true;

    if (st.has_state and st.key_version == term.rt.editor_lsp_version and st.chainCount() == cur.items.len and sameSelections(st.key_sels.items, cur.items)) {
        step(self, term, primary_pos, delta);
        return true;
    }
    st.has_state = false;
    if (!forward) return true; // 세운 것이 없으면 축소는 제자리(§8.2q)

    // 새로 세운다 — 커서마다 물을 자리.
    const queries = self.allocator.alloc(u32, cur.items.len) catch return true;
    defer self.allocator.free(queries);
    for (cur.items, queries) |s, *q| q.* = baseOf(doc.file.content, s).query;
    if (editor_lsp.requestSelectionRange(self, term, queries)) |seq| {
        st.waiting = true;
        st.waiting_seq = seq;
        st.waiting_since_ms = self.awakeMs();
        st.waiting_version = term.rt.editor_lsp_version;
        st.waiting_sels.clearRetainingCapacity();
        st.waiting_sels.appendSlice(self.allocator, cur.items) catch {
            st.waiting = false;
            return true;
        };
        st.pending_steps = 1;
        st.sent += 1;
        return true;
    }
    buildAll(self, term, cur.items, null) catch return true;
    step(self, term, primary_pos, 1);
    return true;
}

/// 서버 답(`editor_lsp` 가 부른다).
pub fn onResponse(self: *AppSession, term: *Term, seq: u32, result: ?std.json.Value, is_error: bool, enc: lsp.rpc.PositionEncoding) void {
    const st = &term.rt.editor_smart_select;
    if (!st.waiting or seq != st.waiting_seq) return; // 시간 초과로 이미 1층을 세웠거나 다른 요청의 답
    st.waiting = false;
    const doc = term.rt.editor_doc orelse return;
    var cur: std.ArrayList(Selection) = .empty;
    defer cur.deinit(self.allocator);
    const primary = term.rt.editor_selection orelse return;
    const primary_pos = canonical(self.allocator, primary, term.rt.editor_extra_selections, &cur) catch return;
    if (st.waiting_version != term.rt.editor_lsp_version or !sameSelections(st.waiting_sels.items, cur.items)) {
        // 그사이 caret 이 움직였거나 문서가 바뀌었다 — 이 답은 지금 선택을 말하지 않는다.
        st.dropped_stale += 1;
        st.pending_steps = 0;
        return;
    }
    var dec: lsp.selection_range.Decoded = .{};
    defer dec.deinit(self.allocator);
    const ok = !is_error and (lsp.selection_range.decode(self.allocator, result, doc.file.content, doc.file.lines, enc, cur.items.len, &dec) catch false);
    if (!ok) st.dropped_error += 1;
    buildAll(self, term, cur.items, if (ok) &dec else null) catch return;
    const steps = st.pending_steps;
    st.pending_steps = 0;
    step(self, term, primary_pos, steps);
}

/// 프레임마다 — 기다림이 상한을 넘었으면 1층으로 세운다(§8.2q).
pub fn tick(self: *AppSession, term: *Term) void {
    const st = &term.rt.editor_smart_select;
    if (!st.waiting) return;
    if (self.awakeMs() -| st.waiting_since_ms < timeout_ms) return;
    st.waiting = false;
    st.timeout_fallback += 1;
    const primary = term.rt.editor_selection orelse return;
    var cur: std.ArrayList(Selection) = .empty;
    defer cur.deinit(self.allocator);
    const primary_pos = canonical(self.allocator, primary, term.rt.editor_extra_selections, &cur) catch return;
    if (st.waiting_version != term.rt.editor_lsp_version or !sameSelections(st.waiting_sels.items, cur.items)) {
        st.dropped_stale += 1;
        st.pending_steps = 0;
        return;
    }
    buildAll(self, term, cur.items, null) catch return;
    const steps = st.pending_steps;
    st.pending_steps = 0;
    step(self, term, primary_pos, steps);
}

/// 선택 하나의 **기준 범위**와 **물을 자리**(§8.2q). 빈 caret 이 낱말에 닿아 있으면 그 낱말의 시작으로 묻고(tsgo 는 낱말 끝
/// 바로 뒤에서 그 식별자를 건너뛴다 — 실측), tree-sitter 도 그 낱말을 품는 노드부터 올라간다.
const Base = struct { base: Range, query: u32, tree_lo: u32, tree_hi: u32 };
fn baseOf(content: []const u8, s: Selection) Base {
    const lo: u32 = @intCast(@min(s.start(), content.len));
    const hi: u32 = @intCast(@min(s.end(), content.len));
    if (lo != hi) return .{ .base = .{ .start = lo, .end = hi }, .query = lo, .tree_lo = lo, .tree_hi = hi };
    if (touchingWord(content, lo)) |w| return .{ .base = .{ .start = lo, .end = lo }, .query = w.start, .tree_lo = w.start, .tree_hi = w.end };
    return .{ .base = .{ .start = lo, .end = lo }, .query = lo, .tree_lo = lo, .tree_hi = lo };
}

/// caret 이 **닿은** 낱말(§8.2p `wordAtCaret` 와 같은 규칙 — 뒤 글자, 아니면 앞 글자).
fn touchingWord(content: []const u8, focus: u32) ?Range {
    const f: usize = @min(focus, content.len);
    const probe: usize = if (f < content.len and sel_mod.isWordByte(content[f]))
        f
    else if (f > 0 and sel_mod.isWordByte(content[f - 1]))
        f - 1
    else
        return null;
    const w = sel_mod.wordRangeAt(content, probe);
    if (w.hi <= w.lo) return null;
    return .{ .start = @intCast(w.lo), .end = @intCast(w.hi) };
}

/// 커서 전부의 사슬을 새로 세운다. `server` 가 있으면 커서마다 그 범위를 쓰되, **기준보다 넓은 것이 하나도 없으면 그 커서는 1층**.
fn buildAll(self: *AppSession, term: *Term, cur: []const Selection, server: ?*const lsp.selection_range.Decoded) error{OutOfMemory}!void {
    const st = &term.rt.editor_smart_select;
    const doc = term.rt.editor_doc orelse return;
    const content = doc.file.content;
    st.ranges.clearRetainingCapacity();
    st.starts.clearRetainingCapacity();
    st.index.clearRetainingCapacity();
    st.has_state = false;
    try st.starts.append(self.allocator, 0);

    var provided: std.ArrayList(Range) = .empty;
    defer provided.deinit(self.allocator);
    var tree: std.ArrayList(ByteRange) = .empty;
    defer tree.deinit(self.allocator);
    var out: std.ArrayList(Range) = .empty;
    defer out.deinit(self.allocator);

    for (cur, 0..) |s, i| {
        const b = baseOf(content, s);
        provided.clearRetainingCapacity();
        var wide = false;
        if (server) |dec| {
            for (dec.at(i)) |r| {
                const rr: Range = .{ .start = r.start, .end = r.end };
                try provided.append(self.allocator, rr);
                if (rr.strictlyContains(b.base)) wide = true;
            }
        }
        if (!wide) {
            if (server != null) st.layer1_only += 1;
            try layer1(self, term, b.tree_lo, b.tree_hi, &tree);
            for (tree.items) |r| try provided.append(self.allocator, .{ .start = r.start, .end = r.end });
        }
        try smart.buildChain(self.allocator, content, doc.file.lines, b.base, b.query, provided.items, &out);
        try st.ranges.appendSlice(self.allocator, out.items);
        try st.starts.append(self.allocator, @intCast(st.ranges.items.len));
        try st.index.append(self.allocator, 0);
    }
}

/// 1층 — tree-sitter 조상 범위. **트리가 있고 이어 파는 중이 아닐 때만**(§8.2q · layering §2.1a).
///
/// **`pending` 가드는 오늘 등가다**(적대적 1회차 D3) — #3886 뒤로 「`pending` 이면 트리가 없다」가 성립한다(여는 파싱은 트리를 버리고
/// 시작하고, 끊긴 동안 편집이 오면 끝까지 판 뒤 `pending` 을 내린다). 그래도 두는 이유는 뜻이다: 다시 파는 중인 트리는 읽지 않는다 —
/// 예산을 든 증분(끊기면 옛 트리로 그린다)이 제품에 들어오는 날 이 줄이 그 창을 막는다.
fn layer1(self: *AppSession, term: *Term, lo: u32, hi: u32, out: *std.ArrayList(ByteRange)) error{OutOfMemory}!void {
    out.clearRetainingCapacity();
    if (term.rt.editor_syntax.pending) return;
    const prov = &(term.rt.editor_syntax.provider orelse return);
    try prov.enclosingRanges(self.allocator, lo, hi, out);
}

/// 커서마다 `delta` 만큼 옮기고 선택을 세운다(anchor = 시작, focus = 끝). 합쳐져 수가 줄면 상태를 버린다 — 다음 키가 새로 세운다.
fn step(self: *AppSession, term: *Term, primary_pos: usize, delta: i32) void {
    const st = &term.rt.editor_smart_select;
    const n = st.chainCount();
    if (n == 0) return;
    const buf = self.allocator.alloc(Selection, n) catch return;
    defer self.allocator.free(buf);
    for (0..n) |i| {
        const c = st.chain(i);
        const idx: i64 = std.math.clamp(@as(i64, st.index.items[i]) + delta, 0, @as(i64, @intCast(c.len)) - 1);
        st.index.items[i] = @intCast(idx);
        const r = c[@intCast(idx)];
        buf[i] = Selection.fromPoints(r.start, r.end);
    }
    const merged = sel_mod.mergeOverlapping(buf, @min(primary_pos, n - 1));
    const items = buf[0..merged.len];
    const extras = self.allocator.alloc(Selection, items.len - 1) catch return;
    var w: usize = 0;
    for (items, 0..) |s, idx| {
        if (idx == merged.primary) continue;
        extras[w] = s;
        w += 1;
    }
    if (term.rt.editor_extra_selections.len > 0) self.allocator.free(term.rt.editor_extra_selections);
    term.rt.editor_extra_selections = extras;
    term.rt.editor_selection = items[merged.primary];

    // 세운 뒤의 키 — 합쳐져 수가 줄었으면 사슬과 커서가 짝을 잃었다: 다음 키가 합친 선택에서 새로 세운다.
    st.key_version = term.rt.editor_lsp_version;
    st.key_sels.clearRetainingCapacity();
    st.key_sels.appendSlice(self.allocator, items) catch {
        st.has_state = false;
        return;
    };
    std.mem.sort(Selection, st.key_sels.items, {}, docOrder);
    // 합쳐져 수가 줄면 상태를 버린다. **오늘 등가다**(적대적 1회차 D9) — 다음 키의 「사슬 수 = 커서 수」 대조가 한 번 더 거른다. 두 곳에
    // 두는 이유는 뜻이다: 여기는 「짝을 잃었다」를 그 자리에서 말하고, 저기는 어떤 경로로 짝이 어긋나도 막는다.
    st.has_state = merged.len == n;
    st.applied += 1;

    editor_ops.breakUndoGroup(term); // 선택이 바뀌었다 — 다음 타이핑은 새 묶음이다(§3.3)
    editor_ops.revealPrimaryCaret(self, term);
    self.metal_dirty = true;
}

/// primary + 여분을 문서 순서로 모은다. primary 의 자리를 돌려준다.
fn canonical(allocator: std.mem.Allocator, primary: Selection, extras: []const Selection, out: *std.ArrayList(Selection)) error{OutOfMemory}!usize {
    out.clearRetainingCapacity();
    try out.append(allocator, primary);
    try out.appendSlice(allocator, extras);
    std.mem.sort(Selection, out.items, {}, docOrder);
    for (out.items, 0..) |s, i| {
        if (s.start() == primary.start() and s.end() == primary.end() and s.focus == primary.focus) return i;
    }
    return 0;
}

fn docOrder(_: void, a: Selection, b: Selection) bool {
    if (a.start() != b.start()) return a.start() < b.start();
    return a.end() < b.end();
}

fn sameSelections(a: []const Selection, b: []const Selection) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.start() != y.start() or x.end() != y.end() or x.focus != y.focus) return false;
    }
    return true;
}
