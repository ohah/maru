//! Map native UTF-16 cluster coverage onto an already prepared terminal run.
//! Every UTF-16 unit of one grapheme carries the same cell identity. In
//! particular, a surrogate pair or a fallback run inside a grapheme must not
//! acquire an extra terminal column merely because it uses more text units.
const std = @import("std");
const Source = @import("glyph_sources.zig").Source;

pub const Cell = struct { col: u16, width: u2 };
pub const Span = struct { col: u16, width: u16 };
pub const Error = error{ UnknownSource, InvalidTextRange, InvalidCells };

pub fn span(units: []const Cell, source: Source) Error!Span {
    return spanOwners(units, source);
}

/// Borrow the shared prepared text's richer owners directly. Only column and
/// width are used here; keeping this projection allocation-free avoids a second
/// UTF-16 ownership buffer drifting from the native shaper's input.
pub fn spanOwners(units: anytype, source: Source) Error!Span {
    if (!source.known) return error.UnknownSource;
    const start: usize = source.utf16_start;
    const length: usize = source.utf16_length;
    // Subtract after checking start: native inputs must never wrap an end index.
    if (length == 0 or start > units.len or length > units.len - start)
        return error.InvalidTextRange;
    const covered = units[start..][0..length];
    const first = covered[0];
    var previous = first;
    for (covered) |cell| {
        if (cell.width == 0 or cell.width > 2 or
            @as(u32, cell.col) + cell.width > std.math.maxInt(u16))
            return error.InvalidCells;
        if (cell.col == previous.col) {
            if (cell.width != previous.width) return error.InvalidCells;
        } else if (@as(u32, previous.col) + previous.width != cell.col) {
            // A shaped run cannot cross an omitted cell, overlap or go backward.
            // RTL changes glyph order, not the logical UTF-16 unit ownership.
            return error.InvalidCells;
        }
        previous = cell;
    }
    return .{ .col = first.col, .width = @intCast(@as(u32, previous.col) + previous.width - first.col) };
}

fn fixtureSource(start: u32, length: u32) Source {
    return .{ .known = true, .utf16_start = start, .utf16_length = length };
}

test "Windows glyph sources cell coverage counts merged glyphs in cells not UTF16 units" {
    const units = [_]Cell{ .{ .col = 7, .width = 1 }, .{ .col = 8, .width = 1 }, .{ .col = 9, .width = 1 } };
    try std.testing.expectEqual(Span{ .col = 7, .width = 3 }, try span(&units, fixtureSource(0, 3)));
    try std.testing.expectEqual(Span{ .col = 8, .width = 1 }, try span(&units, fixtureSource(1, 1)));
}

test "Windows glyph sources cell coverage preserves surrogate and NFD ownership" {
    const units = [_]Cell{ .{ .col = 4, .width = 2 }, .{ .col = 4, .width = 2 }, .{ .col = 6, .width = 2 }, .{ .col = 6, .width = 2 }, .{ .col = 6, .width = 2 } };
    try std.testing.expectEqual(Span{ .col = 4, .width = 4 }, try span(&units, fixtureSource(0, 5)));
    // Native fallback can split one grapheme without changing its cell identity.
    try std.testing.expectEqual(Span{ .col = 6, .width = 2 }, try span(&units, fixtureSource(3, 2)));
}

test "Windows glyph sources cell coverage follows reversed native glyph order" {
    const units = [_]Cell{ .{ .col = 20, .width = 1 }, .{ .col = 21, .width = 1 }, .{ .col = 22, .width = 1 } };
    var sources: [4]Source = @splat(.{});
    try @import("glyph_sources.zig").assign(&.{ 2, 0, 0 }, 4, 0, &sources);
    for (sources[0..2]) |item| try std.testing.expectEqual(Span{ .col = 21, .width = 2 }, try span(&units, item));
    for (sources[2..]) |item| try std.testing.expectEqual(Span{ .col = 20, .width = 1 }, try span(&units, item));
}

test "Windows glyph sources cell coverage rejects absent empty and overflowing text ranges" {
    const units = [_]Cell{.{ .col = 0, .width = 1 }};
    try std.testing.expectError(error.UnknownSource, span(&units, .{}));
    for ([_]Source{ fixtureSource(0, 0), fixtureSource(1, 1), fixtureSource(2, 1), fixtureSource(0, 2), fixtureSource(std.math.maxInt(u32), 2), fixtureSource(0, std.math.maxInt(u32)) }) |item|
        try std.testing.expectError(error.InvalidTextRange, span(&units, item));
    try std.testing.expectError(error.InvalidTextRange, span(&.{}, fixtureSource(0, 1)));
}

test "Windows glyph sources cell coverage rejects gaps overlaps backward and inconsistent units" {
    const bad = [_][2]Cell{
        .{ .{ .col = 4, .width = 1 }, .{ .col = 6, .width = 1 } },
        .{ .{ .col = 4, .width = 2 }, .{ .col = 5, .width = 1 } },
        .{ .{ .col = 4, .width = 1 }, .{ .col = 3, .width = 1 } },
        .{ .{ .col = 4, .width = 1 }, .{ .col = 4, .width = 2 } },
        .{ .{ .col = 4, .width = 0 }, .{ .col = 4, .width = 0 } },
        .{ .{ .col = 4, .width = 3 }, .{ .col = 7, .width = 1 } },
    };
    for (bad) |units| try std.testing.expectError(error.InvalidCells, span(&units, fixtureSource(0, 2)));
}

test "Windows glyph sources cell coverage validates terminal edge without narrowing overflow" {
    try std.testing.expectEqual(Span{ .col = 65533, .width = 2 }, try span(&.{.{ .col = 65533, .width = 2 }}, fixtureSource(0, 1)));
    try std.testing.expectError(error.InvalidCells, span(&.{.{ .col = 65534, .width = 2 }}, fixtureSource(0, 1)));
    try std.testing.expectError(error.InvalidCells, span(&.{.{ .col = 65535, .width = 1 }}, fixtureSource(0, 1)));
}
