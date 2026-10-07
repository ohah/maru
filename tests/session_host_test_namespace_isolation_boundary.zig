//! Session-host tests must never borrow the live per-UID namespace.
//!
//! A Zig test process gets a PID-scoped root, but a product executable started by that process is
//! compiled with `builtin.is_test == false`. Without an explicit root in the launcher contract it
//! silently falls back to `/tmp/maru-<uid>` and can make the real app's discovery ambiguous.

const std = @import("std");
const build_source = @import("support/build_source.zig");

test "product-child fixtures require an isolated root and the default suite never injects the live uid root" {
    const allocator = std.testing.allocator;
    const build = try build_source.read(allocator);
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
    try std.testing.expect(std.mem.indexOf(
        u8,
        runner,
        "if (setenv(\"HOME\", made, 1) != 0)",
    ) != null);
    // 임시 홈은 실행마다 새로 만든다(`mkdtemp`). 있던 자리(`EEXIST`)를 받아들이면 pid 재사용 때 이전 실행의 캐시를
    // 물려받고, 다른 사용자가 미리 둔 디렉터리·심볼릭 링크를 홈으로 쓴다.
    try std.testing.expect(std.mem.indexOf(u8, runner, "mkdtemp(template.ptr) orelse return isolationFail(\"mkdtemp\")") != null);
    // exec 전에 「고친 환경이면 다시 exec 할 일이 없다」를 확인한다 — 판정과 고침이 어긋나면 끝없는 self-exec 가 된다
    // (`HOME=/` 에서 실제로 그랬다, 2026-10-07). 판정 함수 자체는 `tools/test_runner_home.zig` 의 판정자가 본다.
    try std.testing.expect(std.mem.indexOf(u8, runner, "if (homeIsRealUserHome()) return isolationFail(") != null);
    try std.testing.expect(std.mem.indexOf(u8, runner, "if (homeUnusable() or xdgNeedsIsolation()) return isolationFail(") != null);
    // 빈 값·루트 HOME 은 실제 홈처럼 새 임시 홈으로 바꾼다 — 루트는 실제 캐시 XDG 까지 「홈 아래」로 읽어 샜다(2026-10-07).
    try std.testing.expect(std.mem.indexOf(u8, runner, "const replace_home = homeIsRealUserHome() or homeUnusable();") != null);
    try std.testing.expect(std.mem.indexOf(u8, runner, "const runner_home = @import(\"test_runner_home.zig\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, runner, "std.c.E.EXIST") == null);
    // 시작 뒤 setenv 만으로는 std 가 붙잡은 envp 조각이 실제 홈을 계속 본다 — 그 환경으로 다시 exec 해야 한다.
    try std.testing.expect(std.mem.indexOf(u8, runner, "_ = std.c.execve(@ptrCast(&exe_buf), _NSGetArgv().*, environ);") != null);
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

// 제품 자식은 `HOME` 에서 캐시를 유도한다 — 러너가 실제 홈을 안 바꾸던 동안 테스트가 띄운 `maru __session-host` 가
// 실제 `~/.cache/maru/agent-turn-events/` 에 칸을 만들고 그 안을 정리했다(2026-10-04 가짜 HOME 실측: 136 항목).
// 이 판정자는 **이 프로세스가 받은 환경**을 본다 — 자식은 그것을 그대로 물려받는다.
test "common runner never leaves the real user HOME to tests or their product children" {
    if (@import("builtin").os.tag != .macos) return;

    const home = std.mem.span(std.c.getenv("HOME") orelse return error.MissingHome);
    const pw = std.c.getpwuid(std.c.getuid()) orelse return error.MissingPasswdEntry;
    const real = std.mem.span(pw.dir orelse return error.MissingPasswdEntry);
    try std.testing.expect(!std.mem.eql(u8, std.mem.trimEnd(u8, home, "/"), std.mem.trimEnd(u8, real, "/")));

    // HOME 은 session root 와 다른 자리다 — root 안에는 session host 의 것만 둔다.
    if (std.c.getenv("MARU_SESSION_HOST_ROOT")) |root| {
        try std.testing.expect(!std.mem.eql(u8, std.mem.trimEnd(u8, home, "/"), std.mem.trimEnd(u8, std.mem.span(root), "/")));
    }
    // 네 XDG_* 는 **언제나 설정돼 있고** 지금 HOME 아래다 — 러너가 HOME 을 바꾼 경우만이 아니다. 예전에는 fixture home 을
    // 받은 스텝이 셸의 실제 `XDG_CACHE_HOME` 을 그대로 물려받았다(2026-10-06 재현). **비어 있어도 채운다** — login(1) 래퍼는
    // HOME 을 실제 홈으로 되돌리지만 XDG 는 지키므로, 비어 있던 XDG 는 그 셸 안에서 실제 홈으로 유도된다. 그리고 비어 있는
    // 것을 건너뛰면 이 판정은 XDG 를 안 두는 CI 러너에서 **아무것도 안 본다**(적대적 검증 2026-10-07).
    // 판정 함수(`tools/test_runner_home.zig` 의 `pathUnder`)는 그 파일의 판정자가 따로 본다 — 러너가 그 파일을 import 해
    // 이 모듈에 다시 넣을 수 없다(「file exists in modules」). 여기서는 결과를 칸 단위로 다시 센다.
    const home_dir = std.mem.trimEnd(u8, home, "/");
    for ([_][*:0]const u8{ "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME" }) |name| {
        const value = std.mem.trimEnd(u8, std.mem.span(std.c.getenv(name) orelse return error.XdgUnset), "/");
        try std.testing.expect(std.mem.startsWith(u8, value, home_dir));
        try std.testing.expect(value.len == home_dir.len or value[home_dir.len] == '/');
    }
    // 러너가 세운 임시 홈이면 **이 실행이 새로 만든 자리**다 — 이 사용자 소유의 0700 디렉터리이고 심볼릭 링크가 아니며,
    // 이름에 pid 뒤 무작위 꼬리가 붙는다(`mkdtemp`). 예전에는 `/tmp/maru-home-<pid>` 의 `EEXIST` 를 받아들여 pid 재사용 때
    // 이전 실행의 캐시를 물려받았고, 다른 사용자가 미리 둔 디렉터리·링크도 그대로 홈으로 썼다.
    var prefix_buf: [64]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "/tmp/maru-home-{d}", .{std.c.getpid()});
    if (std.mem.startsWith(u8, home, prefix)) {
        try std.testing.expect(home.len > prefix.len + 1 and home[prefix.len] == '-');
        var home_z_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const home_z = try std.fmt.bufPrintZ(&home_z_buf, "{s}", .{home});
        var info: std.posix.Stat = undefined;
        try std.testing.expectEqual(@as(c_int, 0), std.c.fstatat(std.posix.AT.FDCWD, home_z.ptr, &info, std.posix.AT.SYMLINK_NOFOLLOW));
        try std.testing.expect(std.posix.S.ISDIR(info.mode));
        try std.testing.expectEqual(std.c.getuid(), info.uid);
        try std.testing.expectEqual(@as(@TypeOf(info.mode), 0o700), info.mode & 0o777);
    }
}

test "macOS product smoke children bind workspace and session registry to one fixture root" {
    const allocator = std.testing.allocator;
    const build = try build_source.read(allocator);
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
    // CR6d uses a /tmp artifact HOME to keep Documents TCC out of actual IME testing.
    // Its path is already absolute, but the same isolation owner must still bind the registry.
    try std.testing.expect(std.mem.indexOf(
        u8,
        build,
        "isolateMacosProductTest(b, run_session_host_cr6d_appkit, session_host_cr6d_home, \"cr6d\")",
    ) != null);
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
