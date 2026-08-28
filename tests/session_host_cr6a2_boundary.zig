//! CR6a-2 launch collector and inert primary-sidebar materialization boundary.

const std = @import("std");
const posixWalk = @import("support/posix_walk.zig").posixWalk;

test "CR6a-2 경계는 launch-before-terminal 순서와 inert system rows를 고정한다" {
    const allocator = std.testing.allocator;
    const build = try read(allocator, "build.zig");
    defer allocator.free(build);
    const app = try read(allocator, "src/platform/macos/app_session.zig");
    defer allocator.free(app);
    const tabs = try read(allocator, "src/platform/macos/app_session/tab.zig");
    defer allocator.free(tabs);
    const chrome = try read(allocator, "src/chrome/components/sidebar.zig");
    defer allocator.free(chrome);
    const swift = try read(allocator, "src/platform/macos/MaruAppHost.swift");
    defer allocator.free(swift);
    const abi = try read(allocator, "src/platform/macos/app_host_abi.zig");
    defer allocator.free(abi);
    const header = try read(allocator, "src/platform/macos/app_host_abi.h");
    defer allocator.free(header);
    const persistent = try read(allocator, "docs/persistent-session-host.md");
    defer allocator.free(persistent);
    const plan = try read(allocator, "docs/implementation-plan.md");
    defer allocator.free(plan);

    try std.testing.expectEqual(@as(usize, 1), count(chrome, "    recovered_sessions_header,\n"));
    try std.testing.expectEqual(@as(usize, 1), count(chrome, "    recovered_session: struct"));
    try std.testing.expectEqual(@as(usize, 1), count(app, "pub fn prepareRecoveredSessionsAtLaunch("));
    try std.testing.expectEqual(@as(usize, 1), count(app, "pub fn finishDeferredInitialSurface("));
    try std.testing.expectEqual(@as(usize, 3), count(app, "test \"CR6a-2 primary sidebar는"));
    try std.testing.expectEqual(@as(usize, 1), count(abi, "test \"CR6a-2 ABI는"));
    try std.testing.expectEqual(@as(usize, 1), count(tabs, ".recovered_sessions_header, .recovered_session => null"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(app, "prepareRecoveredSessionsAtLaunch"));
    try std.testing.expectEqual(@as(usize, 3), countIdentifier(app, "prepareRecoveredSessionsAtLaunchFromBase"));
    // N3 adds one secure-registry notification adoption caller. P3-e4d-2b adds one focused actual
    // frozen-binary product test caller; the helper and shipping launch/recovery callers do not grow.
    try std.testing.expectEqual(@as(usize, 6), countIdentifier(app, "ensureRestoreHostAdapterAtBase"));
    try std.testing.expectEqual(@as(usize, 2), countIdentifier(app, "appendRecoveredSessionRows"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(tabs, "appendRecoveredSessionRows"));
    try std.testing.expectEqual(@as(usize, 2), countIdentifier(app, "finishDeferredInitialSurface"));
    try std.testing.expectEqual(@as(usize, 0), try countProductIdentifiersExcept(
        allocator,
        "prepareRecoveredSessionsAtLaunch",
        &.{ "platform/macos/app_session.zig", "platform/macos/app_host_abi.zig" },
    ));
    try std.testing.expectEqual(@as(usize, 0), try countProductIdentifiersExcept(
        allocator,
        "prepareRecoveredSessionsAtLaunchFromBase",
        &.{"platform/macos/app_session.zig"},
    ));
    try std.testing.expectEqual(@as(usize, 0), try countProductIdentifiersExcept(
        allocator,
        "appendRecoveredSessionRows",
        &.{ "platform/macos/app_session.zig", "platform/macos/app_session/tab.zig" },
    ));
    try std.testing.expectEqual(@as(usize, 0), try countProductIdentifiersExcept(
        allocator,
        "finishDeferredInitialSurface",
        &.{ "platform/macos/app_session.zig", "platform/macos/app_host_abi.zig" },
    ));

    const coordinator = between(app, "fn prepareRecoveredSessionsAtLaunchFromBase(", "pub fn finishDeferredInitialSurface(") orelse return error.TestUnexpectedResult;
    try expectOrdered(coordinator, &.{
        "validateRuntimeBindings",
        "recovery_discovery.discover",
        "ensureRestoreHostAdapter",
        "adapterGeneration",
        "recovery_discovery.collect",
        "replaceRecoveredSessionsProjection",
        "rebuildSidebar",
    });
    try std.testing.expectEqual(@as(usize, 0), count(coordinator, ".adopt("));
    try std.testing.expectEqual(@as(usize, 0), count(coordinator, ".spawn("));
    try std.testing.expectEqual(@as(usize, 0), count(coordinator, ".terminate("));

    inline for (.{
        "maru_macos_app_session_set_primary_window",
        "maru_macos_app_session_prepare_recovered_sessions",
        "maru_macos_app_session_finish_deferred_initial_surface",
    }) |name| {
        try std.testing.expectEqual(@as(usize, 1), count(abi, "pub export fn " ++ name));
        try std.testing.expectEqual(@as(usize, 1), count(header, name ++ "("));
    }
    const launch = between(swift, "let deferInitialSurface = !smokeMode", "if !restoreWorkspace(") orelse return error.TestUnexpectedResult;
    try expectOrdered(launch, &.{
        "deferInitialSurface = !smokeMode",
        "maru_macos_app_session_set_primary_window",
        "maru_macos_app_session_prepare_recovered_sessions",
        "maru_macos_app_session_finish_deferred_initial_surface",
    });
    try std.testing.expect(std.mem.indexOf(u8, persistent, "CR6a-2 구현 계약") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan, "CR6a-2는") != null);

    const gate = between(build, "const session_host_cr6a2_step =", "const session_host_cr6b_step =") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(gate, "\"test-session-host-cr6a2\""));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "session_host_cr6a2_step.dependOn(session_host_cr6a1_step);"));
    try std.testing.expectEqual(@as(usize, 2), count(gate, "--maru-expect-tests=6"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "--maru-expect-tests=1"));
}

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(8 * 1024 * 1024));
}

fn count(haystack: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, haystack, needle);
}

fn between(source: []const u8, start: []const u8, end: []const u8) ?[]const u8 {
    const from = std.mem.indexOf(u8, source, start) orelse return null;
    const to = std.mem.indexOfPos(u8, source, from, end) orelse return null;
    return source[from..to];
}

fn expectOrdered(source: []const u8, needles: []const []const u8) !void {
    var cursor: usize = 0;
    for (needles) |needle| {
        const at = std.mem.indexOfPos(u8, source, cursor, needle) orelse return error.TestUnexpectedResult;
        cursor = at + needle.len;
    }
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

fn countProductIdentifiersExcept(allocator: std.mem.Allocator, identifier: []const u8, excluded: []const []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    var total: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        var skip = false;
        for (excluded) |path| if (std.mem.eql(u8, entry.path, path)) {
            skip = true;
            break;
        };
        if (skip) continue;
        const source = try dir.readFileAlloc(std.testing.io, entry.path, allocator, .limited(8 * 1024 * 1024));
        defer allocator.free(source);
        total += countIdentifier(source, identifier);
    }
    return total;
}
