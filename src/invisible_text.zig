//! 화면에 **보이지 않는** 코드 포인트 판정 — 남이 정한 글(에이전트가 친 낱말·프로그램이 정한 pane 제목)을 사람이 읽을 한 줄에 실을 때,
//! 보이는 것과 실제가 달라지게 만드는 글자를 가린다. 판정만 한다 — 그 글자를 빼거나(공백으로) 보이게 쓸지(`<U+200B>`)는 부르는 쪽이 정한다.
//!
//! **왜 따로 있나**: 같은 질문을 두 층이 묻는다 — CLI 의 파싱 오류가 되비추는 낱말(`maru browser` — `'--sel<ZWSP>ector'` 가 `'--selector'` 로
//! 보이면 맞는 옵션이 「모르는 옵션」 으로 읽힌다)과 L2 의 pane 동의 모달·메뉴 제목(`control_agent_tab_consent.sanitizeTitle` — RLO 하나면 뒤
//! 질문이 거꾸로 그려진다). 두 곳이 목록을 따로 적으면 한쪽만 자란다(실제로 그랬다 — 모달은 U+200B 를 지웠고 CLI 는 그대로 냈다). 둘 다
//! 닿는 최상위 중립 leaf(`path_shape.zig` 결, std 만)에 둔다(layering-and-portability.md §3.5).
//!
//! **목록의 근거(공개 명세)**: Unicode `Default_Ignorable_Code_Point`(UAX #44 · DerivedCoreProperties.txt — 「렌더러가 그 글자를 지원하지 않으면
//! 아무것도 그리지 않는다」 로 정의된 집합: 폭 0 글자·양방향 서식·변이 선택자·한글 채움·태그) ∪ 일반 범주 Cc(C0·DEL·C1 — 터미널을 움직인다)
//! ∪ Zl/Zp(U+2028·U+2029 — 줄을 바꾼다) ∪ 행간 주석(U+FFF9–U+FFFB — 글을 숨긴다).
//!
//! **이 판정이 하지 않는 것**: 페이지 글 출력(`browser.displayUnsafe` — get-cookies·exec·snapshot 의 `\uXXXX`)은 이것을 쓰지 않는다. 거기서
//! ZWJ·변이 선택자를 바꾸면 페이지의 이모지(👨‍👩‍👧·❤️)가 깨진다 — 사람이 읽을 낱말 하나와 페이지가 보낸 글은 목적이 다르다. 편집기 문서의
//! 위험 글자(`hazard.zig` — 탭·줄바꿈을 빼고 ZWJ 를 문맥으로 가른다)와도 다르다. NBSP 같은 비표준 공백은 **보이는** 빈칸이라 여기 넣지 않는다.

const std = @import("std");

/// `cp` 가 그려지지 않거나(폭 0·서식) 화면·줄을 움직이는(제어) 글자인가.
pub fn isInvisible(cp: u21) bool {
    // Cc — C0·DEL·C1.
    if (cp < 0x20 or (cp >= 0x7F and cp <= 0x9F)) return true;
    return switch (cp) {
        // Default_Ignorable_Code_Point(Unicode 16.0 DerivedCoreProperties.txt 의 범위 그대로).
        0x00AD, // SOFT HYPHEN
        0x034F, // COMBINING GRAPHEME JOINER
        0x061C, // ARABIC LETTER MARK
        0x115F...0x1160, // HANGUL CHOSEONG/JUNGSEONG FILLER
        0x17B4...0x17B5, // KHMER VOWEL INHERENT AQ/AA
        0x180B...0x180F, // MONGOLIAN FREE VARIATION SELECTORS·VOWEL SEPARATOR
        0x200B...0x200F, // ZWSP·ZWNJ·ZWJ·LRM·RLM
        0x202A...0x202E, // 양방향 embedding·override
        0x2060...0x206F, // WORD JOINER·보이지 않는 연산자·양방향 isolate·폐기된 서식
        0x3164, // HANGUL FILLER
        0xFE00...0xFE0F, // VARIATION SELECTOR-1..16
        0xFEFF, // ZERO WIDTH NO-BREAK SPACE(BOM)
        0xFFA0, // HALFWIDTH HANGUL FILLER
        0xFFF0...0xFFF8, // 미할당(무시 예약)
        0x1BCA0...0x1BCA3, // SHORTHAND FORMAT CONTROLS
        0x1D173...0x1D17A, // MUSICAL SYMBOL BEGIN/END …
        0xE0000...0xE0FFF, // 태그 글자·VARIATION SELECTOR-17..256·예약
        // Zl·Zp — 줄·문단 구분(줄을 바꾼다).
        0x2028,
        0x2029,
        // 행간 주석 — 그 사이 글을 숨긴다.
        0xFFF9...0xFFFB,
        => true,
        else => false,
    };
}

const testing = std.testing;

// 이 시험이 증명하는 것: 범위의 **양 끝과 바로 밖**을 하나씩 — 범위를 하나 좁히거나 넓히는 실수(`...` 끝 하나)가 걸린다. 사람이 읽는 한 줄에서
// 「보이는데 안 보인다」 가 갈리는 자리다.
test "보이지 않는 글자: Default_Ignorable·Cc·줄 구분·행간 주석의 양 끝은 참, 바로 밖은 거짓" {
    const yes = [_]u21{
        0x00,    0x1F,    0x7F,    0x80,    0x9F,   0x00AD, 0x034F, 0x061C,  0x115F,  0x1160,
        0x17B4,  0x17B5,  0x180B,  0x180F,  0x200B, 0x200F, 0x202A, 0x202E,  0x2060,  0x206F,
        0x3164,  0xFE00,  0xFE0F,  0xFEFF,  0xFFA0, 0xFFF0, 0xFFF8, 0x1BCA0, 0x1BCA3, 0x1D173,
        0x1D17A, 0xE0000, 0xE0041, 0xE0FFF, 0x2028, 0x2029, 0xFFF9, 0xFFFB,
    };
    for (yes) |cp| {
        errdefer std.debug.print("U+{X:0>4} 은 보이지 않는 글자여야 한다\n", .{cp});
        try testing.expect(isInvisible(cp));
    }
    const no = [_]u21{
        0x20,     'a',    '-',    0x7E,   0xA0,    0x00AC,  0x00AE,  0x034E,  0x0350,  0x061B,
        0x061D,   0x115E, 0x1161, 0x17B3, 0x17B6,  0x180A,  0x1810,  0x200A,  0x2010,  0x2027,
        0x202F,   0x205F, 0x2070, 0x3163, 0x3165,  0xFDFF,  0xFE10,  0xFEFE,  0xFF00,  0xFF9F,
        0xFFA1,   0xFFEF, 0xFFFC, 0xFFFD, 0x1BC9F, 0x1BCA4, 0x1D172, 0x1D17B, 0xDFFFF, 0xE1000,
        0x10FFFF,
        '가',
        0x1F600,
    };
    for (no) |cp| {
        errdefer std.debug.print("U+{X:0>4} 은 보이는 글자다\n", .{cp});
        try testing.expect(!isInvisible(cp));
    }
}
