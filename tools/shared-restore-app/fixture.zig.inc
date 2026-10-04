// 격리된 소스 사본에만 붙이는 관측기다. 배포 ABI나 사용자 명령을 추가하지 않는다.
var shared_restore_session: ?*AppSession = null;
var shared_restore_seeded = false;
var shared_restore_edited = false;

pub fn sharedRestoreObserve(self: *AppSession) void {
    if (std.c.getenv("MARU_SHARED_RESTORE_PHASE") == null) return;
    if (self.dock_initialized) shared_restore_session = self;
}

fn sharedRestoreViews(self: *AppSession, out: *[2]*app_session_mod.Term) usize {
    var count: usize = 0;
    for (tab_ops.activeTab(self).panes.items) |pane| {
        for (pane.terms.items) |term| {
            if (term.kind != .editor) continue;
            if (count < out.len) out[count] = term;
            count += 1;
        }
    }
    return count;
}

fn sharedRestoreReport(self: *AppSession, label: u32) !void {
    var views: [2]*app_session_mod.Term = undefined;
    if (sharedRestoreViews(self, &views) != 2) return error.ExpectedTwoViews;
    const shared = views[0].rt.editorDocument() == views[1].rt.editorDocument();
    if (!shared) return error.ExpectedSharedDocument;
    for (views, 0..) |term, i| {
        const rt = term.rt;
        const doc = rt.editorDocument().opened.?;
        const selection = rt.editor_selection orelse return error.MissingSelection;
        const visible = if (rt.editor_visible_lines.len > 0) rt.editor_visible_lines else rt.editor_lines;
        const top_doc = if (rt.editor_visible_numbers.len > rt.editor_first_line)
            rt.editor_visible_numbers[rt.editor_first_line].? - 1
        else
            rt.editor_first_line;
        std.debug.print("SHARED_RESTORE label={d} view={d} shared={any} surface={d} hash={x} bytes={d} dirty={any} anchor={d} focus={d} line={d} doc_line={d} piece={d} col={d} wrap={any} folded={d} fold_heads_hash={x} fold_source={s} pending={any} max_cols={d} visible={d} hit_rows={d}\n", .{
            label, i, shared, term.surfaceId(), editor_ops.contentHash(doc.file.content), doc.file.content.len,
            doc.isDirty(), selection.anchor_start, selection.focus, rt.editor_first_line, top_doc,
            rt.editor_first_piece, rt.editor_first_col, rt.editor_wrap orelse self.loaded_config.config.editor.wrap,
            rt.editor_folded_len, std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(editor_ops.foldedHeads(term))), @tagName(rt.editor_fold_source), rt.editor_syntax.pending,
            rt.editor_max_cols, visible.len, rt.editor_hit_rows_len,
        });
    }
}

fn sharedRestoreSeed(self: *AppSession) !bool {
    if (shared_restore_seeded) return true;
    const source = pane_ops.activePane(self).activeTerm();
    if (source.kind != .editor or source.rt.editor_syntax.pending or !source.rt.editor_syntax_folds_applied) return false;
    if (std.c.getenv("MARU_SHARED_RESTORE_WAIT_LSP") != null and source.rt.editor_fold_source != .lsp) return false;
    if (!shared_restore_edited) {
        source.rt.editor_selection = maru.session.editor.selection.Selection.at(0);
        if (!editor_ops.insertText(self, source, "// 미저장 복원 검증\n")) return error.InsertFailed;
        shared_restore_edited = true;
        return false;
    }
    const peer = try pane_ops.splitSharedEditorPane(self, .horizontal, false);
    const views = [_]*app_session_mod.Term{ source, peer };
    for (views, 0..) |term, i| {
        term.rt.editor_wrap = i == 1;
        const ranges = term.rt.editor_fold_ranges;
        if (ranges.len < 6) return error.ExpectedFoldRanges;
        term.rt.editor_folded_buf[0] = ranges[if (i == 0) @as(usize, 1) else 5].head;
        term.rt.editor_folded_len = 1;
        const copy = try self.allocator.dupe(maru.session.editor.fold.Range, ranges);
        if (!editor_ops.installFoldRanges(self, term, copy)) {
            self.allocator.free(copy);
            return error.FoldFailed;
        }
        const lines = if (term.rt.editor_visible_lines.len > 0) term.rt.editor_visible_lines else term.rt.editor_lines;
        const first: usize = if (i == 0) 40 else 90;
        var top = first;
        while (top < lines.len and lines[top].len < 400) : (top += 1) {}
        if (top == lines.len) return error.NoLongLine;
        const doc_line = term.rt.editor_visible_numbers[top].? - 1;
        const line = term.rt.editorDocument().opened.?.file.lines.line(doc_line).?;
        term.rt.editor_selection = maru.session.editor.selection.Selection.fromPoints(line.start + 100, line.start + 110);
        term.rt.editor_first_line = top;
        term.rt.editor_first_col = if (i == 0) 70 else 0;
        term.rt.editor_first_piece = if (i == 0) 0 else 2;
    }
    if (!self.activateSurfaceById(source.surfaceId())) return error.FocusFailed;
    self.metal_dirty = true;
    shared_restore_seeded = true;
    return true;
}

export fn maru_shared_restore_fixture_step(command: u32) callconv(.c) i32 {
    const self = shared_restore_session orelse return 0;
    return sharedRestoreStep(self, command) catch |err| {
        std.debug.print("SHARED_RESTORE_ERROR command={d} error={s}\n", .{ command, @errorName(err) });
        return -1;
    };
}

fn sharedRestoreStep(self: *AppSession, command: u32) !i32 {
    if (command == 1) return if (try sharedRestoreSeed(self)) 1 else 0;
    var views: [2]*app_session_mod.Term = undefined;
    if (sharedRestoreViews(self, &views) != 2) return 0;
    if (command == 2) {
        for (views) |term| if (term.rt.editor_syntax.pending) return 0;
        if (std.c.getenv("MARU_SHARED_RESTORE_WAIT_LSP") != null) {
            for (views) |term| if (term.rt.editor_fold_source != .lsp) return 0;
        }
        return 1;
    }
    try sharedRestoreReport(self, command);
    return 1;
}
