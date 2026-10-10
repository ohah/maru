// 배치 fixture의 추가 관측. UI 버튼은 Swift의 실제 AppKit mouse 이벤트가 누른다.
fn editorBatchProbe(self: *AppSession, stage: u32) i32 {
    const st = &self.editor_search;
    const wanted = std.fmt.parseInt(usize, std.mem.span(std.c.getenv("MARU_EDITOR_PROJECT_BATCH_OPEN_FILES") orelse "2"), 10) catch return -1;
    if (stage == 29) return if (st.result.phase == .complete) 1 else 0;
    if (stage == 30 or stage == 31) {
        if (st.batch.phase == .building) return 0;
        std.debug.print("BATCH_OBSERVE stage={d} phase={s} files={d} omitted={d} failure={any}\n", .{stage, @tagName(st.batch.phase), st.batch.files, st.batch.omitted, st.batch.failure});
        if (st.batch.phase != .ready or st.batch.files != wanted or st.batch.omitted != 2) return -1;
        if ((stage == 30) != (self.dock.side == .right)) return -1;
        var input_bytes: usize = 0;
        var output_bytes: usize = 0;
        var plan_rows: usize = 0;
        for (st.batch.ready.?.prepared.items.items) |item| {
            input_bytes += item.plan.before.len;
            output_bytes += item.plan.after.len;
            plan_rows += item.plan.rows.items.len;
        }
        std.debug.print("BATCH_READY files={d} matches={d} omitted={d} input_bytes={d} output_bytes={d} plan_rows={d}\n", .{st.batch.files, st.batch.matches, st.batch.omitted, input_bytes, output_bytes, plan_rows});
        return 1;
    }
    if (stage == 32 or stage == 33) {
        if (st.batch.phase != .completed or st.batch.result.saved != wanted or st.batch.result.save_failed != 0) return -1;
        if ((stage == 33) != (self.dock.side == .right)) return -1;
        std.debug.print("BATCH_SAVED files={d} saved={d} failed={d}\n", .{st.batch.files, st.batch.result.saved, st.batch.result.save_failed});
        return 1;
    }
    if (stage == 34 or stage == 35) {
        var count: usize = 0;
        for (self.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| {
            if (term.kind != .editor) continue;
            const doc = term.rt.editorDocument();
            const path = doc.path orelse continue;
            const name = std.fs.path.basename(path);
            if (!std.mem.eql(u8, name, "symbols.zig") and !std.mem.startsWith(u8, name, "peer")) continue;
            const opened = doc.opened orelse return -1;
            if (std.mem.indexOf(u8, opened.file.content, "renamed") != null) return -1;
            if (stage == 35 and editor_ops.isDirty(term)) return -1;
            count += 1;
        };
        return if (count == wanted) 1 else -1;
    }
    return -1;
}
fn editorBatchAction(self: *AppSession, stage: u32) void {
    const d = @import("editor/search/dock.zig");
    if (stage == 28) {
        // 앞 단일 파일 시나리오가 열었던 disk 탭을 닫아 ‘두 모델 + 닫힌 두 파일’을 만든다.
        close_disk: for (self.tabs.items, 0..) |tab, ti| for (tab.panes.items) |pane| for (pane.terms.items, 0..) |term, i| {
            if (term.kind != .editor) continue;
            const current_path = term.rt.editorDocument().path orelse continue;
            if (std.mem.startsWith(u8, std.fs.path.basename(current_path), "disk")) {
                term_ops.closeTermAt(self, ti, pane, i);
                break :close_disk;
            }
        };
        const root = self.file_tree.rootAt(0) orelse return;
        const wanted = std.fmt.parseInt(usize, std.mem.span(std.c.getenv("MARU_EDITOR_PROJECT_BATCH_OPEN_FILES") orelse "2"), 10) catch return;
        for (1..wanted) |i| {
            const name = if (i == 1) self.allocator.dupe(u8, "peer.zig") catch return else std.fmt.allocPrint(self.allocator, "peer{d}.zig", .{i}) catch return;
            defer self.allocator.free(name);
            const path = std.fs.path.join(self.allocator, &.{root, name}) catch return;
            defer self.allocator.free(path);
            std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = "pub fn sample_peer() void {}\n" }) catch return;
            _ = editor_ops.openPathInActivePane(self, path) catch return;
        }
        d.preview.back(self);
        d.batch_ui.back(self);
        self.editor_search.replacing = true;
        self.editor_search.focused = 3;
        d.run(self);
    } else if (stage == 30 or stage == 32) {
        self.dispatchAppAction(.toggle_file_panel_dock_side);
    } else if (stage == 33) {
        const term = pane_ops.activePane(self).activeTerm();
        if (!editor_ops.undoEdit(self, term)) return;
        if (self.pending_confirm != .linked_history) return;
        const pending = self.pending_confirm.linked_history;
        self.chrome_host.confirm.open = false;
        self.pending_confirm = .none;
        editor_ops.linked_history.choose(self, pending, false);
    } else if (stage == 34) {
        for (self.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| {
            if (term.kind != .editor or !editor_ops.isDirty(term)) continue;
            const path = term.rt.editorDocument().path orelse continue;
            const name = std.fs.path.basename(path);
            if (std.mem.eql(u8, name, "symbols.zig") or std.mem.startsWith(u8, name, "peer")) editor_ops.saveDocument(self, term) catch return;
        };
    }
}
