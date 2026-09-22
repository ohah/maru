//! C3-3b2b1 source boundary: typed seals and the trusted projection stay dormant and leaf-owned.

const std = @import("std");
/// 스캐너가 보는 walker 경로를 POSIX 구분자로 정규화한다(정본: tests/support/posix_walk.zig).
const posixWalk = @import("support/posix_walk.zig").posixWalk;

test "C3-3b2b1 trusted preparation seal boundary" {
    const allocator = std.testing.allocator;
    const neutral = try readSource(
        allocator,
        "src/platform/macos/session_host/event_cleanup_seal.zig",
    );
    defer allocator.free(neutral);
    const service = try readSource(
        allocator,
        "src/platform/macos/session_host/process_seal_service.zig",
    );
    defer allocator.free(service);
    const slot = try readSource(allocator, "src/platform/macos/session_host/client_slot.zig");
    defer allocator.free(slot);
    const contract = try readSource(
        allocator,
        "src/platform/macos/session_host/generation_event_contract.zig",
    );
    defer allocator.free(contract);
    const transport = try readSource(
        allocator,
        "src/platform/macos/session_host/generation_transport.zig",
    );
    defer allocator.free(transport);
    const runtime = try readSource(
        allocator,
        "src/platform/macos/session_host/remote_runtime.zig",
    );
    defer allocator.free(runtime);
    const poll_owner = try readSource(allocator, "src/platform/macos/session_host/poll_owner.zig");
    defer allocator.free(poll_owner);
    const connection_turn = try readSource(allocator, "src/platform/macos/session_host/connection_turn.zig");
    defer allocator.free(connection_turn);
    const reconnect_window_transaction = try readSource(
        allocator,
        "src/platform/macos/session_host/host_reconnect_window_transaction.zig",
    );
    defer allocator.free(reconnect_window_transaction);
    const shutdown_attempt = try readSource(
        allocator,
        "src/platform/macos/session_host/shutdown_attempt_authority.zig",
    );
    defer allocator.free(shutdown_attempt);
    const remote_backend = try readSource(
        allocator,
        "src/platform/macos/session_host/remote_term_backend.zig",
    );
    defer allocator.free(remote_backend);
    const shutdown_connector = try readSource(
        allocator,
        "src/platform/macos/session_host/shutdown_admin_connector.zig",
    );
    defer allocator.free(shutdown_connector);
    const reconnect_resident_budget = try readSource(
        allocator,
        "src/platform/macos/session_host/reconnect_resident_budget.zig",
    );
    defer allocator.free(reconnect_resident_budget);

    try std.testing.expectEqual(@as(usize, 1), count(
        service,
        "pub fn cleanupTranscriptSeal(",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(
        service,
        "pub fn cleanupProgressSeal(",
    ));
    try std.testing.expectEqual(@as(usize, 0), count(service, "pub fn generic"));
    try std.testing.expectEqual(@as(usize, 0), count(service, "rawKey"));
    try std.testing.expectEqual(@as(usize, 0), count(neutral, "std.mem.Allocator"));
    inline for (.{
        "cleanupDescriptorCanonical",
        "cleanupPlanCanonical",
        "cleanupTranscriptInputCanonical",
        "cleanupProgressInputCanonical",
        "foregroundProcessesInputCanonical",
        "observationCleanupInputCanonical",
        "progressCanonical",
    }) |validator| try std.testing.expectEqual(
        @as(usize, 0),
        count(neutral, "pub fn " ++ validator),
    );
    try std.testing.expectEqual(@as(usize, 1), count(
        neutral,
        "pub fn assertCleanupTranscriptCanonical(",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(
        neutral,
        "pub fn assertCleanupProgressCanonical(",
    ));
    inline for (.{ "RemoteRuntime", "PendingEventOwner", "EventCorrelation", "../pty" }) |forbidden| {
        try std.testing.expectEqual(@as(usize, 0), count(neutral, forbidden));
        try std.testing.expectEqual(@as(usize, 0), count(service, forbidden));
    }

    try std.testing.expectEqual(@as(usize, 1), count(
        slot,
        "pub fn generationEventPreparationProjection(",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(
        contract,
        "client_slot.generationEventPreparationProjection(",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(
        transport,
        "generation_event.preparationEventView(owner, self.event_correlation)",
    ));
    try std.testing.expectEqual(@as(usize, 0), count(
        transport,
        "pub const PreparationEventView",
    ));
    // b2b3 adds the dormant RemoteRuntime orchestration signature while keeping the normal pump
    // caller at zero; b2b1 still owns the sole projection type and validation path.
    try std.testing.expectEqual(@as(usize, 1), countIdentifierOutsideTopLevelTests(runtime, "PreparationEventView"));
    try std.testing.expectEqual(@as(usize, 0), count(runtime, "cleanupTranscriptSeal"));
    try std.testing.expectEqual(
        // b3 settlement contract도 pointer-free receipt digest를 위해 neutral seal type을 소비한다.
        @as(usize, 6),
        try countProductSources(allocator, "@import(\"event_cleanup_seal.zig\")"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        try countProductSources(
            allocator,
            "generation_event.preparationEventView(owner, self.event_correlation)",
        ),
    );
    try std.testing.expectEqual(
        // C3-3b3 receipt/permit, b5 close owner, b6 shutdown owner, 2d2 terminal handoff와 CR0b composite/GUI/daemon owner,
        // CR1 scheduler dispatch, CR2e-e3b1 resident admission budget, e3c1 coordinator,
        // CR6e-c3b2a product coordinator와
        // CR4 poll-owner/client-turn process fence와 exec 뒤 restore bootstrap, CR5d-1의 sealed
        // two-Window transaction까지 검증한다.
        @as(usize, 35),
        try countProductSources(allocator, "@import(\"process_seal_service.zig\")"),
    );
    try std.testing.expectEqual(@as(usize, 1), count(poll_owner, "@import(\"process_seal_service.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(connection_turn, "@import(\"process_seal_service.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(reconnect_window_transaction, "@import(\"process_seal_service.zig\")"));
    const restore_activation = try readSource(allocator, "src/platform/macos/session_host/restore_activation.zig");
    defer allocator.free(restore_activation);
    try std.testing.expectEqual(@as(usize, 1), count(restore_activation, "@import(\"process_seal_service.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(poll_owner, "pub fn requireCurrentProcessOrFatal("));
    try std.testing.expectEqual(@as(usize, 1), count(connection_turn, "fn commitCatchupArm("));
    try std.testing.expectEqual(
        @as(usize, 1),
        count(reconnect_resident_budget, "@import(\"process_seal_service.zig\")"),
    );
    const publisher_registry = try readSource(allocator, "src/platform/macos/session_host/incident_publisher_registry.zig");
    defer allocator.free(publisher_registry);
    try std.testing.expectEqual(@as(usize, 1), count(publisher_registry, "@import(\"process_seal_service.zig\")"));
    try std.testing.expectEqual(@as(usize, 0), count(publisher_registry, "client.zig"));
    try std.testing.expectEqual(@as(usize, 0), count(publisher_registry, "incident_runtime.zig"));
    const incident_runtime = try readSource(allocator, "src/platform/macos/session_host/incident_runtime.zig");
    defer allocator.free(incident_runtime);
    try std.testing.expectEqual(@as(usize, 1), count(incident_runtime, "@import(\"process_seal_service.zig\")"));
    try std.testing.expectEqual(@as(usize, 2), count(incident_runtime, "fatalIntegrity(.counter_exhausted)"));
    const daemon = try readSource(allocator, "src/platform/macos/session_host/daemon.zig");
    defer allocator.free(daemon);
    try std.testing.expectEqual(@as(usize, 1), count(daemon, "@import(\"process_seal_service.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(
        remote_backend,
        "@import(\"process_seal_service.zig\")",
    ));
    const batch_registry = try readSource(allocator, "src/platform/macos/session_host/generation_batch_registry.zig");
    defer allocator.free(batch_registry);
    try std.testing.expectEqual(@as(usize, 1), count(batch_registry, "@import(\"process_seal_service.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(
        shutdown_attempt,
        "@import(\"process_seal_service.zig\")",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(
        shutdown_connector,
        "@import(\"process_seal_service.zig\")",
    ));
    inline for (.{
        .{ "generationEventPreparationProjection", 2 },
        .{ "GenerationEventPreparationProjection", 8 },
        .{ "preparationEventView", 6 },
        // b2b3 adds the dormant RemoteRuntime orchestration signature.
        .{ "PreparationEventView", 10 },
        // b2b3 persists and revalidates the exact transcript input at the final owner.
        // C3-3b3 event release completion의 준비와 contextual 재검증이 transcript seal을 각각 한 번 계산한다.
        .{ "cleanupTranscriptSeal", 9 },
        // b2b3 seals the projected post-publication transfer before its no-fail owner write.
        // C3-3b3 event release completion의 준비와 contextual 재검증이 progress seal도 각각 한 번 계산한다.
        // b4 semantic commit이 callback 전후 POST continuation을 한 번 더 봉인한다.
        .{ "cleanupProgressSeal", 11 },
    }) |entry| try std.testing.expectEqual(
        @as(usize, entry[1]),
        try countProductIdentifiers(allocator, entry[0]),
    );
}

fn countProductSources(allocator: std.mem.Allocator, needle: []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    var total: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        const source = try readSource(allocator, path);
        defer allocator.free(source);
        total += count(source, needle);
    }
    return total;
}

fn countProductIdentifiers(allocator: std.mem.Allocator, identifier: []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    var total: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        const source = try readSource(allocator, path);
        defer allocator.free(source);
        total += countIdentifierOutsideTopLevelTests(source, identifier);
    }
    return total;
}

fn countIdentifierOutsideTopLevelTests(source: [:0]const u8, wanted: []const u8) usize {
    var tokenizer = std.zig.Tokenizer.init(source);
    var brace_depth: usize = 0;
    var waiting_for_test_body = false;
    var test_body_depth: ?usize = null;
    var result: usize = 0;
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => return result,
            .keyword_test => if (brace_depth == 0 and test_body_depth == null) {
                waiting_for_test_body = true;
            },
            .l_brace => {
                brace_depth += 1;
                if (waiting_for_test_body) {
                    test_body_depth = brace_depth;
                    waiting_for_test_body = false;
                }
            },
            .r_brace => {
                if (test_body_depth != null and test_body_depth.? == brace_depth)
                    test_body_depth = null;
                if (brace_depth > 0) brace_depth -= 1;
            },
            .identifier => if (test_body_depth == null and
                std.mem.eql(u8, source[token.loc.start..token.loc.end], wanted))
            {
                result += 1;
            },
            else => {},
        }
    }
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

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, needle)) |index| {
        total += 1;
        offset = index + needle.len;
    }
    return total;
}
