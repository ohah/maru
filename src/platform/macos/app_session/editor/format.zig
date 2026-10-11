//! 문서 포맷(docs/editor-surface-tooling.md §8.2e) — `textDocument/formatting` 을 보내고 응답의 `TextEdit[]` 을 §3.6 의 규칙으로
//! 적용한다: `text_edits.toChanges`(정렬·겹침 거부) → `applyEditAsOne`(되돌리기 하나·selection 은 delta 가 민다·스크롤 앵커).
//! 트리거는 `⇧⌥F`·팔레트. 서버가 없거나 `documentFormattingProvider` 가 없으면 무동작.
//!
//! 요청은 `4e8+seq`(§8.2e) — 응답은 **지금 기다리는 seq** 일 때만 적용하고 낡은 것은 버린다. 요청 때의 `notifications.lsp_version`
//! 을 기억해 응답 때 다르면 버리고 알린다(§3.6 「revision 이 어긋나면 버린다」 — 서버 응답에는 version 이 없으므로 클라이언트가 잰다).
//! 겹치거나 모양이 틀린 결과는 **아무것도 적용하지 않고** 알린다(반만 적용된 문서를 만들지 않는다).
//!
//! **저장 시 포맷**(§8.2r — 계획 docs/plans/editor-format-on-save.md): 사용자의 `⌘S` 가 같은 요청을 보내고 응답(또는 시한
//! `save_format_timeout_ms`) 뒤에 그 문서를 저장한다. 응답이 버려지면(낡은 revision·겹침·오류) 포맷 없이 저장한다 — 저장은 포맷 때문에
//! 막히지 않는다.

const std = @import("std");
const maru = @import("maru");
const app_session_mod = @import("../../app_session.zig");
const AppSession = app_session_mod.AppSession;
const Term = app_session_mod.Term;
const editor_ops = @import("mod.zig");
const editor_lsp = @import("lsp.zig");
const pane_ops = @import("../pane.zig");
const conflict_ops = @import("conflict.zig");
const term_ops = @import("../term.zig");
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
    /// **저장 시 포맷**(§8.2r) — 이 요청의 응답(또는 시한) 뒤에 그 문서를 저장한다. 시한은 `awakeMs` 기준.
    then_save: bool = false,
    save_deadline_ms: u64 = 0,
    /// 판정자 관측: 시한을 넘겨 포맷 없이 저장한 횟수.
    save_timeouts: u64 = 0,
};

/// 저장 시 포맷이 응답을 기다리는 시한(ms) — 넘기면 포맷 없이 저장한다(2026-10-11 사용자 결정 「시한 뒤 그냥 저장」). 1 초: 사람이 「저장이
/// 늦다」고 느끼기 전이고, 정상 서버의 문서 포맷은 대개 그 안에 온다(VS Code 의 옛 `editor.formatOnSaveTimeout` 기본 750ms 와 같은 크기).
pub const save_format_timeout_ms: u64 = 1000;

/// `format_document` 명령·`⇧⌥F` — 활성 편집기의 문서 전체. 보냈으면 true. 나가 있는 요청이 있으면 **새 것이 대체한다**(앞 응답은 seq 가
/// 달라 버려진다 — 서버가 답을 안 주는 채로 다음 포맷을 막지 않는다).
pub fn formatDocument(self: *AppSession) bool {
    // 저장 시 포맷이 기다리는 동안은 대체하지 않는다 — 그 자리를 빼앗으면 기다리던 저장이 사라진다(시한 안에 끝난다).
    if (self.editor_format.waiting and self.editor_format.then_save) return false;
    const term = pane_ops.activePane(self).activeTerm();
    // 비교 뷰 거절은 `readyClientFor` 가 먼저 한다(비교 뷰는 서버에 동기화되지 않는다) — 여기 것은 정의·호버·시그니처와 같은 싼 조기
    // 반환이지 둘째 방어가 아니다(적대적 3회차 C7 등가).
    if (term.kind != .editor or term.rt.editor_diff != null) return false;
    const doc = term.rt.editorDocument().opened orelse return false;
    if (doc.file.read_only) return false; // 싼 조기 반환 — 실제 방어는 `EditableFile.apply` 의 `error.ReadOnly`(§3.5)
    const st = &self.editor_format;
    const seq = editor_lsp.requestFormatting(self, term) orelse return false;
    st.waiting = true;
    st.waiting_seq = seq;
    st.waiting_surface = term.surface.id;
    st.asked_version = term.rt.editorDocument().notifications.lsp_version;
    return true;
}

/// `editor_save`(`⌘S`) — **저장 시 포맷**(§8.2r). 설정 `editor.format-on-save` 가 켜져 있고 그 문서의 서버가 포맷할 수 있으면 포맷을
/// 요청하고 응답(또는 시한) 뒤에 저장한다. 아니면(설정 끔·서버 없음·준비 전·신뢰 전·포맷 못 하는 서버·이름 없는/원격 문서 — 서버에 열리지
/// 않는다) 곧바로 저장한다. 같은 문서의 저장이 이미 기다리면 무동작(시한 안에 끝난다); 다른 문서의 것이 기다리면 그것을 포맷 없이 먼저
/// 저장한다(자리가 하나다 — 누른 저장을 잃지 않는다).
pub fn saveCommand(self: *AppSession, term: *Term) void {
    saveCommandImpl(self, term, false);
}

/// 저장 시 code action(§8.2s) 단계가 끝난 뒤 이어 부른다 — 응답·시한 뒤라 곧바로 저장할 때도 실패 알림은 늦은 응답의 규칙이다.
pub fn continueSave(self: *AppSession, term: *Term) void {
    saveCommandImpl(self, term, true);
}

fn saveCommandImpl(self: *AppSession, term: *Term, late: bool) void {
    const st = &self.editor_format;
    if (st.waiting and st.then_save) {
        if (st.waiting_surface == term.surface.id) return;
        finishPendingSave(self, late);
    }
    if (self.loaded_config.config.editor.format_on_save and term.kind == .editor and term.rt.editor_diff == null) {
        if (term.rt.editorDocument().opened) |doc| if (!doc.file.read_only) {
            if (editor_lsp.requestFormatting(self, term)) |seq| {
                st.waiting = true;
                st.waiting_seq = seq;
                st.waiting_surface = term.surface.id;
                st.asked_version = term.rt.editorDocument().notifications.lsp_version;
                st.then_save = true;
                st.save_deadline_ms = self.awakeMs() + save_format_timeout_ms;
                return;
            }
        };
    }
    saveNow(self, term, late);
}

/// 저장 시 포맷의 시한(`editor_lsp.pump` 가 tick 마다 부른다 — 언어 서버를 꺼도 부른다: 기다리던 저장이 남지 않게). 넘겼으면 포맷 없이
/// 저장하고 알린다 — 늦게 온 응답은 seq 가 달라 버려진다.
pub fn tick(self: *AppSession, now_ms: u64) void {
    const st = &self.editor_format;
    if (!st.waiting or !st.then_save or now_ms < st.save_deadline_ms) return;
    st.save_timeouts += 1;
    self.showResponseNotice(.fmt_save_timeout, &.{}); // 저장 실패면 그 알림이 이것을 덮는다(더 중요하다)
    finishPendingSave(self, true);
}

/// 기다리던 저장을 포맷 없이 지금 한다(시한 — `late`·다른 문서의 저장). 문서가 닫혔으면 할 것이 없다(닫기는 저장하지 않은 편집을 묻는다).
fn finishPendingSave(self: *AppSession, late: bool) void {
    const st = &self.editor_format;
    st.waiting = false;
    st.then_save = false;
    const term = editorTerm(self, st.waiting_surface) orelse return;
    saveNow(self, term, late);
}

/// 저장하고 결과를 말한다 — 실패는 이유별로(§3.9d), 외부 충돌은 묻는다(C1a — editor-surface.md §4). `late` 는 누른 순간이 아니라 포맷
/// 응답·시한 뒤에 저장한다는 뜻이다 — 실패 알림은 늦게 온 응답의 규칙대로 그사이 연 오버레이를 닫지 않는다(§8.2a `showResponseNotice`).
fn saveNow(self: *AppSession, term: *Term, late: bool) void {
    editor_ops.saveDocument(self, term) catch |e| switch (e) {
        // `Handled` 는 실패가 아니다 — 저쪽 파일이라 이 함수 밖에서 끝난다(U3). 결말이 말한다. `AskName` 은 「이름을 물었다」다.
        error.AskName, error.NotAnEditor, error.Handled => {},
        // ⚠️ **충돌은 알리는 자리가 아니라 «묻는» 자리다**(C1a). C0 은 이유를 올렸을 뿐 「아무것도 저장하지 않았다」로 끝냈고, 그러면
        // 사용자는 편집을 든 채 손으로 내용을 옮겨야 한다. 여기만 묻는다 — 닫기-저장은 자기 안내를 갖고 있고, 일괄 저장은 파일마다 물으면
        // 스무 개가 뜬다.
        error.ExternalConflict => conflict_ops.ask(self, term),
        // 읽기 전용 문서(열 때 쓸 수 없던 파일 — 상태바가 「읽기 전용」)는 이유를 말한다. 예전 `⌘S` 는 이것을 `else` 의 `@errorCast` 로
        // 보내 **panic** 했다(`ReadOnly` 는 쓰기 오류 집합에 없다 — 저장 시 포맷 판정자가 드러냈다).
        error.ReadOnly => if (late) self.showResponseNotice(.editor_save_read_only, &.{}) else self.showNoticeKey(.editor_save_read_only),
        else => {
            const key = editor_ops.saveFailureNoticeKey(@errorCast(e));
            if (late) self.showResponseNotice(key, &.{}) else self.showNoticeKey(key);
        },
    };
}

/// formatting 응답의 입구(`editor_lsp` 가 부른다) — **응답을 보낸 서버가 기다리는 문서를 연 그 서버일 때만** 받는다. seq 는 클라이언트(저장소 ×
/// 서버)마다 따로 세므로, 다른 저장소의 서버가 늦게 보낸 같은 번호의 응답이 기다리는 문서에 적용될 수 있었다(그 문서의 revision 은 그대로라
/// 검증을 지난다 — 남의 문서의 edit 가 들어간다). 저장 시 포맷의 「다른 문서의 ⌘S」가 이 길을 쉽게 열어 적대적 검증 4회차가 찾았다(수동 `⇧⌥F`
/// 에도 있던 구멍). 남의 응답은 버리지도 적용하지도 않는다 — 기다리는 응답은 아직 오고 있다.
pub fn onClientResponse(self: *AppSession, c: *editor_lsp.Client, seq: u32, result: ?std.json.Value, enc: lsp.rpc.PositionEncoding) void {
    const st = &self.editor_format;
    if (!st.waiting or seq != st.waiting_seq) return;
    if (editorTerm(self, st.waiting_surface)) |term| if (c.findDoc(term) == null) return;
    onResponse(self, seq, result, enc);
}

/// formatting 응답(`onClientResponse` 가 부른다). `result` 는 응답의 `result`(오류 응답이면 null). 저장 시 포맷이면 적용(또는 버림) 뒤에 저장한다.
pub fn onResponse(self: *AppSession, seq: u32, result: ?std.json.Value, enc: lsp.rpc.PositionEncoding) void {
    const st = &self.editor_format;
    if (!st.waiting or seq != st.waiting_seq) return;
    st.waiting = false;
    const then_save = st.then_save;
    st.then_save = false;
    const term = editorTerm(self, st.waiting_surface) orelse return;
    defer if (then_save) saveNow(self, term, true);
    const doc = term.rt.editorDocument().opened orelse return;
    // §3.6 revision 검증 — 요청 뒤 문서가 바뀌었으면 결과가 그 문서의 것이 아니다.
    if (term.rt.editorDocument().notifications.lsp_version != st.asked_version) {
        st.stale += 1;
        // 늦게 온 응답 — 사용자가 그사이 연 오버레이를 닫지 않는다. 저장 시 포맷이면 「저장했다」까지 말한다(「버렸다」만 보면 저장도 안 된 줄 안다 — 적대적 5회차).
        self.showResponseNotice(if (then_save) .fmt_stale_saved else .fmt_stale, &.{});
        return;
    }
    var changes = lsp.text_edits.toChanges(self.allocator, result, doc.file.content, doc.file.lines, enc) catch |err| switch (err) {
        error.Overlap, error.Malformed => {
            st.rejected += 1;
            self.showResponseNotice(if (then_save) .fmt_rejected_saved else .fmt_rejected, &.{});
            return;
        },
        error.OutOfMemory => return,
    };
    defer changes.deinit(self.allocator);
    if (changes.items.len == 0) {
        st.noop += 1; // 이미 정리된 문서 — 되돌리기 항목도 만들지 않는다
        return;
    }
    // `WithUndo` — 문서를 열고 한 번도 caret 을 놓지 않았으면(선택이 null) 맨 앞을 임시 caret 으로 쓰고 적용 뒤 다시 null 로 둔다. 그냥
    // `applyEditAsOne` 은 선택이 없으면 **조용히 실패**해 「열고 바로 ⌘S·⇧⌥F」가 포맷되지 않았다(저장 시 포맷 판정자가 드러냈다). 되돌리기
    // 칸도 본문을 바꾸기 전에 잡는다.
    if (editor_ops.applyEditAsOneWithUndo(self, term, changes.items)) st.applied += 1;
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
