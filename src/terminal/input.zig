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

pub const CodepointError = error{
    CodepointOutOfRange,
    CodepointIsSurrogate,
};

/// AppKit/ABI key event가 준 raw codepoint를 char Key로 바꾼다. 유효한 Unicode scalar가
/// 아닌 값(U+10FFFF 초과, lone surrogate 0xd800..0xdfff)은 여기서 거부한다. 그대로 두면
/// 나중에 encodeKey -> utf8Encode에서 덜 명확한 오류로 터지기 때문에 platform/ABI 경계에서
/// 막는 게 낫다. native keyDown smoke와 Swift app host ABI가 같은 변환을 공유한다.
pub fn charKeyFromCodepoint(codepoint: u32) CodepointError!Key {
    if (codepoint > 0x10ffff) return error.CodepointOutOfRange;
    if (codepoint >= 0xd800 and codepoint <= 0xdfff) return error.CodepointIsSurrogate;
    return .{ .char = @intCast(codepoint) };
}

/// 프로그램이 정한 입력 모드 중 인코딩에 영향을 주는 것들. TerminalCore가 DECSET/DECRST로 추적하고
/// (DECCKM `CSI ?1h/l`), 인코딩 시점에 호출자가 active surface의 현재 값을 넘긴다 — 인코더가
/// 터미널 상태를 직접 들고 있지 않게 분리한다.
pub const EncodeOptions = struct {
    /// DECCKM(application cursor keys). vim/less가 켜면 화살표가 CSI(`\x1b[A`) 대신 SS3(`\x1bOA`)로
    /// 인코딩된다. 끄면(normal) CSI 형식.
    application_cursor_keys: bool = false,
};

pub fn encodeKey(event: KeyEvent, buffer: *[encoded_key_buffer_len]u8, options: EncodeOptions) ![]const u8 {
    // Key encoding is separate from TerminalCore because input policy changes
    // for modifiers, application cursor mode, and platform shortcuts should not
    // force storage or parser files to change.
    var len: usize = 0;
    if (event.modifiers.option and !keyBaseStartsWithEscape(event.key)) {
        // macOS Option/Alt is the traditional terminal "Meta" modifier. The
        // terminal byte stream represents Meta by prefixing the normal key bytes
        // with ESC, which lets shells/readline see Alt+B without Maru inventing
        // a platform-specific control path. Keys whose base encoding is itself an
        // ESC-introduced sequence (arrows, escape) are excluded: prefixing ESC
        // would produce a double-ESC like \x1b\x1b[A that no terminal recognizes.
        // Modifier encoding for those keys (CSI parameters) is a later contract.
        buffer[len] = 0x1b;
        len += 1;
    }

    return switch (event.key) {
        .char => |codepoint| blk: {
            if (event.modifiers.control) {
                // Ctrl+<key> maps to a C0 control byte when the key has one. Keys
                // with no C0 mapping (digits, most punctuation) fall back to the
                // plain character so an unbound Ctrl+1 types "1" instead of
                // erroring the whole key event.
                if (controlByte(codepoint)) |byte| {
                    buffer[len] = byte;
                    len += 1;
                    break :blk buffer[0..len];
                } else |_| {}
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
        // DECCKM이 켜지면(vim/less) 화살표는 SS3(`ESC O`) 형식, 아니면 CSI(`ESC [`) 형식이다.
        .arrow_up => appendBytes(buffer, &len, if (options.application_cursor_keys) "\x1bOA" else "\x1b[A"),
        .arrow_down => appendBytes(buffer, &len, if (options.application_cursor_keys) "\x1bOB" else "\x1b[B"),
        .arrow_right => appendBytes(buffer, &len, if (options.application_cursor_keys) "\x1bOC" else "\x1b[C"),
        .arrow_left => appendBytes(buffer, &len, if (options.application_cursor_keys) "\x1bOD" else "\x1b[D"),
    };
}

pub fn controlByte(codepoint: u21) !u8 {
    // Ctrl maps an ASCII key to its C0 control byte by clearing the upper bits
    // (codepoint & 0x1f over the 0x40-0x5f range). This is the full terminal
    // contract, not just letters:
    //   Ctrl+@ = 0x00, Ctrl+A..Z = 0x01..0x1a, Ctrl+[ = 0x1b (ESC),
    //   Ctrl+\ = 0x1c, Ctrl+] = 0x1d, Ctrl+^ = 0x1e, Ctrl+_ = 0x1f.
    // Lowercase letters fold to uppercase first so Ctrl+b == Ctrl+B. Ctrl+Space
    // (NUL) and Ctrl+? (DEL) are the two well-known controls outside 0x40-0x5f.
    // Keeping the complete table here lets keybinding macros reuse the exact
    // terminal contract instead of copying arithmetic in app/config code.
    if (codepoint >= 'a' and codepoint <= 'z') return @intCast(codepoint - 'a' + 1);
    if (codepoint >= '@' and codepoint <= '_') return @intCast(codepoint - '@');
    if (codepoint == ' ') return 0x00;
    if (codepoint == '?') return 0x7f;
    return error.InvalidControlKey;
}

fn keyBaseStartsWithEscape(key: Key) bool {
    return switch (key) {
        .escape, .arrow_up, .arrow_down, .arrow_left, .arrow_right => true,
        else => false,
    };
}

fn appendBytes(buffer: *[encoded_key_buffer_len]u8, len: *usize, bytes: []const u8) []const u8 {
    @memcpy(buffer[len.*..][0..bytes.len], bytes);
    len.* += bytes.len;
    return buffer[0..len.*];
}

test "encodes basic control keys" {
    var buffer: [encoded_key_buffer_len]u8 = undefined;

    try std.testing.expectEqualStrings("\r", try encodeKey(.{ .key = .enter }, &buffer, .{}));
    try std.testing.expectEqualStrings("\x1b[A", try encodeKey(.{ .key = .arrow_up }, &buffer, .{}));
    try std.testing.expectEqualStrings("\x7f", try encodeKey(.{ .key = .backspace }, &buffer, .{}));
}

test "encodes character keys as UTF-8" {
    var buffer: [encoded_key_buffer_len]u8 = undefined;

    try std.testing.expectEqualStrings("a", try encodeKey(.{ .key = .{ .char = 'a' } }, &buffer, .{}));
    try std.testing.expectEqualStrings("한", try encodeKey(.{ .key = .{ .char = '한' } }, &buffer, .{}));
}

test "encodes control letters and option-prefixed terminal input" {
    var buffer: [encoded_key_buffer_len]u8 = undefined;

    try std.testing.expectEqualStrings(
        "\x02",
        try encodeKey(.{ .key = .{ .char = 'b' }, .modifiers = .{ .control = true } }, &buffer, .{}),
    );
    try std.testing.expectEqualStrings(
        "\x02",
        try encodeKey(.{ .key = .{ .char = 'B' }, .modifiers = .{ .control = true, .shift = true } }, &buffer, .{}),
    );
    try std.testing.expectEqualStrings(
        "\x1bb",
        try encodeKey(.{ .key = .{ .char = 'b' }, .modifiers = .{ .option = true } }, &buffer, .{}),
    );
    try std.testing.expectEqualStrings(
        "\x1b한",
        try encodeKey(.{ .key = .{ .char = '한' }, .modifiers = .{ .option = true } }, &buffer, .{}),
    );
}

test "charKeyFromCodepoint rejects non-scalar codepoints" {
    try std.testing.expectEqual(Key{ .char = 'b' }, try charKeyFromCodepoint('b'));
    try std.testing.expectEqual(Key{ .char = 0x10ffff }, try charKeyFromCodepoint(0x10ffff));
    try std.testing.expectError(error.CodepointOutOfRange, charKeyFromCodepoint(0x110000));
    try std.testing.expectError(error.CodepointIsSurrogate, charKeyFromCodepoint(0xd800));
    try std.testing.expectError(error.CodepointIsSurrogate, charKeyFromCodepoint(0xdfff));
}

test "controlByte covers the full C0 table, not just letters" {
    try std.testing.expectEqual(@as(u8, 0x00), try controlByte('@'));
    try std.testing.expectEqual(@as(u8, 0x01), try controlByte('A'));
    try std.testing.expectEqual(@as(u8, 0x1a), try controlByte('Z'));
    try std.testing.expectEqual(@as(u8, 0x1b), try controlByte('[')); // Ctrl+[ == ESC
    try std.testing.expectEqual(@as(u8, 0x1c), try controlByte('\\'));
    try std.testing.expectEqual(@as(u8, 0x1d), try controlByte(']'));
    try std.testing.expectEqual(@as(u8, 0x1e), try controlByte('^'));
    try std.testing.expectEqual(@as(u8, 0x1f), try controlByte('_'));
    try std.testing.expectEqual(@as(u8, 0x00), try controlByte(' ')); // Ctrl+Space == NUL
    try std.testing.expectEqual(@as(u8, 0x7f), try controlByte('?')); // Ctrl+? == DEL
    try std.testing.expectEqual(@as(u8, 0x02), try controlByte('b')); // lowercase folds to upper
    try std.testing.expectError(error.InvalidControlKey, controlByte('1'));
}

test "encodes Ctrl+[ and Ctrl+Space as their C0 bytes" {
    var buffer: [encoded_key_buffer_len]u8 = undefined;
    try std.testing.expectEqualStrings(
        "\x1b",
        try encodeKey(.{ .key = .{ .char = '[' }, .modifiers = .{ .control = true } }, &buffer, .{}),
    );
    try std.testing.expectEqualStrings(
        "\x00",
        try encodeKey(.{ .key = .{ .char = ' ' }, .modifiers = .{ .control = true } }, &buffer, .{}),
    );
}

test "Ctrl with an unmapped key falls back to the plain character" {
    var buffer: [encoded_key_buffer_len]u8 = undefined;
    // Ctrl+1 has no C0 control byte; encode the digit rather than erroring the
    // whole key event.
    try std.testing.expectEqualStrings(
        "1",
        try encodeKey(.{ .key = .{ .char = '1' }, .modifiers = .{ .control = true } }, &buffer, .{}),
    );
}

test "option modifier does not double-escape ESC-introduced keys" {
    var buffer: [encoded_key_buffer_len]u8 = undefined;
    // Arrows/escape already begin with ESC; the Meta prefix must not turn
    // Option+Up into \x1b\x1b[A.
    try std.testing.expectEqualStrings(
        "\x1b[A",
        try encodeKey(.{ .key = .arrow_up, .modifiers = .{ .option = true } }, &buffer, .{}),
    );
    try std.testing.expectEqualStrings(
        "\x1b",
        try encodeKey(.{ .key = .escape, .modifiers = .{ .option = true } }, &buffer, .{}),
    );
    // Plain-byte keys still get the Meta ESC prefix.
    try std.testing.expectEqualStrings(
        "\x1b\r",
        try encodeKey(.{ .key = .enter, .modifiers = .{ .option = true } }, &buffer, .{}),
    );
}

test "DECCKM (application cursor keys) switches arrows from CSI to SS3" {
    var buffer: [encoded_key_buffer_len]u8 = undefined;
    const app: EncodeOptions = .{ .application_cursor_keys = true };
    try std.testing.expectEqualStrings("\x1bOA", try encodeKey(.{ .key = .arrow_up }, &buffer, app));
    try std.testing.expectEqualStrings("\x1bOB", try encodeKey(.{ .key = .arrow_down }, &buffer, app));
    try std.testing.expectEqualStrings("\x1bOC", try encodeKey(.{ .key = .arrow_right }, &buffer, app));
    try std.testing.expectEqualStrings("\x1bOD", try encodeKey(.{ .key = .arrow_left }, &buffer, app));
    // 비-화살표 키는 모드와 무관하다.
    try std.testing.expectEqualStrings("\r", try encodeKey(.{ .key = .enter }, &buffer, app));
}
