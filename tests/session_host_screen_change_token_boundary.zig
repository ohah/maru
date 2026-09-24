//! P4 E3a product boundary.
//! Screen work may be skipped only by a runtime-owned change token, while the performance proof
//! must keep using the independent ReleaseFast host with actual PTYs at 1/10/100 scale.

const std = @import("std");

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |index| {
        total += 1;
        rest = rest[index + needle.len ..];
    }
    return total;
}

test "P4 E3a product token and actual scale evidence stay on reviewed owners" {
    const allocator = std.testing.allocator;
    const manager = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/macos/session_host/runtime_manager.zig",
        allocator,
        .limited(512 * 1024),
    );
    defer allocator.free(manager);
    const server = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/macos/session_host/server.zig",
        allocator,
        .limited(512 * 1024),
    );
    defer allocator.free(server);
    const e2e = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "tests/session_host_slow_observer_e2e.zig",
        allocator,
        .limited(256 * 1024),
    );
    defer allocator.free(e2e);
    const validator = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "tools/perf/session_host_slow_observer_validator.zig",
        allocator,
        .limited(256 * 1024),
    );
    defer allocator.free(validator);

    try std.testing.expectEqual(@as(usize, 1), count(manager, ".screen_change_token = screenChangeTokenOp"));
    try std.testing.expectEqual(@as(usize, 1), count(manager, "if (drained.output_events != 0)"));
    try std.testing.expectEqual(@as(usize, 1), count(server, "const initial_screen_change_token"));
    try std.testing.expectEqual(@as(usize, 1), count(server, "const screen_incarnation_changed"));
    try std.testing.expectEqual(@as(usize, 1), count(server, "sub.resync_pending or screen_incarnation_changed"));

    const token_read = std.mem.indexOf(u8, server, "// Read once before projection.") orelse
        return error.MissingTokenReadFence;
    const delta_call = std.mem.indexOfPos(u8, server, token_read, "const update = ops.delta") orelse
        return error.MissingDeltaCall;
    try std.testing.expect(token_read < delta_call);

    try std.testing.expectEqual(@as(usize, 1), count(e2e, "var scale_runtime_ids: [100][32]u8"));
    try std.testing.expect(count(e2e, "\"runtime.spawn\"") >= 2);
    try std.testing.expectEqual(@as(usize, 1), count(e2e, "reached_count == 10 or reached_count == 100"));
    try std.testing.expectEqual(@as(usize, 1), count(validator, "const expected_runtime_counts = [_]u32{ 1, 10, 100 }"));
    try std.testing.expectEqual(@as(usize, 1), count(validator, "sample.cpu_total_delta_ns > screen_idle_cpu_total_cap_ns"));
}
