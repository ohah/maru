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
