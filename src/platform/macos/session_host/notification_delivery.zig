//! Host-owned notification delivery metadata (P4 N2b).
//!
//! This leaf owns only bounded runtime configuration snapshots. Socket authorization remains in
//! `server.zig`, journal rows remain in `notification_journal.zig`, and OS presentation belongs to
//! the daemon adapter. Keeping the generation transaction here makes rejected updates mutation-free.

const std = @import("std");

pub const RuntimeId = u128;
pub const max_display_label_bytes: usize = 256;
pub const max_runtime_records: usize = 256;
const handoff_magic = "MRUNMD01";
const handoff_version: u16 = 1;
pub const LogicalDigest = [32]u8;

pub const InitialSnapshot = struct {
    config_generation: u64,
    notifications_osc: bool,
    display_label: []const u8,
};

pub const Update = struct {
    expected_controller_generation: u64,
    config_generation: u64,
    notifications_osc: bool,
    display_label: []const u8,
};

pub const View = struct {
    controller_generation: u64,
    config_generation: u64,
    notifications_osc: bool,
    display_label: []const u8,
};

pub const UpdateResult = enum {
    applied,
    runtime_not_found,
    stale_controller,
    stale_config,
};

pub const Error = std.mem.Allocator.Error || error{
    DuplicateRuntime,
    InvalidRuntimeId,
    InvalidConfigGeneration,
    InvalidDisplayLabel,
    DisplayLabelTooLong,
    StoreFull,
};

pub const HandoffError = Error || error{
    DestinationNotEmpty,
    BadMagic,
    UnsupportedVersion,
    Truncated,
    TrailingBytes,
    InvalidValue,
};

const Record = struct {
    controller_generation: u64,
    config_generation: u64,
    notifications_osc: bool,
    display_label: []u8,

    fn view(self: *const Record) View {
        return .{
            .controller_generation = self.controller_generation,
            .config_generation = self.config_generation,
            .notifications_osc = self.notifications_osc,
            .display_label = self.display_label,
        };
    }
};

pub const MetadataStore = struct {
    allocator: std.mem.Allocator,
    records: std.AutoHashMapUnmanaged(RuntimeId, Record) = .empty,

    pub fn init(allocator: std.mem.Allocator) MetadataStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MetadataStore) void {
        var values = self.records.valueIterator();
        while (values.next()) |record| self.allocator.free(record.display_label);
        self.records.deinit(self.allocator);
        self.* = undefined;
    }

    /// Installs the complete pre-reader snapshot. Missing metadata is intentionally represented by
    /// an owned disabled record so later admission never has to guess whether absence means enabled.
    pub fn install(self: *MetadataStore, runtime_id: RuntimeId, initial: ?InitialSnapshot) Error!void {
        if (runtime_id == 0) return error.InvalidRuntimeId;
        if (self.records.contains(runtime_id)) return error.DuplicateRuntime;
        if (self.records.count() >= max_runtime_records) return error.StoreFull;
        const snapshot = initial orelse InitialSnapshot{
            .config_generation = 0,
            .notifications_osc = false,
            .display_label = "",
        };
        if (initial != null and snapshot.config_generation == 0)
            return error.InvalidConfigGeneration;
        const label = try ownedLabel(self.allocator, runtime_id, snapshot.display_label);
        errdefer self.allocator.free(label);
        try self.records.put(self.allocator, runtime_id, .{
            .controller_generation = 0,
            .config_generation = snapshot.config_generation,
            .notifications_osc = snapshot.notifications_osc,
            .display_label = label,
        });
    }

    pub fn remove(self: *MetadataStore, runtime_id: RuntimeId) bool {
        const removed = self.records.fetchRemove(runtime_id) orelse return false;
        self.allocator.free(removed.value.display_label);
        return true;
    }

    pub fn get(self: *const MetadataStore, runtime_id: RuntimeId) ?View {
        const record = self.records.getPtr(runtime_id) orelse return null;
        return record.view();
    }

    pub fn count(self: *const MetadataStore) usize {
        return self.records.count();
    }

    /// `current_controller_generation` is registry-authoritative evidence gathered by the server
    /// after exact stream/controller authorization. All validation and allocation precedes mutation.
    pub fn update(
        self: *MetadataStore,
        runtime_id: RuntimeId,
        current_controller_generation: u64,
        next: Update,
    ) Error!UpdateResult {
        const record = self.records.getPtr(runtime_id) orelse return .runtime_not_found;
        if (current_controller_generation == 0 or
            next.expected_controller_generation != current_controller_generation)
            return .stale_controller;
        if (next.config_generation == 0) return error.InvalidConfigGeneration;
        if (record.controller_generation == current_controller_generation and
            next.config_generation <= record.config_generation)
            return .stale_config;

        const label = try ownedLabel(self.allocator, runtime_id, next.display_label);
        const old_label = record.display_label;
        record.* = .{
            .controller_generation = current_controller_generation,
            .config_generation = next.config_generation,
            .notifications_osc = next.notifications_osc,
            .display_label = label,
        };
        self.allocator.free(old_label);
        return .applied;
    }

    pub fn encodeHandoff(self: *const MetadataStore, allocator: std.mem.Allocator) Error![]u8 {
        var ids: [max_runtime_records]RuntimeId = undefined;
        var record_count: usize = 0;
        var iterator = self.records.keyIterator();
        while (iterator.next()) |id| : (record_count += 1) ids[record_count] = id.*;
        std.mem.sort(RuntimeId, ids[0..record_count], {}, std.sort.asc(RuntimeId));
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, handoff_magic);
        try appendInt(&out, allocator, u16, handoff_version);
        try appendInt(&out, allocator, u16, @intCast(record_count));
        for (ids[0..record_count]) |id| {
            const record = self.records.getPtr(id).?;
            try appendInt(&out, allocator, u128, id);
            try appendInt(&out, allocator, u64, record.controller_generation);
            try appendInt(&out, allocator, u64, record.config_generation);
            try out.append(allocator, @intFromBool(record.notifications_osc));
            try appendInt(&out, allocator, u16, @intCast(record.display_label.len));
            try out.appendSlice(allocator, record.display_label);
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn restoreHandoff(self: *MetadataStore, bytes: []const u8) HandoffError!void {
        if (self.records.count() != 0) return error.DestinationNotEmpty;
        var reader: Reader = .{ .bytes = bytes };
        if (!std.mem.eql(u8, try reader.take(handoff_magic.len), handoff_magic)) return error.BadMagic;
        if (try reader.int(u16) != handoff_version) return error.UnsupportedVersion;
        const record_count = try reader.int(u16);
        if (record_count > max_runtime_records) return error.StoreFull;
        var candidate = MetadataStore.init(self.allocator);
        errdefer candidate.deinit();
        for (0..record_count) |_| {
            const runtime_id = try reader.int(u128);
            if (runtime_id == 0 or candidate.records.contains(runtime_id)) return error.DuplicateRuntime;
            const controller_generation = try reader.int(u64);
            const config_generation = try reader.int(u64);
            const enabled_raw = (try reader.take(1))[0];
            if (enabled_raw > 1) return error.InvalidValue;
            if (config_generation == 0 and (controller_generation != 0 or enabled_raw != 0))
                return error.InvalidValue;
            if (controller_generation != 0 and config_generation == 0) return error.InvalidValue;
            const label_len = try reader.int(u16);
            if (label_len == 0 or label_len > max_display_label_bytes) return error.InvalidValue;
            const label_bytes = try reader.take(label_len);
            if (!std.unicode.utf8ValidateSlice(label_bytes)) return error.InvalidValue;
            const label = try self.allocator.dupe(u8, label_bytes);
            errdefer self.allocator.free(label);
            try candidate.records.put(self.allocator, runtime_id, .{
                .controller_generation = controller_generation,
                .config_generation = config_generation,
                .notifications_osc = enabled_raw == 1,
                .display_label = label,
            });
        }
        if (reader.pos != bytes.len) return error.TrailingBytes;
        self.* = candidate;
        candidate = undefined;
    }

    pub fn logicalDigest(self: *const MetadataStore) LogicalDigest {
        var ids: [max_runtime_records]RuntimeId = undefined;
        var record_count: usize = 0;
        var iterator = self.records.keyIterator();
        while (iterator.next()) |id| : (record_count += 1) ids[record_count] = id.*;
        std.mem.sort(RuntimeId, ids[0..record_count], {}, std.sort.asc(RuntimeId));
        var hasher = std.crypto.hash.Blake3.init(.{});
        hashInt(&hasher, u64, record_count);
        for (ids[0..record_count]) |id| {
            const record = self.records.getPtr(id).?;
            hashInt(&hasher, u128, id);
            hashInt(&hasher, u64, record.controller_generation);
            hashInt(&hasher, u64, record.config_generation);
            hashInt(&hasher, u8, @intFromBool(record.notifications_osc));
            hashInt(&hasher, u64, record.display_label.len);
            hasher.update(record.display_label);
        }
        var digest: LogicalDigest = undefined;
        hasher.final(&digest);
        return digest;
    }
};

fn ownedLabel(allocator: std.mem.Allocator, runtime_id: RuntimeId, requested: []const u8) Error![]u8 {
    if (requested.len > max_display_label_bytes) return error.DisplayLabelTooLong;
    if (!std.unicode.utf8ValidateSlice(requested)) return error.InvalidDisplayLabel;
    if (requested.len != 0) return allocator.dupe(u8, requested);
    var fallback: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&fallback, "{x:0>32}", .{runtime_id}) catch unreachable;
    return allocator.dupe(u8, text);
}

fn appendInt(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, comptime T: type, value: T) std.mem.Allocator.Error!void {
    var encoded: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &encoded, value, .big);
    try out.appendSlice(allocator, &encoded);
}

fn hashInt(hasher: *std.crypto.hash.Blake3, comptime T: type, value: T) void {
    var encoded: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &encoded, value, .big);
    hasher.update(&encoded);
}

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(self: *Reader, len: usize) HandoffError![]const u8 {
        const end = std.math.add(usize, self.pos, len) catch return error.Truncated;
        if (end > self.bytes.len) return error.Truncated;
        defer self.pos = end;
        return self.bytes[self.pos..end];
    }

    fn int(self: *Reader, comptime T: type) HandoffError!T {
        const bytes = try self.take(@sizeOf(T));
        const fixed: *const [@sizeOf(T)]u8 = @ptrCast(bytes.ptr);
        return std.mem.readInt(T, fixed, .big);
    }
};
