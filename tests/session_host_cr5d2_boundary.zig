//! CR5d-2 actual AppSession two-Window move/close wiring boundary.

const std = @import("std");
const posixWalk = @import("support/posix_walk.zig").posixWalk;
const max_source_bytes = 16 * 1024 * 1024;

test "CR5d-2 경계는 기존 Window 이동 뒤 fresh abandon commit 하나만 연다" {
    const allocator = std.testing.allocator;
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);
    const app = try readSource(allocator, "src/platform/macos/app_session.zig");
    defer allocator.free(app);
    const coordinator = try readSource(allocator, "src/platform/macos/app_session/session_host_window.zig");
    defer allocator.free(coordinator);
    const workspace = try readSource(allocator, "src/platform/macos/app_session/workspace.zig");
    defer allocator.free(workspace);
    const term = try readSource(allocator, "src/platform/macos/app_session/term.zig");
    defer allocator.free(term);
    const backend = try readSource(allocator, "src/platform/macos/session_host/remote_term_backend.zig");
    defer allocator.free(backend);
    const contract = try readSource(allocator, "src/platform/macos/session_host/host_reconnect_window_transaction.zig");
    defer allocator.free(contract);
    const development = try readSource(allocator, "docs/development-commands.md");
    defer allocator.free(development);
    const plan = try readSource(allocator, "docs/implementation-plan.md");
    defer allocator.free(plan);
    const matrix = try readSource(allocator, "docs/verification-matrix.md");
    defer allocator.free(matrix);
    const persistent = try readSource(allocator, "docs/persistent-session-host.md");
    defer allocator.free(persistent);

    try std.testing.expectEqual(@as(usize, 1), count(app, "test \"CR5d-2 actual AppSession Window 이동은"));
    try std.testing.expectEqual(@as(usize, 1), count(app, "@import(\"app_session/session_host_window.zig\")"));
    inline for (.{
        "pub fn prepareClose(",
        "pub fn prepareCloseWithBackend(",
        "pub fn commitClose(",
        "pub fn commitCloseWithBackend(",
    }) |needle| try std.testing.expectEqual(@as(usize, 1), count(coordinator, needle));

    const chain = [_]struct { id: []const u8, backend_count: usize, coordinator_count: usize }{
        .{ .id = "prepareHostReconnectWindowTransaction", .backend_count = 1, .coordinator_count = 1 },
        .{ .id = "commitHostReconnectWindowClose", .backend_count = 1, .coordinator_count = 1 },
        .{ .id = "revokeStaleHostReconnectWindowTransaction", .backend_count = 1, .coordinator_count = 1 },
    };
    for (chain) |entry| {
        try std.testing.expectEqual(entry.backend_count, countIdentifier(backend, entry.id));
        try std.testing.expectEqual(entry.coordinator_count, countIdentifier(coordinator, entry.id));
        try std.testing.expectEqual(@as(usize, 0), try countProductIdentifiersExcept(
            allocator,
            entry.id,
            &.{
                "platform/macos/session_host/remote_term_backend.zig",
                "platform/macos/app_session/session_host_window.zig",
            },
        ));
    }
    try std.testing.expectEqual(@as(usize, 2), count(backend, "bindings[0..projection.binding_count]"));
    try std.testing.expectEqual(@as(usize, 0), count(backend, "bindings[0..drafts.len]"));
    const projection = between(
        backend,
        "fn fillWindowTransactionProjection(",
        "fn releaseProductSingleton(",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(projection, "for (rows, 0..)"));
    try std.testing.expectEqual(@as(usize, 1), count(projection, ".binding_count = rows.len"));
    try std.testing.expectEqual(@as(usize, 1), count(app, "const foreign_handle: u64 = 99;"));
    try std.testing.expectEqual(@as(usize, 2), count(app, "terminalSurfaceById(first, foreign_surface_id) != null"));
    try std.testing.expectEqual(@as(usize, 1), count(term, "pub fn abandonTermAt("));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(coordinator, "abandonTermAt"));
    try std.testing.expectEqual(@as(usize, 0), try countProductIdentifiersExcept(
        allocator,
        "abandonTermAt",
        &.{
            "platform/macos/app_session/term.zig",
            "platform/macos/app_session/session_host_window.zig",
        },
    ));

    const abandon = between(term, "pub fn abandonTermAt(", "/// Read-only fixture evidence") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(abandon, "destroyTermWithAbandonBackend("));
    try std.testing.expectEqual(@as(usize, 0), count(abandon, "closeAndDetach("));
    try std.testing.expectEqual(@as(usize, 0), count(abandon, ".remove("));
    const destroy = between(term, "fn destroyTermWithAbandonBackend(", "/// platform 관찰 훅") orelse
        return error.TestUnexpectedResult;
    const abandon_destroy = between(
        destroy,
        "if (is_macos and term.rt.abandoned_to_inventory",
        "} else if (is_macos and term.rt.restored_existing",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(abandon_destroy, "rb.detachAbandonedWindowTerm(term.rt.handle);"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(backend, "detachAbandonedWindowTerm"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(term, "detachAbandonedWindowTerm"));
    try std.testing.expectEqual(@as(usize, 0), try countProductIdentifiersExcept(
        allocator,
        "detachAbandonedWindowTerm",
        &.{
            "platform/macos/session_host/remote_term_backend.zig",
            "platform/macos/app_session/term.zig",
        },
    ));

    try std.testing.expectEqual(@as(usize, 1), count(workspace, "pub fn advanceSessionHostWindowGraph("));
    const move = between(workspace, "pub fn moveWorkspaceToSession(", "pub fn workspaceRootCwd(") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), count(move, "advanceSessionHostWindowGraph("));
    try std.testing.expectEqual(@as(usize, 1), count(contract, "pub fn revokeStale("));
    try std.testing.expectEqual(@as(usize, 1), count(contract, "pub fn consumedExact("));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(backend, "consumedExact"));
    try std.testing.expectEqual(@as(usize, 0), try countProductIdentifiersExcept(
        allocator,
        "consumedExact",
        &.{
            "platform/macos/session_host/host_reconnect_window_transaction.zig",
            "platform/macos/session_host/remote_term_backend.zig",
        },
    ));

    const gate = between(build, "const session_host_cr5d2_step =", "const session_host_cr6a1_step =") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(gate, "\"test-session-host-cr5d2\""));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "session_host_cr5d2_step.dependOn(session_host_cr5d1_step);"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "\"CR5d-2 actual AppSession Window 이동은\""));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "src/platform/macos/app_session.zig"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "src/platform/macos/coretext_smoke.m"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "--maru-expect-tests=4"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "src/platform/macos/session_host_cr5d2_boundary.zig") +
        count(gate, "tests/session_host_cr5d2_boundary.zig"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "--maru-expect-tests=1"));

    inline for (.{ development, plan, matrix, persistent }) |doc|
        try std.testing.expect(std.mem.indexOf(u8, doc, "CR5d-2") != null);
}

fn between(source: []const u8, start: []const u8, end: []const u8) ?[]const u8 {
    const from = std.mem.indexOf(u8, source, start) orelse return null;
    const to = std.mem.indexOfPos(u8, source, from, end) orelse return null;
    return source[from..to];
}

fn count(haystack: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, haystack, needle);
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
