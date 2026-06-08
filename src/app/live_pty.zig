const builtin = @import("builtin");
const std = @import("std");
const pty = @import("../pty.zig");
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

        // PtyReader는 session/queue 포인터를 들고 실행된다. LivePtySession 값 자체가
        // 나중에 배열이나 app state 안에서 이동돼도 reader 포인터가 낡지 않도록,
        // thread가 참조하는 두 객체는 owner가 heap에 고정한다.
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
        // attach link도 live PTY owner가 기록한다. 아직 detach 정책은 실제 tab/window close
        // PR에서 정하지만, 어느 PTY가 어느 surface와 연결됐는지는 이 owner가 알아야 한다.
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
        self.queue.close();
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
