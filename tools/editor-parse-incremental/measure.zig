//! 서비스 호출 준비와 완료까지의 경과를 분리한다. GUI 입력 지연을 재는 도구가 아니다.
const std = @import("std");
const worker = @import("worker");
const syntax = @import("syntax");
const maru = @import("maru");
fn now() i128 {
    return std.Io.Clock.awake.now(std.testing.io).nanoseconds;
}
fn take(service: *worker.Service) !worker.Completion {
    const deadline = now() + 10_000_000_000;
    while (true) {
        if (service.take()) |result| return result;
        if (now() > deadline) return error.Timeout;
        std.Thread.yield() catch {};
    }
}
test "incremental service measurement" {
    const a = std.heap.page_allocator;
    const path = std.mem.span(std.c.getenv("MARU_PARSE_FILE") orelse return error.MissingFixture);
    const incremental = std.mem.eql(u8, std.mem.span(std.c.getenv("MARU_PARSE_MODE") orelse return error.MissingMode), "incremental");
    const accuracy = std.mem.eql(u8, std.mem.span(std.c.getenv("MARU_PARSE_ACCURACY") orelse return error.MissingAccuracy), "1");
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(syntax.max_parse_bytes));
    defer a.free(bytes);
    const language: syntax.Language = if (std.mem.endsWith(u8, path, ".swift")) .swift else .zig;
    var source = try maru.session.editor.buffer.Buffer.init(a, bytes);
    defer source.deinit();
    var position = bytes.len / 2;
    while (position > 0 and bytes[position - 1] != '\n') : (position -= 1) {}
    var service = try worker.Service.init(a, .{});
    defer service.deinit() catch unreachable;
    var gate: maru.session.editor.syntax.request.Gate = .{};
    var input: maru.session.editor.syntax.request.Input = .{ .document = .{ .owner = 1, .slot = 1, .generation = 1 }, .revision = 1, .grammar = .{ .identity = @backingInt(language), .generation = 0 } };
    var snapshot = source.snapshot();
    _ = try service.submit(&gate, input, &snapshot, language);
    var prior = try take(&service);
    defer prior.release();
    try std.testing.expect(prior.accept(&gate));
    for (0..20) |index| {
        _ = try source.insert(position, " ");
        input.revision += 1;
        var next = source.snapshot();
        const start = now();
        if (incremental) {
            _ = try service.submitFrom(&gate, input, &next, language, &prior);
        } else {
            _ = try service.submit(&gate, input, &next, language);
        }
        const submitted = now();
        var result = try take(&service);
        const completed = now();
        errdefer result.release();
        try std.testing.expect(result.accept(&gate));
        try std.testing.expectEqual(if (incremental) worker.Mode.incremental else worker.Mode.cold, result.mode());
        if (incremental) try std.testing.expectEqual(prior.tag(), result.basis().?);
        var nodes: usize = 0;
        if (accuracy) {
            const current = try nextBytes(source, a);
            defer a.free(current);
            var fresh = syntax.Provider.init(current, language, 0) orelse return error.NoProvider;
            defer fresh.deinit();
            nodes = syntax.testing.equal(fresh.tree.?, result.provider().?.tree.?) orelse return error.TreeMismatch;
        }
        std.debug.print("PARSE_MEASURE index={d} mode={s} accuracy={d} submit_ns={d} complete_ns={d} nodes={d}\n", .{ index, @tagName(result.mode()), @intFromBool(accuracy), submitted - start, completed - start, nodes });
        prior.release();
        prior = result;
    }
}
fn nextBytes(source: maru.session.editor.buffer.Buffer, a: std.mem.Allocator) ![]u8 {
    var snapshot = source.snapshot();
    defer snapshot.deinit();
    return snapshot.copyRange(a, 0, snapshot.byteLen());
}
