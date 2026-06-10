//! macOS 물리 키코드(kVK_ANSI_*) -> US 배열 기준 라틴 문자.
//!
//! 단축키는 물리 키 기준이어야 한다: 한글 입력 모드에서 Ctrl+B를 누르면 AppKit의
//! charactersIgnoringModifiers는 'ㅂ'을 주므로, 그걸로 매칭하는 터미널은 한글 모드에서
//! 단축키(tmux prefix 등)가 죽는다. Maru는 Ctrl/Cmd 조합에서 현재 레이아웃 결과가 라틴이
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

const std = @import("std");

test "physical keycodes map to US-layout latin for layout-independent shortcuts" {
    try std.testing.expectEqual(@as(?u21, 'b'), usAsciiForKeyCode(0x0B));
    try std.testing.expectEqual(@as(?u21, 'c'), usAsciiForKeyCode(0x08));
    try std.testing.expectEqual(@as(?u21, 'v'), usAsciiForKeyCode(0x09));
    try std.testing.expectEqual(@as(?u21, null), usAsciiForKeyCode(0x24)); // Return은 별도 KeyCode
    try std.testing.expectEqual(@as(?u21, null), usAsciiForKeyCode(0xFFFF));
}
