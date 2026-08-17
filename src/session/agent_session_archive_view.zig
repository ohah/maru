//! 에이전트 세션 archive 도크의 그룹·카드 투영.
//!
//! 이 모듈은 provider log, AppKit, renderer를 알지 않는다. 이미 mtime 순으로
//! 필터된 record identity를 workspace 그룹과 3줄 카드의 **표시 행**으로 바꾼다.
//! 따라서 scroll/hit-test가 도크의 고정 chrome이나 선택 detail에 의존하지 않는다.

const std = @import("std");
const i18n = @import("../i18n.zig"); // 표시 문자열 단일 출처

pub const card_rows: usize = 3;

pub const Item = struct {
    record_index: usize,
    /// Canonical local cwd only. Empty/noncanonical cwd is the one shared
    /// unknown-location bucket, rather than a lexical path grouping.
    cwd: []const u8,
    cwd_canonical: bool,
};

pub const Group = struct {
    /// Owned canonical cwd, or the empty unknown-location key.
    key: []u8,
    /// Borrowed basename of key, or the stable unknown label.
    label: []const u8,
    count: usize = 0,
    collapsed: bool = false,
    /// Record indices are retained only while this projection is live. Keeping
    /// them here makes the grouped emission linear instead of rescanning every
    /// filtered session for every workspace on the UI thread.
    record_indices: std.ArrayList(usize) = .empty,
};

pub const Entry = union(enum) {
    group: usize,
    card: usize,

    pub fn visualRows(self: Entry) usize {
        return switch (self) {
            .group => 1,
            .card => card_rows,
        };
    }
};

pub const Projection = struct {
    groups: std.ArrayList(Group) = .empty,
    entries: std.ArrayList(Entry) = .empty,
    visual_rows: usize = 0,

    pub fn deinit(self: *Projection, allocator: std.mem.Allocator) void {
        for (self.groups.items) |*group| {
            allocator.free(group.key);
            group.record_indices.deinit(allocator);
        }
        self.groups.deinit(allocator);
        self.entries.deinit(allocator);
        self.* = .{};
    }

    pub fn visualRowAt(self: *const Projection, row: usize) ?struct { entry_index: usize, line: usize } {
        var offset: usize = 0;
        for (self.entries.items, 0..) |entry, entry_index| {
            const height = entry.visualRows();
            if (row < offset + height) return .{ .entry_index = entry_index, .line = row - offset };
            offset += height;
        }
        return null;
    }
};

pub fn build(
    allocator: std.mem.Allocator,
    items: []const Item,
    collapsed_keys: []const []const u8,
) !Projection {
    var out: Projection = .{};
    errdefer out.deinit(allocator);
    var group_indices: std.StringHashMapUnmanaged(usize) = .empty;
    defer group_indices.deinit(allocator);

    // Input is already newest-first.  First occurrence determines group order;
    // subsequent entries preserve that chronological order inside the group.
    for (items) |item| {
        const key = if (item.cwd_canonical and item.cwd.len > 0) item.cwd else "";
        const lookup = try group_indices.getOrPut(allocator, key);
        const group_index: usize = if (lookup.found_existing)
            lookup.value_ptr.*
        else blk: {
            const owned_key = try allocator.dupe(u8, key);
            errdefer allocator.free(owned_key);
            const collapsed = contains(collapsed_keys, key);
            try out.groups.append(allocator, .{
                .key = owned_key,
                .label = groupLabel(owned_key),
                .collapsed = collapsed,
            });
            const index = out.groups.items.len - 1;
            lookup.value_ptr.* = index;
            break :blk index;
        };
        const group = &out.groups.items[group_index];
        group.count += 1;
        try group.record_indices.append(allocator, item.record_index);
    }

    // Emit each group contiguously.  This second bounded pass preserves the
    // original newest-first order within a group while keeping its cards under
    // the one header users can collapse.
    for (out.groups.items, 0..) |group, group_index| {
        try out.entries.append(allocator, .{ .group = group_index });
        out.visual_rows += 1;
        if (group.collapsed) continue;
        for (group.record_indices.items) |record_index| {
            try out.entries.append(allocator, .{ .card = record_index });
            out.visual_rows += card_rows;
        }
    }
    return out;
}

pub fn groupLabel(key: []const u8) []const u8 {
    return if (key.len == 0) i18n.t(.arch_unknown_location) else std.fs.path.basename(key);
}

fn contains(keys: []const []const u8, needle: []const u8) bool {
    for (keys) |key| if (std.mem.eql(u8, key, needle)) return true;
    return false;
}

test "projection groups noncontiguous cwd records and retains newest order within each group" {
    const items = [_]Item{
        .{ .record_index = 4, .cwd = "/work/a", .cwd_canonical = true },
        .{ .record_index = 3, .cwd = "/work/b", .cwd_canonical = true },
        .{ .record_index = 2, .cwd = "/work/a", .cwd_canonical = true },
        .{ .record_index = 1, .cwd = "ssh://host/work", .cwd_canonical = false },
    };
    var projection = try build(std.testing.allocator, &items, &.{});
    defer projection.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), projection.groups.items.len);
    try std.testing.expectEqualStrings("a", projection.groups.items[0].label);
    try std.testing.expectEqualStrings("b", projection.groups.items[1].label);
    try std.testing.expectEqualStrings(i18n.t(.arch_unknown_location), projection.groups.items[2].label);
    try std.testing.expectEqual(@as(usize, 15), projection.visual_rows);
    try std.testing.expectEqual(@as(usize, 4), projection.entries.items[1].card);
    try std.testing.expectEqual(@as(usize, 2), projection.entries.items[2].card);
}

test "projection preserves collapsed group header and visual hit rows" {
    const items = [_]Item{
        .{ .record_index = 0, .cwd = "/work/a", .cwd_canonical = true },
        .{ .record_index = 1, .cwd = "/work/b", .cwd_canonical = true },
    };
    const collapsed = [_][]const u8{"/work/a"};
    var projection = try build(std.testing.allocator, &items, &collapsed);
    defer projection.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 5), projection.visual_rows);
    try std.testing.expectEqual(@as(usize, 0), projection.visualRowAt(0).?.entry_index);
    try std.testing.expectEqual(@as(usize, 1), projection.visualRowAt(1).?.entry_index);
    try std.testing.expectEqual(@as(usize, 2), projection.visualRowAt(2).?.entry_index);
    try std.testing.expectEqual(@as(usize, 2), projection.visualRowAt(4).?.line);
}
