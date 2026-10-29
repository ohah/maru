//! 실제 생성·입력·공유·팔레트 경로를 검사한다. 기존 동기 픽스처 대조군과 별도로 수집한다.
const std = @import("std");
const maru = @import("maru");
const host = @import("../../../app_session.zig");
const editor = @import("../mod.zig");
const client = @import("client.zig");
const dispatch = @import("dispatch.zig");
const colors = @import("../syntax.zig");
const a = std.testing.allocator;
fn now() i128 {
    return std.Io.Clock.awake.now(std.testing.io).nanoseconds;
}
fn pump(term: *host.Term) !void {
    const deadline = now() + 10_000_000_000;
    while (term.rt.editor_syntax.pending) {
        try std.testing.expect(now() < deadline);
        _ = dispatch.wake.deliverForTest();
        std.Thread.yield() catch {};
    }
}
fn oracle(term: *host.Term) !void {
    const doc = term.rt.editorDocument().opened.?;
    const held = term.rt.editor_syntax.parse_result orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(doc.file.revision, held.tag().input.revision);
    try std.testing.expect(std.meta.eql(term.rt.editor_document_lease.?.owner.identity(term.rt.editor_document_lease.?).?, held.tag().input.document));
    var cold = colors.openParsedBudgeted(doc.file.content, term.rt.editor_grammar, 0);
    defer cold.deinit(a);
    const actual = term.rt.editor_syntax.provider orelse return error.TestUnexpectedResult;
    try std.testing.expect(colors.syntax.testing.equal(cold.provider.?.tree.?, actual.tree.?) != null);
    try std.testing.expect(actual.parser != held.provider().?.parser);
    const rows = colors.lineColors(&term.rt.editor_syntax, a, doc.file.content, doc.file.lines, 0, doc.file.lines.lines.len, 4, &.{}, .inherit);
    const expected = colors.lineColors(&cold, a, doc.file.content, doc.file.lines, 0, doc.file.lines.lines.len, 4, &.{}, .inherit);
    try std.testing.expectEqualDeep(expected, rows);
}
pub fn typing(comptime Fixture: type) !void {
    var fx = try Fixture.initWithSyntax(a, true);
    defer fx.deinit(a);
    fx.term.rt.editor_selection = maru.session.editor.selection.Selection.at(0);
    try std.testing.expect(fx.term.rt.editor_syntax.async_view.enabled);
    try std.testing.expect(fx.term.rt.editor_syntax.provider == null);
    try std.testing.expect(fx.term.rt.editor_syntax.pending);
    for ([_][]const u8{ "// 한글\n", "const rapid = 3;\n", "pub fn latest() void {}\n" }) |text| {
        try std.testing.expect(editor.insertText(fx.session, fx.term, text));
        try std.testing.expect(fx.term.rt.editor_syntax.provider == null);
    }
    fx.session.metal_dirty = false;
    try pump(fx.term);
    try std.testing.expect(fx.session.metal_dirty);
    try oracle(fx.term);
    try std.testing.expect(editor.undoEdit(fx.session, fx.term));
    try pump(fx.term);
    try oracle(fx.term);
    try std.testing.expect(editor.insertText(fx.session, fx.term, "// "));
    try pump(fx.term);
    editor.setEditorPreedit(fx.session, fx.term, "한");
    const revision = fx.term.rt.editorDocument().opened.?.file.revision;
    const selection = fx.term.rt.editor_selection;
    fx.session.dispatchAppAction(.reparse_syntax);
    try pump(fx.term);
    try std.testing.expectEqualStrings("한", fx.term.rt.editor_preedit);
    try std.testing.expectEqual(revision, fx.term.rt.editorDocument().opened.?.file.revision);
    try std.testing.expectEqualDeep(selection, fx.term.rt.editor_selection);
    try std.testing.expect(editor.commitEditorPreedit(fx.session, fx.term));
    try pump(fx.term);
    try oracle(fx.term);
    try std.testing.expect(fx.term.rt.editor_preedit.len == 0);
    try std.testing.expect(std.mem.indexOf(u8, fx.term.rt.editorDocument().opened.?.file.content, "한") != null);
}
pub fn shared(comptime Fixture: type) !void {
    var fx = try Fixture.initWithSyntax(a, true);
    defer fx.deinit(a);
    fx.term.rt.editor_selection = maru.session.editor.selection.Selection.at(0);
    try pump(fx.term);
    const peer = try editor.openSharedViewInActivePane(fx.session, fx.term);
    try std.testing.expect(peer.rt.editor_syntax.async_view.enabled);
    try std.testing.expect(peer.rt.editor_syntax.provider.?.parser != fx.term.rt.editor_syntax.provider.?.parser);
    try std.testing.expect(editor.insertText(fx.session, peer, "pub fn example() void {\n    const x = 1;\n    _ = x;\n}\n"));
    try std.testing.expect(fx.term.rt.editor_syntax.provider == null);
    editor.toggleSymbolPicker(fx.session);
    try std.testing.expect(fx.session.chrome_host.symbol_picker.open);
    try std.testing.expectEqual(editor.SymbolPickerReadiness.pending, editor.symbolPickerReadiness(fx.session));
    try pump(fx.term);
    try pump(peer);
    try oracle(fx.term);
    try oracle(peer);
    try std.testing.expectEqual(editor.SymbolPickerReadiness.ready, editor.symbolPickerReadiness(fx.session));
    try std.testing.expect(fx.session.symbol_picker_rows.rows.items.len > 0);
    editor.closeSymbolPicker(fx.session);
    var frame = editor.appendPaneFrame(fx.session, fx.leaf_rect, peer) orelse return error.TestUnexpectedResult;
    defer frame.dl.deinit(a);
    try std.testing.expect(peer.rt.editor_syntax_folds_applied);
    try std.testing.expect(peer.rt.editor_fold_source == .syntax);
}
pub fn failure(comptime Fixture: type) !void {
    var copies = std.testing.FailingAllocator.init(std.heap.page_allocator, .{ .fail_index = 0 });
    var fx = try Fixture.initWithSyntax(a, true);
    defer fx.deinit(a);
    fx.term.rt.editor_selection = maru.session.editor.selection.Selection.at(0);
    try pump(fx.term);
    client.releaseWindow(fx.session);
    try dispatch.startForTest(.{ .copy_allocator = copies.allocator() });
    fx.session.dispatchAppAction(.reparse_syntax);
    try pump(fx.term);
    try std.testing.expect(fx.term.rt.editor_syntax.provider == null);
    const lease = fx.term.rt.editor_document_lease.?;
    const gate = try @constCast(lease.owner).syntaxRequestGate(lease);
    const serial = gate.next_serial;
    copies.fail_index = std.math.maxInt(usize);
    try std.testing.expect(editor.insertText(fx.session, fx.term, "// still editable 한글\n"));
    try std.testing.expectEqual(serial, gate.next_serial);
    try std.testing.expect(!fx.term.rt.editor_syntax.pending);
    const revision = fx.term.rt.editorDocument().opened.?.file.revision;
    const history = fx.term.rt.editorDocument().history.undo.len;
    fx.session.dispatchAppAction(.reparse_syntax);
    try pump(fx.term);
    try oracle(fx.term);
    try std.testing.expectEqual(revision, fx.term.rt.editorDocument().opened.?.file.revision);
    try std.testing.expectEqual(history, fx.term.rt.editorDocument().history.undo.len);
    try std.testing.expect(editor.insertText(fx.session, fx.term, "// healthy\n"));
    try pump(fx.term);
    try oracle(fx.term);
}
pub fn viewFailure(comptime Fixture: type) !void {
    var fx = try Fixture.initWithSyntax(a, true);
    defer fx.deinit(a);
    fx.term.rt.editor_selection = maru.session.editor.selection.Selection.at(0);
    try pump(fx.term);
    const peer = try editor.openSharedViewInActivePane(fx.session, fx.term);
    try std.testing.expect(editor.insertText(fx.session, peer, "// changed\n"));
    dispatch.onCompleted(null);
    const control = &peer.rt.editor_syntax.async_view;
    const identity = control.input.?.document;
    const grammar = control.input.?.grammar;
    const language = colors.syntaxLanguage(peer.rt.editor_grammar);
    const deadline = now() + 10_000_000_000;
    while (dispatch.ready(identity, grammar, language) == null) {
        try std.testing.expect(now() < deadline);
        _ = dispatch.wake.deliverForTest();
        std.Thread.yield() catch {};
    }
    const ready = dispatch.ready(identity, grammar, language).?;
    const refs = ready.job.main_refs;
    ready.job.main_refs = std.math.maxInt(usize);
    client.install(fx.session, fx.term);
    ready.job.main_refs = refs;
    try std.testing.expect(fx.term.rt.editor_syntax.async_view.disabled != null);
    try std.testing.expect(!fx.term.rt.editor_syntax.pending);
    client.install(fx.session, peer);
    try oracle(peer);
    // 중단된 뷰를 분할해도 새 뷰는 정상 문서 결과를 즉시 재사용한다.
    const fresh = try editor.openSharedViewInActivePane(fx.session, fx.term);
    try std.testing.expect(fresh.rt.editor_syntax.async_view.disabled == null);
    try pump(fresh);
    try oracle(fresh);
    try std.testing.expect(fx.term.rt.editor_syntax.async_view.disabled != null);
    try std.testing.expect(editor.insertText(fx.session, peer, "// second\n"));
    try pump(peer);
    try std.testing.expect(fx.term.rt.editor_syntax.provider == null);
    try std.testing.expect(!fx.term.rt.editor_syntax.pending);
    fx.session.dispatchAppAction(.reparse_syntax);
    try pump(fx.term);
    try pump(peer);
    try oracle(fx.term);
    try oracle(peer);
}
pub fn lifetime(comptime Fixture: type) !void {
    var fx = try Fixture.initWithSyntax(a, true);
    var live = true;
    defer if (live) fx.deinit(a);
    fx.term.rt.editor_selection = maru.session.editor.selection.Selection.at(0);
    try pump(fx.term);
    fx.term.rt.editor_grammar = .none;
    editor.resetSyntaxForGrammar(fx.session, fx.term);
    try std.testing.expect(!fx.term.rt.editor_syntax.pending);
    try std.testing.expect(fx.term.rt.editor_syntax.provider == null);
    const deadline = now() + 10_000_000_000;
    while (dispatch.lastPollThread() != null) {
        try std.testing.expect(now() < deadline);
        _ = dispatch.wake.deliverForTest();
        std.Thread.yield() catch {};
    }
    try std.testing.expect(editor.insertText(fx.session, fx.term, "// plain\n"));
    try std.testing.expect(dispatch.lastPollThread() == null);
    fx.term.rt.editor_grammar = .zig;
    editor.resetSyntaxForGrammar(fx.session, fx.term);
    try pump(fx.term);
    try oracle(fx.term);
    fx.deinit(a);
    live = false;
    try std.testing.expect(dispatch.lastPollThread() == null);
    _ = dispatch.wake.deliverForTest();
    try std.testing.expect(dispatch.lastPollThread() == null);
}

pub fn special(comptime Fixture: type) !void {
    var fx = try Fixture.initWithSyntax(a, true);
    defer fx.deinit(a);
    try pump(fx.term);
    fx.term.rt.editor_merge = .{};
    try editor.refreshViewAfterEdit(fx.session, fx.term, null);
    try std.testing.expect(!fx.term.rt.editor_syntax.async_view.enabled);
    try std.testing.expect(fx.term.rt.editor_syntax.parse_result == null);
    try std.testing.expect(fx.term.rt.editor_syntax.provider != null);
}
