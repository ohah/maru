const std = @import("std");
const pty = @import("../pty.zig");
const terminal = @import("../terminal.zig");
const surface_mod = @import("surface.zig");

pub const SurfaceId = u64;
pub const PtyId = u64;

pub const RuntimeError = std.mem.Allocator.Error || error{
    UnknownSurface,
    UnknownPty,
    SurfaceAlreadyAttached,
    PtyAlreadyAttached,
    ProcessExited,
    WriteFailed,
    ResizeFailed,
    ReadFailed,
    InvalidOutput,
};

pub const RuntimeLink = struct {
    surface_id: SurfaceId,
    pty_id: PtyId,
};

pub const TerminalInput = struct {
    bytes: []const u8,
};

pub const RuntimePtyEvent = union(enum) {
    output: struct {
        pty_id: PtyId,
        bytes: []const u8,
    },
    exited: struct {
        pty_id: PtyId,
        status: pty.ExitStatus,
    },
    read_error: struct {
        pty_id: PtyId,
        message: []const u8,
    },
};

// SurfaceRuntime은 실제 macOS PTY를 직접 알아서는 안 된다. 이 adapter는
// runtime이 필요한 "input 쓰기"와 "resize 전달"만 노출해서, routing 테스트가
// OS process 없이 fake PTY로 같은 계약을 검증할 수 있게 한다.
pub const PtyIo = struct {
    ctx: *anyopaque,
    write_input: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void,
    resize_fn: *const fn (ctx: *anyopaque, size: terminal.Size) anyerror!void,

    pub fn fromSession(session: *pty.PtySession) PtyIo {
        return .{
            .ctx = session,
            .write_input = writeSessionInput,
            .resize_fn = resizeSession,
        };
    }

    pub fn writeInput(self: PtyIo, bytes: []const u8) !void {
        try self.write_input(self.ctx, bytes);
    }

    pub fn resize(self: PtyIo, size: terminal.Size) !void {
        try self.resize_fn(self.ctx, size);
    }

    fn writeSessionInput(ctx: *anyopaque, bytes: []const u8) !void {
        const session: *pty.PtySession = @ptrCast(@alignCast(ctx));
        try session.writeInput(bytes);
    }

    fn resizeSession(ctx: *anyopaque, size: terminal.Size) !void {
        const session: *pty.PtySession = @ptrCast(@alignCast(ctx));
        try session.resize(size);
    }
};

pub const SurfaceRuntime = struct {
    allocator: std.mem.Allocator,
    links: std.ArrayList(Link) = .empty,

    pub fn init(allocator: std.mem.Allocator) SurfaceRuntime {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SurfaceRuntime) void {
        self.links.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn attach(
        self: *SurfaceRuntime,
        surface_id: SurfaceId,
        surface: *surface_mod.Surface,
        pty_id: PtyId,
        pty_io: PtyIo,
    ) RuntimeError!RuntimeLink {
        // live handle은 Surface에 저장하지 않고 runtime의 연결 표에만 둔다.
        // 그래야 workspace restore가 저장 가능한 metadata와 process handle을 섞지 않는다.
        if (self.findBySurface(surface_id) != null) return error.SurfaceAlreadyAttached;
        if (self.findByPty(pty_id) != null) return error.PtyAlreadyAttached;

        try self.links.append(self.allocator, .{
            .surface_id = surface_id,
            .surface = surface,
            .pty_id = pty_id,
            .pty_io = pty_io,
        });

        surface.process_state = .running;
        return .{ .surface_id = surface_id, .pty_id = pty_id };
    }

    pub fn detachSurface(self: *SurfaceRuntime, surface_id: SurfaceId) void {
        if (self.findBySurface(surface_id)) |index| {
            _ = self.links.orderedRemove(index);
        }
    }

    pub fn writeInput(self: *SurfaceRuntime, surface_id: SurfaceId, input: TerminalInput) RuntimeError!void {
        const link = self.linkBySurface(surface_id) orelse return error.UnknownSurface;
        if (link.surface.process_state == .exited) return error.ProcessExited;
        link.pty_io.writeInput(input.bytes) catch return error.WriteFailed;
    }

    pub fn resize(self: *SurfaceRuntime, surface_id: SurfaceId, size: terminal.Size) RuntimeError!void {
        const link = self.linkBySurface(surface_id) orelse return error.UnknownSurface;
        if (link.surface.process_state == .exited) return error.ProcessExited;

        try link.surface.core.resize(size.cols, size.rows);
        link.pty_io.resize(size) catch return error.ResizeFailed;
    }

    pub fn applyPtyEvent(self: *SurfaceRuntime, event: RuntimePtyEvent) RuntimeError!void {
        switch (event) {
            .output => |output| {
                // PTY bytes는 여기서 해석하지 않고 TerminalCore로만 전달한다.
                // escape parsing과 UTF-8 tail buffering은 terminal layer 책임이다.
                const link = self.linkByPty(output.pty_id) orelse return error.UnknownPty;
                if (link.surface.process_state == .exited) return error.ProcessExited;
                link.surface.core.write(output.bytes) catch return error.InvalidOutput;
                link.surface.process_state = .running;
            },
            .exited => |exited| {
                const link = self.linkByPty(exited.pty_id) orelse return error.UnknownPty;
                _ = exited.status;
                link.surface.process_state = .exited;
            },
            .read_error => |read_error| {
                _ = read_error.message;
                if (self.linkByPty(read_error.pty_id) == null) return error.UnknownPty;
                return error.ReadFailed;
            },
        }
    }

    fn linkBySurface(self: *SurfaceRuntime, surface_id: SurfaceId) ?*Link {
        if (self.findBySurface(surface_id)) |index| return &self.links.items[index];
        return null;
    }

    fn linkByPty(self: *SurfaceRuntime, pty_id: PtyId) ?*Link {
        if (self.findByPty(pty_id)) |index| return &self.links.items[index];
        return null;
    }

    fn findBySurface(self: *const SurfaceRuntime, surface_id: SurfaceId) ?usize {
        for (self.links.items, 0..) |link, index| {
            if (link.surface_id == surface_id) return index;
        }
        return null;
    }

    fn findByPty(self: *const SurfaceRuntime, pty_id: PtyId) ?usize {
        for (self.links.items, 0..) |link, index| {
            if (link.pty_id == pty_id) return index;
        }
        return null;
    }
};

const Link = struct {
    surface_id: SurfaceId,
    surface: *surface_mod.Surface,
    pty_id: PtyId,
    pty_io: PtyIo,
};

const FakePty = struct {
    allocator: std.mem.Allocator,
    writes: std.ArrayList(u8) = .empty,
    resize_calls: usize = 0,
    last_size: ?terminal.Size = null,
    fail_write: bool = false,
    fail_resize: bool = false,

    fn init(allocator: std.mem.Allocator) FakePty {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *FakePty) void {
        self.writes.deinit(self.allocator);
    }

    fn io(self: *FakePty) PtyIo {
        return .{
            .ctx = self,
            .write_input = fakeWriteInput,
            .resize_fn = fakeResize,
        };
    }

    fn fakeWriteInput(ctx: *anyopaque, bytes: []const u8) !void {
        const self: *FakePty = @ptrCast(@alignCast(ctx));
        if (self.fail_write) return error.FakeWriteFailed;
        try self.writes.appendSlice(self.allocator, bytes);
    }

    fn fakeResize(ctx: *anyopaque, size: terminal.Size) !void {
        const self: *FakePty = @ptrCast(@alignCast(ctx));
        if (self.fail_resize) return error.FakeResizeFailed;
        self.resize_calls += 1;
        self.last_size = size;
    }
};

test "runtime rejects input for an unattached surface" {
    var runtime = SurfaceRuntime.init(std.testing.allocator);
    defer runtime.deinit();

    try std.testing.expectError(
        error.UnknownSurface,
        runtime.writeInput(1, .{ .bytes = "hello" }),
    );
}

test "runtime rejects duplicate surface and pty attachments" {
    const allocator = std.testing.allocator;
    var runtime = SurfaceRuntime.init(allocator);
    defer runtime.deinit();

    var surface_a = try surface_mod.Surface.init(allocator, 1, terminal.Size.default);
    defer surface_a.deinit();
    var surface_b = try surface_mod.Surface.init(allocator, 2, terminal.Size.default);
    defer surface_b.deinit();

    var pty_a = FakePty.init(allocator);
    defer pty_a.deinit();
    var pty_b = FakePty.init(allocator);
    defer pty_b.deinit();

    _ = try runtime.attach(1, &surface_a, 10, pty_a.io());
    try std.testing.expectError(
        error.SurfaceAlreadyAttached,
        runtime.attach(1, &surface_a, 11, pty_b.io()),
    );
    try std.testing.expectError(
        error.PtyAlreadyAttached,
        runtime.attach(2, &surface_b, 10, pty_b.io()),
    );
}

test "runtime routes pty output to the matching surface core" {
    const allocator = std.testing.allocator;
    var runtime = SurfaceRuntime.init(allocator);
    defer runtime.deinit();

    var surface_a = try surface_mod.Surface.init(allocator, 1, .{ .cols = 20, .rows = 3 });
    defer surface_a.deinit();
    var surface_b = try surface_mod.Surface.init(allocator, 2, .{ .cols = 20, .rows = 3 });
    defer surface_b.deinit();

    var pty_a = FakePty.init(allocator);
    defer pty_a.deinit();
    var pty_b = FakePty.init(allocator);
    defer pty_b.deinit();

    _ = try runtime.attach(1, &surface_a, 10, pty_a.io());
    _ = try runtime.attach(2, &surface_b, 20, pty_b.io());

    try runtime.applyPtyEvent(.{ .output = .{ .pty_id = 20, .bytes = "runtime" } });

    const screen_a = try surface_a.core.dumpUtf8(allocator);
    defer allocator.free(screen_a);
    const screen_b = try surface_b.core.dumpUtf8(allocator);
    defer allocator.free(screen_b);

    try std.testing.expect(std.mem.indexOf(u8, screen_a, "runtime") == null);
    try std.testing.expect(std.mem.indexOf(u8, screen_b, "runtime") != null);
    try std.testing.expectEqual(surface_mod.ProcessState.running, surface_b.process_state);
}

test "runtime sends terminal input through the attached pty io" {
    const allocator = std.testing.allocator;
    var runtime = SurfaceRuntime.init(allocator);
    defer runtime.deinit();

    var surface = try surface_mod.Surface.init(allocator, 1, terminal.Size.default);
    defer surface.deinit();
    var fake_pty = FakePty.init(allocator);
    defer fake_pty.deinit();

    _ = try runtime.attach(1, &surface, 10, fake_pty.io());
    try runtime.writeInput(1, .{ .bytes = "abc" });

    try std.testing.expectEqualStrings("abc", fake_pty.writes.items);
}

test "runtime maps pty input failures to WriteFailed" {
    const allocator = std.testing.allocator;
    var runtime = SurfaceRuntime.init(allocator);
    defer runtime.deinit();

    var surface = try surface_mod.Surface.init(allocator, 1, terminal.Size.default);
    defer surface.deinit();
    var fake_pty = FakePty.init(allocator);
    defer fake_pty.deinit();
    fake_pty.fail_write = true;

    _ = try runtime.attach(1, &surface, 10, fake_pty.io());

    try std.testing.expectError(
        error.WriteFailed,
        runtime.writeInput(1, .{ .bytes = "abc" }),
    );
}

test "runtime resize updates core and pty io together" {
    const allocator = std.testing.allocator;
    var runtime = SurfaceRuntime.init(allocator);
    defer runtime.deinit();

    var surface = try surface_mod.Surface.init(allocator, 1, .{ .cols = 20, .rows = 5 });
    defer surface.deinit();
    var fake_pty = FakePty.init(allocator);
    defer fake_pty.deinit();

    _ = try runtime.attach(1, &surface, 10, fake_pty.io());
    try runtime.resize(1, .{ .cols = 42, .rows = 13 });

    try std.testing.expectEqual(terminal.Size{ .cols = 42, .rows = 13 }, surface.core.size);
    try std.testing.expectEqual(@as(usize, 1), fake_pty.resize_calls);
    try std.testing.expectEqual(terminal.Size{ .cols = 42, .rows = 13 }, fake_pty.last_size.?);
}

test "runtime maps pty resize failures to ResizeFailed after updating the surface size" {
    const allocator = std.testing.allocator;
    var runtime = SurfaceRuntime.init(allocator);
    defer runtime.deinit();

    var surface = try surface_mod.Surface.init(allocator, 1, .{ .cols = 20, .rows = 5 });
    defer surface.deinit();
    var fake_pty = FakePty.init(allocator);
    defer fake_pty.deinit();
    fake_pty.fail_resize = true;

    _ = try runtime.attach(1, &surface, 10, fake_pty.io());

    try std.testing.expectError(
        error.ResizeFailed,
        runtime.resize(1, .{ .cols = 42, .rows = 13 }),
    );
    try std.testing.expectEqual(terminal.Size{ .cols = 42, .rows = 13 }, surface.core.size);
}

test "runtime detaches surface and rejects late pty output" {
    const allocator = std.testing.allocator;
    var runtime = SurfaceRuntime.init(allocator);
    defer runtime.deinit();

    var surface = try surface_mod.Surface.init(allocator, 1, terminal.Size.default);
    defer surface.deinit();
    var fake_pty = FakePty.init(allocator);
    defer fake_pty.deinit();

    _ = try runtime.attach(1, &surface, 10, fake_pty.io());
    runtime.detachSurface(1);

    try std.testing.expectError(
        error.UnknownPty,
        runtime.applyPtyEvent(.{ .output = .{ .pty_id = 10, .bytes = "late" } }),
    );
    try std.testing.expectError(
        error.UnknownSurface,
        runtime.writeInput(1, .{ .bytes = "ignored" }),
    );
}

test "runtime marks a surface exited and blocks further input" {
    const allocator = std.testing.allocator;
    var runtime = SurfaceRuntime.init(allocator);
    defer runtime.deinit();

    var surface = try surface_mod.Surface.init(allocator, 1, terminal.Size.default);
    defer surface.deinit();
    var fake_pty = FakePty.init(allocator);
    defer fake_pty.deinit();

    _ = try runtime.attach(1, &surface, 10, fake_pty.io());
    try runtime.applyPtyEvent(.{ .exited = .{ .pty_id = 10, .status = .{ .exited = 0 } } });

    try std.testing.expectEqual(surface_mod.ProcessState.exited, surface.process_state);
    try std.testing.expectError(
        error.ProcessExited,
        runtime.writeInput(1, .{ .bytes = "after-exit" }),
    );
}

test "runtime reports pty read errors without tracing them as output" {
    const allocator = std.testing.allocator;
    var runtime = SurfaceRuntime.init(allocator);
    defer runtime.deinit();

    var surface = try surface_mod.Surface.init(allocator, 1, terminal.Size.default);
    defer surface.deinit();
    var fake_pty = FakePty.init(allocator);
    defer fake_pty.deinit();

    _ = try runtime.attach(1, &surface, 10, fake_pty.io());

    try std.testing.expectError(
        error.ReadFailed,
        runtime.applyPtyEvent(.{ .read_error = .{ .pty_id = 10, .message = "read failed" } }),
    );
}
