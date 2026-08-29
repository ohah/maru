//! CR4c C2 forced resize, publication, mutation reopen and ordered reclaim sole chain.

const std = @import("std");
const posixWalk = @import("support/posix_walk.zig").posixWalk;
const max_source_bytes = 16 * 1024 * 1024;

test "CR4c C2 경계는 forced resize 뒤 generation publication과 ordered reclaim만 연다" {
    const allocator = std.testing.allocator;
    const mutation = try readSource(allocator, "src/platform/macos/session_host/reconnect_mutation_seal.zig");
    defer allocator.free(mutation);
    const attachment = try readSource(allocator, "src/platform/macos/session_host/generation_attachment.zig");
    defer allocator.free(attachment);
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);
    const backend = try readSource(allocator, "src/platform/macos/session_host/remote_term_backend.zig");
    defer allocator.free(backend);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);

    const resize = functionSlice(
        attachment,
        "pub fn forcePromotedControllerResizeUntil(",
        "pub fn statePtr(",
    );
    try std.testing.expect(index(resize, "validatePromotedController(") <
        index(resize, "callControllerUntil("));
    try std.testing.expect(index(resize, "callControllerUntil(") <
        index(resize, "decodeResizeResponse("));

    const publication = functionSlice(
        runtime,
        "fn publishReconnectPromotedCandidateImpl(",
        "pub fn reconnectMutationSealDigest(",
    );
    try std.testing.expect(index(publication, "preflightCandidatePromotedPublication(") <
        index(publication, "preflightExternalPublication("));
    try std.testing.expect(index(publication, "preflightExternalPublication(") <
        index(publication, "publishAfterClientReplacement("));
    try std.testing.expect(index(publication, "publishAfterClientReplacement(") <
        index(publication, "reopenNoFail("));
    try std.testing.expect(index(publication, "reopenNoFail(") <
        index(publication, "publishExternalNoFail("));
    try std.testing.expect(index(publication, "publishExternalNoFail(") <
        index(publication, "releasePromotedControllerNoFail("));
    try std.testing.expect(index(publication, "releasePromotedControllerNoFail(") <
        index(publication, "commitOrderedRetiringReclaimAtTickEndNoFail("));

    const product = functionSlice(
        backend,
        "pub fn publishHostReconnectGeneration(",
        "fn finishHostReconnectTakeoverOutcome(",
    );
    try std.testing.expect(index(product, "forceReconnectCandidateResizeUntil(") <
        index(product, "publishReconnectPromotedCandidate("));
    try std.testing.expect(index(product, "publishReconnectPromotedCandidate(") <
        index(product, "self.host_reconnect_job = null;"));

    inline for (.{
        .{ "forcePromotedControllerResizeUntil", &.{
            "platform/macos/session_host/generation_attachment.zig",
            "platform/macos/session_host/remote_runtime.zig",
        } },
        .{ "forceReconnectCandidateResizeUntil", &.{
            "platform/macos/session_host/remote_runtime.zig",
            "platform/macos/session_host/remote_term_backend.zig",
        } },
        .{ "publishReconnectPromotedCandidate", &.{
            "platform/macos/session_host/remote_runtime.zig",
            "platform/macos/session_host/remote_term_backend.zig",
        } },
        .{ "publishHostReconnectGeneration", &.{
            "platform/macos/session_host/remote_term_backend.zig",
        } },
    }) |inventory| try std.testing.expectEqual(
        @as(usize, 0),
        try countProductIdentifiersExcept(allocator, inventory[0], inventory[1]),
    );

    try std.testing.expectEqual(@as(usize, 5), countIdentifier(mutation, "preflightReopen"));
    try std.testing.expectEqual(@as(usize, 2), countIdentifier(mutation, "reopenNoFail"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(attachment, "forcePromotedControllerResizeUntil"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(runtime, "forceReconnectCandidateResizeUntil"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(runtime, "publishReconnectPromotedCandidate"));
    try std.testing.expectEqual(@as(usize, 2), countIdentifier(runtime, "preflightExternalPublication"));
    try std.testing.expectEqual(@as(usize, 2), countIdentifier(runtime, "publishExternalNoFail"));
    // Declaration + CR4 success/expired/replay + CR5b-2c multi-runtime product reuse.
    // CR6e-c3b2b adds the reviewed one-state frame driver caller.
    try std.testing.expectEqual(@as(usize, 6), countIdentifier(backend, "publishHostReconnectGeneration"));
    try std.testing.expectEqual(@as(usize, 4), countIdentifier(backend, "cr4c_publication_drift"));
    try std.testing.expectEqual(@as(usize, 2), count(backend, "test \"CR4c C2 actual host job은"));
    try std.testing.expectEqual(@as(usize, 1), count(
        backend,
        "test \"CR4c C2 publication suffix authority drift는",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "test \"CR4c C2 actual socket forced resize는"));

    // CR5 follows CR4c in the build graph; keep this inherited inventory scoped to CR4c itself.
    const gate = functionSlice(build, "const session_host_cr4c_c2_step =", "const session_host_cr5a_step =");
    try std.testing.expectEqual(@as(usize, 1), count(gate, "\"test-session-host-cr4c-c2\""));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "\"test-session-host-cr4c\""));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "session_host_cr4c_c2_step.dependOn(session_host_cr4c_c1_step);"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "session_host_cr4c_step.dependOn(session_host_cr4c_c2_step);"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "CR4c C2 actual host job은"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "CR4c C2 publication suffix authority drift는"));
    try std.testing.expectEqual(@as(usize, 4), count(gate, "--maru-expect-tests=1"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "--maru-expect-tests=2"));
}

fn functionSlice(source: []const u8, start: []const u8, end: []const u8) []const u8 {
    const from = index(source, start);
    return source[from..indexFrom(source, from, end)];
}
fn index(source: []const u8, needle: []const u8) usize {
    return std.mem.indexOf(u8, source, needle) orelse @panic("missing boundary anchor");
}
fn indexFrom(source: []const u8, from: usize, needle: []const u8) usize {
    return std.mem.indexOfPos(u8, source, from, needle) orelse @panic("missing boundary end anchor");
}
fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, needle)) |at| {
        total += 1;
        offset = at + needle.len;
    }
    return total;
}
fn identifierByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}
fn countIdentifier(haystack: []const u8, identifier: []const u8) usize {
    var total: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, identifier)) |at| {
        const end = at + identifier.len;
        if ((at == 0 or !identifierByte(haystack[at - 1])) and
            (end == haystack.len or !identifierByte(haystack[end]))) total += 1;
        offset = end;
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
