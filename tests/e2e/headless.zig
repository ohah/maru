const std = @import("std");
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
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "printf 'hello maru\\n'" },
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
