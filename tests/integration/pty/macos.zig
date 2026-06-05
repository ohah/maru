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
    // Write the raw PTY bytes first so the PTY-layer evidence survives a later
    // core-write failure or a failing assertion below.
    try artifacts.writeText(
        "tests/artifacts/integration/pty/controlled-command.raw.txt",
        raw.bytes,
    );

    var core = try maru.terminal.TerminalCore.init(allocator, .{ .cols = 40, .rows = 5 });
    defer core.deinit();
    try core.write(raw.bytes);

    const screen = try core.dumpUtf8(allocator);
    defer allocator.free(screen);
    const snapshot = try maru.observability.snapshot.renderTerminalSnapshot(allocator, core.snapshot());
    defer allocator.free(snapshot);

    // Derived artifacts are written before the content assertions so a failing
    // run still leaves the screen and snapshot on disk to diagnose.
    try artifacts.writeTextWithFinalNewline(
        allocator,
        "tests/artifacts/integration/pty/controlled-command.screen.txt",
        screen,
    );
    try artifacts.writeText(
        "tests/artifacts/integration/pty/controlled-command.snapshot.txt",
        snapshot,
    );

    try std.testing.expectEqual(maru.pty.ExitStatus{ .exited = 0 }, raw.exit_status);
    try std.testing.expect(std.mem.indexOf(u8, raw.bytes, "pty maru") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, "pty maru") != null);
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

    var queue = try maru.app.PtyEventQueue.init(std.testing.io, allocator, 1);
    defer queue.deinit();
    var reader = maru.app.PtyReader.init(allocator, 10, &session, &queue);
    try reader.start();
    defer reader.join();
    defer queue.close();

    const raw = try drainRuntimeQueueUntilExit(allocator, &queue, &runtime);
    defer allocator.free(raw.bytes);
    // Write raw PTY bytes first so the PTY-layer evidence survives any later
    // failure in routing, core, or the assertions below.
    try artifacts.writeText(
        "tests/artifacts/integration/pty/runtime-controlled-command.raw.txt",
        raw.bytes,
    );

    const screen = try surface.core.dumpUtf8(allocator);
    defer allocator.free(screen);
    const snapshot = try maru.observability.snapshot.renderTerminalSnapshot(allocator, surface.core.snapshot());
    defer allocator.free(snapshot);
    const metadata = try renderSurfaceMetadata(allocator, surface.restorableMetadata());
    defer allocator.free(metadata);

    // Derived artifacts are written before the content assertions so a failing
    // run still leaves the screen, snapshot, and surface metadata to diagnose.
    try artifacts.writeTextWithFinalNewline(
        allocator,
        "tests/artifacts/integration/pty/runtime-controlled-command.screen.txt",
        screen,
    );
    try artifacts.writeText(
        "tests/artifacts/integration/pty/runtime-controlled-command.snapshot.txt",
        snapshot,
    );
    try artifacts.writeText(
        "tests/artifacts/integration/pty/runtime-controlled-command.surface.txt",
        metadata,
    );

    try std.testing.expectEqual(maru.pty.ExitStatus{ .exited = 0 }, raw.exit_status);
    try std.testing.expectEqual(maru.app.ProcessState.exited, surface.process_state);
    try std.testing.expect(std.mem.indexOf(u8, raw.bytes, "runtime pty maru") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, "runtime pty maru") != null);
}

test "macOS PTY reader and pump preserve large stdout through a bounded queue" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const expected_lines: usize = 2048;
    const size: maru.terminal.Size = .{ .cols = 32, .rows = 8 };
    const command = try std.fmt.allocPrint(
        allocator,
        "i=0; while [ \"$i\" -lt {d} ]; do printf 'pty-stress-%04d\\n' \"$i\"; i=$((i + 1)); done",
        .{expected_lines},
    );
    defer allocator.free(command);

    var session = try maru.pty.PtySession.spawn(allocator, .{
        .command = "/bin/sh",
        .args = &.{ "-c", command },
        .size = size,
    });
    defer session.deinit();

    var surface = try maru.app.Surface.init(allocator, 1, size);
    defer surface.deinit();
    surface.title = "runtime pty stress";
    surface.command = "/bin/sh -c pty-stress";

    var runtime = maru.app.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    _ = try runtime.attach(&surface, 10, maru.app.PtyIo.fromSession(&session));

    var queue = try maru.app.PtyEventQueue.init(std.testing.io, allocator, 1);
    defer queue.deinit();
    var reader = maru.app.PtyReader.init(allocator, 10, &session, &queue);
    try reader.start();
    defer reader.join();
    defer queue.close();

    const raw = try drainRuntimeQueueUntilExit(allocator, &queue, &runtime);
    defer allocator.free(raw.bytes);

    const marker_count = countOccurrences(raw.bytes, "pty-stress-");
    const expected_last_line = try std.fmt.allocPrint(allocator, "pty-stress-{d}", .{expected_lines - 1});
    defer allocator.free(expected_last_line);

    try artifacts.writeText(
        "tests/artifacts/integration/pty/runtime-backpressure.raw.txt",
        raw.bytes,
    );

    const screen = try surface.core.dumpUtf8(allocator);
    defer allocator.free(screen);
    const snapshot = try maru.observability.snapshot.renderTerminalSnapshot(allocator, surface.core.snapshot());
    defer allocator.free(snapshot);
    const summary = try renderPtyStressSummary(allocator, .{
        .expected_lines = expected_lines,
        .marker_count = marker_count,
        .raw_bytes = raw.bytes.len,
        .output_events = raw.output_events,
        .queue_capacity = queue.capacity(),
    });
    defer allocator.free(summary);

    // Stress artifacts are written before assertions so a failure shows whether
    // bytes were lost before the queue, during pump drain, or inside TerminalCore.
    try artifacts.writeTextWithFinalNewline(
        allocator,
        "tests/artifacts/integration/pty/runtime-backpressure.screen.txt",
        screen,
    );
    try artifacts.writeText(
        "tests/artifacts/integration/pty/runtime-backpressure.snapshot.txt",
        snapshot,
    );
    try artifacts.writeText(
        "tests/artifacts/integration/pty/runtime-backpressure.summary.txt",
        summary,
    );

    try std.testing.expectEqual(maru.pty.ExitStatus{ .exited = 0 }, raw.exit_status);
    try std.testing.expectEqual(expected_lines, marker_count);
    try std.testing.expect(raw.output_events > 1);
    try std.testing.expectEqual(maru.app.ProcessState.exited, surface.process_state);
    try std.testing.expect(std.mem.indexOf(u8, screen, expected_last_line) != null);
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
    // Write the raw bytes before asserting so a failing run still shows what the
    // child reported for `stty size`.
    try artifacts.writeText(
        "tests/artifacts/integration/pty/resize.raw.txt",
        raw.bytes,
    );

    try std.testing.expectEqual(maru.pty.ExitStatus{ .exited = 0 }, raw.exit_status);
    try std.testing.expect(std.mem.indexOf(u8, raw.bytes, "13 42") != null);
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
    output_events: usize,
};

fn collectUntilExit(allocator: std.mem.Allocator, session: *maru.pty.PtySession) !CollectedOutput {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    var output_events: usize = 0;

    while (true) {
        const event = try session.readEvent(allocator);
        defer event.deinit(allocator);

        switch (event) {
            .output => |chunk| {
                output_events += 1;
                try bytes.appendSlice(allocator, chunk);
            },
            .exited => |status| return .{
                .bytes = try bytes.toOwnedSlice(allocator),
                .exit_status = status,
                .output_events = output_events,
            },
        }
    }
}

fn drainRuntimeQueueUntilExit(
    allocator: std.mem.Allocator,
    queue: *maru.app.PtyEventQueue,
    runtime: *maru.app.SurfaceRuntime,
) !CollectedOutput {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    var pump = maru.app.RuntimeEventPump.init(allocator, queue, runtime);
    var output_events: usize = 0;

    while (true) {
        const event = queue.popBlocking() orelse return error.ReaderQueueClosedBeforeExit;
        const exit_status: ?maru.pty.ExitStatus = switch (event) {
            .output => |output| blk: {
                // 테스트는 raw PTY artifact를 남기기 위해 output bytes를 복사한다.
                // event 적용과 event 해제는 제품 코드인 RuntimeEventPump에 맡겨
                // 테스트 전용 ownership 규칙이 따로 생기지 않게 한다.
                output_events += 1;
                try bytes.appendSlice(allocator, output.bytes);
                break :blk null;
            },
            .exited => |exited| exited.status,
            .read_error => null,
        };

        _ = try pump.applyQueuedEvent(event);
        if (exit_status) |status| {
            return .{
                .bytes = try bytes.toOwnedSlice(allocator),
                .exit_status = status,
                .output_events = output_events,
            };
        }
    }
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    std.debug.assert(needle.len > 0);

    var count: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOf(u8, haystack[offset..], needle)) |relative| {
        count += 1;
        offset += relative + needle.len;
    }
    return count;
}

const PtyStressSummary = struct {
    expected_lines: usize,
    marker_count: usize,
    raw_bytes: usize,
    output_events: usize,
    queue_capacity: usize,
};

fn renderPtyStressSummary(
    allocator: std.mem.Allocator,
    summary: PtyStressSummary,
) ![]u8 {
    // Summary는 screen/snapshot만으로 보이지 않는 backpressure 단서를 남긴다.
    // queue capacity와 output event 수가 있어야 대량 출력 실패가 drop인지,
    // chunking인지, runtime 적용 문제인지 좁혀 볼 수 있다.
    return std.fmt.allocPrint(
        allocator,
        \\expected_lines={d}
        \\marker_count={d}
        \\raw_bytes={d}
        \\output_events={d}
        \\queue_capacity={d}
        \\
    ,
        .{
            summary.expected_lines,
            summary.marker_count,
            summary.raw_bytes,
            summary.output_events,
            summary.queue_capacity,
        },
    );
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
