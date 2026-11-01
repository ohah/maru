//! Shared native shaping inputs. Core snapshots have already been copied into
//! DrawList: these routines borrow frame-owned cells, never a live core screen.
const std = @import("std");
const draw = @import("draw_list.zig");
const terminal = @import("../terminal.zig");

pub const bold_bit: u16 = 1 << 0;
pub const italic_bit: u16 = 1 << 1;
pub const cursor_bit: u16 = 1 << 2;

/// Preserve the existing CoreText host policy: visible cursor cells form a
/// separate shaping key so editing a ligature exposes its individual cells.
pub fn atCursor(cell: draw.DrawCell, cursor: terminal.Cursor) bool {
    if (!cursor.visible or cell.row != cursor.row) return false;
    const width: u32 = @max(1, cell.width);
    return cursor.col >= cell.col and @as(u32, cursor.col) < @as(u32, cell.col) + width;
}

/// Shared bold/italic face index for shaping and native raster banks.
pub fn faceKey(style: terminal.Style) u2 {
    const key: u16 = (if (style.bold) bold_bit else 0) | (if (style.italic) italic_bit else 0);
    return @intCast(key);
}

/// This is the existing native face/cursor key, not a paint-style key. Native
/// adapters decode these bits rather than reconstructing cursor-hit policy.
pub fn styleKey(cell: draw.DrawCell, cursor: terminal.Cursor) u16 {
    return @as(u16, faceKey(cell.style)) |
        (if (atCursor(cell, cursor)) cursor_bit else 0);
}

pub const UnitOwner = struct { cell_index: u32, col: u16, width: u2 };
pub const Text = struct {
    utf8: []u8,
    utf16_owners: []UnitOwner,

    pub fn deinit(self: *Text, allocator: std.mem.Allocator) void {
        allocator.free(self.utf8);
        allocator.free(self.utf16_owners);
        self.* = undefined;
    }
};

fn scalarLength(cp: u32) error{InvalidCodepoint}!usize {
    if (cp > 0x10ffff or (cp >= 0xd800 and cp <= 0xdfff)) return error.InvalidCodepoint;
    return std.unicode.utf8CodepointSequenceLength(@intCast(cp)) catch return error.InvalidCodepoint;
}

fn extras(cell: draw.DrawCell, pool: []const u32) error{InvalidGraphemeRange}![]const u32 {
    const start: usize = cell.grapheme_offset;
    const count: usize = cell.grapheme_count;
    if (count == 0) return &.{};
    if (start > pool.len or count > pool.len - start) return error.InvalidGraphemeRange;
    return pool[start..][0..count];
}

/// Prepare one contiguous row slice without losing grapheme extras. Surrogate
/// pairs repeat the same owner; NFD/ZWJ scalars repeat their base cell owner.
/// Preflight all ranges/scalars before allocation and allocate exact buffers so
/// a native shaper can use the complete UTF-16 map without partial publication.
pub fn prepare(allocator: std.mem.Allocator, cells: []const draw.DrawCell, pool: []const u32) !Text {
    if (cells.len > std.math.maxInt(u32)) return error.TextTooLarge;
    var byte_count: usize = 0;
    var unit_count: usize = 0;
    for (cells, 0..) |cell, index| {
        const width: u32 = @max(1, cell.width);
        if (width > 2 or @as(u32, cell.col) + width > std.math.maxInt(u16)) return error.InvalidCell;
        if (index > 0) {
            const previous = cells[index - 1];
            if (cell.row != previous.row or @as(u32, previous.col) + @max(@as(u32, 1), previous.width) != cell.col) return error.DiscontinuousCells;
        }
        const extra = try extras(cell, pool);
        const base: u32 = if (cell.codepoint == 0) ' ' else cell.codepoint;
        byte_count = try std.math.add(usize, byte_count, try scalarLength(base));
        unit_count = try std.math.add(usize, unit_count, if (base > 0xffff) 2 else 1);
        for (extra) |cp| {
            byte_count = try std.math.add(usize, byte_count, try scalarLength(cp));
            unit_count = try std.math.add(usize, unit_count, if (cp > 0xffff) 2 else 1);
        }
    }
    if (unit_count > std.math.maxInt(u32)) return error.TextTooLarge;
    const utf8 = try allocator.alloc(u8, byte_count);
    errdefer allocator.free(utf8);
    const owners = try allocator.alloc(UnitOwner, unit_count);
    errdefer allocator.free(owners);
    var bytes: usize = 0;
    var units: usize = 0;
    for (cells, 0..) |cell, index| {
        const owner: UnitOwner = .{ .cell_index = @intCast(index), .col = cell.col, .width = @max(1, cell.width) };
        try appendScalar(if (cell.codepoint == 0) ' ' else cell.codepoint, owner, utf8, owners, &bytes, &units);
        for (try extras(cell, pool)) |cp| try appendScalar(cp, owner, utf8, owners, &bytes, &units);
    }
    return .{ .utf8 = utf8, .utf16_owners = owners };
}

fn appendScalar(cp: u32, owner: UnitOwner, text: []u8, owners: []UnitOwner, bytes: *usize, units: *usize) !void {
    _ = try scalarLength(cp);
    var encoded: [4]u8 = undefined;
    const count = try std.unicode.utf8Encode(@intCast(cp), &encoded);
    @memcpy(text[bytes.*..][0..count], encoded[0..count]);
    bytes.* += count;
    owners[units.*] = owner;
    units.* += 1;
    if (cp > 0xffff) {
        owners[units.*] = owner;
        units.* += 1;
    }
}

test "shaping run face cursor key preserves all eight native combinations and ignores paint" {
    for (0..8) |key| {
        const cell: draw.DrawCell = .{ .row = 2, .col = 3, .codepoint = 'A', .style = .{ .bold = key & 1 != 0, .italic = key & 2 != 0, .underline = true, .conceal = true } };
        try std.testing.expectEqual(@as(u16, @intCast(key)), styleKey(cell, .{ .row = 2, .col = 3, .visible = key & 4 != 0 }));
        try std.testing.expectEqual(@as(u16, @intCast(key & 3)), styleKey(cell, .{ .row = 3, .col = 3, .visible = true }));
    }
}

test "shaping run cursor hit preserves wide continuation zero width and nonwrapping edge" {
    const wide: draw.DrawCell = .{ .row = 0, .col = 10, .width = 2, .codepoint = 'A' };
    try std.testing.expect(atCursor(wide, .{ .row = 0, .col = 11 }));
    try std.testing.expect(!atCursor(wide, .{ .row = 0, .col = 12 }));
    try std.testing.expect(!atCursor(wide, .{ .row = 0, .col = 11, .visible = false }));
    try std.testing.expect(atCursor(.{ .row = 0, .col = 65535, .width = 2, .codepoint = 'A' }, .{ .row = 0, .col = 65535 }));
    try std.testing.expect(atCursor(.{ .row = 0, .col = 4, .width = 0, .codepoint = 'A' }, .{ .row = 0, .col = 4 }));
}

test "shaping run text keeps emoji surrogate units and every NFD scalar on its original cell" {
    const cells = [_]draw.DrawCell{
        .{ .row = 0, .col = 0, .codepoint = 'A' },
        .{ .row = 0, .col = 1, .width = 2, .codepoint = 0x1f600 },
        .{ .row = 0, .col = 3, .width = 2, .codepoint = 0x1100, .grapheme_count = 2 },
    };
    var text = try prepare(std.testing.allocator, &cells, &.{ 0x1161, 0x11a8 });
    defer text.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("A\u{1f600}\u{1100}\u{1161}\u{11a8}", text.utf8);
    try std.testing.expectEqual(@as(usize, 6), text.utf16_owners.len);
    const indices = [_]u32{ 0, 1, 1, 2, 2, 2 };
    const columns = [_]u16{ 0, 1, 1, 3, 3, 3 };
    for (text.utf16_owners, indices, columns) |owner, index, col| {
        try std.testing.expectEqual(index, owner.cell_index);
        try std.testing.expectEqual(col, owner.col);
        try std.testing.expectEqual(@as(u2, if (index == 0) 1 else 2), owner.width);
    }
    var empty = try prepare(std.testing.allocator, &.{}, &.{});
    defer empty.deinit(std.testing.allocator);
    try std.testing.expect(empty.utf8.len == 0 and empty.utf16_owners.len == 0);
    var blank = try prepare(std.testing.allocator, &.{.{ .row = 0, .col = 5, .width = 0, .codepoint = 0, .grapheme_offset = 0xffffffff }}, &.{});
    defer blank.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(" ", blank.utf8);
    try std.testing.expectEqual(@as(u2, 1), blank.utf16_owners[0].width);
}

test "shaping run preflight rejects malformed scalar and pool ranges before allocation" {
    var no_memory = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const a = no_memory.allocator();
    for ([_]u21{ 0xd800, 0xdfff, 0x110000 }) |cp|
        try std.testing.expectError(error.InvalidCodepoint, prepare(a, &.{.{ .row = 0, .col = 0, .codepoint = cp }}, &.{}));
    try std.testing.expectError(error.InvalidCodepoint, prepare(a, &.{.{ .row = 0, .col = 0, .codepoint = 'A', .grapheme_count = 1 }}, &.{0xffffffff}));
    try std.testing.expectError(error.InvalidGraphemeRange, prepare(a, &.{.{ .row = 0, .col = 0, .codepoint = 'A', .grapheme_offset = 0xffffffff, .grapheme_count = 1 }}, &.{}));
    try std.testing.expectEqual(@as(usize, 0), no_memory.alloc_index);
    try std.testing.expect(!no_memory.has_induced_failure);
}

test "shaping run preflight rejects row gaps overlaps invalid widths and terminal edge overflow" {
    const first: draw.DrawCell = .{ .row = 0, .col = 0, .codepoint = 'A' };
    for ([_]draw.DrawCell{ .{ .row = 0, .col = 2, .codepoint = 'B' }, .{ .row = 1, .col = 1, .codepoint = 'B' }, first }) |second|
        try std.testing.expectError(error.DiscontinuousCells, prepare(std.testing.allocator, &.{ first, second }, &.{}));
    try std.testing.expectError(error.InvalidCell, prepare(std.testing.allocator, &.{.{ .row = 0, .col = 0, .width = 3, .codepoint = 'A' }}, &.{}));
    try std.testing.expectError(error.InvalidCell, prepare(std.testing.allocator, &.{.{ .row = 0, .col = 65534, .width = 2, .codepoint = 'A' }}, &.{}));
}

fn allocationProbe(a: std.mem.Allocator) !void {
    var text = try prepare(a, &.{.{ .row = 0, .col = 4, .codepoint = 0, .grapheme_count = 1 }}, &.{0x301});
    defer text.deinit(a);
    try std.testing.expectEqualStrings(" \u{301}", text.utf8);
    try std.testing.expectEqual(@as(usize, 2), text.utf16_owners.len);
}

test "shaping run exact buffer ownership survives every allocation failure prefix" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
}
