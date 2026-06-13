//! 전역(OS) 단축키 descriptor — config의 GlobalBinding(KeyChord + GlobalAction)을 Carbon
//! `RegisterEventHotKey`가 요구하는 (가상 키코드, Carbon modifier mask)로 변환한다. 순수 매핑이라
//! OS 무관 단위 테스트한다. a2의 Swift가 ABI로 이 값을 받아 전역 핫키를 등록한다.
//!
//! 상수 출처: 가상 키코드는 macOS Carbon `Events.h`의 kVK_* (공개 헤더), modifier mask 비트는
//! `Events.h`의 cmdKey/shiftKey/optionKey/controlKey (RegisterEventHotKey가 받는 값)다.

const std = @import("std");
const maru = @import("maru");
const config = maru.config;
const terminal = maru.terminal;
const keycode = @import("keycode.zig");

// Carbon modifier mask 비트(RegisterEventHotKey 인자). 공개 헤더 상수.
pub const cmd_key: u32 = 0x0100;
pub const shift_key: u32 = 0x0200;
pub const option_key: u32 = 0x0800;
pub const control_key: u32 = 0x1000;

/// OS 등록용 전역 핫키 기술자. a2의 Swift가 RegisterEventHotKey(carbon_modifiers, virtual_key_code)로
/// 등록하고, 핫키가 눌리면 action(toggle_window/show_window)을 수행한다.
pub const Descriptor = struct {
    virtual_key_code: u16,
    carbon_modifiers: u32,
    action: config.GlobalAction,
};

/// ModifierSet → Carbon modifier mask. RegisterEventHotKey가 그대로 받는다.
pub fn carbonModifiers(mods: terminal.ModifierSet) u32 {
    var mask: u32 = 0;
    if (mods.command) mask |= cmd_key;
    if (mods.shift) mask |= shift_key;
    if (mods.option) mask |= option_key;
    if (mods.control) mask |= control_key;
    return mask;
}

/// KeyName → macOS 가상 키코드(kVK_*). 대응 키코드가 없는 키(예: `+`/Plus, Insert)는 null —
/// 그 chord는 전역 등록 불가다(호출자가 건너뛰고 진단). 글자는 keycode.zig 표(US 배열)를 쓰고,
/// Space와 명명 키(Enter/Esc/Tab/방향/Fn 등)는 여기서 직접 매핑한다.
fn virtualKeyCode(key: config.keybinding.KeyName) ?u16 {
    return switch (key) {
        // Space는 글자 표 밖이라 직접 매핑(kVK_Space=0x31). 나머지 글자는 US 배열 역매핑.
        .char => |c| if (c == ' ') @as(?u16, 0x31) else keycode.macVirtualKeyCodeForAscii(c),
        .enter => 0x24, // kVK_Return
        .escape => 0x35, // kVK_Escape
        .tab => 0x30, // kVK_Tab
        .backspace => 0x33, // kVK_Delete (백스페이스)
        .delete => 0x75, // kVK_ForwardDelete
        .insert => null, // Mac 키보드엔 대응 키코드 없음
        .home => 0x73,
        .end => 0x77,
        .page_up => 0x74,
        .page_down => 0x79,
        .arrow_up => 0x7E,
        .arrow_down => 0x7D,
        .arrow_left => 0x7B,
        .arrow_right => 0x7C,
        .function => |n| switch (n) {
            1 => 0x7A,
            2 => 0x78,
            3 => 0x63,
            4 => 0x76,
            5 => 0x60,
            6 => 0x61,
            7 => 0x62,
            8 => 0x64,
            9 => 0x65,
            10 => 0x6D,
            11 => 0x67,
            12 => 0x6F,
            13 => 0x69,
            14 => 0x6B,
            15 => 0x71,
            16 => 0x6A,
            17 => 0x40,
            18 => 0x4F,
            19 => 0x50,
            20 => 0x5A,
            else => null, // F21~F24는 표준 키코드 상수가 없어 미지원
        },
    };
}

/// GlobalBinding → OS 등록용 Descriptor. chord의 키가 가상 키코드로 매핑 안 되면 null(호출자가 건너뜀).
pub fn descriptorFor(binding: config.keybinding.GlobalBinding) ?Descriptor {
    const vk = virtualKeyCode(binding.chord.key) orelse return null;
    return .{
        .virtual_key_code = vk,
        .carbon_modifiers = carbonModifiers(binding.chord.modifiers),
        .action = binding.action,
    };
}

test "carbonModifiers maps the modifier set to Carbon mask bits" {
    try std.testing.expectEqual(@as(u32, 0), carbonModifiers(.{}));
    try std.testing.expectEqual(cmd_key | option_key, carbonModifiers(.{ .command = true, .option = true }));
    try std.testing.expectEqual(
        cmd_key | shift_key | option_key | control_key,
        carbonModifiers(.{ .command = true, .shift = true, .option = true, .control = true }),
    );
}

test "descriptorFor maps global bindings to virtual keycode + carbon modifiers" {
    // global:Cmd+Alt+Space = toggle_window → Space(0x31), cmd|option.
    {
        const d = descriptorFor(.{
            .chord = try config.KeyChord.parse("Cmd+Alt+Space"),
            .action = .toggle_window,
        }).?;
        try std.testing.expectEqual(@as(u16, 0x31), d.virtual_key_code);
        try std.testing.expectEqual(cmd_key | option_key, d.carbon_modifiers);
        try std.testing.expectEqual(config.GlobalAction.toggle_window, d.action);
    }
    // Cmd+Shift+B → B는 대문자 .char='B'지만 keycode가 소문자로 fold → 0x0B. Shift는 modifier로 따로.
    {
        const d = descriptorFor(.{
            .chord = try config.KeyChord.parse("Cmd+Shift+B"),
            .action = .show_window,
        }).?;
        try std.testing.expectEqual(@as(u16, 0x0B), d.virtual_key_code);
        try std.testing.expectEqual(cmd_key | shift_key, d.carbon_modifiers);
    }
    // F5 → 0x60.
    {
        const d = descriptorFor(.{
            .chord = try config.KeyChord.parse("Cmd+F5"),
            .action = .toggle_window,
        }).?;
        try std.testing.expectEqual(@as(u16, 0x60), d.virtual_key_code);
    }
    // 매핑 없는 키는 null — '+'(Plus)와 Insert.
    try std.testing.expect(descriptorFor(.{ .chord = try config.KeyChord.parse("Cmd+Plus"), .action = .toggle_window }) == null);
    try std.testing.expect(descriptorFor(.{ .chord = try config.KeyChord.parse("Cmd+Insert"), .action = .toggle_window }) == null);
}
