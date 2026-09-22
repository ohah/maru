//! 인레이 힌트 — 제품 배선(docs/editor-surface-tooling.md §8.2n · visual-mapping §4.1h). semantic 2층(`editor_semantic`)과 같은 창: 프레임마다
//! `tick` 이 「물을 때인가」를 판정해 보이는 원본 줄 ± `range_pad_lines` 를 묻고, 응답은 요청 때의 `editor_lsp_version` 과 같을 때만 받아 문서
//! 절대 byte 의 힌트로 든다. 편집 통지는 힌트를 민다(경계 = 뒤 — `inlay.shift`). 렌더는 `lineInlays` 로 줄마다 `content.Inlay` 목록을 받는다.
//!
//! **힌트 세대**(`generation`)는 응답·밀기·비움마다 오른다 — `frame.RowCache` 가 그것을 키에 넣는다(§4.1h: 힌트가 줄 폭을 늘려 랩 행 수가 바뀐다).
const std = @import("std");
const maru = @import("maru");
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const Term = app_session_mod.Term;
const editor_lsp = @import("editor_lsp.zig");
const chrome_editor = maru.chrome.components.editor_view;
const lsp = maru.session.editor.lsp;
const inlay = lsp.inlay;

/// 마지막 편집 뒤 이만큼 조용해야 묻는다(§8.2n — semantic 과 같은 시계).
pub const quiet_ms: u64 = 120;
/// 범위 요청의 위·아래 여유(원본 줄).
pub const range_pad_lines: usize = 20;
/// 줄당 힌트 폭 합 상한의 분모(§4.1h — 화면 폭의 절반).
pub const line_budget_divisor: u32 = 2;
/// hit-test 저장소의 줄당 힌트 수 상한.
pub const max_inlay_per_line: usize = 64;

pub const State = struct {
    /// 문서 순서의 힌트(문서 절대 byte). 편집이 밀어 두고 응답이 갈아 끼운다.
    hints: inlay.Hints = .{},
    /// 렌더에 넘길 줄별 `content.Inlay` — 프레임마다 보이는 줄만 다시 만든다(줄 안 byte 로 옮긴 것). 저장소 재사용.
    row_inlays: std.ArrayList(chrome_editor.content.Inlay) = .empty,
    row_slices: std.ArrayList([]const chrome_editor.content.Inlay) = .empty,
    /// 힌트가 말하는 문서 version(응답 때의 것).
    version: u64 = 0,
    covered_lo: usize = 0,
    covered_hi: usize = 0,
    waiting: bool = false,
    waiting_seq: u32 = 0,
    waiting_version: u64 = 0,
    waiting_lo: usize = 0,
    waiting_hi: usize = 0,
    dirty: bool = false,
    last_edit_ms: u64 = 0,
    /// 힌트 세대 — 응답·밀기·비움마다 오른다(`RowCache` 키).
    generation: u64 = 0,
    /// hit-test 용 한 줄 힌트 저장소(할당 없이 — `hitTestBody` 는 세션 없이 불린다). 상한을 넘는 힌트는 hit 에서 무시된다(렌더 상한과
    /// 같은 예산이라 실제로는 줄당 열 예산에 먼저 걸린다).
    hit_line_buf: [max_inlay_per_line]chrome_editor.content.Inlay = undefined,
    /// 관측 카운터.
    sent: u64 = 0,
    applied: u64 = 0,
    dropped_stale: u64 = 0,
    dropped_error: u64 = 0,
    shifted: u64 = 0,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.hints.deinit(allocator);
        self.row_inlays.deinit(allocator);
        self.row_slices.deinit(allocator);
        self.* = .{};
    }
};

/// 프레임마다(색을 만드는 자리에서) — 보이는 원본 줄 `[first_src, last_src]` 를 알려 주면 물을 때인지 판정해 보낸다.
pub fn tick(self: *AppSession, term: *Term, first_src: usize, last_src: usize) void {
    const st = &term.rt.editor_inlay;
    if (st.waiting) return;
    const doc = term.rt.editor_doc orelse return;
    if (term.rt.editor_lsp_version == 0) return;
    const now = self.awakeMs();
    if (st.last_edit_ms != 0 and now -| st.last_edit_ms < quiet_ms) return;
    const line_count = doc.file.lines.lineCount();
    const lo = first_src -| range_pad_lines;
    const hi = @min(last_src + range_pad_lines, line_count -| 1);
    const version_ok = st.version == term.rt.editor_lsp_version;
    const covered = lo >= st.covered_lo and hi <= st.covered_hi;
    if (version_ok and covered and !st.dirty) return;
    const seq = editor_lsp.requestInlayHints(self, term, lo, hi) orelse return; // 서버·provider 검사는 요청이 한다
    st.waiting = true;
    st.waiting_seq = seq;
    st.waiting_version = term.rt.editor_lsp_version;
    st.waiting_lo = lo;
    st.waiting_hi = hi;
    st.dirty = false;
    st.sent += 1;
}

/// 응답(`editor_lsp` 가 부른다). 낡은 seq·낡은 version·오류는 버린다(오류·낡음은 `dirty` 로 다시 묻는다).
pub fn onResponse(self: *AppSession, term: *Term, seq: u32, result: ?std.json.Value, is_error: bool, enc: lsp.rpc.PositionEncoding) void {
    const st = &term.rt.editor_inlay;
    if (!st.waiting or seq != st.waiting_seq) return;
    st.waiting = false;
    if (is_error or result == null) {
        st.dropped_error += 1;
        st.dirty = true;
        st.last_edit_ms = self.awakeMs(); // 곧바로 되묻지 않는다(조용 뒤)
        return;
    }
    if (st.waiting_version != term.rt.editor_lsp_version) {
        st.dropped_stale += 1;
        st.dirty = true;
        return;
    }
    const doc = term.rt.editor_doc orelse return;
    inlay.decode(self.allocator, result, doc.file.content, doc.file.lines, enc, &st.hints) catch {
        st.dirty = true;
        return;
    };
    st.version = st.waiting_version;
    st.covered_lo = st.waiting_lo;
    st.covered_hi = st.waiting_hi;
    st.generation += 1;
    st.applied += 1;
    self.metal_dirty = true;
}

/// 서버의 `workspace/inlayHint/refresh`(§8.2n) — 지금 힌트는 그대로 두고(깜빡임 없이) **다시 묻게** 표시한다. 조용 시계는 안 건드린다
/// (편집이 아니다 — 다음 프레임에 묻는다). 대기 중이면 그 응답이 든 뒤 `dirty` 가 남아 있어 한 번 더 묻는다.
pub fn onRefresh(term: *Term) void {
    term.rt.editor_inlay.dirty = true;
}

/// 편집 통지(§4.1h 「편집과의 결합」) — 힌트를 밀고 조용 시계를 되감는다. 범위를 모르면(`null` — undo 묶음의 범위를 못 셀 때, `undoGroupSpan`) 전부 버린다. 보통의 undo/redo 는 범위를 알아 **민다**.
pub fn onEdit(self: *AppSession, term: *Term, start: ?u32, old_end: u32, new_end: u32) void {
    const st = &term.rt.editor_inlay;
    st.last_edit_ms = self.awakeMs();
    if (st.hints.items.items.len == 0) return;
    if (start) |s| {
        inlay.shift(self.allocator, &st.hints, s, old_end, new_end);
        st.shifted += 1;
    } else st.hints.clear(self.allocator);
    st.generation += 1;
}

/// 렌더가 받을 줄별 힌트(창 앞 줄 `first` 부터 `count` 줄 — 렌더 축; 접힘이면 `visible_numbers` 로 원본 줄을 푼다). 줄마다 폭 합이
/// `view_cols / line_budget_divisor` 를 넘으면 그 뒤 힌트는 뺀다(§4.1h). 실패하면 빈 목록(힌트 없이 그린다 — 저하).
pub fn lineInlays(self: *AppSession, term: *Term, first: usize, count: usize, view_cols: u32) []const []const chrome_editor.content.Inlay {
    const st = &term.rt.editor_inlay;
    st.row_inlays.clearRetainingCapacity();
    st.row_slices.clearRetainingCapacity();
    if (st.hints.items.items.len == 0) return &.{};
    const doc = term.rt.editor_doc orelse return &.{};
    const budget: usize = @max(1, view_cols / line_budget_divisor);
    const hints = st.hints.items.items;
    // 첫 번째 훑기 — 줄마다 몇 개인지 세어 저장소를 한 번에 잡는다(슬라이스가 움직이지 않게).
    var total: usize = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const src = sourceLine(term, first + i) orelse continue;
        const ln = doc.file.lines.line(src) orelse continue;
        total += countIn(hints, ln.start, ln.contentEnd());
    }
    st.row_inlays.ensureTotalCapacity(self.allocator, total) catch return &.{};
    st.row_slices.ensureTotalCapacity(self.allocator, count) catch return &.{};
    i = 0;
    while (i < count) : (i += 1) {
        const begin = st.row_inlays.items.len;
        if (sourceLine(term, first + i)) |src| if (doc.file.lines.line(src)) |ln| {
            var used: usize = 0;
            for (hints) |h| {
                if (h.offset < ln.start) continue;
                if (h.offset > ln.contentEnd()) break;
                if (used + h.text.len > budget) break;
                used += h.text.len;
                st.row_inlays.appendAssumeCapacity(.{ .at = @intCast(h.offset - ln.start), .text = h.text });
            }
        };
        st.row_slices.appendAssumeCapacity(st.row_inlays.items[begin..]);
    }
    return st.row_slices.items;
}

/// 한 줄의 힌트(줄 안 byte) — hit-test 가 쓴다(줄 예산 상한은 렌더와 같다). 할당 없음(고정 저장소).
pub fn inlaysForLine(term: *Term, src_line: usize, view_cols: u32) []const chrome_editor.content.Inlay {
    const st = &term.rt.editor_inlay;
    if (st.hints.items.items.len == 0) return &.{};
    const doc = term.rt.editor_doc orelse return &.{};
    const ln = doc.file.lines.line(src_line) orelse return &.{};
    const budget: usize = @max(1, view_cols / line_budget_divisor);
    var n: usize = 0;
    var used: usize = 0;
    for (st.hints.items.items) |h| {
        if (h.offset < ln.start) continue;
        if (h.offset > ln.contentEnd()) break;
        if (used + h.text.len > budget) break;
        if (n >= st.hit_line_buf.len) break;
        used += h.text.len;
        st.hit_line_buf[n] = .{ .at = @intCast(h.offset - ln.start), .text = h.text };
        n += 1;
    }
    return st.hit_line_buf[0..n];
}

fn countIn(hints: []const inlay.Hint, start: usize, end: usize) usize {
    var n: usize = 0;
    for (hints) |h| {
        if (h.offset < start) continue;
        if (h.offset > end) break;
        n += 1;
    }
    return n;
}

fn sourceLine(term: *Term, render_line: usize) ?usize {
    const nums = term.rt.editor_visible_numbers;
    if (nums.len == 0) return render_line;
    if (render_line >= nums.len) return null;
    const n = nums[render_line] orelse return null;
    return @as(usize, n) - 1;
}

/// 줄별 힌트 폭 합(L3 파생 — `max_cols` 에 더한다, §4.1h). 예산 상한은 렌더와 같다.
pub fn lineExtraCols(term: *Term, src_line: usize, view_cols: u32) u32 {
    const st = &term.rt.editor_inlay;
    if (st.hints.items.items.len == 0) return 0;
    const doc = term.rt.editor_doc orelse return 0;
    const ln = doc.file.lines.line(src_line) orelse return 0;
    const budget: usize = @max(1, view_cols / line_budget_divisor);
    var used: usize = 0;
    for (st.hints.items.items) |h| {
        if (h.offset < ln.start) continue;
        if (h.offset > ln.contentEnd()) break;
        if (used + h.text.len > budget) break;
        used += h.text.len;
    }
    return @intCast(used);
}
