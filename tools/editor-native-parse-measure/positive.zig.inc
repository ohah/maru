// 시간값으로 성공을 고르지 않는다. 취소 조건만 대조 사본에서 강제하고 실제 C 반환을 확인한다.
test "native probe control cold structural cancellation counters are live" {
    const a = testing.allocator;
    const native = syntax_color.syntax;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(a);
    for (0..3000) |_| try source.appendSlice(a, "const value = 1;\n");
    var wrapped: std.ArrayList(u8) = .empty;
    defer wrapped.deinit(a);
    try wrapped.appendSlice(a, "fn control() void {\n");
    try wrapped.appendSlice(a, source.items);
    try wrapped.appendSlice(a, "}\n");
    native.native_probe_force_expired = false;
    defer native.native_probe_force_expired = false;
    var provider = native.Provider.init("", .zig, 0) orelse return error.NoProvider;
    defer provider.deinit();
    native.native_parse_probe = .{};
    try testing.expectEqual(native.Provider.ParseStatus.done, provider.setSourceBudgeted(source.items, 0));
    const cold = native.native_parse_probe;
    try testing.expectEqual(@as(u64, 1), cold.calls);
    try testing.expectEqual(@as(u64, 0), cold.old_tree_calls);
    try testing.expectEqual(@as(u64, @intCast(source.items.len)), cold.source_bytes);
    try testing.expect(cold.read_calls > 0 and cold.eof_calls > 0 and cold.offered_bytes > 0);
    native.native_parse_probe = .{};
    provider.onEditBudgeted(wrapped.items, .{
        .start_byte = 0,
        .old_end_byte = @intCast(source.items.len),
        .new_end_byte = @intCast(wrapped.items.len),
        .start_point = .{ .row = 0, .column = 0 },
        .old_end_point = .{ .row = 3000, .column = 0 },
        .new_end_point = .{ .row = 3002, .column = 0 },
    }, 0);
    const structural = native.native_parse_probe;
    try testing.expectEqual(@as(u64, 1), structural.calls);
    try testing.expectEqual(@as(u64, 1), structural.old_tree_calls);
    try testing.expectEqual(@as(u64, 1), structural.done);
    try testing.expectEqual(@as(u64, 1), structural.range_calls);
    try testing.expect(structural.range_items > 0 and structural.nonempty_ranges > 0);
    var cancelled = native.Provider.init("", .zig, 0) orelse return error.NoProvider;
    defer cancelled.deinit();
    native.native_parse_probe = .{};
    native.native_probe_force_expired = true;
    const status = cancelled.setSourceBudgeted(source.items, 1);
    native.native_probe_force_expired = false;
    const pending = native.native_parse_probe;
    try testing.expectEqual(native.Provider.ParseStatus.pending, status);
    try testing.expectEqual(@as(u64, 1), pending.budget_ns);
    try testing.expectEqual(@as(u64, 1), pending.pending);
    try testing.expect(pending.progress_calls > 0 and pending.cancel_returns > 0);
    try testing.expectEqual(native.Provider.ParseStatus.done, cancelled.setSourceBudgeted(source.items, 0));
    try testing.expect(cancelled.tree != null);
    std.debug.print("NATIVE_POSITIVE cold_old={d} cold_reads={d} cold_eof={d} structural_items={d} forced_cancel={d} pending={d} resume_done=1\n", .{
        cold.old_tree_calls, cold.read_calls, cold.eof_calls, structural.range_items, pending.cancel_returns, pending.pending,
    });
}
