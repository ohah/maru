//! 같은 낱말 강조 — 제품 배선(docs/editor-surface-tooling.md §8.2p · native-editor-visual-mapping.md §5.1a).
//!
//! **caret 이 낱말 위에 멈추면** 그 자리를 묻고, 응답 범위를 `search_marks` 와 같은 축의 마크로 깐다. 대조가 **둘**이다: 요청 때의 문서 version 과
//! 요청 때의 **낱말 범위** — caret 이 다른 낱말로 간 뒤 온 답을 들면 엉뚱한 글자를 강조한다(그 자체가 거짓말이다).
//!
//! **선택이 있으면 묻지 않는다**(§5.1a) — 그 칸은 선택 강조가 이기므로 그릴 것이 없고, 드래그 중에 서버를 두드릴 이유도 없다.
//! **편집이 나면 버린다**(심볼 2층과 같은 규율) — 범위가 낡으면 엉뚱한 자리를 칠한다.
const std = @import("std");
const maru = @import("maru");
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const Term = app_session_mod.Term;
const editor_lsp = @import("editor_lsp.zig");
const lsp = maru.session.editor.lsp;
const highlight = lsp.highlight;

/// caret 이 멈추고 이만큼 지나야 묻는다(§8.2p).
pub const quiet_ms: u64 = 150;

pub const State = struct {
    /// 든 범위(문서 절대 byte, 문서 순서). 비면 강조가 없다.
    spans: highlight.Spans = .{},
    /// 지금 강조가 말하는 문서 version 과 **낱말 범위**.
    version: u64 = 0,
    word_start: u32 = 0,
    word_end: u32 = 0,
    waiting: bool = false,
    waiting_seq: u32 = 0,
    waiting_version: u64 = 0,
    waiting_word_start: u32 = 0,
    waiting_word_end: u32 = 0,
    /// caret 이 마지막으로 움직이거나 문서가 바뀐 때(조용 시계의 기준).
    last_move_ms: u64 = 0,
    /// 관측 카운터.
    sent: u64 = 0,
    applied: u64 = 0,
    applied_empty: u64 = 0,
    dropped_stale: u64 = 0,
    dropped_word: u64 = 0,
    dropped_error: u64 = 0,
    cleared: u64 = 0,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.spans.deinit(allocator);
        self.* = .{};
    }
};

/// caret 아래 **낱말** 범위 — 선택이 있거나 낱말이 아니면 `null`. 낱말 규칙은 §5.1 이 정한 소유자(`selection.wordRangeAt`)가 준다.
pub fn wordAtCaret(term: *Term) ?struct { start: u32, end: u32 } {
    const doc = term.rt.editor_doc orelse return null;
    const sel = term.rt.editor_selection orelse return null;
    if (sel.anchor_start != sel.anchor_end) return null; // 선택이 있다 — 그 칸은 선택이 이긴다
    if (term.rt.editor_extra_selections.len > 0) return null; // 멀티커서도 같은 이유(§9.1)
    const content = doc.file.content;
    const focus = @min(sel.focus, content.len);
    // **caret 이 낱말에 «닿아» 있으면 그 낱말이다.** 타이핑·이동 뒤 caret 은 보통 낱말 **끝 바로 뒤**에 선다(`scale|`) — 그 자리에서
    // 강조가 꺼지면 「멈추면 뜬다」가 사실상 성립하지 않는다(실서버 캡처가 잡았다). 뒤를 먼저 보고, 아니면 앞 글자를 본다.
    const probe: usize = if (focus < content.len and maru.session.editor.selection.isWordByte(content[focus]))
        focus
    else if (focus > 0 and maru.session.editor.selection.isWordByte(content[focus - 1]))
        focus - 1
    else
        return null;
    const w = maru.session.editor.selection.wordRangeAt(content, probe);
    if (w.hi <= w.lo) return null;
    if (!maru.session.editor.selection.isWordByte(content[w.lo])) return null;
    return .{ .start = @intCast(w.lo), .end = @intCast(w.hi) };
}

/// 지금 그릴 강조 — 문서·낱말이 그대로일 때만. 아니면 빈 목록.
pub fn spans(term: *Term) []const highlight.Span {
    const st = &term.rt.editor_highlight;
    if (st.spans.items.items.len == 0) return &.{};
    if (st.version != term.rt.editor_lsp_version) return &.{};
    const w = wordAtCaret(term) orelse return &.{};
    if (w.start != st.word_start or w.end != st.word_end) return &.{};
    return st.spans.items.items;
}

/// 프레임마다 — 물을 때인지 판정해 보낸다.
pub fn tick(self: *AppSession, term: *Term) void {
    const st = &term.rt.editor_highlight;
    if (st.waiting) return;
    if (term.rt.editor_diff != null) return; // 비교 뷰는 축이 다르다(§5.1a)
    if (term.rt.editor_lsp_version == 0) return;
    const w = wordAtCaret(term) orelse {
        // 낱말 밖(또는 선택 중)으로 옮겼다 — 들고 있던 강조를 버린다.
        if (st.spans.items.items.len > 0) {
            st.spans.clear();
            st.cleared += 1;
            self.metal_dirty = true;
        }
        return;
    };
    const fresh = st.version == term.rt.editor_lsp_version and st.word_start == w.start and st.word_end == w.end;
    if (fresh) return; // 이 낱말의 답을 이미 들고 있다
    const now = self.awakeMs();
    if (st.last_move_ms != 0 and now -| st.last_move_ms < quiet_ms) return;
    const doc = term.rt.editor_doc orelse return;
    const line = doc.file.lines.lineAt(w.start);
    const ln = doc.file.lines.line(line) orelse return;
    const seq = editor_lsp.requestDocumentHighlight(self, term, @intCast(line), @intCast(w.start - ln.start)) orelse return;
    st.waiting = true;
    st.waiting_seq = seq;
    st.waiting_version = term.rt.editor_lsp_version;
    st.waiting_word_start = w.start;
    st.waiting_word_end = w.end;
    st.sent += 1;
}

/// 응답(`editor_lsp` 가 부른다).
pub fn onResponse(self: *AppSession, term: *Term, seq: u32, result: ?std.json.Value, is_error: bool, enc: lsp.rpc.PositionEncoding) void {
    const st = &term.rt.editor_highlight;
    if (!st.waiting or seq != st.waiting_seq) return;
    st.waiting = false;
    if (is_error or result == null) {
        st.dropped_error += 1;
        st.last_move_ms = self.awakeMs(); // 곧바로 되묻지 않는다
        return;
    }
    if (st.waiting_version != term.rt.editor_lsp_version) {
        st.dropped_stale += 1;
        return;
    }
    // **caret 이 다른 낱말로 갔으면 버린다** — 그 답은 지금 화면의 낱말을 말하지 않는다.
    const w = wordAtCaret(term) orelse {
        st.dropped_word += 1;
        return;
    };
    if (w.start != st.waiting_word_start or w.end != st.waiting_word_end) {
        st.dropped_word += 1;
        return;
    }
    const doc = term.rt.editor_doc orelse return;
    highlight.decode(self.allocator, result, doc.file.content, doc.file.lines, enc, &st.spans) catch {
        st.spans.clear();
        return;
    };
    st.version = st.waiting_version;
    st.word_start = st.waiting_word_start;
    st.word_end = st.waiting_word_end;
    if (st.spans.items.items.len == 0) st.applied_empty += 1 else st.applied += 1;
    self.metal_dirty = true;
}

/// caret 이 움직였다 — 조용 시계를 되감는다(강조는 `spans` 의 낱말 대조로 이미 안 그려진다).
pub fn onCaretMove(self: *AppSession, term: *Term) void {
    term.rt.editor_highlight.last_move_ms = self.awakeMs();
}

/// 편집 통지 — **버린다**(§8.2p). 조용해지면 caret 자리로 다시 묻는다.
pub fn onEdit(self: *AppSession, term: *Term) void {
    const st = &term.rt.editor_highlight;
    st.last_move_ms = self.awakeMs();
    if (st.spans.items.items.len > 0) {
        st.spans.clear();
        st.cleared += 1;
        self.metal_dirty = true;
    }
    st.version = 0;
}
