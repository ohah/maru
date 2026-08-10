const std = @import("std");

test "CR3a-2c3d C3-3b2a process seal migration boundary" {
    const allocator = std.testing.allocator;
    const service = try readSource(allocator, "src/platform/macos/session_host/process_seal_service.zig");
    defer allocator.free(service);
    const identity = try readSource(allocator, "src/platform/macos/session_host/operation_thread_identity.zig");
    defer allocator.free(identity);
    const slot = try readSource(allocator, "src/platform/macos/session_host/client_slot.zig");
    defer allocator.free(slot);
    const process_identity = try readSource(allocator, "src/platform/macos/session_host/process_identity.zig");
    defer allocator.free(process_identity);
    const client = try readSource(allocator, "src/platform/macos/session_host/client.zig");
    defer allocator.free(client);
    const transport = try readSource(allocator, "src/platform/macos/session_host/generation_transport.zig");
    defer allocator.free(transport);
    const snapshot_owner = try readSource(allocator, "src/platform/macos/session_host/initial_snapshot_owner.zig");
    defer allocator.free(snapshot_owner);
    const batch_registry = try readSource(allocator, "src/platform/macos/session_host/generation_batch_registry.zig");
    defer allocator.free(batch_registry);
    const quarantine = try readSource(allocator, "src/platform/macos/session_host/ended_purge_quarantine.zig");
    defer allocator.free(quarantine);
    const fresh_exec_helper = try readSource(allocator, "tests/session_host_process_seal_fresh_exec_helper.zig");
    defer allocator.free(fresh_exec_helper);
    const fresh_exec_oracle = try readSource(allocator, "tests/session_host_process_seal_fresh_exec_oracle.zig");
    defer allocator.free(fresh_exec_oracle);

    try std.testing.expectEqual(@as(usize, 0), count(identity, "capability_key_secret"));
    try std.testing.expectEqual(@as(usize, 0), count(identity, "capability_key_secret_initialized"));
    try std.testing.expectEqual(@as(usize, 0), try countSessionHostSources(allocator, "maru.capability.registry-key.v1"));
    try std.testing.expectEqual(@as(usize, 0), try countSessionHostSources(allocator, "pid) ^"));
    try std.testing.expectEqual(@as(usize, 1), count(identity, "return process_seal_service.currentProcessId();"));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "return process_seal_service.currentProcessId();"));
    try std.testing.expectEqual(@as(usize, 1), count(service, "return process_identity.currentProcessId();"));
    try std.testing.expectEqual(@as(usize, 1), count(process_identity, ".macos, .linux => @intCast(std.c.getpid()),"));
    try std.testing.expectEqual(@as(usize, 5), try countSessionHostSources(allocator, "@import(\"process_identity.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(service, "@import(\"process_identity.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(transport, "@import(\"process_identity.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(snapshot_owner, "@import(\"process_identity.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(batch_registry, "@import(\"process_identity.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(quarantine, "@import(\"process_identity.zig\")"));
    const fence_identity = client[std.mem.indexOf(u8, client, "fn identityMatches(") orelse
        return error.TestUnexpectedResult ..];
    const fence_identity_end = std.mem.indexOf(u8, fence_identity, "\n    }\n};") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        @as(usize, 1),
        count(fence_identity[0..fence_identity_end], "operation_thread_identity.currentProcessId()"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(client, "const actual_pid = operation_thread_identity.currentProcessId();"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(client, "const actual_pid: u64 = operation_thread_identity.currentProcessId();"),
    );
    inline for (.{ client, transport, snapshot_owner, batch_registry, quarantine }) |authority_source| {
        try std.testing.expectEqual(@as(usize, 0), count(authority_source, "if (builtin.os.tag == .macos) @intCast(c.getpid()) else 1"));
        try std.testing.expectEqual(@as(usize, 0), count(authority_source, "if (builtin.os.tag == .macos) @intCast(std.c.getpid()) else 1"));
    }
    try std.testing.expectEqual(@as(usize, 0), count(quarantine, "std.c.getpid()"));
    try std.testing.expectEqual(@as(usize, 2), try countSessionHostSources(allocator, "@import(\"process_seal_service.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(identity, "@import(\"process_seal_service.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "@import(\"process_seal_service.zig\")"));
    try std.testing.expectEqual(@as(usize, 0), count(service, "pub fn raw"));
    try std.testing.expectEqual(@as(usize, 0), count(service, "RemoteRuntime"));
    try std.testing.expectEqual(@as(usize, 0), count(service, "PendingEventOwner"));
    try std.testing.expectEqual(@as(usize, 0), count(service, "EventCorrelation"));
    try std.testing.expectEqual(@as(usize, 0), count(service, "std.mem.Allocator"));
    try std.testing.expectEqual(@as(usize, 0), count(service, "@panic"));
    try std.testing.expectEqual(@as(usize, 0), count(service, "MARU_PROCESS_SEAL_FRESH_EXEC"));
    try std.testing.expectEqual(@as(usize, 0), count(service, "std.c.getenv"));
    inline for (.{
        "pub fn generateProcessNonce()",
        "pub fn prepare(pid:",
        "pub fn commitReady(receipt:",
        "pub fn validateReady(pid:",
        "pub fn capabilityRegistryKey(",
    }) |signature| try std.testing.expectEqual(@as(usize, 1), count(service, signature));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "process_seal_service.generateProcessNonce()"));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "process_seal_service.prepare(pid, nonce)"));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "process_seal_service.validateReady(pid,"));
    try std.testing.expect(count(slot, "process_seal_service.commitReady(prepared_seal)") == 1);
    try std.testing.expect(count(identity, "process_seal_service.capabilityRegistryKey(") == 1);
    inline for (.{
        "process_seal_service.generateProcessNonce()",
        "process_seal_service.prepare(pid, nonce)",
        "process_seal_service.commitReady(receipt)",
        "process_seal_service.validateReady(pid, nonce)",
        "process_seal_service.capabilityRegistryKey(pid, nonce, input)",
    }) |marker| try std.testing.expect(count(fresh_exec_helper, marker) >= 1);
    try std.testing.expectEqual(@as(usize, 2), count(fresh_exec_oracle, "@embedFile("));
    try std.testing.expectEqual(@as(usize, 1), count(fresh_exec_oracle, "first != second"));
}

fn countSessionHostSources(allocator: std.mem.Allocator, needle: []const u8) !usize {
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

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(
        std.testing.io,
        path,
        allocator,
        .limited(8 * 1024 * 1024),
        .of(u8),
        0,
    );
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, needle)) |found| {
        total += 1;
        offset = found + needle.len;
    }
    return total;
}
