// 제품 coordinator로 다수 뷰와 비관련 문서를 섞는다. 화면/HID 지연을 뜻하지 않는다.
test "shared parse reuse product stress 다수 뷰와 비관련 문서" {
    const a = testing.allocator;
    for ([_]usize{ 0, 128 }) |unrelated| {
        var fx = try PaneFixture.init(a);
        defer fx.deinit(a);
        fx.session.loaded_config.config.lsp.enabled = false;
        for (0..unrelated) |i| {
            var name: [64]u8 = undefined;
            _ = try undoFixture(&fx, a, try std.fmt.bufPrint(&name, "unrelated-{d}.zig", .{i}), "fn unrelated() void {}\n");
        }
        const source = try undoFixture(&fx, a, "shared-stress.zig", "fn f() void {\n _ = 1;\n}\n");
        const second = try pane_ops.splitSharedEditorPane(fx.session, .horizontal, false);
        const third = try pane_ops.splitSharedEditorPane(fx.session, .vertical, false);
        const views = [_]*Term{ source, second, third };
        for (views) |view| view.rt.editor_selection = editor_selection.Selection.at(0);
        var samples: [20]u64 = undefined;
        for (&samples, 0..) |*sample, i| {
            var before: u64 = 0;
            for (views) |view| before += view.rt.editor_syntax.provider.?.stats.reused_parses;
            const start = std.Io.Clock.awake.now(fx.session.io).nanoseconds;
            try testing.expect(insertText(fx.session, views[i % views.len], " "));
            sample.* = @intCast(std.Io.Clock.awake.now(fx.session.io).nanoseconds - start);
            var after: u64 = 0;
            for (views) |view| {
                after += view.rt.editor_syntax.provider.?.stats.reused_parses;
                try foldMarksReady(&fx, view);
                try expectSharedParseOutputs(view, a);
            }
            try testing.expectEqual(before + 2, after);
        }
        std.debug.print("SHARED_PARSE_STRESS views=3 unrelated={d} samples_ns=", .{unrelated});
        for (samples) |value| std.debug.print("{d},", .{value});
        std.debug.print("\n", .{});
    }
}
