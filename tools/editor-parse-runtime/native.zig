//! 실제 Apple main queue만 진행한다. worker.take/poll이나 render tick을 직접 호출하지 않는다.
const std = @import("std");
const parse = @import("parse").dispatch;
const maru = @import("maru");
const a = std.heap.page_allocator;
extern "c" fn maru_parse_run_main_turn() void;
const grammar: parse.request.Grammar = .{ .identity = 1, .generation = 0 };
fn document(owner: *parse.registry.Registry) !parse.registry.Lease {
    const file = try maru.session.editor.edit_doc.EditableFile.init(a, "// 한글\r\nconst first = 1;\n", false);
    var state: maru.session.editor.document_state.State = .{ .opened = .{ .file = file, .saved_hash = 0 } };
    defer state.clear(a);
    return owner.create(&state, a);
}
pub fn main() !void {
    var threaded = std.Io.Threaded.init(a, .{ .async_limit = .nothing, .concurrent_limit = .nothing });
    defer threaded.deinit();
    const deadline = std.Io.Clock.awake.now(threaded.io()).nanoseconds + 15_000_000_000;
    var first: parse.registry.Registry = .{ .allocator = a };
    var first_live = true;
    defer if (first_live) first.deinit() catch unreachable;
    const old_view = try document(&first);
    var old_open = true;
    defer {
        if (old_open) _ = first.release(old_view) catch unreachable;
    }
    defer parse.shutdown();
    const old_identity = first.identity(old_view).?;
    const initial = try parse.ensure(old_view, grammar, .zig);
    const duplicate = try parse.ensure(old_view, grammar, .zig);
    if (!initial.published or duplicate.published or !std.meta.eql(initial.tag, duplicate.tag)) return error.DuplicateParseRequest;
    while (parse.ready(old_identity, grammar, .zig) == null) {
        if (std.Io.Clock.awake.now(threaded.io()).nanoseconds > deadline) return error.Timeout;
        maru_parse_run_main_turn();
    }
    if (parse.lastPollThread().? != std.Thread.getCurrentId()) return error.WrongThread;
    const reused = try parse.ensure(old_view, grammar, .zig);
    if (reused.published or !std.meta.eql(reused.tag, initial.tag)) return error.ReadyNotShared;
    var installed: parse.view.State = .{};
    var installed_live = true;
    defer if (installed_live) installed.deinit(a);
    var prepared = (try parse.prepareView(old_identity, grammar, .zig)).?;
    defer prepared.deinit();
    if (!try parse.installView(&prepared, &installed, old_view, grammar, .zig)) return error.ViewNotInstalled;
    if (installed.provider == null or installed.input_stamp == null) return error.MissingViewProof;
    if (installed.provider.?.parser == parse.ready(old_identity, grammar, .zig).?.provider().?.parser) {
        // 잘못된 얕은 복사를 주입한 실행도 원본 parser를 두 번 지우지 않고 실패를 보고한다.
        installed.provider = null;
        return error.AliasedViewProvider;
    }
    var retained = (try parse.acquire(old_identity, grammar, .zig)).?;
    var retained_live = true;
    defer if (retained_live) retained.release();
    if (parse.tryShutdown()) |_| return error.ShutdownIgnoredConsumer else |err| {
        if (err != error.ResultsHeld) return err;
    }
    if (parse.ready(old_identity, grammar, .zig) == null or retained.provider() == null) return error.LostRetainedResult;
    retained.release();
    retained_live = false;
    if (parse.tryShutdown()) |_| return error.ShutdownIgnoredView else |err| {
        if (err != error.ResultsHeld) return err;
    }
    installed.deinit(a);
    installed_live = false;
    // 큐에 실제 OS 전달을 남기고 소유자와 원래 registry를 먼저 종료한다.
    parse.wake.request();
    parse.shutdown();
    if (!try first.release(old_view)) return error.LeakedKeeper;
    old_open = false;
    try first.deinit();
    first_live = false;
    var second: parse.registry.Registry = .{ .allocator = a };
    var second_live = true;
    defer {
        parse.shutdown();
        if (second_live) second.deinit() catch unreachable;
    }
    const view = try document(&second);
    var open = true;
    defer {
        if (open) _ = second.release(view) catch unreachable;
    }
    const identity = second.identity(view).?;
    _ = try parse.submit(view, grammar, .zig);
    while (parse.ready(identity, grammar, .zig) == null) {
        if (std.Io.Clock.awake.now(threaded.io()).nanoseconds > deadline) return error.Timeout;
        maru_parse_run_main_turn();
    }
    if (parse.ready(old_identity, grammar, .zig) != null) return error.StaleOwner;
    if (parse.lastPollThread().? != std.Thread.getCurrentId()) return error.WrongThread;
    if (try second.release(view)) return error.KeeperReleasedEarly;
    open = false;
    parse.viewsChanged();
    var saw_busy = false;
    while (true) {
        second.deinit() catch |err| {
            if (err != error.Busy) return err;
            saw_busy = true;
            if (std.Io.Clock.awake.now(threaded.io()).nanoseconds > deadline) return error.Timeout;
            maru_parse_run_main_turn();
            continue;
        };
        break;
    }
    second_live = false;
    if (!saw_busy) return error.KeeperReleasedEarly;
    parse.shutdown();
    maru_parse_run_main_turn(); // 늦게 남은 전달은 현재 소유자 없음으로 끝난다.
    std.debug.print("PARSE_MAIN_QUEUE accepted=2 main_thread=1 closed_document_reaped=1 late_delivery=1 retained_result=1 installed_view=1 shared_request=1\n", .{});
}
