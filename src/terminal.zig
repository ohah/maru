const std = @import("std");

pub const Size = struct {
    cols: u16,
    rows: u16,

    pub const default: Size = .{ .cols = 80, .rows = 24 };
};

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const Color = union(enum) {
    default,
    indexed: u8,
    rgb: Rgb,
};

pub const Style = struct {
    foreground: Color = .default,
    background: Color = .default,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
};

pub const Cell = struct {
    codepoint: u21 = ' ',
    style: Style = .{},
};

pub const Cursor = struct {
    row: u16 = 0,
    col: u16 = 0,
    visible: bool = true,
};

pub const DirtyRegion = struct {
    start_row: u16 = 0,
    end_row: u16 = 0,
};

pub const RenderSnapshot = struct {
    size: Size,
    cursor: Cursor = .{},
    cells: []const Cell = &.{},
    dirty: DirtyRegion = .{},
};

pub const ModifierSet = packed struct {
    shift: bool = false,
    control: bool = false,
    option: bool = false,
    command: bool = false,
};

pub const Key = union(enum) {
    char: u21,
    enter,
    escape,
    tab,
    backspace,
    arrow_up,
    arrow_down,
    arrow_left,
    arrow_right,
};

pub const KeyEvent = struct {
    key: Key,
    modifiers: ModifierSet = .{},
};

pub const TerminalCore = struct {
    size: Size,

    pub fn init(size: Size) TerminalCore {
        return .{ .size = size };
    }

    pub fn write(self: *TerminalCore, bytes: []const u8) void {
        _ = self;
        _ = bytes;
    }

    pub fn resize(self: *TerminalCore, cols: u16, rows: u16) void {
        self.size = .{ .cols = cols, .rows = rows };
    }

    pub fn snapshot(self: *const TerminalCore) RenderSnapshot {
        return .{ .size = self.size };
    }

    pub fn encodeKey(self: *const TerminalCore, event: KeyEvent, buffer: *[4]u8) ![]const u8 {
        _ = self;
        return switch (event.key) {
            .char => |codepoint| blk: {
                const len = try std.unicode.utf8Encode(codepoint, buffer);
                break :blk buffer[0..len];
            },
            .enter => "\r",
            .escape => "\x1b",
            .tab => "\t",
            .backspace => "\x7f",
            .arrow_up => "\x1b[A",
            .arrow_down => "\x1b[B",
            .arrow_right => "\x1b[C",
            .arrow_left => "\x1b[D",
        };
    }
};

test "terminal core stores size and resizes" {
    var core = TerminalCore.init(.{ .cols = 100, .rows = 30 });
    try std.testing.expectEqual(@as(u16, 100), core.snapshot().size.cols);

    core.resize(120, 40);
    const snapshot = core.snapshot();
    try std.testing.expectEqual(@as(u16, 120), snapshot.size.cols);
    try std.testing.expectEqual(@as(u16, 40), snapshot.size.rows);
}

test "terminal core encodes basic control keys" {
    const core = TerminalCore.init(Size.default);
    var buffer: [4]u8 = undefined;

    try std.testing.expectEqualStrings("\r", try core.encodeKey(.{ .key = .enter }, &buffer));
    try std.testing.expectEqualStrings("\x1b[A", try core.encodeKey(.{ .key = .arrow_up }, &buffer));
    try std.testing.expectEqualStrings("\x7f", try core.encodeKey(.{ .key = .backspace }, &buffer));
}

test "terminal core encodes character keys as UTF-8" {
    const core = TerminalCore.init(Size.default);
    var buffer: [4]u8 = undefined;

    try std.testing.expectEqualStrings("a", try core.encodeKey(.{ .key = .{ .char = 'a' } }, &buffer));
    try std.testing.expectEqualStrings("한", try core.encodeKey(.{ .key = .{ .char = '한' } }, &buffer));
}
