//! 문서 포맷(docs/editor-surface-tooling.md §8.2e) — `textDocument/formatting` 을 보내고 응답의 `TextEdit[]` 을 §3.6 의 규칙으로
//! 적용한다: `text_edits.toChanges`(정렬·겹침 거부) → `applyEditAsOne`(되돌리기 하나·selection 은 delta 가 민다·스크롤 앵커).
//! 트리거는 `⇧⌥F`·팔레트. 서버가 없거나 `documentFormattingProvider` 가 없으면 무동작.
//!
//! 요청은 `4_000_000_000+seq`(§8.2e) — 응답은 **지금 기다리는 seq** 일 때만 적용하고 낡은 것은 버린다. 요청 때의 `editor_lsp_version`
//! 을 기억해 응답 때 다르면 버리고 알린다(§3.6 「revision 이 어긋나면 버린다」 — 서버 응답에는 version 이 없으므로 클라이언트가 잰다).
//! 겹치거나 모양이 틀린 결과는 **아무것도 적용하지 않고** 알린다(반만 적용된 문서를 만들지 않는다).

const std = @import("std");
const maru = @import("maru");
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const Term = app_session_mod.Term;
const editor_ops = @import("editor.zig");
const editor_lsp = @import("editor_lsp.zig");
const pane_ops = @import("pane.zig");
const term_ops = @import("term.zig");
const lsp = maru.session.editor.lsp;

pub const State = struct {
    waiting: bool = false,
    waiting_seq: u32 = 0,
    /// 요청한 문서(surface) 와 그때의 revision — 응답은 이 둘이 그대로일 때만 적용한다.
    waiting_surface: u64 = 0,
    asked_version: u64 = 0,
    /// 판정자 관측: 적용한 횟수 · 빈 결과로 무동작한 횟수 · revision 이 어긋나 버린 횟수 · 겹침/모양으로 거부한 횟수.
    applied: u64 = 0,
    noop: u64 = 0,
    stale: u64 = 0,
    rejected: u64 = 0,
};

/// `format_document` 명령·`⇧⌥F` — 활성 편집기의 문서 전체. 보냈으면 true. 나가 있는 요청이 있으면 **새 것이 대체한다**(앞 응답은 seq 가
/// 달라 버려진다 — 서버가 답을 안 주는 채로 다음 포맷을 막지 않는다).
pub fn formatDocument(self: *AppSession) bool {
    const term = pane_ops.activePane(self).activeTerm();
    if (term.kind != .editor or term.rt.editor_diff != null) return false;
    const doc = term.rt.editor_doc orelse return false;
    if (doc.file.read_only) return false; // 싼 조기 반환 — 실제 방어는 `EditableFile.apply` 의 `error.ReadOnly`(§3.5)
    const st = &self.editor_format;
    const seq = editor_lsp.requestFormatting(self, term) orelse return false;
    st.waiting = true;
    st.waiting_seq = seq;
    st.waiting_surface = term.surface.id;
    st.asked_version = term.rt.editor_lsp_version;
    return true;
}

/// formatting 응답(`editor_lsp` 가 부른다). `result` 는 응답의 `result`(오류 응답이면 null).
pub fn onResponse(self: *AppSession, seq: u32, result: ?std.json.Value, enc: lsp.rpc.PositionEncoding) void {
    const st = &self.editor_format;
    if (!st.waiting or seq != st.waiting_seq) return;
    st.waiting = false;
    const term = editorTerm(self, st.waiting_surface) orelse return;
    const doc = term.rt.editor_doc orelse return;
    // §3.6 revision 검증 — 요청 뒤 문서가 바뀌었으면 결과가 그 문서의 것이 아니다.
    if (term.rt.editor_lsp_version != st.asked_version) {
        st.stale += 1;
        self.showNoticeKey(.fmt_stale);
        return;
    }
    var changes = lsp.text_edits.toChanges(self.allocator, result, doc.file.content, doc.file.lines, enc) catch |err| switch (err) {
        error.Overlap, error.Malformed => {
            st.rejected += 1;
            self.showNoticeKey(.fmt_rejected);
            return;
        },
        error.OutOfMemory => return,
    };
    defer changes.deinit(self.allocator);
    if (changes.items.len == 0) {
        st.noop += 1; // 이미 정리된 문서 — 되돌리기 항목도 만들지 않는다
        return;
    }
    if (editor_ops.applyEditAsOne(self, term, changes.items)) st.applied += 1;
}

/// 요청한 문서의 Term — 탭이 바뀌었거나 닫혔어도 문서가 살아 있으면 적용한다(포맷은 화면이 아니라 문서에 하는 것이다). 없으면 null.
fn editorTerm(self: *AppSession, surface_id: u64) ?*Term {
    const loc = term_ops.findTermWhere(self, surface_id, struct {
        fn pred(want: u64, t: *Term) bool {
            return t.kind == .editor and t.surface.id == want;
        }
    }.pred) orelse return null;
    return loc.pane.terms.items[loc.term_index];
}
