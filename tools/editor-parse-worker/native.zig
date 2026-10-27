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
    var service = try worker.Service.init(allocator, .{ .notify = notify });
    defer service.deinit() catch unreachable;
    var gate: maru.session.editor.syntax.request.Gate = .{};
    var snapshot = source.snapshot();
    const input: maru.session.editor.syntax.request.Input = .{ .document = .{ .owner = 1, .slot = 1, .generation = 1 }, .revision = 1, .grammar = .{ .identity = 1, .generation = 0 } };
    _ = service.submit(&gate, input, &snapshot, .zig) catch |err| {
        snapshot.deinit();
        return err;
    };
    var first = try wait(&service, threaded.io());
    var first_open = true;
    defer if (first_open) first.release();
    if (first.outcome() != .ready or !first.accept(&gate) or first.provider().?.tree == null) return error.UnexpectedResult;
    _ = try source.insert(6, "changed_");
    var next = source.snapshot();
    var updated = input;
    updated.revision += 1;
    _ = service.submitFrom(&gate, updated, &next, .zig, &first) catch |err| {
        next.deinit();
        return err;
    };
    // submitFrom이 독립 참조를 준비했으므로 원본 결과를 곧바로 반납해도 된다.
    first.release();
    first_open = false;
    var second = try wait(&service, threaded.io());
    defer second.release();
    if (second.outcome() != .ready or !second.accept(&gate) or second.mode() != .incremental or second.basis() == null) return error.UnexpectedResult;
    std.debug.print("PARSE_WORKER_NATIVE cold=1 incremental=1 accepted=2\n", .{});
}
fn wait(service: *worker.Service, io: std.Io) !worker.Completion {
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + 10_000_000_000;
    while (true) {
        if (pending.swap(false, .acq_rel)) {
            _ = service.beginDrain();
            service.reap();
            if (service.take()) |value| return value;
        }
        if (std.Io.Clock.awake.now(io).nanoseconds > deadline) return error.Timeout;
        std.Thread.yield() catch {};
    }
}

var pending: std.atomic.Value(bool) = .init(false);
fn notify() void {
    pending.store(true, .release);
}
