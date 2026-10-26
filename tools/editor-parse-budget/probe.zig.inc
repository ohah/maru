// 모든 byte/point를 새 C 트리와 비교한다. S-expression만 같아도 좌표가 다를 수 있다.
fn budgetTreeEqual(left: *c.TSTree, right: *c.TSTree) ?usize {
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

fn budgetNow() i128 {
    return std.Io.Clock.awake.now(std.testing.io).nanoseconds;
}

test "budget measure edit slices and complete tree oracle" {
    const a = std.testing.allocator;
    const path = std.mem.span(std.c.getenv("MARU_BUDGET_FILE") orelse return error.MissingFixture);
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(max_parse_bytes));
    defer a.free(source);
    const language: Language = if (std.mem.endsWith(u8, path, ".swift")) .swift else .zig;
    const raw_budget = std.mem.span(std.c.getenv("MARU_BUDGET_NS") orelse return error.MissingBudget);
    const budget = try std.fmt.parseInt(u64, raw_budget, 10);
    const accuracy = std.mem.eql(u8, std.mem.span(std.c.getenv("MARU_BUDGET_ACCURACY") orelse "1"), "1");
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(a);
    try current.appendSlice(a, source);
    var p = Provider.init(source, language, 0) orelse return error.NoProvider;
    defer p.deinit();
    // 줄 시작을 고르므로 각 편집의 byte 축과 point 축이 같은 위치를 나타낸다.
    var position = source.len / 2;
    while (position > 0 and source[position - 1] != '\n') : (position -= 1) {}
    var row: u32 = 0;
    for (source[0..position]) |byte| if (byte == '\n') { row += 1; };
    for (0..20) |key| {
        var edited: std.ArrayList(u8) = .empty;
        defer edited.deinit(a);
        try edited.appendSlice(a, current.items[0..position]);
        try edited.append(a, ' ');
        try edited.appendSlice(a, current.items[position..]);
        const edit: Edit = .{ .start_byte = @intCast(position), .old_end_byte = @intCast(position), .new_end_byte = @intCast(position + 1),
            .start_point = .{ .row = row, .column = 0 }, .old_end_point = .{ .row = row, .column = 0 }, .new_end_point = .{ .row = row, .column = 1 } };
        provider_probe_ns = @splat(0);
        frame_parse_ns = 0;
        const start = budgetNow();
        p.onEditBudgeted(edited.items, edit, budget);
        const first_ns = budgetNow() - start;
        var done = budget_probe_done;
        var rounds: usize = 0;
        var total_call_ns = first_ns;
        var max_call_ns = first_ns;
        std.debug.print("BUDGET_SLICE key={d} slice=0 ns={d} native_ns={d} range_ns={d} done={d}\n", .{
            key, first_ns, frame_parse_ns, provider_probe_ns[5], @intFromBool(done),
        });
        while (!done and rounds < 10000) {
            frame_parse_ns = 0;
            provider_probe_ns = @splat(0);
            const resume_start = budgetNow();
            const status = p.setSourceBudgeted(edited.items, budget);
            const elapsed = budgetNow() - resume_start;
            rounds += 1;
            done = status == .done;
            try std.testing.expectEqual(done, budget_probe_done);
            total_call_ns += elapsed;
            max_call_ns = @max(max_call_ns, elapsed);
            std.debug.print("BUDGET_SLICE key={d} slice={d} ns={d} native_ns={d} range_ns={d} done={d}\n", .{
                key, rounds, elapsed, frame_parse_ns, provider_probe_ns[5], @intFromBool(done),
            });
        }
        try std.testing.expect(done);
        const wall_ns = budgetNow() - start;
        var nodes: usize = 0;
        var got: std.ArrayList(Span) = .empty;
        defer got.deinit(a);
        const lo: u32 = @intCast(position -| 128);
        const hi: u32 = @intCast(@min(edited.items.len, position + 512));
        const lookup_start = budgetNow();
        p.spansForRange(a, edited.items, .{ .start = lo, .end = hi }, &got);
        const lookup_ns = budgetNow() - lookup_start;
        if (accuracy) {
            var fresh = Provider.init(edited.items, language, 0) orelse return error.NoProvider;
            defer fresh.deinit();
            nodes = budgetTreeEqual(p.tree orelse return error.NoTree, fresh.tree orelse return error.NoTree) orelse return error.TreeMismatch;
            // 실제 색 질의 결과도 비교한다. 신선한 파싱과 oracle의 비용은 시간 모집단 밖이다.
            var want: std.ArrayList(Span) = .empty;
            defer want.deinit(a);
            fresh.spansForRange(a, edited.items, .{ .start = lo, .end = hi }, &want);
            try std.testing.expectEqual(want.items.len, got.items.len);
            for (got.items, want.items) |g, w| {
                try std.testing.expectEqual(g.start, w.start);
                try std.testing.expectEqual(g.end, w.end);
                try std.testing.expectEqualStrings(g.capture, w.capture);
            }
        }
        std.debug.print("BUDGET_EDIT key={d} budget_ns={d} first_ns={d} call_ns={d} max_ns={d} wall_ns={d} resumes={d} changed_all={d} changed_len={d} oracle_nodes={d} color_ns={d} accuracy={d}\n", .{
            key, budget, first_ns, total_call_ns, max_call_ns, wall_ns, rounds, @intFromBool(p.changed_all), p.changed_len, nodes, lookup_ns, @intFromBool(accuracy),
        });
        current.clearRetainingCapacity();
        try current.appendSlice(a, edited.items);
    }
}

fn budgetPoint(source: []const u8) Point {
    var point: Point = .{ .row = 0, .column = 0 };
    for (source) |byte| {
        if (byte == '\n') { point.row += 1; point.column = 0; } else point.column += 1;
    }
    return point;
}

test "budget measure pending edits discard older parse state" {
    if (std.mem.eql(u8, std.mem.span(std.c.getenv("MARU_BUDGET_ACCURACY") orelse "1"), "0")) {
        std.debug.print("BUDGET_CHAIN skipped=1\n", .{});
        return;
    }
    const a = std.testing.allocator;
    const original = try denseSource(a, 3000);
    defer a.free(original);
    const first = try std.mem.concat(a, u8, &.{ " ", original });
    defer a.free(first);
    const second = try std.mem.concat(a, u8, &.{ "\n", first });
    defer a.free(second);
    var p = Provider.init(original, .zig, 0) orelse return error.NoProvider;
    defer p.deinit();
    for ([_][]const u8{ first, second }, 0..) |after, stage| {
        p.onEditBudgeted(after, .{ .start_byte = 0, .old_end_byte = 0, .new_end_byte = 1,
            .start_point = .{ .row = 0, .column = 0 }, .old_end_point = .{ .row = 0, .column = 0 },
            .new_end_point = if (stage == 0) .{ .row = 0, .column = 1 } else .{ .row = 1, .column = 0 } }, 1);
        try std.testing.expect(!budget_probe_done);
        std.debug.print("BUDGET_CHAIN stage={d} pending=1\n", .{stage});
    }
    const memo = "// latest\n";
    const latest = try std.mem.concat(a, u8, &.{ memo, second });
    defer a.free(latest);
    // 처음 pending 원문으로 돌아가기 전에 반드시 다른 최신 원문을 확인해야 reset 결함이 드러난다.
    p.onEditBudgeted(latest, .{ .start_byte = 0, .old_end_byte = 0, .new_end_byte = memo.len,
        .start_point = .{ .row = 0, .column = 0 }, .old_end_point = .{ .row = 0, .column = 0 },
        .new_end_point = .{ .row = 1, .column = 0 } }, 0);
    try std.testing.expect(budget_probe_done);
    var newest = Provider.init(latest, .zig, 0) orelse return error.NoProvider;
    defer newest.deinit();
    _ = budgetTreeEqual(p.tree.?, newest.tree.?) orelse return error.PendingLatestMismatch;
    // 트리가 아직 없는 여는 파싱의 pending도 같은 새 입력으로 전환해야 한다.
    var cold = Provider.init("", .zig, 0) orelse return error.NoProvider;
    defer cold.deinit();
    try std.testing.expectEqual(Provider.ParseStatus.pending, cold.setSourceBudgeted(original, 1));
    cold.onEditBudgeted(latest, .{ .start_byte = 0, .old_end_byte = @intCast(original.len), .new_end_byte = @intCast(latest.len),
        .start_point = .{ .row = 0, .column = 0 }, .old_end_point = budgetPoint(original),
        .new_end_point = budgetPoint(latest) }, 0);
    _ = budgetTreeEqual(cold.tree orelse return error.NoTree, newest.tree.?) orelse return error.PendingColdMismatch;
    // 실제 Undo 명령이 아닌 같은 byte 역편집 대조다.
    p.onEditBudgeted(second, .{ .start_byte = 0, .old_end_byte = memo.len, .new_end_byte = 0,
        .start_point = .{ .row = 0, .column = 0 }, .old_end_point = .{ .row = 1, .column = 0 },
        .new_end_point = .{ .row = 0, .column = 0 } }, 0);
    try std.testing.expect(budget_probe_done);
    var fresh = Provider.init(second, .zig, 0) orelse return error.NoProvider;
    defer fresh.deinit();
    const inverse_nodes = budgetTreeEqual(p.tree.?, fresh.tree.?) orelse return error.PendingInverseMismatch;
    const replacement = "fn f() void { const s = \"한😀\"; _ = s; }\n";
    p.onEditBudgeted(replacement, .{ .start_byte = 0, .old_end_byte = @intCast(second.len), .new_end_byte = replacement.len,
        .start_point = .{ .row = 0, .column = 0 }, .old_end_point = budgetPoint(second),
        .new_end_point = budgetPoint(replacement) }, 0);
    try std.testing.expect(budget_probe_done);
    var replaced = Provider.init(replacement, .zig, 0) orelse return error.NoProvider;
    defer replaced.deinit();
    const replaced_nodes = budgetTreeEqual(p.tree.?, replaced.tree.?) orelse return error.PendingReplacementMismatch;
    std.debug.print("BUDGET_CHAIN stage=2 inverse_nodes={d} replacement_nodes={d} latest_equal=1\n", .{inverse_nodes, replaced_nodes});
}

test "budget measure oracle rejects a shifted native tree" {
    var left = Provider.init("const a = 1;\n", .zig, 0) orelse return error.NoProvider;
    defer left.deinit();
    var right = Provider.init("const a = 1;\n", .zig, 0) orelse return error.NoProvider;
    defer right.deinit();
    try std.testing.expect(budgetTreeEqual(left.tree.?, right.tree.?) != null);
    var edit: c.TSInputEdit = .{ .start_byte = 0, .old_end_byte = 0, .new_end_byte = 1,
        .start_point = .{ .row = 0, .column = 0 }, .old_end_point = .{ .row = 0, .column = 0 }, .new_end_point = .{ .row = 0, .column = 1 } };
    c.ts_tree_edit(left.tree.?, &edit);
    try std.testing.expect(budgetTreeEqual(left.tree.?, right.tree.?) == null);
    std.debug.print("BUDGET_ORACLE normal=1 shifted_rejected=1\n", .{});
}
