//! One-way blocking-to-external fd mode transaction.
//!
//! This leaf owns only the external-mode storage inventory and exact fd-flag rollback policy.
//! `Client` remains the fd/parser owner and decides when an indeterminate transition poisons and
//! closes the connection.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const client_deadline = @import("client_deadline.zig");
const protocol = @import("protocol.zig");

pub const max_tx_frames: usize = 64;

pub const ExternalTxFrame = struct {
    bytes: []u8,
    offset: usize = 0,
    kind: protocol.Kind,
    stream_id: u64,
    request_id: u64,
    activated_at_ns: i128,
    last_progress_at_ns: i128,
};

pub const InFlightControl = struct {
    request_id: u64,
    deadline: client_deadline.AbsoluteDeadline,
};

pub const State = struct {
    saved_flags: c_int,
    external_tx: std.ArrayListUnmanaged(ExternalTxFrame) = .empty,
    external_tx_bytes: usize = 0,
    in_flight_control: ?InFlightControl = null,

    fn stage(allocator: std.mem.Allocator) error{OutOfMemory}!State {
        var result = State{ .saved_flags = 0 };
        result.external_tx.ensureTotalCapacityPrecise(allocator, max_tx_frames) catch
            return error.OutOfMemory;
        return result;
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        for (self.external_tx.items) |frame| allocator.free(frame.bytes);
        self.external_tx.deinit(allocator);
        self.* = undefined;
    }
};

pub const Mode = union(enum) {
    blocking,
    external: State,
};

pub const FlagOps = struct {
    context: *anyopaque,
    get_flags: *const fn (context: *anyopaque, fd: c.fd_t) ?c_int,
    set_flags: *const fn (context: *anyopaque, fd: c.fd_t, flags: c_int) bool,
};

pub const Outcome = union(enum) {
    external: State,
    flag_failed,
    invalid_blocking_flags,
    indeterminate,
};

/// Stage every 2a-owned allocation before observing or mutating fd flags. A successful target
/// verification returns owned state; every other outcome has already reclaimed staged storage.
pub fn transition(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    ops: FlagOps,
) error{OutOfMemory}!Outcome {
    var staged = try State.stage(allocator);
    errdefer staged.deinit(allocator);

    const saved_flags = ops.get_flags(ops.context, fd) orelse {
        staged.deinit(allocator);
        return .flag_failed;
    };
    const nonblocking: c_int = @bitCast(posix.O{ .NONBLOCK = true });
    if (saved_flags & nonblocking != 0) {
        staged.deinit(allocator);
        return .invalid_blocking_flags;
    }
    staged.saved_flags = saved_flags;
    const target_flags = saved_flags | nonblocking;
    const set_ok = ops.set_flags(ops.context, fd, target_flags);
    const observed = ops.get_flags(ops.context, fd);
    if (set_ok and observed != null and observed.? == target_flags)
        return .{ .external = staged };

    // A failing adapter may still have changed the open-file-description. Only an exact observed
    // original value, or an explicitly successful and verified rollback, is reusable.
    if (!set_ok and observed != null and observed.? == saved_flags) {
        staged.deinit(allocator);
        return .flag_failed;
    }
    if (!ops.set_flags(ops.context, fd, saved_flags)) {
        staged.deinit(allocator);
        return .indeterminate;
    }
    const restored = ops.get_flags(ops.context, fd);
    staged.deinit(allocator);
    return if (restored != null and restored.? == saved_flags)
        .flag_failed
    else
        .indeterminate;
}

const FakeFlags = struct {
    flags: c_int = 0x20,
    get_results: []const ?c_int = &.{},
    get_index: usize = 0,
    set_results: []const bool = &.{true},
    set_index: usize = 0,
    mutate_on_set: bool = true,

    fn ops(self: *FakeFlags) FlagOps {
        return .{
            .context = self,
            .get_flags = getFlags,
            .set_flags = setFlags,
        };
    }

    fn cast(context: *anyopaque) *FakeFlags {
        return @ptrCast(@alignCast(context));
    }

    fn getFlags(context: *anyopaque, _: c.fd_t) ?c_int {
        const self = cast(context);
        if (self.get_index < self.get_results.len) {
            const result = self.get_results[self.get_index];
            self.get_index += 1;
            return result;
        }
        self.get_index += 1;
        return self.flags;
    }

    fn setFlags(context: *anyopaque, _: c.fd_t, flags: c_int) bool {
        const self = cast(context);
        const result = if (self.set_index < self.set_results.len)
            self.set_results[self.set_index]
        else
            true;
        self.set_index += 1;
        if (self.mutate_on_set) self.flags = flags;
        return result;
    }
};

test "external mode transition preserves unrelated flags and stages exact descriptor capacity" {
    var fake = FakeFlags{ .flags = 0x20 };
    const outcome = try transition(std.testing.allocator, 7, fake.ops());
    var state = outcome.external;
    defer state.deinit(std.testing.allocator);
    const nonblocking: c_int = @bitCast(posix.O{ .NONBLOCK = true });
    try std.testing.expectEqual(@as(c_int, 0x20), state.saved_flags);
    try std.testing.expectEqual(@as(c_int, 0x20) | nonblocking, fake.flags);
    try std.testing.expectEqual(max_tx_frames, state.external_tx.capacity);
    try std.testing.expectEqual(@as(usize, 0), state.external_tx.items.len);
    try std.testing.expectEqual(@as(usize, 1), fake.set_index);
    try std.testing.expectEqual(@as(usize, 2), fake.get_index);
}

test "external mode transition classifies initial and unexpected blocking flag failures" {
    var get_failed = FakeFlags{ .get_results = &.{null} };
    try std.testing.expect(
        (try transition(std.testing.allocator, 7, get_failed.ops())) == .flag_failed,
    );
    try std.testing.expectEqual(@as(usize, 0), get_failed.set_index);

    const nonblocking: c_int = @bitCast(posix.O{ .NONBLOCK = true });
    var already_nonblocking = FakeFlags{ .flags = 0x20 | nonblocking };
    try std.testing.expect(
        (try transition(std.testing.allocator, 7, already_nonblocking.ops())) ==
            .invalid_blocking_flags,
    );
    try std.testing.expectEqual(@as(usize, 0), already_nonblocking.set_index);
}

test "external mode transition verifies mutate-then-fail rollback and poisons ambiguity" {
    const nonblocking: c_int = @bitCast(posix.O{ .NONBLOCK = true });
    const original: c_int = 0x20;
    const target = original | nonblocking;

    var restored = FakeFlags{
        .flags = original,
        .get_results = &.{ original, target, original },
        .set_results = &.{ false, true },
    };
    try std.testing.expect(
        (try transition(std.testing.allocator, 7, restored.ops())) == .flag_failed,
    );
    try std.testing.expectEqual(original, restored.flags);

    var successful_set_not_observed = FakeFlags{
        .flags = original,
        .get_results = &.{ original, original, original },
        .set_results = &.{ true, true },
    };
    try std.testing.expect(
        (try transition(
            std.testing.allocator,
            7,
            successful_set_not_observed.ops(),
        )) == .flag_failed,
    );
    try std.testing.expectEqual(@as(usize, 2), successful_set_not_observed.set_index);

    var rollback_failed = FakeFlags{
        .flags = original,
        .get_results = &.{ original, target },
        .set_results = &.{ false, false },
    };
    try std.testing.expect(
        (try transition(std.testing.allocator, 7, rollback_failed.ops())) == .indeterminate,
    );

    var verify_failed = FakeFlags{
        .flags = original,
        .get_results = &.{ original, null, null },
        .set_results = &.{ true, true },
    };
    try std.testing.expect(
        (try transition(std.testing.allocator, 7, verify_failed.ops())) == .indeterminate,
    );
}

fn checkTransitionAllocation(allocator: std.mem.Allocator) !void {
    var fake = FakeFlags{};
    const outcome = transition(allocator, 7, fake.ops()) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), fake.get_index);
        try std.testing.expectEqual(@as(usize, 0), fake.set_index);
        return err;
    };
    var state = outcome.external;
    state.deinit(allocator);
}

test "external mode transition is leak free at every allocation fail index" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkTransitionAllocation,
        .{},
    );
}
