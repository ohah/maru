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
    const decision_seal = try readSource(allocator, "src/platform/macos/session_host/runtime_prepared_decision_seal.zig");
    defer allocator.free(decision_seal);
    const cleanup_seal = try readSource(allocator, "src/platform/macos/session_host/event_cleanup_seal.zig");
    defer allocator.free(cleanup_seal);
    const lifetime = try readSource(allocator, "src/platform/macos/session_host/runtime_lifetime_owner.zig");
    defer allocator.free(lifetime);
    const owner = try readSource(allocator, "src/platform/macos/session_host/pending_event_owner.zig");
    defer allocator.free(owner);
    const preparation = try readSource(allocator, "src/platform/macos/session_host/pending_event_preparation.zig");
    defer allocator.free(preparation);
    const observation_digest = try readSource(allocator, "src/platform/macos/session_host/runtime_observation_digest.zig");
    defer allocator.free(observation_digest);
    const adapter = try readSource(allocator, "src/platform/macos/session_host/remote_runtime_pending_event.zig");
    defer allocator.free(adapter);
    const attachment = try readSource(allocator, "src/platform/macos/session_host/generation_attachment.zig");
    defer allocator.free(attachment);
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);
    const transport = try readSource(allocator, "src/platform/macos/session_host/generation_transport.zig");
    defer allocator.free(transport);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);

    try std.testing.expectEqual(@as(usize, 1), count(pending_control, "@import(\"runtime_control_types.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(owner, "@import(\"runtime_event_prepared_types.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(prepared_types, "@import(\"runtime_prepared_decision_seal.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(cleanup_seal, "@import(\"runtime_prepared_decision_seal.zig\")"));
    try std.testing.expectEqual(
        @as(usize, 2),
        try countProductSources(allocator, "@import(\"runtime_prepared_decision_seal.zig\")"),
    );
    try std.testing.expectEqual(@as(usize, 1), count(decision_seal, "pub fn canonical("));
    try std.testing.expectEqual(@as(usize, 0), count(decision_seal, "runtime_event_prepared_types.zig"));
    try std.testing.expectEqual(@as(usize, 0), count(decision_seal, "event_cleanup_seal.zig"));
    try std.testing.expectEqual(@as(usize, 0), count(decision_seal, "client_poison.zig"));
    try std.testing.expectEqual(@as(usize, 0), count(decision_seal, "@import(\"maru\")"));
    try std.testing.expectEqual(@as(usize, 1), count(preparation, "@import(\"pending_event_owner.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(owner, "@import(\"runtime_observation_digest.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(preparation, "@import(\"runtime_observation_digest.zig\")"));
    try std.testing.expectEqual(
        @as(usize, 2),
        try countProductSources(allocator, "@import(\"runtime_observation_digest.zig\")"),
    );
    try std.testing.expectEqual(@as(usize, 1), count(observation_digest, "pub fn digest("));
    try std.testing.expectEqual(@as(usize, 0), count(observation_digest, "pending_event_owner.zig"));
    try std.testing.expectEqual(@as(usize, 0), count(observation_digest, "pending_event_preparation.zig"));
    try std.testing.expectEqual(@as(usize, 0), count(observation_digest, "remote_runtime_pending_event.zig"));
    try std.testing.expectEqual(@as(usize, 0), count(observation_digest, "remote_runtime.zig"));
    try std.testing.expectEqual(@as(usize, 1), count(adapter, "@import(\"pending_event_preparation.zig\")"));
    try std.testing.expectEqual(@as(usize, 0), count(preparation, "@import(\"remote_runtime_pending_event.zig\")"));
    try std.testing.expectEqual(@as(usize, 0), count(adapter, "@import(\"remote_runtime.zig\")"));
    try std.testing.expectEqual(@as(usize, 0), count(control_types, "generation_attachment_contract.zig"));
    try std.testing.expectEqual(@as(usize, 0), count(pending_control, "generation_attachment_contract.zig"));
    try std.testing.expectEqual(@as(usize, 0), count(attachment, "PreparedRuntimeEvent"));
    const prepared_settlement_start = std.mem.indexOf(u8, attachment, "pub const PreparedSettlement = struct {") orelse
        return error.MissingPreparedSettlement;
    const prepared_settlement_end = std.mem.indexOfPos(u8, attachment, prepared_settlement_start, "pub fn preparePendingSettlement(") orelse
        return error.MissingPreparedSettlementEnd;
    const prepared_settlement = attachment[prepared_settlement_start..prepared_settlement_end];
    try std.testing.expectEqual(@as(usize, 0), count(prepared_settlement, "*"));
    try std.testing.expectEqual(@as(usize, 0), count(prepared_settlement, "PreparationEventView"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "pending_event_owner: pending_event_owner_mod.PendingEventOwner"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "runtime_lifetime: runtime_lifetime_owner_mod.RuntimeLifetimeOwner"));
    try std.testing.expectEqual(@as(usize, 2), countProductCalls(runtime, "try self.initializePendingEventOwner(generation_adapter);"));
    try std.testing.expectEqual(@as(usize, 1), count(transport, "pub fn preparationEventViewOwned("));
    try std.testing.expectEqual(@as(usize, 0), countProductCalls(runtime, "preparationEventViewOwned("));
    try std.testing.expectEqual(@as(usize, 1), count(adapter, "pub fn prepareTakenEvent("));
    // One dormant product-source orchestration body owns the adapter call. Its own caller remains
    // test-only until b4, so the normal product pump cannot bypass this single construction seam.
    try std.testing.expectEqual(@as(usize, 1), countProductCalls(runtime, "prepareTakenEvent("));
    try std.testing.expectEqual(@as(usize, 1), countProductCalls(runtime, "classifyAndPrepareEvent("));
    // The hostile DTO drift probe adds one test-only call while remaining outside the product
    // RemoteRuntime declaration counted above.
    try std.testing.expectEqual(@as(usize, 6), count(runtime, "classifyAndPrepareEvent("));
    const prepare_entry = function(runtime, "classifyAndPrepareEvent") orelse return error.MissingRuntimeEntry;
    try std.testing.expectEqual(@as(usize, 1), count(
        prepare_entry,
        ") pending_event_preparation_mod.PrepareError!void {",
    ));
    try std.testing.expectEqual(@as(usize, 0), count(prepare_entry, "anyerror"));
    try std.testing.expectEqual(@as(usize, 1), count(owner, "pub fn abortPrepare(self: *PendingEventOwner, attempt: u64) noreturn"));
    try std.testing.expectEqual(@as(usize, 0), count(owner, "fn beginSettlement("));
    try std.testing.expectEqual(@as(usize, 0), count(owner, "fn commitEffect("));
    try std.testing.expectEqual(@as(usize, 0), count(owner, "fn finishCommitted("));
    try expectRuntimeAdmissionInventory(runtime);
    try std.testing.expectEqual(@as(usize, 1), count(build, "test-session-host-2c3d-c3-3b2b3"));
    try std.testing.expectEqual(@as(usize, 1), count(build, "\"test-session-host-2c3d-c3-3b2b\""));
    const gate_start = std.mem.indexOf(u8, build, "const event_c3_3b2b3_control_types_module") orelse return error.MissingGateStart;
    const gate_end = std.mem.indexOfPos(u8, build, gate_start, "const control_c1_runtime_tests") orelse return error.MissingGateEnd;
    const gate = build[gate_start..gate_end];
    try std.testing.expectEqual(@as(usize, 2), count(gate, "--maru-expect-tests={d}"));
    // 상속 gate에는 b3의 pointer-free facade와 ClientSlot focused 4개가 추가된다.
    try std.testing.expectEqual(@as(usize, 11), count(gate, ", 1);"));
    try std.testing.expectEqual(@as(usize, 3), count(gate, "--maru-expect-tests=1"));
    try std.testing.expectEqual(@as(usize, 1), count(
        gate,
        "session_host_2c3d_c3_3b2b3_step.dependOn(\n            &run_event_c3_3b2b3_dto_drift_tests.step,\n        );",
    ));
    // b5 backend 소유 테스트 7개도 중앙 RED fixture를 거치지 않고 실제 모듈에서 실행한다.
    try std.testing.expectEqual(@as(usize, 4), count(gate, ", 7);"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, ", 10);"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, ", 5);"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, ", 3);"));
    try std.testing.expectEqual(@as(usize, 2), count(gate, ", 2);"));
    const unique_per_mode: usize = 7 + 1 + 7 + 10 + 5 + 3 + 1 + 1 + 1 + 2 + 1;
    const fresh_replay_per_mode: usize = 1;
    try std.testing.expectEqual(@as(usize, 39), unique_per_mode);
    try std.testing.expectEqual(@as(usize, 40), unique_per_mode + fresh_replay_per_mode);
}

fn expectRuntimeAdmissionInventory(runtime: []const u8) !void {
    const runtime_start = std.mem.indexOf(u8, runtime, "pub const RemoteRuntime = struct {") orelse
        return error.MissingRuntimeEntry;
    const test_start = std.mem.indexOfPos(u8, runtime, runtime_start, "\ntest \"") orelse runtime.len;
    const remote = runtime[runtime_start..test_start];
    const read_only = [_][]const u8{
        "runtimeIdHex", "attachedAsObserver", "usesGenerationAttachment",
    };
    for (read_only) |name| {
        const body = publicFunction(remote, name) orelse return error.MissingRuntimeEntry;
        try std.testing.expectEqual(@as(usize, 0), count(body, "admitRuntimeOperation("));
        try std.testing.expectEqual(@as(usize, 0), count(body, "admitDestructiveRuntimeOperation("));
    }

    const destructive = [_][]const u8{
        "surfacePtr", "deinit", "detachClientSide", "terminate",
    };
    for (destructive) |name| {
        const body = publicFunction(remote, name) orelse return error.MissingRuntimeEntry;
        try std.testing.expectEqual(@as(usize, 1), count(body, "self.admitDestructiveRuntimeOperation();"));
    }

    const fallible = [_][]const u8{
        "sendInput",          "sendInputNonBlocking",    "requestScrollToBottom", "queueCoreCommand",
        "resize",             "pumpDelta",               "requestResync",         "refreshObservation",
        "selectedText",       "linkAt",                  "clipboardWrite",        "find",
        "selectContentAware", "sendCoreCommandBlocking", "sendMouseReport",       "takeNotification",
    };
    for (fallible) |name| {
        const body = publicFunction(remote, name) orelse return error.MissingRuntimeEntry;
        try std.testing.expectEqual(@as(usize, 1), count(body, "try self.admitRuntimeOperation();"));
    }
    try std.testing.expectEqual(@as(usize, 23), read_only.len + destructive.len + fallible.len);
    try std.testing.expectEqual(@as(usize, 1), count(
        function(remote, "admitDestructiveRuntimeOperation") orelse return error.MissingRuntimeEntry,
        "process_seal_service.fatalIntegrity(.destructive_reentry)",
    ));
}

fn publicFunction(source: []const u8, name: []const u8) ?[]const u8 {
    var prefix_buffer: [160]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buffer, "    pub fn {s}(", .{name}) catch return null;
    return functionFromPrefix(source, prefix);
}

fn function(source: []const u8, name: []const u8) ?[]const u8 {
    var prefix_buffer: [160]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buffer, "    fn {s}(", .{name}) catch return null;
    return functionFromPrefix(source, prefix);
}

fn functionFromPrefix(source: []const u8, prefix: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, source, prefix) orelse return null;
    const public_end = std.mem.indexOfPos(u8, source, start + prefix.len, "\n    pub fn ") orelse source.len;
    const private_end = std.mem.indexOfPos(u8, source, start + prefix.len, "\n    fn ") orelse source.len;
    return source[start..@min(public_end, private_end)];
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

fn countProductSources(allocator: std.mem.Allocator, needle: []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(
        std.testing.io,
        "src/platform/macos/session_host",
        .{ .iterate = true },
    );
    defer dir.close(std.testing.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var total: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const path = try std.fmt.allocPrint(
            allocator,
            "src/platform/macos/session_host/{s}",
            .{entry.path},
        );
        defer allocator.free(path);
        const source = try readSource(allocator, path);
        defer allocator.free(source);
        total += count(source, needle);
    }
    return total;
}
