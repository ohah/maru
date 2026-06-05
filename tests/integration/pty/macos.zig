const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const artifacts = @import("test_support");

// These tests are opt-in because they touch the real macOS PTY subsystem and
// child process lifecycle. The purpose is not to test shell syntax; it is to
// prove that Maru can run a controlled command through a real terminal device
// and still produce the same core/snapshot artifacts used by headless tests.

test "macOS openpty controlled command reaches TerminalCore snapshot" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var session = try maru.pty.PtySession.spawn(allocator, .{
        .command = "/bin/sh",
        .args = &.{ "-c", "printf 'pty maru\\n'" },
        .size = .{ .cols = 40, .rows = 5 },
    });
    defer session.deinit();

    const raw = try collectUntilExit(allocator, &session);
    defer allocator.free(raw.bytes);

    try std.testing.expectEqual(maru.pty.ExitStatus{ .exited = 0 }, raw.exit_status);
    try std.testing.expect(std.mem.indexOf(u8, raw.bytes, "pty maru") != null);

    var core = try maru.terminal.TerminalCore.init(allocator, .{ .cols = 40, .rows = 5 });
    defer core.deinit();
    try core.write(raw.bytes);

    const screen = try core.dumpUtf8(allocator);
    defer allocator.free(screen);
    try std.testing.expect(std.mem.indexOf(u8, screen, "pty maru") != null);

    try artifacts.writeText(
        "tests/artifacts/integration/pty/controlled-command.raw.txt",
        raw.bytes,
    );
    try artifacts.writeTextWithFinalNewline(
        allocator,
        "tests/artifacts/integration/pty/controlled-command.screen.txt",
        screen,
    );

    const snapshot = try maru.observability.snapshot.renderTerminalSnapshot(allocator, core.snapshot());
    defer allocator.free(snapshot);
    try artifacts.writeText(
        "tests/artifacts/integration/pty/controlled-command.snapshot.txt",
        snapshot,
    );
}

test "macOS PTY resize is visible to the child terminal" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var session = try maru.pty.PtySession.spawn(allocator, .{
        .command = "/bin/sh",
        .args = &.{ "-c", "read line; stty size; printf 'done\\n'" },
        .size = .{ .cols = 20, .rows = 8 },
    });
    defer session.deinit();

    try session.resize(.{ .cols = 42, .rows = 13 });
    try std.testing.expectEqual(maru.terminal.Size{ .cols = 42, .rows = 13 }, try session.currentSize());
    try session.writeInput("\n");

    const raw = try collectUntilExit(allocator, &session);
    defer allocator.free(raw.bytes);

    try std.testing.expectEqual(maru.pty.ExitStatus{ .exited = 0 }, raw.exit_status);
    try std.testing.expect(std.mem.indexOf(u8, raw.bytes, "13 42") != null);

    try artifacts.writeText(
        "tests/artifacts/integration/pty/resize.raw.txt",
        raw.bytes,
    );
}

test "macOS PTY close reaps a signal-ignoring child without leaking a zombie" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var session = try maru.pty.PtySession.spawn(allocator, .{
        // The child ignores HUP and TERM and would otherwise sleep for 30s, so a
        // correct close must escalate to SIGKILL and still reap it promptly.
        .command = "/bin/sh",
        .args = &.{ "-c", "trap '' HUP TERM; sleep 30" },
        .size = .{ .cols = 20, .rows = 8 },
    });
    const child_pid = session.child_pid;

    session.deinit();

    // The child must have been reaped during close: waitpid on a reaped pid
    // fails with ECHILD. A leftover zombie would instead return the pid, and a
    // still-running child would return 0 (WNOHANG keeps this from blocking).
    var status: c_int = 0;
    const rc = std.c.waitpid(child_pid, &status, std.c.W.NOHANG);
    try std.testing.expect(rc < 0);
}

const CollectedOutput = struct {
    bytes: []u8,
    exit_status: maru.pty.ExitStatus,
};

fn collectUntilExit(allocator: std.mem.Allocator, session: *maru.pty.PtySession) !CollectedOutput {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);

    while (true) {
        const event = try session.readEvent(allocator);
        defer event.deinit(allocator);

        switch (event) {
            .output => |chunk| try bytes.appendSlice(allocator, chunk),
            .exited => |status| return .{
                .bytes = try bytes.toOwnedSlice(allocator),
                .exit_status = status,
            },
        }
    }
}
