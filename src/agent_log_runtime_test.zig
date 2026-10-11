test {
    _ = @import("pty/macos.zig");
}

// A correct EnvStorage helper is insufficient if the physical spawn caller
// forgets to pass the selected profile. Exercise the actual fork/exec boundary.
test "runtime pinned format reaches the actual PTY child" {
    const std = @import("std");
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const format = @import("agent_log_format.zig");
    const pty = @import("pty/macos.zig");
    const a = std.testing.allocator;
    for ([_]format.Profile{ .v1, .v2 }) |profile| {
        var child = try pty.PtySession.spawn(a, .{
            .command = "/bin/sh",
            .args = &.{ "-c", "printf '%s' \"$MARU_AGENT_LOG_FORMAT\"" },
            .env = &.{ "HOME=/nonexistent", "PATH=/nonexistent", "MARU_AGENT_LOG_FORMAT=3" },
            .env_overrides = &.{"MARU_AGENT_LOG_FORMAT="},
            .hook_log_profile = profile,
        });
        defer child.deinit();
        var output: std.ArrayListUnmanaged(u8) = .empty;
        defer output.deinit(a);
        const deadline = std.Io.Clock.awake.now(std.testing.io).nanoseconds + 5 * std.time.ns_per_s;
        var buffer: [32]u8 = undefined;
        while (true) {
            if (std.Io.Clock.awake.now(std.testing.io).nanoseconds >= deadline) return error.ChildDeadline;
            switch (try child.readChunk(&buffer)) {
                .data => |count| {
                    if (output.items.len + count > 32) return error.UnexpectedChildOutput;
                    try output.appendSlice(a, buffer[0..count]);
                },
                .again => try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake),
                .eof => break,
            }
        }
        try std.testing.expectEqualStrings(if (profile == .v1) "1" else "2", output.items);
    }
}
