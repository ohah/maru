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

test "macOS openpty controlled command reaches SurfaceRuntime snapshot" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const size: maru.terminal.Size = .{ .cols = 40, .rows = 5 };
    var session = try maru.pty.PtySession.spawn(allocator, .{
        .command = "/bin/sh",
        .args = &.{ "-c", "printf 'runtime pty maru\\n'" },
        .size = size,
    });
    defer session.deinit();

    var surface = try maru.app.Surface.init(allocator, 1, size);
    defer surface.deinit();
    surface.title = "runtime pty";
    surface.command = "/bin/sh -c printf";

    var runtime = maru.app.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    _ = try runtime.attach(&surface, 10, maru.app.PtyIo.fromSession(&session));

    const raw = try driveRuntimeUntilExit(allocator, &session, &runtime, 10);
    defer allocator.free(raw.bytes);

    try std.testing.expectEqual(maru.pty.ExitStatus{ .exited = 0 }, raw.exit_status);
    try std.testing.expectEqual(maru.app.ProcessState.exited, surface.process_state);
    try std.testing.expect(std.mem.indexOf(u8, raw.bytes, "runtime pty maru") != null);

    const screen = try surface.core.dumpUtf8(allocator);
    defer allocator.free(screen);
    try std.testing.expect(std.mem.indexOf(u8, screen, "runtime pty maru") != null);

    try artifacts.writeText(
        "tests/artifacts/integration/pty/runtime-controlled-command.raw.txt",
        raw.bytes,
    );
    try artifacts.writeTextWithFinalNewline(
        allocator,
        "tests/artifacts/integration/pty/runtime-controlled-command.screen.txt",
        screen,
    );

    const snapshot = try maru.observability.snapshot.renderTerminalSnapshot(allocator, surface.core.snapshot());
    defer allocator.free(snapshot);
    try artifacts.writeText(
        "tests/artifacts/integration/pty/runtime-controlled-command.snapshot.txt",
        snapshot,
    );

    const metadata = try renderSurfaceMetadata(allocator, surface.restorableMetadata());
    defer allocator.free(metadata);
    try artifacts.writeText(
        "tests/artifacts/integration/pty/runtime-controlled-command.surface.txt",
        metadata,
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

fn driveRuntimeUntilExit(
    allocator: std.mem.Allocator,
    session: *maru.pty.PtySession,
    runtime: *maru.app.SurfaceRuntime,
    pty_id: maru.app.PtyId,
) !CollectedOutput {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);

    while (true) {
        const event = try session.readEvent(allocator);
        defer event.deinit(allocator);

        switch (event) {
            .output => |chunk| {
                // 이 helper는 실제 reader thread가 생기기 전의 headless 대체 경로다.
                // PTY backend가 만든 raw bytes를 SurfaceRuntime의 public event로만 넣어,
                // 테스트가 private TerminalCore storage를 우회하지 않게 한다.
                try bytes.appendSlice(allocator, chunk);
                try runtime.applyPtyEvent(.{ .output = .{
                    .pty_id = pty_id,
                    .bytes = chunk,
                } });
            },
            .exited => |status| {
                try runtime.applyPtyEvent(.{ .exited = .{
                    .pty_id = pty_id,
                    .status = status,
                } });
                return .{
                    .bytes = try bytes.toOwnedSlice(allocator),
                    .exit_status = status,
                };
            },
        }
    }
}

fn renderSurfaceMetadata(
    allocator: std.mem.Allocator,
    metadata: maru.app.RestorableSurfaceMetadata,
) ![]u8 {
    // Snapshot은 terminal grid를 보여주고, 이 작은 metadata artifact는
    // workspace restore가 저장 가능한 surface state만 보게 됐는지 확인한다.
    // live PTY handle이나 env 값이 여기에 나오면 책임 경계가 깨진 것이다.
    return std.fmt.allocPrint(
        allocator,
        \\surface.id={d}
        \\surface.title={s}
        \\surface.cwd={s}
        \\surface.command={s}
        \\surface.size.cols={d}
        \\surface.size.rows={d}
        \\surface.process_state={s}
        \\surface.env.len={d}
        \\
    ,
        .{
            metadata.id,
            metadata.title,
            metadata.cwd orelse "null",
            metadata.command orelse "null",
            metadata.size.cols,
            metadata.size.rows,
            @tagName(metadata.process_state),
            metadata.env.len,
        },
    );
}
