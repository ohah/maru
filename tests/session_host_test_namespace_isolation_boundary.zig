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
    const signed_upgrade = try readSource(allocator, "tests/session_host_signed_upgrade_e2e.zig");
    defer allocator.free(signed_upgrade);

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
    // signed product E2E 자체는 `builtin.is_test == false`로 컴파일된다. 따라서 parent가
    // current-user helper를 부르면 실제 앱 root로 빠지며, exact isolated root helper만 허용한다.
    try std.testing.expect(std.mem.indexOf(u8, signed_upgrade, "socketDirPathUnder") != null);
    try std.testing.expect(std.mem.indexOf(u8, signed_upgrade, "socketPathUnder") != null);
    try std.testing.expect(std.mem.indexOf(u8, signed_upgrade, "prepareCurrentUserNamespace") == null);
    try std.testing.expect(std.mem.indexOf(u8, signed_upgrade, "currentSocketPathIn") == null);
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

test "macOS product smoke children bind workspace and session registry to one fixture root" {
    const allocator = std.testing.allocator;
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);
    const instance_lease = try readSource(allocator, "tools/test-macos-app-instance-lease.sh");
    defer allocator.free(instance_lease);
    const archive = try readSource(allocator, "tools/test-macos-agent-session-archive.sh");
    defer allocator.free(archive);
    const browser = try readSource(allocator, "tools/test-macos-browser-bounded-smoke.sh");
    defer allocator.free(browser);

    try std.testing.expect(std.mem.indexOf(
        u8,
        build,
        "fn isolateMacosProductTest(b: *std.Build, run: *std.Build.Step.Run, home: []const u8, tag: []const u8) void",
    ) != null);
    // **pid 계열을 `build.zig` 에서 부르지 않는다.** `std.c.getpid` 든 `std.posix.system.getpid` 든
    // 참조하는 순간 빌드 스크립트가 libc 를 명시적으로 요구하고(`error: dependency on libc must be
    // explicitly specified`), 그 함수가 macOS 전용인 것과 무관하게 **`build.zig` 를 읽는 모든 호스트**가
    // 그 참조를 컴파일한다 — Windows 러너가 없어 CI 는 못 보고 로컬 Windows 빌드가 `zig build` 부터
    // 죽는다(실측 2026-08-31). 필요한 것은 "이 빌드 프로세스만의 자리" 하나뿐이라 이식성 있는
    // 식별자를 쓴다. 그래서 **요구하는 쪽이 `getCurrentId`, 막는 쪽이 pid 계열 둘 다**이다.
    try std.testing.expect(std.mem.indexOf(u8, build, "std.Thread.getCurrentId()") != null);
    try std.testing.expect(std.mem.indexOf(u8, build, "std.c.getpid()") == null);
    try std.testing.expect(std.mem.indexOf(u8, build, "std.posix.system.getpid()") == null);
    const product_smokes = [_][]const u8{
        "macos_divider_smoke",
        "macos_scrollbar_smoke",
        "macos_tab_drag_smoke",
        "run_session_host_r2a_checkpoint",
        "run_session_host_r1_tombstone",
        "run_session_host_cr6c_appkit",
        "run_session_host_cr6d_appkit",
        "run_session_host_cr6e_recovery",
        "run_session_host_cr6e_c3c",
        "macos_app_smoke",
        "macos_app_html_smoke",
    };
    for (product_smokes) |name| {
        const needle = try std.fmt.allocPrint(
            allocator,
            "isolateMacosProductTest(b, {s}, b.pathFromRoot(",
            .{name},
        );
        defer allocator.free(needle);
        try std.testing.expect(std.mem.indexOf(u8, build, needle) != null);
    }
    // C4는 한 shell 안에서 서로 다른 두 home을 실행하므로 각 exec 앞에서 세 변수를 다시 묶는다.
    try std.testing.expect(std.mem.indexOf(
        u8,
        build,
        "HOME=\\\"$success_root\\\" CFFIXED_USER_HOME=\\\"$success_root\\\" MARU_SESSION_HOST_ROOT=\\\"$success_session_root\\\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        build,
        "HOME=\\\"$root\\\" CFFIXED_USER_HOME=\\\"$root\\\" MARU_SESSION_HOST_ROOT=\\\"$session_root\\\" ./zig-out/Maru.app",
    ) != null);

    try std.testing.expect(std.mem.indexOf(u8, instance_lease, "mktemp -d \"/tmp/maru-app-instance-lease.XXXXXX\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, instance_lease, "MARU_SESSION_HOST_ROOT=\"$session_root\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "mktemp -d \"/tmp/maru-agent-session-archive.XXXXXX\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "MARU_SESSION_HOST_ROOT=\"$session_root\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, browser, "mktemp -d \"/tmp/maru-browser-bounded-smoke.XXXXXX\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, browser, "MARU_SESSION_HOST_ROOT=\"$test_root/session-host-root\"") != null);
    // HOME-derived workspace paths can be long; they must never double as a Unix socket root.
    for ([_][]const u8{ instance_lease, archive }) |script| {
        try std.testing.expect(std.mem.indexOf(u8, script, "MARU_SESSION_HOST_ROOT=\"$home\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, script, "MARU_SESSION_HOST_ROOT=\"$test_home\"") == null);
    }
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
