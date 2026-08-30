//! Session-host tests must never borrow the live per-UID namespace.
//!
//! A Zig test process gets a PID-scoped root, but a product executable started by that process is
//! compiled with `builtin.is_test == false`. Without an explicit root in the launcher contract it
//! silently falls back to `/tmp/maru-<uid>` and can make the real app's discovery ambiguous.

const std = @import("std");

test "product-child fixtures require an isolated root and the default suite never injects the live uid root" {
    const allocator = std.testing.allocator;
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);
    const launcher = try readSource(allocator, "src/platform/macos/session_host/launcher.zig");
    defer allocator.free(launcher);
    const runner = try readSource(allocator, "tools/simple_test_runner.zig");
    defer allocator.free(runner);

    try std.testing.expect(std.mem.indexOf(
        u8,
        launcher,
        "pub fn spawnSessionHostSupervisedForTest(\n    allocator: std.mem.Allocator,\n    isolated_root: [:0]const u8,",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        launcher,
        "MARU_SESSION_HOST_ROOT={s}",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        launcher,
        "error.SharedUserNamespace",
    ) != null);
    // 문자열 prefix만 보는 RED는 `..`·symlink가 실제 사용자 root로 해석되는 우회를 놓친다.
    try std.testing.expect(std.mem.indexOf(u8, launcher, "posix.AT.SYMLINK_NOFOLLOW") != null);
    try std.testing.expect(std.mem.indexOf(u8, launcher, "c.realpath(isolated_root.ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, launcher, "const tmp_prefix = \"/tmp/\";") != null);
    // root가 안전해도 child suffix의 `..`·빈 component를 허용하면 다시 공용 root로 빠질 수 있다.
    try std.testing.expect(std.mem.indexOf(u8, launcher, "path[root.len + 1 ..]") != null);
    try std.testing.expect(std.mem.indexOf(u8, launcher, "std.mem.eql(u8, component, \"..\")") != null);
    // execve는 fork 뒤 unsetenv가 아니라 fork 전에 만든 envp를 전달하므로 그 배열 자체가 정화돼야 한다.
    try std.testing.expect(std.mem.indexOf(u8, launcher, "isSessionHostTestEnvironmentAssignment(text)") != null);
    // 병렬 테스트가 같은 고정 디렉터리를 chmod/rmdir해서는 안 된다.
    try std.testing.expect(std.mem.indexOf(u8, launcher, "\"/tmp/maru-supervised-test-isolated\"") == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        build,
        "b.fmt(\"/tmp/maru-{d}\", .{std.c.getuid()})",
    ) == null);
    // runner가 root env 주입 실패를 무시하면 product child만 공용 UID namespace로 돌아간다.
    try std.testing.expect(std.mem.indexOf(
        u8,
        runner,
        "isolateSessionHostRoot() catch std.process.exit(1)",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        runner,
        "if (setenv(\"MARU_SESSION_HOST_ROOT\", root.ptr, 1) != 0)",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        runner,
        "inherited roots are untrusted",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        runner,
        "if (setenv(\"CFFIXED_USER_HOME\", root.ptr, 1) != 0)",
    ) != null);
}

test "common runner binds session registry and app workspace to the same pid root" {
    if (@import("builtin").os.tag != .macos) return;

    const session_root = std.c.getenv("MARU_SESSION_HOST_ROOT") orelse
        return error.MissingSessionHostRoot;
    const app_home = std.c.getenv("CFFIXED_USER_HOME") orelse
        return error.MissingFixedUserHome;
    var expected_buf: [64]u8 = undefined;
    const expected = try std.fmt.bufPrintZ(&expected_buf, "/tmp/maru-t{d}", .{std.c.getpid()});

    try std.testing.expectEqualStrings(expected, std.mem.span(session_root));
    try std.testing.expectEqualStrings(expected, std.mem.span(app_home));
}

test "default product fixtures do not reconstruct uid-keyed sockets" {
    const allocator = std.testing.allocator;
    const app_session = try readSource(allocator, "src/platform/macos/app_session.zig");
    defer allocator.free(app_session);
    const shutdown = try readSource(
        allocator,
        "src/platform/macos/session_host/shutdown_admin_connector.zig",
    );
    defer allocator.free(shutdown);

    try std.testing.expect(std.mem.indexOf(u8, app_session, "socketDirPathIn(&socket_dir_buf, std.c.getuid())") == null);
    try std.testing.expect(std.mem.indexOf(u8, app_session, "socketPathIn(&socket_buf, std.c.getuid(), host_id)") == null);
    try std.testing.expect(std.mem.indexOf(u8, shutdown, "**이 테스트만 uid 기준 공용 socket 을 쓴다.**") == null);

    const endpoint = try readSource(
        allocator,
        "src/platform/macos/session_host/short_endpoint.zig",
    );
    defer allocator.free(endpoint);
    try std.testing.expect(std.mem.indexOf(
        u8,
        endpoint,
        "currentLoginUserOwnsSharedNamespace()",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        endpoint,
        "if (currentLoginUserOwnsSharedNamespace()) return error.SharedUserNamespace;",
    ) != null);
}

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(16 * 1024 * 1024));
}
