//! `terminal.KeyEvent` → `chrome.input.InputEvent.KeyEvent` — 키 이벤트를 크롬 위젯이 읽는 꼴로 바꾸는 **표**.
//!
//! 중립 chrome 은 terminal 타입을 모르고(L1/L3 경계 — `chrome/input.zig`), session 은 chrome 을 모른다. 그래서 두 타입을 다 아는
//! 이 L4 중립 런타임(`src/app`)에 둔다. 예전에는 macOS(`app_session/input.zig` 의 `chromeInputFromKeyEvent`)와 Windows
//! (`win32_keys.zig` 의 `chromeKeyEvent`)가 「같은 표여야 한다」고 적어 둔 채 각자 들고 있었다 — 한쪽만 고치면 같은 키가 두 OS 에서
//! 다른 위젯 동작을 낸다([layering-and-portability.md](../../docs/layering-and-portability.md) §3.5).
const terminal = @import("../terminal.zig");
const chrome = @import("../chrome.zig");

/// 표에 없는 키는 `.other` — 위젯이 「모르는 키」로 다루게 하는 것이 계약이다. 모디파이어(shift/ctrl/opt/cmd)도 그대로 건넨다 —
/// find 의 Shift+Enter(이전 매치)·⌘/⌃/⌥+글자(닫기) 판정이 쓴다. 글자가 아닌 키의 codepoint 는 0.
pub fn chromeKeyEvent(event: terminal.KeyEvent) chrome.input.InputEvent.KeyEvent {
    const key: chrome.input.Key = switch (event.key) {
        .enter => .enter,
        .escape => .escape,
        .arrow_up => .up,
        .arrow_down => .down,
        .arrow_left => .left,
        .arrow_right => .right,
        .backspace => .backspace,
        .char => .char,
        .tab => .tab,
        else => .other,
    };
    return .{
        .key = key,
        .codepoint = switch (event.key) {
            .char => |c| c,
            else => 0,
        },
        .mods = .{
            .shift = event.modifiers.shift,
            .control = event.modifiers.control,
            .option = event.modifiers.option,
            .command = event.modifiers.command,
        },
    };
}

const std = @import("std");

test "chromeKeyEvent: 특수 키와 글자, 모디파이어가 그대로 건너가고 표에 없는 키는 other 다" {
    const enter = chromeKeyEvent(.{ .key = .enter });
    try std.testing.expectEqual(chrome.input.Key.enter, enter.key);
    try std.testing.expectEqual(@as(u21, 0), enter.codepoint);

    const y = chromeKeyEvent(.{ .key = .{ .char = 'y' }, .modifiers = .{ .shift = true, .command = true } });
    try std.testing.expectEqual(chrome.input.Key.char, y.key);
    try std.testing.expectEqual(@as(u21, 'y'), y.codepoint);
    try std.testing.expect(y.mods.shift and y.mods.command and !y.mods.option);

    try std.testing.expectEqual(chrome.input.Key.other, chromeKeyEvent(.{ .key = .home }).key);
}
