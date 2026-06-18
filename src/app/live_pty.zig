const builtin = @import("builtin");
const std = @import("std");
const pty = @import("../pty.zig");
const terminal = @import("../terminal.zig");
const runtime_mod = @import("runtime.zig");
const runtime_pump = @import("runtime_pump.zig");
const surface_mod = @import("surface.zig");
const pty_reader = @import("pty_reader.zig");

pub const LivePtySession = struct {
    allocator: std.mem.Allocator,
    session: *pty.PtySession,
    queue: *pty_reader.PtyEventQueue,
    reader: pty_reader.PtyReader,
    pty_id: runtime_mod.PtyId,
    link: ?runtime_mod.RuntimeLink = null,
    reader_finished: bool = false,

    pub fn init(
        self: *LivePtySession,
        io: std.Io,
        allocator: std.mem.Allocator,
        pty_id: runtime_mod.PtyId,
        request: pty.SpawnRequest,
        queue_capacity: usize,
    ) !void {
        // 이 타입은 live process, fd, reader thread, queue를 한 단위로 소유한다.
        // 호출자가 각각의 deinit/close 순서를 기억하게 두면 실제 tab close와 smoke cleanup이
        // 서로 다른 수명 규칙을 갖게 되므로, app layer에는 이 owner만 노출한다.
        self.* = .{
            .allocator = allocator,
            .session = undefined,
            .queue = undefined,
            .reader = undefined,
            .pty_id = pty_id,
        };

        // PtyReader는 session/queue 포인터를 들고 실행된다. 이 두 객체는 owner가 heap에
        // 고정하므로 reader thread가 읽는 session/queue는 안정적이다.
        //
        // 불변식: 단, reader thread는 `&self.reader`(이 구조체 안의 embedded reader 필드)도
        // 잡고 실행된다. heap 고정은 session/queue 객체만 보호하고 reader self 포인터는
        // 보호하지 않으므로, init()으로 reader.start()가 실행된 뒤에는 이 LivePtySession 값을
        // 절대 이동/복사하면 안 된다(by-value 반환, realloc되는 ArrayList/HashMap 저장 등).
        // 모든 호출부는 고정 지역변수(`var x: LivePtySession = undefined; x.init(&x, ...)`)로
        // 제자리에서 소유한다. 값 이동이 필요해지면 reader도 heap-pin하거나 LivePtySession
        // 자체를 heap에 둬야 한다.
        self.session = try allocator.create(pty.PtySession);
        var session_allocated = true;
        errdefer if (session_allocated) allocator.destroy(self.session);
        self.session.* = try pty.PtySession.spawn(allocator, request);
        var session_initialized = true;
        errdefer if (session_initialized) self.session.deinit();

        self.queue = try allocator.create(pty_reader.PtyEventQueue);
        var queue_allocated = true;
        errdefer if (queue_allocated) allocator.destroy(self.queue);
        self.queue.* = try pty_reader.PtyEventQueue.init(io, allocator, queue_capacity);
        var queue_initialized = true;
        errdefer if (queue_initialized) self.queue.deinit();

        self.reader = pty_reader.PtyReader.init(allocator, pty_id, self.session, self.queue);
        errdefer {
            queue_allocated = false;
            queue_initialized = false;
            session_allocated = false;
            session_initialized = false;
            self.queue.deinit();
            allocator.destroy(self.queue);
            self.session.deinit();
            allocator.destroy(self.session);
            self.* = undefined;
        }

        try self.reader.start();
        queue_allocated = false;
        queue_initialized = false;
        session_allocated = false;
        session_initialized = false;
    }

    pub fn deinit(self: *LivePtySession) void {
        self.close();
        self.queue.deinit();
        self.allocator.destroy(self.queue);
        self.session.deinit();
        self.allocator.destroy(self.session);
        self.* = undefined;
    }

    pub fn attachSurface(
        self: *LivePtySession,
        runtime: *runtime_mod.SurfaceRuntime,
        surface: *surface_mod.Surface,
    ) runtime_mod.RuntimeError!runtime_mod.RuntimeLink {
        // attach link도 live PTY owner가 기록한다. closeAndDetach가 이 link를 이용해
        // runtime routing을 먼저 끊으므로, 어느 PTY가 어느 surface와 연결됐는지는
        // 이 owner가 알아야 한다.
        const link = try runtime.attach(surface, self.pty_id, self.ptyIo());
        self.link = link;
        return link;
    }

    pub fn ptyIo(self: *LivePtySession) runtime_mod.PtyIo {
        return runtime_mod.PtyIo.fromSession(self.session);
    }

    pub fn eventQueue(self: *LivePtySession) *pty_reader.PtyEventQueue {
        return self.queue;
    }

    pub fn pump(self: *LivePtySession, runtime: *runtime_mod.SurfaceRuntime) runtime_pump.RuntimeEventPump {
        return runtime_pump.RuntimeEventPump.init(self.allocator, self.queue, runtime);
    }

    pub fn finishAfterTermination(self: *LivePtySession) void {
        // drain이 exit/read_error를 본 뒤에는 reader thread가 더 할 일이 없다.
        // 여기서 정상 join을 기록해 이후 artifact 작성 중 오류가 나도 close cleanup이
        // 이미 종료된 reader를 다시 stop하지 않게 한다.
        if (!self.reader_finished) {
            self.reader.join();
            self.reader_finished = true;
        }
        // 종료 관측 시점에 child를 직접 종료/reap한다. 정상 exit 경로는 reader가 EOF에서
        // 이미 reap했으므로 session.close()가 atomic 가드로 no-op이지만, read_error처럼
        // reader가 child를 reap하지 않고 끝난 경로에서는 여기서 reap해야 한다. 이 단계를
        // 빼면 reader_finished=true 이후의 close()/closeAndDetach 수명 경계가 else 분기로
        // 빠져 session.close()를 부르지 않으므로, child가 deinit() 전까지 좀비로 남는다.
        self.session.close();
        self.queue.close();
    }

    pub fn detachSurface(self: *LivePtySession, runtime: *runtime_mod.SurfaceRuntime) void {
        // Pane close는 surface routing부터 끊어야 한다. 그래야 닫힌 pane으로 늦게 도착한
        // output이나 input이 살아 있는 surface에 섞이지 않고 UnknownPty/UnknownSurface로
        // 떨어진다. 실제 PTY 종료는 close()가 맡고, detach는 runtime 연결만 제거한다.
        if (self.link) |link| {
            runtime.detachSurface(link.surface_id);
            self.link = null;
        }
    }

    pub fn closeAndDetach(self: *LivePtySession, runtime: *runtime_mod.SurfaceRuntime) void {
        // 실제 tab/window close command가 호출할 app-layer 수명 경계다.
        // detach와 PTY close 순서를 호출자마다 다시 쓰게 두면 late event 처리와 reader
        // cleanup이 갈라질 수 있으므로, owner가 하나의 idempotent operation으로 제공한다.
        self.detachSurface(runtime);
        self.close();
    }

    pub fn close(self: *LivePtySession) void {
        // 조기 실패, tab close, app quit은 같은 종료 순서를 타야 한다.
        // PtyReader.stopAndJoin이 queue.close -> session.close -> reader.join 순서를 소유하고,
        // 이 owner는 그 순서가 최대 한 번만 실행되도록 상태를 보관한다.
        if (!self.reader_finished) {
            self.reader.stopAndJoin();
            self.reader_finished = true;
        } else {
            self.queue.close();
        }
    }
};

test "live pty session owns controlled command until normal termination" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var live: LivePtySession = undefined;
    try live.init(std.testing.io, allocator, 10, .{
        .command = "/bin/sh",
        .args = &.{ "-c", "printf 'live owner\\n'" },
        .size = .{ .cols = 20, .rows = 3 },
    }, 4);
    defer live.deinit();

    var saw_output = false;
    while (true) {
        const event = live.eventQueue().popBlocking() orelse return error.LivePtyQueueClosedTooEarly;
        defer event.deinit(allocator);

        switch (event) {
            .output => |output| {
                if (std.mem.indexOf(u8, output.bytes, "live owner") != null) {
                    saw_output = true;
                }
            },
            .exited => break,
            .read_error => return error.LivePtyReadError,
        }
    }

    live.finishAfterTermination();
    try std.testing.expect(saw_output);
    try std.testing.expect(live.reader_finished);
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

test "live pty closeAndDetach removes runtime routing before closing the queue" {
    // 이 테스트는 실제 macOS PTY 없이 close lifecycle의 app-level 계약을 고정한다.
    // 핵심은 닫힌 pane이 runtime link에서 먼저 빠지고, reader가 이미 끝난 session이면
    // close가 queue만 닫아도 idempotent하게 동작한다는 점이다.
    const allocator = std.testing.allocator;
    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();

    var surface = try surface_mod.Surface.init(allocator, 1, .{ .cols = 20, .rows = 3 });
    defer surface.deinit();
    var fake_pty: FakePty = .{};
    const link = try runtime.attach(&surface, 10, fake_pty.io());

    var queue = try pty_reader.PtyEventQueue.init(std.testing.io, allocator, 1);
    defer queue.deinit();
    var live: LivePtySession = .{
        .allocator = allocator,
        .session = undefined,
        .queue = &queue,
        .reader = undefined,
        .pty_id = 10,
        .link = link,
        .reader_finished = true,
    };

    live.closeAndDetach(&runtime);
    try std.testing.expect(live.link == null);
    try std.testing.expectError(error.UnknownSurface, runtime.writeInput(1, .{ .bytes = "x" }));
    try std.testing.expectError(error.UnknownPty, runtime.applyPtyEvent(.{
        .output = .{ .pty_id = 10, .bytes = "late output" },
    }, std.testing.io));
    try std.testing.expectError(error.QueueClosed, queue.tryPush(.{
        .exited = .{ .pty_id = 10, .status = .{ .exited = 0 } },
    }));

    live.closeAndDetach(&runtime);
    try std.testing.expect(live.link == null);
}
