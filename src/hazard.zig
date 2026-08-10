//! **문서 내용은 신뢰 입력이 아니다** — 보이는 것과 실제가 달라지게 만드는 문자를 가려낸다
//! ([native-editor-document-model.md](../docs/native-editor-document-model.md) §3.8).
//!
//! 편집기의 첫 제품 가치가 "에이전트가 만든 변경을 검토"하는 것이므로, **화면에 보이는 것과 파일의
//! 실제 내용이 달라지면 그 가치가 무너진다.** 이 모듈은 그 불변식을 깨는 codepoint를 판정한다.
//!
//! **문서를 바꾸지 않는다.** 여기서 하는 일은 "이 글자는 위험하다"는 판정과 "대신 무엇을 보여줄
//! 것인가"뿐이고, 버퍼의 바이트는 그대로다 — 지우거나 치환하면 저장 시 파일이 달라진다.
//!
//! **L2에 두는 이유**: 어떤 codepoint가 위험한지는 화면 폭·폰트·테마와 무관한 **문서 성질**이다.
//! 그것을 어떻게 그릴지(색·스팬 role)는 L3와 §5가 정한다.

const std = @import("std");
const width = @import("width.zig"); // 이모지 판정 단일 출처(§3.8 ZWJ 문맥)

/// 위험한 codepoint의 종류. 왜 위험한지가 곧 분류다.
pub const Hazard = enum {
    /// BiDi 제어 문자. **폭 0인데 주변 텍스트의 표시 순서를 바꾼다** — Trojan Source의 수단이
    /// 정확히 이것이다(CVE-2021-42574). 주석 안에 넣으면 코드가 주석처럼, 주석이 코드처럼 보인다.
    bidi_control,
    /// C0 제어 문자(NUL·ESC·BEL 등). **터미널과 달리 해석하지 않는다** — 편집기에 온 ESC는 명령이
    /// 아니라 파일의 바이트다. 탭과 줄바꿈은 편집기가 의미를 부여하므로 여기서 뺀다.
    control,
    /// 폭 0 문자(`U+200B` ZWSP·`U+FEFF` BOM 등). 식별자 안에 숨어 **다른 이름을 같아 보이게** 한다.
    zero_width,
    /// 비표준 공백(`U+00A0` NBSP 등). 공백처럼 보이지만 다른 바이트라, 문법 오류의 원인이 눈에
    /// 안 보인다.
    exotic_space,
    /// **이모지를 잇지 않는 ZWJ**(`U+200D`). 폭 0이라 보이지 않으면서 식별자를 쪼갠다 —
    /// `admin`과 `ad<ZWJ>min`이 같아 보이는데 다른 이름이다. 이모지 가족(👨‍👩‍👧)을 잇는 ZWJ는
    /// 정상이므로 **앞뒤 문맥으로 가른다**(`classifyInText`).
    zwj_outside_emoji,
};

/// 이 codepoint가 **그 자체로** 위험한가. 문맥이 필요한 것(ZWJ)은 여기서 판정하지 않는다 —
/// `classifyInText`를 쓴다.
///
/// **탭(`U+0009`)과 줄바꿈(`U+000A`/`U+000D`)은 제외한다.** 편집기가 그 셋에 의미를 부여하므로
/// (탭스톱 전개·줄 경계) 여기서 위험으로 잡으면 정상 텍스트가 전부 경고가 된다.
pub fn classify(cp: u21) ?Hazard {
    // BiDi 제어: U+202A~U+202E(embedding/override), U+2066~U+2069(isolate).
    if ((cp >= 0x202A and cp <= 0x202E) or (cp >= 0x2066 and cp <= 0x2069)) return .bidi_control;

    // C0 제어 — 탭·LF·CR 제외. DEL(U+007F)과 C1(U+0080~U+009F)도 같은 성격이다.
    if (cp < 0x20) {
        if (cp == 0x09 or cp == 0x0A or cp == 0x0D) return null;
        return .control;
    }
    if (cp == 0x7F) return .control;
    if (cp >= 0x80 and cp <= 0x9F) return .control;

    switch (cp) {
        // ZWSP·ZWNJ·ZWJ·word joiner·BOM(문서 중간에 나오면 폭 0 문자다).
        //
        // **U+200D(ZWJ)를 여기 넣지 않는다** — 이모지를 잇는지 식별자를 쪼개는지는 **앞뒤 문맥**이
        // 정하므로 `classifyInText`가 판정한다. codepoint 하나만 보면 둘을 가를 수 없다.
        0x200B, 0x200C, 0x2060, 0xFEFF => return .zero_width,
        // NBSP·narrow NBSP·ideographic space. 공백처럼 보이지만 다른 바이트다.
        0x00A0, 0x202F, 0x3000 => return .exotic_space,
        else => return null,
    }
}

/// **문맥까지 보고** 판정한다. `text` 안 `index` 위치의 codepoint가 대상이다.
///
/// `classify`가 못 가르는 것은 ZWJ 하나다 — 이모지를 잇는 ZWJ(👨‍👩‍👧)는 정상이고 그 밖은
/// 식별자를 쪼개는 공격 수단이다. **앞뒤 중 한쪽이라도 이모지가 아니면 위험으로 본다.**
///
/// 왜 "양쪽 다 이모지"가 아니라 "한쪽이라도 아니면"인가: 이모지 ZWJ 시퀀스는 정의상 양쪽이
/// 그림문자다(UTS #51). 한쪽이 글자면 그것은 시퀀스가 아니라 **글자 사이에 끼운 ZWJ**이고,
/// 그게 정확히 `ad<ZWJ>min`을 `admin`처럼 보이게 하는 수법이다.
pub fn classifyInText(text: []const u8, index: usize) ?Hazard {
    if (index >= text.len) return null;
    const len = std.unicode.utf8ByteSequenceLength(text[index]) catch return null;
    if (index + len > text.len) return null;
    const cp = std.unicode.utf8Decode(text[index .. index + len]) catch return null;

    if (cp == 0x200D) {
        return if (zwjJoinsEmoji(text, index, len)) null else .zwj_outside_emoji;
    }
    return classify(cp);
}

/// ZWJ가 양쪽 그림문자를 잇고 있는가. 한쪽이라도 이모지가 아니거나 줄 끝/처음이면 false.
///
/// **VS16(`U+FE0F`)을 건너뛴다.** `❤️‍🔥`(U+2764 U+FE0F U+200D U+1F525)처럼 **변형 선택자가 ZWJ
/// 바로 앞에 오는 시퀀스**가 있는데, VS16 자체는 그림문자가 아니라 앞 글자를 이모지 표현으로
/// 만드는 부호다. 건너뛰지 않으면 그 정상 이모지가 위험으로 잡힌다(실제로 그렇게 오탐했다).
///
/// 그리고 VS16이 붙은 base(`U+2764` 같은 텍스트 기호)는 `isEmojiPresentation`이 잡지 않으므로
/// **VS16이 있었다는 사실 자체를 이모지 근거로 쓴다** — 그것이 VS16의 정의다.
fn zwjJoinsEmoji(text: []const u8, index: usize, zwj_len: usize) bool {
    const before = beforeIsEmoji(text, index);
    const after_start = index + zwj_len;
    if (after_start >= text.len) return false;
    const after_len = std.unicode.utf8ByteSequenceLength(text[after_start]) catch return false;
    if (after_start + after_len > text.len) return false;
    const after = std.unicode.utf8Decode(text[after_start .. after_start + after_len]) catch return false;

    // 스킨톤 modifier(U+1F3FB~U+1F3FF)는 `isEmojiPresentation` 범위 안이라 그대로 통과한다.
    return before and width.isEmojiPresentation(after);
}

/// ZWJ 앞이 이모지인가. VS16이면 그 자체를 근거로 삼고, 아니면 그 codepoint를 판정한다.
fn beforeIsEmoji(text: []const u8, index: usize) bool {
    const prev = prevCodepointAt(text, index) orelse return false;
    if (prev.cp == 0xFE0F) return true; // VS16 = 앞 글자가 이모지 표현이라는 선언
    return width.isEmojiPresentation(prev.cp);
}

/// `index` 바로 앞 codepoint와 그 시작 offset. UTF-8 continuation byte를 거슬러 올라간다.
fn prevCodepointAt(text: []const u8, index: usize) ?struct { cp: u21, start: usize } {
    if (index == 0) return null;
    var start = index - 1;
    // continuation byte(0b10xxxxxx)를 지나 선두 byte까지.
    while (start > 0 and text[start] & 0xC0 == 0x80) start -= 1;
    const len = std.unicode.utf8ByteSequenceLength(text[start]) catch return null;
    if (start + len > text.len) return null;
    const cp = std.unicode.utf8Decode(text[start .. start + len]) catch return null;
    return .{ .cp = cp, .start = start };
}

/// 이 문서에 위험한 문자가 하나라도 있는가. 상태바 경고 같은 요약에 쓴다.
///
/// **전체를 훑는다.** 뷰포트만 보면 화면 밖의 Trojan Source를 놓치는데, 그것이 정확히 공격자가
/// 노리는 자리다(긴 파일 아래쪽).
pub fn containsAny(bytes: []const u8) bool {
    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            i += 1;
            continue;
        };
        if (i + len > bytes.len) break;
        const cp = std.unicode.utf8Decode(bytes[i .. i + len]) catch {
            i += len;
            continue;
        };
        _ = cp;
        if (classifyInText(bytes, i) != null) return true;
        i += len;
    }
    return false;
}

/// 이 codepoint를 화면에 무엇으로 보여줄 것인가.
///
/// **`U+FFFD`(대체 문자) 하나로 뭉뚱그리지 않는다.** 검토자가 "무엇이 숨어 있었나"를 알아야
/// 하므로 codepoint 값을 그대로 보여준다 — Trojan Source 리뷰에서 `U+202E`인지 `U+2066`인지가
/// 판단을 가른다.
///
/// 형식은 `<U+202E>`이며 버퍼에 쓰지 않고 **표시할 때만** 만든다. 반환 길이는 최대 `max_display_len`.
pub fn displayText(cp: u21, out: []u8) []const u8 {
    return std.fmt.bufPrint(out, "<U+{X:0>4}>", .{cp}) catch out[0..0];
}

/// `displayText`가 쓸 수 있는 최대 길이. `<U+10FFFF>` = 10 byte.
pub const max_display_len = 10;

const testing = std.testing;

test "BiDi 제어 문자를 잡는다 — Trojan Source의 수단이다" {
    // U+202E RIGHT-TO-LEFT OVERRIDE: 뒤 텍스트를 역순으로 보이게 한다.
    try testing.expectEqual(Hazard.bidi_control, classify(0x202E).?);
    try testing.expectEqual(Hazard.bidi_control, classify(0x202A).?);
    try testing.expectEqual(Hazard.bidi_control, classify(0x2066).?); // LRI
    try testing.expectEqual(Hazard.bidi_control, classify(0x2069).?); // PDI
}

test "BiDi 범위 경계 — 바로 밖은 잡지 않는다" {
    try testing.expectEqual(@as(?Hazard, null), classify(0x2029)); // embedding 범위 직전
    // U+202F는 범위 바로 뒤지만 BiDi가 아니라 **비표준 공백**이다 — 경계를 넘었다는 것과
    // 안전하다는 것은 다르다.
    try testing.expectEqual(Hazard.exotic_space, classify(0x202F).?);
    try testing.expectEqual(@as(?Hazard, null), classify(0x2065)); // isolate 직전
    try testing.expectEqual(@as(?Hazard, null), classify(0x206A)); // isolate 직후
}

test "C0 제어 문자를 잡되 탭·줄바꿈은 뺀다 — 편집기가 의미를 부여한 셋이다" {
    try testing.expectEqual(Hazard.control, classify(0x00).?); // NUL
    try testing.expectEqual(Hazard.control, classify(0x1B).?); // ESC
    try testing.expectEqual(Hazard.control, classify(0x07).?); // BEL

    try testing.expectEqual(@as(?Hazard, null), classify(0x09)); // TAB
    try testing.expectEqual(@as(?Hazard, null), classify(0x0A)); // LF
    try testing.expectEqual(@as(?Hazard, null), classify(0x0D)); // CR
}

test "DEL과 C1도 제어로 본다" {
    try testing.expectEqual(Hazard.control, classify(0x7F).?);
    try testing.expectEqual(Hazard.control, classify(0x85).?); // NEL
    // C1 범위(U+0080~U+009F) 바로 뒤인 U+00A0은 제어가 아니라 NBSP다.
    try testing.expectEqual(Hazard.exotic_space, classify(0xA0).?);
}

test "폭 0 문자를 잡는다 — 식별자가 같아 보이게 만든다" {
    try testing.expectEqual(Hazard.zero_width, classify(0x200B).?); // ZWSP
    try testing.expectEqual(Hazard.zero_width, classify(0xFEFF).?); // BOM(문서 중간)
    try testing.expectEqual(Hazard.zero_width, classify(0x2060).?); // word joiner
}

test "classify는 ZWJ를 판정하지 않는다 — 문맥이 필요해 classifyInText가 맡는다" {
    // codepoint 하나만 보면 이모지를 잇는 정상 ZWJ와 식별자를 쪼개는 ZWJ를 가를 수 없다.
    try testing.expectEqual(@as(?Hazard, null), classify(0x200D));
}

test "비표준 공백을 잡는다 — 문법 오류가 눈에 안 보인다" {
    try testing.expectEqual(Hazard.exotic_space, classify(0x00A0).?); // NBSP
    try testing.expectEqual(Hazard.exotic_space, classify(0x3000).?); // 전각 공백
}

test "평범한 글자는 잡지 않는다" {
    try testing.expectEqual(@as(?Hazard, null), classify('a'));
    try testing.expectEqual(@as(?Hazard, null), classify(' '));
    try testing.expectEqual(@as(?Hazard, null), classify('가'));
    try testing.expectEqual(@as(?Hazard, null), classify(0x1F600)); // 😀
}

test "containsAny: 평범한 문서는 false" {
    try testing.expect(!containsAny("const x = 1; // 주석"));
    try testing.expect(!containsAny(""));
    try testing.expect(!containsAny("탭\t줄바꿈\n도 정상"));
}

test "containsAny: 숨은 BiDi를 찾아낸다" {
    // 주석 안에 RLO를 숨긴 형태 — Trojan Source의 전형이다.
    try testing.expect(containsAny("// \u{202E}상관없음"));
}

test "containsAny: 잘린 UTF-8에서도 죽지 않는다" {
    // "가"의 첫 두 byte만. §3.5가 열 때 거부하지만 여기서 죽으면 안 된다.
    try testing.expect(!containsAny("\xEA\xB0"));
    try testing.expect(!containsAny("\xFF\xFE"));
}

test "displayText: codepoint 값을 그대로 보여준다 — 무엇이 숨었는지 알아야 한다" {
    var buf: [max_display_len]u8 = undefined;
    try testing.expectEqualStrings("<U+202E>", displayText(0x202E, &buf));
    try testing.expectEqualStrings("<U+0000>", displayText(0x00, &buf));
    try testing.expectEqualStrings("<U+FEFF>", displayText(0xFEFF, &buf));
}

test "displayText: 최대 길이가 max_display_len을 넘지 않는다" {
    var buf: [max_display_len]u8 = undefined;
    const r = displayText(0x10FFFF, &buf);
    try testing.expect(r.len <= max_display_len);
    try testing.expectEqualStrings("<U+10FFFF>", r);
}

test "ZWJ: 이모지를 이으면 정상이다 — 가족 이모지가 경고로 도배되면 안 된다" {
    // 👨‍👩‍👧 = U+1F468 ZWJ U+1F469 ZWJ U+1F467
    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
    try testing.expect(!containsAny(family));

    // 첫 ZWJ 위치(U+1F468은 4 byte)에서 직접 확인.
    try testing.expectEqual(@as(?Hazard, null), classifyInText(family, 4));
}

test "ZWJ: 글자 사이에 끼면 위험이다 — 식별자를 쪼개 같아 보이게 한다" {
    // `ad<ZWJ>min`은 화면에서 `admin`과 같아 보이지만 다른 이름이다.
    const sneaky = "ad\u{200D}min";
    try testing.expect(containsAny(sneaky));
    try testing.expectEqual(Hazard.zwj_outside_emoji, classifyInText(sneaky, 2).?);
}

test "ZWJ: 한쪽만 이모지여도 위험이다" {
    // 이모지 ZWJ 시퀀스는 정의상 양쪽이 그림문자다(UTS #51). 한쪽이 글자면 시퀀스가 아니다.
    const half = "\u{1F468}\u{200D}x";
    try testing.expectEqual(Hazard.zwj_outside_emoji, classifyInText(half, 4).?);
}

test "ZWJ: 줄 처음이나 끝에 홀로 있으면 위험이다" {
    try testing.expectEqual(Hazard.zwj_outside_emoji, classifyInText("\u{200D}a", 0).?);
    try testing.expectEqual(Hazard.zwj_outside_emoji, classifyInText("a\u{200D}", 1).?);
}

test "classifyInText: 문맥이 필요 없는 것은 classify와 같게 답한다" {
    const s = "a\u{202E}b";
    try testing.expectEqual(Hazard.bidi_control, classifyInText(s, 1).?);
    try testing.expectEqual(@as(?Hazard, null), classifyInText(s, 0));
}

test "classifyInText: 범위 밖·잘린 시퀀스에서 죽지 않는다" {
    try testing.expectEqual(@as(?Hazard, null), classifyInText("ab", 99));
    try testing.expectEqual(@as(?Hazard, null), classifyInText("\xEA\xB0", 0));
}

test "ZWJ: VS16이 낀 이모지 시퀀스를 오탐하지 않는다" {
    // ❤️‍🔥 = U+2764 U+FE0F U+200D U+1F525. ZWJ 앞이 VS16이라, 건너뛰지 않으면
    // "앞이 이모지가 아니다"로 판정돼 정상 이모지가 경고로 나온다.
    const heart_fire = "\u{2764}\u{FE0F}\u{200D}\u{1F525}";
    try testing.expect(!containsAny(heart_fire));
}

test "ZWJ: 스킨톤 modifier 뒤도 정상이다" {
    // 👨🏽‍💻 = U+1F468 U+1F3FD U+200D U+1F4BB
    const dev = "\u{1F468}\u{1F3FD}\u{200D}\u{1F4BB}";
    try testing.expect(!containsAny(dev));
}

test "ZWJ: VS16이 있어도 뒤가 글자면 여전히 위험이다" {
    // VS16을 근거로 앞을 통과시키더라도 뒤가 그림문자가 아니면 시퀀스가 아니다.
    const bad = "\u{2764}\u{FE0F}\u{200D}x";
    try testing.expect(containsAny(bad));
}
