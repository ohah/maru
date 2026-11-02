//! 문서 요청과 뷰 설치의 제품 연결. worker에는 AppSession/Term 포인터를 넘기지 않는다.
const std = @import("std");
const maru = @import("maru");
const host = @import("../../../app_session.zig");
const editor = @import("../mod.zig");
const panes = @import("../../pane.zig");
const dispatch = @import("dispatch.zig");
const colors = @import("../syntax.zig");
const request = dispatch.request;
const Key = dispatch.registry.SyntaxRecovery.Key;

fn ordinary(term: *host.Term) bool {
    return term.kind == .editor and term.rt.editor_diff == null and term.rt.editor_merge == null and term.rt.editor_syntax.async_view.enabled;
}
fn grammar(term: *host.Term) request.Grammar {
    return .{ .identity = @backingInt(term.rt.editor_grammar), .generation = 0 };
}
fn key(term: *host.Term) Key {
    return .{ .grammar = grammar(term), .native_language = @backingInt(colors.syntaxLanguage(term.rt.editor_grammar)) };
}
fn input(term: *host.Term) ?request.Input {
    const lease = term.rt.editor_document_lease orelse return null;
    const doc = term.rt.editorDocument().opened orelse return null;
    return .{ .document = lease.owner.identity(lease) orelse return null, .revision = doc.file.revision, .grammar = grammar(term) };
}
pub fn init() colors.State {
    return .{ .async_view = .{ .enabled = true }, .pending = true };
}

/// 편집 경로에서 한 번 호출한다. 프레임마다 새 작업을 게시하거나 실패한 엔진을 재생성하지 않는다.
pub fn refresh(session: *host.AppSession, term: *host.Term) void {
    if (!ordinary(term)) return;
    dispatch.onCompleted(completed);
    const current = input(term) orelse return;
    const state = &term.rt.editor_syntax;
    if (!state.async_view.begin(current, key(term))) return;
    state.discardCompleted();
    const lease = term.rt.editor_document_lease.?;
    if (state.async_view.blocked(key(term))) {
        state.pending = false;
        editor.syntaxDidComplete(session, term);
        return;
    }
    if (!colors.syntax.supportsLanguage(colors.syntaxLanguage(term.rt.editor_grammar))) {
        dispatch.invalidate(lease);
        state.pending = false;
        editor.syntaxDidComplete(session, term);
        return;
    }
    _ = dispatch.ensure(lease, grammar(term), colors.syntaxLanguage(term.rt.editor_grammar)) catch {
        state.pending = false;
        editor.syntaxDidComplete(session, term);
        return;
    };
    install(session, term);
    if (state.pending) editor.syntaxDidComplete(session, term);
}

/// 완료 사건과 이미 완료한 문서를 여는 경로가 함께 쓴다. 상태 조회만으로 재시도하지 않는다.
pub fn install(session: *host.AppSession, term: *host.Term) void {
    if (!ordinary(term)) return;
    const current = input(term) orelse return;
    const state = &term.rt.editor_syntax;
    switch (dispatch.observe(current.document, grammar(term), colors.syntaxLanguage(term.rt.editor_grammar))) {
        .none => {
            if (state.pending and (dispatch.runtime.Runtime.automaticDisabled(term.rt.editor_document_lease.?, grammar(term), colors.syntaxLanguage(term.rt.editor_grammar)) catch false)) {
                state.pending = false;
                editor.syntaxDidComplete(session, term);
            }
            return;
        },
        .pending => return,
        .finished => |done| {
            if (!state.async_view.permits(done.tag, key(term))) return;
            state.async_view.seen = done.tag;
            if (done.outcome != .ready) {
                state.pending = false;
                editor.syntaxDidComplete(session, term);
                return;
            }
            var prepared = (dispatch.prepareView(session.allocator, current.document, grammar(term), colors.syntaxLanguage(term.rt.editor_grammar)) catch |err| {
                // 문서 결과는 정상이다. 이 뷰만 중단하고 다른 공유 뷰의 설치는 계속한다.
                state.async_view.disabled = key(term);
                state.pending = false;
                std.log.scoped(.editor_parse).warn("syntax view installation disabled: {s}", .{@errorName(err)});
                editor.syntaxDidComplete(session, term);
                return;
            }) orelse return;
            defer prepared.deinit();
            if (!(dispatch.installView(&prepared, state, term.rt.editor_document_lease.?, grammar(term), colors.syntaxLanguage(term.rt.editor_grammar)) catch unreachable)) return;
            editor.syntaxDidComplete(session, term);
        },
    }
}
fn window(session: *host.AppSession) void {
    for (session.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| install(session, term);
}
fn completed() void {
    for (host.editorSaveWindows()) |session| window(session);
}

pub fn releaseWindow(session: *host.AppSession) void {
    for (session.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| {
        if (term.rt.editor_syntax.async_view.enabled) term.rt.editor_syntax.discardCompleted();
    };
}
fn resetDocument(session: *host.AppSession, identity: dispatch.registry.DocumentIdentity) void {
    for (session.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| {
        if (!ordinary(term)) continue;
        const current = input(term) orelse continue;
        if (!std.meta.eql(current.document, identity)) continue;
        term.rt.editor_syntax.async_view.restart();
        _ = term.rt.editor_syntax.async_view.begin(current, key(term));
        term.rt.editor_syntax.discardCompleted();
        session.metal_dirty = true;
    };
}
/// 사용자가 명시적으로 요청한 문서 재분석이다. 본문·선택·Undo와 LSP는 변경하지 않는다.
pub fn restart(session: *host.AppSession) bool {
    const term = panes.activePane(session).activeTerm();
    if (!ordinary(term) or !colors.syntax.supportsLanguage(colors.syntaxLanguage(term.rt.editor_grammar))) return false;
    const current = input(term) orelse return false;
    resetDocument(session, current.document);
    for (host.editorSaveWindows()) |peer| if (peer != session) resetDocument(peer, current.document);
    dispatch.onCompleted(completed);
    _ = dispatch.submit(term.rt.editor_document_lease.?, grammar(term), colors.syntaxLanguage(term.rt.editor_grammar)) catch {
        // 재시도도 실패하면 무색으로 중단한다. 편집으로 자동 복구하지 않는다.
        window(session);
        for (host.editorSaveWindows()) |peer| if (peer != session) window(peer);
        return true;
    };
    window(session);
    for (host.editorSaveWindows()) |peer| if (peer != session) window(peer);
    return true;
}
