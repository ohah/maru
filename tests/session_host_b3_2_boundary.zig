const std = @import("std");
const max_source_bytes = 8 * 1024 * 1024;

test "B3-2 private destination admission keeps RPC test-only and public execute unchanged" {
    const registry = try readSource("src/platform/macos/session_host/attachment_cleanup_registry.zig");
    defer std.testing.allocator.free(registry);
    const client_slot = try readSource("src/platform/macos/session_host/client_slot.zig");
    defer std.testing.allocator.free(client_slot);
    const transport = try readSource("src/platform/macos/session_host/generation_transport.zig");
    defer std.testing.allocator.free(transport);
    const registry_product = registry[0 .. std.mem.indexOf(
        u8,
        registry,
        "test \"B3-2 private destination admission",
    ) orelse return error.TestExpectedEqual];

    try std.testing.expectEqual(@as(usize, 1), count(registry, "const AdmissionContext = enum(u8)"));
    try std.testing.expectEqual(@as(usize, 1), count(registry, "pub fn preparedAttachAdmission("));
    try std.testing.expectEqual(@as(usize, 1), count(client_slot, ".preparedAttachAdmission("));
    try std.testing.expectEqual(@as(usize, 2), count(registry_product, "classifyRequestAdmission("));
    // The enum declaration and classifier switch are the only product-prefix occurrences.
    // Any third occurrence would create an RPC destination caller before B3-3 owns it.
    try std.testing.expectEqual(@as(usize, 2), count(registry_product, ".execute_rpc"));
    try std.testing.expectEqual(@as(usize, 0), count(client_slot, ".execute_rpc"));
    try std.testing.expectEqual(@as(usize, 0), count(transport, ".execute_rpc"));
    try std.testing.expectEqual(@as(usize, 0), count(client_slot, "rpc_response_authority.reserveExecuting("));
    try std.testing.expectEqual(@as(usize, 0), count(transport, "rpc_response_authority.reserveExecuting("));
    try std.testing.expectEqual(@as(usize, 0), count(client_slot, "pub const ResponseDestination"));
    try std.testing.expectEqual(@as(usize, 0), count(transport, "pub const ResponseDestination"));
    try std.testing.expectEqual(@as(usize, 1), count(
        transport,
        "pub fn executePreparedRequest(\n        self: *GenerationTransport,\n        receipt: contract.PreparedCallReceipt,\n        response_out: *executed_response_mod.ExecutedResponse,",
    ));
    const execute_start = std.mem.indexOf(
        u8,
        transport,
        "pub fn executePreparedRequest(\n        self: *GenerationTransport,",
    ) orelse return error.TestExpectedEqual;
    const abort_start = std.mem.indexOf(
        u8,
        transport,
        "pub fn abortPreparedRequest(\n        self: *GenerationTransport,",
    ) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), count(
        transport[execute_start..abort_start],
        ".bound_stream_id = self.bound_stream_id,",
    ));
    const request_operation_start = std.mem.indexOf(
        u8,
        transport,
        "fn requestOperation(\n        self: *GenerationTransport,",
    ) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 0), count(
        transport[request_operation_start..@min(transport.len, request_operation_start + 1200)],
        ".bound_stream_id = self.bound_stream_id,",
    ));
}

fn readSource(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        std.testing.allocator,
        .limited(max_source_bytes),
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
