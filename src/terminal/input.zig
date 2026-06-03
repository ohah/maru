const std = @import("std");

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

pub fn encodeKey(event: KeyEvent, buffer: *[4]u8) ![]const u8 {
    // Key encoding is separate from TerminalCore because input policy changes
    // for modifiers, application cursor mode, and platform shortcuts should not
    // force storage or parser files to change.
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

test "encodes basic control keys" {
    var buffer: [4]u8 = undefined;

    try std.testing.expectEqualStrings("\r", try encodeKey(.{ .key = .enter }, &buffer));
    try std.testing.expectEqualStrings("\x1b[A", try encodeKey(.{ .key = .arrow_up }, &buffer));
    try std.testing.expectEqualStrings("\x7f", try encodeKey(.{ .key = .backspace }, &buffer));
}

test "encodes character keys as UTF-8" {
    var buffer: [4]u8 = undefined;

    try std.testing.expectEqualStrings("a", try encodeKey(.{ .key = .{ .char = 'a' } }, &buffer));
    try std.testing.expectEqualStrings("한", try encodeKey(.{ .key = .{ .char = '한' } }, &buffer));
}
