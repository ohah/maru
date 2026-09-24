//! P5c3c-3a2 exact test inventory sentinel.

const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const files = [_]struct { path: []const u8, names: []const []const u8 }{
        .{
            .path = "src/platform/macos/session_host/external_tty.zig",
            .names = &.{
                "p5c3c-3a2 prepared raw TTY rejects pre-commit drift before termios mutation",
            },
        },
        .{
            .path = "src/platform/macos/session_host/external_pump_owner.zig",
            .names = &.{
                "p5c3c-3a2 pre-raw owner mutates no TTY or ANSI state before commit",
                "p5c3c-3a2 raw commit publishes exact enter and teardown restores with exact leave",
                "p5c3c-3a2 commit rejects TTY drift before raw mutation and remains cleanable",
                "p5c3c-3a2 partial enter write restores TTY and keeps terminal cleanup authority",
                "p5c3c-3a2 repaint allocation failure consumes or cleans every owner without raw mutation",
                "p5c3c-3a2 repaint allocator teardown reentry is busy and preserves the final owner",
                "p5c3c-3a2 enter writer teardown reentry is busy until commit publishes live",
            },
        },
    };
    for (files) |file| {
        const source = try std.Io.Dir.cwd().readFileAlloc(
            io,
            file.path,
            allocator,
            .limited(512 * 1024),
        );
        defer allocator.free(source);
        for (file.names) |name|
            if (std.mem.count(u8, source, name) != 1) return error.P5c3c3a2GateMissing;
    }
}
