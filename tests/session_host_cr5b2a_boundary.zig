//! CR5b-2a host-wide prepublication retirement preparation boundary.

const std = @import("std");
const posixWalk = @import("support/posix_walk.zig").posixWalk;
const max_source_bytes = 16 * 1024 * 1024;

test "CR5b-2a 경계는 all-runtime prepare와 reverse abort만 열고 shared replacement를 닫는다" {
    const allocator = std.testing.allocator;
    const backend = try readSource(allocator, "src/platform/macos/session_host/remote_term_backend.zig");
    defer allocator.free(backend);
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);
    const attachment = try readSource(allocator, "src/platform/macos/session_host/generation_attachment.zig");
    defer allocator.free(attachment);
    const screen = try readSource(allocator, "src/platform/macos/session_host/stable_screen_source.zig");
    defer allocator.free(screen);
    const slot = try readSource(allocator, "src/platform/macos/session_host/client_slot.zig");
    defer allocator.free(slot);
    const payload = try readSource(allocator, "src/platform/macos/session_host/remote_attachment.zig");
    defer allocator.free(payload);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);

    inline for (.{
        "retirements_prepared = 14,",
        "pub fn prepareHostReconnectRuntimeRetirements(",
        "test \"CR5b-2a host job은",
    }) |needle| try std.testing.expectEqual(@as(usize, 1), count(backend, needle));
    inline for (.{
        "pub fn prepareHostWideRetirement(",
        "pub fn hostWideRetirementPreparedExact(",
        "pub fn abortHostWideRetirement(",
    }) |needle| try std.testing.expectEqual(@as(usize, 1), count(runtime, needle));
    inline for (.{
        "pub fn prepareHostRetirement(",
        "pub fn hostRetirementPreparedExact(",
        "pub fn abortHostRetirement(",
    }) |needle| try std.testing.expectEqual(@as(usize, 1), count(attachment, needle));
    inline for (.{
        "pub fn prepareUnavailableFromLive(",
        "pub fn preparedUnavailableExact(",
        "pub fn abortPreparedUnavailable(",
    }) |needle| try std.testing.expectEqual(@as(usize, 1), count(screen, needle));
    try std.testing.expectEqual(@as(usize, 1), count(slot, "pub fn preflightAttachmentDrop("));
    try std.testing.expectEqual(@as(usize, 1), count(payload, "pub fn preflightPayloadOnlyDeinit("));

    const owner_inventory = [_]struct {
        identifier: []const u8,
        backend_count: usize = 0,
        runtime_count: usize = 0,
        attachment_count: usize = 0,
        screen_count: usize = 0,
    }{
        // CR5b-2b and CR5b-2c actual shared-replacement fixtures each reuse the product entry.
        // CR6e-c3b2b adds the reviewed one-state frame driver caller.
        .{ .identifier = "prepareHostReconnectRuntimeRetirements", .backend_count = 9 },
        // CR5c reuses the same prepare/abort pair for already-published rows before its no-fail
        // host-wide unavailable suffix.
        .{ .identifier = "prepareHostWideRetirement", .backend_count = 2, .runtime_count = 3 },
        // CR5b-2b adds one whole-set revalidation in its reserved state and two explicit
        // pre-commit mutation-zero assertions in the actual three-runtime fixture.
        .{ .identifier = "hostWideRetirementPreparedExact", .backend_count = 7, .runtime_count = 5 },
        .{ .identifier = "abortHostWideRetirement", .backend_count = 3, .runtime_count = 3 },
        .{ .identifier = "prepareHostRetirement", .runtime_count = 1, .attachment_count = 1 },
        .{ .identifier = "hostRetirementPreparedExact", .runtime_count = 1, .attachment_count = 3 },
        .{ .identifier = "abortHostRetirement", .runtime_count = 2, .attachment_count = 1 },
        .{ .identifier = "prepareUnavailableFromLive", .runtime_count = 1, .screen_count = 1 },
        .{ .identifier = "preparedUnavailableExact", .runtime_count = 1, .screen_count = 3 },
        .{ .identifier = "abortPreparedUnavailable", .runtime_count = 1, .screen_count = 1 },
    };
    for (owner_inventory) |entry| {
        try std.testing.expectEqual(entry.backend_count, countIdentifier(backend, entry.identifier));
        try std.testing.expectEqual(entry.runtime_count, countIdentifier(runtime, entry.identifier));
        try std.testing.expectEqual(entry.attachment_count, countIdentifier(attachment, entry.identifier));
        try std.testing.expectEqual(entry.screen_count, countIdentifier(screen, entry.identifier));
    }

    const prepare = between(
        backend,
        "pub fn prepareHostReconnectRuntimeRetirements(",
        "/// A terminal shared transport invalidates every runtime",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(prepare, "RemoteRuntime.backend_api.prepareHostWideRetirement("));
    try std.testing.expectEqual(@as(usize, 1), count(prepare, "RemoteRuntime.backend_api.abortHostWideRetirement("));
    try std.testing.expectEqual(@as(usize, 0), count(prepare, "publishReconnectClientReplacement("));
    try std.testing.expectEqual(@as(usize, 0), count(prepare, "publishHostReconnectReplacement("));
    const shared_state = between(
        backend,
        "@intFromEnum(HostReconnectJobState.shared_replacement_reserved) => {",
        "@intFromEnum(HostReconnectJobState.replacement_published) => {",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        @as(usize, 1),
        count(shared_state, "RemoteRuntime.backend_api.hostWideRetirementPreparedExact("),
    );

    inline for (.{
        "prepareHostReconnectRuntimeRetirements",
        "prepareHostWideRetirement",
        "hostWideRetirementPreparedExact",
        "abortHostWideRetirement",
        "prepareHostRetirement",
        "hostRetirementPreparedExact",
        "abortHostRetirement",
        "prepareUnavailableFromLive",
        "preparedUnavailableExact",
        "abortPreparedUnavailable",
    }) |identifier| try std.testing.expectEqual(
        @as(usize, 0),
        try countProductIdentifiersExcept(allocator, identifier, &.{
            "platform/macos/session_host/remote_term_backend.zig",
            "platform/macos/session_host/remote_runtime.zig",
            "platform/macos/session_host/generation_attachment.zig",
            "platform/macos/session_host/stable_screen_source.zig",
        }),
    );

    const gate = between(build, "const session_host_cr5b2a_step =", "const session_host_cr5b2b_step =") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(gate, "\"test-session-host-cr5b2a\""));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "session_host_cr5b2a_step.dependOn(session_host_cr5b1_step);"));
    try std.testing.expectEqual(@as(usize, 2), count(gate, "--maru-expect-tests=1"));
}

fn between(source: []const u8, start: []const u8, end: []const u8) ?[]const u8 {
    const from = std.mem.indexOf(u8, source, start) orelse return null;
    const to = std.mem.indexOfPos(u8, source, from, end) orelse return null;
    return source[from..to];
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
