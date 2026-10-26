//! The runtime rejects dead adapters. A retained terminal still needs a view
//! grid matching its layout; this is the same host responsibility as macOS.
const std = @import("std");
const maru = @import("maru");
const Surface = maru.session.surface.Surface;
const Cell = maru.session.core_command.CellMetrics;

/// Only the warning produced by this font publication may be cleared on recovery.
/// Seeing another message revokes ownership even while a resize is still pending.
pub const RecoveryNotice = struct {
    owned: bool = false,
    eligible: bool = true,

    pub fn begin(self: *RecoveryNotice) void {
        self.* = .{};
    }

    pub fn failed(self: *RecoveryNotice, retryable: bool) void {
        self.eligible = self.eligible and retryable;
        self.owned = self.eligible;
    }

    pub fn recovered(self: *RecoveryNotice, pending: bool, permanent_error: bool, font_current: bool, message_matches: bool) bool {
        if (!self.owned) return false;
        if (!message_matches or permanent_error or !font_current) {
            self.owned = false;
            return false;
        }
        if (pending) return false;
        self.owned = false;
        return true;
    }
};

/// One latest layout per session, with no heap queue or borrowed font resources.
/// A failed PTY resize can follow a successful core resize; retain the desired
/// geometry until transport catches up instead of treating that as completion.
pub const Retry = struct {
    pub const Request = struct { size: maru.terminal.Size, cell: ?Cell };
    pending: ?Request = null,
    last_error: ?maru.app.RuntimeError = null,
    failures: u8 = 0,
    due_ns: i128 = 0,

    pub fn submit(self: *Retry, runtime: *maru.app.SurfaceRuntime, surface: *Surface, size: maru.terminal.Size, cell: ?Cell, now_ns: i128, io: std.Io) maru.app.RuntimeError!void {
        const pixels: ?Cell = if (cell) |c| (if (c.width != 0 and c.height != 0) c else null) else null;
        const desired: Request = .{ .size = maru.terminal.clampGridSize(size), .cell = pixels orelse if (self.pending) |old| old.cell else null };
        if (self.pending) |old| {
            if (std.meta.eql(old, desired)) {
                if (now_ns < self.due_ns) return self.last_error orelse error.ResizeFailed;
                return self.attempt(runtime, surface, now_ns, io);
            }
        }
        self.pending = desired;
        self.failures = 0;
        try self.attempt(runtime, surface, now_ns, io);
    }

    pub fn pump(self: *Retry, runtime: *maru.app.SurfaceRuntime, surface: *Surface, now_ns: i128, io: std.Io) maru.app.RuntimeError!bool {
        if (self.pending == null or now_ns < self.due_ns) return false;
        try self.attempt(runtime, surface, now_ns, io);
        return true;
    }

    fn attempt(self: *Retry, runtime: *maru.app.SurfaceRuntime, surface: *Surface, now_ns: i128, io: std.Io) maru.app.RuntimeError!void {
        const desired = self.pending orelse return;
        resizeAttempt(runtime, surface, desired.size, desired.cell, self.failures != 0, io) catch |err| {
            self.last_error = err;
            if (err != error.ResizeFailed and err != error.OutOfMemory) {
                self.pending = null;
                return err;
            }
            self.failures +|= 1;
            const shift: u6 = @intCast(@min(self.failures -| 1, 5));
            const delay: u64 = @min(@as(u64, 50 * std.time.ns_per_ms) << shift, std.time.ns_per_s);
            self.due_ns = now_ns +| @as(i128, delay);
            return err;
        };
        self.pending = null;
        self.last_error = null;
        self.failures = 0;
        self.due_ns = 0;
    }
};

pub fn resize(runtime: *maru.app.SurfaceRuntime, surface: *Surface, size: maru.terminal.Size, cell: ?Cell, io: std.Io) maru.app.RuntimeError!void {
    return resizeAttempt(runtime, surface, size, cell, false, io);
}

fn resizeAttempt(runtime: *maru.app.SurfaceRuntime, surface: *Surface, size: maru.terminal.Size, cell: ?Cell, retry_report: bool, io: std.Io) maru.app.RuntimeError!void {
    const pixels: ?Cell = if (cell) |c| (if (c.width != 0 and c.height != 0) c else null) else null;
    const result = if (retry_report) runtime.retryResizeWithCell(surface.id, size, pixels, io) else runtime.resizeWithCell(surface.id, size, pixels, io);
    result catch |err| {
        if (err != error.ProcessExited) return err;
        // The dead adapter stays closed. Layout owns the retained display grid,
        // following macOS resizeTermCoreToLayout without changing runtime APIs.
        const grid = maru.terminal.clampGridSize(size);
        surface.lockCore(io);
        defer surface.unlockCore(io);
        if (pixels) |p|
            try surface.core.resizeWithCellMetrics(grid.cols, grid.rows, p.width, p.height)
        else
            try surface.core.resize(grid.cols, grid.rows);
        // There is no receiver for in-band size notifications after termination.
        // Keep repeated layout changes from accumulating undeliverable replies.
        surface.core.clearResponse();
    };
}

const FakePty = struct {
    resizes: usize = 0,
    writes: usize = 0,
    size: maru.terminal.Size = .{ .cols = 0, .rows = 0 },
    cell: ?Cell = null,
    fail: bool = false,
    response: [128]u8 = undefined,
    response_len: usize = 0,
    surface: ?*Surface = null,
    flushes: usize = 0,
    flush_before_resize: bool = false,
    fn channel(self: *FakePty) maru.app.runtime.PtyIo {
        return .{ .ctx = self, .write_input = write, .resize_fn = resizePlain, .resize_with_cell_fn = resizeCell };
    }
    fn write(ctx: *anyopaque, bytes: []const u8) !void {
        const self: *FakePty = @ptrCast(@alignCast(ctx));
        @memcpy(self.response[0..bytes.len], bytes);
        self.response_len = bytes.len;
        self.writes += 1;
        try std.testing.expect(self.resizes > 0);
        try std.testing.expect(!self.fail);
    }
    fn flush(ctx: *anyopaque) void {
        const self: *FakePty = @ptrCast(@alignCast(ctx));
        self.flushes += 1;
        self.flush_before_resize = self.flush_before_resize or self.fail or self.resizes == 0;
        const core = &self.surface.?.core;
        const bytes = core.pendingResponse();
        @memcpy(self.response[0..bytes.len], bytes);
        self.response_len = bytes.len;
        core.clearResponse();
    }
    fn resizePlain(ctx: *anyopaque, size: maru.terminal.Size) !void {
        const self: *FakePty = @ptrCast(@alignCast(ctx));
        self.resizes += 1;
        self.size = size;
        if (self.fail) return error.TestResizeFailed;
    }
    fn resizeCell(ctx: *anyopaque, size: maru.terminal.Size, cell: Cell) !void {
        const self: *FakePty = @ptrCast(@alignCast(ctx));
        try resizePlain(ctx, size);
        self.cell = cell;
    }
};

const Fixture = struct {
    runtime: maru.app.SurfaceRuntime,
    surface: Surface,
    pty: FakePty = .{},
    fn init() !*Fixture {
        const a = std.testing.allocator;
        const self = try a.create(Fixture);
        errdefer a.destroy(self);
        self.* = .{ .runtime = maru.app.SurfaceRuntime.init(a), .surface = try Surface.init(a, 1, .{ .cols = 20, .rows = 3 }) };
        self.pty.surface = &self.surface;
        errdefer self.surface.deinit();
        errdefer self.runtime.deinit();
        _ = try self.runtime.attach(&self.surface, 10, self.pty.channel());
        try self.surface.core.resizeWithCellMetrics(20, 3, 9, 19);
        try self.surface.core.write("kept\x1b[?2048h");
        self.surface.core.clearResponse();
        return self;
    }
    fn deinit(self: *Fixture) void {
        self.runtime.deinit();
        self.surface.deinit();
        std.testing.allocator.destroy(self);
    }
    fn end(self: *Fixture) !void {
        try self.runtime.applyPtyEvent(.{ .exited = .{ .pty_id = 10, .status = .{ .exited = 0 } } }, std.testing.io);
    }
};

test "Windows layout resize running surface keeps runtime transport and notification" {
    const f = try Fixture.init();
    defer f.deinit();
    try resize(&f.runtime, &f.surface, .{ .cols = 42, .rows = 13 }, .{ .width = 12, .height = 26 }, std.testing.io);
    try std.testing.expectEqual(@as(usize, 1), f.pty.resizes);
    try std.testing.expectEqual(@as(usize, 1), f.pty.writes);
    try std.testing.expectEqual(Cell{ .width = 12, .height = 26 }, f.pty.cell.?);
    try std.testing.expectEqual(maru.terminal.Size{ .cols = 42, .rows = 13 }, f.surface.core.size);
}

test "Windows layout resize exited surface updates display pixels without dead transport" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.end();
    try resize(&f.runtime, &f.surface, .{ .cols = 42, .rows = 13 }, .{ .width = 12, .height = 26 }, std.testing.io);
    try std.testing.expectEqual(@as(u32, 12), f.surface.core.cell_width_px);
    try std.testing.expectEqual(@as(u32, 26), f.surface.core.cell_height_px);
    try std.testing.expectEqual(maru.session.surface.ProcessState.exited, f.surface.process_state);
    try std.testing.expectEqual(@as(usize, 0), f.pty.resizes);
    try std.testing.expectEqual(@as(usize, 0), f.pty.writes);
    try std.testing.expectEqual(@as(usize, 0), f.surface.core.pendingResponse().len);
    try std.testing.expectError(error.ProcessExited, f.runtime.writeInput(f.surface.id, .{ .bytes = "no" }));
    try std.testing.expectError(error.ProcessExited, f.runtime.resizeWithCell(f.surface.id, .{ .cols = 90, .rows = 20 }, null, std.testing.io));
    try std.testing.expectEqual(maru.terminal.Size{ .cols = 42, .rows = 13 }, f.surface.core.size);
    const body = try f.surface.core.dumpUtf8(std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "kept") != null);
}

test "Windows layout resize retained zero pixels preserve known metrics and clamp grid" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.end();
    for ([_]?Cell{ null, .{ .width = 0, .height = 17 }, .{ .width = 12, .height = 0 } }) |cell| {
        try resize(&f.runtime, &f.surface, .{ .cols = 1, .rows = 0 }, cell, std.testing.io);
        try std.testing.expectEqual(maru.terminal.Size{ .cols = 2, .rows = 1 }, f.surface.core.size);
        try std.testing.expectEqual(@as(u32, 9), f.surface.core.cell_width_px);
        try std.testing.expectEqual(@as(u32, 19), f.surface.core.cell_height_px);
        try std.testing.expectEqual(@as(usize, 0), f.surface.core.pendingResponse().len);
    }
    try std.testing.expectEqual(@as(usize, 0), f.pty.resizes);
}

test "Windows layout resize reader error retains display and drains repeated size responses" {
    const f = try Fixture.init();
    defer f.deinit();
    try std.testing.expectError(error.ReadFailed, f.runtime.applyPtyEvent(.{ .read_error = .{ .pty_id = 10, .message = "fixture" } }, std.testing.io));
    for ([_]u16{ 30, 40, 20 }) |cols| {
        try resize(&f.runtime, &f.surface, .{ .cols = cols, .rows = 5 }, .{ .width = 11, .height = 23 }, std.testing.io);
        try std.testing.expectEqual(@as(usize, 0), f.surface.core.pendingResponse().len);
        try std.testing.expectEqual(cols, f.surface.core.size.cols);
    }
    try std.testing.expectEqual(@as(usize, 0), f.pty.resizes);
    try std.testing.expectEqual(@as(usize, 0), f.pty.writes);
}

test "Windows layout resize preserves unknown surface and live backend errors" {
    const f = try Fixture.init();
    defer f.deinit();
    var unknown = maru.app.SurfaceRuntime.init(std.testing.allocator);
    defer unknown.deinit();
    try std.testing.expectError(error.UnknownSurface, resize(&unknown, &f.surface, .{ .cols = 42, .rows = 13 }, null, std.testing.io));
    try std.testing.expectEqual(maru.terminal.Size{ .cols = 20, .rows = 3 }, f.surface.core.size);
    try std.testing.expectEqual(@as(usize, 0), f.pty.resizes);
    f.pty.fail = true;
    try std.testing.expectError(error.ResizeFailed, resize(&f.runtime, &f.surface, .{ .cols = 42, .rows = 13 }, null, std.testing.io));
    try std.testing.expectEqual(@as(usize, 1), f.pty.resizes);
    try std.testing.expectEqual(maru.session.surface.ProcessState.running, f.surface.process_state);
}

test "Windows layout retry recovers partial core success after its deadline" {
    const f = try Fixture.init();
    defer f.deinit();
    var retry: Retry = .{};
    f.pty.fail = true;
    try std.testing.expectError(error.ResizeFailed, retry.submit(&f.runtime, &f.surface, .{ .cols = 42, .rows = 13 }, .{ .width = 12, .height = 26 }, 0, std.testing.io));
    try std.testing.expectEqual(maru.terminal.Size{ .cols = 42, .rows = 13 }, f.surface.core.size);
    try std.testing.expect(retry.pending != null);
    try std.testing.expectEqual(@as(usize, 0), f.pty.writes);
    f.pty.fail = false;
    try std.testing.expect(!try retry.pump(&f.runtime, &f.surface, retry.due_ns - 1, std.testing.io));
    try std.testing.expectEqual(@as(usize, 1), f.pty.resizes);
    try std.testing.expect(try retry.pump(&f.runtime, &f.surface, retry.due_ns, std.testing.io));
    try std.testing.expect(retry.pending == null and retry.last_error == null);
    try std.testing.expectEqual(Cell{ .width = 12, .height = 26 }, f.pty.cell.?);
    try std.testing.expectEqual(@as(usize, 2), f.pty.resizes);
    // A failed transport must not lose the notification when the grid is already new.
    try std.testing.expectEqual(@as(usize, 1), f.pty.writes);
    try std.testing.expectEqualStrings("\x1b[48;13;42;338;504t", f.pty.response[0..f.pty.response_len]);
}

test "Windows layout retry latest size preserves pending font pixels" {
    const f = try Fixture.init();
    defer f.deinit();
    var retry: Retry = .{};
    f.pty.fail = true;
    try std.testing.expectError(error.ResizeFailed, retry.submit(&f.runtime, &f.surface, .{ .cols = 42, .rows = 13 }, .{ .width = 12, .height = 26 }, 0, std.testing.io));
    try std.testing.expectError(error.ResizeFailed, retry.submit(&f.runtime, &f.surface, .{ .cols = 50, .rows = 15 }, null, 1, std.testing.io));
    try std.testing.expectEqual(@as(u16, 50), retry.pending.?.size.cols);
    f.pty.fail = false;
    _ = try retry.pump(&f.runtime, &f.surface, retry.due_ns, std.testing.io);
    try std.testing.expectEqual(maru.terminal.Size{ .cols = 50, .rows = 15 }, f.pty.size);
    try std.testing.expect(f.pty.cell != null);
    try std.testing.expectEqual(Cell{ .width = 12, .height = 26 }, f.pty.cell.?);
    try std.testing.expectEqualStrings("\x1b[48;15;50;390;600t", f.pty.response[0..f.pty.response_len]);
}

test "Windows layout retry caps backoff and duplicate requests do not spin" {
    const f = try Fixture.init();
    defer f.deinit();
    var retry: Retry = .{};
    f.pty.fail = true;
    const size: maru.terminal.Size = .{ .cols = 42, .rows = 13 };
    try std.testing.expectError(error.ResizeFailed, retry.submit(&f.runtime, &f.surface, size, null, 0, std.testing.io));
    try std.testing.expectEqual(@as(i128, 50 * std.time.ns_per_ms), retry.due_ns);
    try std.testing.expectError(error.ResizeFailed, retry.submit(&f.runtime, &f.surface, size, null, 1, std.testing.io));
    try std.testing.expectEqual(@as(usize, 1), f.pty.resizes);
    for ([_]u64{ 100, 200, 400, 800, 1000, 1000 }) |delay_ms| {
        const due = retry.due_ns;
        try std.testing.expect(!try retry.pump(&f.runtime, &f.surface, due - 1, std.testing.io));
        try std.testing.expectError(error.ResizeFailed, retry.pump(&f.runtime, &f.surface, due, std.testing.io));
        try std.testing.expectEqual(@as(i128, delay_ms * std.time.ns_per_ms), retry.due_ns - due);
    }
}

test "Windows layout retry exit settles display without retrying dead transport" {
    const f = try Fixture.init();
    defer f.deinit();
    var retry: Retry = .{};
    f.pty.fail = true;
    try std.testing.expectError(error.ResizeFailed, retry.submit(&f.runtime, &f.surface, .{ .cols = 42, .rows = 13 }, .{ .width = 12, .height = 26 }, 0, std.testing.io));
    try f.end();
    _ = try retry.pump(&f.runtime, &f.surface, retry.due_ns, std.testing.io);
    try std.testing.expect(retry.pending == null);
    try std.testing.expectEqual(@as(usize, 1), f.pty.resizes);
    try std.testing.expectEqual(@as(usize, 0), f.surface.core.pendingResponse().len);
}

test "Windows layout retry unknown and detached surfaces never remain queued" {
    const f = try Fixture.init();
    defer f.deinit();
    var retry: Retry = .{};
    var unknown = maru.app.SurfaceRuntime.init(std.testing.allocator);
    defer unknown.deinit();
    try std.testing.expectError(error.UnknownSurface, retry.submit(&unknown, &f.surface, .{ .cols = 42, .rows = 13 }, null, 0, std.testing.io));
    try std.testing.expect(retry.pending == null);
    f.pty.fail = true;
    try std.testing.expectError(error.ResizeFailed, retry.submit(&f.runtime, &f.surface, .{ .cols = 42, .rows = 13 }, null, 0, std.testing.io));
    f.runtime.detachSurface(f.surface.id);
    try std.testing.expectError(error.UnknownSurface, retry.pump(&f.runtime, &f.surface, retry.due_ns, std.testing.io));
    try std.testing.expect(retry.pending == null);
    try std.testing.expect(!try retry.pump(&f.runtime, &f.surface, std.math.maxInt(i128), std.testing.io));
}


test "Windows layout retry notice clears once after full recovery" {
    var notice: RecoveryNotice = .{};
    notice.begin();
    notice.failed(true);
    try std.testing.expect(notice.recovered(false, false, true, true));
    try std.testing.expect(!notice.recovered(false, false, true, true));
}

test "Windows layout retry notice waits for every pending session" {
    var notice: RecoveryNotice = .{};
    notice.failed(true);
    try std.testing.expect(!notice.recovered(true, false, true, true));
    try std.testing.expect(!notice.recovered(true, false, true, true));
    try std.testing.expect(notice.recovered(false, false, true, true));
}

test "Windows layout retry notice preserves permanent errors regardless of session order" {
    var notice: RecoveryNotice = .{};
    notice.failed(false);
    notice.failed(true);
    try std.testing.expect(!notice.recovered(false, false, true, true));
    notice.begin();
    notice.failed(true);
    try std.testing.expect(!notice.recovered(false, true, true, true));
}

test "Windows layout retry notice revokes replaced warning while still pending" {
    var notice: RecoveryNotice = .{};
    notice.failed(true);
    try std.testing.expect(!notice.recovered(true, false, true, false));
    try std.testing.expect(!notice.recovered(false, false, true, true));
}

test "Windows layout retry notice cannot clear a newer font preparation failure" {
    var notice: RecoveryNotice = .{};
    notice.failed(true);
    notice.begin();
    try std.testing.expect(!notice.recovered(false, false, true, true));
    notice.failed(true);
    try std.testing.expect(!notice.recovered(false, false, false, true));
    try std.testing.expect(!notice.recovered(false, false, true, true));
}


test "Windows layout retry reader receives latest report only after transport success" {
    const f = try Fixture.init();
    defer f.deinit();
    f.runtime.detachSurface(f.surface.id);
    var channel = f.pty.channel();
    channel.request_response_flush = FakePty.flush;
    _ = try f.runtime.attach(&f.surface, 10, channel);
    var retry: Retry = .{};
    f.pty.fail = true;
    try std.testing.expectError(error.ResizeFailed, retry.submit(&f.runtime, &f.surface, .{ .cols = 42, .rows = 13 }, .{ .width = 12, .height = 26 }, 0, std.testing.io));
    try std.testing.expectEqual(@as(usize, 0), f.pty.flushes);
    try std.testing.expectEqual(@as(usize, 0), f.surface.core.pendingResponse().len);
    f.pty.fail = false;
    try std.testing.expect(try retry.pump(&f.runtime, &f.surface, retry.due_ns, std.testing.io));
    try std.testing.expectEqual(@as(usize, 1), f.pty.flushes);
    try std.testing.expect(!f.pty.flush_before_resize);
    try std.testing.expectEqualStrings("\x1b[48;13;42;338;504t", f.pty.response[0..f.pty.response_len]);
    try std.testing.expect(!try retry.pump(&f.runtime, &f.surface, retry.due_ns, std.testing.io));
    try std.testing.expectEqual(@as(usize, 1), f.pty.flushes);
    try std.testing.expectEqual(@as(usize, 0), f.pty.writes);
}
