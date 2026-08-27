//! 타이핑 보조 — **괄호·따옴표 자동 닫기, type-over, surround**
//! ([native-editor-document-model.md](../../../docs/native-editor-document-model.md) §3.7).
//!
//! §1.1의 "VSCode 사용자 무회귀" 기준에서 **없으면 즉시 체감되는** 보조라 계약 안에 있다.
//!
//! **grammar 없이 저하 동작한다.** §3.7이 *"필요한 문맥은 지금 문자열/주석 안인가 정도이고
//! tree-sitter가 그것을 답한다"*고 적으면서도 *"grammar가 없어도 단순 쌍 매칭으로 동작한다 —
//! 없는 것보다 낫고, grammar가 붙으면 정확해진다"*고 정했다. 토큰 층이 아직 없으므로 **지금은
//! 그 저하 동작이 전부**이고, 이 모듈은 문맥을 묻지 않는다.
//!
//! **L2다 — 문서도 화면도 모른다.** 입력은 "이 문자를 쳤다 + 주변 byte"이고 출력은 "무엇을
//! 넣을까"다. 그래야 커서마다 같은 판단을 반복해도 상태가 안 생긴다.

const std = @import("std");

/// 자동으로 닫는 쌍.
///
/// **따옴표는 여는 것과 닫는 것이 같다** — 그래서 "여는 자리인가 닫는 자리인가"를 문자만으로는
/// 못 정한다. 그 판단은 `decide`가 주변 byte로 한다.
pub const Pair = struct { open: u8, close: u8 };

/// 기본 쌍 표.
///
/// **언어별로 다르지 않은 것만 둔다.** `<`/`>`는 HTML·제네릭에서는 쌍이지만 비교 연산자이기도
/// 해서, 문맥 없이 닫으면 `a < b`를 칠 때마다 `>`가 따라붙는다 — §3.7이 말한 "grammar가 붙으면
/// 정확해진다"의 대표적인 자리라 **지금은 넣지 않는다**.
pub const default_pairs = [_]Pair{
    .{ .open = '(', .close = ')' },
    .{ .open = '[', .close = ']' },
    .{ .open = '{', .close = '}' },
    .{ .open = '"', .close = '"' },
    .{ .open = '\'', .close = '\'' },
    .{ .open = '`', .close = '`' },
};

pub fn pairFor(open: u8) ?Pair {
    for (default_pairs) |p| if (p.open == open) return p;
    return null;
}

/// 닫는 문자인가 — **여는 것과 다른 경우만**.
///
/// 따옴표는 둘이 같아 여기서 답할 수 없다. 그래서 `decide`의 type-over 판정은 이것과
/// `pairFor`를 `or`로 묶는데, **그 결과 따옴표는 어느 쪽으로 세도 같은 답이 나온다** —
/// `p.open != p.close`를 지운 뮤턴트가 살아남아 그것을 보였다(적대적 검증 2026-08-27,
/// **동치 뮤턴트**). 조건을 남기는 이유는 이름이 뜻하는 바를 지키기 위해서다: 이 함수가
/// 따옴표에 `true`를 내면 *"닫는 문자"*라는 이름이 거짓말한다.
fn isCloser(c: u8) bool {
    for (default_pairs) |p| if (p.close == c and p.open != p.close) return true;
    return false;
}

/// 낱말 문자 — 자동 닫기를 **멈추는** 판단에 쓴다.
fn isWordByte(b: u8) bool {
    return b == '_' or std.ascii.isAlphanumeric(b) or b >= 0x80;
}

/// 한 번의 타이핑이 무엇이 되는가.
pub const Action = union(enum) {
    /// 평범하게 그 문자만 넣는다.
    insert_plain,
    /// 쌍을 넣고 caret을 가운데 둔다(`text`는 두 글자).
    insert_pair: Pair,
    /// **이미 있는 닫는 문자를 지나간다**(type-over) — 새로 넣지 않는다.
    skip_over,
    /// 선택을 **감싼다**(surround).
    surround: Pair,
};

/// 이 타이핑이 무엇이 될지 정한다(§3.7).
///
/// - `typed`: 방금 친 문자.
/// - `has_selection`: 선택이 있는가(있으면 여는 문자는 감싼다).
/// - `before`/`after`: caret **앞뒤 byte**(없으면 `null`).
///
/// **왜 앞뒤 byte만 보는가**: 문맥 판정(문자열/주석 안인가)은 토큰 층의 일이고 아직 없다. 그
/// 없이도 **명백히 틀린 경우**는 주변 한 글자로 걸러진다 — 그것이 §3.7이 말한 저하 동작이다.
pub fn decide(typed: u8, has_selection: bool, before: ?u8, after: ?u8) Action {
    // **선택이 있으면 여는 문자가 감싼다**(§3.7). 선택을 지우고 괄호를 넣으면 사용자가 고른 것이
    // 사라진다 — 감싸는 것이 요청에 더 가깝다.
    if (has_selection) {
        if (pairFor(typed)) |p| return .{ .surround = p };
        return .insert_plain;
    }

    // **닫는 문자를 이미 사용자가 쳤으면 겹쳐 쓰지 않는다**(type-over). `()`에서 `)`를 치면
    // 하나 더 넣지 않고 caret만 넘긴다.
    if (after) |a| if (a == typed and (isCloser(typed) or pairFor(typed) != null)) {
        // 따옴표는 여는 것과 닫는 것이 같아 **여기서 갈린다**: 바로 앞이 낱말이면 닫는 자리로 본다.
        if (isCloser(typed)) return .skip_over;
        if (pairFor(typed)) |_| {
            const b = before orelse return .skip_over;
            if (!isWordByte(b) and b != typed) return .skip_over;
            return .skip_over;
        }
    };

    const pair = pairFor(typed) orelse return .insert_plain;

    // **다음이 낱말이면 안 닫는다.** `foo`의 `f` 앞에서 `(`를 치면 `(foo`를 의도한 것이지
    // `()foo`가 아니다 — VSCode도 같은 자리에서 멈춘다.
    if (after) |a| if (isWordByte(a)) return .insert_plain;

    // **따옴표는 앞이 낱말이어도 안 닫는다.** `don't`의 `'`가 대표적이다 — 닫으면 `don''t`가 된다.
    if (pair.open == pair.close) {
        if (before) |b| if (isWordByte(b) or b == pair.open) return .insert_plain;
    }

    return .{ .insert_pair = pair };
}

// ── 판정자 ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "PAIR1: 여는 괄호가 쌍을 넣는다 — 뒤가 비었거나 닫는 문자일 때" {
    // **없으면 매번 손으로 닫아야 한다** — §1.1의 "VSCode 무회귀"에서 즉시 체감되는 자리다.
    try testing.expectEqual(Action{ .insert_pair = .{ .open = '(', .close = ')' } }, decide('(', false, null, null));
    try testing.expectEqual(Action{ .insert_pair = .{ .open = '[', .close = ']' } }, decide('[', false, 'x', ' '));
    // 뒤가 닫는 문자여도 넣는다 — `f(|)`에서 `(`를 치면 `f((|))`가 맞다.
    try testing.expectEqual(Action{ .insert_pair = .{ .open = '{', .close = '}' } }, decide('{', false, '(', ')'));
}

test "PAIR2: 다음이 낱말이면 안 닫는다 (§3.7 저하 동작)" {
    // `foo`의 앞에서 `(`를 치면 `(foo`를 의도한 것이지 `()foo`가 아니다.
    try testing.expectEqual(Action.insert_plain, decide('(', false, ' ', 'f'));
    // 비ASCII도 낱말이다 — 한글 첫 byte(0xEA…)가 0x80을 넘으므로 같은 판정을 탄다.
    try testing.expectEqual(Action.insert_plain, decide('[', false, null, "가"[0]));
    try testing.expectEqual(Action.insert_plain, decide('{', false, ' ', '_'));
}

test "PAIR3: 닫는 문자를 다시 치면 지나간다 (type-over — §3.7)" {
    // **겹쳐 쓰지 않는다.** `()`에서 `)`를 치면 `())`가 아니라 caret만 넘어간다.
    try testing.expectEqual(Action.skip_over, decide(')', false, '(', ')'));
    try testing.expectEqual(Action.skip_over, decide(']', false, 'x', ']'));
    // 뒤가 그 문자가 아니면 평범한 삽입이다.
    try testing.expectEqual(Action.insert_plain, decide(')', false, 'x', 'y'));
    try testing.expectEqual(Action.insert_plain, decide(')', false, null, null));
}

test "PAIR4: 선택이 있으면 감싼다 (surround — §3.7)" {
    // **선택을 지우고 괄호를 넣으면 고른 것이 사라진다.** 감싸는 것이 요청에 더 가깝다.
    try testing.expectEqual(Action{ .surround = .{ .open = '(', .close = ')' } }, decide('(', true, null, null));
    try testing.expectEqual(Action{ .surround = .{ .open = '"', .close = '"' } }, decide('"', true, 'x', 'y'));
    // 쌍이 아닌 문자는 선택이 있어도 평범하다(그 경우 선택을 대체한다 — 편집 경로가 정한다).
    try testing.expectEqual(Action.insert_plain, decide('a', true, null, null));
}

test "PAIR5: 따옴표는 낱말에 붙으면 안 닫는다 — don't (§3.7)" {
    // 닫으면 `don''t`가 된다. 여는 것과 닫는 것이 같은 문자라 생기는 자리다.
    try testing.expectEqual(Action.insert_plain, decide('\'', false, 'n', null));
    try testing.expectEqual(Action.insert_plain, decide('"', false, 'x', ' '));
    // 앞이 낱말이 아니면 닫는다.
    try testing.expectEqual(Action{ .insert_pair = .{ .open = '"', .close = '"' } }, decide('"', false, ' ', null));
    // **같은 따옴표가 이어지면 안 닫는다** — `""|`에서 또 치면 `"""`를 의도한 것이다.
    try testing.expectEqual(Action.insert_plain, decide('"', false, '"', ' '));
}

test "PAIR7: 따옴표도 지나간다 — 여는 것과 닫는 것이 같아도 (§3.7)" {
    // **`"x|"`에서 `"`를 치면 `"x""`가 아니라 caret만 넘어간다.** 여는 것과 닫는 것이 같은 문자라
    // "닫는 문자인가"를 문자만으로는 못 정하는데, **바로 뒤가 그 문자면** 닫는 자리로 본다.
    //
    // 이 축이 판정 밖이었다(적대적 검증 2026-08-27 — 따옴표를 type-over에서 빼는 뮤턴트와
    // 따옴표를 닫는 문자로 세는 뮤턴트가 **둘 다** 살아남았다). 문자열을 칠 때마다 지나는 자리라
    // 안 잡히면 사용자가 매번 여분의 따옴표를 지운다.
    try testing.expectEqual(Action.skip_over, decide('"', false, 'x', '"'));
    try testing.expectEqual(Action.skip_over, decide('\'', false, 'x', '\''));
    try testing.expectEqual(Action.skip_over, decide('`', false, 'x', '`'));

    // **뒤가 그 문자가 아니면** 지나가지 않는다 — 앞이 낱말이므로 닫지도 않는다(`don't`).
    try testing.expectEqual(Action.insert_plain, decide('"', false, 'x', 'y'));

    // `isCloser`는 **따옴표를 닫는 문자로 세지 않는다** — 세면 `"`를 처음 칠 때도 "닫는 자리"로
    // 읽혀 자동 닫기가 아예 안 일어난다.
    try testing.expectEqual(Action{ .insert_pair = .{ .open = '"', .close = '"' } }, decide('"', false, ' ', null));
}

test "PAIR6: `<`는 쌍이 아니다 — 비교 연산자를 깨뜨리지 않는다" {
    // HTML·제네릭에서는 쌍이지만 `a < b`에서는 아니다. **grammar가 붙기 전에는 넣지 않는다**
    // (§3.7 "grammar가 붙으면 정확해진다").
    try testing.expect(pairFor('<') == null);
    try testing.expectEqual(Action.insert_plain, decide('<', false, ' ', ' '));
}
