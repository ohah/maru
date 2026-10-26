const cancel_buffer = @import("handoff_buffer");
const CancelProbe = struct {
    active: std.atomic.Value(bool) = .init(true),
    entered: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),
    callbacks: std.atomic.Value(usize) = .init(0),
    fault: []const u8,
    fn progress(self: *@This()) bool {
        _ = self.callbacks.fetchAdd(1, .monotonic);
        if (std.mem.eql(u8, self.fault, "skip_barrier")) return false;
        self.entered.store(true, .release);
        while (!self.release.load(.acquire)) std.atomic.spinLoopHint();
        if (std.mem.eql(u8, self.fault, "ignore_cancel")) return false;
        if (std.mem.eql(u8, self.fault, "false_cancel")) return true;
        return self.cancel.load(.acquire);
    }
};
// 한 번에 한 워커만 사용하며 spawn 전 설치, join 후 제거한다. 실행 중 포인터를 교체하지 않는다.
var cancel_probe: ?*CancelProbe = null;
const CancelJob = struct {
    snapshot: cancel_buffer.Snapshot,
    lang: Language,
    probe: *CancelProbe,
    oom: bool,
    done: std.atomic.Value(bool) = .init(false),
    copied_hash: u64 = 0,
    failed_copy: bool = false,
    had_tree: bool = false,
    parser_created: bool = false,
    fn run(self: *@This()) void {
        defer self.done.store(true, .release);
        var failing = std.testing.FailingAllocator.init(std.heap.page_allocator, .{ .fail_index = 0 });
        const fail = self.oom and !std.mem.eql(u8, self.probe.fault, "ignore_oom");
        const allocator = if (fail) failing.allocator() else std.heap.page_allocator;
        const bytes = self.snapshot.copyRange(allocator, 0, self.snapshot.byteLen()) catch {
            self.failed_copy = true;
            return;
        };
        defer allocator.free(bytes);
        if (std.mem.eql(u8, self.probe.fault, "corrupt_copy")) bytes[0] ^= 1;
        self.copied_hash = std.hash.Wyhash.hash(0, bytes);
        var provider = Provider.init(bytes, self.lang, 0) orelse return;
        self.parser_created = true;
        self.had_tree = provider.tree != null;
        provider.deinit();
    }
};
fn cancelNow() i128 { return std.Io.Clock.awake.now(std.testing.io).nanoseconds; }
test "handoff measure real callback cancellation lifetime" {
    const a = std.testing.allocator;
    const path = std.mem.span(std.c.getenv("MARU_HANDOFF_FILE") orelse return error.MissingFixture);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(max_parse_bytes));
    defer a.free(bytes);
    const expected_hash = std.hash.Wyhash.hash(0, bytes);
    const language: Language = if (std.mem.endsWith(u8, path, ".swift")) .swift else .zig;
    const fault = std.mem.span(std.c.getenv("MARU_HANDOFF_FAULT") orelse "none");
    for (0..5) |iteration| {
        var total_callbacks: usize = 0;
        // 0: 첫 콜백 전 취소, 1: 콜백 진입 후 취소, 2: 정상 완료, 3: 실제 복사 할당 실패.
        for (0..4) |mode| {
            var buffer = try cancel_buffer.Buffer.init(a, bytes);
            var buffer_open = true;
            defer if (buffer_open) buffer.deinit();
            var snapshot = buffer.snapshot();
            defer snapshot.deinit();
            var probe: CancelProbe = .{ .fault = fault };
            if (mode == 0) probe.cancel.store(true, .release);
            var job: CancelJob = .{ .snapshot = snapshot, .lang = language, .probe = &probe, .oom = mode == 3 };
            cancel_probe = &probe;
            defer cancel_probe = null;
            const worker = try std.Thread.spawn(.{}, CancelJob.run, .{&job});
            const deadline = cancelNow() + 10_000_000_000;
            while (!probe.entered.load(.acquire) and !job.done.load(.acquire) and cancelNow() < deadline) std.atomic.spinLoopHint();
            const entered = probe.entered.load(.acquire);
            const held = !job.done.load(.acquire);
            // 원본 문서 버퍼를 바꾼 뒤 닫아도 snapshot은 C 호출 반환 이후까지 메인이 유지한다.
            const edit_ok = blk: {
                _ = buffer.insert(0, " // 최신 본문\n") catch break :blk false;
                break :blk true;
            };
            buffer.deinit();
            buffer_open = false;
            if (mode == 1) probe.cancel.store(true, .release);
            probe.release.store(true, .release);
            worker.join();
            cancel_probe = null;
            try std.testing.expect(edit_ok);
            if (mode == 3) {
                try std.testing.expect(job.failed_copy and !job.parser_created);
                try std.testing.expectEqual(@as(usize, 0), probe.callbacks.load(.acquire));
            } else {
                try std.testing.expect(entered and held);
                try std.testing.expect(job.parser_created and !job.failed_copy);
                try std.testing.expectEqual(expected_hash, job.copied_hash);
                try std.testing.expectEqual(mode == 2, job.had_tree);
                total_callbacks += probe.callbacks.load(.acquire);
            }
            const retained = try snapshot.copyRange(a, 0, snapshot.byteLen());
            defer a.free(retained);
            try std.testing.expectEqualSlices(u8, bytes, retained);
        }
        std.debug.print("CANCEL iteration={d} bytes={d} cases=4 callbacks={d} good=1\n", .{iteration, bytes.len, total_callbacks});
    }
}
