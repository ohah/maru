const std = @import("std");

const max_source_bytes = 8 * 1024 * 1024;

test "CR3a-2c3c control facade stays typed canonical through C3 wiring" {
    const allocator = std.testing.allocator;
    const contract = try readSource(allocator, "src/platform/macos/session_host/generation_attachment_contract.zig");
    defer allocator.free(contract);
    const transport = try readSource(allocator, "src/platform/macos/session_host/generation_transport.zig");
    defer allocator.free(transport);
    const attachment = try readSource(allocator, "src/platform/macos/session_host/generation_attachment.zig");
    defer allocator.free(attachment);
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
    // C3-3a3 keeps the same typed control facade but executes below the already-held
    // registered-operation lease instead of re-entering the public Client guard.
    try std.testing.expectEqual(@as(usize, 1), count(slot, "node.client.sendScrollToBottomUnderRegisteredOperationExecutionLease("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "node.client.sendScrollToBottomNonBlockingUnderRegisteredOperationExecutionLease("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "node.client.sendCoreCommandUnderRegisteredOperationExecutionLease("));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "node.client.sendCoreCommandNonBlockingUnderRegisteredOperationExecutionLease("));
    const transport_facade = between(transport, "pub const GenerationTransport = struct", "fn mapPrepareError(") orelse
        return error.TestExpectedEqual;
    // 2c3d C3-2 adds the bounded ended-purge facade without widening control.
    try std.testing.expectEqual(@as(usize, 15), count(transport_facade, "    pub fn "));
    try std.testing.expectEqual(@as(usize, 1), count(transport_facade, "    pub fn sendControl("));
    try std.testing.expectEqual(@as(usize, 1), count(transport_facade, "    pub fn sendControlNonBlocking("));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "    pub fn sendControlNonBlocking("));
    const attachment_control = between(
        attachment,
        "    pub fn sendControlNonBlocking(",
        "    pub fn sendControl(",
    ) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(
        @as(usize, 1),
        count(attachment_control, "control: contract.RuntimeControl,"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(attachment_control, ") generation_transport_mod.ControlError!bool"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(attachment_control, "self.transport.sendControlNonBlocking(control)"),
    );
    inline for (.{ "client", "stream_id", "params", "json", "allocator" }) |forbidden|
        try std.testing.expectEqual(@as(usize, 0), count(attachment_control, forbidden));

    try std.testing.expectEqual(@as(usize, 1), count(attachment, "    pub fn sendControl("));
    const attachment_blocking_control = between(
        attachment,
        "    pub fn sendControl(",
        "    pub fn callOrdered(",
    ) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(
        @as(usize, 1),
        count(attachment_blocking_control, "control: contract.RuntimeControl,"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(attachment_blocking_control, ") generation_transport_mod.ControlError!void"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(attachment_blocking_control, "self.transport.sendControl(control)"),
    );
    inline for (.{ "client", "stream_id", "params", "json", "allocator" }) |forbidden|
        try std.testing.expectEqual(@as(usize, 0), count(attachment_blocking_control, forbidden));

    // C2/C3 open exactly one generation adapter for each send mode. Recovery resync and
    // legacy direct Client callsites stay explicit.
    try std.testing.expectEqual(@as(usize, 1), count(runtime, ".sendControl("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, ".sendControlNonBlocking("));
    const admission = between(runtime, "    fn admitControl(", "    fn normalizeGenerationControlError(") orelse
        return error.TestExpectedEqual;
    const generation_arm = between(admission, "if (self.attachment == .generation)", "        return switch (control.op)") orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), count(generation_arm, ".sendControlNonBlocking("));
    try std.testing.expectEqual(@as(usize, 0), count(generation_arm, "self.client.send"));
    const blocking_admission = between(runtime, "    fn flushControlBlocking(", "    fn discardQueuedMutations(") orelse
        return error.TestExpectedEqual;
    const blocking_generation_arm = between(
        blocking_admission,
        "if (self.attachment == .generation)",
        "        switch (control.op)",
    ) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), count(blocking_generation_arm, ".sendControl("));
    try std.testing.expectEqual(@as(usize, 0), count(blocking_generation_arm, "self.client.send"));
    try std.testing.expectEqual(@as(usize, 0), count(blocking_generation_arm, "encodeParams"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "self.client.sendScrollToBottomNonBlocking("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "self.client.sendCoreCommandNonBlocking("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "self.client.sendScrollToBottom("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "self.client.sendCoreCommand("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "client.sendResyncNonBlocking("));
    const response_core = between(
        runtime,
        "    pub fn sendCoreCommandBlocking(",
        "    pub fn sendMouseReport(",
    ) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), count(response_core, "self.callOrdered(\"runtime.core_command\""));
    try std.testing.expectEqual(@as(usize, 1), count(response_core, "core_command_wire.encodeParams("));
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
