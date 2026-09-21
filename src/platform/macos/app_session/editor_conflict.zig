//! **저장하려는데 파일이 밖에서 바뀌었다 — 고르게 한다**(C1a).
//! 계약은 [editor-surface.md](../../../docs/editor-surface.md) §4 가 소유한다.
//!
//! **왜 따로 있나.** C0 이 「충돌이었다」를 이유로 올렸고(§3.9d), 이 파일은 그 이유에 **행동 둘**을
//! 붙인다: 덮어쓰기(디스크의 변경을 버린다)와 다시 읽기(방금 친 것을 버린다 — `⌘Z` 로 돌아온다).
//! 그 둘은 `saveDocument` 의 갈래가 아니라 **사용자의 답**이라, 확인 상자를 사이에 두고 뒤에 온다.
//!
//! **들고 있는 것은 surface id 하나뿐이다**(`PendingConfirm.save_conflict`). 내용을 들고 있으면 상자가
//! 떠 있는 동안 친 글자가 조용히 사라진다 — §4 의 「고른 순간의 내용으로 쓴다」가 그 규칙이다.

const std = @import("std");
const maru = @import("maru");

const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const Term = app_session_mod.Term;
const editor_ops = @import("editor.zig");
const term_ops = @import("term.zig");

/// 저장이 충돌로 멈췄다 — 두 행동과 「계속 편집」을 띄운다.
///
/// **포커스는 `cancel` 이다.** 이 상자의 두 행동은 **둘 다 무언가를 버리므로**, 열 때 포커스를
/// `primary` 에 두는 컴포넌트 기본값을 쓰면 무심한 Enter 가 그것을 실행한다(§4 — C1b 가 안전한
/// 선택인 비교를 `primary` 로 올리면 이 예외는 사라진다).
pub fn ask(self: *AppSession, term: *Term) void {
    // 편집기 문서가 아니면 물을 것이 없다 — 이 자리에 오는 길은 `saveDocument` 의 `ExternalConflict`
    // 하나뿐이고 그것은 문서가 있을 때만 난다. 그래도 확인해 둔다: 상자가 뜨면 **키를 먹으므로**
    // 대상 없는 상자는 입력을 삼키는 빈 모달이 된다.
    if (term.kind != .editor or term.rt.editor_doc == null) return;
    self.showConfirmChoiceKeys(
        .{ .save_conflict = term.surface.id },
        .editor_save_conflict_choose,
        .{ .primary = .btn_overwrite, .alternate = .btn_reload, .cancel = .btn_keep_editing, .focus = .cancel },
    );
}

/// 「덮어쓰기」 — **CAS 를 건너뛰고** 지금 버퍼를 쓴다.
///
/// 건너뛰지 않으면 그 사이 파일이 또 바뀐 경우 같은 물음이 되풀이돼 **영영 저장하지 못한다**(§4).
/// 그 대가는 분명하다: 사용자가 본 적 없는 변경까지 지운다. 그래서 이 함수는 **사용자가 명시로 고른
/// 자리 하나**에서만 불린다 — 자동 재시도·일괄 저장은 부르지 않는다.
pub fn confirmOverwrite(self: *AppSession, surface_id: u64) void {
    // **지금 다시 찾는다.** 상자가 떠 있는 동안 그 Term 이 닫혔으면 아무 일도 하지 않는다.
    const term = term_ops.termBySurfaceId(self, surface_id) orelse return;
    editor_ops.overwriteDocument(self, term) catch |e| switch (e) {
        // 덮어쓰기는 CAS 를 건너뛰므로 충돌이 다시 올 수 없다. 나머지 이유는 §3.9d 의 그 표가 말한다 —
        // 여기서 문구를 다시 고르면 표가 둘이 된다.
        error.AskName, error.NotAnEditor, error.ReadOnly => {},
        else => self.showNoticeKey(editor_ops.saveFailureNoticeKey(@errorCast(e))),
    };
}

/// 「다시 읽기」 — 디스크를 읽어 **편집 하나로** 문서에 넣는다.
///
/// **통짜 교체가 아니다.** §4 가 「외부 변경을 받아들일 때 통짜 model 교체로 undo/cursor 를 깨지
/// 않는다」고 정했고, 평범한 편집으로 넣으면 `⌘Z` 가 사용자의 편집을 되살린다 — 버리는 선택 중
/// **되돌릴 수 있는** 쪽이 되는 것이다.
///
/// **디스크를 읽는 길은 `openPath` 하나다.** 여기서 따로 읽으면 UTF-8 거절·상한·짧은 읽기 규칙이
/// 두 벌이 된다.
pub fn confirmReload(self: *AppSession, surface_id: u64) void {
    const term = term_ops.termBySurfaceId(self, surface_id) orelse return;
    if (term.kind != .editor) return;
    const doc = term.rt.editor_doc orelse return;
    const path = term.rt.editor_path orelse return;

    var fresh = editor_ops.openPath(self.io, self.allocator, path) catch |e| {
        self.showNoticeKey(reloadFailureNoticeKey(e));
        return;
    };
    defer fresh.deinit(self.allocator);

    // **커서가 없으면 편집이 들어가지 않는다**(`applyEditAsOne` 이 선택을 요구한다). LSP 일괄 편집이
    // dirty 로 만든 문서는 사용자가 커서를 둔 적이 없을 수 있어, 그 경우 문서 앞에 세운다.
    if (term.rt.editor_selection == null) {
        term.rt.editor_selection = maru.session.editor.selection.Selection.at(0);
    }

    var changes = [_]maru.session.editor.delta.Change{.{
        .start = 0,
        .end = @intCast(doc.file.content.len),
        .text = fresh.file.content,
    }};
    if (!editor_ops.applyEditAsOne(self, term, &changes)) {
        self.showNoticeKey(.editor_reload_failed);
        return;
    }

    // **형식도 새로 읽은 것을 따른다** — 안 따르면 다음 저장이 낡은 관례(BOM·개행)로 쓴다.
    term.rt.editor_doc.?.file.format = fresh.file.format;
    // **이제 clean 이다.** 사용자가 「디스크를 받아들였다」고 답했고 내용이 그것과 같다 — 편집으로
    // 넣었다는 이유로 dirty 로 남으면 화면이 그 답과 어긋난다.
    term.rt.editor_doc.?.saved_hash = editor_ops.contentHash(fresh.file.content);
    term.rt.editor_doc.?.disk_hash = fresh.disk_hash;
    // 구문 트리·LSP 통지·줄 인덱스는 **편집 경로가 이미 한다** — `applyEditAsOne` 이 `refreshAfterEdit`
    // 를 지나므로(그 함수 주석: 「제품의 편집 경로 여섯이 전부 이 함수를 지난다」) 여기서 다시 부르면
    // 그 통지가 두 번 간다.
    self.metal_dirty = true;
}

/// **다시 읽기 실패의 이유 → 사용자에게 할 말.** §3.9d 의 저장 표와 **같은 규율**이고 **다른 표**다 —
/// 그쪽은 쓰기 실패이고 이쪽은 읽기 실패라, 사용자가 할 일이 다르다(그쪽은 다시 눌러 보는 것,
/// 이쪽은 파일이 왜 읽히지 않는지 보는 것). 뭉개지 않는다: 지워진 것과 글자가 아닌 것과 너무 커진
/// 것은 서로 다른 상황이다.
pub fn reloadFailureNoticeKey(e: editor_ops.OpenFileError) maru.i18n.Key {
    return switch (e) {
        error.Unreadable => .editor_reload_gone,
        error.NotUtf8 => .editor_reload_not_text,
        error.TooLarge => .editor_reload_too_large,
        error.OutOfMemory => .editor_reload_failed,
    };
}
