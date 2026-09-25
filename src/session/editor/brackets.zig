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

/// **괄호 짝으로 점프**(§3.9c)가 caret 을 둘 byte — VS Code `jumpToBracket` 의 세 갈래.
///
/// ① 닿은 괄호가 있으면: 여는 괄호에**만** 닿았으면 닫는 괄호 앞, 닫는 괄호에 닿았으면 여는 괄호 앞(`{|}` 는 둘 다 닿아 여는 괄호 앞).
/// ② 없으면 **감싸는 쌍의 닫는 괄호 앞**(`findEnclosingBrackets` — 강조 `always` 와 같은 판정). ③ 그것도 없으면 **다음 여는 괄호 앞**
/// (`findNextBracket` — caret 바로 뒤 글자도 친다). ②③ 은 출처가 답할 때만이다 — 글자 훑기(`Plain`)는 둘 다 `null` 이다. 갈 데가 없으면 `null`.
pub fn jumpTarget(src: anytype, len: usize, pos: usize) ?usize {
    const at = @min(pos, len);
    if (touchJump(src, len, at)) |t| return t;
    if (src.enclosing(at)) |p| return p.close;
    return src.nextOpen(at);
}

/// **커서 여럿의 점프**(§3.9c) — `positions[i]` 의 도착을 `out[i]` 에(갈 데가 없으면 `null`). 답은 `jumpTarget` 을 커서마다 부른 것과 같다. ③ 다음 여는
/// 괄호는 남은 커서들을 **정렬해 한 번에** 묻는다(`nextOpenMany`) — 커서마다 걸으면 최상위 형제를 커서 수만큼 다시 지난다.
pub fn jumpTargets(src: anytype, len: usize, positions: []const usize, out: []?usize, allocator: std.mem.Allocator) error{OutOfMemory}!void {
    var pending: std.ArrayList(u32) = .empty;
    defer pending.deinit(allocator);
    for (positions, out, 0..) |pos, *o, i| {
        const at = @min(pos, len);
        o.* = touchJump(src, len, at) orelse if (src.enclosing(at)) |p| p.close else null;
        if (o.* == null) try pending.append(allocator, @intCast(i));
    }
    if (pending.items.len == 0) return;
    std.mem.sort(u32, pending.items, positions, struct {
        fn lt(ps: []const usize, a: u32, b: u32) bool {
            return ps[a] < ps[b];
        }
    }.lt);
    const qs = try allocator.alloc(u32, pending.items.len);
    defer allocator.free(qs);
    const got = try allocator.alloc(?u32, pending.items.len);
    defer allocator.free(got);
    for (pending.items, qs) |i, *q| q.* = @intCast(@min(positions[i], len));
    src.nextOpenMany(qs, got);
    for (pending.items, got) |i, g| out[i] = if (g) |k| k else null;
}

/// ① 만 — 닿은 괄호의 짝.
pub fn touchJump(src: anytype, len: usize, pos: usize) ?usize {
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

    /// 다음 여는 괄호도 **안 찾는다**(§3.9c) — 감싸는 쌍을 안 찾는 것과 같은 이유다.
    pub fn nextOpen(self: Plain, pos: usize) ?usize {
        _ = self;
        _ = pos;
        return null;
    }

    pub fn nextOpenMany(self: Plain, positions: []const u32, out: []?u32) void {
        _ = self;
        _ = positions;
        @memset(out, null);
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
        // **`lo` 에서 멈추는 것은 비용이다 — 답은 같다**(적대적 1회차 B12: 0 까지 가도 초록). 뒤로 훑으므로 범위 밖 글자는 범위 안을 다 본 뒤에야
        // 오고, 거기서 찾은 여는 괄호는 `pairAt` 이 범위 밖으로 버린다.
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
            // caret 뒤 글자의 잎만 본다. **잎 끝에 선 caret 을 앞 글자의 잎으로 보지 않는다** — 그 잎 안의 어느 쌍도 닫는 괄호가 `hi - 1` 이하라
            // caret(`hi`)을 품을 수 없다. 처음엔 그 갈래를 두었는데 적대적 1회차(B15)가 지워도 같은 답임을 보였고, 이유가 위 한 줄이라 걷어냈다.
            if (self.prov.proseLeafAt(at)) |l| {
                if ((Scan{ .bytes = self.bytes, .lo = l.start, .hi = l.end }).enclosing(at)) |p| return p;
            }
            const p = self.prov.enclosingBracketTokens(self.bytes, at) orelse return null;
            return .{ .open = p.open, .close = p.close };
        }

        /// **`pos` 이후 첫 여는 괄호**(§3.9c ③ — VS Code `findNextBracket`): ⓐ 괄호 토큰의 여는 괄호이거나 ⓑ 글 잎 속 여는 괄호 글자. 짝은 안
        /// 본다 — 안 닫힌 여는 괄호도 친다(VS Code 실측 `x| ) (` → `(` 앞). 닫는 괄호는 볼 까닭이 없다 — 짝 있는 닫는 괄호는 감싸는 쌍이 먼저
        /// 걸렸거나 그 여는 괄호를 먼저 만나고, 짝 없는 것은 VS Code 도 건너뛴다(`x| )` → 그대로). 트리 걷기는 provider 가 한다(`nextOpenBracket`).
        pub fn nextOpen(self: Self, pos: usize) ?usize {
            const at = @min(pos, self.bytes.len);
            const k = self.prov.nextOpenBracket(self.bytes, @intCast(at)) orelse return null;
            return k;
        }

        /// 여러 caret(**오름차순**)의 다음 여는 괄호를 한 번에 — provider 가 한 번 걷는다(`nextOpenBrackets`).
        pub fn nextOpenMany(self: Self, positions: []const u32, out: []?u32) void {
            self.prov.nextOpenBrackets(self.bytes, positions, out);
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
    // **범위 밖 글자에서는 묻지도 않는다** — 범위 끝 뒤의 ')' 가 범위 안 '(' 와 짝이 **될 수 있는** 표본이라야 갈린다. 위 `leaf.pairAt(4)` 는
    // 짝을 못 찾아 어느 쪽이든 `null` 이었다(적대적 1회차 B7 — 검사를 `bytes.len` 으로 바꿔도 초록이었다).
    try testing.expectEqual(@as(?Pair, null), (Scan{ .bytes = "(a))", .lo = 0, .hi = 2 }).pairAt(2));
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
    /// 짝 없이 괄호 토큰인 여는 괄호 자리(안 닫힌 것).
    lone_opens: []const u32 = &.{},
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
    /// 표의 여는 괄호(짝 있는 것 · 없는 것)와 글 잎 속 여는 괄호 글자 중 `pos` 이후 첫 것 — `Provider.nextOpenBracket` 의 정의 그대로.
    pub fn nextOpenBracket(self: *FakeProv, bytes: []const u8, pos: u32) ?u32 {
        var best: ?u32 = null;
        for (self.tokens) |t| if (t.open >= pos and (best == null or t.open < best.?)) {
            best = t.open;
        };
        for (self.lone_opens) |o| if (o >= pos and (best == null or o < best.?)) {
            best = o;
        };
        if (self.leaf) |l| {
            var k = @max(l.start, pos);
            while (k < l.end and k < bytes.len) : (k += 1) {
                const b = bracketOf(bytes[k]) orelse continue;
                if (b.open) {
                    if (best == null or k < best.?) best = k;
                    break;
                }
            }
        }
        return best;
    }
    pub fn nextOpenBrackets(self: *FakeProv, bytes: []const u8, positions: []const u32, out: []?u32) void {
        for (positions, out) |p, *o| o.* = self.nextOpenBracket(bytes, p);
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
    // 잎 끝에 선 caret(8) — 뒤 글자는 잎 밖이라 곧바로 조상으로(앞 잎을 봐도 품는 쌍이 있을 수 없다)
    try testing.expectEqual(pr(0, 9), ms.enclosing(8));
    try testing.expectEqual(@as(usize, 1), prose.enclosing_calls);
    // 잎이 없으면 곧바로 조상
    var code: FakeProv = .{ .tree_enclosing = pr(1, 8) };
    const cs: Tree(FakeProv) = .{ .prov = &code, .bytes = "f(\"(\", x)" };
    try testing.expectEqual(pr(1, 8), cs.enclosing(4));
}

test "BRJ1 점프 — 닿은 괄호가 없으면 감싸는 쌍의 닫는 괄호 앞, 없으면 다음 여는 괄호 앞; 글자 훑기는 둘 다 안 한다 (§3.9c, VS Code 실측)" {
    // ① 감싸는 쌍 — `f("(", x)` 의 x(7) 앞: 닿은 괄호가 없어 트리가 준 (1,8) 의 닫는 괄호 앞. 닿았으면 닿은 쪽이 이긴다(8 뒤 → 여는 괄호 1).
    const call = "f(\"(\", x)";
    var enc: FakeProv = .{ .tokens = &.{.{ .open = 1, .close = 8 }}, .tree_enclosing = pr(1, 8) };
    const es: Tree(FakeProv) = .{ .prov = &enc, .bytes = call };
    try testing.expectEqual(@as(?usize, 8), jumpTarget(es, call.len, 7));
    try testing.expectEqual(@as(?usize, 1), jumpTarget(es, call.len, 9));
    // **감싸는 쌍이 다음 여는 괄호보다 먼저다** — 뒤에 여는 괄호(11)가 있어도 7 에서는 닫는 괄호(8) 앞(적대적 3회차: ②③ 을 바꿔도 위 줄은 초록이었다)
    const call2 = "f(\"(\", x) (";
    var enc2: FakeProv = .{ .tokens = &.{.{ .open = 1, .close = 8 }}, .lone_opens = &.{10}, .tree_enclosing = pr(1, 8) };
    const es2: Tree(FakeProv) = .{ .prov = &enc2, .bytes = call2 };
    try testing.expectEqual(@as(?usize, 8), jumpTarget(es2, call2.len, 7));
    // ① 만(`touchJump`) — 닿은 괄호가 없으면 감싸는 쌍·다음 괄호로 안 간다
    try testing.expectEqual(@as(?usize, null), touchJump(es2, call2.len, 7));
    try testing.expectEqual(@as(?usize, 1), touchJump(es2, call2.len, 9));
    // ② 다음 여는 괄호 — `a ( ) x (b) (`: 2 는 괄호 토큰이 아니고(문자열 속), 4 는 닫는 괄호, 8 이 첫 여는 괄호 토큰이다. 12 는 안 닫힌 여는 괄호
    // 토큰 — 짝이 없어도 친다. caret 바로 뒤 글자도 「다음」이다(12 에서 제자리).
    const s = "a ( ) x (b) (";
    var nx: FakeProv = .{ .tokens = &.{.{ .open = 8, .close = 10 }}, .lone_opens = &.{12} };
    const ns: Tree(FakeProv) = .{ .prov = &nx, .bytes = s };
    try testing.expectEqual(@as(?usize, 8), jumpTarget(ns, s.len, 0));
    try testing.expectEqual(@as(?usize, 12), jumpTarget(ns, s.len, 12));
    try testing.expectEqual(@as(?usize, null), jumpTarget(ns, s.len, 13)); // 뒤에 없다
    // ⓑ 글 잎 속 '(' 는 괄호다 — 잎 [0, 4) 안의 2
    var pl: FakeProv = .{ .tokens = &.{.{ .open = 8, .close = 10 }}, .leaf = .{ .start = 0, .end = 4 } };
    const ps: Tree(FakeProv) = .{ .prov = &pl, .bytes = s };
    try testing.expectEqual(@as(?usize, 2), jumpTarget(ps, s.len, 0));
    // **출처가 답한 자리 그대로 쓴다** — 짝을 다시 보거나 앞으로 되돌리지 않는다(caret 바로 뒤 글자 12 도 그대로)
    try testing.expectEqual(@as(?usize, 12), ns.nextOpen(12));
    try testing.expectEqual(@as(?usize, 8), ns.nextOpen(3));
    // **커서 여럿**(`jumpTargets`) — 순서가 섞인 자리들에서 `jumpTarget` 을 하나씩 부른 것과 같다(③ 은 정렬해 한 번에 묻는다)
    {
        const carets = [_]usize{ 12, 0, 7, 13, 3, 12 };
        var outs: [carets.len]?usize = undefined;
        try jumpTargets(ns, s.len, &carets, &outs, testing.allocator);
        for (carets, outs) |p, o| try testing.expectEqual(jumpTarget(ns, s.len, p), o);
        const carets2 = [_]usize{ 9, 7, 11 };
        try jumpTargets(es2, call2.len, &carets2, outs[0..3], testing.allocator);
        for (carets2, outs[0..3]) |p, o| try testing.expectEqual(jumpTarget(es2, call2.len, p), o);
        try testing.expectEqual(@as(?usize, 1), outs[0]); // 9 — 닿은 ')' → 여는 괄호
        try testing.expectEqual(@as(?usize, 8), outs[1]); // 7 — 감싸는 쌍
    }
    // **글자 훑기는 감싸는 쌍도 다음 괄호도 안 찾는다**(§3.9c — 문자열 속 괄호를 센다)
    try testing.expectEqual(@as(?usize, null), jumpTarget(Plain{ .bytes = "(a b)" }, 5, 2));
    try testing.expectEqual(@as(?usize, null), jumpTarget(Plain{ .bytes = "x (a)" }, 5, 0));
}
