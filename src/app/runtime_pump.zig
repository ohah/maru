const std = @import("std");
const pty = @import("../pty.zig");
const terminal = @import("../terminal.zig");
const pty_reader = @import("pty_reader.zig");
const runtime_mod = @import("runtime.zig");
const surface_mod = @import("surface.zig");

pub const PumpError = runtime_mod.RuntimeError || error{
    ReaderQueueClosedBeforeTermination,
};

pub const PumpedEventKind = enum {
    output,
    exited,
    read_error,
};

pub const Termination = union(enum) {
    exited: pty.ExitStatus,
    // read_error의 message는 QueuedPtyEvent에서 빌려온 슬라이스다. applyQueuedEvent의
    // `defer event.deinit`이 끝난 뒤에도 이 값이 DrainSummary.ended에 남으므로, message는
    // 종료를 소비하는 쪽보다 오래 살아야 한다. 현재 PtyReader는 항상 `@errorName(err)`
    // (정적 문자열)만 넘기고 QueuedPtyEvent.deinit은 read_error message를 해제하지 않아
    // 안전하다. 나중에 heap message를 넣게 되면 여기서 소유권을 복사해야 한다.
    read_error: []const u8,
};

pub const DrainSummary = struct {
    output_events: usize = 0,
    exit_events: usize = 0,
    ended: ?Termination = null,

    fn record(self: *DrainSummary, event: PumpedEvent) void {
        if (event.termination) |termination| {
            // 세션은 첫 termination에서 끝난다. 같은 drain에서 종료 뒤에 들어온 event가
            // 종료 원인을 덮어쓰지 않도록 첫 termination만 latch한다(예: [exited, read_error]
            // 순서에서 실제 종료인 exit이 read_error로 가려지지 않게).
            if (self.ended == null) self.ended = termination;
        }

        const kind = event.kind;
        switch (kind) {
            .output => self.output_events += 1,
            .exited => self.exit_events += 1,
            // read_error는 output/exit 개수가 아니라 종료 원인이다. frame loop는
            // summary.ended를 보고 surface 표시를 바꾸면 되고, UnknownPty 같은 진짜
            // 결함만 error로 받는다.
            .read_error => {},
        }
    }
};

pub const PumpedEvent = struct {
    kind: PumpedEventKind,
    termination: ?Termination = null,
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
            const pumped = try self.applyQueuedEvent(event);
            summary.record(pumped);
        }
        return summary;
    }

    pub fn drainBlockingUntilTermination(self: *RuntimeEventPump) PumpError!DrainSummary {
        var summary: DrainSummary = .{};

        while (true) {
            const event = self.queue.popBlocking() orelse return error.ReaderQueueClosedBeforeTermination;
            const pumped = try self.applyQueuedEvent(event);
            summary.record(pumped);

            if (summary.ended != null) {
                return summary;
            }
        }
    }

    pub fn applyQueuedEvent(self: *RuntimeEventPump, event: pty_reader.QueuedPtyEvent) runtime_mod.RuntimeError!PumpedEvent {
        // 큐에서 꺼낸 event는 pump가 runtime에 적용한 뒤 반드시 여기서 소유권을 끝낸다.
        // app host, integration test, future trace recorder가 같은 함수를 쓰면 output bytes
        // 해제 규칙이 한 곳에 모여서 double-free와 leak을 함께 피할 수 있다.
        defer event.deinit(self.allocator);

        const kind = queuedEventKind(event);
        const termination = queuedTermination(event);
        self.runtime.applyPtyEvent(event.runtimeEvent()) catch |err| {
            // RuntimePtyEvent.read_error는 SurfaceRuntime이 surface를 exited로 latch한 뒤
            // error.ReadFailed를 반환한다. 이것은 환경 의존적 종료 신호이지 root-cause
            // 결함이 아니므로 pump summary의 종료 데이터로 바꾼다.
            if (kind == .read_error and err == error.ReadFailed) {
                return .{ .kind = kind, .termination = termination };
            }
            return err;
        };
        return .{ .kind = kind, .termination = termination };
    }
};

fn queuedEventKind(event: pty_reader.QueuedPtyEvent) PumpedEventKind {
    return switch (event) {
        .output => .output,
        .exited => .exited,
        .read_error => .read_error,
    };
}

fn queuedTermination(event: pty_reader.QueuedPtyEvent) ?Termination {
    return switch (event) {
        .output => null,
        .exited => |exited| .{ .exited = exited.status },
        .read_error => |read_error| .{ .read_error = read_error.message },
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

    const summary = try pump.drainBlockingUntilTermination();
    try std.testing.expectEqual(@as(usize, 1), summary.output_events);
    try std.testing.expectEqual(@as(usize, 1), summary.exit_events);
    try std.testing.expectEqual(pty.ExitStatus{ .exited = 7 }, summary.ended.?.exited);
    try std.testing.expectEqual(surface_mod.ProcessState.exited, surface.process_state);
}

test "runtime event pump reports a closed queue before termination" {
    // app shutdown이 queue를 닫았는데 exit event가 오지 않았다면 성공처럼 보이면 안 된다.
    // 이 오류가 있어야 lifecycle PR에서 reader close 순서를 검증할 수 있다.
    const allocator = std.testing.allocator;
    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    var queue = try pty_reader.PtyEventQueue.init(std.testing.io, allocator, 1);
    defer queue.deinit();
    queue.close();
    var pump = RuntimeEventPump.init(allocator, &queue, &runtime);

    try std.testing.expectError(error.ReaderQueueClosedBeforeTermination, pump.drainBlockingUntilTermination());
}

test "runtime event pump returns read errors as termination data" {
    // read_error는 성공한 출력이 아니라 PTY reader의 실패 신호다.
    // SurfaceRuntime은 먼저 surface를 exited로 표시하고, pump는 frame loop가 처리할 수
    // 있도록 ReadFailed throw 대신 summary.ended에 종료 원인을 담아 반환한다.
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

    const summary = try pump.drainAvailable();
    try std.testing.expectEqualStrings("EIO", summary.ended.?.read_error);
    try std.testing.expectEqual(surface_mod.ProcessState.exited, surface.process_state);
    try std.testing.expectEqual(@as(usize, 0), queue.count());
}

test "runtime event pump keeps output summary before a read error termination" {
    // GUI frame loop는 한 frame에서 output을 적용한 뒤 reader 종료를 볼 수 있다.
    // read_error를 error로 던지면 이미 적용한 output 개수를 잃기 때문에, 종료는
    // summary.ended 데이터로 보존한다.
    const allocator = std.testing.allocator;
    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    var surface = try surface_mod.Surface.init(allocator, 1, terminal.Size.default);
    defer surface.deinit();
    var fake_pty: FakePty = .{};
    try attachTestSurface(&runtime, &surface, &fake_pty, 10);

    var queue = try pty_reader.PtyEventQueue.init(std.testing.io, allocator, 2);
    defer queue.deinit();
    var pump = RuntimeEventPump.init(allocator, &queue, &runtime);

    const bytes = try allocator.dupe(u8, "before read error");
    try queue.pushBlocking(.{ .output = .{ .pty_id = 10, .bytes = bytes } });
    try queue.pushBlocking(.{ .read_error = .{ .pty_id = 10, .message = "SessionClosed" } });

    const summary = try pump.drainAvailable();
    try std.testing.expectEqual(@as(usize, 1), summary.output_events);
    try std.testing.expectEqual(@as(usize, 0), summary.exit_events);
    try std.testing.expectEqualStrings("SessionClosed", summary.ended.?.read_error);
    try std.testing.expectEqual(surface_mod.ProcessState.exited, surface.process_state);
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
