//! 짝 괄호 판정 — **강조**([시각 매핑](../../../docs/native-editor-visual-mapping.md) §5.1b)와 **점프**
//! ([문서 모델](../../../docs/native-editor-document-model.md) §3.9c)가 같이 쓴다. 강조가 가리키는 쌍과 점프가 가는 곳이 갈리면
//! 사용자는 둘 중 무엇을 믿을지 모른다.
//!
//! **출처가 둘이고 규칙은 여기 하나다.** 출처는 「byte `i` 의 괄호의 짝」(`pairAt`)과 「caret 을 품는 가장 안쪽 쌍」(`enclosing`)을 답한다 —
//! 트리가 있으면 트리(`Tree`), 없으면 글자 훑기(`Plain` — 감싸는 쌍은 안 찾는다). 어느 괄호를 고르는가(뒤 먼저)·감싸는 쌍으로 물러서는가·
//! 점프가 어디로 가는가는 출처와 무관하게 아래 세 함수가 정한다.
//!
//! **byte 로 세도 UTF-8 이 안 깨진다** — 괄호 여섯은 ASCII 이고 연속 byte(`0x80`–`0xBF`)와 겹치지 않는다.
const std = @import("std");

/// 괄호 한 쌍 — 두 괄호 **글자**의 문서 절대 byte(`open < close`).
pub const Pair = struct { open: u32, close: u32 };

/// `editor.match-brackets`(§5.1b) — VS Code `matchBrackets` 와 같은 값.
pub const Mode = enum { never, near, always };

/// **caret `pos` 에 닿은 괄호의 쌍**(§5.1b ②). 뒤 글자(`pos`)를 먼저, 그것에 짝이 없으면 앞 글자(`pos - 1`)를 본다 — VS Code 가 닿은 괄호 중
/// 시작이 가장 뒤인 것을 고르고(`findLastMaxBy`), 짝 없는 괄호는 후보가 아니다(실측: `(a)|(b)` → `[3,5]`, `(a)|(` → `[0,2]`).
pub fn touching(src: anytype, len: usize, pos: usize) ?Pair {
    const at = @min(pos, len);
    if (at < len) if (src.pairAt(at)) |p| return p;
    if (at > 0) if (src.pairAt(at - 1)) |p| return p;
    return null;
}

/// 강조할 쌍(§5.1b). `near` 는 닿은 괄호만, `always` 는 닿은 괄호가 없으면 caret 을 품는 가장 안쪽 쌍.
pub fn forHighlight(src: anytype, len: usize, pos: usize, mode: Mode) ?Pair {
    return switch (mode) {
        .never => null,
        .near => touching(src, len, pos),
        .always => touching(src, len, pos) orelse src.enclosing(@min(pos, len)),
    };
}

/// **괄호 짝으로 점프**(§3.9c)가 caret 을 둘 byte. 여는 괄호에**만** 닿았으면 닫는 괄호 앞으로, 닫는 괄호에 닿았으면 여는 괄호 앞으로
/// (VS Code `jumpToBracket` — `{|}` 는 둘 다 닿아 여는 괄호 앞으로 간다). 닿은 괄호가 없으면 `null`(감싸는 쌍으로는 아직 안 간다).
pub fn jumpTarget(src: anytype, len: usize, pos: usize) ?usize {
    const at = @min(pos, len);
    const p = touching(src, len, at) orelse return null;
    const on_close = at == p.close or at == @as(usize, p.close) + 1;
    return if (on_close) p.open else p.close;
}

/// **grammar 없는 문서**의 출처(§3.9c 저하) — 문서 전체를 글자로 훑는다. 감싸는 쌍은 **안 찾는다**: 문자열 속 괄호를 세어 틀린 쌍을 보인다.
pub const Plain = struct {
    bytes: []const u8,

    pub fn pairAt(self: Plain, i: usize) ?Pair {
        return (Scan{ .bytes = self.bytes, .lo = 0, .hi = self.bytes.len }).pairAt(i);
    }

    pub fn enclosing(self: Plain, pos: usize) ?Pair {
        _ = self;
        _ = pos;
        return null;
    }
};

/// `[lo, hi)` 안의 **글자 훑기**(§3.9c) — 같은 종류만 깊이로 센다. 문서 전체(`Plain`)와 글 잎(§5.1b ⓑ)이 쓴다.
///
/// **다른 종류는 무시한다** — `([)` 같은 어긋난 중첩을 글자만으로 고쳐 읽을 길이 없고, 세면 `(` 의 짝을 못 찾는다. **상한을 두지 않는다** —
/// 두면 큰 파일에서만 조용히 답이 달라진다(§3.9c).
pub const Scan = struct {
    bytes: []const u8,
    lo: usize,
    hi: usize,

    /// `bytes[i]` 가 괄호면 그 짝. 아니거나 범위 밖이거나 짝이 없으면 `null`.
    pub fn pairAt(self: Scan, i: usize) ?Pair {
        if (i < self.lo or i >= self.hi) return null;
        const b = bracketOf(self.bytes[i]) orelse return null;
        const same_open = open_chars[b.kind];
        const same_close = close_chars[b.kind];
        var depth: usize = 0;
        if (b.open) {
            // **자기 자리부터 센다** — 닫는 갈래와 대칭이다(둘 다 「자기 자리를 포함해 훑는다」).
            var j = i;
            while (j < self.hi) : (j += 1) {
                if (self.bytes[j] == same_open) {
                    depth += 1;
                } else if (self.bytes[j] == same_close) {
                    depth -= 1;
                    if (depth == 0) return .{ .open = @intCast(i), .close = @intCast(j) };
                }
            }
            return null;
        }
        var j = i + 1;
        while (j > self.lo) {
            j -= 1;
            if (self.bytes[j] == same_close) {
                depth += 1;
            } else if (self.bytes[j] == same_open) {
                depth -= 1;
                if (depth == 0) return .{ .open = @intCast(j), .close = @intCast(i) };
            }
        }
        return null;
    }

    /// caret `pos` 를 품는 가장 안쪽 쌍(`open < pos ≤ close`). 뒤로 훑으며 종류별로 닫는 괄호를 세고, 짝 없이 남은 첫 여는 괄호가 후보다 —
    /// 그 짝이 없으면(안 닫혔다) 그것을 건너뛰고 더 뒤로 간다(VS Code 도 안 닫힌 괄호는 품지 않는다).
    pub fn enclosing(self: Scan, pos: usize) ?Pair {
        const p = @min(pos, self.hi);
        var depth = [3]usize{ 0, 0, 0 };
        var j = p;
        while (j > self.lo) {
            j -= 1;
            const b = bracketOf(self.bytes[j]) orelse continue;
            if (!b.open) {
                depth[b.kind] += 1;
            } else if (depth[b.kind] > 0) {
                depth[b.kind] -= 1;
            } else if (self.pairAt(j)) |pair| {
                return pair; // 뒤로 세어 짝 없이 남았으니 그 짝은 `pos` 이상에 있다
            }
        }
        return null;
    }
};

/// **트리가 있는 문서**의 출처(§5.1b). `P` 는 `syntax.Provider` 모양이다 — `bracketTokenPair`·`proseLeafAt`·`enclosingBracketTokens`.
/// 제네릭인 이유는 판정자다: 조합 규칙(토큰 → 글 잎 → 없음)을 가짜 provider 로 따로 잰다.
pub fn Tree(comptime P: type) type {
    return struct {
        prov: *P,
        bytes: []const u8,

        const Self = @This();

        /// ⓐ 괄호 토큰이면 트리의 짝, ⓑ 글 잎 속이면 그 잎 안의 글자 훑기, ⓒ 그 밖(문자열·주석 속)은 괄호가 아니다.
        pub fn pairAt(self: Self, i: usize) ?Pair {
            if (i >= self.bytes.len) return null;
            if (self.prov.bracketTokenPair(self.bytes, @intCast(i))) |p| return .{ .open = p.open, .close = p.close };
            const leaf = self.prov.proseLeafAt(@intCast(i)) orelse return null;
            return (Scan{ .bytes = self.bytes, .lo = leaf.start, .hi = leaf.end }).pairAt(i);
        }

        /// 글 잎 안이면 그 안에서 먼저 찾고(가장 안쪽이다), 없으면 트리의 조상을 걷는다.
        pub fn enclosing(self: Self, pos: usize) ?Pair {
            const at: u32 = @intCast(@min(pos, self.bytes.len));
            // caret 은 글자 **사이**다 — 뒤 글자의 잎, 없으면 앞 글자의 잎(잎 끝에 선 caret).
            const leaf = self.prov.proseLeafAt(at) orelse if (at > 0) self.prov.proseLeafAt(at - 1) else null;
            if (leaf) |l| {
                if ((Scan{ .bytes = self.bytes, .lo = l.start, .hi = l.end }).enclosing(at)) |p| return p;
            }
            const p = self.prov.enclosingBracketTokens(self.bytes, at) orelse return null;
            return .{ .open = p.open, .close = p.close };
        }
    };
}

const open_chars = "([{";
const close_chars = ")]}";

fn bracketOf(ch: u8) ?struct { kind: u2, open: bool } {
    return switch (ch) {
        '(' => .{ .kind = 0, .open = true },
        ')' => .{ .kind = 0, .open = false },
        '[' => .{ .kind = 1, .open = true },
        ']' => .{ .kind = 1, .open = false },
        '{' => .{ .kind = 2, .open = true },
        '}' => .{ .kind = 2, .open = false },
        else => null,
    };
}

// ── 판정자 ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn pr(o: u32, cl: u32) ?Pair {
    return .{ .open = o, .close = cl };
}

test "BRK1 닿은 괄호는 뒤 먼저 — 짝이 없으면 앞 (§5.1b ②, VS Code 실측)" {
    const T = struct {
        fn t(s: []const u8, pos: usize) ?Pair {
            return touching(Plain{ .bytes = s }, s.len, pos);
        }
    };
    try testing.expectEqual(pr(3, 5), T.t("(a)(b)", 3)); // 뒤 '(' 가 이긴다 — 앞 ')' 의 쌍 [0,2] 가 아니다
    try testing.expectEqual(pr(0, 4), T.t("((a))", 4)); // `(a)|)` — 바깥 쌍(뒤 ')'), 안쪽 [1,3] 이 아니다
    try testing.expectEqual(pr(0, 2), T.t("(a)(", 3)); // 뒤 '(' 가 안 닫혔다 → 앞
    try testing.expectEqual(pr(2, 4), T.t("a)(b)", 2)); // 앞 ')' 가 안 열렸다 → 뒤
    try testing.expectEqual(pr(0, 2), T.t("(a)", 2)); // `(a|)` — 앞 'a' 는 괄호가 아니다
    try testing.expectEqual(@as(?Pair, null), T.t(")(", 1)); // 둘 다 짝이 없다
    try testing.expectEqual(@as(?Pair, null), T.t("(abc)", 2)); // 닿은 괄호가 없다
    try testing.expectEqual(pr(0, 2), T.t("(a)", 99)); // 문서 끝을 넘으면 끝에서 본다
    try testing.expectEqual(@as(?Pair, null), T.t("", 0));
}

test "BRK2 글자 훑기는 같은 종류만 깊이로 센다 — 범위 밖은 없다 (§3.9c)" {
    const s = "[a{b}c]";
    const whole = Scan{ .bytes = s, .lo = 0, .hi = s.len };
    try testing.expectEqual(pr(0, 6), whole.pairAt(0));
    try testing.expectEqual(pr(2, 4), whole.pairAt(4));
    try testing.expectEqual(pr(0, 4), (Scan{ .bytes = "((a))", .lo = 0, .hi = 5 }).pairAt(4)); // 닫는 쪽도 깊이를 센다
    try testing.expectEqual(pr(1, 3), (Scan{ .bytes = "((a))", .lo = 0, .hi = 5 }).pairAt(3));
    // **범위가 짝을 가른다** — 잎이 `[1,4)` 면 0 과 4 의 괄호는 없는 것이다
    const leaf = Scan{ .bytes = "((a))", .lo = 1, .hi = 4 };
    try testing.expectEqual(pr(1, 3), leaf.pairAt(1));
    try testing.expectEqual(@as(?Pair, null), leaf.pairAt(0));
    try testing.expectEqual(@as(?Pair, null), leaf.pairAt(4));
    const cut = Scan{ .bytes = "(a)", .lo = 0, .hi = 2 }; // 닫는 괄호가 범위 밖
    try testing.expectEqual(@as(?Pair, null), cut.pairAt(0));
    const cut_back = Scan{ .bytes = "(a)", .lo = 1, .hi = 3 }; // 여는 괄호가 범위 밖
    try testing.expectEqual(@as(?Pair, null), cut_back.pairAt(2));
    try testing.expectEqual(@as(?Pair, null), whole.pairAt(1)); // 괄호 아님
}

test "BRK3 감싸는 쌍은 open < pos ≤ close 인 가장 안쪽 — 안 닫힌 여는 괄호는 건너뛴다 (§5.1b ③)" {
    const s = "f(ab, c)";
    const sc = Scan{ .bytes = s, .lo = 0, .hi = s.len };
    try testing.expectEqual(pr(1, 7), sc.enclosing(3)); // VS Code 실측 [1,7]
    try testing.expectEqual(pr(1, 7), sc.enclosing(7)); // 닫는 괄호 바로 앞도 품는다
    try testing.expectEqual(@as(?Pair, null), sc.enclosing(1)); // 여는 괄호 바로 앞은 품지 않는다
    try testing.expectEqual(@as(?Pair, null), sc.enclosing(8)); // 닫는 괄호 바로 뒤도
    const nested = "(a[b]c)";
    const ns = Scan{ .bytes = nested, .lo = 0, .hi = nested.len };
    try testing.expectEqual(pr(2, 4), ns.enclosing(3)); // 안쪽
    try testing.expectEqual(pr(0, 6), ns.enclosing(6)); // `[b]` 를 지나 바깥 — 닫는 ']' 를 세고 여는 '[' 로 지운다
    // 종류가 섞여도 종류별로 센다 — ']' 가 '(' 를 지우지 않는다
    const mixed = "(a]b)";
    try testing.expectEqual(pr(0, 4), (Scan{ .bytes = mixed, .lo = 0, .hi = mixed.len }).enclosing(3));
    // 안 닫힌 '(' 는 건너뛰고 바깥 '{' 로
    const open = "{a(b}";
    try testing.expectEqual(pr(0, 4), (Scan{ .bytes = open, .lo = 0, .hi = open.len }).enclosing(4));
    // 범위가 경계다 — lo 앞의 여는 괄호는 없는 것이다
    try testing.expectEqual(@as(?Pair, null), (Scan{ .bytes = s, .lo = 2, .hi = s.len }).enclosing(3));
}

test "BRK4 강조 모드 — never 없음 · near 닿은 것만 · always 는 감싸는 쌍으로 물러선다 (§5.1b)" {
    const s = "f(ab, c)";
    const sc = Scan{ .bytes = s, .lo = 0, .hi = s.len }; // 감싸는 쌍을 아는 출처
    try testing.expectEqual(@as(?Pair, null), forHighlight(sc, s.len, 3, .never));
    try testing.expectEqual(@as(?Pair, null), forHighlight(sc, s.len, 3, .near));
    try testing.expectEqual(pr(1, 7), forHighlight(sc, s.len, 3, .always));
    try testing.expectEqual(pr(1, 7), forHighlight(sc, s.len, 2, .near)); // `f(|ab` — 닿았다
    try testing.expectEqual(@as(?Pair, null), forHighlight(sc, s.len, 2, .never));
    // **Plain 은 감싸는 쌍을 안 찾는다**(§3.9c) — always 여도 닿은 것만
    try testing.expectEqual(@as(?Pair, null), forHighlight(Plain{ .bytes = s }, s.len, 3, .always));
}

test "BRK5 점프 — 여는 괄호에만 닿으면 닫는 괄호 앞, 닫는 괄호에 닿으면 여는 괄호 앞 (§3.9c, VS Code 실측)" {
    const J = struct {
        fn j(s: []const u8, pos: usize) ?usize {
            return jumpTarget(Plain{ .bytes = s }, s.len, pos);
        }
    };
    try testing.expectEqual(@as(?usize, 0), J.j("{}", 1)); // 둘 다 닿았다 → 여는 괄호 앞(제자리가 아니다)
    try testing.expectEqual(@as(?usize, 4), J.j("((a))", 0));
    try testing.expectEqual(@as(?usize, 0), J.j("((a))", 4)); // 왕복한다
    try testing.expectEqual(@as(?usize, 5), J.j("(a)(b)", 3));
    try testing.expectEqual(@as(?usize, 0), J.j("(a)(", 3));
    try testing.expectEqual(@as(?usize, 2), J.j("(a)", 1)); // 여는 괄호 뒤(닿음) → 닫는 괄호 앞
    try testing.expectEqual(@as(?usize, 0), J.j("(a)", 2)); // 닫는 괄호 앞(닿음) → 여는 괄호 앞
    try testing.expectEqual(@as(?usize, null), J.j("abc", 1));
}

/// 가짜 provider — 토큰 짝·글 잎·감싸는 토큰을 표로 답한다.
const FakeProv = struct {
    tokens: []const Pair = &.{},
    leaf: ?struct { start: u32, end: u32 } = null,
    tree_enclosing: ?Pair = null,
    enclosing_calls: usize = 0,

    pub fn bracketTokenPair(self: *FakeProv, bytes: []const u8, i: u32) ?Pair {
        _ = bytes;
        for (self.tokens) |t| if (t.open == i or t.close == i) return t;
        return null;
    }
    pub fn proseLeafAt(self: *FakeProv, i: u32) ?struct { start: u32, end: u32 } {
        const l = self.leaf orelse return null;
        return if (l.start <= i and i < l.end) .{ .start = l.start, .end = l.end } else null;
    }
    pub fn enclosingBracketTokens(self: *FakeProv, bytes: []const u8, pos: u32) ?Pair {
        _ = bytes;
        _ = pos;
        self.enclosing_calls += 1;
        return self.tree_enclosing;
    }
};

test "BRK6 트리 출처 — 토큰이 먼저, 그다음 글 잎 안의 훑기, 그 밖은 괄호가 아니다 (§5.1b ⓐⓑⓒ)" {
    const s = "f(\"(\", x)"; // 문자열 속 '(' 는 토큰이 아니다
    var fake: FakeProv = .{ .tokens = &.{.{ .open = 1, .close = 8 }} };
    const src: Tree(FakeProv) = .{ .prov = &fake, .bytes = s };
    try testing.expectEqual(pr(1, 8), src.pairAt(8));
    try testing.expectEqual(@as(?Pair, null), src.pairAt(3)); // ⓒ — 글자 훑기로 물러서지 않는다(그러면 [3,8] 을 낸다)
    try testing.expectEqual(pr(1, 8), touching(src, s.len, 9)); // 끝 ')' 뒤 — 바른 '('

    // ⓑ 글 잎 — 그 안에서만 짝짓는다
    const md = "a (b) [c";
    var prose: FakeProv = .{ .leaf = .{ .start = 2, .end = 8 } };
    const ms: Tree(FakeProv) = .{ .prov = &prose, .bytes = md };
    try testing.expectEqual(pr(2, 4), ms.pairAt(2));
    try testing.expectEqual(@as(?Pair, null), ms.pairAt(6)); // 안 닫힌 '['
    try testing.expectEqual(@as(?Pair, null), ms.pairAt(99));
}

test "BRK7 트리 출처의 감싸는 쌍 — 글 잎 안이 먼저, 없으면 조상 (§5.1b ③)" {
    // 글 잎 [2,8) 안의 caret 5 — 잎 안의 '(' 3 … ')' 6 이 품는다. 조상은 묻지도 않는다
    const md = "a [(bc)] z";
    var prose: FakeProv = .{ .leaf = .{ .start = 2, .end = 8 }, .tree_enclosing = pr(0, 9) };
    const ms: Tree(FakeProv) = .{ .prov = &prose, .bytes = md };
    try testing.expectEqual(pr(3, 6), ms.enclosing(5));
    try testing.expectEqual(@as(usize, 0), prose.enclosing_calls);
    // 잎 끝에 선 caret(8) — 뒤 글자는 잎 밖이라 앞 글자의 잎을 쓴다: 잎 안에서 품는 쌍이 없어 조상으로
    try testing.expectEqual(pr(0, 9), ms.enclosing(8));
    try testing.expectEqual(@as(usize, 1), prose.enclosing_calls);
    // 잎이 없으면 곧바로 조상
    var code: FakeProv = .{ .tree_enclosing = pr(1, 8) };
    const cs: Tree(FakeProv) = .{ .prov = &code, .bytes = "f(\"(\", x)" };
    try testing.expectEqual(pr(1, 8), cs.enclosing(4));
}
