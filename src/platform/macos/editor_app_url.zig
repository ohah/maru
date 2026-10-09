//! Main-thread adapter for the OS-neutral startup queue. The URL itself never
//! selects an AppSession pointer: Swift resolves a live normal window at drain.
const std = @import("std");
const maru = @import("maru");
const AppSession = @import("app_session.zig").AppSession;
const editor = @import("app_session/editor/mod.zig");
const pane = @import("app_session/pane.zig");
var queue: maru.session.editor_app_url.Queue = .{};

pub fn offer(raw: []const u8) u32 {
    queue.offer(std.heap.page_allocator, raw) catch |err| return switch (err) {
        error.InvalidURL, error.TooLong => 1,
        error.Full => 2,
        error.Stopped => 3,
        error.OutOfMemory => 4,
    };
    return 0;
}
pub fn ready() void {
    queue.ready();
}
pub fn stop() void {
    queue.stop(std.heap.page_allocator);
}
pub fn pending() u32 {
    return if (queue.state == .ready) @intCast(queue.count) else 0;
}

/// Every result consumes exactly one request, including failed IME admission.
pub fn drain(session: ?*AppSession, admitted: bool) u32 {
    var request = queue.take() orelse return 0;
    defer request.deinit(std.heap.page_allocator);
    const target = session orelse {
        std.log.warn("editor URL id={d} rejected: no normal window", .{request.id});
        return 2;
    };
    if (!admitted) {
        target.showNoticeKey(.git_conflict_open_failed); // Existing neutral translated "Could not open that file".
        return 2;
    }
    editor.navigateUserFile(target, request) catch |err| {
        std.log.warn("editor URL id={d} open failed: {s}", .{ request.id, @errorName(err) });
        target.showNoticeKey(.git_conflict_open_failed);
        return 2;
    };
    const term = pane.activePane(target).activeTerm();
    const offset = if (term.rt.editor_selection) |selection| selection.focus else 0;
    std.log.info("editor URL id={d} opened surface={d} byte={d}", .{ request.id, term.surfaceId(), offset });
    // Opt-in OS smoke binds the exact requested file without exposing its name.
    if (std.c.getenv("MARU_EDITOR_APP_URL_RECEIPTS")) |value| {
        if (std.mem.eql(u8, std.mem.span(value), "1")) {
            var hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(request.path, &hash, .{});
            const hex = std.fmt.bytesToHex(hash, .lower);
            std.debug.print("[EDITOR_URL] id={d} surface={d} byte={d} path_sha256={s}\n", .{ request.id, term.surfaceId(), offset, hex });
        }
    }
    return 1;
}
