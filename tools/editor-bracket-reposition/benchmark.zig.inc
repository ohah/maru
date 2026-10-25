// 실제 AppSession 편집·다음 pane frame을 측정한다. 전체 판정 대조는 시계 밖이다.
test "bracket coordinate benchmark product edit and frame" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const a = testing.allocator;
    const path = std.mem.span(std.c.getenv("MARU_BRACKET_FILE") orelse return error.MissingFixture);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, a, .limited(8 * 1024 * 1024));
    defer a.free(bytes);
    const shared = std.mem.eql(u8, std.mem.span(std.c.getenv("MARU_BRACKET_SHARED") orelse "0"), "1");
    const structure = std.mem.eql(u8, std.mem.span(std.c.getenv("MARU_BRACKET_STRUCTURE") orelse "0"), "1");
    const verify = std.mem.eql(u8, std.mem.span(std.c.getenv("MARU_BRACKET_VERIFY") orelse "0"), "1");
    var fx = try PaneFixture.init(a);
    defer fx.deinit(a);
    fx.session.loaded_config.config.lsp.enabled = false;
    const term = try undoFixture(&fx, a, std.fs.path.basename(path), bytes);
    term.rt.editor_selection = editor_selection.Selection.at(0);
    const peer: ?*Term = if (shared) try pane_ops.splitSharedEditorPane(fx.session, .horizontal, false) else null;
    if (peer) |p| {
        p.rt.editor_selection = editor_selection.Selection.at(0);
        fx.leaf_rect.w /= 2;
    }
    const views: usize = if (shared) 2 else 1;
    // 파일 첫 파싱도 frame 예산에 나뉜다. 초기 준비를 표본 시간에 섞지 않는다.
    const initial_pending = term.rt.editor_syntax.pending;
    var warm_rounds: usize = 0;
    var parsed = false;
    while (warm_rounds < 4096) {
        warm_rounds += 1;
        parsed = true;
        for ([_]?*Term{ term, peer }) |maybe| if (maybe) |view| {
            var frame = appendPaneFrame(fx.session, fx.leaf_rect, view) orelse return error.NoWarmFrame;
            frame.dl.deinit(a);
            parsed = parsed and !view.rt.editor_syntax.pending;
        };
        if (parsed) break;
    }
    if (!parsed) return error.WarmParseIncomplete;
    std.debug.print("BRACKET_WARM pending_before={d} rounds={d} views={d}\n", .{ @as(u8, if (initial_pending) 1 else 0), warm_rounds, views });
    for ([_]?*Term{ term, peer }) |maybe| if (maybe) |view| {
        try syntax_color.finishBrackets(&view.rt.editor_syntax, a, bytes);
        var frame = appendPaneFrame(fx.session, fx.leaf_rect, view) orelse return error.NoFrame;
        frame.dl.deinit(a);
        if (syntax_color.bracketSource(&view.rt.editor_syntax) == null) return error.MissingWarmBracketSource;
    };
    // 준비 프레임 뒤의 실제 입력 위치도 고정한다. 바뀐 원문은 시계 밖에서 전부 대조한다.
    term.rt.editor_selection = editor_selection.Selection.at(0);
    if (term.rt.editor_syntax.bracket_toks.items.len == 0) return error.EmptyBracketFixture;
    for (0..20) |key| {
        const tokens_before = term.rt.editor_syntax.bracket_toks.items.len;
        const calls = maru.session.editor.bracket_colors.resolutionCountForTest();
        const start = std.Io.Clock.awake.now(fx.session.io).nanoseconds;
        const text = if (structure) " (" else " ";
        try testing.expect(insertText(fx.session, term, text));
        const edited = std.Io.Clock.awake.now(fx.session.io).nanoseconds;
        var rounds: usize = 0;
        var ready = false;
        while (rounds < 128) {
            rounds += 1;
            ready = true;
            for ([_]?*Term{ term, peer }) |maybe| if (maybe) |view| {
                var frame = appendPaneFrame(fx.session, fx.leaf_rect, view) orelse return error.NoFrame;
                frame.dl.deinit(a);
                ready = ready and syntax_color.bracketSource(&view.rt.editor_syntax) != null;
            };
            if (ready) break;
        }
        if (!ready) return error.BracketFramesIncomplete;
        const done = std.Io.Clock.awake.now(fx.session.io).nanoseconds;
        const resolved = maru.session.editor.bracket_colors.resolutionCountForTest() - calls;
        const tokens_after = term.rt.editor_syntax.bracket_toks.items.len;
        const current_bytes = term.rt.editorDocument().opened.?.file.content;
        const added = (key + 1) * text.len;
        if (current_bytes.len != bytes.len + added) return error.UnexpectedInputByteLength;
        for (current_bytes[0..added], 0..) |ch, i| if (ch != text[i % text.len]) return error.UnexpectedInputPrefix;
        if (!std.mem.eql(u8, bytes, current_bytes[added..])) return error.UnexpectedInputSuffix;
        // 구조 변경이라는 이름만으로는 부족하다. 실제 토큰 수 증가와 전체 판정 호출을 함께 확인한다.
        if (structure) {
            if (tokens_after != tokens_before + 1) {
                std.debug.print("BRACKET_BAD key={d} before={d} after={d} resolves={d}\n", .{ key, tokens_before, tokens_after, resolved });
                return error.CanonicalStructureDidNotChange;
            }
            if (resolved != views) return error.MissingFullResolution;
        } else {
            try testing.expectEqual(tokens_before, tokens_after);
            try testing.expectEqual(@as(u64, BRACKET_EXPECT_RESOLVES) * views, resolved);
        }
        if (verify) {
            const current = term.rt.editorDocument().opened.?.file.content;
            var cold = syntax_color.openBudgeted(current, term.rt.editor_grammar, 0);
            defer cold.deinit(a);
            try syntax_color.finishBrackets(&cold, a, current);
            for ([_]?*Term{ term, peer }) |maybe| if (maybe) |view| {
                try testing.expectEqualDeep(cold.bracket_toks.items, view.rt.editor_syntax.bracket_toks.items);
                try testing.expectEqualDeep(cold.bracket_info.items, view.rt.editor_syntax.bracket_info.items);
                try testing.expectEqualDeep(cold.bracket_navigation.entries.items, view.rt.editor_syntax.bracket_navigation.entries.items);
            };
        }
        std.debug.print("BRACKET key={d} views={d} edit_ns={d} frame_ns={d} total_ns={d} resolves={d} rounds={d} tokens_before={d} tokens_after={d} oracle={d}\n", .{ key, views, edited - start, done - edited, done - start, resolved, rounds, tokens_before, tokens_after, @as(u8, if (verify) 1 else 0) });
    }
}
