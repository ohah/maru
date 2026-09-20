//! semantic tokens 2층 — 제품 배선(docs/editor-surface-tooling.md §8.2i · visual-mapping §5). 프레임마다 `tick` 이 「물을 때인가」를 판정해
//! `semanticTokens/range`(보이는 원본 줄 ± `range_pad_lines`) 또는 `full`(범위를 못 하는 서버 — clangd)을 보내고, 응답은 요청 때의
//! `editor_lsp_version` 과 같을 때만 받아 byte 스팬으로 든다. 편집 통지는 스팬을 밀어(§8.2i 「편집 중」) 새 응답까지 옛 색을 유지한다.
//! 렌더는 `editor_syntax.lineColorsWith` 가 1층 스팬 뒤에 이 스팬을 문서 순서로 섞는다 — 「마지막이 이긴다」로 겹친 자리만 2층.
//!
//! 요청은 `10e8+seq`(§8.2a id 표). 서버가 없거나 provider 가 없으면 아무것도 안 한다 — 1층만(저하, 실패 아님).
const std = @import("std");
const maru = @import("maru");
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const Term = app_session_mod.Term;
const editor_lsp = @import("editor_lsp.zig");
const lsp = maru.session.editor.lsp;
const semantic = lsp.semantic;

/// 마지막 편집 뒤 이만큼 조용해야 묻는다(§8.2i 「시점」).
pub const quiet_ms: u64 = 120;
/// 범위 요청의 위·아래 여유(원본 줄).
pub const range_pad_lines: usize = 20;

pub const State = struct {
    /// 문서 순서의 byte 스팬(우리 색 역할로 옮긴 것). 편집이 밀어 두고 응답이 갈아 끼운다.
    spans: std.ArrayList(semantic.Span) = .empty,
    /// 스팬이 말하는 문서 version(응답 때의 것). 편집이 밀면 문서 version 과 달라져 다음 `tick` 이 다시 묻는다.
    version: u64 = 0,
    /// 스팬이 덮는 원본 줄 범위(`range` 요청일 때; `full` 이면 0..maxInt).
    covered_lo: usize = 0,
    covered_hi: usize = 0,
    waiting: bool = false,
    waiting_seq: u32 = 0,
    waiting_version: u64 = 0,
    waiting_lo: usize = 0,
    waiting_hi: usize = 0,
    waiting_full: bool = false,
    /// 대기 중에 문서나 범위가 바뀌었다 — 응답 뒤 한 번 더.
    dirty: bool = false,
    last_edit_ms: u64 = 0,
    /// 관측 카운터.
    sent: u64 = 0,
    applied: u64 = 0,
    dropped_stale: u64 = 0,
    dropped_error: u64 = 0,
    shifted: u64 = 0,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.spans.deinit(allocator);
        self.* = .{};
    }
};

/// 프레임마다(색을 만드는 자리에서) — 보이는 원본 줄 `[first_src, last_src]` 를 알려 주면 물을 때인지 판정해 보낸다.
pub fn tick(self: *AppSession, term: *Term, first_src: usize, last_src: usize) void {
    const st = &term.rt.editor_semantic;
    if (st.waiting) return;
    const c = editor_lsp.readyClientFor(self, term) orelse return;
    if (!c.semantic_caps.supported) return;
    const doc = term.rt.editor_doc orelse return;
    const now = self.awakeMs();
    if (st.last_edit_ms != 0 and now -| st.last_edit_ms < quiet_ms) return; // 0 = 아직 편집이 없었다
    const line_count = doc.file.lines.lineCount();
    const lo = first_src -| range_pad_lines;
    const hi = @min(last_src + range_pad_lines, line_count -| 1);
    const version_ok = st.version == term.rt.editor_lsp_version and term.rt.editor_lsp_version != 0;
    const covered = lo >= st.covered_lo and hi <= st.covered_hi;
    if (version_ok and covered and !st.dirty) return;
    const use_full = !c.semantic_caps.range;
    const seq = editor_lsp.requestSemanticTokens(self, term, use_full, lo, hi) orelse return;
    st.waiting = true;
    st.waiting_seq = seq;
    st.waiting_version = term.rt.editor_lsp_version;
    st.waiting_lo = if (use_full) 0 else lo;
    st.waiting_hi = if (use_full) std.math.maxInt(usize) else hi;
    st.waiting_full = use_full;
    st.dirty = false;
    st.sent += 1;
}

/// 응답(`editor_lsp` 가 부른다). 낡은 seq·낡은 version·오류는 버린다(오류·낡음은 `dirty` 로 다시 묻는다).
pub fn onResponse(self: *AppSession, term: *Term, seq: u32, result: ?std.json.Value, is_error: bool, enc: lsp.rpc.PositionEncoding) void {
    const st = &term.rt.editor_semantic;
    if (!st.waiting or seq != st.waiting_seq) return;
    st.waiting = false;
    if (is_error or result == null) {
        st.dropped_error += 1;
        st.dirty = true; // `content modified` 등 — 조용해지면 다시
        st.last_edit_ms = self.awakeMs(); // 곧바로 되묻지 않는다(quiet 뒤)
        return;
    }
    if (st.waiting_version != term.rt.editor_lsp_version) {
        st.dropped_stale += 1;
        st.dirty = true;
        return;
    }
    const doc = term.rt.editor_doc orelse return;
    const c = editor_lsp.readyClientFor(self, term) orelse return;
    const decoded = semantic.decode(self.allocator, result, c.semantic_caps.roles, doc.file.content, doc.file.lines, enc) catch return;
    defer self.allocator.free(decoded);
    st.spans.clearRetainingCapacity();
    st.spans.appendSlice(self.allocator, decoded) catch return;
    st.version = st.waiting_version;
    st.covered_lo = st.waiting_lo;
    st.covered_hi = st.waiting_hi;
    st.applied += 1;
    self.metal_dirty = true;
}

/// 편집 통지(§8.2i 「편집 중」) — 스팬을 밀고 조용 시계를 되감는다. 범위를 모르면(`null`, undo/redo) 전부 버린다.
pub fn onEdit(self: *AppSession, term: *Term, start: ?u32, old_end: u32, new_end: u32) void {
    const st = &term.rt.editor_semantic;
    st.last_edit_ms = self.awakeMs();
    if (start) |s| {
        semantic.shift(&st.spans, s, old_end, new_end);
        st.shifted += 1;
    } else st.spans.clearRetainingCapacity();
    st.dirty = true;
}

/// 렌더가 섞을 스팬(문서 순서).
pub fn spans(term: *const Term) []const semantic.Span {
    return term.rt.editor_semantic.spans.items;
}
