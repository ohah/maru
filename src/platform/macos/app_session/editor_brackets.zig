//! 짝 괄호 — 제품 배선(visual-mapping §5.1b · document-model §3.9c).
//!
//! **판정은 `session/editor/brackets.zig` 한 곳이다.** 여기는 출처를 고르고(트리가 있고 이어 파는 중이 아니면 트리, 아니면 글자 훑기) 강조의
//! 조건(설정·포커스·커서 수·빈 선택)을 걸고, 쌍을 **렌더 축 마크**(보이는 줄마다 줄 안 byte)로 옮긴다. 점프(`⇧⌘\`)도 같은 출처 고르기를 쓴다 —
//! 강조가 가리키는 쌍과 점프가 가는 곳이 갈리면 안 된다.
//!
//! **다시 세기는 키가 바뀔 때만** — (내용 · revision · 커서 자리들 · 모드 · 트리 상태). VS Code 는 50 ms 미뤄 세지만(§5.1b 「다른 점」 ①) 여기서는
//! 동기로 세고 같은 키면 건너뛴다. 마크는 접힘·스크롤과 함께 달라지므로 프레임마다 옮긴다(같은 낱말 강조와 같다).
const std = @import("std");
const maru = @import("maru");
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const Term = app_session_mod.Term;
const editor_ops = @import("editor.zig");
const editor_syntax = @import("editor_syntax.zig");
const pane_ops = @import("pane.zig");
const brackets = maru.session.editor.brackets;
const Mark = maru.chrome.components.editor_view.frame.Mark;
const Provider = editor_syntax.syntax.Provider;

/// 커서가 이보다 많으면 강조하지 않는다 — VS Code 와 같은 값(`selections.length > 100`).
pub const max_cursors: usize = 100;

pub const State = struct {
    /// 지금 든 쌍이 말하는 키. `valid` 가 거짓이면 아직 안 셌다.
    key: u64 = 0,
    valid: bool = false,
    /// 이번 키의 쌍(커서마다 하나 이하 — 같은 쌍은 한 번).
    pairs: std.ArrayList(brackets.Pair) = .empty,
    /// 렌더 축 마크(보이는 줄마다) — 프레임마다 다시 채운다.
    marks: [][]const Mark = &.{},
    mark_buf: []Mark = &.{},
    /// 관측 — 다시 센 횟수(키가 같으면 안 는다).
    computed: u64 = 0,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.pairs.deinit(allocator);
        if (self.marks.len > 0) allocator.free(self.marks);
        if (self.mark_buf.len > 0) allocator.free(self.mark_buf);
        self.* = .{};
    }
};

/// 트리 출처 — 트리가 있고 **이어 파는 중이 아닐 때만**(선택 확장 1층과 같은 규율 — 다시 파는 중인 트리는 읽지 않는다).
fn treeOf(term: *Term) ?*Provider {
    if (term.rt.editor_syntax.pending) return null;
    if (term.rt.editor_syntax.provider) |*p| {
        if (p.tree != null) return p;
    }
    return null;
}

/// **괄호 짝으로 점프**(§3.9c)의 도착 byte — 강조와 같은 출처 고르기. 닿은 괄호가 없으면 `null`.
pub fn jumpTarget(term: *Term, content: []const u8, pos: usize) ?usize {
    if (treeOf(term)) |p| return brackets.jumpTarget(brackets.Tree(Provider){ .prov = p, .bytes = content }, content.len, pos);
    return brackets.jumpTarget(brackets.Plain{ .bytes = content }, content.len, pos);
}

/// 강조의 모드 — 설정, 그리고 **포커스**(창이 key · 활성 pane 의 활성 Term — VS Code `hasWidgetFocus`). 포커스가 없으면 `never`.
pub fn modeFor(self: *AppSession, term: *Term) brackets.Mode {
    const m: brackets.Mode = switch (self.loaded_config.config.editor.match_brackets) {
        .never => .never,
        .near => .near,
        .always => .always,
    };
    if (m == .never) return .never;
    if (!self.window_focused) return .never;
    if (!self.surface_initialized or self.tabs.items.len == 0) return .never;
    if (pane_ops.activePane(self).activeTerm() != term) return .never;
    return m;
}

/// 이번 프레임의 괄호 마크(보이는 줄 축). 강조가 설 수 없으면 `null`.
pub fn marks(self: *AppSession, term: *Term) ?[]const []const Mark {
    if (term.rt.editor_diff != null) return null; // 비교 뷰 — 축이 둘이다(§5.1b)
    const mode = modeFor(self, term);
    if (mode == .never) return null;
    const doc = term.rt.editor_doc orelse return null;
    const content = doc.file.content;
    const st = &term.rt.editor_brackets;

    var iter = editor_ops.selections(term);
    const count = iter.count();
    if (count == 0 or count > max_cursors) return null;

    // ── 키 ───────────────────────────────────────────────────────────────────
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.asBytes(&@intFromPtr(content.ptr)));
    h.update(std.mem.asBytes(&content.len));
    h.update(std.mem.asBytes(&doc.file.revision));
    h.update(std.mem.asBytes(&@intFromEnum(mode)));
    const tree = treeOf(term);
    // 트리가 오면(파싱이 끝나면) 같은 자리의 답이 바뀐다 — 글자 훑기 → 트리.
    h.update(std.mem.asBytes(&@intFromPtr(if (tree) |p| p.tree else null)));
    while (iter.next()) |sel| {
        // 빈 선택만 괄호를 본다 — 선택이 있는 커서는 자리만 표시한다(그 자리가 바뀌어도 답은 같지만, 비었다가 찬 것은 가른다).
        const tag: u8 = if (sel.isEmpty()) 1 else 0;
        h.update(std.mem.asBytes(&tag));
        h.update(std.mem.asBytes(&sel.focus));
    }
    const key = h.final();

    if (!st.valid or st.key != key) {
        st.pairs.clearRetainingCapacity();
        st.valid = false;
        var it = editor_ops.selections(term);
        while (it.next()) |sel| {
            if (!sel.isEmpty()) continue;
            const pos = @min(sel.focus, content.len);
            const pair = if (tree) |p|
                brackets.forHighlight(brackets.Tree(Provider){ .prov = p, .bytes = content }, content.len, pos, mode)
            else
                brackets.forHighlight(brackets.Plain{ .bytes = content }, content.len, pos, mode);
            const got = pair orelse continue;
            // 같은 쌍은 한 번 — 커서 둘이 같은 괄호에 닿을 수 있다.
            var dup = false;
            for (st.pairs.items) |q| {
                if (q.open == got.open and q.close == got.close) dup = true;
            }
            if (!dup) st.pairs.append(self.allocator, got) catch return null;
        }
        st.key = key;
        st.valid = true;
        st.computed += 1;
    }
    if (st.pairs.items.len == 0) return null;
    return toRows(self, term, doc, st);
}

/// 쌍 → 보이는 줄마다의 마크(줄 안 byte, **오름차순·중복 없음** — 열 변환이 그것을 단언한다).
fn toRows(self: *AppSession, term: *Term, doc: editor_ops.Opened, st: *State) ?[]const []const Mark {
    const numbers = term.rt.editor_visible_numbers;
    const visible = term.rt.editor_visible_lines;
    const lines_len = if (visible.len > 0) visible.len else term.rt.editor_lines.len;
    if (lines_len == 0) return null;

    // 괄호 글자 자리를 모아 정렬·중복 제거 — 쌍이 줄 사이에서 엇갈리거나(커서 둘) 한 괄호를 두 쌍이 나눌 수 있다(`(a)|(b)` 와 `(a|)(b)`).
    var at: [2 * max_cursors]u32 = undefined;
    var n: usize = 0;
    for (st.pairs.items) |p| {
        at[n] = p.open;
        at[n + 1] = p.close;
        n += 2;
    }
    const offs = at[0..n];
    std.mem.sort(u32, offs, {}, std.sort.asc(u32));
    var u: usize = 0;
    for (offs) |o| {
        if (u > 0 and offs[u - 1] == o) continue;
        offs[u] = o;
        u += 1;
    }
    const uniq = offs[0..u];

    if (st.marks.len < lines_len) {
        const grown = self.allocator.alloc([]const Mark, lines_len) catch return null;
        if (st.marks.len > 0) self.allocator.free(st.marks);
        st.marks = grown;
    }
    if (st.mark_buf.len < uniq.len) {
        const grown = self.allocator.alloc(Mark, uniq.len) catch return null;
        if (st.mark_buf.len > 0) self.allocator.free(st.mark_buf);
        st.mark_buf = grown;
    }
    const rows = st.marks[0..lines_len];
    @memset(rows, &.{});
    // 줄과 괄호가 둘 다 문서 순서이므로 함께 걷는다(`buildCaretRows` 와 같은 병합 훑기).
    var k: usize = 0;
    var w: usize = 0;
    var any = false;
    for (0..lines_len) |i| {
        if (k >= uniq.len) break;
        const line = editor_ops.visibleDocLine(doc, numbers, visible, i) orelse continue;
        while (k < uniq.len and uniq[k] < line.start) k += 1; // 접혀 숨은 줄의 괄호
        const from = w;
        while (k < uniq.len and uniq[k] < line.contentEnd()) : (k += 1) {
            st.mark_buf[w] = .{ .start = uniq[k] - @as(u32, @intCast(line.start)), .len = 1 };
            w += 1;
        }
        if (w > from) {
            rows[i] = st.mark_buf[from..w];
            any = true;
        }
    }
    return if (any) rows else null;
}
