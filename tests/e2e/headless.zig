const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const artifacts = @import("test_support");

// Headless E2E exists before GUI E2E because terminal bugs are easiest to
// debug from the bottom up. If this test fails, the beginner-friendly mental
// model is: "a real command produced bytes, but our core did not turn those
// bytes into the expected screen text." That narrows the bug to process I/O or
// TerminalCore instead of AppKit, Metal, fonts, and input all at once.
test "headless E2E feeds real command stdout into TerminalCore" {
    // This is the first E2E layer on purpose: it runs a real process, captures
    // real stdout bytes, and feeds them into Maru's terminal core. It does not
    // require PTY, AppKit, Metal, or screenshots, so a failure points at either
    // process I/O or terminal-core state instead of the whole app at once.
    const allocator = std.testing.allocator;
    // **셸 이름을 호스트에서 고른다.** `/bin/sh` 를 박아 두면 Windows 에서 `FileNotFound` 로 죽고,
    // 그러면 이 층이 재는 것("진짜 프로세스의 바이트가 코어를 지나 화면이 된다")을 그 호스트에서는
    // 통째로 못 잰다 — 게이트가 상시 빨개져 **진짜 실패와 구별이 안 된다**(§2m.108).
    // `cmd` 는 CRLF 를 내지만 CR 은 코어가 캐리지 리턴으로 먹으므로 화면 글자는 같다.
    const argv: []const []const u8 = if (builtin.os.tag == .windows)
        &.{ "cmd.exe", "/c", "echo hello maru" }
    else
        &.{ "/bin/sh", "-c", "printf 'hello maru\\n'" };
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = argv,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.ChildProcessDidNotExitCleanly,
    }

    var core = try maru.terminal.TerminalCore.init(allocator, .{ .cols = 40, .rows = 5 });
    defer core.deinit();

    try core.write(result.stdout);

    const screen = try core.dumpUtf8(allocator);
    defer allocator.free(screen);

    try artifacts.writeTextWithFinalNewline(
        allocator,
        "tests/artifacts/e2e/headless/hello-maru.screen.txt",
        screen,
    );

    const snapshot = try maru.observability.snapshot.renderTerminalSnapshot(allocator, core.snapshot());
    defer allocator.free(snapshot);

    try artifacts.writeText(
        "tests/artifacts/e2e/headless/hello-maru.snapshot.txt",
        snapshot,
    );

    try artifacts.writeText(
        "tests/artifacts/e2e/headless/hello-maru.stdout.txt",
        result.stdout,
    );

    try std.testing.expect(std.mem.indexOf(u8, screen, "hello maru") != null);
}
