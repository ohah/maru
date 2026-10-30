//! 전체 프레임 게시를 거친 작업 지속과 완료 뒤 idle 복귀를 검사한다.
//! 프레임 생성 함수만 직접 부르면 dirty 소거 결함을 검출할 수 없다.
const std = @import("std");
const maru = @import("maru");
const editor = @import("../mod.zig");
const colors = @import("../syntax.zig");
const wake = @import("dispatch.zig").wake;
const a = std.testing.allocator;

pub const Case = enum { legacy, asynchronous, shared, highlight_only, color_only, independent, preedit, edit, undo, disabled, disable_during, empty, unsupported };

fn wait(term: anytype) !void {
    const deadline = std.Io.Clock.awake.now(std.testing.io).nanoseconds + 10 * std.time.ns_per_s;
    while (term.rt.editor_syntax.pending) {
        try std.testing.expect(std.Io.Clock.awake.now(std.testing.io).nanoseconds < deadline);
        _ = wake.deliverForTest();
        std.Thread.yield() catch {};
    }
}

pub fn exercise(comptime Fixture: type, comptime open: anytype, which: Case) !void {
    const asynchronous = switch (which) {
        .asynchronous, .shared, .preedit, .edit, .undo => true,
        else => false,
    };
    var fx = try Fixture.initWithSyntax(a, asynchronous);
    defer fx.deinit(a);
    fx.session.loaded_config.config.lsp.enabled = false;
    fx.session.appearance.cursor.blink_interval_ms = 600_000;
    fx.session.blink_phase_ns = 0;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    if (which != .empty) for (0..300) |_| try text.appendSlice(a, "const x = f([1], .{2});\n");
    const term = if (asynchronous) fx.term else try open(&fx, a, if (which == .unsupported) "plain.txt" else "walk.zig", text.items);
    if (asynchronous) {
        fx.session.surface_initialized = true;
        fx.session.backing_width_px = 1200;
        fx.session.backing_height_px = 800;
        term.rt.editor_selection = maru.session.editor.selection.Selection.at(0);
        try std.testing.expect(editor.insertText(fx.session, term, text.items));
        try wait(term);
    }
    var peer: ?@TypeOf(term) = null;
    if (which == .shared) {
        try std.testing.expect(fx.session.runAction("split_editor_right"));
        // split 작업이 활성 pane을 바꿔도 문서의 두 독립 상태를 모두 판정한다.
        for (fx.session.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |candidate| {
            if (candidate.kind == .editor and candidate != term and candidate.rt.editorDocument() == term.rt.editorDocument()) peer = candidate;
        };
        try std.testing.expect(peer != null);
        try wait(peer.?);
    }
    const cfg = &fx.session.loaded_config.config.editor;
    if (which == .highlight_only or which == .disabled) cfg.bracket_pair_colorization = false;
    if (which == .color_only or which == .disabled) cfg.match_brackets = .never;
    if (which == .independent) cfg.bracket_pair_colorization_independent_pools = true;
    colors.dropBrackets(&term.rt.editor_syntax, a);
    term.rt.editor_syntax.bracket_walk_budget_ns = 1;
    if (peer) |p| {
        colors.dropBrackets(&p.rt.editor_syntax, a);
        p.rt.editor_syntax.bracket_walk_budget_ns = 1;
    }
    if (which == .preedit) editor.setEditorPreedit(fx.session, term, "한");
    fx.session.metal_dirty = true;
    var rounds: usize = 0;
    var changed = false;
    while (true) : (rounds += 1) {
        if (rounds > 2000) return error.ContinuationDidNotFinish;
        _ = try fx.session.tick();
        if (which == .disabled or which == .unsupported or which == .empty) {
            try std.testing.expect(!term.rt.editor_syntax.brackets.ready);
            break;
        }
        if (which == .disable_during and rounds == 0) {
            try std.testing.expect(!term.rt.editor_syntax.brackets.ready);
            cfg.bracket_pair_colorization = false;
            cfg.match_brackets = .never;
        }
        if (which == .disable_during and rounds > 0) {
            try std.testing.expect(!term.rt.editor_syntax.brackets.ready);
            break;
        }
        if (!changed and (which == .edit or which == .undo) and term.rt.editor_syntax.brackets.walking) {
            try std.testing.expect(editor.insertText(fx.session, term, "// 변경\n"));
            if (which == .undo) try std.testing.expect(editor.undoEdit(fx.session, term));
            try wait(term);
            changed = true;
        }
        if (term.rt.editor_syntax.brackets.ready and (peer == null or peer.?.rt.editor_syntax.brackets.ready)) break;
        // 외부 입력/수동 dirty 설정으로 작업을 밀어 주지 않는다.
        try std.testing.expect(fx.session.metal_dirty);
    }
    if (which == .edit or which == .undo) try std.testing.expect(changed);
    if (which == .preedit) try std.testing.expectEqualStrings("한", term.rt.editor_preedit);
    if (which != .disabled and which != .unsupported and which != .disable_during and which != .empty) {
        const bytes = term.rt.editorDocument().opened.?.file.content;
        var cold = colors.openParsedBudgeted(bytes, term.rt.editor_grammar, 0);
        defer cold.deinit(a);
        try colors.finishBrackets(&cold, a, bytes);
        // 토큰 위치뿐 아니라 독립 색 풀의 깊이·짝 판정도 같은 옵션으로 대조한다.
        while (colors.advanceBrackets(&cold, a, bytes, cfg.bracket_pair_colorization_independent_pools)) {}
        const got = colors.bracketMarks(&term.rt.editor_syntax);
        const expected = colors.bracketMarks(&cold);
        try std.testing.expectEqualDeep(expected.toks, got.toks);
        try std.testing.expectEqualDeep(expected.info, got.info);
    }
    // 마지막 조각 뒤 예약이 남아 무한 재투영하지 않는지 확인한다.
    for (0..3) |_| _ = try fx.session.tick();
    try std.testing.expect(!fx.session.metal_dirty);
    try std.testing.expect(!fx.session.reproject_after_frame);
}
