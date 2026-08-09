//! **문서 내용은 신뢰 입력이 아니다** — 보이는 것과 실제가 달라지게 만드는 문자를 가려낸다
//! ([native-editor.md](../../../docs/native-editor.md) §3.8).
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
};

/// 이 codepoint가 위험한가. 아니면 null.
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
        // **U+200D(ZWJ)를 여기 넣지 않는다** — 이모지 가족(👨‍👩‍👧)을 잇는 정상 문자라, 잡으면
        // 평범한 이모지가 전부 경고가 된다. 식별자 안의 ZWJ는 §5 진단이 볼 문제이지 표시의 문제가 아니다.
        0x200B, 0x200C, 0x2060, 0xFEFF => return .zero_width,
        // NBSP·narrow NBSP·ideographic space. 공백처럼 보이지만 다른 바이트다.
        0x00A0, 0x202F, 0x3000 => return .exotic_space,
        else => return null,
    }
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
        if (classify(cp) != null) return true;
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

test "ZWJ는 잡지 않는다 — 이모지 가족이 전부 경고가 된다" {
    // 👨‍👩‍👧 같은 가족 이모지가 U+200D로 이어진다. 이것을 위험으로 잡으면 평범한 이모지가
    // 경고 표시로 도배된다.
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
