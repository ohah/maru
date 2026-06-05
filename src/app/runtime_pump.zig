const std = @import("std");
const pty = @import("../pty.zig");
const terminal = @import("../terminal.zig");
const pty_reader = @import("pty_reader.zig");
const runtime_mod = @import("runtime.zig");
const surface_mod = @import("surface.zig");

pub const PumpError = runtime_mod.RuntimeError || error{
    ReaderQueueClosedBeforeExit,
};

pub const PumpedEventKind = enum {
    output,
    exited,
    read_error,
};

pub const DrainSummary = struct {
    output_events: usize = 0,
    exit_events: usize = 0,

    fn record(self: *DrainSummary, kind: PumpedEventKind) void {
        switch (kind) {
            .output => self.output_events += 1,
            .exited => self.exit_events += 1,
            // read_error는 summary로 집계하지 않는다. applyQueuedEvent가 read_error를
            // applyPtyEvent의 error.ReadFailed로 먼저 전파하므로 .read_error kind는
            // record()까지 도달하지 못한다. 즉 reader 실패는 카운터가 아니라 반환된
            // error로만 신호한다. (집계용 카운터를 두면 항상 0이라 오해를 부른다.)
            .read_error => {},
        }
    }
};

pub const DrainUntilExitResult = struct {
    summary: DrainSummary,
    exit_status: pty.ExitStatus,
};

pub const RuntimeEventPump = struct {
    allocator: std.mem.Allocator,
    queue: *pty_reader.PtyEventQueue,
    runtime: *runtime_mod.SurfaceRuntime,

    pub fn init(
        allocator: std.mem.Allocator,
        queue: *pty_reader.PtyEventQueue,
        runtime: *runtime_mod.SurfaceRuntime,
    ) RuntimeEventPump {
        return .{
            .allocator = allocator,
            .queue = queue,
            .runtime = runtime,
        };
    }

    pub fn drainAvailable(self: *RuntimeEventPump) PumpError!DrainSummary {
        var summary: DrainSummary = .{};
        while (self.queue.tryPop()) |event| {
            const kind = try self.applyQueuedEvent(event);
            summary.record(kind);
        }
        return summary;
    }

    pub fn drainBlockingUntilExit(self: *RuntimeEventPump) PumpError!DrainUntilExitResult {
        var summary: DrainSummary = .{};

        while (true) {
            const event = self.queue.popBlocking() orelse return error.ReaderQueueClosedBeforeExit;
            const exit_status = queuedExitStatus(event);
            const kind = try self.applyQueuedEvent(event);
            summary.record(kind);

            if (exit_status) |status| {
                return .{
                    .summary = summary,
                    .exit_status = status,
                };
            }
        }
    }

    pub fn applyQueuedEvent(self: *RuntimeEventPump, event: pty_reader.QueuedPtyEvent) runtime_mod.RuntimeError!PumpedEventKind {
        // 큐에서 꺼낸 event는 pump가 runtime에 적용한 뒤 반드시 여기서 소유권을 끝낸다.
        // app host, integration test, future trace recorder가 같은 함수를 쓰면 output bytes
        // 해제 규칙이 한 곳에 모여서 double-free와 leak을 함께 피할 수 있다.
        defer event.deinit(self.allocator);

        const kind = queuedEventKind(event);
        try self.runtime.applyPtyEvent(event.runtimeEvent());
        return kind;
    }
};

fn queuedEventKind(event: pty_reader.QueuedPtyEvent) PumpedEventKind {
    return switch (event) {
        .output => .output,
        .exited => .exited,
        .read_error => .read_error,
    };
}

fn queuedExitStatus(event: pty_reader.QueuedPtyEvent) ?pty.ExitStatus {
    return switch (event) {
        .output, .read_error => null,
        .exited => |exited| exited.status,
    };
}

const FakePty = struct {
    fn io(self: *FakePty) runtime_mod.PtyIo {
        return .{
            .ctx = self,
            .write_input = fakeWriteInput,
            .resize_fn = fakeResize,
        };
    }

    fn fakeWriteInput(ctx: *anyopaque, bytes: []const u8) !void {
        _ = ctx;
        _ = bytes;
    }

    fn fakeResize(ctx: *anyopaque, size: terminal.Size) !void {
        _ = ctx;
        _ = size;
    }
};

fn attachTestSurface(
    runtime: *runtime_mod.SurfaceRuntime,
    surface: *surface_mod.Surface,
    fake_pty: *FakePty,
    pty_id: runtime_mod.PtyId,
) !void {
    _ = try runtime.attach(surface, pty_id, fake_pty.io());
}

test "runtime event pump drains queued output into the attached surface" {
    // 이 테스트는 app host가 아직 없어도 가장 중요한 runtime loop 계약을 증명한다.
    // reader thread가 넘긴 output bytes는 SurfaceRuntime에 적용되고 pump가 해제해야 한다.
    const allocator = std.testing.allocator;
    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    var surface = try surface_mod.Surface.init(allocator, 1, .{ .cols = 20, .rows = 3 });
    defer surface.deinit();
    var fake_pty: FakePty = .{};
    try attachTestSurface(&runtime, &surface, &fake_pty, 10);

    var queue = try pty_reader.PtyEventQueue.init(std.testing.io, allocator, 2);
    defer queue.deinit();
    var pump = RuntimeEventPump.init(allocator, &queue, &runtime);

    const bytes = try allocator.dupe(u8, "pump maru");
    try queue.pushBlocking(.{ .output = .{ .pty_id = 10, .bytes = bytes } });

    const summary = try pump.drainAvailable();
    try std.testing.expectEqual(@as(usize, 1), summary.output_events);
    try std.testing.expectEqual(@as(usize, 0), summary.exit_events);

    const screen = try surface.core.dumpUtf8(allocator);
    defer allocator.free(screen);
    try std.testing.expect(std.mem.indexOf(u8, screen, "pump maru") != null);
}

test "runtime event pump latches exit events on the attached surface" {
    // 종료 event는 surface를 삭제하지 않고 exited 상태로 남긴다.
    // 그래야 사용자가 마지막 화면과 restore metadata를 계속 볼 수 있다.
    const allocator = std.testing.allocator;
    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    var surface = try surface_mod.Surface.init(allocator, 1, terminal.Size.default);
    defer surface.deinit();
    var fake_pty: FakePty = .{};
    try attachTestSurface(&runtime, &surface, &fake_pty, 10);

    var queue = try pty_reader.PtyEventQueue.init(std.testing.io, allocator, 1);
    defer queue.deinit();
    var pump = RuntimeEventPump.init(allocator, &queue, &runtime);

    try queue.pushBlocking(.{ .exited = .{ .pty_id = 10, .status = .{ .exited = 0 } } });

    const summary = try pump.drainAvailable();
    try std.testing.expectEqual(@as(usize, 1), summary.exit_events);
    try std.testing.expectEqual(surface_mod.ProcessState.exited, surface.process_state);
}

test "runtime event pump drainAvailable returns immediately on an empty queue" {
    // GUI frame loop에서는 매 frame마다 non-blocking drain이 필요하다.
    // 빈 queue에서 멈추면 renderer와 입력 처리가 같이 멈추므로 이 계약을 먼저 고정한다.
    const allocator = std.testing.allocator;
    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    var queue = try pty_reader.PtyEventQueue.init(std.testing.io, allocator, 1);
    defer queue.deinit();
    var pump = RuntimeEventPump.init(allocator, &queue, &runtime);

    const summary = try pump.drainAvailable();
    try std.testing.expectEqual(@as(usize, 0), summary.output_events);
    try std.testing.expectEqual(@as(usize, 0), summary.exit_events);
}

test "runtime event pump can block until an exit event is applied" {
    // headless PTY integration은 아직 window loop가 없으므로 output을 모두 적용한 뒤
    // exit status까지 한 번에 기다리는 helper가 필요하다. 이 함수도 같은 ownership
    // 규칙을 쓰기 때문에 integration 전용 drain helper를 중복으로 만들지 않는다.
    const allocator = std.testing.allocator;
    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    var surface = try surface_mod.Surface.init(allocator, 1, .{ .cols = 20, .rows = 3 });
    defer surface.deinit();
    var fake_pty: FakePty = .{};
    try attachTestSurface(&runtime, &surface, &fake_pty, 10);

    var queue = try pty_reader.PtyEventQueue.init(std.testing.io, allocator, 2);
    defer queue.deinit();
    var pump = RuntimeEventPump.init(allocator, &queue, &runtime);

    const bytes = try allocator.dupe(u8, "before exit");
    try queue.pushBlocking(.{ .output = .{ .pty_id = 10, .bytes = bytes } });
    try queue.pushBlocking(.{ .exited = .{ .pty_id = 10, .status = .{ .exited = 7 } } });

    const result = try pump.drainBlockingUntilExit();
    try std.testing.expectEqual(pty.ExitStatus{ .exited = 7 }, result.exit_status);
    try std.testing.expectEqual(@as(usize, 1), result.summary.output_events);
    try std.testing.expectEqual(@as(usize, 1), result.summary.exit_events);
    try std.testing.expectEqual(surface_mod.ProcessState.exited, surface.process_state);
}

test "runtime event pump reports a closed queue before exit" {
    // app shutdown이 queue를 닫았는데 exit event가 오지 않았다면 성공처럼 보이면 안 된다.
    // 이 오류가 있어야 lifecycle PR에서 reader close 순서를 검증할 수 있다.
    const allocator = std.testing.allocator;
    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    var queue = try pty_reader.PtyEventQueue.init(std.testing.io, allocator, 1);
    defer queue.deinit();
    queue.close();
    var pump = RuntimeEventPump.init(allocator, &queue, &runtime);

    try std.testing.expectError(error.ReaderQueueClosedBeforeExit, pump.drainBlockingUntilExit());
}

test "runtime event pump latches read errors before reporting ReadFailed" {
    // read_error는 성공한 출력이 아니라 PTY reader의 실패 신호다.
    // SurfaceRuntime은 먼저 surface를 exited로 표시하고, pump는 그 오류를 숨기지 않는다.
    const allocator = std.testing.allocator;
    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    var surface = try surface_mod.Surface.init(allocator, 1, terminal.Size.default);
    defer surface.deinit();
    var fake_pty: FakePty = .{};
    try attachTestSurface(&runtime, &surface, &fake_pty, 10);

    var queue = try pty_reader.PtyEventQueue.init(std.testing.io, allocator, 1);
    defer queue.deinit();
    var pump = RuntimeEventPump.init(allocator, &queue, &runtime);

    try queue.pushBlocking(.{ .read_error = .{ .pty_id = 10, .message = "EIO" } });

    try std.testing.expectError(error.ReadFailed, pump.drainAvailable());
    try std.testing.expectEqual(surface_mod.ProcessState.exited, surface.process_state);
    try std.testing.expectEqual(@as(usize, 0), queue.count());
}

test "runtime event pump releases output bytes even when runtime rejects the pty" {
    // UnknownPty 같은 root-cause 오류를 덮지 않으면서도 event ownership은 끝나야 한다.
    // testing allocator가 leak을 잡기 때문에 이 테스트는 실패 경로 deinit을 보호한다.
    const allocator = std.testing.allocator;
    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    var queue = try pty_reader.PtyEventQueue.init(std.testing.io, allocator, 1);
    defer queue.deinit();
    var pump = RuntimeEventPump.init(allocator, &queue, &runtime);

    const bytes = try allocator.dupe(u8, "orphan output");
    try queue.pushBlocking(.{ .output = .{ .pty_id = 404, .bytes = bytes } });

    try std.testing.expectError(error.UnknownPty, pump.drainAvailable());
    try std.testing.expectEqual(@as(usize, 0), queue.count());
}
