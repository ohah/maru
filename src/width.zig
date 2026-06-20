const std = @import("std");

pub fn cellWidth(codepoint: u21) u2 {
    if (isCombiningMark(codepoint)) return 0;
    if (isWideCodepoint(codepoint)) return 2;
    return 1;
}

/// 셀 폭은 1(EAW Ambiguous)이지만 폰트가 글리프를 한 칸보다 넓게 그려, **여유가 있으면(다음 셀이 비면) 2칸으로
/// 렌더**하는 게 자연스러운 심볼인지. advance(커서 폭)는 1로 두고 그릴 폭만 2로 키우는 Ghostty `constraintWidth`
/// 패턴의 maru판 — 동그란/괄호친 영숫자(Enclosed Alphanumerics U+2460~U+24FF: ①②③ ⑴ ⒈ Ⓐ ⓐ ⓪ 등)는
/// 거의 다 폰트에서 ~2칸 폭이라 1칸에 욱여넣으면 작아진다(사용자 피드백 "③가 너무 작다"). 베이스: UAX#11이
/// 이들을 Ambiguous=narrow(1)로 두므로 advance는 1 유지(셸 wcwidth와 커서 정합), 렌더만 2칸 허용(Ghostty 동일).
/// 셀 폭 자체(cellWidth)는 바꾸지 않는다 — 이건 draw-list가 "다음 셀이 비었을 때만" 그릴 폭을 키우는 판정용이다.
pub fn isWideRenderSymbol(codepoint: u21) bool {
    return codepoint >= 0x2460 and codepoint <= 0x24FF;
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

/// Unicode Emoji_Presentation=Yes 중 0x1F300 미만의 큐레이션 집합(기본 이모지 표현 — VS16 없이도
/// width 2이고 컬러). ✅(2705)·⌚(231A)·⏰(23F0)·⭐(2B50)·❌(274C) 등. 0x2600~0x27BF·0x2B00~0x2BFF
/// 블록을 통째로 넣지 않는다 — 그 안엔 ✓(2713)·★(2605)·♠(2660) 같은 단색 텍스트 기호가 많아,
/// 통째로 이모지로 분류하면 SGR 전경색을 잃고(컬러 경로로 가) 잘못 그려진다.
fn isDefaultEmojiPresentation(codepoint: u21) bool {
    return switch (codepoint) {
        // 0x1F000~0x1F2FF의 Emoji_Presentation=Yes(전부 EAW-Wide): 마작 🀄, 조커 🃏, 스퀘어드
        // 기호 🆎🆑🆒🈁🈚 등. 이전 isColorGlyph(0x1F000~0x1FAFF)가 컬러로 칠하던 것을 단일화하며
        // 빠뜨려 단색으로 그려졌다(회귀). EAW-Wide라 width 2도 함께 복원한다.
        0x1F004,
        0x1F0CF,
        0x1F18E,
        0x1F191...0x1F19A,
        0x1F201,
        0x1F21A,
        0x1F22F,
        0x1F232...0x1F236,
        0x1F238...0x1F23A,
        0x1F250...0x1F251,
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
        => true,
        else => false,
    };
}

/// 컬러 이모지로 렌더되는(emoji 폰트로 래스터되는) codepoint인지 — metal_frame 컬러 UV sentinel의
/// 단일 출처. 셀 너비와는 별개다(지역 표시자 RI는 컬러지만 폭 1). 래스터라이저(coretext_smoke.m)는
/// codepoint가 아니라 그린 폰트의 컬러 테이블(sbix/COLR)로 이모지를 판정하므로(maru_font_is_color)
/// 이 집합을 미러링하지 않는다 — VS16 결합(❤️)처럼 codepoint만으론 못 가르는 경우까지 정확하다.
pub fn isEmojiPresentation(codepoint: u21) bool {
    return switch (codepoint) {
        0x1F1E6...0x1F1FF, // 지역 표시자(국기 — 컬러, 폭은 1)
        0x1F300...0x1FAFF, // 주요 이모지/그림문자 + 스킨톤 modifier
        => true,
        else => isDefaultEmojiPresentation(codepoint),
    };
}

fn isWideCodepoint(codepoint: u21) bool {
    // Minimal UAX#11-inspired ranges for the first terminal grid model. The
    // ranges cover Hangul, CJK, Kana, fullwidth forms, and common emoji blocks
    // without pulling in a generated Unicode table before the parser/storage
    // shape is stable. 0x1F300 미만 default-emoji는 isDefaultEmojiPresentation과 공유한다.
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
        else => isDefaultEmojiPresentation(codepoint),
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

// core 통합 테스트(VS16 클러스터 → 셀 폭/combining)는 terminal/core.zig로 옮겼다 — width.zig는 순수 Unicode
// 폭 함수(중립)라 terminal/core를 import하지 않는다(레이어 무관 유지).

test "isEmojiPresentation: 0x1F000-block default-emoji restored (color + wide)" {
    // 회귀: 단일화 때 0x1F000~0x1F2FF 컬러 이모지가 빠졌다.
    try std.testing.expect(isEmojiPresentation(0x1F004)); // 🀄 마작
    try std.testing.expect(isEmojiPresentation(0x1F0CF)); // 🃏 조커
    try std.testing.expect(isEmojiPresentation(0x1F18E)); // 🆎
    try std.testing.expect(isEmojiPresentation(0x1F19A)); // 🆚
    try std.testing.expectEqual(@as(u2, 2), cellWidth(0x1F004)); // EAW-Wide라 width 2도
    try std.testing.expectEqual(@as(u2, 2), cellWidth(0x1F0CF));
    // 비-이모지 enclosed alphanumeric은 그대로 false(블록 전체를 넣지 않음).
    try std.testing.expect(!isEmojiPresentation(0x1F100)); // 🄀 (Emoji_Presentation 아님)
}

test "isEmojiPresentation: default-emoji yes, mono text symbols no (SGR fg preserved)" {
    // default-emoji-presentation = true(VS16 없이도 컬러)
    try std.testing.expect(isEmojiPresentation(0x2705)); // ✅
    try std.testing.expect(isEmojiPresentation(0x1F389)); // 🎉
    try std.testing.expect(isEmojiPresentation(0x2B50)); // ⭐
    try std.testing.expect(isEmojiPresentation(0x1F1F0)); // 🇰(RI, 컬러)
    // ❤(U+2764)는 text-default라 단독은 false — 컬러는 VS16 결합 시에만(metal_frame이 combining
    // 으로 판정). 단독 ❤는 SGR 전경색을 따르는 텍스트 글자다.
    try std.testing.expect(!isEmojiPresentation(0x2764));
    // 단색 텍스트 기호 = false (SGR 전경색을 잃지 않게)
    try std.testing.expect(!isEmojiPresentation(0x2713)); // ✓ 텍스트 체크
    try std.testing.expect(!isEmojiPresentation(0x2605)); // ★
    try std.testing.expect(!isEmojiPresentation(0x2660)); // ♠
    try std.testing.expect(!isEmojiPresentation(0x2717)); // ✗
    try std.testing.expect(!isEmojiPresentation('A'));
}
