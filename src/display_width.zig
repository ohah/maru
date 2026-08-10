//! 편집기 본문의 **표시 폭** — 몇 칸을 차지하는가([native-editor-visual-mapping.md](../docs/native-editor-visual-mapping.md) §4.2).
//!
//! **터미널과 갈리는 지점이다.** 터미널은 셸·앱과 폭을 합의해야 해서(상대가 자기 `wcwidth`로 커서를
//! 계산한다) 보수적으로 센다 — mode 2027 협상과 `text.ambiguous-width` 설정이 그래서 있다. 편집기가
//! 다루는 것은 파일이고 위치 축은 byte offset이라(§3.1) 표시 폭은 **밖으로 새지 않는다**. 우리가 유일한
//! 표시 주체이므로 시각적으로 옳은 답을 고른다.
//!
//! **폭을 세는 규칙과 글자를 놓는 규칙이 같아야 한다.** 이 모듈이 세는 칸 수만큼 `system_text`가 셀
//! 인덱스를 전진시킨다(§4.2). 어긋나면 뒤 글자가 밀린다.
//!
//! `width.cellWidth`(터미널 협상용)를 대체하지 않고 **그 위에 편집기 규칙을 얹는다** — 대부분의 문자는
//! 그대로 통과하고, 아래 세 경우만 다르다.

const std = @import("std");
const width = @import("width.zig");
const grapheme = @import("grapheme.zig");

/// 이모지 표현 선택자. 앞 글자를 **컬러 이모지로 그리라**는 선언이다(UTS #51).
const vs16: u21 = 0xFE0F;

/// `bytes[start..end]` 한 cluster가 차지하는 칸 수. `start..end`는 `grapheme.clusterEnd`가 낸 경계여야
/// 한다 — cluster 전체를 보지 않으면 VS16·국기를 판정할 수 없다.
///
/// 폭이 0인 cluster는 만들지 않는다(최소 1). 폭 0을 허용하면 caret이 놓일 자리가 사라진다.
pub fn clusterCols(bytes: []const u8, start: usize, end: usize) u16 {
    if (start >= end or start >= bytes.len) return 1;
    const stop = @min(end, bytes.len);
    const base = decodeAt(bytes, start) orelse return 1;

    // (1) **VS16이 붙으면 2칸.** base가 EAW=1이어도(❤ U+2764·⚠ U+26A0·✔ U+2714 …) VS16은 컬러
    // 이모지로 그리라는 선언이고, 컬러 글리프는 정사각이라 1칸에 넣으면 **세로가 절반이 된다**
    // (실측: 슬롯 8×18에 잉크 8×8 = 44.4%. 일반 글자 `W`의 61.1%보다 작다 — §4.2).
    // 터미널은 여기서 1칸을 유지한다(셸 `wcwidth`와 합의) — 그 제약이 편집기엔 없다.
    if (hasVs16(bytes, start, stop)) return 2;

    // (2) **지역 표시자는 2칸.** 둘이 모이면 국기 하나가 되고(GB12/13), **짝이 안 맞아 홀로 남아도**
    // 컬러 이모지 글리프다 — 실측: 1칸 슬롯에 잉크 7×8(44.4%), 2칸이면 13×14(77.8%). 판정 근거는
    // "짝이 찼는가"가 아니라 (1)과 같은 "컬러로 그려지는가"다.
    if (grapheme.isRegionalIndicator(base)) return 2;

    // (3) **폰트가 2칸으로 그리는 기호는 2칸.** 동그란/괄호친 영숫자(①②③)가 대표적이다. 렌더
    // 단계의 2칸 승격은 **다음 셀이 비었을 때만** 가능해서(겹쳐 그릴 수 없다) `①②③`를 연달아 쓰면
    // 앞의 둘이 1칸에 짓눌린다(실측: 렌더 폭 1·1·2). advance 자체를 2로 두는 것이 유일한 해법이다.
    if (width.isWideRenderSymbol(base)) return 2;

    return @max(1, width.cellWidth(base));
}

/// **셰이핑이 끝난 glyph 하나**가 차지하는 칸 수 — 배치(L4)가 쓰는 짝이다.
///
/// `clusterCols`와 **같은 답을 내야 한다.** 폭을 세는 규칙과 글자를 놓는 규칙이 갈리면 뒤 글자가
/// 밀린다(§4.2) — 실제로 그 어긋남이 이 모듈을 만든 계기다. 아래 교차 검증 테스트가 둘을 묶는다.
///
/// 입력이 다른 이유: 셰이퍼를 지난 뒤에는 cluster가 **glyph 하나로 합쳐져** 원래 바이트가 없다.
/// 대신 **폰트가 컬러 글리프를 줬는지**를 알 수 있고, 그것이 `clusterCols`의 VS16 규칙보다 오히려
/// 정확하다 — 코드포인트 테이블은 `❤️`가 컬러로 그려질지 추측하지만 여기서는 폰트가 답한 뒤다.
pub fn glyphCells(cp: u21, is_color: bool) u16 {
    // (1)(2) 컬러 글리프 = 이모지 표현. `clusterCols`의 VS16·지역 표시자 규칙이 여기 대응한다.
    if (is_color) return 2;
    // (3) 폰트가 2칸으로 그리는 단색 기호(①②③).
    if (width.isWideRenderSymbol(cp)) return 2;
    return @max(1, width.cellWidth(cp));
}

/// 문자열 전체의 표시 폭. cluster 단위로 순회한다 — 코드포인트로 세면 이모지 ZWJ 시퀀스에서
/// 실제 렌더보다 많이 세어 뒤 글자가 밀린다.
pub fn displayCols(bytes: []const u8) usize {
    var total: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const end = @max(i + 1, grapheme.clusterEnd(bytes, i));
        total += clusterCols(bytes, i, end);
        i = end;
    }
    return total;
}

/// cluster 안 어딘가에 VS16이 있는가. base 바로 뒤로 한정하지 않는 이유는 `❤️‍🔥`(❤ VS16 ZWJ 🔥)처럼
/// **cluster 중간**에 오는 경우가 있기 때문이다.
fn hasVs16(bytes: []const u8, start: usize, end: usize) bool {
    var i = start;
    while (i < end) {
        const cp = decodeAt(bytes, i) orelse return false;
        if (cp == vs16) return true;
        i += @max(1, std.unicode.utf8ByteSequenceLength(bytes[i]) catch 1);
    }
    return false;
}

fn decodeAt(bytes: []const u8, i: usize) ?u21 {
    const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch return null;
    if (i + len > bytes.len) return null;
    return std.unicode.utf8Decode(bytes[i .. i + len]) catch null;
}

const testing = std.testing;

test "ASCII·한글은 터미널과 같다 — 대부분의 문자는 그대로 통과한다" {
    try testing.expectEqual(@as(usize, 1), displayCols("A"));
    try testing.expectEqual(@as(usize, 2), displayCols("가"));
    try testing.expectEqual(@as(usize, 5), displayCols("hello"));
    try testing.expectEqual(@as(usize, 4), displayCols("한글"));
}

test "VS16이 붙으면 2칸 — 컬러로 그려지므로 1칸에 넣으면 절반이 된다" {
    // ❤(U+2764)는 EAW=1이지만 ❤️(+VS16)는 컬러 이모지다.
    try testing.expectEqual(@as(usize, 1), displayCols("\u{2764}"));
    try testing.expectEqual(@as(usize, 2), displayCols("\u{2764}\u{FE0F}"));
    // ⚠️·✔️도 같다.
    try testing.expectEqual(@as(usize, 2), displayCols("\u{26A0}\u{FE0F}"));
    try testing.expectEqual(@as(usize, 2), displayCols("\u{2714}\u{FE0F}"));
}

test "VS16이 cluster 중간에 와도 잡는다 (❤️‍🔥)" {
    try testing.expectEqual(@as(usize, 2), displayCols("\u{2764}\u{FE0F}\u{200D}\u{1F525}"));
}

test "이모지 ZWJ 가족은 cluster 하나라 2칸이다" {
    // 이게 6칸으로 세지던 것이 §4.2를 쓰게 만든 회귀다.
    try testing.expectEqual(@as(usize, 2), displayCols("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"));
    try testing.expectEqual(@as(usize, 2), displayCols("\u{1F44D}\u{1F3FD}")); // 스킨톤
    try testing.expectEqual(@as(usize, 2), displayCols("\u{1F600}")); // 단독
}

test "국기는 RI 둘이 모여 2칸 — 셋이 오면 앞 둘만 한 국기다" {
    try testing.expectEqual(@as(usize, 2), displayCols("\u{1F1F0}\u{1F1F7}"));
    try testing.expectEqual(@as(usize, 4), displayCols("\u{1F1F0}\u{1F1F7}\u{1F1FA}\u{1F1F8}"));
    // **홀로 남은 RI도 2칸이다.** 처음엔 "짝이 없으니 1칸"으로 적었는데 실측이 뒤집었다 — 단독 RI도
    // 컬러 이모지 글리프라(1칸 슬롯에 잉크 7×8 = 44.4%, 2칸이면 13×14 = 77.8%) 1칸에 넣으면 다른
    // 이모지와 똑같이 절반이 된다. 폭 판정의 근거는 "짝이 찼는가"가 아니라 "컬러로 그려지는가"다.
    try testing.expectEqual(@as(usize, 4), displayCols("\u{1F1F0}\u{1F1F7}\u{1F1FA}"));
}

test "동그란 번호는 2칸 — 연달아 써도 짓눌리지 않는다" {
    // 렌더 승격은 다음 셀이 비었을 때만 되므로 `①②③`가 1·1·2로 그려졌다(§4.2 실측).
    try testing.expectEqual(@as(usize, 2), displayCols("\u{2460}"));
    try testing.expectEqual(@as(usize, 6), displayCols("\u{2460}\u{2461}\u{2462}"));
}

test "폭 0인 cluster는 만들지 않는다 — caret이 놓일 자리가 사라진다" {
    // 결합 문자만 홀로 오는 비정상 입력(앞 글자가 잘려 나간 경우).
    try testing.expectEqual(@as(usize, 1), displayCols("\u{0301}"));
    // 손상 UTF-8도 자리를 갖는다.
    try testing.expectEqual(@as(usize, 1), displayCols("\xFF"));
}

test "섞인 문장의 폭" {
    // "a" + 가족 + "b" + ❤️ + "가"
    const s = "a\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}b\u{2764}\u{FE0F}가";
    try testing.expectEqual(@as(usize, 1 + 2 + 1 + 2 + 2), displayCols(s));
}

test "빈 문자열" {
    try testing.expectEqual(@as(usize, 0), displayCols(""));
}

test "교차 검증: clusterCols와 glyphCells가 같은 답을 낸다" {
    // **이 둘이 갈리면 뒤 글자가 밀린다**(§4.2). 열은 clusterCols가 세고 배치는 glyphCells가 하므로,
    // 규칙을 한쪽만 고치는 실수를 여기서 잡는다 — 실제로 그 어긋남이 이 모듈을 만든 계기다.
    const cases = [_]struct { text: []const u8, base: u21, color: bool }{
        .{ .text = "M", .base = 'M', .color = false },
        .{ .text = "가", .base = 0xAC00, .color = false },
        .{ .text = "\u{1F600}", .base = 0x1F600, .color = true },
        .{ .text = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", .base = 0x1F468, .color = true },
        .{ .text = "\u{1F44D}\u{1F3FD}", .base = 0x1F44D, .color = true },
        .{ .text = "\u{1F1F0}\u{1F1F7}", .base = 0x1F1F0, .color = true },
        .{ .text = "\u{2764}\u{FE0F}", .base = 0x2764, .color = true },
        .{ .text = "\u{26A0}\u{FE0F}", .base = 0x26A0, .color = true },
        .{ .text = "\u{2460}", .base = 0x2460, .color = false },
        .{ .text = "\u{2713}", .base = 0x2713, .color = false }, // ✓ 텍스트 기호
    };
    for (cases) |c| {
        const by_text = displayCols(c.text);
        const by_glyph = glyphCells(c.base, c.color);
        try testing.expectEqual(by_text, @as(usize, by_glyph));
    }
}

test "glyphCells: 컬러 여부가 codepoint 테이블보다 정확하다" {
    // ❤(U+2764)는 VS16 없이는 단색 1칸이고, VS16이 붙으면 컬러 2칸이다. 셰이핑 뒤에는 그 차이가
    // codepoint가 아니라 **폰트가 컬러를 줬는가**로 나타난다.
    try testing.expectEqual(@as(u16, 1), glyphCells(0x2764, false));
    try testing.expectEqual(@as(u16, 2), glyphCells(0x2764, true));
}
