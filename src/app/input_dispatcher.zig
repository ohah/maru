//! A host-owned ordered input producer. Bytes and inline core commands share
//! byte barriers so a partial protocol reply cannot be overtaken by later input.
const std = @import("std");
const runtime = @import("runtime.zig");
const typed = @import("typed_input_queue.zig");
const command = @import("../session/core_command.zig");
const Control = struct { fence: usize, value: command.CoreCommand };
const Pending = struct {
    bytes: typed.Queue = .{},
    controls: std.ArrayList(Control) = .empty,
    head: usize = 0,
    fn reset(self: *Pending, a: std.mem.Allocator) void {
        self.bytes.reset(a);
        if (self.controls.capacity > typed.retain_max / @sizeOf(Control)) self.controls.clearAndFree(a) else self.controls.clearRetainingCapacity();
        self.head = 0;
    }
    fn deinit(self: *Pending, a: std.mem.Allocator) void {
        self.bytes.deinit(a);
        self.controls.deinit(a);
    }
};

pub const Dispatcher = struct {
    allocator: std.mem.Allocator,
    target: *runtime.SurfaceRuntime,
    pending: std.AutoHashMapUnmanaged(runtime.SurfaceId, Pending) = .empty,

    /// Install only after this owner has reached its stable address. Each
    /// runtime has one producer; silently replacing it would lose queued input.
    pub fn install(self: *Dispatcher) !void {
        if (self.target.input_admission != null) return error.AlreadyInstalled;
        self.target.input_admission = .{ .context = self, .bytes = admitBytes, .command = admitCommand, .drop = drop };
    }
    pub fn deinit(self: *Dispatcher) void {
        if (self.target.input_admission) |hook| {
            if (hook.context == @as(*anyopaque, @ptrCast(self))) self.target.input_admission = null;
        }
        var it = self.pending.valueIterator();
        while (it.next()) |p| p.deinit(self.allocator);
        self.pending.deinit(self.allocator);
    }
    fn owner(ctx: *anyopaque) *Dispatcher {
        return @ptrCast(@alignCast(ctx));
    }
    fn admitBytes(ctx: *anyopaque, id: runtime.SurfaceId, bytes: []const u8, sensitive: bool) runtime.RuntimeError!void {
        const self = owner(ctx);
        if (bytes.len == 0) return;
        const entry = try self.pending.getOrPut(self.allocator, id);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        errdefer if (!entry.found_existing) {
            entry.value_ptr.deinit(self.allocator);
            _ = self.pending.remove(id);
        };
        entry.value_ptr.bytes.append(self.allocator, .{ .kind = if (sensitive) .osc52_response else .paste, .first = bytes }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable, // Raw admission never requests newline conversion.
        };
    }
    fn admitCommand(ctx: *anyopaque, id: runtime.SurfaceId, cmd: command.CoreCommand) runtime.RuntimeError!void {
        const self = owner(ctx);
        const entry = try self.pending.getOrPut(self.allocator, id);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        errdefer if (!entry.found_existing) {
            entry.value_ptr.deinit(self.allocator);
            _ = self.pending.remove(id);
        };
        try entry.value_ptr.controls.append(self.allocator, .{ .fence = entry.value_ptr.bytes.buf.items.len, .value = cmd });
    }
    fn drop(ctx: *anyopaque, id: runtime.SurfaceId) void {
        const self = owner(ctx);
        if (self.pending.fetchRemove(id)) |removed| {
            var p = removed.value;
            p.deinit(self.allocator);
        }
    }
    pub fn flush(self: *Dispatcher) void {
        var it = self.pending.iterator();
        while (it.next()) |entry| self.flushOne(entry.key_ptr.*, entry.value_ptr) catch |err| {
            if (typed.discardOnError(err)) entry.value_ptr.reset(self.allocator);
        };
    }
    fn flushOne(self: *Dispatcher, id: runtime.SurfaceId, p: *Pending) runtime.RuntimeError!void {
        var wrote = false;
        // Bound work independently of the byte budget: a run of controls must
        // not monopolize a UI tick while another surface needs repainting.
        var budget: usize = 64;
        while (budget > 0) : (budget -= 1) {
            if (p.head < p.controls.items.len) {
                const next = p.controls.items[p.head];
                if (next.fence == p.bytes.offset) {
                    if (!try self.target.flushCoreCommandNonBlocking(id, next.value)) return;
                    p.head += 1;
                    continue;
                }
            }
            const chunk = p.bytes.next() orelse {
                std.debug.assert(p.head == p.controls.items.len);
                p.reset(self.allocator);
                return;
            };
            if (wrote) return;
            const end = if (p.head < p.controls.items.len) p.controls.items[p.head].fence else p.bytes.buf.items.len;
            std.debug.assert(end > p.bytes.offset);
            const bytes = chunk.bytes[0..@min(chunk.bytes.len, end - p.bytes.offset)];
            const n = try self.target.flushInputChunkNonBlocking(id, bytes, chunk.sensitive);
            p.bytes.advance(n) catch return error.WriteFailed;
            if (n == 0) return;
            wrote = true;
        }
    }
};

const Probe = struct {
    output: std.ArrayList(u8) = .empty,
    limit: usize = std.math.maxInt(usize),
    commands_ready: bool = true,
    blocking_called: bool = false,
    fn write(ctx: *anyopaque, bytes: []const u8) !usize {
        const self: *Probe = @ptrCast(@alignCast(ctx));
        const n = @min(self.limit, bytes.len);
        try self.output.appendSlice(std.testing.allocator, bytes[0..n]);
        return n;
    }
    fn control(ctx: *anyopaque, _: command.CoreCommand) !bool {
        const self: *Probe = @ptrCast(@alignCast(ctx));
        if (!self.commands_ready) return false;
        try self.output.append(std.testing.allocator, '#');
        return true;
    }
    fn blocking(ctx: *anyopaque, _: []const u8) !void {
        const self: *Probe = @ptrCast(@alignCast(ctx));
        self.blocking_called = true;
        return error.ForbiddenBlocking;
    }
    fn resize(_: *anyopaque, _: @import("../terminal.zig").Size) !void {}
};
// In-place initialization keeps borrowed runtime, recorder and callback pointers
// stable. This exercises public admission and physical flush as separate steps.
const Fixture = struct {
    target: runtime.SurfaceRuntime,
    surface: @import("../session/surface.zig").Surface,
    dispatcher: Dispatcher,
    probe: Probe,
    trace: std.Io.Writer.Allocating,
    recorder: @import("trace_recorder.zig").TraceRecorder,
    fn init(self: *Fixture, a: std.mem.Allocator) !void {
        self.target = .init(std.testing.allocator);
        self.surface = try .init(std.testing.allocator, 45, .{ .cols = 8, .rows = 2 });
        self.probe = .{};
        self.trace = .init(std.testing.allocator);
        self.recorder = .init(&self.trace.writer);
        _ = try self.target.attach(&self.surface, 9, .{ .ctx = &self.probe, .write_input = Probe.blocking, .write_input_nb = Probe.write, .resize_fn = Probe.resize, .enqueue_command_nb = Probe.control });
        try self.target.setSurfaceTraceRecorder(45, &self.recorder);
        self.dispatcher = .{ .allocator = a, .target = &self.target };
        try self.dispatcher.install();
    }
    fn deinit(self: *Fixture) void {
        self.dispatcher.deinit();
        self.target.deinit();
        self.surface.deinit();
        self.probe.output.deinit(std.testing.allocator);
        self.trace.deinit();
    }
};
test "ordered input dispatcher preserves command byte barriers and privacy" {
    var f: Fixture = undefined;
    try f.init(std.testing.allocator);
    defer f.deinit();
    try std.testing.expectError(error.AlreadyInstalled, f.dispatcher.install());
    try f.target.writeInput(45, .{ .bytes = "A" });
    try f.target.enqueueCoreCommand(45, .{ .report_focus = true }, std.testing.io);
    try std.testing.expectEqual(@as(usize, 6), try f.target.writeProtocolResponseNonBlocking(45, "secret"));
    _ = try f.target.writeInputNonBlocking(45, "B");
    try std.testing.expectEqual(@as(usize, 0), f.probe.output.items.len);
    f.dispatcher.flush();
    try std.testing.expectEqualStrings("A#", f.probe.output.items);
    f.dispatcher.flush();
    f.dispatcher.flush();
    try std.testing.expectEqualStrings("A#secretB", f.probe.output.items);
    try std.testing.expect(std.mem.indexOf(u8, f.trace.written(), "secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, f.trace.written(), "bytes=\"A\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, f.trace.written(), "bytes=\"B\"") != null);
    try std.testing.expect(!f.probe.blocking_called);
}
test "ordered input dispatcher partial stalled response blocks later control" {
    var f: Fixture = undefined;
    try f.init(std.testing.allocator);
    defer f.deinit();
    _ = try f.target.writeProtocolResponseNonBlocking(45, "abcd");
    try f.target.enqueueCoreCommand(45, .scroll_to_bottom, std.testing.io);
    f.probe.limit = 2;
    f.dispatcher.flush();
    try std.testing.expectEqualStrings("ab", f.probe.output.items);
    f.probe.limit = 0;
    f.dispatcher.flush();
    try std.testing.expectEqualStrings("ab", f.probe.output.items);
    f.probe.limit = 2;
    f.dispatcher.flush();
    try std.testing.expectEqualStrings("abcd#", f.probe.output.items);
}
test "ordered input dispatcher command backpressure retains later bytes" {
    var f: Fixture = undefined;
    try f.init(std.testing.allocator);
    defer f.deinit();
    f.probe.commands_ready = false;
    try f.target.enqueueCoreCommand(45, .scroll_to_bottom, std.testing.io);
    try f.target.writeInput(45, .{ .bytes = "after" });
    f.dispatcher.flush();
    try std.testing.expectEqual(@as(usize, 0), f.probe.output.items.len);
    f.probe.commands_ready = true;
    f.dispatcher.flush();
    try std.testing.expectEqualStrings("#after", f.probe.output.items);
}
test "ordered input dispatcher detach drops ownership and refuses stale target" {
    var f: Fixture = undefined;
    try f.init(std.testing.allocator);
    defer f.deinit();
    try f.target.writeInput(45, .{ .bytes = "old" });
    f.target.detachSurface(45);
    try std.testing.expectEqual(@as(usize, 0), f.dispatcher.pending.count());
    try std.testing.expectError(error.UnknownSurface, f.target.writeInput(45, .{ .bytes = "stale" }));
    f.dispatcher.flush();
    try std.testing.expectEqual(@as(usize, 0), f.probe.output.items.len);
}
fn allocationProbe(a: std.mem.Allocator) !void {
    var f: Fixture = undefined;
    try f.init(a);
    defer f.deinit();
    try f.target.writeInput(45, .{ .bytes = "A" });
    try f.target.enqueueCoreCommand(45, .scroll_to_bottom, std.testing.io);
    _ = try f.target.writeProtocolResponseNonBlocking(45, "secret");
    f.dispatcher.flush();
    f.dispatcher.flush();
    try std.testing.expectEqualStrings("A#secret", f.probe.output.items);
}
test "ordered input dispatcher allocation failure releases all owned records" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
}
