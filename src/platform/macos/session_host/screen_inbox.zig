//! Allocation-free stream-local recovery state for the blocking GUI screen inbox.

const std = @import("std");
const client_queue_limits = @import("client_queue_limits.zig");
const protocol = @import("protocol.zig");

pub const State = enum(u8) { valid, needs_resync, awaiting_snapshot };
pub const FrameDecision = enum { accept, discard };
pub const Error = error{ InvalidStream, CapacityExhausted, InvalidTransition };

const Entry = struct {
    stream_id: u64 = 0,
    state: State = .valid,
};

pub const RecoveryTable = struct {
    entries: [client_queue_limits.max_recovery_streams]Entry =
        [_]Entry{.{}} ** client_queue_limits.max_recovery_streams,
    count: u16 = 0,

    pub fn valid(self: *const RecoveryTable) bool {
        if (self.count > self.entries.len) return false;
        for (self.entries[0..self.count], 0..) |entry, index| {
            if (entry.stream_id == 0 or entry.state == .valid) return false;
            for (self.entries[0..index]) |prior|
                if (prior.stream_id == entry.stream_id) return false;
        }
        for (self.entries[self.count..]) |entry|
            if (entry.stream_id != 0 or entry.state != .valid) return false;
        return true;
    }

    fn find(self: *const RecoveryTable, stream_id: u64) ?usize {
        for (self.entries[0..self.count], 0..) |entry, index|
            if (entry.stream_id == stream_id) return index;
        return null;
    }

    pub fn state(self: *const RecoveryTable, stream_id: u64) State {
        const index = self.find(stream_id) orelse return .valid;
        return self.entries[index].state;
    }

    /// Coalesces repeated pressure without allocation. `true` means a new intent was published.
    pub fn invalidate(self: *RecoveryTable, stream_id: u64) Error!bool {
        if (stream_id == 0) return error.InvalidStream;
        if (self.find(stream_id)) |index| {
            return switch (self.entries[index].state) {
                .valid => unreachable,
                .needs_resync => false,
                // The admitted request's snapshot itself could not enter the unified inbox.
                // That response is gone, so a later outer pump must admit one new request.
                .awaiting_snapshot => blk: {
                    self.entries[index].state = .needs_resync;
                    break :blk true;
                },
            };
        }
        if (self.count == self.entries.len) return error.CapacityExhausted;
        self.entries[self.count] = .{ .stream_id = stream_id, .state = .needs_resync };
        self.count += 1;
        return true;
    }

    pub fn requestAdmitted(self: *RecoveryTable, stream_id: u64) Error!void {
        const index = self.find(stream_id) orelse return error.InvalidTransition;
        if (self.entries[index].state != .needs_resync) return error.InvalidTransition;
        self.entries[index].state = .awaiting_snapshot;
    }

    /// Deltas are never accepted while recovery is sticky. Snapshot chunks may be assembled while
    /// awaiting recovery, but authority becomes valid only after the complete batch is admitted.
    pub fn classify(self: *RecoveryTable, stream_id: u64, kind: protocol.Kind) FrameDecision {
        const index = self.find(stream_id) orelse return .accept;
        switch (self.entries[index].state) {
            .valid => return .accept,
            .needs_resync => return .discard,
            .awaiting_snapshot => return if (kind == .snapshot_chunk) .accept else .discard,
        }
    }

    pub fn snapshotAccepted(self: *RecoveryTable, stream_id: u64) Error!void {
        const index = self.find(stream_id) orelse return error.InvalidTransition;
        if (self.entries[index].state != .awaiting_snapshot) return error.InvalidTransition;
        self.removeAt(index);
    }

    pub fn remove(self: *RecoveryTable, stream_id: u64) void {
        self.removeAt(self.find(stream_id) orelse return);
    }

    fn removeAt(self: *RecoveryTable, index: usize) void {
        const last = self.count - 1;
        self.entries[index] = self.entries[last];
        self.entries[last] = .{};
        self.count = last;
    }
};

test "R3 recovery table coalesces without allocation and isolates streams" {
    var table: RecoveryTable = .{};
    try std.testing.expect(try table.invalidate(9));
    try std.testing.expect(!(try table.invalidate(9)));
    try std.testing.expectEqual(State.needs_resync, table.state(9));
    try std.testing.expectEqual(State.valid, table.state(10));
    try std.testing.expectEqual(FrameDecision.discard, table.classify(9, .delta_chunk));
    try table.requestAdmitted(9);
    try std.testing.expectEqual(FrameDecision.discard, table.classify(9, .delta_chunk));
    try std.testing.expectEqual(FrameDecision.accept, table.classify(9, .snapshot_chunk));
    try std.testing.expectEqual(State.awaiting_snapshot, table.state(9));
    try table.snapshotAccepted(9);
    try std.testing.expectEqual(State.valid, table.state(9));
}

test "R4 a snapshot rejected after resync admission schedules exactly one replacement" {
    var table: RecoveryTable = .{};
    try std.testing.expect(try table.invalidate(9));
    try table.requestAdmitted(9);
    try std.testing.expect(try table.invalidate(9));
    try std.testing.expectEqual(State.needs_resync, table.state(9));
    try std.testing.expect(!(try table.invalidate(9)));
}

test "R3 recovery table has the exact per-connection stream ceiling" {
    var table: RecoveryTable = .{};
    for (1..client_queue_limits.max_recovery_streams + 1) |stream_id|
        try std.testing.expect(try table.invalidate(stream_id));
    try std.testing.expectError(error.CapacityExhausted, table.invalidate(10_000));
    table.remove(7);
    try std.testing.expect(try table.invalidate(10_000));
    try std.testing.expect(table.valid());
}
