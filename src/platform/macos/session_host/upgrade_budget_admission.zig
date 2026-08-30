//! U5 pre-quiesce handoff-size, disk, and I/O budget admission.

const std = @import("std");
const handoff_store = @import("handoff_store.zig");
const upgrade_deadline = @import("upgrade_deadline.zig");
const upgrade_limits = @import("upgrade_limits.zig");
const test_scratch = @import("test_scratch.zig");

pub const safety_factor: u128 = 4;
const max_probe_bytes: usize = 1024 * 1024;

pub const Error = handoff_store.Error || error{InsufficientIoBudget};

pub const Preview = struct {
    bytes: usize,
    membership_generation: u64,
    runtime_ids: []const u128,
};

pub const Reservation = struct {
    store: handoff_store.Reservation,
    reserved_bytes: usize,
    membership_generation: u64,
    runtime_ids: [upgrade_limits.max_runtime_count]u128 = undefined,
    runtime_count: usize,

    pub fn deinit(self: *Reservation) void {
        self.store.deinit();
        self.* = undefined;
    }

    pub fn cancel(self: *Reservation) handoff_store.Error!void {
        try self.store.cancel();
        self.* = undefined;
    }

    pub fn matches(
        self: *const Reservation,
        membership_generation: u64,
        runtime_ids: []const u128,
        authoritative_bytes: usize,
    ) bool {
        return membership_generation == self.membership_generation and
            runtime_ids.len == self.runtime_count and
            authoritative_bytes <= self.reserved_bytes and
            std.mem.eql(u128, runtime_ids, self.runtime_ids[0..self.runtime_count]);
    }

    pub fn commit(
        self: *Reservation,
        allocator: std.mem.Allocator,
        expected: handoff_store.ExpectedAuthority,
        bytes: []const u8,
        deadline: upgrade_deadline.Deadline,
    ) handoff_store.Error!handoff_store.Pair {
        return handoff_store.commitReserved(
            allocator,
            &self.store,
            expected,
            bytes,
            .{ .deadline = deadline, .max_bytes = self.reserved_bytes },
        );
    }
};

pub fn prepare(
    allocator: std.mem.Allocator,
    owner_dir: [:0]const u8,
    attempt_id: u128,
    preview: Preview,
    deadline: upgrade_deadline.Deadline,
) Error!Reservation {
    if (preview.bytes == 0 or preview.bytes > upgrade_limits.max_handoff_commit_bytes or
        preview.membership_generation == 0 or
        preview.runtime_ids.len > upgrade_limits.max_runtime_count)
        return error.LimitExceeded;
    var reservation: Reservation = .{
        .store = try handoff_store.reserve(owner_dir, attempt_id, preview.bytes, deadline),
        .reserved_bytes = preview.bytes,
        .membership_generation = preview.membership_generation,
        .runtime_count = preview.runtime_ids.len,
    };
    @memcpy(reservation.runtime_ids[0..preview.runtime_ids.len], preview.runtime_ids);

    const sample_len = @min(preview.bytes, max_probe_bytes);
    const sample = allocator.alloc(u8, sample_len) catch {
        reservation.store.cancel() catch return error.CleanupFailed;
        return error.OutOfMemory;
    };
    defer allocator.free(sample);
    fillProbe(sample, attempt_id);
    const elapsed_ns = handoff_store.probeReservation(&reservation.store, sample, deadline) catch |err| {
        reservation.store.cancel() catch return error.CleanupFailed;
        return err;
    };
    if (!fitsPauseBudget(preview.bytes, sample_len, elapsed_ns, deadline.remainingNs())) {
        reservation.store.cancel() catch return error.CleanupFailed;
        return error.InsufficientIoBudget;
    }
    return reservation;
}

fn fitsPauseBudget(
    handoff_bytes: usize,
    probe_bytes: usize,
    probe_elapsed_ns: i128,
    remaining_ns: i128,
) bool {
    if (handoff_bytes == 0 or probe_bytes == 0 or probe_elapsed_ns <= 0 or remaining_ns <= 0)
        return false;
    // Product commit performs two writes and two read-backs. The probe performs one of each and
    // includes one fsync; the safety factor covers the second fsync and filesystem variance.
    const projected_work = std.math.mul(u128, @as(u128, handoff_bytes), 4) catch return false;
    const guarded_work = std.math.mul(u128, projected_work, safety_factor) catch return false;
    const lhs = std.math.mul(u128, guarded_work, @intCast(probe_elapsed_ns)) catch return false;
    const probe_work = std.math.mul(u128, @as(u128, probe_bytes), 2) catch return false;
    const rhs = std.math.mul(u128, probe_work, @intCast(remaining_ns)) catch return false;
    return lhs <= rhs;
}

fn fillProbe(bytes: []u8, attempt_id: u128) void {
    var state: u64 = @truncate(attempt_id ^ (attempt_id >> 64));
    if (state == 0) state = 0x9E3779B97F4A7C15;
    for (bytes) |*byte| {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        byte.* = @truncate(state);
    }
}

test "budget projection is fail-closed and includes two-copy I/O" {
    try std.testing.expect(fitsPauseBudget(1024, 1024, 1, 8));
    try std.testing.expect(!fitsPauseBudget(1024, 1024, 2, 7));
    try std.testing.expect(!fitsPauseBudget(0, 1024, 1, 8));
    try std.testing.expect(!fitsPauseBudget(1024, 0, 1, 8));
    try std.testing.expect(!fitsPauseBudget(1024, 1024, 0, 8));
    try std.testing.expect(!fitsPauseBudget(1024, 1024, 1, 0));
}

test "budget admission durable probe reserves and cleans before quiesce" {
    var dir_buf: [192]u8 = undefined;
    const dir = try test_scratch.open(std.testing.io, &dir_buf, "upgrade-budget-admission");
    defer test_scratch.close(std.testing.io, dir);
    const deadline = try upgrade_deadline.Deadline.after(std.testing.io, 5 * std.time.ns_per_s);
    var reservation = try prepare(
        std.testing.allocator,
        dir,
        0xB7,
        .{
            .bytes = 64 * 1024,
            .membership_generation = 4,
            .runtime_ids = &.{ 2, 9 },
        },
        deadline,
    );
    try std.testing.expect(reservation.matches(4, &.{ 2, 9 }, 64 * 1024));
    try reservation.cancel();
    var attempt_buf: [256]u8 = undefined;
    const attempt_path = try std.fmt.bufPrintZ(
        &attempt_buf,
        "{s}/attempt-{x:0>32}",
        .{ dir, @as(u128, 0xB7) },
    );
    try std.testing.expect(std.c.access(attempt_path.ptr, std.c.F_OK) != 0);
}

test "reservation membership and reserved length are exact" {
    var reservation: Reservation = undefined;
    reservation.reserved_bytes = 100;
    reservation.membership_generation = 7;
    reservation.runtime_count = 2;
    reservation.runtime_ids[0] = 3;
    reservation.runtime_ids[1] = 9;
    try std.testing.expect(reservation.matches(7, &.{ 3, 9 }, 100));
    try std.testing.expect(!reservation.matches(8, &.{ 3, 9 }, 100));
    try std.testing.expect(!reservation.matches(7, &.{ 3, 10 }, 100));
    try std.testing.expect(!reservation.matches(7, &.{ 3, 9 }, 101));
}
