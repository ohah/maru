fn foldProbeJudge(p: *Provider) !void {
    const a = std.testing.allocator;
    var expected: std.ArrayList(Provider.FoldSpan) = .empty;
    defer expected.deinit(a);
    var got: std.ArrayList(Provider.FoldSpan) = .empty;
    defer got.deinit(a);
    try p.foldSpansFull(a, &expected);
    try p.foldSpans(a, &got);
    try std.testing.expectEqualDeep(expected.items, got.items);
}

test "EW2 fold cache 전체 순회 대조 언어와 편집 지연 삭제 교체" {
    const a = std.testing.allocator;
    for ([_]struct { language: Language, source: []const u8 }{
EW2_CASES
    }) |case| {
        var p = Provider.init(case.source, case.language, 0) orelse return error.NoProvider;
        defer p.deinit();
        try foldProbeJudge(&p);
    }
    for ([_]Language{.zig, .python, .dart, .swift, .markdown}) |language| {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(a);
        try text.appendSlice(a, "const A = struct {\n fn f() void {\n return;\n }\n};\nfn g() void {\n return;\n}\n");
        var p = Provider.init(text.items, language, 0) orelse return error.NoProvider;
        defer p.deinit();
        try foldProbeJudge(&p);
        var random: std.Random.DefaultPrng = .init(0x464f4c4453);
        const rng = random.random();
        const inserts = [_][]const u8{"x", "\n", "{}", "fn q() void {\n return;\n}\n", " ", "/*", "*/", "\r\n", "// 한글\n"};
        for (0..400) |i| {
            const at = rng.uintLessThan(usize, text.items.len + 1);
            const end = @min(text.items.len, at + rng.uintLessThan(usize, 16));
            const insert = if (i % 3 == 0) "" else inserts[rng.uintLessThan(usize, inserts.len)];
            const sp = stickyPoint(text.items, at);
            const ep = stickyPoint(text.items, end);
            try text.replaceRange(a, at, end-at, insert);
            p.onEdit(text.items, .{.start_byte=@intCast(at), .old_end_byte=@intCast(end), .new_end_byte=@intCast(at+insert.len), .start_point=sp, .old_end_point=ep, .new_end_point=stickyPoint(text.items,at+insert.len)});
            if (i % 4 == 0 or i == 399) try foldProbeJudge(&p);
        }
        for ([_][]const u8{"\n", "fn f() void {\n return;\n}\n", "fn g() void {\r\n return;\r\n}\r\n", ""}) |next| {
            p.setSource(next);
            try foldProbeJudge(&p);
        }
    }
}

test "EW2 fold cache C 트리 사본의 수명" {
    const a = std.testing.allocator;
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(a);
    highlights(a, .zig, "fn f() void {}\n", &spans);
    c.ts_set_allocator(countingMalloc, countingCalloc, countingRealloc, countingFree);
    defer c.ts_set_allocator(null, null, null, null);
    live_allocs = 0;
    {
        const source = "fn f() void {\n return;\n}\n";
        var p = Provider.init(source, .zig, 0) orelse return error.NoProvider;
        defer p.deinit();
        try foldProbeJudge(&p);
        p.onEdit(source, .{.start_byte=0,.old_end_byte=0,.new_end_byte=0,.start_point=.{.row=0,.column=0},.old_end_point=.{.row=0,.column=0},.new_end_point=.{.row=0,.column=0}});
        try foldProbeJudge(&p);
        p.setSource("fn g() void {\n _ = 1;\n}\n");
        try foldProbeJudge(&p);
    }
    try std.testing.expectEqual(@as(isize,0),live_allocs);
}
