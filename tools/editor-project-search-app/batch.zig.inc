// 배치 fixture의 추가 관측. UI 버튼은 Swift의 실제 AppKit mouse 이벤트가 누른다.
fn editorBatchProbe(self: *AppSession, stage: u32) i32 {
    const st = &self.editor_search;
    const wanted = std.fmt.parseInt(usize, std.mem.span(std.c.getenv("MARU_EDITOR_PROJECT_BATCH_OPEN_FILES") orelse "2"), 10) catch return -1;
    const retrying = std.mem.eql(u8, std.mem.span(std.c.getenv("MARU_EDITOR_PROJECT_BATCH_SAVE_RETRY") orelse "0"), "1");
    const saving = if (@hasField(@TypeOf(st.batch.result), "saving")) st.batch.result.saving else 0;
    if (stage >= 32 and stage <= 36 and saving != 0) return 0;
    if (retrying and stage >= 32 and stage <= 36) {
        const failed: usize = if (stage <= 34) 1 else 0;
        if (st.batch.phase != .completed or st.batch.result.save_failed != failed or st.batch.result.saved != wanted + 2 - failed) return -1;
        if ((stage >= 33 and stage <= 35) != (self.dock.side == .right)) return -1;
        return 1;
    }
    if (stage == 29) return if (st.result.phase == .complete) 1 else 0;
    if (stage == 30 or stage == 31) {
        if (st.batch.phase == .building) return 0;
        std.debug.print("BATCH_OBSERVE stage={d} phase={s} files={d} closed={d} failure={any}\n", .{stage, @tagName(st.batch.phase), st.batch.files, st.batch.closed, st.batch.failure});
        if (st.batch.phase != .ready or st.batch.files != wanted + 2 or st.batch.closed != 2) return -1;
        if ((stage == 30) != (self.dock.side == .right)) return -1;
        var input_bytes: usize = 0;
        var output_bytes: usize = 0;
        var plan_rows: usize = 0;
        for (st.batch.ready.?.prepared.items.items) |item| {
            input_bytes += item.plan.before.len;
            output_bytes += item.plan.after.len;
            plan_rows += item.plan.rows.items.len;
        }
        std.debug.print("BATCH_READY files={d} matches={d} closed={d} input_bytes={d} output_bytes={d} plan_rows={d}\n", .{st.batch.files, st.batch.matches, st.batch.closed, input_bytes, output_bytes, plan_rows});
        return 1;
    }
    if (stage == 32 or stage == 33) {
        if (st.batch.phase != .completed or st.batch.result.saved != wanted + 2 or st.batch.result.save_failed != 0) return -1;
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
            if (!std.mem.eql(u8, name, "symbols.zig") and !std.mem.startsWith(u8, name, "peer") and !std.mem.startsWith(u8, name, "disk")) continue;
            const opened = doc.opened orelse return -1;
            if (std.mem.indexOf(u8, opened.file.content, "renamed") != null) return -1;
            if (stage == 35 and editor_ops.isDirty(term)) return -1;
            count += 1;
        };
        return if (count == wanted + 2) 1 else -1;
    }
    return -1;
}
fn editorBatchAction(self: *AppSession, stage: u32) void {
    const d = @import("editor/search/dock.zig");
    const retrying = std.mem.eql(u8, std.mem.span(std.c.getenv("MARU_EDITOR_PROJECT_BATCH_SAVE_RETRY") orelse "0"), "1");
    if (retrying and (stage == 31 or stage == 34)) {
        const ready = &self.editor_search.batch.ready.?;
        for (ready.specification.targets.items, ready.prepared.items.items) |target, item| {
            if (target.source != .model or (stage == 34 and target.outcome != .save_failed)) continue;
            const data = if (stage == 31) "external conflict\n" else item.plan.before;
            std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = target.absolute, .data = data }) catch return;
            return;
        }
    }
    if (retrying and stage == 33) return;
    if (retrying and stage == 35) { self.dispatchAppAction(.toggle_file_panel_dock_side); return; }
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
            // 크기 실험은 일치 개수와 분리한다. 추가 본문은 검색어가 없는 주석이다.
            const padding = std.fmt.parseInt(usize, std.mem.span(std.c.getenv("MARU_EDITOR_PROJECT_BATCH_PEER_BYTES") orelse "0"), 10) catch return;
            const body = self.allocator.alloc(u8, "pub fn sample_peer() void {}\n".len + if (padding == 0) @as(usize, 0) else padding + 3) catch return;
            defer self.allocator.free(body);
            const prefix = "pub fn sample_peer() void {}\n";
            @memcpy(body[0..prefix.len], prefix);
            if (padding > 0) {
                @memcpy(body[prefix.len..][0..2], "//");
                @memset(body[prefix.len + 2 .. body.len - 1], 'x');
                body[body.len - 1] = '\n';
            }
            std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = body }) catch return;
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
            if (std.mem.eql(u8, name, "symbols.zig") or std.mem.startsWith(u8, name, "peer") or std.mem.startsWith(u8, name, "disk")) editor_ops.saveDocument(self, term) catch return;
        };
    }
}
