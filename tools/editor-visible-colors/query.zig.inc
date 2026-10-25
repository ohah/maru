// 별도 사본에만 붙이는 관측이다. 실제 제품 함수를 호출하고 후보 범위는 별도 저장소로 대조한다.
fn visibleColorQuery(s: *AppSession, term: *Term, bufs: *syntax_color.ColorBufs, count: usize) []const []const chrome_editor.content.ColorSpan {
    const doc = term.rt.editorDocument().opened.?;
    return syntax_color.lineColorsInto(&term.rt.editor_syntax, bufs, testing.allocator, doc.file.content, doc.file.lines,
        term.rt.editor_first_line, count, term.rt.editor_tab_width, term.rt.editor_visible_numbers,
        .inherit, semantic_client.spans(term), inlayRows(s, term), bracketMarksFor(s, term));
}

test "visible color query 화면 상한과 원문 색 및 함수 비용을 대조한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const a = testing.allocator;
    const raw = std.c.getenv("MARU_VISIBLE_COLOR_FILE") orelse return error.MissingFixture;
    const path = std.mem.span(raw);
    const name = std.fs.path.basename(path);
    const source = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, a, .limited(4 * 1024 * 1024));
    defer a.free(source);
    var fx = try PaneFixture.init(a);
    defer fx.deinit(a);
    const s = fx.session;
    s.loaded_config.config.lsp.enabled = false;
    const term = try undoFixture(&fx, a, name, source);
    fx.term = term;
    term.rt.editor_wrap = false;
    for (0..10000) |i| {
        var frame = appendPaneFrame(s, fx.leaf_rect, term) orelse return error.NoFrame;
        frame.dl.deinit(a);
        if (!term.rt.editor_syntax.pending and i > 2) break;
    }
    try testing.expect(!term.rt.editor_syntax.pending);
    try syntax_color.finishBrackets(&term.rt.editor_syntax, a, source);
    _ = syntax_color.advanceBrackets(&term.rt.editor_syntax, a, source, s.loaded_config.config.editor.bracket_pair_colorization_independent_pools);
    try testing.expect(term.rt.editor_syntax.bracket_resolved != null);
    try testing.expect(s.cell_height_px > 0);
    const doc = term.rt.editorDocument().opened.?;
    term.rt.editor_first_line = 31;
    try testing.expect(doc.file.lineCount() > 31 + 256);
    var full_bufs: syntax_color.ColorBufs = .{};
    defer full_bufs.deinit(a);
    const full = visibleColorQuery(s, term, &full_bufs, doc.file.lineCount() - term.rt.editor_first_line);
    var old_bufs: syntax_color.ColorBufs = .{};
    defer old_bufs.deinit(a);
    var bounded_bufs: syntax_color.ColorBufs = .{};
    defer bounded_bufs.deinit(a);
    for ([_]u32{ 180, 640, 10000 }) |height| {
        fx.leaf_rect.w = 960;
        fx.leaf_rect.h = height;
        const body = editorBodyRect(s, fx.leaf_rect, term);
        const cell_h: usize = @intCast(s.cell_height_px);
        // 여백·막대·sticky를 빼지 않은 상한이므로 작은 창의 과잉 조회를 보수적으로만 주장한다.
        const upper = (@as(usize, body.h) + cell_h - 1) / cell_h;
        const bounded_count = @min(upper + 1, doc.file.lineCount() - term.rt.editor_first_line);
        const current = syntaxColors(s, term);
        const queried_count = current.len - term.rt.editor_first_line;
        try testing.expectEqual(@as(usize, 256), queried_count);
        const old = visibleColorQuery(s, term, &old_bufs, queried_count);
        const bounded = visibleColorQuery(s, term, &bounded_bufs, bounded_count);
        try testing.expectEqualDeep(current, old);
        try testing.expectEqualDeep(full[0..old.len], old);
        try testing.expectEqualDeep(full[0..bounded.len], bounded);
        const shared = @min(old.len, bounded.len);
        try testing.expectEqualDeep(old[0..shared], bounded[0..shared]);
        std.debug.print("VISIBLE_COLOR file={s} height={d} body_h={d} cell_h={d} first={d} queried_rows={d} visible_upper={d} bounded_rows={d} full_oracle=1 wrap=0 folded=0 ime=0\n", .{name,height,body.h,cell_h,term.rt.editor_first_line,queried_count,upper,bounded.len - term.rt.editor_first_line});
        for (0..6) |rep| for (0..2) |order| {
            const reduced = (rep + order) % 2 == 0;
            const start = std.Io.Clock.awake.now(testing.io).nanoseconds;
            for (0..32) |_| {
                const colors = visibleColorQuery(s, term, if (reduced) &bounded_bufs else &old_bufs, if (reduced) bounded_count else queried_count);
                std.mem.doNotOptimizeAway(colors.len);
            }
            const elapsed = std.Io.Clock.awake.now(testing.io).nanoseconds - start;
            std.debug.print("VISIBLE_COLOR_COST file={s} height={d} rep={d} bounded={d} calls=32 ns={d}\n", .{name,height,rep,@intFromBool(reduced),elapsed});
        };
    }
}
