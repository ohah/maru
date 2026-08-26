//! Host-owned bounded journal for stable OSC notification events (P4 N1).
//!
//! This leaf deliberately has no socket, terminal, or UI dependency. N2 owns product admission and
//! delivery; this module only owns stable identity, memory, eviction, and per-consumer acknowledgement.

const std = @import("std");

/// Product/session-host protocol already owns host identity as a non-zero opaque u128. Reusing that
/// exact type avoids inventing a byte order when journal keys cross the upgrade or RPC boundary.
pub const HostId = u128;
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
pub const LogicalDigest = [32]u8;

pub const HandoffError = std.mem.Allocator.Error || error{
    InvalidOwner,
    DestinationNotEmpty,
    BadMagic,
    UnsupportedVersion,
    Truncated,
    TrailingBytes,
    ForeignHost,
    LimitsMismatch,
    InvalidValue,
    LimitExceeded,
};
pub const EncodeHandoffError = std.mem.Allocator.Error || error{ InvalidOwner, LimitExceeded };

const handoff_magic = "MRUNOT01";
const handoff_version: u16 = 1;

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
        if (key.host_id != self.host_id) return null;
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

    /// Legacy GUI RPC is addressed by runtime. Stable delivery still uses the row key internally;
    /// this selector prevents one Term's poll from consuming another Term's oldest event.
    pub fn oldestPendingForRuntime(self: *const Journal, consumer: Consumer, runtime_id: RuntimeId) ?View {
        if (!self.isOwner()) return null;
        for (self.rows.items) |row| {
            if (row.runtime_id != runtime_id) continue;
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
        if (key.host_id != self.host_id) return .not_found;
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

    pub fn hostId(self: *const Journal) ?HostId {
        return if (self.isOwner()) self.host_id else null;
    }

    /// Encode only logical host-lifetime state. Allocator identity, owner address, and capacity are
    /// process-local and are rebuilt by the successor at its final address.
    pub fn encodeHandoff(self: *const Journal, allocator: std.mem.Allocator, permanent_drops: u64) EncodeHandoffError![]u8 {
        if (!self.isOwner()) return error.InvalidOwner;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, handoff_magic);
        try appendInt(&out, allocator, u16, handoff_version);
        try appendInt(&out, allocator, u128, self.host_id);
        inline for (.{
            self.limits.max_events,
            self.limits.max_resident_bytes,
            self.limits.max_title_bytes,
            self.limits.max_body_bytes,
            self.limits.max_label_bytes,
        }) |value| try appendInt(&out, allocator, u64, std.math.cast(u64, value) orelse return error.LimitExceeded);
        try appendInt(&out, allocator, u64, self.last_event_id);
        try appendInt(&out, allocator, u64, permanent_drops);
        try appendInt(&out, allocator, u64, self.evicted_count);
        try out.append(allocator, @intFromBool(self.event_id_exhausted));
        try appendInt(&out, allocator, u32, std.math.cast(u32, self.rows.items.len) orelse return error.LimitExceeded);
        try appendInt(&out, allocator, u64, std.math.cast(u64, self.resident_bytes) orelse return error.LimitExceeded);
        for (self.rows.items) |row| {
            try appendInt(&out, allocator, u64, row.event_id);
            try appendInt(&out, allocator, u128, row.runtime_id);
            try appendInt(&out, allocator, u64, row.occurred_at_ns);
            try out.append(allocator, @as(u8, @intFromBool(row.pending_gui)) | (@as(u8, @intFromBool(row.pending_os)) << 1));
            try appendInt(&out, allocator, u32, std.math.cast(u32, row.title.len) orelse return error.LimitExceeded);
            try appendInt(&out, allocator, u32, std.math.cast(u32, row.body.len) orelse return error.LimitExceeded);
            try appendInt(&out, allocator, u32, std.math.cast(u32, row.display_label.len) orelse return error.LimitExceeded);
            try out.appendSlice(allocator, row.title);
            try out.appendSlice(allocator, row.body);
            try out.appendSlice(allocator, row.display_label);
        }
        return out.toOwnedSlice(allocator);
    }

    /// Decode into temporary owned rows and publish only after every cap, identity, and ordering
    /// invariant succeeds. The destination must be the empty final-address journal created by init.
    pub fn restoreHandoff(self: *Journal, bytes: []const u8) HandoffError!u64 {
        if (!self.isOwner()) return error.InvalidOwner;
        if (self.rows.items.len != 0 or self.resident_bytes != 0 or self.last_event_id != 0 or
            self.event_id_exhausted or self.evicted_count != 0) return error.DestinationNotEmpty;
        var reader = HandoffReader{ .bytes = bytes };
        if (!std.mem.eql(u8, try reader.take(handoff_magic.len), handoff_magic)) return error.BadMagic;
        if (try reader.int(u16) != handoff_version) return error.UnsupportedVersion;
        if (try reader.int(u128) != self.host_id) return error.ForeignHost;
        const encoded_limits = Limits{
            .max_events = std.math.cast(usize, try reader.int(u64)) orelse return error.LimitExceeded,
            .max_resident_bytes = std.math.cast(usize, try reader.int(u64)) orelse return error.LimitExceeded,
            .max_title_bytes = std.math.cast(usize, try reader.int(u64)) orelse return error.LimitExceeded,
            .max_body_bytes = std.math.cast(usize, try reader.int(u64)) orelse return error.LimitExceeded,
            .max_label_bytes = std.math.cast(usize, try reader.int(u64)) orelse return error.LimitExceeded,
        };
        if (!std.meta.eql(encoded_limits, self.limits)) return error.LimitsMismatch;
        const last_event_id = try reader.int(u64);
        const permanent_drops = try reader.int(u64);
        const evicted_count = try reader.int(u64);
        const exhausted_raw = (try reader.take(1))[0];
        if (exhausted_raw > 1) return error.InvalidValue;
        const exhausted = exhausted_raw == 1;
        if (exhausted != (last_event_id == std.math.maxInt(u64))) return error.InvalidValue;
        const row_count = try reader.int(u32);
        if (row_count > self.limits.max_events) return error.LimitExceeded;
        const encoded_resident = std.math.cast(usize, try reader.int(u64)) orelse return error.LimitExceeded;
        if (encoded_resident > self.limits.max_resident_bytes) return error.LimitExceeded;

        var prepared: std.ArrayListUnmanaged(Row) = .empty;
        errdefer {
            for (prepared.items) |*row| row.deinit(self.allocator);
            prepared.deinit(self.allocator);
        }
        try prepared.ensureTotalCapacity(self.allocator, row_count);
        var resident: usize = 0;
        var previous_event_id: u64 = 0;
        for (0..row_count) |_| {
            const event_id = try reader.int(u64);
            const runtime_id = try reader.int(u128);
            const occurred_at_ns = try reader.int(u64);
            const flags = (try reader.take(1))[0];
            if (event_id == 0 or event_id <= previous_event_id or event_id > last_event_id or runtime_id == 0 or
                flags == 0 or flags & ~@as(u8, 0x03) != 0) return error.InvalidValue;
            const title_len = try boundedLength(&reader, self.limits.max_title_bytes);
            const body_len = try boundedLength(&reader, self.limits.max_body_bytes);
            const label_len = try boundedLength(&reader, self.limits.max_label_bytes);
            const title_source = try reader.take(title_len);
            const body_source = try reader.take(body_len);
            const label_source = try reader.take(label_len);
            if (!std.unicode.utf8ValidateSlice(title_source) or !std.unicode.utf8ValidateSlice(body_source) or
                !std.unicode.utf8ValidateSlice(label_source)) return error.InvalidValue;
            const row_bytes = std.math.add(usize, title_len, body_len) catch return error.LimitExceeded;
            resident = std.math.add(usize, resident, std.math.add(usize, row_bytes, label_len) catch return error.LimitExceeded) catch
                return error.LimitExceeded;
            if (resident > self.limits.max_resident_bytes) return error.LimitExceeded;
            const title = self.allocator.dupe(u8, title_source) catch return error.OutOfMemory;
            errdefer self.allocator.free(title);
            const body = self.allocator.dupe(u8, body_source) catch return error.OutOfMemory;
            errdefer self.allocator.free(body);
            const label = self.allocator.dupe(u8, label_source) catch return error.OutOfMemory;
            errdefer self.allocator.free(label);
            prepared.appendAssumeCapacity(.{
                .event_id = event_id,
                .runtime_id = runtime_id,
                .occurred_at_ns = occurred_at_ns,
                .title = title,
                .body = body,
                .display_label = label,
                .pending_gui = flags & 0x01 != 0,
                .pending_os = flags & 0x02 != 0,
            });
            previous_event_id = event_id;
        }
        if (reader.pos != reader.bytes.len) return error.TrailingBytes;
        if (resident != encoded_resident) return error.InvalidValue;
        self.rows = prepared;
        prepared = .empty;
        self.resident_bytes = resident;
        self.last_event_id = last_event_id;
        self.event_id_exhausted = exhausted;
        self.evicted_count = evicted_count;
        return permanent_drops;
    }

    /// Allocation-free semantic seal used between upgrade capture and destructive exec. It covers
    /// delivery bits and payload bytes, so an ack or admission after capture invalidates the plan.
    pub fn logicalDigest(self: *const Journal, permanent_drops: u64) LogicalDigest {
        var hasher = std.crypto.hash.Blake3.init(.{});
        hasher.update("maru.notification-journal.logical.v1");
        hashInt(&hasher, u128, self.host_id);
        inline for (.{ self.limits.max_events, self.limits.max_resident_bytes, self.limits.max_title_bytes, self.limits.max_body_bytes, self.limits.max_label_bytes }) |value|
            hashInt(&hasher, u64, @intCast(value));
        hashInt(&hasher, u64, self.last_event_id);
        hashInt(&hasher, u64, permanent_drops);
        hashInt(&hasher, u64, self.evicted_count);
        hashInt(&hasher, u8, @intFromBool(self.event_id_exhausted));
        hashInt(&hasher, u64, @intCast(self.resident_bytes));
        hashInt(&hasher, u64, @intCast(self.rows.items.len));
        for (self.rows.items) |row| {
            hashInt(&hasher, u64, row.event_id);
            hashInt(&hasher, u128, row.runtime_id);
            hashInt(&hasher, u64, row.occurred_at_ns);
            hashInt(&hasher, u8, @intFromBool(row.pending_gui));
            hashInt(&hasher, u8, @intFromBool(row.pending_os));
            hashInt(&hasher, u64, @intCast(row.title.len));
            hasher.update(row.title);
            hashInt(&hasher, u64, @intCast(row.body.len));
            hasher.update(row.body);
            hashInt(&hasher, u64, @intCast(row.display_label.len));
            hasher.update(row.display_label);
        }
        var out: LogicalDigest = undefined;
        hasher.final(&out);
        return out;
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

fn appendInt(
    out: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    comptime T: type,
    value: T,
) std.mem.Allocator.Error!void {
    var encoded: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &encoded, value, .big);
    try out.appendSlice(allocator, &encoded);
}

fn hashInt(hasher: *std.crypto.hash.Blake3, comptime T: type, value: T) void {
    var encoded: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &encoded, value, .big);
    hasher.update(&encoded);
}

const HandoffReader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(self: *HandoffReader, len: usize) HandoffError![]const u8 {
        const end = std.math.add(usize, self.pos, len) catch return error.Truncated;
        if (end > self.bytes.len) return error.Truncated;
        defer self.pos = end;
        return self.bytes[self.pos..end];
    }

    fn int(self: *HandoffReader, comptime T: type) HandoffError!T {
        const bytes = try self.take(@sizeOf(T));
        const fixed: *const [@sizeOf(T)]u8 = @ptrCast(bytes.ptr);
        return std.mem.readInt(T, fixed, .big);
    }
};

fn boundedLength(reader: *HandoffReader, limit: usize) HandoffError!usize {
    const len = std.math.cast(usize, try reader.int(u32)) orelse return error.LimitExceeded;
    if (len > limit) return error.LimitExceeded;
    return len;
}

fn viewOf(host_id: HostId, row: Row) View {
    return .{ .key = .{ .host_id = host_id, .event_id = row.event_id }, .runtime_id = row.runtime_id, .occurred_at_ns = row.occurred_at_ns, .title = row.title, .body = row.body, .display_label = row.display_label, .pending_gui = row.pending_gui, .pending_os = row.pending_os };
}

const test_limits: Limits = .{ .max_events = 3, .max_resident_bytes = 64, .max_title_bytes = 16, .max_body_bytes = 32, .max_label_bytes = 16 };
const test_host: HostId = 0x11111111111111111111111111111111;

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
    foreign.host_id ^= 1;
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

test "P4 N2a handoff preserves IDs rows delivery bits and counters" {
    const allocator = std.testing.allocator;
    var source: Journal = undefined;
    try source.initInPlace(allocator, test_host, test_limits);
    defer source.deinit() catch unreachable;
    const first = try source.admit(1, 10, "one", "body", "left");
    _ = try source.admit(2, 11, "two", "body", "right");
    try std.testing.expectEqual(AckResult.acknowledged, source.ack(first, .gui));
    const encoded = try source.encodeHandoff(allocator, 7);
    defer allocator.free(encoded);

    var target: Journal = undefined;
    try target.initInPlace(allocator, test_host, test_limits);
    defer target.deinit() catch unreachable;
    const drops = try target.restoreHandoff(encoded);
    try std.testing.expectEqual(@as(u64, 7), drops);
    try std.testing.expectEqual(@as(u64, 2), target.last_event_id);
    try std.testing.expect(!target.peek(first).?.pending_gui);
    try std.testing.expect(target.peek(first).?.pending_os);
    const next = try target.admit(3, 12, "three", "body", "final");
    try std.testing.expectEqual(@as(u64, 3), next.event_id);
}

test "P4 N2a handoff rejects corruption foreign host and nonempty target without mutation" {
    const allocator = std.testing.allocator;
    var source: Journal = undefined;
    try source.initInPlace(allocator, test_host, test_limits);
    defer source.deinit() catch unreachable;
    _ = try source.admit(1, 10, "one", "body", "left");
    const encoded = try source.encodeHandoff(allocator, 4);
    defer allocator.free(encoded);

    var target: Journal = undefined;
    try target.initInPlace(allocator, test_host, test_limits);
    defer target.deinit() catch unreachable;
    try std.testing.expectError(error.Truncated, target.restoreHandoff(encoded[0 .. encoded.len - 1]));
    try std.testing.expectEqual(@as(usize, 0), target.count());

    var foreign: Journal = undefined;
    try foreign.initInPlace(allocator, test_host ^ 1, test_limits);
    defer foreign.deinit() catch unreachable;
    try std.testing.expectError(error.ForeignHost, foreign.restoreHandoff(encoded));
    try std.testing.expectEqual(@as(usize, 0), foreign.count());

    _ = try target.admit(9, 9, "existing", "row", "kept");
    try std.testing.expectError(error.DestinationNotEmpty, target.restoreHandoff(encoded));
    try std.testing.expectEqual(@as(usize, 1), target.count());
}

test "P4 N2a handoff allocation failures leave destination pristine" {
    const allocator = std.testing.allocator;
    var source: Journal = undefined;
    try source.initInPlace(allocator, test_host, test_limits);
    defer source.deinit() catch unreachable;
    _ = try source.admit(1, 10, "one", "body", "left");
    _ = try source.admit(2, 11, "two", "more", "right");
    const encoded = try source.encodeHandoff(allocator, 4);
    defer allocator.free(encoded);

    var reached_success = false;
    for (0..16) |fail_offset| {
        var failing = std.testing.FailingAllocator.init(allocator, .{});
        var target: Journal = undefined;
        try target.initInPlace(failing.allocator(), test_host, test_limits);
        failing.fail_index = failing.alloc_index + fail_offset;
        const result = target.restoreHandoff(encoded);
        if (result) |drops| {
            reached_success = true;
            try std.testing.expectEqual(@as(u64, 4), drops);
            try std.testing.expectEqual(@as(usize, 2), target.count());
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(@as(usize, 0), target.count());
            try std.testing.expectEqual(@as(usize, 0), target.residentBytes());
            try std.testing.expectEqual(@as(u64, 0), target.last_event_id);
        }
        failing.fail_index = std.math.maxInt(usize);
        try target.deinit();
        if (reached_success) break;
    }
    try std.testing.expect(reached_success);
}
