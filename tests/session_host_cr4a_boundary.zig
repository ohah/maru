const std = @import("std");
const posixWalk = @import("support/posix_walk.zig").posixWalk;

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |at| {
        total += 1;
        rest = rest[at + needle.len ..];
    }
    return total;
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

fn countProductSourcesExcept(
    allocator: std.mem.Allocator,
    needle: []const u8,
    excluded: []const []const u8,
) !usize {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    var total: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        var skip = false;
        for (excluded) |path| if (std.mem.eql(u8, entry.path, path)) {
            skip = true;
            break;
        };
        if (skip) continue;
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        const source = try readSource(allocator, path);
        defer allocator.free(source);
        total += count(source, needle);
    }
    return total;
}

test "CR4a 경계는 observer attach와 final candidate 준비만 연다" {
    const allocator = std.testing.allocator;
    const contract = try readSource(
        allocator,
        "src/platform/macos/session_host/generation_attachment_contract.zig",
    );
    defer allocator.free(contract);
    const attachment = try readSource(
        allocator,
        "src/platform/macos/session_host/generation_attachment.zig",
    );
    defer allocator.free(attachment);
    const remote_attachment = try readSource(
        allocator,
        "src/platform/macos/session_host/remote_attachment.zig",
    );
    defer allocator.free(remote_attachment);
    const client_slot = try readSource(
        allocator,
        "src/platform/macos/session_host/client_slot.zig",
    );
    defer allocator.free(client_slot);
    const cleanup_registry = try readSource(
        allocator,
        "src/platform/macos/session_host/attachment_cleanup_registry.zig",
    );
    defer allocator.free(cleanup_registry);
    const runtime = try readSource(
        allocator,
        "src/platform/macos/session_host/remote_runtime.zig",
    );
    defer allocator.free(runtime);
    const server = try readSource(
        allocator,
        "src/platform/macos/session_host/server.zig",
    );
    defer allocator.free(server);
    const snapshot = try readSource(
        allocator,
        "src/platform/macos/session_host/screen_snapshot.zig",
    );
    defer allocator.free(snapshot);
    const assembler = try readSource(
        allocator,
        "src/platform/macos/session_host/screen_assembler.zig",
    );
    defer allocator.free(assembler);
    const runtime_manager = try readSource(
        allocator,
        "src/platform/macos/session_host/runtime_manager.zig",
    );
    defer allocator.free(runtime_manager);
    const catchup = try readSource(
        allocator,
        "src/platform/macos/session_host/catchup_barrier_contract.zig",
    );
    defer allocator.free(catchup);
    const protocol = try readSource(
        allocator,
        "src/platform/macos/session_host/protocol.zig",
    );
    defer allocator.free(protocol);
    const connection_turn = try readSource(
        allocator,
        "src/platform/macos/session_host/connection_turn.zig",
    );
    defer allocator.free(connection_turn);
    const poll_owner = try readSource(
        allocator,
        "src/platform/macos/session_host/poll_owner.zig",
    );
    defer allocator.free(poll_owner);
    const daemon = try readSource(
        allocator,
        "src/platform/macos/session_host/daemon.zig",
    );
    defer allocator.free(daemon);
    const restore_activation = try readSource(
        allocator,
        "src/platform/macos/session_host/restore_activation.zig",
    );
    defer allocator.free(restore_activation);
    const catchup_wire = try readSource(
        allocator,
        "src/platform/macos/session_host/catchup_barrier_wire.zig",
    );
    defer allocator.free(catchup_wire);
    const runtime_product = runtime[0..std.mem.indexOf(u8, runtime, "const testing = std.testing;").?];
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);
    const build_cr4a_start = std.mem.indexOf(u8, build, "const session_host_cr4a_step =").?;
    const build_cr4a_end = std.mem.indexOfPos(u8, build, build_cr4a_start, "const b3_1_boundary_tests =").?;
    const build_cr4a = build[build_cr4a_start..build_cr4a_end];

    try std.testing.expectEqual(@as(usize, 4), count(contract, "attach_observer,"));
    try std.testing.expectEqual(@as(usize, 1), count(contract, "pub fn attachObserver() RuntimeRequest"));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "pub fn prepareObserverAttach("));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "contract.RuntimeRequest.attachObserver()"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime_product, ".prepareObserverAttach(args.adapter, args.runtime_id)"));
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExcept(allocator, "prepareObserverAttach(", &.{
            "platform/macos/session_host/generation_attachment.zig",
            "platform/macos/session_host/remote_runtime.zig",
        }),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExcept(allocator, "attachObserver()", &.{
            "platform/macos/session_host/generation_attachment_contract.zig",
            "platform/macos/session_host/generation_attachment.zig",
        }),
    );
    // Observer tag consumers stay closed to the wire contract, attachment preparation,
    // cleanup policy and the reconnect owner. No unrelated product source may admit it.
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExcept(allocator, ".attach_observer", &.{
            "platform/macos/session_host/generation_attachment_contract.zig",
            "platform/macos/session_host/generation_attachment.zig",
            "platform/macos/session_host/attachment_cleanup_registry.zig",
            "platform/macos/session_host/client_slot.zig",
            "platform/macos/session_host/remote_runtime.zig",
        }),
    );
    try std.testing.expectEqual(@as(usize, 9), count(contract, ".attach_observer"));
    try std.testing.expectEqual(@as(usize, 0), count(attachment, ".attach_observer"));
    try std.testing.expectEqual(@as(usize, 3), count(client_slot, ".attach_observer"));
    try std.testing.expectEqual(@as(usize, 3), count(cleanup_registry, ".attach_observer"));
    try std.testing.expectEqual(@as(usize, 2), count(runtime, ".attach_observer"));
    try std.testing.expectEqual(
        @as(usize, 0),
        count(runtime_product, "if (self.statePtr().role == .observer) return error.Unauthorized;"),
    );
    try std.testing.expectEqual(@as(usize, 1), count(runtime_product, "return mapGenerationDecodedError(err);"));
    try std.testing.expectEqual(
        @as(usize, 1),
        count(cleanup_registry, "tag == .attach_observer and identity.role == .observer"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(cleanup_registry, ".tag = .attach_observer, .lifecycle = .reserved, .role = .observer"),
    );
    try std.testing.expectEqual(@as(usize, 2), count(client_slot, "\\\"mode\\\":\\\"observer\\\""));
    try std.testing.expectEqual(@as(usize, 1), count(runtime_product, "fn initObserverReconnectCandidate("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime_product, "pub fn prepareObserverReconnectCandidate("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime_product, "self.generation_owner.prepareAfterClientReplacement("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime_product, "initObserverReconnectCandidate,"));
    try std.testing.expectEqual(@as(usize, 2), count(runtime, "test \"CR4a "));
    try std.testing.expectEqual(@as(usize, 1), count(server, "test \"CR4a frontier는"));
    try std.testing.expectEqual(@as(usize, 1), count(snapshot, "test \"CR4a frontier는"));
    try std.testing.expectEqual(@as(usize, 1), count(server, "next_screen_sequence: ?u64 = null"));
    try std.testing.expectEqual(@as(usize, 1), count(server, "sub.screen_sequence = sequence"));
    try std.testing.expectEqual(@as(usize, 1), count(assembler, "admitted_sequence != expected_sequence"));
    try std.testing.expectEqual(@as(usize, 1), count(remote_attachment, "prepared_screen.prepareRecoveryFrontierFrom(screen)"));
    try std.testing.expectEqual(@as(usize, 1), count(assembler, "pub fn prepareRecoveryFrontierFrom("));
    try std.testing.expectEqual(@as(usize, 1), count(server, "base, next_sequence, self.allocator"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime_product, "screenPtr().?.requireSequencedDeltas()"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime_manager, ".{ .generation = generation, .sequence = sequence }"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime_manager, "base: []const u8, sequence: u64,"));
    try std.testing.expectEqual(@as(usize, 1), count(snapshot, ".{ .generation = 7, .sequence = 1 }"));
    try std.testing.expectEqual(@as(usize, 2), count(runtime, "runtime.prepareObserverReconnectCandidate("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "fn publishCr4aReplacementPrerequisite("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "candidate_adapter == &adapter"));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "\"test-session-host-cr4a\""));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "CR4a actual socket observer"));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "CR4a observer 실패"));
    try std.testing.expectEqual(@as(usize, 2), count(build_cr4a, "--maru-expect-tests=2"));
    try std.testing.expectEqual(@as(usize, 10), count(build_cr4a, "--maru-expect-tests=1"));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "CR4a frontier는 snapshot zero"));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "CR4a frontier는 output admission"));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "CR4a dormant barrier"));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "CR4a host pending은"));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "CR4a host capability는"));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "CR4a host admission은"));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "CR4a poll owner는"));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "CR4a restore exec bootstrap은"));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "MARU_CR4A_RESTORE_EXEC_ROLE"));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "maru-cr4a-restore-parent-v1"));
    try std.testing.expectEqual(@as(usize, 2), count(build_cr4a, "CR4a host barrier frame"));
    try std.testing.expectEqual(@as(usize, 1), count(catchup, "pub const ScreenFrontier = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(catchup, "pub const CatchupIdentity = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(catchup, "pub const Barrier = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(catchup, "pub const HostState = union(enum)"));
    try std.testing.expectEqual(@as(usize, 1), count(catchup, "pub const Pending = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(catchup, "pub const Admitted = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(catchup, "pub const Terminal = struct"));
    try std.testing.expectEqual(@as(usize, 2), count(catchup, "test \"CR4a dormant barrier"));
    try std.testing.expectEqual(@as(usize, 1), count(catchup, "test \"CR4a host pending은"));
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExcept(allocator, "catchup_barrier_contract.zig", &.{
            "platform/macos/session_host/catchup_barrier_contract.zig",
            "platform/macos/session_host/server.zig",
        }),
    );
    try std.testing.expectEqual(@as(usize, 1), count(catchup, "pub const capability ="));
    try std.testing.expectEqual(@as(usize, 1), count(catchup_wire, "kind_raw: u16 = 14"));
    try std.testing.expectEqual(@as(usize, 1), count(catchup_wire, "version: u16 = 1"));
    try std.testing.expectEqual(@as(usize, 1), count(catchup_wire, "payload_size: usize = 96"));
    try std.testing.expectEqual(@as(usize, 0), count(catchup, "process_nonce"));
    try std.testing.expectEqual(@as(usize, 1), count(server, "const catchup_barrier_contract = @import"));
    try std.testing.expectEqual(@as(usize, 1), count(server, "runtime_catchup_barrier_v1: bool = false"));
    try std.testing.expectEqual(@as(usize, 1), count(server, "catchup: catchup_barrier_contract.HostState = .idle"));
    try std.testing.expectEqual(@as(usize, 1), count(server, "test \"CR4a host capability는"));
    try std.testing.expectEqual(@as(usize, 1), count(server, ".runtime_catchup => self.dispatchCatchup"));
    try std.testing.expectEqual(@as(usize, 1), count(connection_turn, ".catchup_arm_requested =>"));
    try std.testing.expectEqual(@as(usize, 1), count(connection_turn, "self.commitCatchupArm(&prepared)"));
    try std.testing.expectEqual(@as(usize, 1), count(connection_turn, "fn commitCatchupArm("));
    try std.testing.expectEqual(@as(usize, 1), count(connection_turn, "sub.catchup = prepared.after"));
    try std.testing.expectEqual(@as(usize, 1), count(connection_turn, "fn validateProcessIdentity("));
    try std.testing.expectEqual(@as(usize, 2), count(poll_owner, "const process_identity = process_seal_service.currentReadyIdentity() catch"));
    try std.testing.expectEqual(@as(usize, 2), count(poll_owner, ".process_identity = process_identity"));
    try std.testing.expectEqual(@as(usize, 1), count(poll_owner, "test \"CR4a poll owner는"));
    try std.testing.expectEqual(@as(usize, 0), count(poll_owner, "pub fn requireCurrentProcess("));
    try std.testing.expectEqual(@as(usize, 1), count(poll_owner, "pub fn requireCurrentProcessOrFatal("));
    try std.testing.expectEqual(@as(usize, 1), count(daemon, "error.ProcessIdentityUnavailable => error.ProcessIdentityUnavailable"));
    try std.testing.expectEqual(@as(usize, 1), count(daemon, ".authority_lost => fd_owner.requireCurrentProcessOrFatal()"));
    try std.testing.expectEqual(@as(usize, 1), count(restore_activation, ".authority_lost => owner.requireCurrentProcessOrFatal()"));
    try std.testing.expectEqual(@as(usize, 1), count(restore_activation, "const process_seal_service = @import(\"process_seal_service.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(restore_activation, "test \"CR4a restore exec bootstrap은"));
    try std.testing.expectEqual(@as(usize, 1), count(restore_activation, "fn bootstrapProcessSeal()"));
    try std.testing.expectEqual(@as(usize, 1), count(restore_activation, "process_seal_service.commitReady(try process_seal_service.prepare(process_pid, process_nonce))"));
    const restore_run_start = std.mem.indexOf(u8, restore_activation, "pub fn run(") orelse
        return error.TestUnexpectedResult;
    const restore_run_end = std.mem.indexOfPos(u8, restore_activation, restore_run_start, "fn bootstrapProcessSeal()") orelse
        return error.TestUnexpectedResult;
    const restore_run = restore_activation[restore_run_start..restore_run_end];
    const bootstrap_pos = std.mem.indexOf(u8, restore_run, "_ = try bootstrapProcessSeal();") orelse
        return error.TestUnexpectedResult;
    const arm_pos = std.mem.indexOf(u8, restore_run, "upgrade_bootstrap.armRestoreInvocation(") orelse
        return error.TestUnexpectedResult;
    const activate_pos = std.mem.indexOf(u8, restore_run, "activateValidated(") orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(bootstrap_pos < arm_pos);
    try std.testing.expect(arm_pos < activate_pos);
    const daemon_turn = daemon[std.mem.indexOf(u8, daemon, "while (true) {\n        fd_owner.requireCurrentProcessOrFatal();") orelse
        return error.TestUnexpectedResult ..];
    try std.testing.expect(std.mem.indexOf(u8, daemon_turn, "server.tickOwner();") != null);
    const restore_turn = restore_activation[std.mem.indexOf(u8, restore_activation, "while (true) {\n        owner.requireCurrentProcessOrFatal();") orelse
        return error.TestUnexpectedResult ..];
    try std.testing.expect(std.mem.indexOf(u8, restore_turn, "server.tickOwner();") != null);
    try std.testing.expectEqual(@as(usize, 1), count(connection_turn, "test \"CR4a host admission은"));
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExcept(allocator, "catchup_barrier_wire.zig", &.{
            "platform/macos/session_host/catchup_barrier_contract.zig",
            "platform/macos/session_host/protocol.zig",
            "platform/macos/session_host/catchup_barrier_wire.zig",
        }),
    );
    try std.testing.expectEqual(@as(usize, 1), count(protocol, "screen_frontier_barrier = catchup_barrier_wire.kind_raw"));
    try std.testing.expectEqual(@as(usize, 1), count(protocol, "test \"CR4a host barrier frame"));
    try std.testing.expectEqual(@as(usize, 1), count(server, "test \"CR4a host barrier frame은"));
    try std.testing.expectEqual(@as(usize, 1), count(connection_turn, ".barrier => return false"));
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExcept(allocator, "prepareObserverReconnectCandidate(", &.{
            "platform/macos/session_host/remote_runtime.zig",
        }),
    );
}
