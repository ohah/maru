const std = @import("std");
const pty = @import("../pty.zig");
const runtime_mod = @import("runtime.zig");

pub const QueueError = std.mem.Allocator.Error || error{
    ZeroCapacity,
    QueueClosed,
    QueueFull,
};

pub const QueuedPtyEvent = union(enum) {
    output: struct {
        pty_id: runtime_mod.PtyId,
        bytes: []u8,
    },
    exited: struct {
        pty_id: runtime_mod.PtyId,
        status: pty.ExitStatus,
    },
    read_error: struct {
        pty_id: runtime_mod.PtyId,
        message: []const u8,
    },

    pub fn deinit(self: QueuedPtyEvent, allocator: std.mem.Allocator) void {
        switch (self) {
            .output => |output| allocator.free(output.bytes),
            .exited, .read_error => {},
        }
    }

    pub fn runtimeEvent(self: QueuedPtyEvent) runtime_mod.RuntimePtyEvent {
        return switch (self) {
            .output => |output| .{ .output = .{
                .pty_id = output.pty_id,
                .bytes = output.bytes,
            } },
            .exited => |exited| .{ .exited = .{
                .pty_id = exited.pty_id,
                .status = exited.status,
            } },
            .read_error => |read_error| .{ .read_error = .{
                .pty_id = read_error.pty_id,
                .message = read_error.message,
            } },
        };
    }
};

pub const PtyEventQueue = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    items: []QueuedPtyEvent,
    head: usize = 0,
    len: usize = 0,
    closed: bool = false,
    mutex: std.Io.Mutex = .init,
    not_empty: std.Io.Condition = .init,
    not_full: std.Io.Condition = .init,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, max_events: usize) QueueError!PtyEventQueue {
        if (max_events == 0) return error.ZeroCapacity;
        return .{
            .io = io,
            .allocator = allocator,
            .items = try allocator.alloc(QueuedPtyEvent, max_events),
        };
    }

    pub fn deinit(self: *PtyEventQueue) void {
        self.close();

        var index: usize = 0;
        while (index < self.len) : (index += 1) {
            const slot = (self.head + index) % self.items.len;
            self.items[slot].deinit(self.allocator);
        }
        self.allocator.free(self.items);
        self.* = undefined;
    }

    pub fn capacity(self: *const PtyEventQueue) usize {
        return self.items.len;
    }

    pub fn count(self: *PtyEventQueue) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.len;
    }

    pub fn close(self: *PtyEventQueue) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.closed = true;
        self.not_empty.broadcast(self.io);
        self.not_full.broadcast(self.io);
    }

    pub fn tryPush(self: *PtyEventQueue, event: QueuedPtyEvent) QueueError!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.closed) return error.QueueClosed;
        if (self.len == self.items.len) return error.QueueFull;
        self.pushAssumeLocked(event);
    }

    pub fn pushBlocking(self: *PtyEventQueue, event: QueuedPtyEvent) QueueError!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // PTY output은 버리면 안 된다. queue가 가득 차면 reader thread가 여기서
        // 기다리고, 그 결과 child stdout도 자연스럽게 느려진다. 이것이 문서화된
        // backpressure 정책이다.
        while (!self.closed and self.len == self.items.len) {
            self.not_full.waitUncancelable(self.io, &self.mutex);
        }
        if (self.closed) return error.QueueClosed;
        self.pushAssumeLocked(event);
    }

    pub fn tryPop(self: *PtyEventQueue) ?QueuedPtyEvent {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.len == 0) return null;
        return self.popAssumeLocked();
    }

    pub fn popBlocking(self: *PtyEventQueue) ?QueuedPtyEvent {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (!self.closed and self.len == 0) {
            self.not_empty.waitUncancelable(self.io, &self.mutex);
        }
        if (self.len == 0) return null;
        return self.popAssumeLocked();
    }

    fn pushAssumeLocked(self: *PtyEventQueue, event: QueuedPtyEvent) void {
        const tail = (self.head + self.len) % self.items.len;
        self.items[tail] = event;
        self.len += 1;
        self.not_empty.signal(self.io);
    }

    fn popAssumeLocked(self: *PtyEventQueue) QueuedPtyEvent {
        const event = self.items[self.head];
        self.head = (self.head + 1) % self.items.len;
        self.len -= 1;
        self.not_full.signal(self.io);
        return event;
    }
};

pub const PtyReader = struct {
    allocator: std.mem.Allocator,
    pty_id: runtime_mod.PtyId,
    session: *pty.PtySession,
    queue: *PtyEventQueue,
    thread: ?std.Thread = null,

    pub fn init(
        allocator: std.mem.Allocator,
        pty_id: runtime_mod.PtyId,
        session: *pty.PtySession,
        queue: *PtyEventQueue,
    ) PtyReader {
        return .{
            .allocator = allocator,
            .pty_id = pty_id,
            .session = session,
            .queue = queue,
        };
    }

    pub fn start(self: *PtyReader) !void {
        std.debug.assert(self.thread == null);
        self.thread = try std.Thread.spawn(.{}, readerMain, .{self});
    }

    pub fn join(self: *PtyReader) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    pub fn run(self: *PtyReader) void {
        while (true) {
            const event = self.session.readEvent(self.allocator) catch |err| {
                self.pushReadError(@errorName(err));
                return;
            };

            switch (event) {
                .output => |bytes| {
                    // readEvent가 allocator-owned bytes를 반환한다. push가 성공하면
                    // queue event가 소유권을 가져가고, consumer가 deinit한다.
                    // queue가 닫혀 push가 실패하면 reader가 즉시 해제해 누수를 막는다.
                    self.queue.pushBlocking(.{ .output = .{
                        .pty_id = self.pty_id,
                        .bytes = bytes,
                    } }) catch {
                        self.allocator.free(bytes);
                        return;
                    };
                },
                .exited => |status| {
                    self.queue.pushBlocking(.{ .exited = .{
                        .pty_id = self.pty_id,
                        .status = status,
                    } }) catch return;
                    return;
                },
            }
        }
    }

    fn pushReadError(self: *PtyReader, message: []const u8) void {
        self.queue.pushBlocking(.{ .read_error = .{
            .pty_id = self.pty_id,
            .message = message,
        } }) catch {};
    }

    fn readerMain(self: *PtyReader) void {
        self.run();
    }
};

test "pty event queue rejects zero capacity" {
    try std.testing.expectError(
        error.ZeroCapacity,
        PtyEventQueue.init(std.testing.io, std.testing.allocator, 0),
    );
}

test "pty event queue preserves event order and output ownership" {
    const allocator = std.testing.allocator;
    var queue = try PtyEventQueue.init(std.testing.io, allocator, 2);
    defer queue.deinit();

    const bytes = try allocator.dupe(u8, "hello");
    try queue.pushBlocking(.{ .output = .{ .pty_id = 7, .bytes = bytes } });
    try queue.pushBlocking(.{ .exited = .{ .pty_id = 7, .status = .{ .exited = 0 } } });

    const first = queue.popBlocking().?;
    defer first.deinit(allocator);
    try std.testing.expectEqual(runtime_mod.RuntimePtyEvent{
        .output = .{ .pty_id = 7, .bytes = bytes },
    }, first.runtimeEvent());

    const second = queue.popBlocking().?;
    defer second.deinit(allocator);
    try std.testing.expectEqual(runtime_mod.RuntimePtyEvent{
        .exited = .{ .pty_id = 7, .status = .{ .exited = 0 } },
    }, second.runtimeEvent());
}

test "pty event queue is bounded and reports full without allocating more" {
    const allocator = std.testing.allocator;
    var queue = try PtyEventQueue.init(std.testing.io, allocator, 1);
    defer queue.deinit();

    const first = try allocator.dupe(u8, "first");
    try queue.tryPush(.{ .output = .{ .pty_id = 1, .bytes = first } });

    const second = try allocator.dupe(u8, "second");
    errdefer allocator.free(second);
    try std.testing.expectError(
        error.QueueFull,
        queue.tryPush(.{ .output = .{ .pty_id = 1, .bytes = second } }),
    );
    allocator.free(second);

    const popped = queue.popBlocking().?;
    defer popped.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), queue.count());
}

test "pty event queue close stops new pushes and wakes empty consumers" {
    var queue = try PtyEventQueue.init(std.testing.io, std.testing.allocator, 1);
    defer queue.deinit();

    queue.close();
    try std.testing.expectError(
        error.QueueClosed,
        queue.pushBlocking(.{ .exited = .{ .pty_id = 1, .status = .{ .exited = 0 } } }),
    );
    try std.testing.expect(queue.popBlocking() == null);
}
