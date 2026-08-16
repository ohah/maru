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
    try std.testing.expectEqual(@as(usize, 2), count(runtime, "runtime.prepareObserverReconnectCandidate("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "fn publishCr4aReplacementPrerequisite("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "candidate_adapter == &adapter"));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "\"test-session-host-cr4a\""));
    try std.testing.expectEqual(@as(usize, 1), count(build_cr4a, "--maru-expect-tests=2"));
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExcept(allocator, "prepareObserverReconnectCandidate(", &.{
            "platform/macos/session_host/remote_runtime.zig",
        }),
    );
}
