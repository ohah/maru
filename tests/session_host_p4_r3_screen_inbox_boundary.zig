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

test "P4 R3 screen inbox has one aggregate owner and no parallel Client fields" {
    const allocator = std.testing.allocator;
    const source = try std.Io.Dir.cwd().readFileAllocOptions(
        std.testing.io,
        "src/platform/macos/session_host/client.zig",
        allocator,
        .limited(32 * 1024 * 1024),
        .of(u8),
        0,
    );
    defer allocator.free(source);

    const client_start = std.mem.indexOf(u8, source, "pub const Client = struct {") orelse
        return error.MissingClient;
    const connect_start = std.mem.indexOfPos(u8, source, client_start, "    pub fn connect(") orelse
        return error.MissingClientMethods;
    const fields = source[client_start..connect_start];

    try std.testing.expectEqual(@as(usize, 1), count(source, "const ScreenInbox = struct {"));
    try std.testing.expectEqual(@as(usize, 1), count(fields, "screen_inbox: ScreenInbox = .{},"));
    try std.testing.expectEqual(
        @as(usize, 1),
        count(source, "const screen_inbox_field_allowlist = [_][]const u8{"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(source, "std.meta.fields(ScreenInbox)"),
    );
    for ([_][]const u8{
        "fn byteCount(self: *const ScreenInbox)",
        "fn itemCount(self: *const ScreenInbox)",
        "fn discardStream(self: *ScreenInbox",
        "fn invalidateStream(self: *ScreenInbox",
        "fn acceptRecoverySnapshot(self: *ScreenInbox",
    }) |owner_method| try std.testing.expectEqual(@as(usize, 1), count(source, owner_method));
    try std.testing.expectEqual(
        @as(usize, 1),
        count(source, "return self.screen_inbox.byteCount();"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(source, "return self.screen_inbox.itemCount();"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(source, "self.screen_inbox.discardStream(self.allocator, stream_id);"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(source, "self.screen_inbox.invalidateStream(self.allocator, stream_id) catch"),
    );
    try std.testing.expectEqual(
        @as(usize, 3),
        count(source, "self.screen_inbox.acceptRecoverySnapshot("),
    );
    for ([_][]const u8{
        "pending_stream:",
        "pending_stream_bytes:",
        "pending_batches:",
        "pending_batch_bytes:",
        "partial_batch:",
        "screen_recovery:",
        "generation_batch_accounting:",
    }) |parallel_field| try std.testing.expectEqual(
        @as(usize, 0),
        count(fields, parallel_field),
    );
}
