//! 테스트 전용 필드가 없는 실제 production-mode 서비스의 최소 실행이다. 앱 UI는 열지 않는다.
const std = @import("std");
const worker = @import("worker");
const maru = @import("maru");
pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(allocator, .{ .async_limit = .nothing, .concurrent_limit = .nothing });
    defer threaded.deinit();
    var source = try maru.session.editor.buffer.Buffer.init(allocator, "const native = 1;\n");
    defer source.deinit();
    var service = try worker.Service.init(allocator, .{});
    defer service.deinit() catch unreachable;
    var gate: maru.session.editor.syntax.request.Gate = .{};
    var snapshot = source.snapshot();
    const input: maru.session.editor.syntax.request.Input = .{ .document = .{ .owner = 1, .slot = 1, .generation = 1 }, .revision = 1, .grammar = .{ .identity = 1, .generation = 0 } };
    _ = service.submit(&gate, input, &snapshot, .zig) catch |err| {
        snapshot.deinit();
        return err;
    };
    const deadline = std.Io.Clock.awake.now(threaded.io()).nanoseconds + 10_000_000_000;
    while (true) {
        if (service.take()) |value| {
            var result = value;
            defer result.release();
            if (result.outcome() != .ready or !result.accept(&gate) or result.provider().?.tree == null) return error.UnexpectedResult;
            std.debug.print("PARSE_WORKER_NATIVE ready=1 accepted=1\n", .{});
            break;
        }
        if (std.Io.Clock.awake.now(threaded.io()).nanoseconds > deadline) return error.Timeout;
        std.Thread.yield() catch {};
    }
}
