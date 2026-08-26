//! Host-owned bounded journal for stable OSC notification events (P4 N1).
//!
//! This leaf deliberately has no socket, terminal, or UI dependency. N2 owns product admission and
//! delivery; this module only owns stable identity, memory, eviction, and per-consumer acknowledgement.

const std = @import("std");

pub const HostId = [16]u8;
pub const RuntimeId = u128;

pub const Limits = struct {
    max_events: usize,
    max_resident_bytes: usize,
    max_title_bytes: usize,
    max_body_bytes: usize,
    max_label_bytes: usize,

    fn valid(self: Limits) bool {
        return self.max_events > 0 and self.max_resident_bytes > 0 and
            self.max_title_bytes > 0 and self.max_body_bytes > 0 and self.max_label_bytes > 0;
    }
};

pub const Key = struct {
    host_id: HostId,
    event_id: u64,
};

pub const Consumer = enum { gui, os };

pub const View = struct {
    key: Key,
    runtime_id: RuntimeId,
    occurred_at_ns: u64,
    title: []const u8,
    body: []const u8,
    display_label: []const u8,
    pending_gui: bool,
    pending_os: bool,
};

pub const AdmissionError = error{
    FieldTooLarge,
    ResidentLimit,
    EventIdExhausted,
    OutOfMemory,
    InvalidOwner,
};

pub const AckResult = enum { acknowledged, already_acknowledged, not_found, invalid_owner };

const Row = struct {
    event_id: u64,
    runtime_id: RuntimeId,
    occurred_at_ns: u64,
    title: []u8,
    body: []u8,
    display_label: []u8,
    pending_gui: bool = true,
    pending_os: bool = true,

    fn residentBytes(self: Row) usize {
        return self.title.len + self.body.len + self.display_label.len;
    }

    fn deinit(self: *Row, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.body);
        allocator.free(self.display_label);
        self.* = undefined;
    }
};

pub const Journal = struct {
    allocator: std.mem.Allocator,
    owner_addr: usize,
    host_id: HostId,
    limits: Limits,
    rows: std.ArrayListUnmanaged(Row) = .empty,
    resident_bytes: usize = 0,
    last_event_id: u64 = 0,
    event_id_exhausted: bool = false,
    evicted_count: u64 = 0,

    pub fn initInPlace(self: *Journal, allocator: std.mem.Allocator, host_id: HostId, limits: Limits) error{InvalidLimits}!void {
        if (!limits.valid()) return error.InvalidLimits;
        self.* = .{ .allocator = allocator, .owner_addr = @intFromPtr(self), .host_id = host_id, .limits = limits };
    }

    pub fn deinit(self: *Journal) error{InvalidOwner}!void {
        if (!self.isOwner()) return error.InvalidOwner;
        for (self.rows.items) |*row| row.deinit(self.allocator);
        self.rows.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn count(self: *const Journal) usize {
        return self.rows.items.len;
    }

    pub fn residentBytes(self: *const Journal) usize {
        return self.resident_bytes;
    }

    pub fn admit(
        self: *Journal,
        runtime_id: RuntimeId,
        occurred_at_ns: u64,
        title: []const u8,
        body: []const u8,
        display_label: []const u8,
    ) AdmissionError!Key {
        if (!self.isOwner()) return error.InvalidOwner;
        if (title.len > self.limits.max_title_bytes or body.len > self.limits.max_body_bytes or
            display_label.len > self.limits.max_label_bytes) return error.FieldTooLarge;
        const title_body = std.math.add(usize, title.len, body.len) catch return error.ResidentLimit;
        const candidate_bytes = std.math.add(usize, title_body, display_label.len) catch return error.ResidentLimit;
        if (candidate_bytes > self.limits.max_resident_bytes) return error.ResidentLimit;
        if (self.event_id_exhausted) return error.EventIdExhausted;

        // Capacity and all owned fields are prepared before the first mutation or eviction.
        self.rows.ensureUnusedCapacity(self.allocator, 1) catch return error.OutOfMemory;
        const owned_title = self.allocator.dupe(u8, title) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned_title);
        const owned_body = self.allocator.dupe(u8, body) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned_body);
        const owned_label = self.allocator.dupe(u8, display_label) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned_label);

        var remove_count: usize = 0;
        var remaining_bytes = self.resident_bytes;
        while (self.rows.items.len - remove_count >= self.limits.max_events or
            remaining_bytes > self.limits.max_resident_bytes - candidate_bytes)
        {
            remaining_bytes -= self.rows.items[remove_count].residentBytes();
            remove_count += 1;
        }

        const event_id = self.last_event_id + 1;
        for (0..remove_count) |_| {
            var removed = self.rows.orderedRemove(0);
            self.resident_bytes -= removed.residentBytes();
            removed.deinit(self.allocator);
            self.evicted_count += 1;
        }
        self.rows.appendAssumeCapacity(.{
            .event_id = event_id,
            .runtime_id = runtime_id,
            .occurred_at_ns = occurred_at_ns,
            .title = owned_title,
            .body = owned_body,
            .display_label = owned_label,
        });
        self.resident_bytes += candidate_bytes;
        self.last_event_id = event_id;
        if (event_id == std.math.maxInt(u64)) self.event_id_exhausted = true;
        return .{ .host_id = self.host_id, .event_id = event_id };
    }

    /// Returned slices borrow the journal and remain valid only until its next successful mutation.
    pub fn peek(self: *const Journal, key: Key) ?View {
        if (!self.isOwner()) return null;
        if (!std.mem.eql(u8, &key.host_id, &self.host_id)) return null;
        for (self.rows.items) |row| if (row.event_id == key.event_id) return viewOf(self.host_id, row);
        return null;
    }

    /// Returned slices borrow the journal and remain valid only until its next successful mutation.
    pub fn oldestPending(self: *const Journal, consumer: Consumer) ?View {
        if (!self.isOwner()) return null;
        for (self.rows.items) |row| {
            const pending = switch (consumer) {
                .gui => row.pending_gui,
                .os => row.pending_os,
            };
            if (pending) return viewOf(self.host_id, row);
        }
        return null;
    }

    pub fn ack(self: *Journal, key: Key, consumer: Consumer) AckResult {
        if (!self.isOwner()) return .invalid_owner;
        if (!std.mem.eql(u8, &key.host_id, &self.host_id)) return .not_found;
        for (self.rows.items) |*row| {
            if (row.event_id != key.event_id) continue;
            const pending = switch (consumer) {
                .gui => &row.pending_gui,
                .os => &row.pending_os,
            };
            if (!pending.*) return .already_acknowledged;
            pending.* = false;
            self.reclaimAcknowledgedPrefix();
            return .acknowledged;
        }
        return .not_found;
    }

    fn reclaimAcknowledgedPrefix(self: *Journal) void {
        while (self.rows.items.len > 0 and !self.rows.items[0].pending_gui and !self.rows.items[0].pending_os) {
            var removed = self.rows.orderedRemove(0);
            self.resident_bytes -= removed.residentBytes();
            removed.deinit(self.allocator);
        }
    }

    fn isOwner(self: *const Journal) bool {
        return self.owner_addr == @intFromPtr(self);
    }
};

fn viewOf(host_id: HostId, row: Row) View {
    return .{ .key = .{ .host_id = host_id, .event_id = row.event_id }, .runtime_id = row.runtime_id, .occurred_at_ns = row.occurred_at_ns, .title = row.title, .body = row.body, .display_label = row.display_label, .pending_gui = row.pending_gui, .pending_os = row.pending_os };
}

const test_limits: Limits = .{ .max_events = 3, .max_resident_bytes = 64, .max_title_bytes = 16, .max_body_bytes = 32, .max_label_bytes = 16 };
const test_host: HostId = [_]u8{0x11} ** 16;

test "P4 N1 limits reject zero before ownership" {
    var limits = test_limits;
    limits.max_events = 0;
    var journal: Journal = undefined;
    try std.testing.expectError(error.InvalidLimits, journal.initInPlace(std.testing.allocator, test_host, limits));
}

test "P4 N1 stable identity is monotonic and independent from runtime" {
    var journal: Journal = undefined;
    try journal.initInPlace(std.testing.allocator, test_host, test_limits);
    defer journal.deinit() catch unreachable;
    const a = try journal.admit(7, 10, "a", "one", "left");
    const b = try journal.admit(9, 11, "b", "two", "right");
    try std.testing.expectEqual(@as(u64, 1), a.event_id);
    try std.testing.expectEqual(@as(u64, 2), b.event_id);
    try std.testing.expectEqual(@as(u128, 9), journal.peek(b).?.runtime_id);
    journal.last_event_id = std.math.maxInt(u64) - 1;
    const last = try journal.admit(10, 12, "c", "three", "final");
    try std.testing.expectEqual(std.math.maxInt(u64), last.event_id);
    const before_count = journal.count();
    try std.testing.expectError(error.EventIdExhausted, journal.admit(11, 13, "d", "four", "blocked"));
    try std.testing.expectEqual(before_count, journal.count());
    try std.testing.expectEqual(std.math.maxInt(u64), journal.last_event_id);
}

test "P4 N1 dual delivery ack is isolated and exact once" {
    var journal: Journal = undefined;
    try journal.initInPlace(std.testing.allocator, test_host, test_limits);
    defer journal.deinit() catch unreachable;
    const key = try journal.admit(1, 2, "title", "body", "label");
    try std.testing.expectEqual(AckResult.acknowledged, journal.ack(key, .gui));
    try std.testing.expectEqual(AckResult.already_acknowledged, journal.ack(key, .gui));
    try std.testing.expect(journal.oldestPending(.gui) == null);
    try std.testing.expectEqual(key.event_id, journal.oldestPending(.os).?.key.event_id);
    try std.testing.expect(journal.peek(key).?.pending_os);
    try std.testing.expectEqual(AckResult.acknowledged, journal.ack(key, .os));
    try std.testing.expectEqual(@as(usize, 0), journal.count());
}

test "P4 N1 cross-host and unknown acknowledgements do not mutate" {
    var journal: Journal = undefined;
    try journal.initInPlace(std.testing.allocator, test_host, test_limits);
    defer journal.deinit() catch unreachable;
    const key = try journal.admit(1, 2, "t", "b", "l");
    var foreign = key;
    foreign.host_id[0] ^= 1;
    try std.testing.expectEqual(AckResult.not_found, journal.ack(foreign, .gui));
    try std.testing.expectEqual(AckResult.not_found, journal.ack(.{ .host_id = test_host, .event_id = 99 }, .gui));
    try std.testing.expect(journal.peek(key).?.pending_gui);
}

test "P4 N1 full journal evicts oldest only after candidate preparation" {
    var journal: Journal = undefined;
    try journal.initInPlace(std.testing.allocator, test_host, test_limits);
    defer journal.deinit() catch unreachable;
    const first = try journal.admit(1, 1, "1", "one", "x");
    _ = try journal.admit(1, 2, "2", "two", "x");
    _ = try journal.admit(1, 3, "3", "three", "x");
    const fourth = try journal.admit(1, 4, "4", "four", "x");
    try std.testing.expect(journal.peek(first) == null);
    try std.testing.expectEqual(@as(u64, 1), journal.evicted_count);
    try std.testing.expectEqualStrings("4", journal.peek(fourth).?.title);

    var byte_limits = test_limits;
    byte_limits.max_events = 10;
    byte_limits.max_resident_bytes = 8;
    var byte_journal: Journal = undefined;
    try byte_journal.initInPlace(std.testing.allocator, test_host, byte_limits);
    defer byte_journal.deinit() catch unreachable;
    const byte_first = try byte_journal.admit(1, 1, "a", "bb", "c");
    _ = try byte_journal.admit(1, 2, "d", "ee", "f");
    const byte_third = try byte_journal.admit(1, 3, "g", "hh", "i");
    try std.testing.expect(byte_journal.peek(byte_first) == null);
    try std.testing.expect(byte_journal.peek(byte_third) != null);
    try std.testing.expectEqual(@as(usize, 8), byte_journal.residentBytes());
}

test "P4 N1 field and resident caps fail before mutation" {
    var journal: Journal = undefined;
    try journal.initInPlace(std.testing.allocator, test_host, test_limits);
    defer journal.deinit() catch unreachable;
    _ = try journal.admit(1, 1, "ok", "body", "label");
    const before = journal.residentBytes();
    try std.testing.expectError(error.FieldTooLarge, journal.admit(1, 2, "0123456789abcdefg", "", ""));
    var limits = test_limits;
    limits.max_resident_bytes = 2;
    var tiny: Journal = undefined;
    try tiny.initInPlace(std.testing.allocator, test_host, limits);
    defer tiny.deinit() catch unreachable;
    try std.testing.expectError(error.ResidentLimit, tiny.admit(1, 1, "a", "b", "c"));
    try std.testing.expectEqual(before, journal.residentBytes());
    try std.testing.expectEqual(@as(u64, 1), journal.last_event_id);
}

test "P4 N1 allocator failures preserve full journal and event identity" {
    // The full journal already owns row capacity; candidate preparation has exactly three non-empty field dupes.
    for (0..3) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var journal: Journal = undefined;
        try journal.initInPlace(failing.allocator(), test_host, test_limits);
        defer journal.deinit() catch unreachable;
        _ = try journal.admit(1, 1, "1", "one", "x");
        _ = try journal.admit(1, 2, "2", "two", "x");
        _ = try journal.admit(1, 3, "3", "three", "x");
        const first = journal.rows.items[0].event_id;
        const before_bytes = journal.residentBytes();
        failing.fail_index = failing.alloc_index + fail_index;
        try std.testing.expectError(error.OutOfMemory, journal.admit(1, 4, "4", "four", "x"));
        failing.fail_index = std.math.maxInt(usize);
        try std.testing.expectEqual(@as(usize, 3), journal.count());
        try std.testing.expectEqual(first, journal.rows.items[0].event_id);
        try std.testing.expectEqual(before_bytes, journal.residentBytes());
        try std.testing.expectEqual(@as(u64, 3), journal.last_event_id);
    }
}

test "P4 N1 copied owner cannot read mutate or free canonical rows" {
    var journal: Journal = undefined;
    try journal.initInPlace(std.testing.allocator, test_host, test_limits);
    defer journal.deinit() catch unreachable;
    const key = try journal.admit(1, 1, "title", "body", "label");
    var copied = journal;
    try std.testing.expect(copied.peek(key) == null);
    try std.testing.expectEqual(AckResult.invalid_owner, copied.ack(key, .gui));
    try std.testing.expectError(error.InvalidOwner, copied.admit(1, 2, "x", "y", "z"));
    try std.testing.expectError(error.InvalidOwner, copied.deinit());
    try std.testing.expect(journal.peek(key) != null);
}
