const std = @import("std");

pub const encoded_key_buffer_len = 8;

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

pub fn encodeKey(event: KeyEvent, buffer: *[encoded_key_buffer_len]u8) ![]const u8 {
    // Key encoding is separate from TerminalCore because input policy changes
    // for modifiers, application cursor mode, and platform shortcuts should not
    // force storage or parser files to change.
    var len: usize = 0;
    if (event.modifiers.option) {
        // macOS Option/Alt is the traditional terminal "Meta" modifier. The
        // terminal byte stream represents Meta by prefixing the normal key bytes
        // with ESC, which lets shells/readline see Alt+B without Maru inventing
        // a platform-specific control path.
        buffer[len] = 0x1b;
        len += 1;
    }

    return switch (event.key) {
        .char => |codepoint| blk: {
            if (event.modifiers.control) {
                buffer[len] = try controlByte(codepoint);
                len += 1;
                break :blk buffer[0..len];
            }

            var encoded: [4]u8 = undefined;
            const encoded_len = try std.unicode.utf8Encode(codepoint, &encoded);
            @memcpy(buffer[len..][0..encoded_len], encoded[0..encoded_len]);
            len += encoded_len;
            break :blk buffer[0..len];
        },
        .enter => appendBytes(buffer, &len, "\r"),
        .escape => appendBytes(buffer, &len, "\x1b"),
        .tab => appendBytes(buffer, &len, "\t"),
        .backspace => appendBytes(buffer, &len, "\x7f"),
        .arrow_up => appendBytes(buffer, &len, "\x1b[A"),
        .arrow_down => appendBytes(buffer, &len, "\x1b[B"),
        .arrow_right => appendBytes(buffer, &len, "\x1b[C"),
        .arrow_left => appendBytes(buffer, &len, "\x1b[D"),
    };
}

pub fn controlByte(codepoint: u21) !u8 {
    // Ctrl+letter maps to ASCII C0 controls: Ctrl+A=0x01 ... Ctrl+Z=0x1a.
    // Keeping this as a small helper lets keybinding macros reuse the exact
    // terminal contract instead of copying arithmetic in app/config code.
    if (codepoint >= 'a' and codepoint <= 'z') return @intCast(codepoint - 'a' + 1);
    if (codepoint >= 'A' and codepoint <= 'Z') return @intCast(codepoint - 'A' + 1);
    return error.InvalidControlKey;
}

fn appendBytes(buffer: *[encoded_key_buffer_len]u8, len: *usize, bytes: []const u8) []const u8 {
    @memcpy(buffer[len.*..][0..bytes.len], bytes);
    len.* += bytes.len;
    return buffer[0..len.*];
}

test "encodes basic control keys" {
    var buffer: [encoded_key_buffer_len]u8 = undefined;

    try std.testing.expectEqualStrings("\r", try encodeKey(.{ .key = .enter }, &buffer));
    try std.testing.expectEqualStrings("\x1b[A", try encodeKey(.{ .key = .arrow_up }, &buffer));
    try std.testing.expectEqualStrings("\x7f", try encodeKey(.{ .key = .backspace }, &buffer));
}

test "encodes character keys as UTF-8" {
    var buffer: [encoded_key_buffer_len]u8 = undefined;

    try std.testing.expectEqualStrings("a", try encodeKey(.{ .key = .{ .char = 'a' } }, &buffer));
    try std.testing.expectEqualStrings("한", try encodeKey(.{ .key = .{ .char = '한' } }, &buffer));
}

test "encodes control letters and option-prefixed terminal input" {
    var buffer: [encoded_key_buffer_len]u8 = undefined;

    try std.testing.expectEqualStrings(
        "\x02",
        try encodeKey(.{ .key = .{ .char = 'b' }, .modifiers = .{ .control = true } }, &buffer),
    );
    try std.testing.expectEqualStrings(
        "\x02",
        try encodeKey(.{ .key = .{ .char = 'B' }, .modifiers = .{ .control = true, .shift = true } }, &buffer),
    );
    try std.testing.expectEqualStrings(
        "\x1bb",
        try encodeKey(.{ .key = .{ .char = 'b' }, .modifiers = .{ .option = true } }, &buffer),
    );
    try std.testing.expectEqualStrings(
        "\x1b한",
        try encodeKey(.{ .key = .{ .char = '한' }, .modifiers = .{ .option = true } }, &buffer),
    );
}
