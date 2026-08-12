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
    const storage = try readSource(allocator, "src/platform/macos/session_host/incident_artifact_store.zig");
    defer allocator.free(storage);

    try std.testing.expectEqual(@as(usize, 1), count(incident, "const std = @import(\"std\");"));
    try std.testing.expectEqual(@as(usize, 1), count(incident, "pub const payload_size: usize = 208;"));
    try std.testing.expectEqual(@as(usize, 1), count(incident, "pub const envelope_size: usize = 256;"));
    try std.testing.expectEqual(@as(usize, 1), count(incident, "pub const incident_slot_count: usize = 120;"));
    try std.testing.expectEqual(@as(usize, 1), count(incident, "pub const aggregate_slot_count: usize = 8;"));
    try std.testing.expectEqual(@as(usize, 1), count(incident, "fn recordRepeatForTest("));
    try std.testing.expectEqual(@as(usize, 0), count(incident, "pub fn recordRepeat("));
    try std.testing.expectEqual(@as(usize, 20), count(incident, "test \"CR0b core "));
    try std.testing.expectEqual(@as(usize, 11), count(incident, "test \"CR0b writer"));
    try std.testing.expectEqual(@as(usize, 6), count(storage, "test \"CR0b 저장소"));
    const storage_product = storage[0 .. std.mem.indexOf(u8, storage, "\ntest \"") orelse storage.len];
    try std.testing.expectEqual(@as(usize, 1), count(storage, "const incident = @import(\"connection_incident\");"));
    try std.testing.expectEqual(@as(usize, 0), count(storage, "client.zig"));
    try std.testing.expectEqual(@as(usize, 0), count(storage, "host_adapter.zig"));
    try std.testing.expectEqual(@as(usize, 1), count(incident, "pub fn takePendingForWriter("));
    try std.testing.expectEqual(@as(usize, 1), count(incident, "pub fn completeWriterHandoff("));
    try std.testing.expectEqual(@as(usize, 0), count(client, "takePendingForWriter"));
    try std.testing.expectEqual(@as(usize, 0), count(adapter, "takePendingForWriter"));
    try std.testing.expectEqual(@as(usize, 0), count(backend, "takePendingForWriter"));
    try std.testing.expectEqual(@as(usize, 0), count(client, "completeWriterHandoff"));
    try std.testing.expectEqual(@as(usize, 0), count(adapter, "completeWriterHandoff"));
    try std.testing.expectEqual(@as(usize, 0), count(backend, "completeWriterHandoff"));
    try std.testing.expectEqual(@as(usize, 0), count(storage_product, "takePendingForWriter("));
    try std.testing.expectEqual(@as(usize, 0), count(storage_product, "completeWriterHandoff("));
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExceptTwo(
            allocator,
            "takePendingForWriter(",
            "observability/connection_incident.zig",
            "platform/macos/session_host/incident_artifact_store.zig",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExceptTwo(
            allocator,
            "completeWriterHandoff(",
            "observability/connection_incident.zig",
            "platform/macos/session_host/incident_artifact_store.zig",
        ),
    );
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

fn countProductSourcesExcept(allocator: std.mem.Allocator, needle: []const u8, excluded_path: []const u8) !usize {
    return countProductSourcesExceptTwo(allocator, needle, excluded_path, "");
}

fn countProductSourcesExceptTwo(
    allocator: std.mem.Allocator,
    needle: []const u8,
    excluded_path: []const u8,
    second_excluded_path: []const u8,
) !usize {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var total: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (std.mem.eql(u8, entry.path, excluded_path) or
            (second_excluded_path.len != 0 and std.mem.eql(u8, entry.path, second_excluded_path))) continue;
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        const source = try readSource(allocator, path);
        defer allocator.free(source);
        total += count(source, needle);
    }
    return total;
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
