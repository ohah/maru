fn handoffTreeEqual(left: *c.TSTree, right: *c.TSTree) ?usize {
    var lc = c.ts_tree_cursor_new(c.ts_tree_root_node(left));
    defer c.ts_tree_cursor_delete(&lc);
    var rc = c.ts_tree_cursor_new(c.ts_tree_root_node(right));
    defer c.ts_tree_cursor_delete(&rc);
    var nodes: usize = 0;
    while (true) {
        const ln = c.ts_tree_cursor_current_node(&lc);
        const rn = c.ts_tree_cursor_current_node(&rc);
        if (!std.mem.eql(u8, std.mem.span(c.ts_node_type(ln)), std.mem.span(c.ts_node_type(rn)))) return null;
        if (c.ts_node_start_byte(ln) != c.ts_node_start_byte(rn) or c.ts_node_end_byte(ln) != c.ts_node_end_byte(rn)) return null;
        if (!std.meta.eql(c.ts_node_start_point(ln), c.ts_node_start_point(rn)) or
            !std.meta.eql(c.ts_node_end_point(ln), c.ts_node_end_point(rn))) return null;
        if (c.ts_node_is_named(ln) != c.ts_node_is_named(rn) or c.ts_node_is_missing(ln) != c.ts_node_is_missing(rn) or
            c.ts_node_is_extra(ln) != c.ts_node_is_extra(rn) or c.ts_node_has_error(ln) != c.ts_node_has_error(rn) or
            c.ts_node_child_count(ln) != c.ts_node_child_count(rn)) return null;
        if (c.ts_tree_cursor_current_field_id(&lc) != c.ts_tree_cursor_current_field_id(&rc)) return null;
        nodes += 1;
        const child = c.ts_tree_cursor_goto_first_child(&lc);
        if (child != c.ts_tree_cursor_goto_first_child(&rc)) return null;
        if (child) continue;
        while (true) {
            const sibling = c.ts_tree_cursor_goto_next_sibling(&lc);
            if (sibling != c.ts_tree_cursor_goto_next_sibling(&rc)) return null;
            if (sibling) break;
            const parent = c.ts_tree_cursor_goto_parent(&lc);
            if (parent != c.ts_tree_cursor_goto_parent(&rc)) return null;
            if (!parent) return nodes;
        }
    }
}

// 스냅샷은 메인에서 반환·해제한다. 워커는 원본 allocator를 호출하지 않는다.
const handoff_buffer = @import("handoff_buffer");
fn handoffNow() i128 { return std.Io.Clock.awake.now(std.testing.io).nanoseconds; }
const Handoff = struct {
    snapshot: handoff_buffer.Snapshot,
    provider: *Provider,
    expected: []const u8,
    go: std.atomic.Value(bool) = .init(false),
    good: bool = false,
    copy_ns: i128 = 0,
    fault: []const u8,
    lang: Language,
    fn run(self: *@This()) void {
        while (!self.go.load(.acquire)) std.atomic.spinLoopHint();
        const start = handoffNow();
        const end = self.snapshot.byteLen() - @as(usize, @intFromBool(std.mem.eql(u8, self.fault, "truncated")));
        const bytes = self.snapshot.copyRange(std.heap.page_allocator, 0, end) catch return;
        self.copy_ns = handoffNow() - start;
        defer std.heap.page_allocator.free(bytes);
        if (std.mem.eql(u8, self.fault, "byte")) bytes[0] ^= 1;
        var oracle = Provider.init(self.expected, self.lang, 0) orelse return;
        defer oracle.deinit();
        self.good = std.mem.eql(u8, bytes, self.expected) and self.provider.tree != null;
        if (self.provider.tree) |tree| {
            self.good = self.good and handoffTreeEqual(tree, oracle.tree.?) != null;
            var cursor = c.ts_tree_cursor_new(c.ts_tree_root_node(tree));
            defer c.ts_tree_cursor_delete(&cursor);
            self.good = self.good and c.ts_node_end_byte(c.ts_tree_cursor_current_node(&cursor)) <= bytes.len;
        }
    }
};
test "handoff measure snapshot provider ownership" {
    const a = std.testing.allocator;
    const path = std.mem.span(std.c.getenv("MARU_HANDOFF_FILE") orelse return error.MissingFixture);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(max_parse_bytes));
    defer a.free(bytes);
    const lang: Language = if (std.mem.endsWith(u8, path, ".swift")) .swift else .zig;
    const fault = std.mem.span(std.c.getenv("MARU_HANDOFF_FAULT") orelse "none");
    for (0..20) |iteration| {
        var buf = try handoff_buffer.Buffer.init(a, bytes);
        var p = Provider.init(bytes, lang, 0) orelse return error.NoProvider;
        const retain_start = handoffNow();
        var snapshot = buf.snapshot();
        const retain_ns = handoffNow() - retain_start;
        const copy_start = handoffNow();
        var peer = p.copyReady(lang) orelse return error.NoCopy;
        const provider_ns = handoffNow() - copy_start;
        if (std.mem.eql(u8, fault, "tree")) {
            const change: c.TSInputEdit = .{ .start_byte = 0, .old_end_byte = 0, .new_end_byte = 1,
                .start_point = .{ .row = 0, .column = 0 }, .old_end_point = .{ .row = 0, .column = 0 }, .new_end_point = .{ .row = 0, .column = 1 } };
            c.ts_tree_edit(peer.tree.?, &change);
        }
        var late: ?handoff_buffer.Snapshot = null;
        var job: Handoff = .{ .snapshot = snapshot, .provider = &peer, .expected = bytes, .fault = fault, .lang = lang };
        if (std.mem.eql(u8, fault, "latest")) {
            _ = try buf.insert(0, "late");
            late = buf.snapshot();
            job.snapshot = late.?;
        }
        const thread = try std.Thread.spawn(.{}, Handoff.run, .{&job});
        job.go.store(true, .release);
        if (!std.mem.eql(u8, fault, "lost_edit")) _ = try buf.insert(0, " // 새 판\n");
        // 워커와 별도 트리 핸들을 메인에서도 조회한다.
        try std.testing.expect(p.tree != null);
        thread.join();
        if (late) |*held| held.deinit();
        try std.testing.expect(job.good);
        const current = try buf.copyRange(a, 0, buf.byteLen());
        defer a.free(current);
        try std.testing.expect(!std.mem.eql(u8, current, bytes));
        const shared_release_start = handoffNow();
        peer.deinit();
        const shared_release_ns = handoffNow() - shared_release_start;
        const final_tree_start = handoffNow();
        p.deinit();
        const final_tree_ns = handoffNow() - final_tree_start;
        buf.deinit();
        const final_snapshot_start = handoffNow();
        snapshot.deinit();
        const final_snapshot_ns = handoffNow() - final_snapshot_start;
        std.debug.print("HANDOFF iteration={d} bytes={d} retain_ns={d} provider_ns={d} worker_copy_ns={d} shared_release_ns={d} final_tree_ns={d} final_snapshot_ns={d} good=1\n", .{iteration, bytes.len, retain_ns, provider_ns, job.copy_ns, shared_release_ns, final_tree_ns, final_snapshot_ns});
    }
}
