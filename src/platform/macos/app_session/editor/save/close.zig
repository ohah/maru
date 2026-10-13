//! 닫기 의도는 창이, 저장 요청은 앱 전역 큐가 소유한다. 취소는 이미 접수한 쓰기를 취소하지 않는다.
const std = @import("std");
const maru = @import("maru");
const host = @import("../../../app_session.zig");
const editor = @import("../mod.zig");
const dispatch = @import("dispatch.zig");
const Receipt = maru.session.editor.save_receipt.Receipt;
const Identity = maru.session.editor.document_registry.DocumentIdentity;
pub const State = struct {
    surface: u64,
    identity: Identity,
    epoch: u64,
    receipt: ?*Receipt = null,
    started: bool = false,
};
fn identity(term: *host.Term) ?Identity {
    const lease = term.rt.editor_document_lease orelse return null;
    return .{ .owner = @intFromPtr(lease.owner), .slot = lease.document.slot, .generation = lease.document.generation };
}
fn find(session: *host.AppSession, state: State) ?*host.Term {
    for (session.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| {
        if (term.surface.id != state.surface or term.kind != .editor) continue;
        const actual = identity(term) orelse return null;
        if (!std.meta.eql(actual, state.identity) or term.rt.editorDocument().save_target_epoch != state.epoch) return null;
        return term;
    };
    return null;
}
/// 처음에는 문서 하나의 닫기를 연결한다. 여러 문서/창 닫기와 이름 없는 문서의 Save As는 기존 계약을 유지한다.
pub fn ask(session: *host.AppSession, target: host.PendingClose, scope: host.CloseScope) bool {
    if (scope != .term or target == .agent_term) return false;
    const term = @import("../../pane.zig").activePane(session).activeTerm();
    if (term.kind != .editor or term.rt.editor_diff != null) return false;
    const doc = term.rt.editorDocument();
    if (doc.remote != null or doc.untitled != null or doc.path == null or doc.opened == null) return false;
    if (term.file_entry) |entry| if (!entry.native_editor or entry.usesEditorBridge()) return false;
    const id = identity(term) orelse return false;
    // showConfirmChoiceKeys가 이전 보류를 취소하므로 새 상태는 모달을 연 뒤 게시한다.
    session.showConfirmChoiceKeys(.editor_save_close, .fp_unsaved_confirm, .{ .primary = .btn_save, .alternate = .btn_discard_changes });
    session.editor_save_close = .{ .surface = term.surface.id, .identity = id, .epoch = doc.save_target_epoch };
    return true;
}
pub fn cancel(session: *host.AppSession) void {
    const state = session.editor_save_close orelse return;
    session.editor_save_close = null;
    if (state.receipt) |value| value.release();
}
pub fn accept(session: *host.AppSession) void {
    const state = session.editor_save_close orelse return;
    if (state.receipt != null) return;
    if (find(session, state) == null) {
        cancel(session);
        return;
    }
    const value = Receipt.create(session.allocator) catch {
        cancel(session);
        session.showNoticeKey(.fp_save_failed_tab_kept);
        return;
    };
    session.editor_save_close.?.receipt = value;
    startAfterInput(session);
}
fn startAfterInput(session: *host.AppSession) void {
    const state = session.editor_save_close orelse return;
    if (state.started or state.receipt == null or session.ime_active) return;
    const term = find(session, state) orelse {
        cancel(session);
        return;
    };
    // 확인창의 Enter도 AppKit 해석 트랜잭션 안에서 호출된다. 그 안에서 조합 확정을
    // 요청하면 정상 거절되므로 취소하지 않고 imeEnd 뒤의 tick에서 시작한다.
    if (!session.tryCommitComposition()) {
        cancel(session);
        session.showResponseNotice(.fp_save_failed_tab_kept, &.{});
        return;
    }
    if (session.editor_save_close == null or find(session, state) == null) return;
    session.editor_save_close.?.started = true;
    @import("../save_actions.zig").saveCommand(session, term);
}
/// 포맷이 끝난 최종 저장 진입점만 이 소비자를 큐에 넘긴다. 뒤의 일반 ⌘S는 별도 요청이다.
pub fn receiptFor(session: *host.AppSession, term: *host.Term) ?*Receipt {
    const state = session.editor_save_close orelse return null;
    if (!state.started or find(session, state) != term) return null;
    const value = state.receipt orelse return null;
    if (value.result != .pending or value.references != 1) return null;
    return value;
}
fn closeSurface(session: *host.AppSession, state: State) void {
    if (find(session, state) == null) return;
    for (session.tabs.items, 0..) |tab, ti| for (tab.panes.items, 0..) |pane, pi| for (pane.terms.items, 0..) |term, index| {
        if (term.surface.id == state.surface) {
            // 완료 시점에 다시 찾은 경로만 사용한다. 오래된 활성 위치/배열 인덱스를 닫지 않는다.
            session.executeClose(.{ .agent_term = .{ .tab = ti, .pane = pi, .term = index } });
            return;
        }
    };
}
pub fn discard(session: *host.AppSession) void {
    const state = session.editor_save_close orelse return;
    if (state.receipt != null) return;
    cancel(session);
    closeSurface(session, state);
}
pub fn poll(session: *host.AppSession) void {
    const state = session.editor_save_close orelse return;
    const term = find(session, state) orelse {
        cancel(session);
        return;
    };
    const value = state.receipt orelse return;
    if (!state.started) {
        startAfterInput(session);
        return;
    }
    switch (value.result) {
        .pending => return,
        .failed => {
            cancel(session);
            session.showResponseNotice(.fp_save_failed_tab_kept, &.{});
            return;
        },
        .saved => {},
    }
    // 나중에 시작한 같은 문서의 저장/포맷도 끝나야 dirty 판정이 최종 저장을 반영한다.
    if (dispatch.hasPendingDocument(state.identity) or
        (session.editor_save_actions.active and session.editor_save_actions.surface == state.surface) or
        (session.editor_format.waiting and session.editor_format.waiting_surface == state.surface)) return;
    if (editor.isDirty(term)) {
        cancel(session);
        session.showResponseNotice(.editor_close_edits_remain, &.{});
        return;
    }
    if (term.file_entry) |entry| if (entry.external_change or entry.dirty_sync_pending) {
        cancel(session);
        session.showResponseNotice(.fp_post_save_check_failed, &.{});
        return;
    };
    // 이 저장의 성공 안내는 닫기를 막지 않는다. 다른 대화 모달은 보호한다.
    if (session.modalOverlayOpenExcept(.notice)) return;
    cancel(session);
    closeSurface(session, state);
}
