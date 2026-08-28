//! P4 E3c opt-in process-local evidence for the generation-backed GUI client pump.
//!
//! The product path records nothing until a ReleaseFast evidence owner is installed. The owner is
//! final-address and thread-bound so a forked host, copied fixture, or another UI thread cannot
//! mutate the counters. No runtime identity, path, argv, or wire payload is retained.

const std = @import("std");

pub const Counters = struct {
    selected_owners: u64 = 0,
    pump_delta_entries: u64 = 0,
    timestamp_seals: u64 = 0,
    client_slot_registry_visits: u64 = 0,
    socket_read_attempts: u64 = 0,
    metadata_events: u64 = 0,
    screen_events: u64 = 0,
    ended_events: u64 = 0,
};

pub const Owner = struct {
    self_addr: usize = 0,
    thread_id: std.Thread.Id = 0,
    counters: Counters = .{},

    pub fn initInPlace(self: *Owner) void {
        self.* = .{
            .self_addr = @intFromPtr(self),
            .thread_id = std.Thread.getCurrentId(),
        };
    }

    pub fn reset(self: *Owner) error{InvalidOwner}!void {
        if (!self.valid()) return error.InvalidOwner;
        self.counters = .{};
    }

    pub fn snapshot(self: *const Owner) error{InvalidOwner}!Counters {
        if (!self.valid()) return error.InvalidOwner;
        return self.counters;
    }

    fn valid(self: *const Owner) bool {
        return self.self_addr == @intFromPtr(self) and self.thread_id == std.Thread.getCurrentId();
    }
};

threadlocal var installed_owner: ?*Owner = null;

pub fn install(owner: *Owner) error{ InvalidOwner, AlreadyInstalled }!void {
    if (!owner.valid()) return error.InvalidOwner;
    if (installed_owner != null) return error.AlreadyInstalled;
    installed_owner = owner;
}

pub fn uninstall(owner: *Owner) error{InvalidOwner}!void {
    if (!owner.valid() or installed_owner != owner) return error.InvalidOwner;
    installed_owner = null;
}

fn active() ?*Owner {
    const owner = installed_owner orelse return null;
    if (!owner.valid()) return null;
    return owner;
}

fn increment(field: *u64) void {
    field.* = std.math.add(u64, field.*, 1) catch @panic("client idle pump evidence counter exhausted");
}

pub fn recordSelectedOwner() void {
    const owner = active() orelse return;
    increment(&owner.counters.selected_owners);
}

pub fn recordPumpDelta() void {
    const owner = active() orelse return;
    increment(&owner.counters.pump_delta_entries);
}

pub fn recordTimestampSeal() void {
    const owner = active() orelse return;
    increment(&owner.counters.timestamp_seals);
}

pub fn recordRegistryVisit() void {
    const owner = active() orelse return;
    increment(&owner.counters.client_slot_registry_visits);
}

pub fn recordSocketRead() void {
    const owner = active() orelse return;
    increment(&owner.counters.socket_read_attempts);
}

pub fn recordMetadataEvent() void {
    const owner = active() orelse return;
    increment(&owner.counters.metadata_events);
}

pub fn recordScreenEvent() void {
    const owner = active() orelse return;
    increment(&owner.counters.screen_events);
}

pub fn recordEndedEvent() void {
    const owner = active() orelse return;
    increment(&owner.counters.ended_events);
}

test "P4 E3c evidence owner is opt-in, final-address, resettable, and thread-bound" {
    var owner: Owner = undefined;
    owner.initInPlace();
    try install(&owner);
    defer uninstall(&owner) catch @panic("evidence owner uninstall failed");
    recordSelectedOwner();
    recordPumpDelta();
    recordTimestampSeal();
    recordRegistryVisit();
    recordSocketRead();
    recordMetadataEvent();
    recordScreenEvent();
    recordEndedEvent();
    const before = try owner.snapshot();
    try std.testing.expectEqual(@as(u64, 1), before.selected_owners);
    try std.testing.expectEqual(@as(u64, 1), before.client_slot_registry_visits);
    try owner.reset();
    try std.testing.expectEqual(Counters{}, try owner.snapshot());

    var copied = owner;
    try std.testing.expectError(error.InvalidOwner, copied.snapshot());
}
