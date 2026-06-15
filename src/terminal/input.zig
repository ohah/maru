const std = @import("std");

// legacy 최대는 "\x1b[24~"(5B)지만 kitty CSI u는 functional code(최대 5자리)+modifier로 더 길다
// (예: "\x1b[57427;16u" = 11B). 가장 긴 kitty 시퀀스도 담기게 여유를 둔다.
pub const encoded_key_buffer_len = 32;

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
    // PC-style 기능키(xterm legacy 인코딩). cursor 계열(home/end)은 화살표처럼 DECCKM 적용,
    // 편집 계열(insert/delete/page_up/page_down)은 CSI ~ 형식, function은 F1~F12.
    home,
    end,
    insert,
    delete,
    page_up,
    page_down,
    function: u8, // F1..F12 (1-indexed)
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
    /// kitty keyboard protocol flag(스택 최상단의 5비트, core.KittyFlags.int()). 0이면 legacy 인코딩,
    /// 0이 아니면 encodeKey가 kitty CSI u 인코딩으로 분기한다. 순환 import를 피해 u5(int)로 받는다.
    kitty_flags: u5 = 0,
};

pub fn encodeKey(event: KeyEvent, buffer: *[encoded_key_buffer_len]u8, options: EncodeOptions) ![]const u8 {
    // Key encoding is separate from TerminalCore because input policy changes
    // for modifiers, application cursor mode, and platform shortcuts should not
    // force storage or parser files to change.

    // kitty keyboard protocol이 켜져 있으면(flag 스택 최상단 != 0) CSI u 인코딩으로 분기한다. 앱이
    // CSI > flags u로 켰을 때만 — 안 켜면 아래 legacy 그대로라 progressive enhancement(legacy 공존).
    if (options.kitty_flags != 0) return encodeKitty(event, buffer, options);

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
        // home/end는 화살표와 같은 cursor key라 DECCKM(application cursor) 적용 — vim/less가
        // application 모드에서 SS3 형식을 기대한다.
        .home => appendBytes(buffer, &len, if (options.application_cursor_keys) "\x1bOH" else "\x1b[H"),
        .end => appendBytes(buffer, &len, if (options.application_cursor_keys) "\x1bOF" else "\x1b[F"),
        // 편집키는 CSI ~ 형식(모드 무관). PC-style xterm 표준.
        .insert => appendBytes(buffer, &len, "\x1b[2~"),
        .delete => appendBytes(buffer, &len, "\x1b[3~"),
        .page_up => appendBytes(buffer, &len, "\x1b[5~"),
        .page_down => appendBytes(buffer, &len, "\x1b[6~"),
        .function => |n| appendBytes(buffer, &len, try functionKeySequence(n)),
    };
}

/// kitty keyboard 인코딩(progressive enhancement). encodeKey가 kitty_flags!=0일 때 분기한다.
/// 베이스: kitty keyboard protocol spec + Ghostty input/key_encode.zig kitty(). 현재 disambiguate
/// 수준만 — report_events/alternates/associated(release/대체키/연관텍스트)는 후속이다(Maru는 press만
/// 전달하고, base codepoint는 Swift charactersIgnoringModifiers라 Ctrl+Shift+printable의 alternate는
/// 한계가 있다). escape·functional·modifier 조합은 CSI 시퀀스로, modifier 없는 텍스트/enter/tab/
/// backspace는 legacy 바이트를 그대로 둔다(kitty spec의 명시 예외 — 모드가 안 꺼져도 shell 복구 가능).
fn encodeKitty(event: KeyEvent, buffer: *[encoded_key_buffer_len]u8, options: EncodeOptions) ![]const u8 {
    _ = options; // 현재 분기는 flags!=0(켜짐)만 보고 disambiguate로 인코딩 — 세부 flag는 후속
    const has_ctrl_alt = event.modifiers.control or event.modifiers.option or event.modifiers.command;
    const has_any_mod = has_ctrl_alt or event.modifiers.shift;

    switch (event.key) {
        // kitty spec: Enter/Tab/Backspace는 modifier가 "전혀" 없을 때만 legacy 바이트(\r/\t/\x7f)를
        // 보낸다(모드가 안 꺼진 채 죽어도 shell에서 reset 입력 가능). shift 포함 어떤 modifier든 있으면
        // CSI u로 — Shift+Tab=CSI 9;2u(backtab) 등. Ghostty binding_mods.empty()가 shift까지 포함해
        // 거르는 것(key_mods.zig binding())과 동형.
        .enter => if (!has_any_mod) return "\r",
        .tab => if (!has_any_mod) return "\t",
        .backspace => if (!has_any_mod) return "\x7f",
        // char는 shift가 codepoint(Swift charactersIgnoringModifiers)에 이미 반영되므로 ctrl/alt/cmd만
        // 본다 — Shift+A는 'A' 텍스트 그대로, Ctrl+a만 CSI 97;5u로.
        .char => |cp| if (!has_ctrl_alt) {
            const n = try std.unicode.utf8Encode(cp, buffer[0..4]);
            return buffer[0..n];
        },
        else => {}, // escape·functional은 아래 CSI 시퀀스로(disambiguate)
    }

    const ent = kittyEntry(event.key);
    const mods = kittyModsSeqInt(event.modifiers);
    return encodeKittySeq(buffer, ent.code, ent.final, mods);
}

const KittyEntry = struct { code: u21, final: u8 };

/// Maru Key → kitty (code, final). 베이스: kitty keyboard protocol functional-key 정의 + Ghostty
/// input/kitty.zig 테이블. final 'u'/'~'는 CSI code[;mods]final, letter(A/B/C/D/H/F/P/Q/S)는 legacy
/// 호환 CSI[1;mods]final 형식이다.
fn kittyEntry(key: Key) KittyEntry {
    return switch (key) {
        .char => |cp| .{ .code = cp, .final = 'u' },
        .escape => .{ .code = 27, .final = 'u' },
        .enter => .{ .code = 13, .final = 'u' },
        .tab => .{ .code = 9, .final = 'u' },
        .backspace => .{ .code = 127, .final = 'u' },
        .insert => .{ .code = 2, .final = '~' },
        .delete => .{ .code = 3, .final = '~' },
        .arrow_left => .{ .code = 1, .final = 'D' },
        .arrow_right => .{ .code = 1, .final = 'C' },
        .arrow_up => .{ .code = 1, .final = 'A' },
        .arrow_down => .{ .code = 1, .final = 'B' },
        .home => .{ .code = 1, .final = 'H' },
        .end => .{ .code = 1, .final = 'F' },
        .page_up => .{ .code = 5, .final = '~' },
        .page_down => .{ .code = 6, .final = '~' },
        .function => |n| switch (n) {
            1 => .{ .code = 1, .final = 'P' },
            2 => .{ .code = 1, .final = 'Q' },
            3 => .{ .code = 13, .final = '~' },
            4 => .{ .code = 1, .final = 'S' },
            5 => .{ .code = 15, .final = '~' },
            6 => .{ .code = 17, .final = '~' },
            7 => .{ .code = 18, .final = '~' },
            8 => .{ .code = 19, .final = '~' },
            9 => .{ .code = 20, .final = '~' },
            10 => .{ .code = 21, .final = '~' },
            11 => .{ .code = 23, .final = '~' },
            else => .{ .code = 24, .final = '~' }, // F12(범위 밖은 encodeKey 진입 전 functionKeySequence가 거름)
        },
    };
}

/// kitty modifier 인코딩값 = 1 + bitmask(shift=1, alt=2, ctrl=4, super=8). 베이스: kitty keyboard
/// protocol modifier 표. modifier가 없으면 1(시퀀스에서 생략된다).
fn kittyModsSeqInt(mods: ModifierSet) u16 {
    var v: u16 = 0;
    if (mods.shift) v |= 1;
    if (mods.option) v |= 2;
    if (mods.control) v |= 4;
    if (mods.command) v |= 8;
    return v + 1;
}

/// KittySequence.encode(Ghostty) 동형: final 'u'/'~'는 CSI code[;mods]final, letter는 CSI[1;mods]final
/// (code=1 생략). mods<=1이면 modifier param을 생략한다(legacy CSI A/B/C/D/H/F와 호환).
fn encodeKittySeq(buffer: *[encoded_key_buffer_len]u8, code: u21, final: u8, mods: u16) ![]const u8 {
    if (final == 'u' or final == '~') {
        if (mods > 1) return std.fmt.bufPrint(buffer, "\x1b[{d};{d}{c}", .{ code, mods, final });
        return std.fmt.bufPrint(buffer, "\x1b[{d}{c}", .{ code, final });
    }
    if (mods > 1) return std.fmt.bufPrint(buffer, "\x1b[1;{d}{c}", .{ mods, final });
    return std.fmt.bufPrint(buffer, "\x1b[{c}", .{final});
}

/// F1~F12의 xterm legacy 시퀀스. F1~F4는 SS3(`ESC O P..S`), F5~F12는 CSI ~ 형식(15/17~21/23/24 —
/// 16·22가 빠진 건 역사적 xterm 표다). 물리 Mac 키보드는 F1~F12라 그 범위만 인코딩하고, 범위 밖
/// (F13+)은 표준이 갈려 거부한다(Ghostty도 f13+는 todo).
fn functionKeySequence(n: u8) ![]const u8 {
    return switch (n) {
        1 => "\x1bOP",
        2 => "\x1bOQ",
        3 => "\x1bOR",
        4 => "\x1bOS",
        5 => "\x1b[15~",
        6 => "\x1b[17~",
        7 => "\x1b[18~",
        8 => "\x1b[19~",
        9 => "\x1b[20~",
        10 => "\x1b[21~",
        11 => "\x1b[23~",
        12 => "\x1b[24~",
        else => error.UnsupportedFunctionKey,
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
        // base 인코딩이 ESC로 시작하는 키들. Option(Meta)이 눌려도 ESC를 한 번 더 붙이지 않는다
        // (안 그러면 \x1b\x1b[3~ 같은 이중 ESC가 된다). modifier 조합 인코딩(CSI 파라미터)은 후속.
        .escape,
        .arrow_up,
        .arrow_down,
        .arrow_left,
        .arrow_right,
        .home,
        .end,
        .insert,
        .delete,
        .page_up,
        .page_down,
        .function,
        => true,
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

test "encodeKey: PC-style function keys (legacy xterm sequences)" {
    var buf: [encoded_key_buffer_len]u8 = undefined;
    const normal: EncodeOptions = .{};
    const app: EncodeOptions = .{ .application_cursor_keys = true };
    // 편집키(모드 무관)
    try std.testing.expectEqualStrings("\x1b[2~", try encodeKey(.{ .key = .insert }, &buf, normal));
    try std.testing.expectEqualStrings("\x1b[3~", try encodeKey(.{ .key = .delete }, &buf, normal));
    try std.testing.expectEqualStrings("\x1b[5~", try encodeKey(.{ .key = .page_up }, &buf, normal));
    try std.testing.expectEqualStrings("\x1b[6~", try encodeKey(.{ .key = .page_down }, &buf, normal));
    // home/end는 cursor key라 DECCKM
    try std.testing.expectEqualStrings("\x1b[H", try encodeKey(.{ .key = .home }, &buf, normal));
    try std.testing.expectEqualStrings("\x1bOH", try encodeKey(.{ .key = .home }, &buf, app));
    try std.testing.expectEqualStrings("\x1b[F", try encodeKey(.{ .key = .end }, &buf, normal));
    try std.testing.expectEqualStrings("\x1bOF", try encodeKey(.{ .key = .end }, &buf, app));
    // function keys
    try std.testing.expectEqualStrings("\x1bOP", try encodeKey(.{ .key = .{ .function = 1 } }, &buf, normal));
    try std.testing.expectEqualStrings("\x1bOS", try encodeKey(.{ .key = .{ .function = 4 } }, &buf, normal));
    try std.testing.expectEqualStrings("\x1b[15~", try encodeKey(.{ .key = .{ .function = 5 } }, &buf, normal));
    try std.testing.expectEqualStrings("\x1b[24~", try encodeKey(.{ .key = .{ .function = 12 } }, &buf, normal));
    try std.testing.expectError(error.UnsupportedFunctionKey, encodeKey(.{ .key = .{ .function = 13 } }, &buf, normal));
}

test "encodeKey: Option does not double-ESC function keys" {
    var buf: [encoded_key_buffer_len]u8 = undefined;
    // base가 ESC로 시작하므로 Option(Meta)이 눌려도 ESC를 또 안 붙인다.
    try std.testing.expectEqualStrings("\x1b[3~", try encodeKey(.{ .key = .delete, .modifiers = .{ .option = true } }, &buf, .{}));
    try std.testing.expectEqualStrings("\x1bOP", try encodeKey(.{ .key = .{ .function = 1 }, .modifiers = .{ .option = true } }, &buf, .{}));
}

test "encodeKey kitty: disambiguate text/ctrl/escape/functional (audit 4/5b-2)" {
    var buf: [encoded_key_buffer_len]u8 = undefined;
    const o: EncodeOptions = .{ .kitty_flags = 0b00001 }; // disambiguate on

    // 텍스트(modifier 없음) → UTF-8 그대로(shift는 codepoint에 이미 반영됨).
    try std.testing.expectEqualStrings("a", try encodeKey(.{ .key = .{ .char = 'a' } }, &buf, o));
    // Enter/Backspace(modifier 없음) → legacy 바이트(kitty 명시 예외 — shell 복구 가능).
    try std.testing.expectEqualStrings("\r", try encodeKey(.{ .key = .enter }, &buf, o));
    try std.testing.expectEqualStrings("\x7f", try encodeKey(.{ .key = .backspace }, &buf, o));
    // Ctrl+a → CSI 97 ; 5 u (base 'a'=97, mods=1+ctrl4=5).
    try std.testing.expectEqualStrings("\x1b[97;5u", try encodeKey(.{ .key = .{ .char = 'a' }, .modifiers = .{ .control = true } }, &buf, o));
    // escape(modifier 없음) → CSI 27 u (disambiguate: legacy ESC와 구분되는 핵심).
    try std.testing.expectEqualStrings("\x1b[27u", try encodeKey(.{ .key = .escape }, &buf, o));
    // arrow_up(modifier 없음) → CSI A (letter final, mods<=1이라 param 생략 — legacy 호환).
    try std.testing.expectEqualStrings("\x1b[A", try encodeKey(.{ .key = .arrow_up }, &buf, o));
    // Shift+arrow_up → CSI 1 ; 2 A (mods=1+shift1=2).
    try std.testing.expectEqualStrings("\x1b[1;2A", try encodeKey(.{ .key = .arrow_up, .modifiers = .{ .shift = true } }, &buf, o));
    // F1 → CSI P (letter), F5 → CSI 15 ~ (tilde final).
    try std.testing.expectEqualStrings("\x1b[P", try encodeKey(.{ .key = .{ .function = 1 } }, &buf, o));
    try std.testing.expectEqualStrings("\x1b[15~", try encodeKey(.{ .key = .{ .function = 5 } }, &buf, o));
    // Shift/Ctrl+Tab·Enter·Backspace는 modifier가 있으니 legacy 바이트가 아니라 CSI u로(backtab 등 —
    // legacy 바이트로 보내면 Shift+Tab backtab이 깨진다, code review 발견).
    try std.testing.expectEqualStrings("\x1b[9;2u", try encodeKey(.{ .key = .tab, .modifiers = .{ .shift = true } }, &buf, o));
    try std.testing.expectEqualStrings("\x1b[13;2u", try encodeKey(.{ .key = .enter, .modifiers = .{ .shift = true } }, &buf, o));
    try std.testing.expectEqualStrings("\x1b[127;2u", try encodeKey(.{ .key = .backspace, .modifiers = .{ .shift = true } }, &buf, o));
    try std.testing.expectEqualStrings("\x1b[9;5u", try encodeKey(.{ .key = .tab, .modifiers = .{ .control = true } }, &buf, o));
    // flags=0(미활성)이면 legacy 그대로 — escape는 \x1b(progressive enhancement 검증).
    try std.testing.expectEqualStrings("\x1b", try encodeKey(.{ .key = .escape }, &buf, .{}));
}
