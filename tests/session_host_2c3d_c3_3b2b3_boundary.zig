//! C3-3b2b3 source boundary: immutable preparation has one directed owner graph.

const std = @import("std");

test "C3-3b2b3 immutable pending preparation boundary" {
    const allocator = std.testing.allocator;
    const control_types = try readSource(allocator, "src/platform/macos/session_host/runtime_control_types.zig");
    defer allocator.free(control_types);
    const pending_control = try readSource(allocator, "src/platform/macos/session_host/runtime_pending_control.zig");
    defer allocator.free(pending_control);
    const prepared_types = try readSource(allocator, "src/platform/macos/session_host/runtime_event_prepared_types.zig");
    defer allocator.free(prepared_types);
    const lifetime = try readSource(allocator, "src/platform/macos/session_host/runtime_lifetime_owner.zig");
    defer allocator.free(lifetime);
    const owner = try readSource(allocator, "src/platform/macos/session_host/pending_event_owner.zig");
    defer allocator.free(owner);
    const preparation = try readSource(allocator, "src/platform/macos/session_host/pending_event_preparation.zig");
    defer allocator.free(preparation);
    const adapter = try readSource(allocator, "src/platform/macos/session_host/remote_runtime_pending_event.zig");
    defer allocator.free(adapter);
    const attachment = try readSource(allocator, "src/platform/macos/session_host/generation_attachment.zig");
    defer allocator.free(attachment);
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);

    try std.testing.expectEqual(@as(usize, 1), count(pending_control, "@import(\"runtime_control_types.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(owner, "@import(\"runtime_event_prepared_types.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(preparation, "@import(\"pending_event_owner.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(adapter, "@import(\"pending_event_preparation.zig\")"));
    try std.testing.expectEqual(@as(usize, 0), count(preparation, "@import(\"remote_runtime_pending_event.zig\")"));
    try std.testing.expectEqual(@as(usize, 0), count(adapter, "@import(\"remote_runtime.zig\")"));
    try std.testing.expectEqual(@as(usize, 0), count(control_types, "generation_attachment_contract.zig"));
    try std.testing.expectEqual(@as(usize, 0), count(pending_control, "generation_attachment_contract.zig"));
    try std.testing.expectEqual(@as(usize, 0), count(attachment, "PreparedEvent"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "pending_event_owner: pending_event_owner_mod.PendingEventOwner"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "runtime_lifetime: runtime_lifetime_owner_mod.RuntimeLifetimeOwner"));
    try std.testing.expectEqual(@as(usize, 1), count(adapter, "pub fn prepareTakenEvent("));
    try std.testing.expectEqual(@as(usize, 0), countProductCalls(runtime, "prepareTakenEvent("));
    try std.testing.expectEqual(@as(usize, 1), count(build, "test-session-host-2c3d-c3-3b2b3"));
    const gate_start = std.mem.indexOf(u8, build, "const event_c3_3b2b3_control_types_module") orelse return error.MissingGateStart;
    const gate_end = std.mem.indexOfPos(build, gate_start, "const control_c1_runtime_tests") orelse return error.MissingGateEnd;
    const gate = build[gate_start..gate_end];
    try std.testing.expectEqual(@as(usize, 1), count(gate, "--maru-expect-tests={d}"));
    try std.testing.expectEqual(@as(usize, 4), count(gate, ", 1);"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "--maru-expect-tests=1"));
    try std.testing.expectEqual(@as(usize, 2), count(gate, ", 7);"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, ", 10);"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, ", 5);"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, ", 2);"));
}

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(
        std.testing.io,
        path,
        allocator,
        .limited(32 * 1024 * 1024),
        .of(u8),
        0,
    );
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var result: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, needle)) |index| {
        result += 1;
        offset = index + needle.len;
    }
    return result;
}

fn countProductCalls(source: []const u8, needle: []const u8) usize {
    const test_start = std.mem.indexOf(u8, source, "test \"") orelse source.len;
    return count(source[0..test_start], needle);
}
