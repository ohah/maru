//! CR6e-c1 bounded app-global reconnect worker job/completion owner.
//!
//! This leaf owns no socket, Client, HostAdapter, runtime pointer, or thread. It is the fixed-cap
//! authority handoff that c2 will use before a worker may execute exact-host connect/hello.

const std = @import("std");
const process_identity = @import("process_identity.zig");

pub const max_jobs: usize = 32;

pub const Snapshot = struct {
    host_id: u128,
    pool_membership_generation: u64,
    connection_generation: u64,
    incident_app_instance_nonce: u64,
    incident_sequence: u64,
    absolute_deadline_ns: u64,
};

pub const AdmitResult = union(enum) {
    admitted: Key,
    coalesced: Key,
};

pub const Outcome = enum(u8) {
    connected,
    host_gone,
    deadline_exceeded,
    cancelled,
};

pub const Key = struct {
    slot: u8,
    generation: u64,
};

pub const JobReceipt = struct {
    self_addr: usize = 0,
    owner_addr: usize = 0,
    pid: u32 = 0,
    process_nonce: u64 = 0,
    owner_thread: ?std.Thread.Id = null,
    key: Key = .{ .slot = 0, .generation = 0 },
    snapshot: Snapshot = zero_snapshot,
    lifecycle: Lifecycle = .pristine,
};

pub const CompletionReceipt = struct {
    self_addr: usize = 0,
    owner_addr: usize = 0,
    pid: u32 = 0,
    process_nonce: u64 = 0,
    owner_thread: ?std.Thread.Id = null,
    key: Key = .{ .slot = 0, .generation = 0 },
    snapshot: Snapshot = zero_snapshot,
    outcome: Outcome = .cancelled,
    coalesced_incidents: u32 = 0,
    lifecycle: Lifecycle = .pristine,
};

const Lifecycle = enum(u8) { pristine, prepared, consumed };
const SlotState = enum(u8) { free, queued, running, completed, completion_claimed };
const zero_snapshot: Snapshot = .{
    .host_id = 0,
    .pool_membership_generation = 0,
    .connection_generation = 0,
    .incident_app_instance_nonce = 0,
    .incident_sequence = 0,
    .absolute_deadline_ns = 0,
};

const Slot = struct {
    generation: u64 = 0,
    state: SlotState = .free,
    snapshot: Snapshot = zero_snapshot,
    outcome: Outcome = .cancelled,
    coalesced_incidents: u32 = 0,
    cancel_requested: bool = false,
};

pub const Owner = struct {
    self_addr: usize = 0,
    pid: u32 = 0,
    process_nonce: u64 = 0,
    owner_thread: ?std.Thread.Id = null,
    slots: [max_jobs]Slot = [_]Slot{.{}} ** max_jobs,
    ready: bool = false,

    pub fn initInPlace(self: *Owner, process_nonce: u64) !void {
        if (!std.meta.eql(self.*, Owner{}) or process_nonce == 0) return error.InvalidAuthority;
        const pid = process_identity.currentProcessId();
        const thread = std.Thread.getCurrentId();
        if (pid == 0) return error.InvalidAuthority;
        self.* = .{
            .self_addr = @intFromPtr(self),
            .pid = pid,
            .process_nonce = process_nonce,
            .owner_thread = thread,
            .ready = true,
        };
    }

    pub fn admit(self: *Owner, snapshot: Snapshot) !AdmitResult {
        try self.validate();
        if (!validSnapshot(snapshot)) return error.InvalidSnapshot;
        for (&self.slots, 0..) |*slot, index| {
            if (slot.state == .free or slot.snapshot.host_id != snapshot.host_id) continue;
            if (slot.state == .completed or slot.state == .completion_claimed) return error.HostBusy;
            if (slot.snapshot.pool_membership_generation != snapshot.pool_membership_generation or
                slot.snapshot.connection_generation != snapshot.connection_generation)
                return error.HostBusy;
            if (slot.snapshot.incident_app_instance_nonce != snapshot.incident_app_instance_nonce)
                return error.HostBusy;
            // A worker receipt is an immutable snapshot. A later incident may share that host job,
            // but it cannot rewrite the deadline/identity already handed to c2.
            if (slot.state == .running and snapshot.absolute_deadline_ns < slot.snapshot.absolute_deadline_ns)
                return error.HostBusy;
            slot.coalesced_incidents = std.math.add(u32, slot.coalesced_incidents, 1) catch
                return error.IncidentOverflow;
            if (slot.state == .queued) {
                if (snapshot.incident_sequence > slot.snapshot.incident_sequence)
                    slot.snapshot.incident_sequence = snapshot.incident_sequence;
                if (snapshot.absolute_deadline_ns < slot.snapshot.absolute_deadline_ns)
                    slot.snapshot.absolute_deadline_ns = snapshot.absolute_deadline_ns;
            }
            return .{ .coalesced = .{ .slot = @intCast(index), .generation = slot.generation } };
        }
        for (&self.slots, 0..) |*slot, index| if (slot.state == .free) {
            const generation = std.math.add(u64, slot.generation, 1) catch return error.GenerationOverflow;
            slot.* = .{
                .generation = generation,
                .state = .queued,
                .snapshot = snapshot,
                .coalesced_incidents = 1,
            };
            return .{ .admitted = .{ .slot = @intCast(index), .generation = generation } };
        };
        return error.CapacityExceeded;
    }

    pub fn claim(self: *Owner, out: *JobReceipt) !void {
        try self.validate();
        if (!std.meta.eql(out.*, JobReceipt{})) return error.InvalidReceipt;
        for (&self.slots, 0..) |*slot, index| if (slot.state == .queued) {
            slot.state = .running;
            out.* = .{
                .self_addr = @intFromPtr(out),
                .owner_addr = @intFromPtr(self),
                .pid = self.pid,
                .process_nonce = self.process_nonce,
                .owner_thread = self.owner_thread,
                .key = .{ .slot = @intCast(index), .generation = slot.generation },
                .snapshot = slot.snapshot,
                .lifecycle = .prepared,
            };
            return;
        };
        return error.NotFound;
    }

    pub fn settle(self: *Owner, receipt: *JobReceipt, outcome: Outcome) !void {
        try self.validateJobReceipt(receipt);
        const slot = &self.slots[receipt.key.slot];
        if (slot.state != .running or slot.generation != receipt.key.generation or
            !std.meta.eql(slot.snapshot, receipt.snapshot))
            return error.StaleReceipt;
        slot.outcome = if (slot.cancel_requested) .cancelled else outcome;
        slot.state = .completed;
        receipt.lifecycle = .consumed;
    }

    pub fn requestCancelAll(self: *Owner) !void {
        try self.validate();
        for (&self.slots) |*slot| switch (slot.state) {
            .queued => {
                slot.outcome = .cancelled;
                slot.state = .completed;
            },
            .running => slot.cancel_requested = true,
            .free, .completed, .completion_claimed => {},
        };
    }

    pub fn takeCompletion(self: *Owner, out: *CompletionReceipt) !void {
        try self.validate();
        if (!std.meta.eql(out.*, CompletionReceipt{})) return error.InvalidReceipt;
        for (&self.slots, 0..) |*slot, index| if (slot.state == .completed) {
            out.* = .{
                .self_addr = @intFromPtr(out),
                .owner_addr = @intFromPtr(self),
                .pid = self.pid,
                .process_nonce = self.process_nonce,
                .owner_thread = self.owner_thread,
                .key = .{ .slot = @intCast(index), .generation = slot.generation },
                .snapshot = slot.snapshot,
                .outcome = slot.outcome,
                .coalesced_incidents = slot.coalesced_incidents,
                .lifecycle = .prepared,
            };
            slot.state = .completion_claimed;
            return;
        };
        return error.NotFound;
    }

    pub fn consumeCompletion(self: *Owner, receipt: *CompletionReceipt) !void {
        try self.validateCompletionReceipt(receipt);
        const slot = &self.slots[receipt.key.slot];
        if (slot.state != .completion_claimed or slot.generation != receipt.key.generation or
            !std.meta.eql(slot.snapshot, receipt.snapshot) or slot.outcome != receipt.outcome or
            slot.coalesced_incidents != receipt.coalesced_incidents)
            return error.StaleReceipt;
        const generation = slot.generation;
        slot.* = .{ .generation = generation };
        receipt.lifecycle = .consumed;
    }

    pub fn activeCount(self: *const Owner) !usize {
        try self.validate();
        var count: usize = 0;
        for (self.slots) |slot| if (slot.state != .free) {
            count += 1;
        };
        return count;
    }

    pub fn deinit(self: *Owner) !void {
        try self.validate();
        if (try self.activeCount() != 0) return error.Busy;
        self.* = .{};
    }

    fn validate(self: *const Owner) !void {
        if (!self.ready or self.self_addr != @intFromPtr(self) or self.pid == 0 or
            self.pid != process_identity.currentProcessId() or self.process_nonce == 0 or
            self.owner_thread == null or self.owner_thread.? != std.Thread.getCurrentId())
            return error.InvalidAuthority;
    }

    fn validateJobReceipt(self: *const Owner, receipt: *const JobReceipt) !void {
        try self.validate();
        if (receipt.lifecycle != .prepared or receipt.self_addr != @intFromPtr(receipt) or
            receipt.owner_addr != @intFromPtr(self) or receipt.pid != self.pid or
            receipt.process_nonce != self.process_nonce or receipt.owner_thread != self.owner_thread or
            receipt.key.slot >= max_jobs or receipt.key.generation == 0 or !validSnapshot(receipt.snapshot))
            return error.InvalidReceipt;
    }

    fn validateCompletionReceipt(self: *const Owner, receipt: *const CompletionReceipt) !void {
        try self.validate();
        if (receipt.lifecycle != .prepared or receipt.self_addr != @intFromPtr(receipt) or
            receipt.owner_addr != @intFromPtr(self) or receipt.pid != self.pid or
            receipt.process_nonce != self.process_nonce or receipt.owner_thread != self.owner_thread or
            receipt.key.slot >= max_jobs or receipt.key.generation == 0 or !validSnapshot(receipt.snapshot) or
            receipt.coalesced_incidents == 0)
            return error.InvalidReceipt;
    }
};

fn validSnapshot(value: Snapshot) bool {
    return value.host_id != 0 and value.pool_membership_generation != 0 and
        value.connection_generation != 0 and value.incident_app_instance_nonce != 0 and
        value.incident_sequence != 0 and value.absolute_deadline_ns != 0;
}

fn fixture(host_id: u128, sequence: u64) Snapshot {
    return .{
        .host_id = host_id,
        .pool_membership_generation = 3,
        .connection_generation = 7,
        .incident_app_instance_nonce = 11,
        .incident_sequence = sequence,
        .absolute_deadline_ns = 1000,
    };
}

test "CR6e-c1 reconnect worker owner admits claims settles and consumes exact once" {
    var owner: Owner = .{};
    try owner.initInPlace(9);
    _ = try owner.admit(fixture(1, 1));
    var job: JobReceipt = .{};
    try owner.claim(&job);
    try owner.settle(&job, .connected);
    try std.testing.expectError(error.InvalidReceipt, owner.settle(&job, .connected));
    var completion: CompletionReceipt = .{};
    try owner.takeCompletion(&completion);
    try std.testing.expectEqual(Outcome.connected, completion.outcome);
    try owner.consumeCompletion(&completion);
    try std.testing.expectError(error.InvalidReceipt, owner.consumeCompletion(&completion));
    try std.testing.expectEqual(@as(usize, 0), try owner.activeCount());
}

test "CR6e-c1 reconnect worker owner coalesces same host and preserves earliest deadline" {
    var owner: Owner = .{};
    try owner.initInPlace(9);
    _ = try owner.admit(fixture(1, 1));
    var second = fixture(1, 2);
    second.absolute_deadline_ns = 900;
    try std.testing.expect((try owner.admit(second)) == .coalesced);
    var job: JobReceipt = .{};
    try owner.claim(&job);
    try std.testing.expectEqual(@as(u64, 2), job.snapshot.incident_sequence);
    try std.testing.expectEqual(@as(u64, 900), job.snapshot.absolute_deadline_ns);
    try owner.settle(&job, .host_gone);
    var completion: CompletionReceipt = .{};
    try owner.takeCompletion(&completion);
    try std.testing.expectEqual(@as(u32, 2), completion.coalesced_incidents);
}

test "CR6e-c1 reconnect worker owner rejects stale same-host generation without mutation" {
    var owner: Owner = .{};
    try owner.initInPlace(9);
    _ = try owner.admit(fixture(1, 1));
    var stale = fixture(1, 2);
    stale.connection_generation = 8;
    try std.testing.expectError(error.HostBusy, owner.admit(stale));
    try std.testing.expectEqual(@as(usize, 1), try owner.activeCount());
}

test "CR6e-c1 running worker receipt stays immutable while later incidents coalesce" {
    var owner: Owner = .{};
    try owner.initInPlace(9);
    _ = try owner.admit(fixture(1, 1));
    var job: JobReceipt = .{};
    try owner.claim(&job);
    var later = fixture(1, 2);
    later.absolute_deadline_ns = 1100;
    try std.testing.expect((try owner.admit(later)) == .coalesced);
    try std.testing.expectEqual(@as(u64, 1), job.snapshot.incident_sequence);
    var impossible_earlier = fixture(1, 3);
    impossible_earlier.absolute_deadline_ns = 900;
    try std.testing.expectError(error.HostBusy, owner.admit(impossible_earlier));
    try owner.settle(&job, .connected);
}

test "CR6e-c1 reconnect worker owner rejects copied receipts and slot ABA" {
    var owner: Owner = .{};
    try owner.initInPlace(9);
    _ = try owner.admit(fixture(1, 1));
    var job: JobReceipt = .{};
    try owner.claim(&job);
    var copied_job = job;
    try std.testing.expectError(error.InvalidReceipt, owner.settle(&copied_job, .connected));
    const canonical_snapshot = job.snapshot;
    job.snapshot.incident_sequence += 1;
    try std.testing.expectError(error.StaleReceipt, owner.settle(&job, .connected));
    job.snapshot = canonical_snapshot;
    try owner.settle(&job, .connected);
    var completion: CompletionReceipt = .{};
    try owner.takeCompletion(&completion);
    var duplicate_take: CompletionReceipt = .{};
    try std.testing.expectError(error.NotFound, owner.takeCompletion(&duplicate_take));
    var copied_completion = completion;
    try std.testing.expectError(error.InvalidReceipt, owner.consumeCompletion(&copied_completion));
    const old_key = completion.key;
    try owner.consumeCompletion(&completion);
    const admitted = try owner.admit(fixture(2, 2));
    try std.testing.expect(admitted.admitted.slot == old_key.slot);
    try std.testing.expect(admitted.admitted.generation != old_key.generation);
}

test "CR6e-c1 completed host rejects coalesce until exact completion consumption" {
    var owner: Owner = .{};
    try owner.initInPlace(9);
    _ = try owner.admit(fixture(1, 1));
    var job: JobReceipt = .{};
    try owner.claim(&job);
    try owner.settle(&job, .connected);
    try std.testing.expectError(error.HostBusy, owner.admit(fixture(1, 2)));
    var completion: CompletionReceipt = .{};
    try owner.takeCompletion(&completion);
    try std.testing.expectError(error.HostBusy, owner.admit(fixture(1, 3)));
    try owner.consumeCompletion(&completion);
    try std.testing.expect((try owner.admit(fixture(1, 4))) == .admitted);
}

test "CR6e-c1 reconnect worker owner cancellation is terminal for queued and running jobs" {
    var owner: Owner = .{};
    try owner.initInPlace(9);
    _ = try owner.admit(fixture(1, 1));
    _ = try owner.admit(fixture(2, 2));
    var running: JobReceipt = .{};
    try owner.claim(&running);
    try owner.requestCancelAll();
    try owner.settle(&running, .connected);
    var first: CompletionReceipt = .{};
    try owner.takeCompletion(&first);
    try std.testing.expectEqual(Outcome.cancelled, first.outcome);
    try owner.consumeCompletion(&first);
    var second: CompletionReceipt = .{};
    try owner.takeCompletion(&second);
    try std.testing.expectEqual(Outcome.cancelled, second.outcome);
}

test "CR6e-c1 reconnect worker owner enforces exact capacity" {
    var owner: Owner = .{};
    try owner.initInPlace(9);
    for (0..max_jobs) |index| _ = try owner.admit(fixture(index + 1, index + 1));
    try std.testing.expectError(error.CapacityExceeded, owner.admit(fixture(max_jobs + 1, max_jobs + 1)));
    try std.testing.expectEqual(max_jobs, try owner.activeCount());
}

test "CR6e-c1 reconnect worker owner deinit requires final zero" {
    var owner: Owner = .{};
    try owner.initInPlace(9);
    _ = try owner.admit(fixture(1, 1));
    try std.testing.expectError(error.Busy, owner.deinit());
    try owner.requestCancelAll();
    var completion: CompletionReceipt = .{};
    try owner.takeCompletion(&completion);
    try owner.consumeCompletion(&completion);
    try owner.deinit();
    try std.testing.expectEqualDeep(Owner{}, owner);
}
