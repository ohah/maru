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

test "macOS interactive shell accepts scripted input through a real PTY" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const size: maru.terminal.Size = .{ .cols = 50, .rows = 8 };
    const marker = "MARU_INTERACTIVE_SHELL_OK";
    const shell_path = interactiveShellPath();

    var session = try maru.pty.PtySession.spawn(allocator, .{
        .command = shell_path,
        .args = &.{"-i"},
        .size = size,
    });
    defer session.deinit();

    var surface = try maru.app.Surface.init(allocator, 1, size);
    defer surface.deinit();
    surface.title = "interactive shell pty";
    surface.command = shell_path;

    var runtime = maru.app.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    _ = try runtime.attach(&surface, 10, maru.app.PtyIo.fromSession(&session));

    var queue = try maru.app.PtyEventQueue.init(std.testing.io, allocator, 8);
    defer queue.deinit();
    var reader = maru.app.PtyReader.init(allocator, 10, &session, &queue);
    try reader.start();
    // interactive shell은 사용자의 dotfile 영향을 받을 수 있다. 실패 경로에서도
    // reader를 깨우고 child를 reap해야 opt-in smoke가 개발 세션을 멈추지 않는다.
    defer reader.stopAndJoin();

    const command = try std.fmt.allocPrint(allocator, "printf '{s}\\n'; exit\n", .{marker});
    defer allocator.free(command);
    try session.writeInput(command);

    const raw = try drainRuntimeQueueUntilExitWithDeadline(allocator, &queue, &runtime, 5_000);
    defer allocator.free(raw.bytes);

    try artifacts.writeText(
        "tests/artifacts/integration/pty/interactive-shell.raw.txt",
        raw.bytes,
    );

    const screen = try surface.core.dumpUtf8(allocator);
    defer allocator.free(screen);
    const snapshot = try maru.observability.snapshot.renderTerminalSnapshot(allocator, surface.core.snapshot());
    defer allocator.free(snapshot);
    const summary = try renderInteractiveShellSummary(allocator, .{
        .shell_path = shell_path,
        .marker = marker,
        .raw = raw.bytes,
        .screen = screen,
        .exit_status = raw.exit_status,
        .output_events = raw.output_events,
        .queue_capacity = queue.capacity(),
        .process_state = surface.process_state,
    });
    defer allocator.free(summary);

    // Artifact를 먼저 남긴다. 이 테스트가 깨졌을 때는 shell startup output,
    // prompt escape, marker echo 중 어디서 막혔는지 raw/screen/snapshot이 더 중요하다.
    try artifacts.writeTextWithFinalNewline(
        allocator,
        "tests/artifacts/integration/pty/interactive-shell.screen.txt",
        screen,
    );
    try artifacts.writeText(
        "tests/artifacts/integration/pty/interactive-shell.snapshot.txt",
        snapshot,
    );
    try artifacts.writeText(
        "tests/artifacts/integration/pty/interactive-shell.summary.txt",
        summary,
    );

    try std.testing.expectEqual(maru.pty.ExitStatus{ .exited = 0 }, raw.exit_status);
    try std.testing.expectEqual(maru.app.ProcessState.exited, surface.process_state);
    try std.testing.expect(std.mem.indexOf(u8, raw.bytes, marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, marker) != null);
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

test "macOS PTY reader stopAndJoin closes a blocking child without leaking a zombie" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var session = try maru.pty.PtySession.spawn(allocator, .{
        // 출력이 없는 long-running child를 사용해 reader thread가 readEvent에서
        // blocking 중인 상황을 만든다. HUP/TERM을 무시하므로 close path가
        // SIGKILL escalation과 reap까지 실제로 수행해야 한다.
        .command = "/bin/sh",
        .args = &.{ "-c", "trap '' HUP TERM; while :; do sleep 1; done" },
        .size = .{ .cols = 20, .rows = 8 },
    });
    defer session.deinit();
    const child_pid = session.child_pid;

    var queue = try maru.app.PtyEventQueue.init(std.testing.io, allocator, 1);
    defer queue.deinit();
    var reader = maru.app.PtyReader.init(allocator, 10, &session, &queue);
    try reader.start();

    // 이 짧은 대기는 shell loop가 시작되고 reader가 PTY read에 들어갈 시간을 준다.
    // 테스트의 핵심은 정확한 시간 측정이 아니라 stopAndJoin이 blocking read를 깨우는지다.
    try sleepMillis(20);
    reader.stopAndJoin();

    const summary = try std.fmt.allocPrint(
        allocator,
        \\child_pid={d}
        \\queue_capacity={d}
        \\reader_stopped_and_joined=true
        \\
    ,
        .{ child_pid, queue.capacity() },
    );
    defer allocator.free(summary);
    try artifacts.writeText(
        "tests/artifacts/integration/pty/reader-stop.summary.txt",
        summary,
    );

    // stopAndJoin이 session.close를 통해 child를 reap했다면 waitpid는 ECHILD로
    // 실패한다. 아직 살아 있거나 zombie라면 pid 또는 0이 돌아와 이 단언이 깨진다.
    var status: c_int = 0;
    const rc = std.c.waitpid(child_pid, &status, std.c.W.NOHANG);
    try std.testing.expect(rc < 0);
}

test "macOS PTY reader stopAndJoin reaps a child that closed its stdio but keeps running" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var session = try maru.pty.PtySession.spawn(allocator, .{
        // child가 stdin/stdout/stderr를 모두 닫으면 master는 EOF를 보지만 child는
        // 계속 살아 있다(daemonize). 그러면 reader는 read 대기가 아니라 reap 경로의
        // kqueue NOTE_EXIT 대기에 들어간다. HUP/TERM도 무시하므로 close는 SIGKILL로
        // child를 끝내고 reap해야 한다. reap 경로가 bare blocking waitpid를 쓰면
        // close가 깨우지 못해 stopAndJoin이 여기서 영원히 hang한다.
        .command = "/bin/sh",
        .args = &.{ "-c", "trap '' HUP TERM; exec 0<&- 1>&- 2>&-; while :; do sleep 1; done" },
        .size = .{ .cols = 20, .rows = 8 },
    });
    defer session.deinit();
    const child_pid = session.child_pid;

    var queue = try maru.app.PtyEventQueue.init(std.testing.io, allocator, 1);
    defer queue.deinit();
    var reader = maru.app.PtyReader.init(allocator, 10, &session, &queue);
    try reader.start();

    // child가 stdio를 닫고 reader가 EOF -> reap 경로(kqueue 대기)에 들어갈 시간을 준다.
    try sleepMillis(50);
    reader.stopAndJoin();

    // 데드락이면 stopAndJoin이 반환하지 않아 이 줄에 도달하지 못한다. 도달했다면
    // kqueue 대기가 깨어났고 child가 reap됐다는 뜻이므로 waitpid는 ECHILD다.
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
        const event = queue.popBlocking() orelse return error.ReaderQueueClosedBeforeTermination;
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
            .read_error => {
                // read_error는 더 이상 applyQueuedEvent에서 throw되지 않고 termination
                // 데이터로 반환된다. 여기서 명시적으로 종료를 신호하지 않으면, reader
                // thread가 멈춘 뒤 queue를 닫는 주체가 없어 다음 popBlocking이 영원히
                // 블록된다. 이벤트를 적용해 소유권을 끝낸 뒤 읽기 실패를 surface한다.
                _ = try pump.applyQueuedEvent(event);
                return error.ReadFailed;
            },
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

fn drainRuntimeQueueUntilExitWithDeadline(
    allocator: std.mem.Allocator,
    queue: *maru.app.PtyEventQueue,
    runtime: *maru.app.SurfaceRuntime,
    timeout_ms: i64,
) !CollectedOutput {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    var pump = maru.app.RuntimeEventPump.init(allocator, queue, runtime);
    var output_events: usize = 0;
    const started = std.Io.Timestamp.now(std.testing.io, .awake);

    while (true) {
        if (queue.tryPop()) |event| {
            const exit_status: ?maru.pty.ExitStatus = switch (event) {
                .output => |output| blk: {
                    output_events += 1;
                    try bytes.appendSlice(allocator, output.bytes);
                    break :blk null;
                },
                .exited => |exited| exited.status,
                .read_error => {
                    _ = try pump.applyQueuedEvent(event);
                    return error.ReadFailed;
                },
            };

            _ = try pump.applyQueuedEvent(event);
            if (exit_status) |status| {
                return .{
                    .bytes = try bytes.toOwnedSlice(allocator),
                    .exit_status = status,
                    .output_events = output_events,
                };
            }
            continue;
        }

        if (started.untilNow(std.testing.io, .awake).toMilliseconds() >= timeout_ms) {
            return error.InteractiveShellTimedOut;
        }
        try sleepMillis(10);
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

fn sleepMillis(ms: i64) !void {
    // Zig 0.16에서는 sleep이 std.Thread가 아니라 std.Io의 clock-aware API다.
    // 테스트도 같은 Io 경계를 쓰면 나중에 platform별 event loop와 섞일 때
    // POSIX-only nanosleep 우회 코드가 남지 않는다.
    try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(ms), .awake);
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

const InteractiveShellSummary = struct {
    shell_path: []const u8,
    marker: []const u8,
    raw: []const u8,
    screen: []const u8,
    exit_status: maru.pty.ExitStatus,
    output_events: usize,
    queue_capacity: usize,
    process_state: maru.app.ProcessState,
};

fn renderInteractiveShellSummary(
    allocator: std.mem.Allocator,
    summary: InteractiveShellSummary,
) ![]u8 {
    const raw_contains_marker = std.mem.indexOf(u8, summary.raw, summary.marker) != null;
    const screen_contains_marker = std.mem.indexOf(u8, summary.screen, summary.marker) != null;
    return std.fmt.allocPrint(
        allocator,
        \\maru.pty-interactive-shell-smoke.v1
        \\shell={s}
        \\interactive=true
        \\raw_contains_marker={}
        \\screen_contains_marker={}
        \\exit_status={s}
        \\process_state={s}
        \\raw_bytes={d}
        \\output_events={d}
        \\queue_capacity={d}
        \\raw_artifact=tests/artifacts/integration/pty/interactive-shell.raw.txt
        \\screen_artifact=tests/artifacts/integration/pty/interactive-shell.screen.txt
        \\snapshot_artifact=tests/artifacts/integration/pty/interactive-shell.snapshot.txt
        \\
    ,
        .{
            summary.shell_path,
            raw_contains_marker,
            screen_contains_marker,
            exitStatusLabel(summary.exit_status),
            @tagName(summary.process_state),
            summary.raw.len,
            summary.output_events,
            summary.queue_capacity,
        },
    );
}

fn interactiveShellPath() []const u8 {
    if (std.c.getenv("MARU_INTERACTIVE_SHELL")) |raw| {
        const value = std.mem.trim(u8, std.mem.span(raw), " \t\r\n");
        if (value.len > 0) return value;
    }
    if (std.c.getenv("SHELL")) |raw| {
        const value = std.mem.trim(u8, std.mem.span(raw), " \t\r\n");
        if (value.len > 0) return value;
    }
    return "/bin/sh";
}

fn exitStatusLabel(status: maru.pty.ExitStatus) []const u8 {
    return switch (status) {
        .exited => "exited",
        .signaled => "signaled",
        .unknown => "unknown",
    };
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

test "macOS reader-processing delivers OSC 11 reply without any render tick (PR3 docs/io-render-threading §6-1)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    // §6-1 수락 기준: I/O–렌더 분리의 핵심을 **타이밍 비의존**으로 직접 인코딩한다. 통제 child가 OSC 11 배경
    // 질의를 보내고 응답을 읽어 OSC11_OK 마커를 찍는다. 이 테스트는 drainAvailable/renderTick을 **한 번도**
    // 호출하지 않는다 — 리더(I/O 스레드)가 락 아래 core.write로 질의를 처리하고 응답을 즉시 PTY로 되써야만
    // child가 응답을 받아 마커를 찍고, 그 마커 출력을 다시 리더가 core에 적용한다. child 종료 → 리더 종료(join)
    // 뒤 core 화면에 OSC11_OK가 있으면 PASS. 구모델(리더 비처리)이면 출력이 큐에만 쌓여 core가 비고, child도
    // 응답을 못 받아(OSC11_FAIL/타임아웃) OSC11_OK가 없어 FAIL — "렌더 분리"가 직접 검증된다.
    const allocator = std.testing.allocator;
    const size: maru.terminal.Size = .{ .cols = 40, .rows = 4 };

    // child: OSC 11 응답은 줄바꿈이 없어 canonical이면 버퍼링되므로 raw(min 0 time 30 = 데이터 즉시·없으면 3s),
    // 응답이 출력으로 echo돼 섞이지 않게 -echo. OSC 11 질의(? + ST) 송신 → 한 번 read(dd)로 응답 수신 → **받은
    // 바이트를 hex로 stdout에 에코**(리더가 그 hex를 core에 적용 → 테스트가 core에서 확인) → |END. hex라 제어문자
    // 가 core를 안 흩뜨리고, "받았는지"를 결정론적으로 관찰한다(파싱·타임아웃 불필요).
    const script =
        "stty -icanon -echo min 0 time 30 2>/dev/null; " ++
        "printf '\\033]11;?\\033\\\\'; " ++
        "dd bs=64 count=1 2>/dev/null | od -An -tx1 | tr -d ' \\n'; " ++
        "printf '|END\\n'";

    var session = try maru.pty.PtySession.spawn(allocator, .{
        .command = "/bin/bash",
        .args = &.{ "-c", script },
        .size = size,
    });
    defer session.deinit();

    var surface = try maru.app.Surface.init(allocator, 1, size);
    defer surface.deinit();

    // 리더-처리 켬: 출력을 락 아래 직접 core에 적용 + OSC 응답을 self.session으로 즉시 되쓰기(렌더 tick 무관).
    // 큐는 "출력 발생" 빈 신호 + exit만 받으므로(메인이 안 드레인) 신호가 안 막히게 넉넉히 잡는다.
    var queue = try maru.app.PtyEventQueue.init(std.testing.io, allocator, 64);
    defer queue.deinit();
    defer queue.close();
    var reader = maru.app.PtyReader.init(allocator, 10, &session, &queue);
    reader.setProcessing(&surface.core, &surface.core_mutex, std.testing.io);
    try reader.start();
    // drainAvailable/renderTick 호출 없음. child가 끝나면(응답 받아 마커 찍고 exit) 리더도 EOF로 끝난다.
    reader.join();

    const screen = try surface.core.dumpUtf8(allocator);
    defer allocator.free(screen);
    try artifacts.writeTextWithFinalNewline(
        allocator,
        "tests/artifacts/integration/pty/osc11-reader-delivery.screen.txt",
        screen,
    );

    // |END = child가 끝까지 실행됐고 그 출력이 (드레인/렌더 없이) 리더로 core에 적용됨.
    // 1b5d31313b726762 = `\x1b]11;rgb` — child가 받은 바이트가 OSC 11 배경 응답으로 시작 = 리더가 렌더 틱 없이
    // 질의 응답을 PTY로 되써 child가 받았다는 직접 증거. 구모델(리더 비처리)이면 응답이 안 나가 이 hex가 없다.
    try std.testing.expect(std.mem.indexOf(u8, screen, "|END") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, "1b5d31313b726762") != null);
}

test "macOS reader-processing answers OSC 11 within a bound under output flood (io-render-threading §6-2)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    // §6-2 회귀: 원결함은 출력 폭주 중 OSC 11 응답이 ~4.2초 지연(렌더 tick 결합)이었다. reader-processing는
    // 폭주와 무관하게 즉시 응답해야 한다. child가 대량 출력(~106KB)을 쏟은 뒤 OSC 11 질의를 보내고, 응답을
    // **유한 상한(VTIME=20 = 2초) 안에** 한 번의 read로 받으면 그 바이트를 hex로 에코한다. 신모델은 폭주를
    // 인라인 처리(<<2s)하고 응답을 즉시 되써 child가 받음 → core에 OSC 11 응답 hex가 있음(PASS). 응답이 초 단위로
    // 지연되면(원결함 회귀) child read가 2초에 타임아웃 → hex 없음 → FAIL. 상한은 codex 데드라인(~50–100ms)보다
    // 훨씬 관대해 머신 편차 flaky를 피하면서 "초 단위 지연"만 정조준한다(docs/io-render-threading §6-2).
    const allocator = std.testing.allocator;
    const size: maru.terminal.Size = .{ .cols = 60, .rows = 6 };

    const script =
        "stty -icanon -echo min 0 time 20 2>/dev/null; " ++ // raw, read는 데이터 즉시 / 없으면 2s(VTIME)
        "seq 1 20000; " ++ // 출력 폭주 ~106KB (reader가 4KB 청크로 인라인 처리)
        "printf '\\033]11;?\\033\\\\'; " ++ // 폭주 뒤 OSC 11 배경 질의
        "dd bs=64 count=1 2>/dev/null | od -An -tx1 | tr -d ' \\n'; " ++ // 응답을 한 번 read(≤2s) → hex 에코
        "printf '|END\\n'";

    var session = try maru.pty.PtySession.spawn(allocator, .{
        .command = "/bin/bash",
        .args = &.{ "-c", script },
        .size = size,
    });
    defer session.deinit();

    var surface = try maru.app.Surface.init(allocator, 1, size);
    defer surface.deinit();

    // 큐는 폭주의 "출력 발생" 빈 신호(청크당 1개, 빈-신호 coalescing 없음 — pty_reader)를 받는다. ~106KB/4KB≈27개
    // ≪ 256이라 메인이 안 드레인해도 reader가 pushBlocking에서 안 막힌다(drain/render 호출 없이 §6-2 성립).
    var queue = try maru.app.PtyEventQueue.init(std.testing.io, allocator, 256);
    defer queue.deinit();
    defer queue.close();
    var reader = maru.app.PtyReader.init(allocator, 10, &session, &queue);
    reader.setProcessing(&surface.core, &surface.core_mutex, std.testing.io);
    try reader.start();
    reader.join(); // child가 응답을 (상한 안에) 받아 마커 찍고 exit → reader도 EOF로 끝남

    const screen = try surface.core.dumpUtf8(allocator);
    defer allocator.free(screen);
    try artifacts.writeTextWithFinalNewline(
        allocator,
        "tests/artifacts/integration/pty/osc11-reader-flood-latency.screen.txt",
        screen,
    );

    // 폭주 뒤에도 OSC 11 응답이 2초 상한 안에 child에 도달 = 원결함(4.2s) 회귀 없음.
    try std.testing.expect(std.mem.indexOf(u8, screen, "|END") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, "1b5d31313b726762") != null);
}

test "macOS reader write and render snapshot hammer concurrently without corruption (io-render-threading §6-3)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    // §6-3 동시성 스트레스: reader-processing가 출력 폭주를 `core_mutex` 아래 core에 적용(write)하는 동안, 메인
    // 스레드가 같은 락으로 renderSnapshot+buildDrawList(렌더 read 경로)를 N회 hammer한다. mutex가 write↔read를
    // 직렬화하므로 손상/크래시가 없어야 한다 — 각 snapshot의 grid 치수가 일관(torn read면 어긋남)하고 buildDrawList
    // 가 성공(또는 OOM만)하며 최종 core도 유효. (ThreadSanitizer 빌드면 데이터 레이스까지 잡는다.)
    const allocator = std.testing.allocator;
    const size: maru.terminal.Size = .{ .cols = 40, .rows = 8 };

    var session = try maru.pty.PtySession.spawn(allocator, .{
        .command = "/bin/bash",
        .args = &.{ "-c", "seq 1 50000" }, // ~288KB 폭주 — reader가 계속 core를 mutate
        .size = size,
    });
    defer session.deinit();

    var surface = try maru.app.Surface.init(allocator, 1, size);
    defer surface.deinit();

    var queue = try maru.app.PtyEventQueue.init(std.testing.io, allocator, 1024); // ~70 chunk ≪ 1024 → 비블록(drain 불필요)
    defer queue.deinit();
    defer queue.close();
    var reader = maru.app.PtyReader.init(allocator, 10, &session, &queue);
    reader.setProcessing(&surface.core, &surface.core_mutex, std.testing.io);
    try reader.start();

    // 폭주가 흐르는 동안(reader가 write 중) 같은 락으로 render-read를 hammer한다.
    var i: usize = 0;
    while (i < 30000) : (i += 1) {
        surface.core_mutex.lockUncancelable(std.testing.io);
        const snap = surface.core.renderSnapshot();
        const dims_ok = snap.size.cols == size.cols and snap.size.rows == size.rows;
        var list_or = maru.renderer.buildDrawList(allocator, snap); // 셀을 DrawList로 복사(read 경로) — 락 안
        surface.core_mutex.unlock(std.testing.io);
        if (list_or) |*list| list.deinit(allocator) else |_| {} // OOM은 허용(크래시만 없으면 됨)
        try std.testing.expect(dims_ok); // 손상되면 치수가 어긋난다
    }
    reader.join();

    // 동시 write/read에서 크래시·손상 0으로 여기 도달. 최종 core도 유효(dump 가능).
    const screen = try surface.core.dumpUtf8(allocator);
    defer allocator.free(screen);
    try std.testing.expect(screen.len > 0);
}

test "macOS close during flood reaps reader-processing child without UAF or zombie (io-render-threading §6-4)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    // §6-4 lifecycle/close race: reader-processing가 폭주를 `core_mutex` 아래 적용(또는 큐 backpressure로 대기)
    // 하는 중에 close한다. stopAndJoin(queue.close → session.close[SIGKILL escalate] → join)으로 reader가 코어
    // 접근을 멈춘 **뒤에야** surface.deinit(core.deinit)이 일어나야 UAF가 없다. child는 reap돼 좀비도 없어야 한다.
    const allocator = std.testing.allocator;
    const size: maru.terminal.Size = .{ .cols = 30, .rows = 8 };

    // 끝없이 폭주하는 child(`yes`). PTY 버퍼가 차면 child가 write에서 막히고 reader는 작은 큐가 차 push에서 막힌다 —
    // close가 그 막힌 reader를 깨우고 child를 SIGKILL로 reap해야 한다.
    var session = try maru.pty.PtySession.spawn(allocator, .{
        .command = "/usr/bin/yes",
        .args = &.{"maru-flood"},
        .size = size,
    });
    const child_pid = session.child_pid;

    var surface = try maru.app.Surface.init(allocator, 1, size);
    var queue = try maru.app.PtyEventQueue.init(std.testing.io, allocator, 16); // 작게 — 곧 차 reader가 backpressure 대기
    var reader = maru.app.PtyReader.init(allocator, 10, &session, &queue);
    reader.setProcessing(&surface.core, &surface.core_mutex, std.testing.io);
    try reader.start();

    // 폭주가 흐르고 reader가 코어를 mutate/대기 중이 되게 잠깐 둔다(정확한 시점이 아니라 close가 그 상태를 안전히
    // 끝내는지가 핵심). 그 뒤 close.
    try sleepMillis(20);
    reader.stopAndJoin(); // reader가 멈춘다(코어 접근 종료) + child reap
    surface.deinit(); // reader join 후 core.deinit — UAF 없음
    session.deinit();
    queue.deinit();

    // child가 reap돼 좀비가 없어야 한다: 이미 reap된 pid의 waitpid는 ECHILD(rc<0). 좀비면 pid 반환, 살아있으면 0.
    var status: c_int = 0;
    const rc = std.c.waitpid(child_pid, &status, std.c.W.NOHANG);
    try std.testing.expect(rc < 0);
}

test "macOS reader-processing writes main input via write_queue as the sole writer (io-render-threading §8 P2-3b)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    // P2-3b 단일 writer: 메인 입력(키/paste/스크롤)은 직접 PTY로 쓰지 않고 write_queue에 enqueue + signalWrite로
    // I/O 스레드(reader)를 깨워, reader가 같은 poll 루프에서 drain해 PTY로 보낸다(reader가 **유일한** writer).
    // child는 raw 모드로 입력을 한 번 read해 받은 바이트를 hex로 에코한다 — reader가 write_queue를 drain해 입력을
    // child에 전달해야만 그 hex가 core에 나타난다. teeth: enqueue 시점에 reader가 read 전용 poll에 park돼 있을 수
    // 있으므로 signalWrite가 reader를 깨워야 한다 — 없으면 입력이 안 나가 child read가 타임아웃(hex 없음) → FAIL.
    const allocator = std.testing.allocator;
    const size: maru.terminal.Size = .{ .cols = 50, .rows = 4 };

    // child: raw(min 1 = 최소 1바이트 올 때까지, time 50 = 5s 상한), -echo(입력이 출력에 안 섞이게), 받은 입력을
    // hex로 에코(제어문자가 core를 안 흩뜨리고 결정론적 관찰) → |END.
    const script =
        "stty -icanon -echo min 1 time 50 2>/dev/null; " ++
        "dd bs=64 count=1 2>/dev/null | od -An -tx1 | tr -d ' \\n'; " ++
        "printf '|END\\n'";

    var session = try maru.pty.PtySession.spawn(allocator, .{
        .command = "/bin/bash",
        .args = &.{ "-c", script },
        .size = size,
    });
    defer session.deinit();

    var surface = try maru.app.Surface.init(allocator, 1, size);
    defer surface.deinit();

    var queue = try maru.app.PtyEventQueue.init(std.testing.io, allocator, 64);
    defer queue.deinit();
    defer queue.close();
    var write_queue = try maru.app.PtyWriteQueue.init(std.testing.io, allocator, 4096);
    defer write_queue.deinit();
    var reader = maru.app.PtyReader.init(allocator, 10, &session, &queue);
    reader.setWriteQueue(&write_queue); // 단일 writer 경로 주입(setProcessing/start 전)
    reader.setProcessing(&surface.core, &surface.core_mutex, std.testing.io);
    try reader.start();

    // 메인 스레드: 입력을 직접 session.writeInput 하지 않고 write_queue로 보낸 뒤 reader를 깨운다.
    try write_queue.enqueueBlocking("MARU-INPUT\n");
    session.signalWrite();

    reader.join(); // child가 입력 받아 hex 찍고 |END 후 exit → reader가 EOF로 종료

    const screen = try surface.core.dumpUtf8(allocator);
    defer allocator.free(screen);
    try artifacts.writeTextWithFinalNewline(
        allocator,
        "tests/artifacts/integration/pty/single-writer-main-input.screen.txt",
        screen,
    );

    // 4d4152552d494e505554 = "MARU-INPUT"의 hex — child가 write_queue 경유로 그 입력을 받아 에코했다는 직접 증거
    // (reader가 유일한 writer로 메인 입력을 drain·전달). 입력 미전달(signalWrite 누락 등)이면 hex 없음 → FAIL.
    try std.testing.expect(std.mem.indexOf(u8, screen, "|END") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, "4d4152552d494e505554") != null);
}

test "macOS close with pending main-input write unblocks producer and reaps without UAF/zombie (io-render-threading §8 P2-4)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    // P2-4 close-with-pending-write(§6-4 확장): child(`yes`)는 stdin을 안 읽으므로 PTY 입력버퍼가 차면 reader가
    // write_queue를 더 비우지 못해 큐가 cap까지 쌓이고, 큰 입력을 넣는 생산자(메인 대역 스레드)는 enqueueBlocking
    // backpressure로 막힌다. 이 상태에서 close가 (1) write_queue를 닫아 막힌 생산자를 QueueClosed로 풀고(무한
    // 대기 금지) (2) session.close로 child를 SIGKILL reap하고 (3) reader join **뒤** surface.deinit이라 UAF가
    // 없어야 한다. 생산자가 안 풀리면 producer.join()에서 영원히 hang → 테스트 실패(teeth).
    const allocator = std.testing.allocator;
    const size: maru.terminal.Size = .{ .cols = 30, .rows = 6 };

    // `yes`: stdout 무한 폭주 + stdin 무시. PTY 입력버퍼가 차면 우리 입력이 write_queue에 남는다.
    var session = try maru.pty.PtySession.spawn(allocator, .{
        .command = "/usr/bin/yes",
        .args = &.{"maru-flood"},
        .size = size,
    });
    const child_pid = session.child_pid;

    var surface = try maru.app.Surface.init(allocator, 1, size);
    var queue = try maru.app.PtyEventQueue.init(std.testing.io, allocator, 64);
    var write_queue = try maru.app.PtyWriteQueue.init(std.testing.io, allocator, 1 << 16); // 64KiB cap
    var reader = maru.app.PtyReader.init(allocator, 10, &session, &queue);
    reader.setWriteQueue(&write_queue);
    reader.setProcessing(&surface.core, &surface.core_mutex, std.testing.io);
    try reader.start();

    // 생산자: child가 안 읽어 PTY 버퍼가 차면 write_queue가 cap까지 차고 여기서 backpressure로 막힌다.
    const Producer = struct {
        fn run(wq: *maru.app.PtyWriteQueue, sess: *maru.pty.PtySession) void {
            var chunk: [4096]u8 = undefined;
            @memset(&chunk, 'x');
            var i: usize = 0;
            while (i < 64) : (i += 1) { // 256KB 시도 — cap(64KB)+PTY버퍼를 넘겨 막히게
                wq.enqueueBlocking(&chunk) catch return; // close되면 QueueClosed로 끝남
                sess.signalWrite();
            }
        }
    };
    var producer = try std.Thread.spawn(.{}, Producer.run, .{ &write_queue, &session });

    try sleepMillis(20); // 생산자가 backpressure로 막히는 상태가 되게 둔다(정확한 시점 불필요)

    // close 순서: write_queue를 먼저 닫아 막힌 생산자를 QueueClosed로 풀고, 그 뒤 reader 멈춤 + child reap.
    write_queue.close();
    reader.stopAndJoin(); // queue.close → session.close[SIGKILL] → join
    producer.join(); // QueueClosed로 끝났어야 한다(무한 대기면 여기서 hang)
    surface.deinit(); // reader join 후 core.deinit — UAF 없음
    session.deinit();
    queue.deinit();
    write_queue.deinit();

    // child가 reap돼 좀비가 없어야 한다: 이미 reap된 pid의 waitpid는 ECHILD(rc<0).
    var status: c_int = 0;
    const rc = std.c.waitpid(child_pid, &status, std.c.W.NOHANG);
    try std.testing.expect(rc < 0);
}
