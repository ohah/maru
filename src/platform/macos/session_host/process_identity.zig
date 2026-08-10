//! Dependency-neutral process identity for session-host ownership authorities.
//!
//! macOS and Linux product/test paths use the real process ID so inherited state is rejected
//! after fork. Unsupported targets return zero so process-domain admission fails closed.

const builtin = @import("builtin");
const std = @import("std");

pub fn currentProcessId() u32 {
    return switch (builtin.os.tag) {
        .macos, .linux => @intCast(std.c.getpid()),
        else => 0,
    };
}

test "macOS and Linux process identity is the real nonzero process ID" {
    if (builtin.os.tag == .macos or builtin.os.tag == .linux) {
        try std.testing.expectEqual(@as(u32, @intCast(std.c.getpid())), currentProcessId());
        try std.testing.expect(currentProcessId() != 0);
    } else {
        try std.testing.expectEqual(@as(u32, 0), currentProcessId());
    }
}
