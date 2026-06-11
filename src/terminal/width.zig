const std = @import("std");

pub fn cellWidth(codepoint: u21) u2 {
    if (isCombiningMark(codepoint)) return 0;
    if (isWideCodepoint(codepoint)) return 2;
    return 1;
}

pub fn isCombiningMark(codepoint: u21) bool {
    // This is intentionally a small first table. It covers the common
    // combining mark blocks needed to keep accents from moving the terminal
    // cursor while leaving full Unicode grapheme support to later fixtures.
    return switch (codepoint) {
        0x0300...0x036F,
        0x1AB0...0x1AFF,
        0x1DC0...0x1DFF,
        0x20D0...0x20FF,
        // These combining ranges sit inside the wide CJK block below, so they
        // must be listed here to win over isWideCodepoint; otherwise a zero-
        // width mark like U+3099 would be stored as a 2-cell glyph and drift
        // the cursor for decomposed Japanese/CJK text.
        0x302A...0x302F,
        0x3099...0x309A,
        // 변형 선택자(VS1~VS16, 0xFE00~0xFE0F): 0폭이며 앞 글자에 붙는다. VS16(0xFE0F)은 앞
        // 글자를 이모지 표현으로 만들어, base+VS16이 한 셀(combining)로 셰이퍼에 가 emoji 폰트로
        // 컬러로 그려진다(예: ❤+VS16=❤️). 별도 셀이면 base만 텍스트 폰트로 그려져 단색이 됐다.
        0xFE00...0xFE0F,
        0xFE20...0xFE2F,
        => true,
        else => false,
    };
}

fn isWideCodepoint(codepoint: u21) bool {
    // Minimal UAX#11-inspired ranges for the first terminal grid model. The
    // ranges cover Hangul, CJK, Kana, fullwidth forms, and common emoji blocks
    // without pulling in a generated Unicode table before the parser/storage
    // shape is stable.
    return switch (codepoint) {
        0x1100...0x115F,
        0x2329...0x232A,
        0x2E80...0xA4CF,
        0xAC00...0xD7A3,
        0xF900...0xFAFF,
        0xFE10...0xFE19,
        0xFE30...0xFE6F,
        0xFF00...0xFF60,
        0xFFE0...0xFFE6,
        // Unicode Emoji_Presentation=Yes 중 0x1F300 미만(기본 이모지 표현 — VS16 없이도 width 2,
        // 컬러). ✅(2705)·⌚(231A)·⏰(23F0)·⭐(2B50)·❌(274C) 등. 이게 없으면 width 1 slot에
        // 그려져 반 잘렸다.
        0x231A...0x231B,
        0x23E9...0x23EC,
        0x23F0,
        0x23F3,
        0x25FD...0x25FE,
        0x2614...0x2615,
        0x2648...0x2653,
        0x267F,
        0x2693,
        0x26A1,
        0x26AA...0x26AB,
        0x26BD...0x26BE,
        0x26C4...0x26C5,
        0x26CE,
        0x26D4,
        0x26EA,
        0x26F2...0x26F3,
        0x26F5,
        0x26FA,
        0x26FD,
        0x2705,
        0x270A...0x270B,
        0x2728,
        0x274C,
        0x274E,
        0x2753...0x2755,
        0x2757,
        0x2795...0x2797,
        0x27B0,
        0x27BF,
        0x2B1B...0x2B1C,
        0x2B50,
        0x2B55,
        0x1F300...0x1FAFF,
        0x20000...0x3FFFD,
        => true,
        else => false,
    };
}

test "cellWidth treats ASCII as single-cell" {
    try std.testing.expectEqual(@as(u2, 1), cellWidth('A'));
}

test "cellWidth treats Hangul and CJK as double-cell" {
    try std.testing.expectEqual(@as(u2, 2), cellWidth('한'));
    try std.testing.expectEqual(@as(u2, 2), cellWidth('界'));
}

test "cellWidth treats combining marks as zero-cell" {
    try std.testing.expectEqual(@as(u2, 0), cellWidth(0x0301));
}

test "cellWidth treats CJK combining marks inside the wide block as zero-cell" {
    // These live inside the 0x2E80..0xA4CF wide range, so without an explicit
    // combining entry they would be misread as 2-cell glyphs.
    try std.testing.expectEqual(@as(u2, 0), cellWidth(0x3099)); // combining voiced sound mark
    try std.testing.expectEqual(@as(u2, 0), cellWidth(0x309A)); // combining semi-voiced sound mark
    try std.testing.expectEqual(@as(u2, 0), cellWidth(0x302A)); // combining CJK tone mark
}

test "cellWidth: variation selectors are zero-width and default-emoji symbols are wide" {
    try std.testing.expectEqual(@as(u2, 0), cellWidth(0xFE0F)); // VS16(이모지 표현)
    try std.testing.expectEqual(@as(u2, 0), cellWidth(0xFE0E)); // VS15(텍스트 표현)
    try std.testing.expectEqual(@as(u2, 2), cellWidth(0x2705)); // ✅
    try std.testing.expectEqual(@as(u2, 2), cellWidth(0x23F0)); // ⏰
    try std.testing.expectEqual(@as(u2, 2), cellWidth(0x2B50)); // ⭐
    try std.testing.expectEqual(@as(u2, 2), cellWidth(0x1F389)); // 🎉(기존)
    try std.testing.expectEqual(@as(u2, 1), cellWidth('A')); // 일반 글자 회귀
    try std.testing.expectEqual(@as(u2, 1), cellWidth(0x2713)); // ✓(텍스트 체크, default-emoji 아님)
}

test "VS16 attaches to the base as a combining mark (one cell), shaper sees the emoji cluster" {
    var core = try @import("core.zig").TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("\xe2\x9d\xa4\xef\xb8\x8f"); // ❤(U+2764) + VS16(U+FE0F)
    // 한 셀에 base + combining(VS16)으로 들어간다 — 두 셀로 갈라지지 않는다.
    try std.testing.expectEqual(@as(u21, 0x2764), core.cells[0].codepoint);
    try std.testing.expectEqual(@as(?u21, 0xFE0F), core.cells[0].combining);
    try std.testing.expectEqual(@as(u21, ' '), core.cells[1].codepoint); // 다음 셀은 비어 있음
}
