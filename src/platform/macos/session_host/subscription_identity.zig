//! Multi-connection session-host subscription identity.
//!
//! Wire `stream_id` is connection-local. Registry/controller authority instead consumes a daemon-global
//! `SubscriptionId`, so two clients may both use local stream 1 without aliasing. Every lookup includes the
//! T0a `ConnectionKey`; slot generation reuse therefore cannot route a stale callback into a new connection.

const std = @import("std");
const connection_slot = @import("connection_slot.zig");

pub const SubscriptionId = struct {
    value: u64,
};
pub const LocalStreamId = u64;
pub const max_subscriptions: usize =
    connection_slot.max_connections * connection_slot.max_screen_trackers_per_slot;

pub const LocalKey = struct {
    connection: connection_slot.ConnectionKey,
    stream_id: LocalStreamId,
};

pub const Record = struct {
    connection: connection_slot.ConnectionKey,
    stream_id: LocalStreamId,
    runtime_id: u128,
};

const LocalContext = struct {
    pub fn hash(_: LocalContext, key: LocalKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&key.connection.monotonic_id));
        h.update(std.mem.asBytes(&key.connection.slot_generation));
        h.update(std.mem.asBytes(&key.stream_id));
        return h.final();
    }

    pub fn eql(_: LocalContext, a: LocalKey, b: LocalKey) bool {
        return std.meta.eql(a, b);
    }
};

const LocalMap = std.HashMapUnmanaged(LocalKey, SubscriptionId, LocalContext, 80);

pub const Table = struct {
    allocator: std.mem.Allocator,
    next_id: u64 = 1,
    local_to_global: LocalMap = .empty,
    global_to_record: std.AutoHashMapUnmanaged(SubscriptionId, Record) = .empty,

    pub fn init(allocator: std.mem.Allocator) Table {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Table) void {
        self.local_to_global.deinit(self.allocator);
        self.global_to_record.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn register(
        self: *Table,
        local: LocalKey,
        runtime_id: u128,
    ) error{ Invalid, Duplicate, Full, Exhausted, OutOfMemory }!SubscriptionId {
        if (!local.connection.valid() or local.stream_id == 0 or runtime_id == 0) return error.Invalid;
        if (self.local_to_global.contains(local)) return error.Duplicate;
        if (self.global_to_record.count() == max_subscriptions) return error.Full;
        if (self.connectionCount(local.connection) ==
            connection_slot.max_screen_trackers_per_slot) return error.Full;
        if (self.next_id == 0) return error.Exhausted;

        const raw_id = self.next_id;
        self.next_id = std.math.add(u64, raw_id, 1) catch 0;
        const id = SubscriptionId{ .value = raw_id };
        self.global_to_record.put(self.allocator, id, .{
            .connection = local.connection,
            .stream_id = local.stream_id,
            .runtime_id = runtime_id,
        }) catch return error.OutOfMemory;
        errdefer _ = self.global_to_record.remove(id);
        self.local_to_global.put(self.allocator, local, id) catch return error.OutOfMemory;
        return id;
    }

    pub fn resolveLocal(self: *const Table, local: LocalKey) ?SubscriptionId {
        return self.local_to_global.get(local);
    }

    pub fn resolveGlobal(self: *const Table, id: SubscriptionId) ?Record {
        return self.global_to_record.get(id);
    }

    pub fn revoke(
        self: *Table,
        local: LocalKey,
    ) error{Stale}!Record {
        const id = self.local_to_global.get(local) orelse return error.Stale;
        const record = self.global_to_record.get(id) orelse return error.Stale;
        _ = self.local_to_global.remove(local);
        _ = self.global_to_record.remove(id);
        return record;
    }

    /// A connection owns at most one local stream per screen tracker, so the fixed collection is bounded by 256.
    pub fn revokeConnection(self: *Table, connection: connection_slot.ConnectionKey) usize {
        var ids: [connection_slot.max_screen_trackers_per_slot]SubscriptionId = undefined;
        var found: usize = 0;
        var it = self.global_to_record.iterator();
        while (it.next()) |entry| {
            if (!std.meta.eql(entry.value_ptr.connection, connection)) continue;
            std.debug.assert(found < ids.len);
            ids[found] = entry.key_ptr.*;
            found += 1;
        }
        for (ids[0..found]) |id| {
            const record = self.global_to_record.get(id).?;
            _ = self.local_to_global.remove(.{
                .connection = record.connection,
                .stream_id = record.stream_id,
            });
            _ = self.global_to_record.remove(id);
        }
        return found;
    }

    pub fn count(self: *const Table) usize {
        return self.global_to_record.count();
    }

    /// 같은 owner turn에서 runtime event fan-out 대상을 안정된 owned snapshot으로 만든다.
    pub fn collectRuntimeRecords(
        self: *const Table,
        allocator: std.mem.Allocator,
        runtime_id: u128,
    ) error{OutOfMemory}![]Record {
        var count_for_runtime: usize = 0;
        var count_it = self.global_to_record.valueIterator();
        while (count_it.next()) |record|
            if (record.runtime_id == runtime_id) {
                count_for_runtime += 1;
            };
        const records = allocator.alloc(Record, count_for_runtime) catch
            return error.OutOfMemory;
        var index: usize = 0;
        var it = self.global_to_record.valueIterator();
        while (it.next()) |record| {
            if (record.runtime_id != runtime_id) continue;
            records[index] = record.*;
            index += 1;
        }
        std.debug.assert(index == records.len);
        return records;
    }

    fn connectionCount(self: *const Table, connection: connection_slot.ConnectionKey) usize {
        var total: usize = 0;
        var it = self.global_to_record.valueIterator();
        while (it.next()) |record| {
            if (std.meta.eql(record.connection, connection)) total += 1;
        }
        return total;
    }
};

test "two connections keep local stream one but receive distinct global subscriptions" {
    var table = Table.init(std.testing.allocator);
    defer table.deinit();
    const first = LocalKey{
        .connection = .{ .monotonic_id = 1, .slot_generation = 1 },
        .stream_id = 1,
    };
    const second = LocalKey{
        .connection = .{ .monotonic_id = 2, .slot_generation = 1 },
        .stream_id = 1,
    };
    const a = try table.register(first, 0xAA);
    const b = try table.register(second, 0xBB);
    try std.testing.expectEqual(@as(u64, 1), a.value);
    try std.testing.expectEqual(@as(u64, 2), b.value);
    try std.testing.expectEqual(a, table.resolveLocal(first).?);
    try std.testing.expectEqual(b, table.resolveLocal(second).?);
}

test "connection generation ABA and close revoke cannot target replacement slot" {
    var table = Table.init(std.testing.allocator);
    defer table.deinit();
    const old = connection_slot.ConnectionKey{ .monotonic_id = 7, .slot_generation = 1 };
    const replacement = connection_slot.ConnectionKey{ .monotonic_id = 8, .slot_generation = 2 };
    const old_local = LocalKey{ .connection = old, .stream_id = 1 };
    _ = try table.register(old_local, 0xAA);
    _ = try table.register(.{ .connection = old, .stream_id = 2 }, 0xBB);
    try std.testing.expectEqual(@as(usize, 2), table.revokeConnection(old));
    try std.testing.expect(table.resolveLocal(old_local) == null);
    const fresh = try table.register(.{ .connection = replacement, .stream_id = 1 }, 0xCC);
    try std.testing.expectEqual(@as(u64, 3), fresh.value);
    try std.testing.expectEqual(@as(usize, 0), table.revokeConnection(old));
    try std.testing.expectEqual(@as(u128, 0xCC), table.resolveGlobal(fresh).?.runtime_id);
}

test "subscription counter overflow never emits zero or reuses an id" {
    var table = Table.init(std.testing.allocator);
    defer table.deinit();
    table.next_id = std.math.maxInt(u64);
    const max = try table.register(.{
        .connection = .{ .monotonic_id = 1, .slot_generation = 1 },
        .stream_id = 1,
    }, 1);
    try std.testing.expectEqual(std.math.maxInt(u64), max.value);
    try std.testing.expectError(error.Exhausted, table.register(.{
        .connection = .{ .monotonic_id = 1, .slot_generation = 1 },
        .stream_id = 2,
    }, 1));
}

test "one connection has an exact 256 subscription revoke bound" {
    var table = Table.init(std.testing.allocator);
    defer table.deinit();
    const connection = connection_slot.ConnectionKey{ .monotonic_id = 1, .slot_generation = 1 };
    for (1..connection_slot.max_screen_trackers_per_slot + 1) |stream_id| {
        _ = try table.register(.{
            .connection = connection,
            .stream_id = stream_id,
        }, stream_id);
    }
    try std.testing.expectError(error.Full, table.register(.{
        .connection = connection,
        .stream_id = connection_slot.max_screen_trackers_per_slot + 1,
    }, 1));
    try std.testing.expectEqual(
        connection_slot.max_screen_trackers_per_slot,
        table.revokeConnection(connection),
    );
}

test "subscription table enforces exact daemon 8192 cap without damaging existing records" {
    var table = Table.init(std.testing.allocator);
    defer table.deinit();
    var first_id: ?SubscriptionId = null;
    for (1..connection_slot.max_connections + 1) |connection_index| {
        const connection = connection_slot.ConnectionKey{
            .monotonic_id = connection_index,
            .slot_generation = 1,
        };
        for (1..connection_slot.max_screen_trackers_per_slot + 1) |stream_id| {
            const id = try table.register(.{
                .connection = connection,
                .stream_id = stream_id,
            }, connection_index);
            if (first_id == null) first_id = id;
        }
    }
    try std.testing.expectEqual(max_subscriptions, table.count());
    try std.testing.expectError(error.Full, table.register(.{
        .connection = .{ .monotonic_id = connection_slot.max_connections + 1, .slot_generation = 1 },
        .stream_id = 1,
    }, 1));
    try std.testing.expectEqual(max_subscriptions, table.count());
    try std.testing.expectEqual(@as(u128, 1), table.resolveGlobal(first_id.?).?.runtime_id);
}

test "subscription register OOM rolls back both maps without reusing the burned id" {
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 1 },
    );
    var table = Table.init(failing.allocator());
    defer table.deinit();
    try std.testing.expectError(error.OutOfMemory, table.register(.{
        .connection = .{ .monotonic_id = 1, .slot_generation = 1 },
        .stream_id = 1,
    }, 1));
    try std.testing.expectEqual(@as(usize, 0), table.count());
    try std.testing.expectEqual(@as(u64, 2), table.next_id);
}
