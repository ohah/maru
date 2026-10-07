// 격리된 소스 사본에만 붙이는 관측기다. 배포 ABI나 사용자 명령을 추가하지 않는다.
var shared_restore_session: ?*AppSession = null;
var shared_restore_seeded = false;
var shared_restore_edited = false;
var shared_restore_split_ready = false;

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
    var views: [2]*app_session_mod.Term = undefined;
    const count = sharedRestoreViews(self, &views);
    if (count == 1) {
        // 공개 메뉴/키/팔레트 경로는 Swift 드라이버가 실행한다. 여기서 내부 helper를 대신 부르지 않는다.
        shared_restore_split_ready = true;
        return false;
    }
    if (count != 2) return error.ExpectedTwoViews;
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
    if (!self.activateSurfaceById(views[0].surfaceId())) return error.FocusFailed;
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
    if (command == 31) {
        // Read-only independent postcondition after the real HID close and save.
        var surviving: [2]*app_session_mod.Term = undefined;
        if (sharedRestoreViews(self, &surviving) != 1) return error.ExpectedOneView;
        const term = surviving[0];
        const doc = term.rt.editorDocument().opened.?;
        if (doc.isDirty() or !std.mem.eql(u8, doc.file.content, "L가 R나")) return error.CloseIMEBody;
        const selection = term.rt.editor_selection orelse return error.MissingSelection;
        if (selection.anchor_start != 4 or selection.focus != 4) return error.CloseIMESelection;
        if (pane_ops.activePane(self).activeTerm() != term or self.pending_confirm != .none) return error.CloseIMEFocus;
        std.debug.print("SHARED_IME_CLOSE count=1 clean=true bytes=9 surface={d} caret=4\n", .{term.surfaceId()});
        return 1;
    }
    if (command == 40) return try sharedRestoreRefuseMove(self);
    if (command >= 50 and command <= 55) return try sharedRestoreCloseProbe(self, command);
    if (command == 1) return if (try sharedRestoreSeed(self)) 1 else if (shared_restore_split_ready) 2 else 0;
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

fn sharedRestoreRefuseMove(self: *AppSession) !i32 {
    var views: [2]*app_session_mod.Term = undefined;
    if (sharedRestoreViews(self, &views) != 2) return error.ExpectedTwoViews;
    const before = editor_ops.contentHash(views[0].rt.editorDocument().opened.?.file.content);
    if (!self.runAction("move_pane_to_new_workspace")) return error.PromoteFailed;
    const index = self.app_window.active_tab;
    const source_tab = self.tabs.items[index];
    // 목적지는 헤드리스 AppSession이다. 실제 두 NSWindow의 메뉴/드래그 검증으로 세지 않는다.
    const dst = try self.allocator.create(AppSession);
    defer self.allocator.destroy(dst);
    try dst.init(self.io, self.allocator, .{
        .abi_version = app_session_mod.abi_version, .cols = 80, .rows = 24, .queue_capacity = 16,
        .command_kind = @intFromEnum(app_session_mod.CommandKind.controlled_smoke),
    });
    defer dst.deinit();
    var out: [16]u64 = undefined;
    if (AppSession.moveWorkspaceToSession(self, dst, index, &out)) |_| return error.MoveUnexpectedlyAccepted else |err| {
        if (err != error.UnsupportedMove) return err;
    }
    if (!self.chrome_host.notice.open or !std.mem.eql(u8, self.chrome_host.notice.message, maru.i18n.t(.ws_move_shared_editor))) return error.ExpectedMoveNotice;
    if (self.tabs.items.len != 2 or self.tabs.items[index] != source_tab or dst.tabs.items.len != 1) return error.MoveChangedTopology;
    if (editor_ops.contentHash(views[0].rt.editorDocument().opened.?.file.content) != before) return error.MoveChangedDocument;
    std.debug.print("SHARED_SPLIT_MOVE refused=true topology_preserved=true body_preserved=true destination=headless-AppSession\n", .{});
    return 1;
}


// These probes observe close results; the Swift driver dispatches every close/cancel/save key.
var shared_close_hash: u64 = 0;
var shared_close_survivor: u64 = 0;
var shared_close_selection: ?maru.session.editor.selection.Selection = null;

fn sharedRestoreCloseProbe(self: *AppSession, command: u32) !i32 {
    var views: [2]*app_session_mod.Term = undefined;
    const count = sharedRestoreViews(self, &views);
    if (command == 50) {
        if (count != 2) return 0;
        if (self.chrome_host.notice.open) return 2;
        shared_close_hash = editor_ops.contentHash(views[0].rt.editorDocument().opened.?.file.content);
        shared_close_survivor = views[0].surfaceId();
        shared_close_selection = views[0].rt.editor_selection;
        // Initial input target only: closing the peer must preserve the other view.
        if (!self.activateSurfaceById(views[1].surfaceId())) return error.FocusFailed;
        return 1;
    }
    if (command == 55) {
        if (count != 0 or self.pending_confirm != .none) return error.LastViewNotClosed;
        std.debug.print("SHARED_CLOSE event=last_closed count=0\n", .{});
        return 1;
    }
    if (count != 1 or views[0].surfaceId() != shared_close_survivor) {
        std.debug.print("SHARED_CLOSE_MISMATCH command={d} count={d} survivor={d} expected={d} pending={s} focus={s} active={d}\n", .{
            command, count, if (count > 0) views[0].surfaceId() else 0, shared_close_survivor,
            @tagName(self.pending_confirm), @tagName(self.focus_owner), pane_ops.activePane(self).activeTerm().surfaceId(),
        });
        return error.SurvivorMissing;
    }
    const survivor = views[0];
    const doc = survivor.rt.editorDocument().opened.?;
    if (editor_ops.contentHash(doc.file.content) != shared_close_hash) return error.CloseChangedDocument;
    if (!std.meta.eql(survivor.rt.editor_selection, shared_close_selection)) return error.CloseChangedSelection;
    if (pane_ops.activePane(self).activeTerm() != survivor) return error.SurvivorNotFocused;
    if (command == 52) {
        if (self.pending_confirm != .close or !doc.isDirty()) return error.MissingDirtyCloseConfirmation;
    } else {
        if (self.pending_confirm != .none) return error.UnexpectedCloseConfirmation;
        if (doc.isDirty() != (command != 54)) return error.UnexpectedDirtyState;
    }
    std.debug.print("SHARED_CLOSE event={s} count=1 hash={x} dirty={any}\n", .{
        switch (command) { 51 => "one_closed", 52 => "last_prompt", 53 => "cancelled", 54 => "saved", else => return error.UnknownCloseProbe },
        shared_close_hash, doc.isDirty(),
    });
    return 1;
}
