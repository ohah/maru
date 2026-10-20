// 격리 검증 사본의 editor/mod.zig 끝에만 붙인다. 제품에는 훅이나 새 공개 API를 넣지 않는다.
test "SAVEWAKEEXTRA 여러 창의 첫 저장이 서로의 경로와 예약을 침범하지 않는다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const wake = @import("save/wake.zig");
    _ = wake.deliverForTest();
    var a = try FirstSaveFixture.init();
    defer a.deinit();
    var b = try FirstSaveFixture.init();
    defer b.deinit();
    var gate: @import("save/worker.zig").TestGate = .{};
    defer gate.set();
    @import("save/as.zig").setGateForTests(&gate);
    @import("save/as.zig").firstSave(a.fx.session, a.term, a.path, false);
    @import("save/as.zig").firstSave(b.fx.session, b.term, b.path, false);
    try testing.expect(wake.deliverForTest());
    try testing.expectEqual(@as(usize, 2), @import("save/as.zig").pending());
    try testing.expect(a.term.rt.editorDocument().path == null and b.term.rt.editorDocument().path == null);
    gate.set();
    try awaitSaveWakeForTest();
    try a.disk("foo");
    try b.disk("foo");
    try testing.expectEqualStrings(a.path, a.term.rt.editorDocument().path.?);
    try testing.expectEqualStrings(b.path, b.term.rt.editorDocument().path.?);
    try testing.expect(a.term.file_entry != b.term.file_entry);
    try testing.expect(!isDirty(a.term) and !isDirty(b.term));
    try testing.expectEqual(@as(usize, 0), a.fx.session.editor_batch_reserved_entries);
    try testing.expectEqual(@as(usize, 0), b.fx.session.editor_batch_reserved_entries);
}

test "SAVEWAKEEXTRA 연속 편집과 32개 저장 접수는 마지막 본문과 Undo를 보존한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    _ = @import("save/wake.zig").deliverForTest();
    var fx = try FirstSaveFixture.init();
    defer fx.deinit();
    @import("save/as.zig").firstSave(fx.fx.session, fx.term, fx.path, false);
    try awaitSaveWakeForTest();
    for (0..32) |_| {
        try testing.expect(insertText(fx.fx.session, fx.term, "x"));
        try testing.expect((try @import("save/dispatch.zig").trySave(fx.fx.session, fx.term, null)) != null);
    }
    const expected = try testing.allocator.dupe(u8, fx.term.rt.editorDocument().opened.?.file.content);
    defer testing.allocator.free(expected);
    try awaitSaveWakeForTest();
    try fx.disk(expected);
    try testing.expect(!isDirty(fx.term));
    try testing.expect(undoEdit(fx.fx.session, fx.term));
    try testing.expect(redoEdit(fx.fx.session, fx.term));
    try testing.expectEqualStrings(expected, fx.term.rt.editorDocument().opened.?.file.content);
}

test "SAVEWAKEEXTRA 한 창의 IME 닫기 대기는 다른 창의 저장과 닫기를 막지 않는다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const wake = @import("save/wake.zig");
    _ = wake.deliverForTest();
    var a = try FirstSaveFixture.init();
    defer a.deinit();
    var b = try FirstSaveFixture.init();
    defer b.deinit();
    @import("save/as.zig").firstSave(a.fx.session, a.term, a.path, false);
    @import("save/as.zig").firstSave(b.fx.session, b.term, b.path, false);
    try awaitSaveWakeForTest();
    try testing.expect(insertText(a.fx.session, a.term, "!"));
    try testing.expect(insertText(b.fx.session, b.term, "!"));
    const a_count = pane_ops.activePane(a.fx.session).terms.items.len;
    const b_count = pane_ops.activePane(b.fx.session).terms.items.len;
    a.fx.session.requestClose(.active_term);
    b.fx.session.requestClose(.active_term);
    a.fx.session.ime_active = true;
    nativeCloseAccept(a.fx.session);
    nativeCloseAccept(b.fx.session);
    const deadline = std.Io.Clock.awake.now(testing.io).nanoseconds + 5 * std.time.ns_per_s;
    while (b.fx.session.editor_save_close != null) {
        _ = wake.deliverForTest();
        if (std.Io.Clock.awake.now(testing.io).nanoseconds >= deadline) return error.SaveWakeTimedOut;
        _ = usleep(1000);
    }
    try b.disk("foo!");
    try testing.expectEqual(b_count - 1, pane_ops.activePane(b.fx.session).terms.items.len);
    try testing.expect(a.fx.session.editor_save_close != null);
    try testing.expectEqual(a_count, pane_ops.activePane(a.fx.session).terms.items.len);
    @import("../input.zig").imeEnd(a.fx.session, null);
    while (a.fx.session.editor_save_close != null) {
        _ = wake.deliverForTest();
        if (std.Io.Clock.awake.now(testing.io).nanoseconds >= deadline) return error.SaveWakeTimedOut;
        _ = usleep(1000);
    }
    try a.disk("foo!");
    try testing.expectEqual(a_count - 1, pane_ops.activePane(a.fx.session).terms.items.len);
    _ = wake.deliverForTest();
}

test "SAVEWAKEEXTRA 시작 전 거절 뒤 새 대상 세대의 저장은 정상 회복한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    _ = @import("save/wake.zig").deliverForTest();
    var fx = try FirstSaveFixture.init();
    defer fx.deinit();
    @import("save/as.zig").firstSave(fx.fx.session, fx.term, fx.path, false);
    try awaitSaveWakeForTest();
    try testing.expect(insertText(fx.fx.session, fx.term, "!"));
    _ = try @import("save/dispatch.zig").trySave(fx.fx.session, fx.term, null);
    fx.term.rt.editorDocument().invalidateSaveTarget();
    try awaitSaveWakeForTest();
    try fx.disk("foo");
    try testing.expect(isDirty(fx.term));
    try testing.expectEqual(@as(usize, 0), @import("save/dispatch.zig").requestCount());
    try testing.expect((try @import("save/dispatch.zig").trySave(fx.fx.session, fx.term, null)) != null);
    try awaitSaveWakeForTest();
    try fx.disk("foo!");
    try testing.expect(!isDirty(fx.term));
    try testing.expectEqual(@as(usize, 0), @import("save/dispatch.zig").requestCount());
}

const SaveWakeExtraReentry = struct {
    var called: usize = 0;
    var failed = false;
    fn run() void {
        const wake = @import("save/wake.zig");
        wake.extra_hook = null; // 격리 훅 자체의 무한 재귀는 만들지 않는다.
        called += 1;
        if (!wake.extraPumping()) failed = true;
        wake.request();
        if (!wake.deliverForTest()) failed = true;
        if (!wake.extraPumping() or !wake.extraQueued()) failed = true;
    }
};

test "SAVEWAKEEXTRA 처리 중 재진입은 중첩 drain을 막고 다음 turn을 보존한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const wake = @import("save/wake.zig");
    _ = wake.deliverForTest();
    var fx = try FirstSaveFixture.init();
    defer fx.deinit();
    SaveWakeExtraReentry.called = 0;
    SaveWakeExtraReentry.failed = false;
    wake.extra_hook = SaveWakeExtraReentry.run;
    defer wake.extra_hook = null;
    @import("save/as.zig").firstSave(fx.fx.session, fx.term, fx.path, false);
    try testing.expect(wake.deliverForTest());
    try testing.expectEqual(@as(usize, 1), SaveWakeExtraReentry.called);
    try testing.expect(!SaveWakeExtraReentry.failed);
    try testing.expect(!wake.extraPumping());
    try awaitSaveWakeForTest();
    try fx.disk("foo");
    try testing.expect(!isDirty(fx.term));
    try testing.expect(!wake.deliverForTest());
}
