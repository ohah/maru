//! CR4b stable mutation seal의 제품 caller와 CR4c 미개방 경계를 고정한다.

const std = @import("std");
const posixWalk = @import("support/posix_walk.zig").posixWalk;

const max_source_bytes = 16 * 1024 * 1024;

test "CR4b 경계는 staged receipt 뒤 stable mutation seal exact once만 연다" {
    const allocator = std.testing.allocator;
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);
    const backend = try readSource(allocator, "src/platform/macos/session_host/remote_term_backend.zig");
    defer allocator.free(backend);
    const attachment = try readSource(allocator, "src/platform/macos/session_host/generation_attachment.zig");
    defer allocator.free(attachment);
    const batch_adapter = try readSource(allocator, "src/platform/macos/session_host/generation_batch_adapter.zig");
    defer allocator.free(batch_adapter);
    const client_slot = try readSource(allocator, "src/platform/macos/session_host/client_slot.zig");
    defer allocator.free(client_slot);
    const seal_input = try readSource(allocator, "src/platform/macos/session_host/event_cleanup_seal.zig");
    defer allocator.free(seal_input);
    const mutation = try readSource(allocator, "src/platform/macos/session_host/reconnect_mutation_seal.zig");
    defer allocator.free(mutation);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);
    const finish_start = std.mem.indexOf(u8, backend, "fn finishHostReconnectTakeoverOutcome(").?;
    const finish_end = std.mem.indexOfPos(u8, backend, finish_start, "fn sealHostReconnectCandidateFailure(").?;
    const finish_takeover = backend[finish_start..finish_end];
    const actual_job_start = std.mem.indexOf(u8, backend, "fn runCr4aActualIssuerReplacementStage(").?;
    const actual_job_end = std.mem.indexOfPos(
        u8,
        backend,
        actual_job_start,
        "test \"CR4a actual issuer job은",
    ).?;
    const actual_job = backend[actual_job_start..actual_job_end];
    const controller_start = std.mem.indexOf(u8, attachment, "pub fn executeControllerTakeoverUntil(").?;
    const controller_end = std.mem.indexOfPos(u8, attachment, controller_start, "pub fn validateControllerEvidence(").?;
    const controller_takeover = attachment[controller_start..controller_end];

    try std.testing.expectEqual(@as(usize, 1), count(runtime, "paused_input_metadata: ?reconnect_mutation_seal.PausedInputMetadata = null,"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "paused_paste_store: reconnect_mutation_seal.PausedPasteStore = .{},"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "fn sealReconnectMutationQueue("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "pub fn sealReconnectMutations("));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "paused_paste_budget: reconnect_mutation_seal.GlobalPasteBudget = .{},"));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "pub fn sealHostReconnectMutations("));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "const result = try RemoteRuntime.backend_api.sealReconnectMutations("));
    try std.testing.expectEqual(@as(usize, 1), count(seal_input, "mutation_digest: Digest,"));
    try std.testing.expectEqual(@as(usize, 3), count(backend, "test \"CR4b actual host job은"));
    try std.testing.expectEqual(@as(usize, 2), count(mutation, "test \"CR4b paused paste는"));
    try std.testing.expectEqual(@as(usize, 2), count(runtime, "test \"CR4b stable queue seal은"));
    try std.testing.expectEqual(@as(usize, 2), count(runtime, "test \"CR4b actual socket controller takeover는"));
    // The daemon binds its listener before manifest/rollback preparation completes. The actual
    // host fixture must never turn that early kernel readiness into an unbounded hello read.
    try std.testing.expectEqual(@as(usize, 0), count(actual_job, "client_mod.Client.connect("));
    try std.testing.expectEqual(@as(usize, 1), count(actual_job, "client_mod.Client.connectUntil("));
    // One pre-fork stale cleanup plus one deferred teardown cleanup.
    try std.testing.expectEqual(@as(usize, 2), count(actual_job, "_ = c.unlink(socket.ptr);"));
    try std.testing.expect(
        std.mem.indexOf(u8, actual_job, "c.access(socket.ptr, c.F_OK)").? <
            std.mem.indexOf(u8, actual_job, "client_mod.Client.connectUntil(").?,
    );
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "pub fn executeControllerTakeoverUntil("));
    try std.testing.expectEqual(@as(usize, 1), count(controller_takeover, "self.catchup_stage_owner.state = .controller_committing;"));
    try std.testing.expect(
        std.mem.indexOf(u8, controller_takeover, "self.catchup_stage_owner.state = .controller_committing;").? <
            std.mem.indexOf(u8, controller_takeover, "remote_attachment.statusParams(").?,
    );
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "pub fn executeReconnectControllerTakeoverUntil("));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "pub fn executeHostReconnectTakeover("));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "fn finishHostReconnectTakeoverOutcome("));
    try std.testing.expectEqual(@as(usize, 1), count(finish_takeover, "RemoteRuntime.backend_api.abortReconnectObserverStage("));
    try std.testing.expectEqual(@as(usize, 1), count(finish_takeover, "RemoteRuntime.backend_api.abortReconnectObserverStageForClosedOutcome("));
    try std.testing.expectEqual(@as(usize, 1), count(batch_adapter, "pub fn callControllerUntil("));
    try std.testing.expectEqual(@as(usize, 1), count(batch_adapter, "pub fn refreshControllerEvidence("));
    try std.testing.expectEqual(@as(usize, 1), count(client_slot, "pub fn callCurrentUntil("));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "pub fn validateControllerEvidence("));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "pub fn releaseControllerEvidence("));
    try std.testing.expectEqual(@as(usize, 8), count(backend, "HostReconnectJobState.controller_evidenced"));

    // Controller promotion is one closed owner chain. Raw identifier inventories catch both
    // qualified calls and function aliases, while the per-file totals prevent caller laundering
    // inside an already allowed owner module.
    inline for (.{
        .{ "executeControllerTakeoverUntil", &.{
            "platform/macos/session_host/generation_attachment.zig",
            "platform/macos/session_host/remote_runtime.zig",
        } },
        .{ "validateControllerEvidence", &.{
            "platform/macos/session_host/generation_attachment.zig",
            "platform/macos/session_host/remote_runtime.zig",
        } },
        .{ "releaseControllerEvidence", &.{
            "platform/macos/session_host/generation_attachment.zig",
            "platform/macos/session_host/remote_runtime.zig",
        } },
        .{ "callControllerUntil", &.{
            "platform/macos/session_host/generation_attachment.zig",
            "platform/macos/session_host/generation_batch_adapter.zig",
        } },
        .{ "refreshControllerEvidence", &.{
            "platform/macos/session_host/generation_attachment.zig",
            "platform/macos/session_host/generation_batch_adapter.zig",
        } },
        .{
            "callCurrentUntil",
            &.{
                "platform/macos/session_host/generation_batch_adapter.zig",
                "platform/macos/session_host/client_slot.zig",
                // CR6b HostAdapter facade가 one-item action의 host.info/runtime.get에 같은 absolute deadline을 전달한다.
                "platform/macos/session_host/host_adapter.zig",
            },
        },
        .{ "executeReconnectControllerTakeoverUntil", &.{
            "platform/macos/session_host/remote_runtime.zig",
            "platform/macos/session_host/remote_term_backend.zig",
        } },
        .{ "validateReconnectControllerEvidence", &.{
            "platform/macos/session_host/remote_runtime.zig",
            "platform/macos/session_host/remote_term_backend.zig",
        } },
        .{ "abortReconnectControllerEvidence", &.{
            "platform/macos/session_host/remote_runtime.zig",
            "platform/macos/session_host/remote_term_backend.zig",
        } },
        .{ "executeHostReconnectTakeover", &.{
            "platform/macos/session_host/remote_term_backend.zig",
        } },
    }) |inventory| try std.testing.expectEqual(
        @as(usize, 0),
        try countProductIdentifiersExcept(allocator, inventory[0], inventory[1]),
    );
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(attachment, "executeControllerTakeoverUntil"));
    try std.testing.expectEqual(@as(usize, 3), countIdentifier(runtime, "executeControllerTakeoverUntil"));
    try std.testing.expectEqual(@as(usize, 3), countIdentifier(attachment, "validateControllerEvidence"));
    try std.testing.expectEqual(@as(usize, 3), countIdentifier(runtime, "validateControllerEvidence"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(attachment, "releaseControllerEvidence"));
    try std.testing.expectEqual(@as(usize, 2), countIdentifier(runtime, "releaseControllerEvidence"));
    // CR4b owns status+takeover exact2; CR4c C2 adds the sole forced-resize consumer.
    try std.testing.expectEqual(@as(usize, 3), countIdentifier(attachment, "callControllerUntil"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(batch_adapter, "callControllerUntil"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(attachment, "refreshControllerEvidence"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(batch_adapter, "refreshControllerEvidence"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(client_slot, "callCurrentUntil"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(batch_adapter, "callCurrentUntil"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(runtime, "executeReconnectControllerTakeoverUntil"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(backend, "executeReconnectControllerTakeoverUntil"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(runtime, "validateReconnectControllerEvidence"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(backend, "validateReconnectControllerEvidence"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(runtime, "abortReconnectControllerEvidence"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(backend, "abortReconnectControllerEvidence"));
    // CR5b-2c reuses the sole product takeover entry in its three-runtime loop.
    // CR6e-c3b2b adds the reviewed one-state frame driver caller.
    try std.testing.expectEqual(@as(usize, 6), countIdentifier(backend, "executeHostReconnectTakeover"));

    const start = std.mem.indexOf(u8, build, "const session_host_cr4b_step =").?;
    const end = std.mem.indexOfPos(u8, build, start, "const session_host_cr4c_c1_step =").?;
    const gate = build[start..end];
    try std.testing.expectEqual(@as(usize, 1), count(gate, "\"test-session-host-cr4b\""));
    try std.testing.expectEqual(@as(usize, 2), count(gate, "--maru-expect-tests=1"));
    try std.testing.expectEqual(@as(usize, 3), count(gate, "--maru-expect-tests=2"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "--maru-expect-tests=3"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "CR4b mutation owner는"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "CR4b paused paste는"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "CR4b stable queue seal은"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "CR4b actual socket controller takeover는"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "CR4b actual host job은"));

    try std.testing.expectEqual(@as(usize, 1), count(backend, "pub fn executeHostReconnectTakeover("));
    // RemoteGeneration publication은 CR4c C2의 sole product entry 하나만 연다.
    try std.testing.expectEqual(@as(usize, 1), count(backend, "pub fn publishHostReconnectGeneration("));
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, needle)) |index| {
        total += 1;
        offset = index + needle.len;
    }
    return total;
}

fn identifierByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn countIdentifier(haystack: []const u8, identifier: []const u8) usize {
    var total: usize = 0;
    var rest = haystack;
    var consumed: usize = 0;
    while (std.mem.indexOf(u8, rest, identifier)) |relative| {
        const at = consumed + relative;
        const end = at + identifier.len;
        if ((at == 0 or !identifierByte(haystack[at - 1])) and
            (end == haystack.len or !identifierByte(haystack[end]))) total += 1;
        consumed = end;
        rest = haystack[consumed..];
    }
    return total;
}

fn countProductIdentifiersExcept(
    allocator: std.mem.Allocator,
    identifier: []const u8,
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
        total += countIdentifier(source, identifier);
    }
    return total;
}

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(
        std.testing.io,
        path,
        allocator,
        .limited(max_source_bytes),
        .of(u8),
        0,
    );
}
