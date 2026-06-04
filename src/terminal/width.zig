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
