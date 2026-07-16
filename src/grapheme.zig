//! 한글 grapheme cluster 분절 — NFD(분해형) conjoining 자모를 한 음절로 묶는 규칙.
//!
//! 왜 필요한가: macOS 파일시스템은 파일명을 NFD로 저장하므로, `ls`가 한글을 conjoining
//! 자모(초성 L + 중성 V + 종성 T, U+1100~U+11FF)로 그대로 출력한다. 이 자모들을 하나의
//! grapheme cluster로 묶지 못하면 자모가 셀마다 흩어져 분리돼 보이고, 폭도 음절당 2배가
//! 된다(초성만 wide=2, 중성·종성은 1칸으로 잡혀 "한글"이 4칸이 아니라 8칸).
//!
//! 베이스 = UAX#29(Unicode Text Segmentation) Grapheme Cluster Boundary 규칙에서 독립
//! 유도한다(clean-room — 레퍼런스 터미널의 코드/자료구조를 옮기지 않는다). 이 파일은 순수
//! 함수만 두어 저장·렌더와 무관하게 단위 테스트로 닫힌다(HG1). 코어 print 경로 통합과 셀
//! 다중 코드포인트 저장은 HG2에서 한다. 설계 단일 출처: docs/grapheme-clustering.md.
//!
//! **위상**: `width.zig`와 같은 **최상위 레이어-무관 중립 유틸**이다(의존은 width.zig+std뿐).
//! terminal(코어 print)·chrome(주소창 TextField caret 그래핌 스냅, docs/text-field-editor.md)이
//! 공유한다 — chrome은 terminal을 import할 수 없으므로(tests/boundary/imports.zig) 순수 Unicode
//! 분절을 여기 최상위 중립에 둔다. terminal/에서 승격(원래 위치는 terminal/grapheme.zig).

const std = @import("std");
const width = @import("width.zig"); // EAW 셀 폭·combining 판정을 단일 출처로 재사용

/// UAX#29 Hangul_Syllable_Type. NFD 자모(conjoining)와 완성형(precomposed) 음절을 분류해
/// 아래 GB6/GB7/GB8 cluster 규칙의 입력으로 쓴다.
pub const JamoClass = enum { none, L, V, T, LV, LVT };

/// 코드포인트의 Hangul_Syllable_Type을 범위로 판정한다. 현대 자모뿐 아니라 옛한글·filler까지
/// conjoining 블록 전체를 포함해, 첫가끝(옛한글)도 같은 cluster 규칙을 타게 한다.
pub fn hangulClass(cp: u21) JamoClass {
    return switch (cp) {
        // conjoining 자모(NFD). U+1100~1112(현대 초성) + 옛 초성 + U+115F(초성 filler) 등.
        0x1100...0x115F => .L, // 초성(leading consonant)
        0x1160...0x11A7 => .V, // 중성(vowel) — U+1160(중성 filler) 포함
        0x11A8...0x11FF => .T, // 종성(trailing consonant)
        // 완성형 음절(U+AC00~U+D7A3). 한글 음절 = ((초성*21)+중성)*28 + 종성이라, 28로 나눈
        // 나머지가 0이면 종성이 없는 LV, 아니면 종성이 있는 LVT다.
        0xAC00...0xD7A3 => if ((cp - 0xAC00) % 28 == 0) .LV else .LVT,
        else => .none,
    };
}

/// combining mark·ZWJ인가 — UAX#29 GB9(× (Extend | ZWJ))에 해당한다. 어떤 base 뒤든 앞
/// cluster에 붙는다(잘리면 클립보드·재출력까지 손실되는 결합 시퀀스의 핵심). Extend 판정은
/// width.isCombiningMark을 단일 출처로 재사용하고 ZWJ(U+200D)를 더한다.
pub fn isExtendOrZwj(cp: u21) bool {
    return cp == 0x200D or width.isCombiningMark(cp);
}

/// prev 다음에 next가 올 때 **같은 grapheme cluster로 이어지는가**(= cluster boundary가 없는가)?
/// UAX#29 중 한글 연쇄(GB6/GB7/GB8)와 결합 문자(GB9)만 구현한다. 그 외 조합은 기본 boundary
/// (GB999 — 매 코드포인트가 새 cluster). emoji ZWJ 시퀀스의 그림문자 잇기(GB11)·국기 RI 쌍
/// (GB12/13)은 HG2 통합 때 기존 mode 2027 경로(skin-tone·RI)와 합친다.
pub fn extendsCluster(prev: u21, next: u21) bool {
    if (isExtendOrZwj(next)) return true; // GB9
    return switch (hangulClass(prev)) {
        .L => switch (hangulClass(next)) {
            .L, .V, .LV, .LVT => true, // GB6: L × (L | V | LV | LVT)
            else => false,
        },
        .V, .LV => switch (hangulClass(next)) {
            .V, .T => true, // GB7: (LV | V) × (V | T)
            else => false,
        },
        .T, .LVT => hangulClass(next) == .T, // GB8: (LVT | T) × T
        .none => false,
    };
}

/// grapheme cluster의 터미널 셀 폭. base(첫 코드포인트)가 폭을 정하고, 이어지는 자모·combining·
/// ZWJ는 0폭으로 흡수된다 — 그래서 NFD '한'(초성 base가 wide)도 완성형 '한'과 같은 2칸이 된다.
pub fn clusterWidth(base: u21) u2 {
    return width.cellWidth(base);
}

/// NFD conjoining 자모(U+1100~U+11FF: 초성 L·중성 V·종성 T)인가. 완성형 음절(U+AC00~)·일반
/// 문자·ZWJ는 제외한다. print 경로의 cluster 흡수는 이 범위의 글자만 대상으로 한다 — combining
/// mark(폭 0)는 이미 별도 경로가 처리하고, ZWJ(GB9)·완성형은 각자 제 셀을 차지해야 하므로, NFD
/// 자모만 0폭으로 앞 음절에 합친다(extendsCluster만으론 GB9가 ZWJ도 true라 폭≠0인 ZWJ가 새어든다).
pub fn isConjoiningJamo(cp: u21) bool {
    return cp >= 0x1100 and cp <= 0x11FF;
}

// ── 바이트 슬라이스 grapheme 경계 walk (extendsCluster 기반) ──────────────────────────────────
// UAX#29 cluster 경계를 UTF-8 바이트 슬라이스 위에서 순회하는 순수 헬퍼. 터미널(코어는 셀 그리드로 클러스터하지만
// 바이트-오프셋 caret/삭제가 필요한 소비자)과 chrome(주소창 TextField)이 공유하도록 여기 최상위 중립에 둔다.

/// `bytes[start..]`에서 시작하는 grapheme cluster 하나의 **끝 바이트 오프셋**. `start`는 cluster 경계여야 한다.
/// `start >= len`이면 len. 손상 UTF-8은 1바이트를 한 cluster로 본다(width.displayCols의 바이트 폴백과 정합).
pub fn clusterEnd(bytes: []const u8, start: usize) usize {
    if (start >= bytes.len) return bytes.len;
    const rest = bytes[start..];
    var it = (std.unicode.Utf8View.init(rest) catch return start + 1).iterator();
    var prev = it.nextCodepoint() orelse return bytes.len;
    var end_in_rest = it.i; // 첫 코드포인트 끝
    while (it.nextCodepoint()) |cp| {
        if (!extendsCluster(prev, cp)) break; // 이 cp는 다음 cluster 시작 — 소비 안 함(idx가 앞에 머묾)
        prev = cp;
        end_in_rest = it.i;
    }
    return start + end_in_rest;
}

/// `bytes`에서 `i`(cluster 경계) **직전**의 cluster 경계 바이트 오프셋. `i==0`이면 0. `i`에서 끝나는 cluster의 시작.
pub fn prevBoundary(bytes: []const u8, i: usize) usize {
    if (i == 0) return 0;
    var b: usize = 0;
    while (b < i) {
        const e = clusterEnd(bytes, b);
        if (e >= i) return b; // b에서 시작해 i에서(또는 그 뒤에서) 끝나는 cluster — b가 직전 경계
        b = e;
    }
    return b;
}

/// 임의 바이트 오프셋을 가장 가까운(내림) grapheme 경계로 스냅 — 폭 산술·단어 walk가 cluster 중간을 가리키면 보정한다.
/// offset 이하의 마지막 경계를 돌려준다.
pub fn snapToBoundary(bytes: []const u8, offset: usize) usize {
    if (offset >= bytes.len) return bytes.len;
    if (offset == 0) return 0;
    var b: usize = 0;
    while (b < bytes.len) {
        const e = clusterEnd(bytes, b);
        if (e > offset) return b; // offset이 [b, e) cluster 안 → 그 시작으로 내림
        if (e == offset) return e;
        b = e;
    }
    return b;
}

// ── Hangul NFC 조합(UAX#15 Hangul Composition — 알고리즘·테이블 불요) ────────────────────────
// conjoining 자모(NFD: L U+1100.. + V U+1161.. [+ T U+11A8..])를 완성형 음절(U+AC00..)로 합친다. 완성형/비-한글은
// 무변. 클러스터 렌더(멀티-codepoint 셀·run shaping)가 없는 소비자(주소창 emitEditBand = codepoint당 단일 셀)가
// macOS IME의 NFD 조합 자모를 합쳐 보이게 하는 데 쓴다(터미널·find는 클러스터/shaping이라 불요).

const hangul_s_base: u21 = 0xAC00;
const hangul_l_base: u21 = 0x1100;
const hangul_v_base: u21 = 0x1161;
const hangul_t_base: u21 = 0x11A7;
const hangul_l_count: u21 = 19;
const hangul_v_count: u21 = 21;
const hangul_t_count: u21 = 28;
const hangul_n_count: u21 = hangul_v_count * hangul_t_count; // 588

fn isLeadingJamo(cp: u21) bool {
    return cp >= hangul_l_base and cp < hangul_l_base + hangul_l_count; // U+1100..U+1112
}
fn isVowelJamo(cp: u21) bool {
    return cp >= hangul_v_base and cp < hangul_v_base + hangul_v_count; // U+1161..U+1175
}
fn isTrailingJamo(cp: u21) bool {
    return cp > hangul_t_base and cp < hangul_t_base + hangul_t_count; // U+11A8..U+11C2(11A7 자체는 T 없음)
}
fn isLvSyllable(cp: u21) bool { // 종성 없는 완성형(LV) — T 결합 가능
    return cp >= hangul_s_base and cp < hangul_s_base + hangul_l_count * hangul_n_count and (cp - hangul_s_base) % hangul_t_count == 0;
}

/// `bytes`의 NFD conjoining 한글 자모를 완성형으로 NFC 조합해 돌려준다(arena 소유). 조합할 게 없으면(완성형·비-한글)
/// 원본과 같은 내용. UTF-8 손상은 원본 반환. **주소창처럼 클러스터 렌더가 없는 셀 소비자용** — 저장/입력 경계에서
/// 적용해 caret 바이트 오프셋이 조합 결과와 일치하게 한다(표시-only 조합은 caret 어긋남).
pub fn composeHangul(arena: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const view = std.unicode.Utf8View.init(bytes) catch return arena.dupe(u8, bytes);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    var it = view.iterator();
    var last: ?u21 = null; // 직전에 낸(아직 flush 안 한) codepoint — 조합 후보
    while (it.nextCodepoint()) |cp| {
        if (last) |p| {
            if (isLeadingJamo(p) and isVowelJamo(cp)) { // L + V → LV 음절
                last = hangul_s_base + (p - hangul_l_base) * hangul_n_count + (cp - hangul_v_base) * hangul_t_count;
                continue;
            }
            if (isLvSyllable(p) and isTrailingJamo(cp)) { // LV + T → LVT 음절
                last = p + (cp - hangul_t_base);
                continue;
            }
            try appendCp(arena, &out, p); // 조합 불가 → 확정하고 새로 시작
        }
        last = cp;
    }
    if (last) |p| try appendCp(arena, &out, p);
    return out.toOwnedSlice(arena);
}

fn appendCp(arena: std.mem.Allocator, out: *std.ArrayList(u8), cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return; // 인코딩 불가(비정상)면 건너뛴다
    try out.appendSlice(arena, buf[0..n]);
}

/// UAX#29 GB11(이모지 ZWJ 시퀀스: `\p{Extended_Pictographic} Extend* ZWJ × \p{Extended_Pictographic}`)
/// 판정용 그림문자 근사. ZWJ로 이어지는 base가 그림문자인지, ZWJ 뒤 글자가 그림문자인지 본다.
/// width.zig "small first table" 철학대로 **흔한 이모지 블록만 큐레이션**한다 — 완전한 Extended_Pictographic
/// 속성표는 fixture로 확장한다(font-strategy.md). 동그란 번호(0x2460~24FF, isWideRenderSymbol)는
/// 그림문자가 아니라 이 범위에서 제외돼 skin-tone/ZWJ 흡수 대상이 안 된다.
pub fn isExtendedPictographic(cp: u21) bool {
    return switch (cp) {
        0x2600...0x27BF, // Misc Symbols + Dingbats (❤ U+2764·☺·✊✋✌·✨·⚧ U+26A7 …)
        0x2B00...0x2BFF, // Misc Symbols and Arrows (⭐ U+2B50·⬛⬜ …)
        0x1F000...0x1FAFF, // 주요 이모지 블록(사람·가족·역할·손·물체 — ZWJ 가족 대부분 + 스킨톤·RI)
        => true,
        else => false,
    };
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "clusterEnd/prevBoundary/snapToBoundary: 바이트 슬라이스 grapheme 경계" {
    const s = "a한b"; // 'a'(1) '한'(EA B0 80, 3바이트) 'b'(1)
    try expectEqual(@as(usize, 1), clusterEnd(s, 0)); // 'a' 끝
    try expectEqual(@as(usize, 4), clusterEnd(s, 1)); // '한'(완성형 1 cluster) 끝
    try expectEqual(@as(usize, 5), clusterEnd(s, 4)); // 'b' 끝
    try expectEqual(@as(usize, 5), clusterEnd(s, 5)); // 끝
    try expectEqual(@as(usize, 1), prevBoundary(s, 4)); // '한' 직전 경계 = 1
    try expectEqual(@as(usize, 4), prevBoundary(s, 5)); // 'b' 직전 = 4
    try expectEqual(@as(usize, 0), prevBoundary(s, 0));
    // NFD '한'(ㅎ U+1112 + ㅏ U+1161 + ㄴ U+11AB)은 한 cluster.
    const nfd = "\u{1112}\u{1161}\u{11AB}";
    try expectEqual(nfd.len, clusterEnd(nfd, 0));
    // snapToBoundary: cluster 중간(1,2,3바이트)은 '한' 시작(1)으로 내림.
    try expectEqual(@as(usize, 1), snapToBoundary(s, 2));
    try expectEqual(@as(usize, 1), snapToBoundary(s, 3));
    try expectEqual(@as(usize, 4), snapToBoundary(s, 4)); // 경계는 그대로
}

test "composeHangul: NFD conjoining 자모를 완성형 NFC로 조합(완성형·비-한글 무변)" {
    const a = std.testing.allocator;
    // NFD "가"(U+1100 초성ㄱ + U+1161 중성ㅏ) → 완성형 "가"(U+AC00).
    {
        const r = try composeHangul(a, "\u{1100}\u{1161}");
        defer a.free(r);
        try std.testing.expectEqualStrings("가", r);
    }
    // NFD "한"(U+1112 ㅎ + U+1161 ㅏ + U+11AB ㄴ) → 완성형 "한"(U+D55C, LVT).
    {
        const r = try composeHangul(a, "\u{1112}\u{1161}\u{11AB}");
        defer a.free(r);
        try std.testing.expectEqualStrings("한", r);
    }
    // NFD "가나다라" → 완성형 4음절.
    {
        const r = try composeHangul(a, "\u{1100}\u{1161}\u{1102}\u{1161}\u{1103}\u{1161}\u{1105}\u{1161}");
        defer a.free(r);
        try std.testing.expectEqualStrings("가나다라", r);
    }
    // 이미 완성형이면 무변(idempotent).
    {
        const r = try composeHangul(a, "가나다");
        defer a.free(r);
        try std.testing.expectEqualStrings("가나다", r);
    }
    // 비-한글·혼합은 자모만 조합, 나머지 그대로.
    {
        const r = try composeHangul(a, "a\u{1100}\u{1161}b");
        defer a.free(r);
        try std.testing.expectEqualStrings("a가b", r);
    }
    // 결합 안 되는 자모 시퀀스(L 없이 V, T 없이 등)는 그대로 보존.
    {
        const r = try composeHangul(a, "\u{1161}\u{1100}"); // V 다음 L — 조합 안 됨
        defer a.free(r);
        try std.testing.expectEqualStrings("\u{1161}\u{1100}", r);
    }
}

test "hangulClass: 현대 자모·완성형 음절을 L/V/T/LV/LVT로 분류" {
    // 왜 중요: macOS 파일명 NFD는 자모를 그대로 보낸다. 이 분류가 GB6/7/8로 자모를 한 음절
    // cluster로 묶는 기준이라, 틀리면 음절 경계가 어긋나 ls 한글이 깨진다.
    try expectEqual(JamoClass.L, hangulClass(0x1100)); // ㄱ 초성
    try expectEqual(JamoClass.L, hangulClass(0x1112)); // ㅎ 초성
    try expectEqual(JamoClass.V, hangulClass(0x1161)); // ㅏ 중성
    try expectEqual(JamoClass.V, hangulClass(0x1175)); // ㅣ 중성
    try expectEqual(JamoClass.T, hangulClass(0x11A8)); // ㄱ 종성
    try expectEqual(JamoClass.T, hangulClass(0x11C2)); // ㅎ 종성
    // 완성형: '가'(U+AC00)는 종성 없음=LV, '각'(U+AC01)·'한'(U+D55C)은 종성 있음=LVT.
    try expectEqual(JamoClass.LV, hangulClass(0xAC00)); // 가
    try expectEqual(JamoClass.LVT, hangulClass(0xAC01)); // 각
    try expectEqual(JamoClass.LVT, hangulClass(0xD55C)); // 한
    // 한글이 아닌 코드포인트는 none.
    try expectEqual(JamoClass.none, hangulClass('a'));
    try expectEqual(JamoClass.none, hangulClass(0x4E00)); // 一 (CJK)
}

test "extendsCluster: NFD 한글 자모가 한 음절 cluster로 이어진다 (GB6/7/8)" {
    // 왜 중요: 'ㅎㅏㄴ'(U+1112 U+1161 U+11AB)이 한 cluster여야 '한'으로 합쳐 그려지고 폭이
    // 2칸이 된다. 안 묶이면 ls 한글이 자모로 분리되고 폭이 음절당 2배가 된다.
    try expect(extendsCluster(0x1112, 0x1161)); // ㅎ(L) → ㅏ(V): GB6
    try expect(extendsCluster(0x1161, 0x11AB)); // ㅏ(V) → ㄴ(T): GB7
    try expect(extendsCluster(0x1100, 0x1173)); // ㄱ(L) → ㅡ(V): GB6
    // 음절 경계: 종성 다음의 새 초성은 끊긴다(다른 음절 시작).
    try expect(!extendsCluster(0x11AB, 0x1100)); // ㄴ(T) → ㄱ(L): boundary
    // 중성 없이 초성→종성은 이어지지 않는다(GB6은 L×T를 포함하지 않음).
    try expect(!extendsCluster(0x1100, 0x11A8)); // ㄱ(L) → ㄱ(T): boundary
}

test "extendsCluster: combining mark와 ZWJ는 앞 cluster에 붙는다 (GB9)" {
    // 왜 중요: 결합 악센트(e + ◌́)와 ZWJ 이모지 시퀀스가 base에 이어져야 데이터가 잘리지
    // 않는다(클립보드·재출력 무손실).
    try expect(extendsCluster('e', 0x0301)); // e + combining acute accent
    try expect(extendsCluster(0x1F468, 0x200D)); // 👨 + ZWJ
}

test "extendsCluster: 일반 문자·완성형 음절끼리는 매번 새 cluster (GB999)" {
    try expect(!extendsCluster('a', 'b'));
    // 완성형 '한'(D55C) 다음 '글'(AE00)은 끊긴다 — 음절마다 하나의 cluster.
    try expect(!extendsCluster(0xD55C, 0xAE00));
}

test "NFD 한글 시퀀스가 boundary 함수만으로 음절 2개로 분절된다" {
    // 왜 중요: 코어 print 경로(HG2)는 스트림에서 extendsCluster(prev,next)로 음절 경계를
    // 판정한다. 이 한 함수로 'ㅎㅏㄴ ㄱㅡㄹ'이 '한'·'글' 2개로 정확히 갈리는지 고정한다.
    const seq = [_]u21{ 0x1112, 0x1161, 0x11AB, 0x1100, 0x1173, 0x11AF }; // 한글 NFD
    var clusters: usize = 1;
    var i: usize = 1;
    while (i < seq.len) : (i += 1) {
        if (!extendsCluster(seq[i - 1], seq[i])) clusters += 1;
    }
    try expectEqual(@as(usize, 2), clusters);
}

test "clusterWidth: 한글 음절은 2칸, ASCII는 1칸 (base가 폭을 정한다)" {
    // base(초성/완성형)가 폭을 정하고 후속 자모는 0폭 흡수 → NFD '한'도 완성형과 같은 2칸.
    try expectEqual(@as(u2, 2), clusterWidth(0x1112)); // ㅎ 초성 = NFD 음절 base
    try expectEqual(@as(u2, 2), clusterWidth(0xAC00)); // 가 (완성형)
    try expectEqual(@as(u2, 1), clusterWidth('a'));
}

test "isConjoiningJamo: NFD 자모만 true, 완성형·ZWJ·일반문자는 false" {
    // 왜 중요: print 경로의 cluster 흡수가 이 범위만 0폭으로 합쳐야 한다. ZWJ(GB9)는
    // extendsCluster에선 true지만 폭 1이라 여기서 걸러내야 NFD와 무관한 ZWJ가 안 새어든다.
    try expect(isConjoiningJamo(0x1100)); // ㄱ 초성
    try expect(isConjoiningJamo(0x1161)); // ㅏ 중성
    try expect(isConjoiningJamo(0x11AB)); // ㄴ 종성
    try expect(isConjoiningJamo(0x11FF)); // 범위 끝
    try expect(!isConjoiningJamo(0x10FF)); // 범위 직전
    try expect(!isConjoiningJamo(0xAC00)); // 완성형 '가' — 제 셀을 차지
    try expect(!isConjoiningJamo(0x200D)); // ZWJ — 폭 1, 제 경로
    try expect(!isConjoiningJamo('a'));
}

test "isExtendedPictographic: 이모지(가족·❤·손)는 true, 동그란 번호·일반문자는 false (GB11)" {
    // 왜 중요: ZWJ 가족(👨‍👩‍👧) 잇기·스킨톤 흡수가 이 판정을 쓴다. 동그란 번호(③)는 ambiguous-wide지만
    // 그림문자가 아니라 false여야 스킨톤/ZWJ를 안 빨아들인다.
    try expect(isExtendedPictographic(0x1F468)); // 👨
    try expect(isExtendedPictographic(0x1F469)); // 👩
    try expect(isExtendedPictographic(0x1F91D)); // 🤝
    try expect(isExtendedPictographic(0x2764)); // ❤ (text-default지만 ZWJ 합류 가능)
    try expect(isExtendedPictographic(0x26A7)); // ⚧ (트랜스 깃발 ZWJ)
    try expect(isExtendedPictographic(0x2B50)); // ⭐
    try expect(!isExtendedPictographic(0x2462)); // ③ 동그란 번호 — 그림문자 아님
    try expect(!isExtendedPictographic('a'));
    try expect(!isExtendedPictographic(0xAC00)); // 완성형 한글
    try expect(!isExtendedPictographic(0x200D)); // ZWJ 자체는 그림문자 아님
}
