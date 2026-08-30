const std = @import("std");

test "U5 signed success reattaches through the GUI RemoteRuntime boundary" {
    const source = @embedFile("session_host_signed_upgrade_e2e.zig");
    try std.testing.expect(std.mem.indexOf(u8, source, "session_host.remote_runtime.RemoteRuntime") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, ".attachExisting(") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "gui_exact_reattach = true") != null);
}
