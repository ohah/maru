//! P5c3c-3b exact test inventory sentinel.

const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const files = [_]struct { path: []const u8, names: []const []const u8 }{
        .{
            .path = "src/platform/macos/session_host/external_loop_policy.zig",
            .names = &.{
                "p5c3c-3b turn priority gives one ready stdin turn before immediate host work",
                "p5c3c-3b normal cleanup appends detach only without in-flight wire authority",
                "p5c3c-3b signal revoke and error discard work and bound leave to one hundred milliseconds",
                "p5c3c-3b cleanup deadline overflow is rejected before a plan is minted",
                "p5c3c-3b poll timeout is the minimum absolute deadline and never rounds past it",
                "p5c3c-3b poll timeout rejects invalid clock and deadline",
                "p5c3c-3b per-turn budgets match the normative transport bounds",
            },
        },
        .{
            .path = "src/platform/macos/session_host/external_loop_owner.zig",
            .names = &.{
                "p5c3c-3b local stack binds chord and resize to one immutable initial role",
                "p5c3c-3b local stack rejects an impossible initial terminal size",
                "p5c3c-3b uncommitted integrated owner rejects pump and input without mutation",
                "p5c3c-3b actual openpty integrated owner commits raw and restores exact ANSI and termios",
                "p5c3c-3b actual openpty stdout backpressure preserves one immutable partial frame",
                "p5c3c-3b actual openpty stdin reaches one MRSH input frame without byte loss",
                "p5c3c-3b actual poll loop suppresses observer input and detaches with restored tty",
                "p5c3c-3b actual poll loop restores tty before forwarding termination signal",
                "p5c3c-3b offset-zero cleanup cancellation retires queued input before detach",
            },
        },
        .{
            .path = "src/platform/macos/session_host/remote_attachment.zig",
            .names = &.{
                "p5c3c-3b external live screen borrow applies through the attachment screen owner",
            },
        },
        .{
            .path = "src/platform/macos/session_host/external_attach_cli.zig",
            .names = &.{
                "p5c3c-3b public attach maps cleanup outcomes to stable exits",
            },
        },
    };
    for (files) |file| {
        const source = try std.Io.Dir.cwd().readFileAlloc(
            io,
            file.path,
            allocator,
            .limited(1024 * 1024),
        );
        defer allocator.free(source);
        for (file.names) |name|
            if (std.mem.count(u8, source, name) != 1) return error.P5c3c3bGateMissing;
    }
}
