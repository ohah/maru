var ew2_clock_ns:i64=0;
const ew2_mode:u8=EW2_PRODUCT_MODE;
// 제품 입력·접힘 승격·프레임을 같은 순서로 실행한다. 대조 순회는 측정 구간 밖이다.
test "EW2 fold measure 제품 편집과 다음 프레임의 접힘 비용 및 결과" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const a = testing.allocator;
    const raw = std.c.getenv("MARU_EW2_FILE") orelse return error.MissingFixture;
    const path = std.mem.span(raw);
    const name = std.fs.path.basename(path);
    const source = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, a, .limited(5 * 1024 * 1024));
    defer a.free(source);
    const verify_each_edit = if (std.c.getenv("MARU_EW2_VERIFY_EACH_EDIT")) |raw_verify| !std.mem.eql(u8,std.mem.span(raw_verify),"0") else true;
    const kind = std.mem.span(std.c.getenv("MARU_EW2_WORKLOAD") orelse "typing");
    var fx = try PaneFixture.init(a);
    defer fx.deinit(a);
    fx.session.loaded_config.config.lsp.enabled = false;
    const term = try undoFixture(&fx, a, name, source);
    fx.term = term;
    const s = fx.session;
    ew2_clock_ns = 0;
    for (0..10000) |i| {
        var frame = appendPaneFrame(s, fx.leaf_rect, term) orelse return error.NoFrame;
        frame.dl.deinit(a);
        if (!term.rt.editor_syntax.pending and i > 2) break;
    }
    try testing.expect(!term.rt.editor_syntax.pending);
    const middle = term.rt.editor_lines.len / 2;
    const doc = term.rt.editorDocument().opened.?;
    term.rt.editor_first_line = middle;
    term.rt.editor_selection = editor_selection.Selection.at(doc.file.lines.line(middle + 2).?.start);
    var peer: ?*Term = null;
    if (std.mem.eql(u8, kind, "shared")) {
        try testing.expect(s.runAction("split_editor_right"));
        peer = pane_ops.activePane(s).activeTerm();
        try testing.expect(peer.? != term);
        try testing.expect(peer.?.rt.editorDocument() == term.rt.editorDocument());
        fx.leaf_rect.w /= 2;
    }
    for (0..10000) |warm| {
        var frame = appendPaneFrame(s, fx.leaf_rect, term) orelse return error.NoFrame;
        frame.dl.deinit(a);
        if (peer) |other| {
            var pf = appendPaneFrame(s, fx.leaf_rect, other) orelse return error.NoFrame;
            pf.dl.deinit(a);
        }
        if (warm >= 2 and foldMeasureReady(term) and (if (peer) |other| foldMeasureReady(other) else true)) break;
    }
    try testing.expect(foldMeasureReady(term));
    if (peer) |other| {
        try testing.expect(other.rt.editor_syntax.provider != null);
        try testing.expect(foldMeasureReady(other));
    }
    if (std.mem.eql(u8, kind, "folded")) try testing.expect(foldAll(s));
    const slow = std.mem.eql(u8, kind, "slow");
    const structural = std.mem.eql(u8, kind, "structure");
    const bulk = std.mem.eql(u8, kind, "paste");
    const undo_case = std.mem.eql(u8, kind, "undo");
    const count: usize = if (bulk) 1 else if (slow or undo_case) 6 else if (structural) 10 else 20;
    var expected: std.ArrayList(syntax_mod.Provider.FoldSpan) = .empty;
    defer expected.deinit(a);
    var samples: [20]u64 = undefined;
    var bad_frames: usize = 0;
    var mismatched: usize = 0;
    var idle_max: u64 = 0;
    var idle_total: u64 = 0;
    const peer_initial_nodes = if (peer) |other| other.rt.editor_syntax.provider.?.stats.fold_nodes else 0;
    const peer_initial_local = if (peer) |other| other.rt.editor_syntax.folds.nodes else 0;
    const peer_initial_records = if (peer) |other| other.rt.editor_syntax.folds.scanned_records else 0;
    const initial_nodes = term.rt.editor_syntax.provider.?.stats.fold_nodes;
    const initial_local = term.rt.editor_syntax.folds.nodes;
    const initial_records = term.rt.editor_syntax.folds.scanned_records;
    for (0..count) |i| {
        const next_key = ew2_clock_ns + @as(i64, if (slow) 250_000_000 else 50_000_000);
        while (ew2_clock_ns + 16_666_667 < next_key) {
            if (foldMeasureReady(term) and (if (peer) |other| foldMeasureReady(other) else true)) break;
            ew2_clock_ns += 16_666_667;
            // 대기 중이라는 이유만으로 프레임을 강제하지 않는다. 파싱 재개나 만기 wake만 모델링한다.
            if (!foldMeasureDue(term) and !(if (peer) |other| foldMeasureDue(other) else false)) continue;
            const idle_start = std.Io.Clock.awake.now(s.io).nanoseconds;
            var idle_frame = appendPaneFrame(s, fx.leaf_rect, term) orelse return error.NoFrame;
            idle_frame.dl.deinit(a);
            if (peer) |other| {
                var pf = appendPaneFrame(s, fx.leaf_rect, other) orelse return error.NoFrame;
                pf.dl.deinit(a);
            }
            const idle_ns: u64 = @intCast(std.Io.Clock.awake.now(s.io).nanoseconds - idle_start);
            idle_max = @max(idle_max, idle_ns);
            idle_total += idle_ns;
        }
        ew2_clock_ns = next_key;
        const start = std.Io.Clock.awake.now(s.io).nanoseconds;
        if (undo_case and i % 2 == 1) {
            if (!undoEdit(s, term)) return error.UndoFailed;
        } else {
            const text = if (bulk) array_repeat.repeat("\nconst Pasted = struct {\n fn p() void {\n _ = 1;\n }\n};\n", 100) else if (structural) (if (i % 2 == 0) "/*\n" else "*/\n") else " ";
            if (!insertText(s, term, text)) return error.InsertFailed;
        }
        if (std.mem.eql(u8, kind, "command")) {
            promoteFoldRangesToSyntax(s,term);
            _ = foldAll(s);
        }
        var frame = appendPaneFrame(s, fx.leaf_rect, term) orelse return error.NoFrame;
        frame.dl.deinit(a);
        if (peer) |other| {
            var pf = appendPaneFrame(s, fx.leaf_rect, other) orelse return error.NoFrame;
            pf.dl.deinit(a);
        }
        samples[i] = @intCast(std.Io.Clock.awake.now(s.io).nanoseconds - start);
        if (!foldMeasureReady(term) or (if (peer) |other| !foldMeasureReady(other) else false)) bad_frames += 1;
        // 단일 뷰의 기존 계약대로 편집 뒤 닫힌 집합을 풀고, 명시 접기 명령은 세 방식 모두 최신 범위를 쓴다.
        if (std.mem.eql(u8,kind,"folded")) try testing.expectEqual(@as(usize,0),term.rt.editor_folded_len);
        if (std.mem.eql(u8,kind,"command") and !term.rt.editor_syntax.pending) {
            try testing.expect(term.rt.editor_syntax_folds_applied);
            try testing.expectEqual(term.rt.editor_fold_ranges.len,term.rt.editor_folded_len);
        }
        // 두 뷰 모두 대조한다. 지연 모드의 불일치는 뷰별로 기록하고 만기 뒤에는 같아야 한다.
        if (verify_each_edit) for ([_]?*Term{term, peer}) |maybe| if (maybe) |view| {
            if (!view.rt.editor_syntax.pending) {
                const same = try foldMeasureMatches(view, a, &expected);
                if (!same) mismatched += 1;
                if (ew2_mode != 2) try testing.expect(same);
            }
        };

    }
    const last_key = ew2_clock_ns;
    var tail_max: u64 = 0;
    for (0..120) |_| {
        if (foldMeasureReady(term) and (if (peer) |other| foldMeasureReady(other) else true)) break;
        ew2_clock_ns += 16_666_667;
        const start = std.Io.Clock.awake.now(s.io).nanoseconds;
        var frame = appendPaneFrame(s, fx.leaf_rect, term) orelse return error.NoFrame;
        frame.dl.deinit(a);
        if (peer) |other| {
            var pf = appendPaneFrame(s, fx.leaf_rect, other) orelse return error.NoFrame;
            pf.dl.deinit(a);
        }
        tail_max = @max(tail_max, @as(u64, @intCast(std.Io.Clock.awake.now(s.io).nanoseconds - start)));
        if (foldMeasureReady(term) and (if (peer) |other| foldMeasureReady(other) else true)) break;
    }
    for ([_]?*Term{term, peer}) |maybe| if (maybe) |view| {
        try testing.expect(foldMeasureReady(view));
        try testing.expect(try foldMeasureMatches(view, a, &expected));
    };
    const p = &term.rt.editor_syntax.provider.?;
    const peer_full = if (peer) |other| other.rt.editor_syntax.provider.?.stats.fold_nodes - peer_initial_nodes else 0;
    const peer_local = if (peer) |other| other.rt.editor_syntax.folds.nodes - peer_initial_local else 0;
    const peer_records = if (peer) |other| other.rt.editor_syntax.folds.scanned_records - peer_initial_records else 0;
    const peer_bytes = if (peer) |other| other.rt.editor_syntax.folds.records.capacity * @sizeOf(@TypeOf(term.rt.editor_syntax.folds.records.items[0])) else 0;
    // 대조 순회의 카운터는 복원하여 제품 작업량에 섞지 않는다.
    std.debug.print("\nEW2 mode={d} file={s} work={s} folded_end={d} verified_each_edit={d} edits={d} deferred={d} mismatch={d} settle_ns={d} tail_ns={d} idle_max_ns={d} idle_total_ns={d} full_nodes={d} local_nodes={d} scanned_records={d} cache_bytes={d} samples_ns=", .{ew2_mode, name, kind, term.rt.editor_folded_len, @intFromBool(verify_each_edit), count, bad_frames, mismatched, ew2_clock_ns-last_key, tail_max, idle_max, idle_total, p.stats.fold_nodes-initial_nodes+peer_full, term.rt.editor_syntax.folds.nodes-initial_local+peer_local, term.rt.editor_syntax.folds.scanned_records-initial_records+peer_records, term.rt.editor_syntax.folds.records.capacity * @sizeOf(@TypeOf(term.rt.editor_syntax.folds.records.items[0])) + peer_bytes});
    for (samples[0..count]) |sample| std.debug.print("{d},", .{sample});
    std.debug.print("\n", .{});
}

fn foldMeasureReady(term: *Term) bool {
    return term.rt.editor_syntax_folds_applied and !term.rt.editor_syntax.pending;
}
fn foldMeasureDue(term: *Term) bool {
    if (term.rt.editor_syntax.pending) return true;
    return !term.rt.editor_syntax_folds_applied;
}
fn foldMeasureMatches(term: *Term, a: std.mem.Allocator, expected: *std.ArrayList(syntax_mod.Provider.FoldSpan)) !bool {
    const p = &term.rt.editor_syntax.provider.?;
    const saved = p.stats;
    defer p.stats = saved;
    try p.foldSpans(a, expected);
    const actual = term.rt.editor_fold_ranges;
    // 구문 후보가 없을 때 들여쓰기 층을 유지하는 기존 제품 계약까지 비교한다.
    if (expected.items.len == 0) {
        const lines = foldSourceLines(term);
        const ranges = try a.alloc(editor_fold.Range, editor_fold.countRanges(lines, term.rt.editor_tab_width));
        defer a.free(ranges);
        const computed = editor_fold.compute(lines, term.rt.editor_tab_width, ranges);
        if (actual.len != computed.len) return false;
        for (actual, computed) |got, want| if (got.head != want.head or got.last_hidden != want.last_hidden) { return false; };
        return true;
    }
    if (actual.len != expected.items.len) return false;
    for (actual, expected.items) |got, want| {
        if (got.head != want.start_row or got.last_hidden != want.end_row) return false;
    }
    return true;
}
