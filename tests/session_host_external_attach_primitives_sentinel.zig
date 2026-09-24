//! P5c3c-3a1 exact test inventory sentinel.
//!
//! Filtered Zig runners may otherwise succeed after a test rename, so this executable pins all
//! nine primitive tests independently of the test runner.

const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const files = [_]struct { path: []const u8, names: []const []const u8 }{
        .{
            .path = "src/platform/macos/session_host/external_detach_chord.zig",
            .names = &.{
                "p5c3c-3a1 detach chord forwards exact controller byte sequences",
                "p5c3c-3a1 detach chord deadline is exact and EOF drops a lone prefix",
                "p5c3c-3a1 observer suppresses non-chord input but still detaches locally",
            },
        },
        .{
            .path = "src/platform/macos/session_host/external_stdout_progress.zig",
            .names = &.{
                "p5c3c-3a1 zero-byte replacement inherits the blocked stdout epoch",
                "p5c3c-3a1 partial stdout frame cannot be replaced and progress has exact deadlines",
                "p5c3c-3a1 stdout progress rejects backwards clocks overflow and impossible writes",
            },
        },
        .{
            .path = "src/platform/macos/session_host/external_tty_output.zig",
            .names = &.{
                "p5c3c-3a1 dedicated TTY output failure matrix leaves no published owner",
                "p5c3c-3a1 dedicated TTY output publishes only at its final address and closes exactly once",
                "p5c3c-3a1 real openpty uses a separate nonblocking close-on-exec output description",
            },
        },
    };
    for (files) |file| {
        const source = try std.Io.Dir.cwd().readFileAlloc(
            io,
            file.path,
            allocator,
            .limited(256 * 1024),
        );
        defer allocator.free(source);
        for (file.names) |name|
            if (std.mem.count(u8, source, name) != 1) return error.P5c3c3a1GateMissing;
    }
}
