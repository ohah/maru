//! Keeps the signed tombstone runner tied to observed product facts rather than caller booleans.

const std = @import("std");

test "runner requires normal Quit zero recovery activity immutable candidate and exclusive leaf" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "tools/session-host/run-signed-tombstone-evidence.sh",
        std.testing.allocator,
        .limited(64 * 1024),
    );
    defer std.testing.allocator.free(source);
    for ([_][]const u8{
        "wait \"$cleanup_pid\"",
        "^final_frame_ended=true$",
        "^output_events=0$",
        "^terminal_input_events=0$",
        "^session_host_recovery_smoke_discovered_candidates=0$",
        "^session_host_recovery_smoke_ready_adapters=0$",
        "^session_host_recovery_smoke_inventory_runtimes=0$",
        "^session_host_recovery_smoke_target_activation_dispatched=false$",
        "test \"$dmg_sha\" = \"$dmg_sha_before\"",
        "test \"$exe_sha\" = \"$exe_sha_before\"",
        "set -C",
    }) |needle| try std.testing.expect(std.mem.indexOf(u8, source, needle) != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "kill -KILL"));
    try std.testing.expect(std.mem.indexOf(u8, source, "kill -TERM") == null);
}
