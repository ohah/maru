//! F3e gate inventory sentinel.
//!
//! The filtered Zig runner succeeds when a filter matches zero tests, so this executable keeps
//! the hostile response/revoke transport evidence from disappearing silently. That matters to a
//! terminal because a missing ordering test can re-open post-revoke writes or leak RX/TX owners
//! while the ordinary unit suite still reports green.

const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const planner = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "src/platform/macos/session_host/client_pump.zig",
        allocator,
        .limited(512 * 1024),
    );
    defer allocator.free(planner);
    const product = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "src/platform/macos/session_host/client_external_pump.zig",
        allocator,
        .limited(4 * 1024 * 1024),
    );
    defer allocator.free(product);

    const pure_name =
        "f3e pure hostile matrix seals response revoke HUP control progress and deadline precedence";
    if (count(planner, pure_name) != 1) return error.F3ePureGateMissing;

    for ([_][]const u8{
        "f3e injected turn suppresses TX across revoke boundaries and transport retries",
        "f3e socketpair orders response revoke and FIN without writable TX",
        "f3e socketpair rejects incomplete frames and bounds one byte drip",
        "f3e allocation fail index restores the common owner graph",
        "f3e bounded stress preserves common final zero",
    }) |test_name| {
        if (count(product, test_name) != 1) return error.F3eProductGateMissing;
    }
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, cursor, needle)) |found| {
        total += 1;
        cursor = found + needle.len;
    }
    return total;
}
