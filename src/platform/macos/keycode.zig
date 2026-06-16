//! macOS 물리 키코드(kVK_ANSI_*) -> US 배열 기준 라틴 문자.
//!
//! 단축키는 물리 키 기준이어야 한다: 한글 입력 모드에서 Ctrl+B를 누르면 AppKit의
//! charactersIgnoringModifiers는 'ㅂ'을 주므로, 그걸로 매칭하는 터미널은 한글 모드에서
//! 단축키(멀티플렉서 prefix 등)가 죽는다. Maru는 Ctrl/Cmd 조합에서 현재 레이아웃 결과가 라틴이
//! 아니면(>=0x80) 물리 키코드를 이 테이블로 되돌려 레이아웃과 무관하게 같은 바이트를
//! 인코딩한다. 라틴 레이아웃(영어/Dvorak 등)의 결과는 그대로 둔다 — 사용자가 고른 라틴
//! 배열의 글자 배치를 존중한다.
//!
//! 키코드 값은 macOS Carbon Events.h의 kVK_ANSI_* 상수(공개 헤더)다.

/// 물리 키코드의 US 배열 기준 소문자/기호(없으면 null). 글자·숫자·기본 기호만 — 단축키
/// 정규화 용도라 그 이상은 필요 없다.
pub fn usAsciiForKeyCode(key_code: u32) ?u21 {
    return switch (key_code) {
        0x00 => 'a',
        0x01 => 's',
        0x02 => 'd',
        0x03 => 'f',
        0x04 => 'h',
        0x05 => 'g',
        0x06 => 'z',
        0x07 => 'x',
        0x08 => 'c',
        0x09 => 'v',
        0x0B => 'b',
        0x0C => 'q',
        0x0D => 'w',
        0x0E => 'e',
        0x0F => 'r',
        0x10 => 'y',
        0x11 => 't',
        0x12 => '1',
        0x13 => '2',
        0x14 => '3',
        0x15 => '4',
        0x16 => '6',
        0x17 => '5',
        0x18 => '=',
        0x19 => '9',
        0x1A => '7',
        0x1B => '-',
        0x1C => '8',
        0x1D => '0',
        0x1E => ']',
        0x1F => 'o',
        0x20 => 'u',
        0x21 => '[',
        0x22 => 'i',
        0x23 => 'p',
        0x25 => 'l',
        0x26 => 'j',
        0x27 => '\'',
        0x28 => 'k',
        0x29 => ';',
        0x2A => '\\',
        0x2B => ',',
        0x2C => '/',
        0x2D => 'n',
        0x2E => 'm',
        0x2F => '.',
        0x32 => '`',
        else => null,
    };
}

/// 물리 키코드가 숫자 키패드(numpad) 키인가(G10 DECKPAM). macOS kVK_ANSI_Keypad* 상수 집합.
/// application keypad 모드일 때 이 키들이 SS3(`ESC O p`..)로 인코딩되도록 platform이 input.KeyEvent.keypad에
/// 채운다 — 키패드의 macOS keycode 지식은 platform에 두고, SS3 인코딩은 core(input.zig)가 한다.
pub fn isKeypad(key_code: u32) bool {
    return switch (key_code) {
        // 0..9
        0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C => true,
        // . * + clear / enter - =
        0x41, 0x43, 0x45, 0x47, 0x4B, 0x4C, 0x4E, 0x51 => true,
        else => false,
    };
}

/// US 배열 기준 라틴 글자/기호 -> macOS 물리 키코드(kVK_ANSI_*). `usAsciiForKeyCode`의 역방향이다.
/// Carbon `RegisterEventHotKey`(전역 단축키)는 가상 키코드를 요구하므로, config의 글자 chord를 OS
/// 등록용 키코드로 되돌린다. 대문자는 소문자로 fold한다(Shift는 modifier로 따로 전달되므로 글자 자체는
/// 소문자 키코드). 매핑이 없는 글자는 null(그 글자는 전역 등록 불가 — 호출자가 diagnostic). 명명 키
/// (Space/Enter/화살표/F1~ 등)는 ANSI 글자 키코드 표 밖이라 여기서 다루지 않는다(global_hotkey가 별도 매핑).
pub fn macVirtualKeyCodeForAscii(codepoint: u21) ?u16 {
    const c: u21 = if (codepoint >= 'A' and codepoint <= 'Z') codepoint + 32 else codepoint;
    return switch (c) {
        'a' => 0x00,
        's' => 0x01,
        'd' => 0x02,
        'f' => 0x03,
        'h' => 0x04,
        'g' => 0x05,
        'z' => 0x06,
        'x' => 0x07,
        'c' => 0x08,
        'v' => 0x09,
        'b' => 0x0B,
        'q' => 0x0C,
        'w' => 0x0D,
        'e' => 0x0E,
        'r' => 0x0F,
        'y' => 0x10,
        't' => 0x11,
        '1' => 0x12,
        '2' => 0x13,
        '3' => 0x14,
        '4' => 0x15,
        '6' => 0x16,
        '5' => 0x17,
        '=' => 0x18,
        '9' => 0x19,
        '7' => 0x1A,
        '-' => 0x1B,
        '8' => 0x1C,
        '0' => 0x1D,
        ']' => 0x1E,
        'o' => 0x1F,
        'u' => 0x20,
        '[' => 0x21,
        'i' => 0x22,
        'p' => 0x23,
        'l' => 0x25,
        'j' => 0x26,
        '\'' => 0x27,
        'k' => 0x28,
        ';' => 0x29,
        '\\' => 0x2A,
        ',' => 0x2B,
        '/' => 0x2C,
        'n' => 0x2D,
        'm' => 0x2E,
        '.' => 0x2F,
        '`' => 0x32,
        else => null,
    };
}

const std = @import("std");

test "physical keycodes map to US-layout latin for layout-independent shortcuts" {
    try std.testing.expectEqual(@as(?u21, 'b'), usAsciiForKeyCode(0x0B));
    try std.testing.expectEqual(@as(?u21, 'c'), usAsciiForKeyCode(0x08));
    try std.testing.expectEqual(@as(?u21, 'v'), usAsciiForKeyCode(0x09));
    try std.testing.expectEqual(@as(?u21, null), usAsciiForKeyCode(0x24)); // Return은 별도 KeyCode
    try std.testing.expectEqual(@as(?u21, null), usAsciiForKeyCode(0xFFFF));
}

test "macVirtualKeyCodeForAscii inverts the table and folds uppercase" {
    // 역방향이 정방향과 왕복해야 한다(전역 단축키 등록이 같은 물리 키를 가리키게).
    try std.testing.expectEqual(@as(?u16, 0x0B), macVirtualKeyCodeForAscii('b'));
    try std.testing.expectEqual(@as(?u16, 0x0B), macVirtualKeyCodeForAscii('B')); // 대문자 fold
    try std.testing.expectEqual(@as(?u16, 0x00), macVirtualKeyCodeForAscii('a'));
    try std.testing.expectEqual(@as(?u16, 0x12), macVirtualKeyCodeForAscii('1'));
    try std.testing.expectEqual(@as(?u16, 0x21), macVirtualKeyCodeForAscii('['));
    try std.testing.expectEqual(@as(?u16, null), macVirtualKeyCodeForAscii(' ')); // Space는 명명 키(별도)
    try std.testing.expectEqual(@as(?u16, null), macVirtualKeyCodeForAscii('가'));
    // 표에 있는 모든 글자가 왕복하는지(usAsciiForKeyCode → macVirtualKeyCodeForAscii → 원래 키코드).
    var kc: u32 = 0;
    while (kc <= 0x32) : (kc += 1) {
        if (usAsciiForKeyCode(kc)) |ascii| {
            try std.testing.expectEqual(@as(?u16, @intCast(kc)), macVirtualKeyCodeForAscii(ascii));
        }
    }
}
