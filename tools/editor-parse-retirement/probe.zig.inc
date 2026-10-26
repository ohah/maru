fn retirementNow() i128 { return std.Io.Clock.awake.now(std.testing.io).nanoseconds; }
const Retirement = struct {
    provider: *Provider,
    expected_end: u32,
    expected_type: []const u8,
    main_thread: std.Thread.Id,
    fault: []const u8,
    good: bool = false,
    released: bool = false,
    release_ns: i128 = 0,
    fn run(self: *@This()) void {
        if (self.provider.tree) |tree| {
            const node = c.ts_tree_root_node(tree);
            self.good = c.ts_node_end_byte(node) == self.expected_end and
                std.mem.eql(u8, std.mem.span(c.ts_node_type(node)), self.expected_type) and
                std.Thread.getCurrentId() != self.main_thread;
        }
        // 해제 누락을 주입해도 호출자가 회수할 수 있도록 소유권을 명시한다.
        if (std.mem.eql(u8, self.fault, "missingrelease")) return;
        const start = retirementNow();
        self.provider.deinit();
        self.release_ns = retirementNow() - start;
        self.released = true;
    }
};
test "handoff measure final provider retirement" {
    const a = std.testing.allocator;
    const path = std.mem.span(std.c.getenv("MARU_HANDOFF_FILE") orelse return error.MissingFixture);
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(max_parse_bytes));
    defer a.free(source);
    const language: Language = if (std.mem.endsWith(u8, path, ".swift")) .swift else .zig;
    const fault = std.mem.span(std.c.getenv("MARU_HANDOFF_FAULT") orelse "none");
    for (0..20) |iteration| {
        var original = Provider.init(source, language, 0) orelse return error.NoProvider;
        const node = c.ts_tree_root_node(original.tree orelse return error.NoTree);
        const expected_type = try a.dupe(u8, std.mem.span(c.ts_node_type(node)));
        defer a.free(expected_type);
        const expected_end = c.ts_node_end_byte(node);
        const copy_start = retirementNow();
        var peer = original.copyReady(language) orelse return error.NoCopy;
        const copy_ns = retirementNow() - copy_start;
        var job: Retirement = .{ .provider = &peer, .expected_end = expected_end, .expected_type = expected_type,
            .main_thread = std.Thread.getCurrentId(), .fault = fault };
        defer if (!job.released) peer.deinit();
        const release_start = retirementNow();
        original.deinit();
        const main_release_ns = retirementNow() - release_start;
        if (std.mem.eql(u8, fault, "geometry")) {
            const edit: c.TSInputEdit = .{ .start_byte = 0, .old_end_byte = 0, .new_end_byte = 1,
                .start_point = .{ .row = 0, .column = 0 }, .old_end_point = .{ .row = 0, .column = 0 }, .new_end_point = .{ .row = 0, .column = 1 } };
            c.ts_tree_edit(peer.tree.?, &edit);
        }
        if (std.mem.eql(u8, fault, "metadata")) job.expected_end += 1;
        if (std.mem.eql(u8, fault, "provider")) {
            peer.deinit();
            peer = Provider.init("const other = 1;\n", language, 0) orelse return error.NoProvider;
        }
        const start = retirementNow();
        if (std.mem.eql(u8, fault, "thread")) job.run() else {
            const worker = try std.Thread.spawn(.{}, Retirement.run, .{&job});
            worker.join();
        }
        const turnaround_ns = retirementNow() - start;
        try std.testing.expect(job.good);
        try std.testing.expect(job.released);
        std.debug.print("HANDOFF iteration={d} bytes={d} provider_copy_ns={d} main_release_ns={d} worker_release_ns={d} turnaround_ns={d} good=1\n", .{iteration,source.len,copy_ns,main_release_ns,job.release_ns,turnaround_ns});
    }
}
