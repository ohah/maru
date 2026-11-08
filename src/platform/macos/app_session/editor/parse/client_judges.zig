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

/// 아래 한국어 문자열은 표시 UI가 아니라 UTF-8·CRLF 편집을 검증하는 본문 fixture다.
/// 실제 편집 경로에서 대기 화면을 먼저 읽는다. 완료를 기다린 결과만 보면 깜빡임을 놓친다.
pub fn paintContinuity(comptime Fixture: type) !void {
    var fx = try Fixture.initWithSyntax(a, true);
    defer fx.deinit(a);
    try pump(fx.term);
    fx.term.rt.editor_selection = maru.session.editor.selection.Selection.at(0);
    try std.testing.expect(editor.insertText(fx.session, fx.term, "const value = 1;\r\n// 한글\r\n"));
    try pump(fx.term);
    const peer = try editor.openSharedViewInActivePane(fx.session, fx.term);
    for ([_]*host.Term{ fx.term, peer }) |term| {
        const doc = term.rt.editorDocument().opened.?;
        const state = &term.rt.editor_syntax;
        const rows = colors.lineColors(state, a, doc.file.content, doc.file.lines, 0, doc.file.lines.lineCount(), 4, &.{}, .inherit);
        try std.testing.expect(rows.len > 0 and rows[0].len > 0);
        _ = colors.minimapColors(state, a, doc.file.content, doc.file.lines, 0, doc.file.lines.lineCount(), 4, &.{}, .inherit);
        try std.testing.expect(state.bufs.paint.input != null);
        try std.testing.expect(state.minimap_bufs.paint.input != null);
    }
    const old_rows = colors.lineColors(&fx.term.rt.editor_syntax, a, fx.term.rt.editorDocument().opened.?.file.content, fx.term.rt.editorDocument().opened.?.file.lines, 0, fx.term.rt.editorDocument().opened.?.file.lines.lineCount(), 4, &.{}, .inherit);
    const first_row = try a.dupe(maru.chrome.components.editor_view.content.ColorSpan, old_rows[0]);
    defer a.free(first_row);
    const before = try a.dupe(maru.chrome.components.editor_view.syntax_colors.ByteSpan, fx.term.rt.editor_syntax.bufs.byte_spans.items);
    defer a.free(before);
    const capacity = fx.term.rt.editor_syntax.bufs.byte_spans.capacity;
    fx.term.rt.editor_selection = maru.session.editor.selection.Selection.at(0);
    try std.testing.expect(editor.insertText(fx.session, fx.term, "// 새 줄\r\n"));
    // worker가 끝나더라도 완료 전달 전에는 provider가 없어야 한다.
    for ([_]*host.Term{ fx.term, peer }) |term| {
        const state = &term.rt.editor_syntax;
        const doc = term.rt.editorDocument().opened.?;
        try std.testing.expect(state.pending);
        try std.testing.expect(state.provider == null and state.parse_result == null);
        try std.testing.expect(!colors.matchesInput(state, state.async_view.input.?.document, doc.file.revision));
        try std.testing.expectEqual(@as(usize, 0), state.symbols.items.len);
        try std.testing.expectEqual(@as(usize, 0), state.bracket_navigation.entries.items.len);
        const rows = colors.lineColors(state, a, doc.file.content, doc.file.lines, 0, doc.file.lines.lineCount(), 4, &.{}, .inherit);
        try std.testing.expect(rows.len > 1 and rows[1].len > 0);
        try std.testing.expectEqualDeep(first_row, rows[1]);
        const mini = colors.minimapColors(state, a, doc.file.content, doc.file.lines, 0, doc.file.lines.lineCount(), 4, &.{}, .inherit);
        try std.testing.expect(mini.len > 1 and mini[1].len > 0);
        for (before, state.bufs.byte_spans.items) |old, mapped| {
            try std.testing.expectEqual(old.role, mapped.role);
            try std.testing.expectEqual(old.end + "// 새 줄\r\n".len, mapped.end);
        }
    }
    try std.testing.expectEqual(capacity, fx.term.rt.editor_syntax.bufs.byte_spans.capacity);
    // 실패 중단에서는 임시 색을 현재 결과처럼 계속 보여 주지 않는다.
    fx.term.rt.editor_syntax.pending = false;
    const changed = fx.term.rt.editorDocument().opened.?;
    const stopped = colors.lineColors(&fx.term.rt.editor_syntax, a, changed.file.content, changed.file.lines, 0, 2, 4, &.{}, .inherit);
    try std.testing.expectEqual(@as(usize, 0), stopped.len);
    fx.term.rt.editor_syntax.pending = true;
    try std.testing.expect(editor.insertText(fx.session, fx.term, "// 연속\n"));
    try std.testing.expect(fx.term.rt.editor_syntax.bufs.paint.input != null);
    try std.testing.expect(editor.undoEdit(fx.session, fx.term));
    try std.testing.expect(fx.term.rt.editor_syntax.bufs.paint.input != null);
    try pump(fx.term);
    try pump(peer);
    try oracle(fx.term);
    try oracle(peer);
    // 문법 교체와 알 수 없는 편집은 표시 캐시도 버린다.
    fx.term.rt.editor_grammar = .none;
    editor.resetSyntaxForGrammar(fx.session, fx.term);
    try std.testing.expect(fx.term.rt.editor_syntax.bufs.paint.input == null);
    try std.testing.expectEqual(@as(usize, 0), fx.term.rt.editor_syntax.bufs.byte_spans.items.len);
}
