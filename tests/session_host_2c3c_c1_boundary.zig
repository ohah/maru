const std = @import("std");

const max_source_bytes = 8 * 1024 * 1024;

test "CR3a-2c3c C1 control facade stays typed canonical and product inert" {
    const allocator = std.testing.allocator;
    const contract = try readSource(allocator, "src/platform/macos/session_host/generation_attachment_contract.zig");
    defer allocator.free(contract);
    const transport = try readSource(allocator, "src/platform/macos/session_host/generation_transport.zig");
    defer allocator.free(transport);
    const slot = try readSource(allocator, "src/platform/macos/session_host/client_slot.zig");
    defer allocator.free(slot);
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);

    const control_contract = between(contract, "pub const RuntimeControlTag", "const RuntimeRequestPayload") orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), count(control_contract, "pub const RuntimeControl = extern struct"));
    try std.testing.expectEqual(@as(usize, 1), count(control_contract, "pub const ValidatedRuntimeControl = union(RuntimeControlTag)"));
    const validated = between(contract, "pub const ValidatedRuntimeControl", "const RuntimeRequestPayload") orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), count(validated, "scroll_to_bottom,"));
    try std.testing.expectEqual(@as(usize, 1), count(validated, "core_command: CoreCommandRequest,"));
    inline for (.{ "method:", "stream_id", "Allocator", "[]u8", "*anyopaque" }) |forbidden|
        try std.testing.expectEqual(@as(usize, 0), count(control_contract, forbidden));
    try std.testing.expectEqual(@as(usize, 1), count(contract, "const RawCoreCommand = extern struct"));
    try std.testing.expectEqual(@as(usize, 1), count(contract, "fn encodeRawCoreCommandInto("));
    try std.testing.expectEqual(@as(usize, 1), count(contract, "fn encodeRawCoreCommand("));
    try std.testing.expectEqual(@as(usize, 1), count(contract, "fn decodeRawCoreCommand("));
    try std.testing.expectEqual(@as(usize, 3), count(contract, "encodeRawCoreCommandInto("));
    try std.testing.expectEqual(@as(usize, 3), count(contract, "decodeRawCoreCommand("));

    try std.testing.expectEqual(@as(usize, 1), count(transport, "client_slot_mod.sendGenerationControl(self.controlOperation(control))"));
    try std.testing.expectEqual(@as(usize, 1), count(transport, "client_slot_mod.sendGenerationControlNonBlocking(self.controlOperation(control))"));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn sendGenerationControl("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn sendGenerationControlNonBlocking("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "node.client.sendScrollToBottom("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "node.client.sendScrollToBottomNonBlocking("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "node.client.sendCoreCommand("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "node.client.sendCoreCommandNonBlocking("));
    const transport_facade = between(transport, "pub const GenerationTransport = struct", "fn mapPrepareError(") orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 12), count(transport_facade, "    pub fn "));
    try std.testing.expectEqual(@as(usize, 1), count(transport_facade, "    pub fn sendControl("));
    try std.testing.expectEqual(@as(usize, 1), count(transport_facade, "    pub fn sendControlNonBlocking("));

    // C1 opens substrate only. Product callsites move in C2/C3 and recovery resync remains separate.
    try std.testing.expectEqual(@as(usize, 0), count(runtime, ".sendControl("));
    try std.testing.expectEqual(@as(usize, 0), count(runtime, ".sendControlNonBlocking("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "self.client.sendScrollToBottomNonBlocking("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "self.client.sendCoreCommandNonBlocking("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "self.client.sendScrollToBottom("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "self.client.sendCoreCommand("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "self.client.sendResyncNonBlocking("));
}

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max_source_bytes));
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var result: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |index| {
        result += 1;
        rest = rest[index + needle.len ..];
    }
    return result;
}

fn between(source: []const u8, start: []const u8, end: []const u8) ?[]const u8 {
    const start_index = std.mem.indexOf(u8, source, start) orelse return null;
    const end_index = std.mem.indexOfPos(u8, source, start_index + start.len, end) orelse return null;
    return source[start_index..end_index];
}
