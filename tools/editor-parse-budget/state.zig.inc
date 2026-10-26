// 현재 공유 뷰 계약이 미완료 자원을 받지 않는지 검사한다. 제품의 편집 정책을 바꾸지 않는다.
test "budget state contract pending gates and independent shared copies" {
    const a = std.testing.allocator;
    const identity: maru.session.editor.document_registry.DocumentIdentity = .{ .owner = 1, .slot = 0, .generation = 1 };
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    for (0..3000) |_| try text.appendSlice(a, "fn f() void {\n _ = (1);\n}\n");
    var lines = try maru.session.editor.line_index.build(a, text.items);
    defer lines.deinit();
    var state = openBudgeted(text.items, .zig, 0);
    var live = true;
    defer if (live) state.deinit(a);
    updateForInput(&state, a, text.items, null, lines, identity, 1, null);
    try std.testing.expect(matchesInput(&state, identity, 1));
    try finishBrackets(&state, a, text.items);
    var folds: std.ArrayList(syntax.Provider.FoldSpan) = .empty;
    defer folds.deinit(a);
    try state.provider.?.foldSpansCached(a, &state.folds, lines.lines, &folds);
    const peer = prepareSharedSnapshot(&state, a, .zig) orelse return error.NoSnapshot;
    defer { peer.deinit(a); a.destroy(peer); }
    try std.testing.expect(matchesInput(peer, identity, 1));
    const edited = try std.mem.concat(a, u8, &.{ " ", text.items });
    defer a.free(edited);
    const p = if (state.provider) |*value| value else return error.NoProvider;
    syntax.budget_probe_done = true;
    p.onEditBudgeted(edited, .{ .start_byte = 0, .old_end_byte = 0, .new_end_byte = 1,
        .start_point = .{ .row = 0, .column = 0 }, .old_end_point = .{ .row = 0, .column = 0 }, .new_end_point = .{ .row = 0, .column = 1 } }, 1);
    // 실제 시계 1ns로 pending API 계약을 검사한다. 이 실행은 성능 표본이 아니다.
    try std.testing.expect(!syntax.budget_probe_done);
    state.pending = true;
    try std.testing.expect(!matchesInput(&state, identity, 1));
    try std.testing.expect(!matchesInput(&state, identity, 2));
    try std.testing.expect(prepareSharedSnapshot(&state, a, .zig) == null);
    try std.testing.expect(matchesInput(peer, identity, 1));
    var rounds: usize = 0;
    while (state.pending and rounds < 10000) : (rounds += 1) _ = resumeParse(&state, edited);
    try std.testing.expect(!state.pending and state.provider.?.tree != null);
    // 완료만으로는 새 입력 판을 발급하지 않는다. 이것을 생략하면 재사용 연계 설계가 빠진다.
    try std.testing.expect(state.input_stamp == null);
    try std.testing.expect(!matchesInput(&state, identity, 2));
    var after_lines = try maru.session.editor.line_index.build(a, edited);
    defer after_lines.deinit();
    updateForInput(&state, a, edited, null, after_lines, identity, 2, null);
    try std.testing.expect(matchesInput(&state, identity, 2));
    const before_reuse = peer.provider.?.stats.reused_parses;
    updateForInput(peer, a, edited, .{ .start = 0, .old_end = 0, .new_end = 1 }, after_lines, identity, 2, &state);
    try std.testing.expect(matchesInput(peer, identity, 2));
    try std.testing.expectEqual(before_reuse + 1, peer.provider.?.stats.reused_parses);
    try finishBrackets(peer, a, edited);
    try expectBracketRepositionOracle(peer, edited, .zig, false);
    try peer.provider.?.foldSpansCached(a, &peer.folds, after_lines.lines, &folds);
    var expected: std.ArrayList(syntax.Provider.FoldSpan) = .empty;
    defer expected.deinit(a);
    try peer.provider.?.foldSpans(a, &expected);
    try std.testing.expectEqualDeep(expected.items, folds.items);
    state.deinit(a);
    live = false;
    try std.testing.expect(matchesInput(peer, identity, 2));
    try expectBracketRepositionOracle(peer, edited, .zig, false);
    std.debug.print("BUDGET_STATE pending_rejected=1 peer_preserved=1 resume_stamp_absent=1 restamped=1 shared_reused=1 brackets_equal=1 folds_equal=1 owner_released=1\n", .{});
}
