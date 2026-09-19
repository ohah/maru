//! 정의로 이동(docs/editor-surface-tooling.md §8.2c) — `textDocument/definition` 을 보내고 응답의 **첫 항목**을 §5.2 의 `navigateTo`
//! 하나로 넘긴다(연 뒤 그 문서로 offset 을 푼다 — `NavTarget.pos`). 트리거는 `F12`(caret)·`⌘클릭`(포인터 아래 글자)·팔레트.
//!
//! 요청은 `2e8+seq`(§8.2c) — 응답은 **지금 기다리는 seq** 일 때만 움직이고 낡은 것은 버린다(hover 와 같은 규율). 서버가 없거나
//! ready 아니면 무동작. 결과가 `null`/빈 배열이면 알림 「정의를 찾지 못했습니다」, root 밖이면 알림 「루트 밖이라 열지 않습니다」(§5.2
//! 「표시와 접근을 가른다」 — 서버가 준 경로라는 것은 열어도 된다는 근거가 아니다).

const std = @import("std");
const maru = @import("maru");
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const Term = app_session_mod.Term;
const editor_ops = @import("editor.zig");
const editor_lsp = @import("editor_lsp.zig");
const pane_ops = @import("pane.zig");
const lsp = maru.session.editor.lsp;

pub const State = struct {
    waiting: bool = false,
    waiting_seq: u32 = 0,
    /// 판정자 관측: 이동한 횟수 · 알림을 낸 횟수(없음·root 밖).
    navigated: u64 = 0,
    notified_none: u64 = 0,
    notified_outside: u64 = 0,
};

/// `goto_definition` 명령·`F12` — 활성 편집기의 caret 자리에서. 보냈으면 true.
pub fn gotoDefinitionAtCaret(self: *AppSession) bool {
    const term = pane_ops.activePane(self).activeTerm();
    if (term.kind != .editor or term.rt.editor_diff != null) return false;
    const doc = term.rt.editor_doc orelse return false;
    const sel = term.rt.editor_selection orelse return false;
    return gotoDefinitionAt(self, term, @min(sel.focus, doc.file.content.len));
}

/// `⌘클릭` — 포인터 아래 **글자**(`.cluster` 판정, hover 와 같다)에서. 글자가 없는 자리면 false(클릭은 흘러간다).
pub fn gotoDefinitionAtPointer(self: *AppSession, term: *Term, x_px: f64, y_px: f64) bool {
    const off = editor_ops.hitTestBodyMode(.cluster, term, x_px, y_px) orelse return false;
    const doc = term.rt.editor_doc orelse return false;
    if (off >= doc.file.content.len) return false;
    return gotoDefinitionAt(self, term, off);
}

fn gotoDefinitionAt(self: *AppSession, term: *Term, offset: usize) bool {
    const st = &self.editor_definition;
    const seq = editor_lsp.requestDefinition(self, term, offset) orelse return false;
    st.waiting = true;
    st.waiting_seq = seq;
    return true;
}

/// definition 응답(`editor_lsp` 가 부른다). 지금 기다리는 seq 가 아니면 버린다.
pub fn onDefinitionResponse(self: *AppSession, seq: u32, target: ?lsp.rpc.Target, enc: lsp.rpc.PositionEncoding) void {
    const st = &self.editor_definition;
    if (!st.waiting or seq != st.waiting_seq) return;
    st.waiting = false;
    const t = target orelse {
        st.notified_none += 1;
        self.showNoticeKey(.nav_no_definition);
        return;
    };
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = lsp.rpc.pathFromFileUri(t.uri, &path_buf) orelse {
        // `file:` 이 아닌 URI(가상 문서 등)는 열 수 없다 — 없는 것과 같이 알린다.
        st.notified_none += 1;
        self.showNoticeKey(.nav_no_definition);
        return;
    };
    if (editor_ops.navigateTo(self, .{ .path = path, .pos = .{ .line = t.line, .character = t.character, .enc = enc } })) |_| {
        st.navigated += 1;
    } else |err| switch (err) {
        error.OutsideRoot => {
            st.notified_outside += 1;
            self.showNoticeFmt(.nav_outside_root, &.{.{ .s = path }});
        },
        error.Unopenable, error.NoDocument => {
            st.notified_none += 1;
            self.showNoticeKey(.nav_no_definition);
        },
    }
}
