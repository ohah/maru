//! CR6a-1 derived Recovered Sessions projection boundary.

const std = @import("std");
const posixWalk = @import("support/posix_walk.zig").posixWalk;

test "CR6a-1 경계는 inert projection owner와 caller zero를 고정한다" {
    const allocator = std.testing.allocator;
    const build = try read(allocator, "build.zig");
    defer allocator.free(build);
    const barrel = try read(allocator, "src/platform/macos/session_host.zig");
    defer allocator.free(barrel);
    const projection = try read(allocator, "src/platform/macos/session_host/recovered_sessions_projection.zig");
    defer allocator.free(projection);
    const app = try read(allocator, "src/platform/macos/app_session.zig");
    defer allocator.free(app);
    const remote_runtime = try read(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(remote_runtime);
    const remote_backend = try read(allocator, "src/platform/macos/session_host/remote_term_backend.zig");
    defer allocator.free(remote_backend);
    const persistent = try read(allocator, "docs/persistent-session-host.md");
    defer allocator.free(persistent);
    const plan = try read(allocator, "docs/implementation-plan.md");
    defer allocator.free(plan);

    try std.testing.expectEqual(@as(usize, 1), count(barrel, "@import(\"session_host/recovered_sessions_projection.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(projection, "pub const Projection = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(projection, "pub fn refresh("));
    try std.testing.expectEqual(@as(usize, 0), count(projection, ".attach("));
    try std.testing.expectEqual(@as(usize, 0), count(projection, ".spawn("));
    try std.testing.expectEqual(@as(usize, 0), count(projection, ".terminate("));
    try std.testing.expectEqual(@as(usize, 4), count(projection, "test \"CR6a recovered projection은"));
    try std.testing.expectEqual(@as(usize, 1), count(app, "var app_recovered_sessions_projection:"));
    try std.testing.expectEqual(@as(usize, 1), count(app, "pub fn replaceRecoveredSessionsProjection("));
    try std.testing.expectEqual(@as(usize, 1), count(app, "pub fn recoveredSessionsRows("));
    try std.testing.expectEqual(@as(usize, 1), count(app, "test \"CR6a-1 AppSession은 recovered projection을"));
    // CR6b ended-conflict actual fixture가 canonical Workspace를 다시 투영하는 caller 하나를 더한다.
    try std.testing.expectEqual(@as(usize, 6), countIdentifier(app, "replaceRecoveredSessionsProjection"));
    // CR6a-2 actual launch, CR6b success/failure, CR6c real-host inert/activation fixture가
    // primary projection identity를 직접 관측한다.
    try std.testing.expectEqual(@as(usize, 13), countIdentifier(app, "recoveredSessionsRows"));
    try std.testing.expectEqual(@as(usize, 0), try countProductIdentifiersExcept(
        allocator,
        "replaceRecoveredSessionsProjection",
        &.{"platform/macos/app_session.zig"},
    ));
    // CR6b keyboard Enter와 0-tab header visibility gate가 sidebar module에서 app-global rows를
    // read-only 조회한다(선언 외 identifier 세 곳).
    try std.testing.expectEqual(@as(usize, 3), try countProductIdentifiersExcept(
        allocator,
        "recoveredSessionsRows",
        &.{"platform/macos/app_session.zig"},
    ));
    // CR6c actual Quit은 shared EOF 뒤 일반 detach RPC를 재발행하지 않는 전용 suffix 하나만 연다.
    try std.testing.expectEqual(@as(usize, 1), count(remote_runtime, "pub fn detachClientSideAfterSharedConnectionTerminalized("));
    try std.testing.expectEqual(@as(usize, 1), count(remote_backend, "entry.runtime.detachClientSideAfterSharedConnectionTerminalized();"));
    try std.testing.expectEqual(@as(usize, 0), try countProductIdentifiersExcept(
        allocator,
        "detachClientSideAfterSharedConnectionTerminalized",
        &.{
            "platform/macos/session_host/remote_runtime.zig",
            "platform/macos/session_host/remote_term_backend.zig",
        },
    ));
    try std.testing.expect(std.mem.indexOf(u8, persistent, "CR6a-1 구현 계약") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan, "CR6a-1은") != null);

    const gate = between(build, "const session_host_cr6a1_step =", "const session_host_cr6a2_step =") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(gate, "\"test-session-host-cr6a1\""));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "session_host_cr6a1_step.dependOn(session_host_cr5d2_step);"));
    // 기존 projection 4행과 CR6c real-host inert/activation fixture 4행을 각각 고정한다.
    try std.testing.expectEqual(@as(usize, 2), count(gate, "--maru-expect-tests=4"));
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
