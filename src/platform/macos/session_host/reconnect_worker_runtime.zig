//! CR6e-c3b app-global physical reconnect worker.
//!
//! The c1 owner remains main-thread-only. This runtime owns one stable physical worker lane and
//! one final-address c2 completion slot; it never receives a runtime/backend/adapter pointer.

const std = @import("std");
const issuer = @import("reconnect_worker_issuer.zig");
const worker_owner = @import("reconnect_worker_owner.zig");

pub const State = enum(u8) { pristine, idle, queued, running, completed, claimed, joined };

pub const Runtime = struct {
    self_addr: usize = 0,
    allocator: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    cache_base: [std.fs.max_path_bytes]u8 = undefined,
    cache_base_len: usize = 0,
    mutex: std.Io.Mutex = .init,
    wake: std.Io.Condition = .init,
    thread: ?std.Thread = null,
    state: State = .pristine,
    closing: bool = false,
    order: issuer.WorkOrder = zero_order,
    cancel: std.atomic.Value(u8) = .init(0),
    completion: issuer.Completion = .{},

    pub fn initInPlace(
        self: *Runtime,
        allocator: std.mem.Allocator,
        io: std.Io,
        cache_base: []const u8,
    ) !void {
        if (self.state != .pristine or self.self_addr != 0 or cache_base.len == 0 or
            cache_base.len > self.cache_base.len)
            return error.InvalidRuntime;
        self.self_addr = @intFromPtr(self);
        self.allocator = allocator;
        self.io = io;
        @memcpy(self.cache_base[0..cache_base.len], cache_base);
        self.cache_base_len = cache_base.len;
        self.state = .idle;
        errdefer self.* = .{};
        self.thread = try std.Thread.spawn(.{}, workerMain, .{self});
    }

    pub fn submit(self: *Runtime, order: issuer.WorkOrder) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.validateLocked();
        try issuer.validateWorkOrder(order);
        if (self.closing) return error.Closing;
        if (self.state != .idle or !std.meta.eql(self.completion, issuer.Completion{}))
            return error.Busy;
        self.order = order;
        self.cancel.store(0, .release);
        self.state = .queued;
        self.wake.signal(self.io);
    }

    /// Main-frame nonblocking claim. The returned pointer is the same inline address c2 filled.
    pub fn claimCompletion(self: *Runtime) !?*issuer.Completion {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.validateLocked();
        if (self.state != .completed) return null;
        self.state = .claimed;
        return &self.completion;
    }

    pub fn finishClaim(self: *Runtime) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.validateLocked();
        if (self.state != .claimed) return error.InvalidState;
        try self.completion.resetConsumedAtFinalAddress();
        self.order = zero_order;
        self.state = if (self.closing and self.thread == null) .joined else .idle;
        self.wake.signal(self.io);
    }

    /// Wakes an idle lane and makes an in-flight c2 issuer observe cancellation no later than its
    /// already-bound absolute deadline. This does not join or touch the completion payload.
    pub fn requestShutdown(self: *Runtime) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.validateLocked();
        if (self.state == .joined) return error.InvalidState;
        if (self.state == .claimed) return error.Busy;
        self.closing = true;
        self.cancel.store(1, .release);
        self.wake.signal(self.io);
    }

    /// Call only after requestShutdown. The worker has no backend/pool pointer, so joining here
    /// before those global owners are destroyed closes the only cross-thread lifetime edge.
    pub fn join(self: *Runtime) !void {
        self.mutex.lockUncancelable(self.io);
        try self.validateLocked();
        if (!self.closing or self.state == .claimed or self.state == .joined) {
            self.mutex.unlock(self.io);
            return error.InvalidState;
        }
        const thread = self.thread orelse {
            self.mutex.unlock(self.io);
            return error.InvalidState;
        };
        self.mutex.unlock(self.io);
        thread.join();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.thread = null;
        if (self.state == .idle) self.state = .joined else if (self.state != .completed)
            return error.InvalidState;
    }

    pub fn deinit(self: *Runtime) !void {
        self.mutex.lockUncancelable(self.io);
        self.validateLocked() catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        if (self.thread != null or self.state != .joined or
            !std.meta.eql(self.completion, issuer.Completion{}))
        {
            self.mutex.unlock(self.io);
            return error.Busy;
        }
        self.mutex.unlock(self.io);
        self.* = .{};
    }

    pub fn stateSnapshot(self: *Runtime) !State {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.validateLocked();
        return self.state;
    }

    fn validateLocked(self: *const Runtime) !void {
        if (self.self_addr != @intFromPtr(self) or self.cache_base_len == 0 or
            self.cache_base_len > self.cache_base.len or self.state == .pristine)
            return error.InvalidRuntime;
    }

    fn workerMain(self: *Runtime) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while ((self.state == .idle or self.state == .completed or self.state == .claimed) and
                !self.closing)
                self.wake.waitUncancelable(self.io, &self.mutex);
            if ((self.state == .idle or self.state == .completed) and self.closing) {
                self.mutex.unlock(self.io);
                return;
            }
            if (self.state != .queued) {
                self.mutex.unlock(self.io);
                @panic("invalid reconnect worker state");
            }
            const order = self.order;
            self.state = .running;
            self.mutex.unlock(self.io);

            issuer.executeInto(
                self.allocator,
                self.io,
                self.cache_base[0..self.cache_base_len],
                order,
                &self.cancel,
                &self.completion,
            ) catch @panic("invalid reconnect worker order");

            self.mutex.lockUncancelable(self.io);
            self.state = .completed;
            const should_exit = self.closing;
            self.mutex.unlock(self.io);
            if (should_exit) return;
        }
    }
};

const zero_order: issuer.WorkOrder = .{
    .key = .{ .slot = 0, .generation = 0 },
    .snapshot = .{
        .host_id = 0,
        .pool_membership_generation = 0,
        .connection_generation = 0,
        .incident_app_instance_nonce = 0,
        .incident_sequence = 0,
        .absolute_deadline_ns = 0,
    },
};

fn expiredOrder(io: std.Io) issuer.WorkOrder {
    const now = std.Io.Clock.awake.now(io).nanoseconds;
    return .{
        .key = .{ .slot = 1, .generation = 2 },
        .snapshot = .{
            .host_id = 3,
            .pool_membership_generation = 4,
            .connection_generation = 5,
            .incident_app_instance_nonce = (@as(u128, 1) << 96) | 6,
            .incident_sequence = 7,
            .absolute_deadline_ns = @intCast(@max(1, now - 1)),
        },
    };
}

test "CR6e-c3b worker writes and main consumes the same final-address completion" {
    var runtime: Runtime = .{};
    try runtime.initInPlace(std.testing.allocator, std.testing.io, "/tmp");
    try runtime.submit(expiredOrder(std.testing.io));
    var completion: ?*issuer.Completion = null;
    for (0..10_000) |_| {
        completion = try runtime.claimCompletion();
        if (completion != null) break;
        std.Thread.yield() catch {};
    }
    const claimed = completion orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@intFromPtr(&runtime.completion), @intFromPtr(claimed));
    try std.testing.expectEqual(worker_owner.Outcome.deadline_exceeded, try claimed.outcome());
    try claimed.consumeFailure();
    try runtime.finishClaim();
    try runtime.requestShutdown();
    try runtime.join();
    try runtime.deinit();
}

test "CR6e-c3b idle shutdown wakes and joins without a completion" {
    var runtime: Runtime = .{};
    try runtime.initInPlace(std.testing.allocator, std.testing.io, "/tmp");
    try runtime.requestShutdown();
    try runtime.join();
    try std.testing.expectEqual(State.joined, try runtime.stateSnapshot());
    try std.testing.expect((try runtime.claimCompletion()) == null);
    try runtime.deinit();
}

test "CR6e-c3b worker rejects a second order while its completion is retained" {
    var runtime: Runtime = .{};
    try runtime.initInPlace(std.testing.allocator, std.testing.io, "/tmp");
    const order = expiredOrder(std.testing.io);
    var invalid = order;
    invalid.key.generation = 0;
    try std.testing.expectError(error.InvalidWorkOrder, runtime.submit(invalid));
    try std.testing.expectEqual(State.idle, try runtime.stateSnapshot());
    try runtime.submit(order);
    var completion: ?*issuer.Completion = null;
    for (0..10_000) |_| {
        completion = try runtime.claimCompletion();
        if (completion != null) break;
        std.Thread.yield() catch {};
    }
    const claimed = completion orelse return error.TestUnexpectedResult;
    try std.testing.expectError(error.Busy, runtime.submit(order));
    try claimed.consumeFailure();
    try runtime.finishClaim();
    try runtime.requestShutdown();
    try runtime.join();
    try runtime.deinit();
}

test "CR6e-c3b shutdown joins before consuming a retained completion" {
    var runtime: Runtime = .{};
    try runtime.initInPlace(std.testing.allocator, std.testing.io, "/tmp");
    try runtime.submit(expiredOrder(std.testing.io));
    while (try runtime.stateSnapshot() != .completed) std.Thread.yield() catch {};
    try runtime.requestShutdown();
    try runtime.join();
    try std.testing.expectEqual(State.completed, try runtime.stateSnapshot());
    const claimed = (try runtime.claimCompletion()) orelse return error.TestUnexpectedResult;
    try std.testing.expectError(error.Busy, runtime.requestShutdown());
    try claimed.consumeFailure();
    try runtime.finishClaim();
    try std.testing.expectEqual(State.joined, try runtime.stateSnapshot());
    try runtime.deinit();
}
