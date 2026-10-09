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
///
/// **이 집합은 래스터 cover-fit 게이트의 단일 출처이기도 하다**(docs/glyph-role-render-model.md). 폰트가 셀보다
/// 넓게 그린 글리프를 종횡비 유지 축소(cover-fit)하는 대상은 이 wide-render-symbol뿐이다 — 일반 텍스트는 ink가
/// advance를 미세하게 넘어도 자연 메트릭+baseline으로 둔다(스케일/ink-center 안 함). `coretext_smoke.m`의
/// `maru_is_wide_render_symbol`이 이 범위를 주석-동기로 미러한다(그 `.m`은 풀 코어 비링크 smoke 하니스 공유라
/// zig 직접 호출 불가). 범위를 바꾸면 거기도 동기.
pub fn isWideRenderSymbol(codepoint: u21) bool {
    return codepoint >= 0x2460 and codepoint <= 0x24FF;
}

/// `text.ambiguous-width` 설정을 반영한 셀 폭. `ambiguous_wide`가 false면 cellWidth와 같다(narrow — 기본).
/// true면 EAW Ambiguous 중 폰트가 전각으로 그리는 심볼(isWideRenderSymbol)을 **advance 2**로 올린다 — 1칸
/// (cellWidth) 결과만 대상이라 combining(0)·이미 wide(2)는 안 건드린다. box/block·PUA는 isWideRenderSymbol에
/// 없어 1칸 유지(maru 합성/Nerd Font 보존). narrow에서도 다음 셀이 비면 렌더만 2칸(draw_list constraintWidth).
pub fn cellWidthAmbiguous(codepoint: u21, ambiguous_wide: bool) u2 {
    const base = cellWidth(codepoint);
    if (base == 1 and ambiguous_wide and isWideRenderSymbol(codepoint)) return 2;
    return base;
}

/// 0폭 결합 문자인가 — Unicode 일반 범주 **Mn(Nonspacing_Mark)·Me(Enclosing_Mark) 전부**.
///
/// **왜 전부인가.** 셸·tmux·앱은 자기 `wcwidth` 로 커서를 세고, 그 사실상 표준은 Mn·Me 를 0폭으로 센다
/// (UAX #11 §6.2: «nonspacing marks do not possess actual advance width»). 우리가 하나라도 폭 1로 세면 그
/// 결합 문자가 **자기 셀**을 차지해 뒤 칸이 전부 밀린다. 예전 표는 몇 블록(U+0300–036F 등)뿐이었고, 실측
/// (2026-10-09)으로 그 구멍이 드러났다 — kitty unicode placeholder 의 행·열 좌표 결합문자 297개
/// (`terminal/kitty_placeholder.zig`, 전부 Mn) 중 30번(U+0483)부터 214개가 폭 1이 되어, tmux 안
/// terminal-browser 화면이 왼쪽 위 30×30 만 그림이 되고 나머지는 줄무늬·결합문자 격자가 됐다.
///
/// 표는 Unicode 18.0.0 `UnicodeData.txt` 의 Mn·Me 를 이어 붙인 구간이다. 예전 표의 구간(1AB0–1AFF·
/// 1DC0–1DFF·20D0–20FF·FE20–FE2F 블록 전체, 변형 선택자 FE00–FE0F)은 미할당 칸까지 그대로 합쳐 두었다 —
/// 0폭이던 것이 폭 1로 돌아가는 회귀가 없게.
///
/// **Mc(Spacing_Mark)는 넣지 않는다.** 이름 그대로 폭을 갖는 결합 부호이고 `wcwidth` 도 대개 1로 센다.
/// NFD 한글 중성·종성(U+1161–11FF)은 Lo 라 여기 해당이 없다 — 그것들은 `grapheme.isConjoiningJamo` 가
/// 따로 묶는다.
///
/// CJK wide 블록 안의 결합 부호(U+302A–302F, U+3099–309A)도 이 표에 있으므로 `cellWidth` 가 이것을
/// `isWideCodepoint` 보다 먼저 묻는 순서를 지켜야 한다 — 거꾸로면 0폭 결합 부호가 2칸이 된다.
/// 변형 선택자(VS16 U+FE0F)는 앞 글자를 이모지 표현으로 만들어 base+VS16 이 한 셀로 셰이퍼에 간다
/// (❤+VS16=❤️) — 별도 셀이면 base 만 텍스트 폰트로 단색이 된다.
pub fn isCombiningMark(codepoint: u21) bool {
    if (codepoint < combining_ranges[0][0]) return false; // ASCII·라틴 기본은 표를 안 탄다(핫 경로)
    // 결합 부호가 하나도 없는 넓은 구간(CJK·한글 음절·이모지)도 표를 안 탄다. 실측(ReleaseFast): 이게
    // 없으면 한글 출력에서 `cellWidth` 가 글자당 2.7 ns → 8.1 ns 로 세 배가 됐다.
    for (no_mark_spans) |s| {
        if (codepoint >= s[0] and codepoint <= s[1]) return false;
    }
    // 이진 탐색: 셀마다 불리는 함수라 364 구간을 선형으로 훑지 않는다(9 비교).
    var lo: usize = 0;
    var hi: usize = combining_ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = combining_ranges[mid];
        if (codepoint < r[0]) {
            hi = mid;
        } else if (codepoint > r[1]) {
            lo = mid + 1;
        } else return true;
    }
    return false;
}

/// 결합 부호가 **하나도 없는** 구간 — `isCombiningMark` 의 빠른 거절. 각각 CJK 통합 한자·가나 뒤쪽
/// (U+309B–A66E), 한글 음절을 담은 구간(U+ABEE–FB1D), 이모지·기호 평면(U+1E94B–E00FF)이다.
/// 표와 겹치면 결합 부호를 놓치므로 아래 comptime 이 «어느 구간과도 안 겹친다»를 지킨다.
const no_mark_spans = [_][2]u21{ .{ 0x309B, 0xA66E }, .{ 0xABEE, 0xFB1D }, .{ 0x1E94B, 0xE00FF } };

/// Mn·Me 구간표(Unicode 18.0.0) — `isCombiningMark` 머리말 참조. 오름차순·겹침 없음은 아래 comptime 이 지킨다.
const combining_ranges = [_][2]u21{
    .{ 0x300, 0x36F },     .{ 0x483, 0x489 },     .{ 0x591, 0x5BD },     .{ 0x5BF, 0x5BF },     .{ 0x5C1, 0x5C2 },     .{ 0x5C4, 0x5C5 },
    .{ 0x5C7, 0x5C9 },     .{ 0x610, 0x61A },     .{ 0x64B, 0x65F },     .{ 0x670, 0x670 },     .{ 0x6D6, 0x6DC },     .{ 0x6DF, 0x6E4 },
    .{ 0x6E7, 0x6E8 },     .{ 0x6EA, 0x6ED },     .{ 0x711, 0x711 },     .{ 0x730, 0x74A },     .{ 0x7A6, 0x7B0 },     .{ 0x7EB, 0x7F3 },
    .{ 0x7FD, 0x7FD },     .{ 0x816, 0x819 },     .{ 0x81B, 0x823 },     .{ 0x825, 0x827 },     .{ 0x829, 0x82D },     .{ 0x859, 0x85B },
    .{ 0x897, 0x89F },     .{ 0x8CA, 0x8E1 },     .{ 0x8E3, 0x902 },     .{ 0x93A, 0x93A },     .{ 0x93C, 0x93C },     .{ 0x941, 0x948 },
    .{ 0x94D, 0x94D },     .{ 0x951, 0x957 },     .{ 0x962, 0x963 },     .{ 0x981, 0x981 },     .{ 0x9BC, 0x9BC },     .{ 0x9C1, 0x9C4 },
    .{ 0x9CD, 0x9CD },     .{ 0x9E2, 0x9E3 },     .{ 0x9FE, 0x9FE },     .{ 0xA01, 0xA02 },     .{ 0xA3C, 0xA3C },     .{ 0xA41, 0xA42 },
    .{ 0xA47, 0xA48 },     .{ 0xA4B, 0xA4D },     .{ 0xA51, 0xA51 },     .{ 0xA70, 0xA71 },     .{ 0xA75, 0xA75 },     .{ 0xA81, 0xA82 },
    .{ 0xABC, 0xABC },     .{ 0xAC1, 0xAC5 },     .{ 0xAC7, 0xAC8 },     .{ 0xACD, 0xACD },     .{ 0xAE2, 0xAE3 },     .{ 0xAFA, 0xAFF },
    .{ 0xB01, 0xB01 },     .{ 0xB3C, 0xB3C },     .{ 0xB3F, 0xB3F },     .{ 0xB41, 0xB44 },     .{ 0xB4D, 0xB4D },     .{ 0xB53, 0xB56 },
    .{ 0xB62, 0xB63 },     .{ 0xB82, 0xB82 },     .{ 0xBC0, 0xBC0 },     .{ 0xBCD, 0xBCD },     .{ 0xC00, 0xC00 },     .{ 0xC04, 0xC04 },
    .{ 0xC3C, 0xC3C },     .{ 0xC3E, 0xC40 },     .{ 0xC46, 0xC48 },     .{ 0xC4A, 0xC4D },     .{ 0xC55, 0xC56 },     .{ 0xC62, 0xC63 },
    .{ 0xC81, 0xC81 },     .{ 0xCBC, 0xCBC },     .{ 0xCBF, 0xCBF },     .{ 0xCC6, 0xCC6 },     .{ 0xCCC, 0xCCD },     .{ 0xCE2, 0xCE3 },
    .{ 0xD00, 0xD01 },     .{ 0xD3B, 0xD3C },     .{ 0xD41, 0xD44 },     .{ 0xD4D, 0xD4D },     .{ 0xD62, 0xD63 },     .{ 0xD81, 0xD81 },
    .{ 0xDCA, 0xDCA },     .{ 0xDD2, 0xDD4 },     .{ 0xDD6, 0xDD6 },     .{ 0xE31, 0xE31 },     .{ 0xE34, 0xE3A },     .{ 0xE47, 0xE4E },
    .{ 0xEB1, 0xEB1 },     .{ 0xEB4, 0xEBC },     .{ 0xEC8, 0xECE },     .{ 0xF18, 0xF19 },     .{ 0xF35, 0xF35 },     .{ 0xF37, 0xF37 },
    .{ 0xF39, 0xF39 },     .{ 0xF71, 0xF7E },     .{ 0xF80, 0xF84 },     .{ 0xF86, 0xF87 },     .{ 0xF8D, 0xF97 },     .{ 0xF99, 0xFBC },
    .{ 0xFC6, 0xFC6 },     .{ 0x102D, 0x1030 },   .{ 0x1032, 0x1037 },   .{ 0x1039, 0x103A },   .{ 0x103D, 0x103E },   .{ 0x1058, 0x1059 },
    .{ 0x105E, 0x1060 },   .{ 0x1071, 0x1074 },   .{ 0x1082, 0x1082 },   .{ 0x1085, 0x1086 },   .{ 0x108D, 0x108D },   .{ 0x109D, 0x109D },
    .{ 0x135D, 0x135F },   .{ 0x1712, 0x1714 },   .{ 0x1732, 0x1733 },   .{ 0x1752, 0x1753 },   .{ 0x1772, 0x1773 },   .{ 0x17B4, 0x17B5 },
    .{ 0x17B7, 0x17BD },   .{ 0x17C6, 0x17C6 },   .{ 0x17C9, 0x17D3 },   .{ 0x17DD, 0x17DD },   .{ 0x180B, 0x180D },   .{ 0x180F, 0x180F },
    .{ 0x1885, 0x1886 },   .{ 0x18A9, 0x18A9 },   .{ 0x1920, 0x1922 },   .{ 0x1927, 0x1928 },   .{ 0x1932, 0x1932 },   .{ 0x1939, 0x193B },
    .{ 0x1A17, 0x1A18 },   .{ 0x1A1B, 0x1A1B },   .{ 0x1A56, 0x1A56 },   .{ 0x1A58, 0x1A5E },   .{ 0x1A60, 0x1A60 },   .{ 0x1A62, 0x1A62 },
    .{ 0x1A65, 0x1A6C },   .{ 0x1A73, 0x1A7C },   .{ 0x1A7F, 0x1A7F },   .{ 0x1AB0, 0x1B03 },   .{ 0x1B34, 0x1B34 },   .{ 0x1B36, 0x1B3A },
    .{ 0x1B3C, 0x1B3C },   .{ 0x1B42, 0x1B42 },   .{ 0x1B6B, 0x1B73 },   .{ 0x1B80, 0x1B81 },   .{ 0x1BA2, 0x1BA5 },   .{ 0x1BA8, 0x1BA9 },
    .{ 0x1BAB, 0x1BAD },   .{ 0x1BE6, 0x1BE6 },   .{ 0x1BE8, 0x1BE9 },   .{ 0x1BED, 0x1BED },   .{ 0x1BEF, 0x1BF1 },   .{ 0x1C2C, 0x1C33 },
    .{ 0x1C36, 0x1C37 },   .{ 0x1CD0, 0x1CD2 },   .{ 0x1CD4, 0x1CE0 },   .{ 0x1CE2, 0x1CE8 },   .{ 0x1CED, 0x1CED },   .{ 0x1CF4, 0x1CF4 },
    .{ 0x1CF8, 0x1CF9 },   .{ 0x1DC0, 0x1DFF },   .{ 0x20D0, 0x20FF },   .{ 0x2CEF, 0x2CF1 },   .{ 0x2D7F, 0x2D7F },   .{ 0x2DE0, 0x2DFF },
    .{ 0x302A, 0x302F },   .{ 0x3099, 0x309A },   .{ 0xA66F, 0xA672 },   .{ 0xA674, 0xA67D },   .{ 0xA69E, 0xA69F },   .{ 0xA6F0, 0xA6F1 },
    .{ 0xA802, 0xA802 },   .{ 0xA806, 0xA806 },   .{ 0xA80B, 0xA80B },   .{ 0xA825, 0xA826 },   .{ 0xA82C, 0xA82C },   .{ 0xA8C4, 0xA8C5 },
    .{ 0xA8E0, 0xA8F1 },   .{ 0xA8FF, 0xA8FF },   .{ 0xA926, 0xA92D },   .{ 0xA947, 0xA951 },   .{ 0xA980, 0xA982 },   .{ 0xA9B3, 0xA9B3 },
    .{ 0xA9B6, 0xA9B9 },   .{ 0xA9BC, 0xA9BD },   .{ 0xA9E5, 0xA9E5 },   .{ 0xAA29, 0xAA2E },   .{ 0xAA31, 0xAA32 },   .{ 0xAA35, 0xAA36 },
    .{ 0xAA43, 0xAA43 },   .{ 0xAA4C, 0xAA4C },   .{ 0xAA7C, 0xAA7C },   .{ 0xAAB0, 0xAAB0 },   .{ 0xAAB2, 0xAAB4 },   .{ 0xAAB7, 0xAAB8 },
    .{ 0xAABE, 0xAABF },   .{ 0xAAC1, 0xAAC1 },   .{ 0xAAEC, 0xAAED },   .{ 0xAAF6, 0xAAF6 },   .{ 0xABE5, 0xABE5 },   .{ 0xABE8, 0xABE8 },
    .{ 0xABED, 0xABED },   .{ 0xFB1E, 0xFB1E },   .{ 0xFE00, 0xFE0F },   .{ 0xFE20, 0xFE2F },   .{ 0x101FD, 0x101FD }, .{ 0x102E0, 0x102E0 },
    .{ 0x10376, 0x1037A }, .{ 0x10A01, 0x10A03 }, .{ 0x10A05, 0x10A06 }, .{ 0x10A0C, 0x10A0F }, .{ 0x10A38, 0x10A3A }, .{ 0x10A3F, 0x10A3F },
    .{ 0x10AE5, 0x10AE6 }, .{ 0x10D24, 0x10D27 }, .{ 0x10D69, 0x10D6D }, .{ 0x10EAB, 0x10EAC }, .{ 0x10ECB, 0x10ECF }, .{ 0x10EF0, 0x10EFF },
    .{ 0x10F46, 0x10F50 }, .{ 0x10F82, 0x10F85 }, .{ 0x11001, 0x11001 }, .{ 0x11038, 0x11046 }, .{ 0x11070, 0x11070 }, .{ 0x11073, 0x11074 },
    .{ 0x1107F, 0x11081 }, .{ 0x110B3, 0x110B6 }, .{ 0x110B9, 0x110BA }, .{ 0x110C2, 0x110C2 }, .{ 0x11100, 0x11102 }, .{ 0x11127, 0x1112B },
    .{ 0x1112D, 0x11134 }, .{ 0x11173, 0x11173 }, .{ 0x11180, 0x11181 }, .{ 0x111B6, 0x111BE }, .{ 0x111C9, 0x111CC }, .{ 0x111CF, 0x111CF },
    .{ 0x1122F, 0x11231 }, .{ 0x11234, 0x11234 }, .{ 0x11236, 0x11237 }, .{ 0x1123E, 0x1123E }, .{ 0x11241, 0x11241 }, .{ 0x112DF, 0x112DF },
    .{ 0x112E3, 0x112EA }, .{ 0x11300, 0x11301 }, .{ 0x1133B, 0x1133C }, .{ 0x11340, 0x11340 }, .{ 0x11366, 0x1136C }, .{ 0x11370, 0x11374 },
    .{ 0x113BB, 0x113C0 }, .{ 0x113CE, 0x113CE }, .{ 0x113D0, 0x113D0 }, .{ 0x113D2, 0x113D2 }, .{ 0x113E1, 0x113E2 }, .{ 0x11438, 0x1143F },
    .{ 0x11442, 0x11444 }, .{ 0x11446, 0x11446 }, .{ 0x1145E, 0x1145E }, .{ 0x114B3, 0x114B8 }, .{ 0x114BA, 0x114BA }, .{ 0x114BF, 0x114C0 },
    .{ 0x114C2, 0x114C3 }, .{ 0x115B2, 0x115B5 }, .{ 0x115BC, 0x115BD }, .{ 0x115BF, 0x115C0 }, .{ 0x115DC, 0x115DD }, .{ 0x11633, 0x1163A },
    .{ 0x1163D, 0x1163D }, .{ 0x1163F, 0x11640 }, .{ 0x116AB, 0x116AB }, .{ 0x116AD, 0x116AD }, .{ 0x116B0, 0x116B5 }, .{ 0x116B7, 0x116B7 },
    .{ 0x1171D, 0x1171D }, .{ 0x1171F, 0x1171F }, .{ 0x11722, 0x11725 }, .{ 0x11727, 0x1172B }, .{ 0x1182F, 0x11837 }, .{ 0x11839, 0x1183A },
    .{ 0x1193B, 0x1193C }, .{ 0x1193E, 0x1193E }, .{ 0x11943, 0x11943 }, .{ 0x119D4, 0x119D7 }, .{ 0x119DA, 0x119DB }, .{ 0x119E0, 0x119E0 },
    .{ 0x11A01, 0x11A0A }, .{ 0x11A33, 0x11A38 }, .{ 0x11A3B, 0x11A3E }, .{ 0x11A47, 0x11A47 }, .{ 0x11A51, 0x11A56 }, .{ 0x11A59, 0x11A5B },
    .{ 0x11A8A, 0x11A96 }, .{ 0x11A98, 0x11A99 }, .{ 0x11B60, 0x11B60 }, .{ 0x11B62, 0x11B64 }, .{ 0x11B66, 0x11B66 }, .{ 0x11C30, 0x11C36 },
    .{ 0x11C38, 0x11C3D }, .{ 0x11C3F, 0x11C3F }, .{ 0x11C92, 0x11CA7 }, .{ 0x11CAA, 0x11CB0 }, .{ 0x11CB2, 0x11CB3 }, .{ 0x11CB5, 0x11CB6 },
    .{ 0x11D31, 0x11D36 }, .{ 0x11D3A, 0x11D3A }, .{ 0x11D3C, 0x11D3D }, .{ 0x11D3F, 0x11D45 }, .{ 0x11D47, 0x11D47 }, .{ 0x11D90, 0x11D91 },
    .{ 0x11D95, 0x11D95 }, .{ 0x11D97, 0x11D97 }, .{ 0x11DF0, 0x11DF0 }, .{ 0x11EF3, 0x11EF4 }, .{ 0x11F00, 0x11F01 }, .{ 0x11F36, 0x11F3A },
    .{ 0x11F40, 0x11F40 }, .{ 0x11F42, 0x11F42 }, .{ 0x11F5A, 0x11F5A }, .{ 0x13440, 0x13440 }, .{ 0x13447, 0x13455 }, .{ 0x1611E, 0x16129 },
    .{ 0x1612D, 0x1612F }, .{ 0x16AF0, 0x16AF4 }, .{ 0x16B30, 0x16B36 }, .{ 0x16F4F, 0x16F4F }, .{ 0x16F8F, 0x16F92 }, .{ 0x16FE4, 0x16FE4 },
    .{ 0x1BC9D, 0x1BC9E }, .{ 0x1CF00, 0x1CF2D }, .{ 0x1CF30, 0x1CF46 }, .{ 0x1D127, 0x1D128 }, .{ 0x1D167, 0x1D169 }, .{ 0x1D17B, 0x1D182 },
    .{ 0x1D185, 0x1D18B }, .{ 0x1D1AA, 0x1D1AD }, .{ 0x1D242, 0x1D244 }, .{ 0x1D25B, 0x1D25C }, .{ 0x1DA00, 0x1DA36 }, .{ 0x1DA3B, 0x1DA6C },
    .{ 0x1DA75, 0x1DA75 }, .{ 0x1DA84, 0x1DA84 }, .{ 0x1DA9B, 0x1DA9F }, .{ 0x1DAA1, 0x1DAAF }, .{ 0x1E000, 0x1E006 }, .{ 0x1E008, 0x1E018 },
    .{ 0x1E01B, 0x1E021 }, .{ 0x1E023, 0x1E024 }, .{ 0x1E026, 0x1E02A }, .{ 0x1E08F, 0x1E08F }, .{ 0x1E130, 0x1E136 }, .{ 0x1E2AE, 0x1E2AE },
    .{ 0x1E2EC, 0x1E2EF }, .{ 0x1E4EC, 0x1E4EF }, .{ 0x1E5EE, 0x1E5EF }, .{ 0x1E6E3, 0x1E6E3 }, .{ 0x1E6E6, 0x1E6E6 }, .{ 0x1E6EE, 0x1E6EF },
    .{ 0x1E6F5, 0x1E6F5 }, .{ 0x1E8D0, 0x1E8D6 }, .{ 0x1E944, 0x1E94A }, .{ 0xE0100, 0xE01EF },
};

comptime {
    // 이진 탐색의 전제: 구간마다 시작 ≤ 끝, 구간끼리 오름차순이고 겹치지도 붙지도 않는다(붙으면 생성이 덜 합친 것).
    @setEvalBranchQuota(10_000);
    for (combining_ranges, 0..) |r, i| {
        if (r[0] > r[1]) @compileError("combining_ranges: start > end");
        if (i > 0 and r[0] <= combining_ranges[i - 1][1] + 1) @compileError("combining_ranges must be strictly ascending and merged");
        for (no_mark_spans) |s| {
            if (r[0] <= s[1] and r[1] >= s[0]) @compileError("no_mark_spans overlaps a combining range");
        }
    }
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

test "cellWidthAmbiguous: ambiguous symbols widen only when ambiguous_wide is set" {
    // narrow(기본): 동그란 번호는 1칸(cellWidth와 동일).
    try std.testing.expectEqual(@as(u2, 1), cellWidthAmbiguous(0x2462, false)); // ③
    try std.testing.expectEqual(@as(u2, 1), cellWidthAmbiguous(0x2460, false)); // ①
    // wide: isWideRenderSymbol(동그란/괄호친 영숫자)만 2칸으로.
    try std.testing.expectEqual(@as(u2, 2), cellWidthAmbiguous(0x2462, true)); // ③ → 2
    try std.testing.expectEqual(@as(u2, 2), cellWidthAmbiguous(0x24FF, true)); // 범위 끝
    // wide여도 일반 ASCII·이미 wide·combining은 안 바뀐다(1→2만 대상).
    try std.testing.expectEqual(@as(u2, 1), cellWidthAmbiguous('A', true));
    try std.testing.expectEqual(@as(u2, 2), cellWidthAmbiguous('한', true)); // 이미 2
    try std.testing.expectEqual(@as(u2, 0), cellWidthAmbiguous(0x0301, true)); // combining(0 유지)
    try std.testing.expectEqual(@as(u2, 1), cellWidthAmbiguous(0x2500, true)); // box-drawing은 isWideRenderSymbol 밖 → 1 유지
}

test "isWideRenderSymbol: cover-fit 게이트 정책 — 텍스트 제외, enclosed alnum만" {
    // 래스터 cover-fit(종횡비 축소 + ink-center)은 이 집합에만 적용된다(docs/glyph-role-render-model.md).
    // 일반 텍스트는 ink가 advance를 미세하게 넘어도(Hack 'w'=ink폭==advance) cover-fit 대상이 아니라
    // 자연 메트릭+baseline으로 둔다 — 안 그러면 descender 없는 'w'가 ink-center로 위로 떴다.
    try std.testing.expect(!isWideRenderSymbol('w')); // 회귀의 핵심: 'w'는 절대 cover-fit 안 됨
    try std.testing.expect(!isWideRenderSymbol('m'));
    try std.testing.expect(!isWideRenderSymbol('A'));
    try std.testing.expect(!isWideRenderSymbol('0'));
    try std.testing.expect(!isWideRenderSymbol('@'));
    try std.testing.expect(!isWideRenderSymbol('한')); // CJK/한글도 텍스트(자연+baseline)
    try std.testing.expect(!isWideRenderSymbol(0x2500)); // box-drawing은 합성 경로(glyph_id==0)
    try std.testing.expect(!isWideRenderSymbol(0x25C6)); // ◆ geometric — wide-render-symbol 밖(자연/클립)
    // Enclosed Alphanumerics(폰트가 ~2칸으로 그림)는 cover-fit 대상.
    try std.testing.expect(isWideRenderSymbol(0x2460)); // ①
    try std.testing.expect(isWideRenderSymbol(0x2462)); // ③
    try std.testing.expect(isWideRenderSymbol(0x24FF)); // 범위 끝
}

test "cellWidth treats Hangul and CJK as double-cell" {
    try std.testing.expectEqual(@as(u2, 2), cellWidth('한'));
    try std.testing.expectEqual(@as(u2, 2), cellWidth('界'));
}

test "cellWidth treats combining marks as zero-cell" {
    try std.testing.expectEqual(@as(u2, 0), cellWidth(0x0301));
}

test "cellWidth: Mn·Me 는 블록과 상관없이 0폭이고, 바로 옆 비결합 문자와 Mc 는 1폭이다" {
    // 예전 표가 몰랐던 블록들 — 구간 **양끝**과 그 **바깥 이웃**을 함께 잰다. 끝만 재면 구간이 한 칸 짧거나
    // 길어도 통과하고, 이진 탐색의 경계 비교(`<` 와 `>`)가 하나 틀려도 통과한다.
    const zero = [_]u21{
        0x0300, // COMBINING GRAVE ACCENT — 표의 첫 칸. 빠른 거절이 `<` 가 아니라 `<=` 로 새면 여기서만 드러난다(변이로 확인)
        0x0483, // COMBINING CYRILLIC TITLO — kitty placeholder 좌표표의 30번, 예전 표의 첫 구멍
        0x0489, // COMBINING CYRILLIC MILLIONS SIGN (Me)
        0x0591, 0x05BD, // 히브리 악센트
        0x0610, 0x061A, // 아랍
        0x0E31, // THAI CHARACTER MAI HAN-AKAT
        0x20DD, // COMBINING ENCLOSING CIRCLE (Me)
        0x1D185, 0x1D244, // 음악 기호 결합 부호 — kitty 좌표표의 끝자락
        0xE0100, 0xE01EF, // 변형 선택자 보충(VS17–VS256)
    };
    for (zero) |cp| try std.testing.expectEqual(@as(u2, 0), cellWidth(cp));
    const one = [_]u21{
        0x0482, // CYRILLIC THOUSANDS SIGN (So) — 0483 의 바로 앞
        0x048A, // 0489 의 바로 뒤
        0x05BE, // HEBREW PUNCTUATION MAQAF (Pd) — 두 Mn 구간 사이
        0x0903, // DEVANAGARI SIGN VISARGA (Mc) — 폭을 갖는 결합 부호는 넣지 않는다
        0x1161, // HANGUL JUNGSEONG A (Lo) — NFD 한글 중성은 grapheme 경로가 따로 묶는다
        0xE01F0, // 마지막 구간 바로 뒤
    };
    for (one) |cp| try std.testing.expectEqual(@as(u2, 1), cellWidth(cp));
    try std.testing.expectEqual(@as(u2, 1), cellWidth(0x02FF)); // 첫 구간 바로 앞(빠른 거절 경로)
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

/// `bytes`를 최대 `max` 바이트로 자르되 **UTF-8 codepoint 경계**에서 자른 길이를 돌려준다. 멀티바이트가 max 중간에서
/// 쪼개지면 그 codepoint의 시작(lead 바이트)까지 후퇴한다(continuation 0x80~0xBF 앞). `bytes.len <= max`면 그대로.
/// 잘린 멀티바이트(무효 UTF-8)가 소비자의 Utf8View/렌더/backspace를 깨뜨리는 걸 막는 **단일 출처** — terminal·session·
/// chrome·platform이 고정 버퍼에 문자열을 담을 때 공유한다(F2-8·리뷰 #823 등 4중복 통합). 반환은 항상 ≤ max.
pub fn truncateToBoundary(bytes: []const u8, max: usize) usize {
    var n = @min(bytes.len, max);
    if (n == bytes.len) return n; // 안 잘림 — 보정 불필요(bytes[n] 인덱스 안 함)
    while (n > 0 and (bytes[n] & 0xC0) == 0x80) : (n -= 1) {}
    return n;
}

/// `bytes`의 **마지막 최대 `max` 바이트**를 담는 tail의 **시작 오프셋**을 UTF-8 codepoint 경계에서 돌려준다(head를 버림).
/// `truncateToBoundary`(head 보존, 끝 오프셋)의 대칭 — 반환 오프셋부터 `bytes` 끝까지가 항상 ≤ max 바이트이고 lead
/// 바이트에서 시작한다(잘린 지점이 continuation 0x80~0xBF면 앞으로 되감음). 초장문 편집(주소창 URL 등)에서 caret이 있는
/// **끝**을 고정 버퍼에 보이게 하는 단일 출처. `bytes.len <= max`면 0(통째). 반환은 항상 ≤ bytes.len.
pub fn tailToBoundary(bytes: []const u8, max: usize) usize {
    if (bytes.len <= max) return 0; // 안 넘침 — head부터 통째
    var start = bytes.len - max;
    while (start < bytes.len and (bytes[start] & 0xC0) == 0x80) : (start += 1) {} // continuation면 다음 lead까지 전진
    return start;
}

/// `bytes[0..len]`에서 **마지막 codepoint 한 개**를 뺀 길이를 돌려준다(백스페이스 — UTF-8 경계). `len==0`이면 0.
/// 마지막 바이트부터 continuation(0x80~0xBF)을 lead까지 건너뛴다. 백스페이스가 멀티바이트를 한 바이트씩 깨는 걸 막는
/// 단일 출처(검색·인라인 편집 버퍼 공유). `len`은 `bytes`의 유효 길이(≤ bytes.len)여야 한다.
pub fn dropLastCodepoint(bytes: []const u8, len: usize) usize {
    if (len == 0) return 0;
    var i = len - 1;
    while (i > 0 and (bytes[i] & 0xC0) == 0x80) : (i -= 1) {}
    return i;
}

test "truncateToBoundary: codepoint 경계에서 자른다(멀티바이트 중간 안 끊김)" {
    try std.testing.expectEqual(@as(usize, 3), truncateToBoundary("abc", 64)); // 상한 이하 — 그대로
    try std.testing.expectEqual(@as(usize, 4), truncateToBoundary("abcd", 4)); // 딱 상한 — 그대로
    // "a가" = 61 EA B0 80. max=2: bytes[2]=B0 continuation→후퇴 n=1('a'만).
    try std.testing.expectEqual(@as(usize, 1), truncateToBoundary("a가", 2));
    try std.testing.expectEqual(@as(usize, 1), truncateToBoundary("a가", 3)); // bytes[3]=80→…→n=1
    try std.testing.expectEqual(@as(usize, 4), truncateToBoundary("a가", 4)); // 전체
    // "가나" = EA B0 80 EB 82 98. max=4: bytes[4]=82 continuation→후퇴 n=3('가'만).
    try std.testing.expectEqual(@as(usize, 3), truncateToBoundary("가나", 4));
    // max=0·빈 입력 안전.
    try std.testing.expectEqual(@as(usize, 0), truncateToBoundary("가", 0));
    try std.testing.expectEqual(@as(usize, 0), truncateToBoundary("", 5));
    // 큰 max(>255)에서도 usize 반환이라 overflow 없음.
    try std.testing.expectEqual(@as(usize, 2), truncateToBoundary("ab", 1000));
}

test "tailToBoundary: 끝에서 max 바이트를 UTF-8 경계로 자른 tail 시작 오프셋" {
    try std.testing.expectEqual(@as(usize, 0), tailToBoundary("abc", 64)); // 상한 이하 — 통째(오프셋 0)
    try std.testing.expectEqual(@as(usize, 0), tailToBoundary("abcd", 4)); // 딱 상한 — 통째
    try std.testing.expectEqual(@as(usize, 1), tailToBoundary("abcd", 3)); // 마지막 3바이트 "bcd"
    // "a가" = 61 EA B0 80(len 4). max=2: start=2(B0=continuation)→3(80)→4(끝) → tail="" (경계 못 맞추면 빈 tail, caret만 보임).
    try std.testing.expectEqual(@as(usize, 4), tailToBoundary("a가", 2));
    try std.testing.expectEqual(@as(usize, 1), tailToBoundary("a가", 3)); // start=1(EA lead) → "가"(3바이트) 통째
    try std.testing.expectEqual(@as(usize, 0), tailToBoundary("a가", 4)); // len==max → 통째(오프셋 0)
    // "가나" = EA B0 80 EB 82 98(len 6). max=3: start=3(EB=lead)→ "나"(3바이트) 통째.
    try std.testing.expectEqual(@as(usize, 3), tailToBoundary("가나", 3));
    // max=4: start=2(80 continuation)→3(EB lead) → "나"(3바이트, ≤4). '가' 중간서 안 쪼갬.
    try std.testing.expectEqual(@as(usize, 3), tailToBoundary("가나", 4));
    // max=0·빈 입력 안전(오프셋이 끝/0).
    try std.testing.expectEqual(@as(usize, 3), tailToBoundary("가", 0)); // start=len=3(끝) → 빈 tail
    try std.testing.expectEqual(@as(usize, 0), tailToBoundary("", 5));
}

test "dropLastCodepoint: 마지막 codepoint 한 개 제거(UTF-8 경계)" {
    try std.testing.expectEqual(@as(usize, 2), dropLastCodepoint("abc", 3)); // 'c' 제거
    try std.testing.expectEqual(@as(usize, 0), dropLastCodepoint("a", 1)); // 마지막 하나
    try std.testing.expectEqual(@as(usize, 0), dropLastCodepoint("abc", 0)); // 빈 길이
    // "a가" 길이 4 → '가'(3바이트) 통째 제거 → 1.
    try std.testing.expectEqual(@as(usize, 1), dropLastCodepoint("a가", 4));
    // "가" 길이 3 → 통째 제거 → 0.
    try std.testing.expectEqual(@as(usize, 0), dropLastCodepoint("가", 3));
}
