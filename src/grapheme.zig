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

/// 코드포인트의 Hangul_Syllable_Type을 범위로 판정한다. **conjoining 블록 U+1100–U+11FF 전체**(현대 자모 +
/// 그 블록 안의 옛 자모 + filler)와 완성형 음절을 덮는다. **Hangul Jamo Extended-A(U+A960–U+A97C)·
/// Extended-B(U+D7B0–U+D7FB)는 아직 포함하지 않는다** — UAX#29는 그것들도 L/V/T로 지정하므로 그 자모를 쓰는
/// 첫가끝 옛한글은 현재 자모별로 분절된다(docs/grapheme-clustering.md §7). 범위를 넓히면 터미널 셀 점유·폭이
/// 함께 바뀌어(EAW·wcwidth 합의) `isConjoiningJamo`와 oracle까지 같이 손봐야 하므로 별도 슬라이스로 둔다.
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

/// Fitzpatrick 스킨톤 modifier(U+1F3FB~1F3FF). **UAX#29의 Extend에 포함된다** — 표준 Extend는
/// `Grapheme_Extend=Yes` *또는* `Emoji_Modifier=Yes`라, 스킨톤은 앞 그림문자에 붙어 한 cluster가 된다.
/// `width.isCombiningMark`(폭 0 결합 문자)와 분리해 둔 이유는 스킨톤이 **폭을 갖지 않으면서도 combining
/// mark는 아니기** 때문이다 — 폭 레이어는 이 범위를 wide(2)로 두고 cluster 레이어만 흡수한다.
pub fn isEmojiModifier(cp: u21) bool {
    return cp >= 0x1F3FB and cp <= 0x1F3FF;
}

/// 지역 표시자(U+1F1E6~1F1FF). **둘이 짝을 이뤄 국기 하나**가 된다(GB12/13) — 홀수 번째만 다음 것과
/// 이어지므로 `clusterEnd`가 개수를 세야 한다(셋이 연달아 오면 앞 둘만 한 cluster다).
pub fn isRegionalIndicator(cp: u21) bool {
    return cp >= 0x1F1E6 and cp <= 0x1F1FF;
}

/// prev 다음에 next가 올 때 **같은 grapheme cluster로 이어지는가**(= cluster boundary가 없는가)?
/// UAX#29 중 한글 연쇄(GB6/GB7/GB8)와 결합 문자(GB9)를 구현한다. 그 외 조합은 기본 boundary
/// (GB999 — 매 코드포인트가 새 cluster).
///
/// **이 함수는 두 코드포인트만 본다.** GB11(이모지 ZWJ 시퀀스)·GB12/13(RI 쌍)은 "cluster가 그림문자로
/// 시작했는가", "RI를 몇 개 삼켰는가" 같은 **누적 상태**가 있어야 판정되므로 여기 넣을 수 없고,
/// `clusterEnd`가 상태를 들고 처리한다. 터미널(`terminal/screen.zig`)은 셀 그리드에 이미 그 상태를
/// 갖고 있어 이 함수를 GB9/한글 용도로만 쓴다 — 시그니처를 바꾸지 않는 이유다.
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
    // **앞으로 한 글자씩만 디코드한다.** 예전엔 `Utf8View.init(bytes[start..])`로 남은 슬라이스 **전체**를 먼저
    // 검증했는데, 그러면 (1) cluster 하나를 재는 비용이 O(남은 길이)라 문자열을 훑으면 O(n²)가 되고
    // (chrome 제목은 매 프레임 훑는다 — 상한 없는 주소창 URL에서 프레임이 초 단위로 멈췄다), (2) 뒤쪽 어딘가의
    // 손상 바이트 하나가 **모든** start에서 init을 실패시켜 문자열 전체가 1바이트 cluster로 무너졌다
    // (라벨 하나에 잡음 바이트가 섞이면 NFD 한글이 통째로 자모로 흩어짐 — code-review max).
    // 지금은 손상이 **그 자리에서만** 1바이트 cluster가 된다(아래 decodeOne의 null 분기).
    const first = decodeOne(bytes, start) orelse return start + 1; // 손상 UTF-8 = 1바이트 cluster
    var prev = first.cp;
    var i = start + first.len;
    // GB11 상태: 이 cluster가 그림문자로 시작했고 그 뒤로 Extend/ZWJ만 왔는가. ZWJ 하나만 봐서는
    // `a<ZWJ>b`(문자 사이 ZWJ — §3.8의 공격 입력)와 `👨<ZWJ>👩`를 가를 수 없다.
    var pictographic = isExtendedPictographic(first.cp);
    // GB12/13 상태: RI를 몇 개 삼켰는가. 국기 하나는 정확히 둘이고, 셋이 연달아 오면 앞 둘만 묶인다.
    var ri_seen: usize = @intFromBool(isRegionalIndicator(first.cp));
    while (i < bytes.len) {
        const next = decodeOne(bytes, i) orelse break; // 손상 바이트는 다음 cluster 시작으로 넘긴다
        if (!clusterContinues(prev, next.cp, pictographic, ri_seen)) break; // 다음 cluster 시작 — 소비 안 함
        if (isRegionalIndicator(next.cp)) ri_seen += 1;
        if (isExtendedPictographic(next.cp)) {
            pictographic = true; // ZWJ로 이어붙은 그림문자 — 다음 ZWJ도 이을 수 있다
        } else if (!isExtendOrZwj(next.cp) and !isEmojiModifier(next.cp)) {
            pictographic = false; // 그림문자도 Extend도 아닌 것이 끼면 GB11 연쇄가 끊긴다
        }
        prev = next.cp;
        i += next.len;
    }
    return i;
}

/// `clusterEnd`의 한 걸음 판정 — 두 코드포인트만으로 되는 규칙(`extendsCluster`)에 **누적 상태가 필요한
/// 규칙**을 더한다. 분리해 둔 이유는 터미널이 `extendsCluster`를 그대로 써야 하기 때문이다(위 주석).
fn clusterContinues(prev: u21, next: u21, pictographic: bool, ri_seen: usize) bool {
    if (extendsCluster(prev, next)) return true; // GB9(Extend·ZWJ) + 한글 GB6/7/8
    // 스킨톤은 표준 Extend라 어떤 base 뒤든 붙는다. 터미널이 "폭 2 base에만" 제한하는 것은 폭 승격
    // (promoteLastToEmojiWidth)이 malformed 입력에서 ❤를 1→2로 늘렸던 회귀 때문이고, 여기는 폭을
    // 승격하지 않으므로 표준대로 둔다.
    if (isEmojiModifier(next)) return true;
    // GB11: `\p{ExtPict} Extend* ZWJ × \p{ExtPict}`
    if (prev == 0x200D and pictographic and isExtendedPictographic(next)) return true;
    // GB12/13: RI 쌍. 홀수 번째 RI만 다음 RI와 이어진다.
    if (ri_seen % 2 == 1 and isRegionalIndicator(prev) and isRegionalIndicator(next)) return true;
    return false;
}

/// `bytes[i]`에서 시작하는 UTF-8 한 글자(손상이면 null — 호출자가 1바이트로 넘긴다). 슬라이스 전체를 검증하지
/// 않는 것이 요점이다(위 clusterEnd 주석의 O(n²)·전역 실패 회귀).
fn decodeOne(bytes: []const u8, i: usize) ?struct { cp: u21, len: usize } {
    const len: usize = std.unicode.utf8ByteSequenceLength(bytes[i]) catch return null;
    if (i + len > bytes.len) return null;
    const cp = std.unicode.utf8Decode(bytes[i .. i + len]) catch return null;
    return .{ .cp = cp, .len = len };
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

test "clusterEnd: 손상 UTF-8은 그 자리에서만 1바이트 cluster다(뒤쪽 잡음이 앞 cluster를 무너뜨리지 않음)" {
    // 회귀(code-review max): 예전 구현은 `Utf8View.init(bytes[start..])`로 **남은 슬라이스 전체**를 검증해서,
    // 뒤쪽 어딘가의 잡음 바이트 하나가 모든 start에서 init을 실패시켰다 → 문자열 전체가 1바이트 cluster로
    // 무너져 NFD 한글 라벨이 통째로 자모로 흩어졌다(비-UTF-8 프로그램의 OSC 2 제목에서 실제로 발생 가능).
    const nfd_han = "\u{1112}\u{1161}\u{11AB}"; // NFD '한'
    const noisy = nfd_han ++ "\xE9" ++ nfd_han; // 가운데 Latin-1 잔여 바이트
    try expectEqual(nfd_han.len, clusterEnd(noisy, 0)); // ★ 앞 음절은 여전히 한 cluster
    try expectEqual(nfd_han.len + 1, clusterEnd(noisy, nfd_han.len)); // 손상 바이트 = 1바이트 cluster
    try expectEqual(noisy.len, clusterEnd(noisy, nfd_han.len + 1)); // ★ 뒤 음절도 온전히 한 cluster
    // 잘린 시퀀스(선두 바이트만 있고 뒤가 없음)도 1바이트로 넘긴다 — 진행이 보장돼야 호출자가 무한루프에 안 빠진다.
    const truncated = "\xE1\x84"; // U+1112의 앞 2바이트만
    try expectEqual(@as(usize, 1), clusterEnd(truncated, 0));
}

test "clusterEnd: 문자열 순회가 선형이다(cluster마다 남은 슬라이스를 재검증하지 않는다)" {
    // 회귀(code-review max): 예전 구현은 cluster 하나를 재는 데 O(남은 길이)를 써서 문자열 순회가 O(n²)였다.
    // chrome 제목은 매 프레임 이 순회를 돌고(chrome/text_layout.displayCols), 주소창 URL은 길이 상한이 없어 큰 data: URI에서
    // 프레임이 초 단위로 멈췄다. 여기선 **총 디코드 횟수**를 길이에 비례하게 유지하는지를 순회 횟수로 고정한다
    // (시간 측정은 기계마다 달라 불안정하므로 쓰지 않는다).
    const n = 4096;
    var buf: [n]u8 = undefined;
    @memset(&buf, 'a');
    var steps: usize = 0;
    var i: usize = 0;
    while (i < buf.len) : (steps += 1) i = clusterEnd(&buf, i);
    try expectEqual(@as(usize, n), steps); // ASCII n글자 = cluster n개(각 1바이트)
    // O(n²)였다면 아래 순회가 4096×4096/2 ≈ 8.4M 바이트 검증을 했다. 지금은 각 호출이 1~2글자만 본다.
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

test "clusterEnd: 이모지 ZWJ 가족이 cluster 하나다 (GB11)" {
    // 왜 중요: 편집기가 이걸 3조각으로 세면 가족 하나가 6칸을 먹어 뒤 글자가 4칸 밀린다.
    // 실측으로 드러난 회귀다(native-editor.md §4.2) — GB9만 있던 시절 6칸이 나왔다.
    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"; // 👨‍👩‍👧
    try std.testing.expectEqual(family.len, clusterEnd(family, 0));

    // 두 사람(👨‍👩)도 하나다.
    const couple = "\u{1F468}\u{200D}\u{1F469}";
    try std.testing.expectEqual(couple.len, clusterEnd(couple, 0));

    // 가족 뒤에 오는 일반 글자는 **다음** cluster다(다 삼키면 안 된다).
    const after = family ++ "A";
    try std.testing.expectEqual(family.len, clusterEnd(after, 0));
}

test "clusterEnd: 글자 사이 ZWJ는 그림문자를 잇지 않는다 (§3.8 공격 입력)" {
    // `ad<ZWJ>min`처럼 식별자를 쪼개는 ZWJ는 GB9로 앞 글자에 붙을 뿐, 뒤 글자까지 삼키면 안 된다.
    // GB11을 "prev==ZWJ"만 보고 적용하면 여기서 m까지 빨려들어간다.
    const attack = "a\u{200D}b";
    try std.testing.expectEqual(@as(usize, 4), clusterEnd(attack, 0)); // "a"+ZWJ(3바이트)까지
}

test "clusterEnd: 스킨톤은 앞 그림문자에 붙는다 (Emoji_Modifier = Extend)" {
    const thumb = "\u{1F44D}\u{1F3FD}"; // 👍🏽
    try std.testing.expectEqual(thumb.len, clusterEnd(thumb, 0));

    // 사람마다 스킨톤이 다른 가족도 하나다.
    const pair = "\u{1F9D1}\u{1F3FB}\u{200D}\u{1F91D}\u{200D}\u{1F9D1}\u{1F3FD}";
    try std.testing.expectEqual(pair.len, clusterEnd(pair, 0));
}

test "clusterEnd: 국기는 RI 둘까지만 묶는다 (GB12/13)" {
    const kr = "\u{1F1F0}\u{1F1F7}"; // 🇰🇷
    try std.testing.expectEqual(kr.len, clusterEnd(kr, 0));

    // **셋이 연달아 오면 앞 둘만** — 세 번째는 다음 국기의 시작이다. 개수를 안 세면 전부 삼킨다.
    const three = "\u{1F1F0}\u{1F1F7}\u{1F1FA}";
    try std.testing.expectEqual(kr.len, clusterEnd(three, 0));

    // 두 국기가 붙어 있으면 각각 하나씩.
    const two_flags = "\u{1F1F0}\u{1F1F7}\u{1F1FA}\u{1F1F8}"; // 🇰🇷🇺🇸
    try std.testing.expectEqual(kr.len, clusterEnd(two_flags, 0));
    try std.testing.expectEqual(two_flags.len, clusterEnd(two_flags, kr.len));
}

test "clusterEnd: VS16 결합과 그 뒤 ZWJ 시퀀스 (❤️‍🔥)" {
    const burning = "\u{2764}\u{FE0F}\u{200D}\u{1F525}"; // ❤️‍🔥
    try std.testing.expectEqual(burning.len, clusterEnd(burning, 0));
}
