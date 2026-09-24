//! P5c3c-2b3 exact inventory sentinel.
//!
//! A filtered Zig runner accepts zero matches, so the executable pins the final-address owner,
//! source-consume, charged-lease ordering, and poisoned-connection lifetime evidence by name.

const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const source = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "src/platform/macos/session_host/external_pump_owner.zig",
        allocator,
        .limited(2 * 1024 * 1024),
    );
    defer allocator.free(source);
    for ([_][]const u8{
        "p5c3c-2b3 owner rejects a moved final-address copy in every build mode",
        "p5c3c-2b3 final owner consumes prepared once and binds only its stable adapter",
        "p5c3c-2b3 attachment-held charged lease blocks storage teardown until release",
        "p5c3c-2b3 poison preserves Client and ledger until attachment-first cleanup",
        "p5c3c-2b3 actual external attach prepare drives one owner pump control and teardown",
        "p5c3c-2b3 parser request id and capability state survive owner transition byte exact",
        "p5c3c-2b3 allocation fail index cleans exactly source or final owner",
        "p5c3c-2b3 owner pump fail-closes revoke and control timeout",
        "p5c3c-2b3 attachment append and apply OOM release stable charged owner",
    }) |test_name| {
        if (count(source, test_name) != 1) return error.P5c3c2b3GateMissing;
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
