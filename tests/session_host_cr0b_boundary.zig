const std = @import("std");

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |at| {
        total += 1;
        rest = rest[at + needle.len ..];
    }
    return total;
}

test "CR0b 경계는 중립 schema와 test-private repeat만 연다" {
    const allocator = std.testing.allocator;
    const incident = try readSource(allocator, "src/observability/connection_incident.zig");
    defer allocator.free(incident);
    const client = try readSource(allocator, "src/platform/macos/session_host/client.zig");
    defer allocator.free(client);
    const adapter = try readSource(allocator, "src/platform/macos/session_host/host_adapter.zig");
    defer allocator.free(adapter);
    const backend = try readSource(allocator, "src/platform/macos/session_host/remote_term_backend.zig");
    defer allocator.free(backend);
    const poison = try readSource(allocator, "src/platform/macos/session_host/client_poison.zig");
    defer allocator.free(poison);

    try std.testing.expectEqual(@as(usize, 1), count(incident, "const std = @import(\"std\");"));
    try std.testing.expectEqual(@as(usize, 1), count(incident, "pub const payload_size: usize = 208;"));
    try std.testing.expectEqual(@as(usize, 1), count(incident, "pub const envelope_size: usize = 256;"));
    try std.testing.expectEqual(@as(usize, 1), count(incident, "pub const incident_slot_count: usize = 120;"));
    try std.testing.expectEqual(@as(usize, 1), count(incident, "pub const aggregate_slot_count: usize = 8;"));
    try std.testing.expectEqual(@as(usize, 1), count(incident, "fn recordRepeatForTest("));
    try std.testing.expectEqual(@as(usize, 0), count(incident, "pub fn recordRepeat("));
    try std.testing.expectEqual(@as(usize, 20), count(incident, "test \"CR0b "));
    try std.testing.expectEqual(@as(usize, 0), count(client, "connection_incident.zig"));
    try std.testing.expectEqual(@as(usize, 0), count(adapter, "connection_incident.zig"));
    try std.testing.expectEqual(@as(usize, 0), count(backend, "connection_incident.zig"));

    const reason_names = [_][]const u8{
        "connection_eof",          "read_timeout",              "transport_read_failure",        "planned_upgrade_reconnect",
        "capability_incompatible", "outbound_partial_write",    "outbound_write_ambiguous",      "event_queue_overflow",
        "local_queue_exhausted",   "local_resource_exhausted",  "frame_malformed",               "response_correlation_lost",
        "peer_contract_violation", "local_invariant_violation", "external_transfer_quarantined", "attachment_cleanup_failed",
    };
    const incident_reason_block = try declarationBlock(incident, "pub const ConnectionReason = enum(u8) {");
    const poison_reason_block = try declarationBlock(poison, "pub const ConnectionReason = enum {");
    inline for (reason_names, 0..) |name, ordinal| {
        var explicit: [96]u8 = undefined;
        const expected = try std.fmt.bufPrint(&explicit, "{s} = {d},", .{ name, ordinal });
        try std.testing.expectEqual(@as(usize, 1), count(incident_reason_block, expected));
        var implicit: [80]u8 = undefined;
        const poison_tag = try std.fmt.bufPrint(&implicit, "{s},", .{name});
        try std.testing.expectEqual(@as(usize, 1), count(poison_reason_block, poison_tag));
    }
}

fn declarationBlock(source: []const u8, prefix: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, source, prefix) orelse return error.TestUnexpectedResult;
    const tail = source[start + prefix.len ..];
    const end = std.mem.indexOf(u8, tail, "};") orelse return error.TestUnexpectedResult;
    return tail[0..end];
}

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(
        std.testing.io,
        path,
        allocator,
        .limited(16 * 1024 * 1024),
        .of(u8),
        0,
    );
}
