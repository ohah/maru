//! 짝 괄호 판정 — **강조**([시각 매핑](../../../docs/native-editor-visual-mapping.md) §5.1b)와 **점프**
//! ([문서 모델](../../../docs/native-editor-document-model.md) §3.9c)가 같이 쓴다. 강조가 가리키는 쌍과 점프가 가는 곳이 갈리면
//! 사용자는 둘 중 무엇을 믿을지 모른다.
//!
//! **괄호 목록과 짝은 색 판정과 공유한다.** `Index`는 그 결과에 조회용 위치만 덧붙인다. 트리에서 짝을 따로 찾지 않는다. 문법이 없는 문서는 글자 기반 판정(`Plain`)을 쓰고,
//! 그 출처는 감싸는 쌍을 찾지 않는다. 출처는 「byte `i`의 괄호의 짝」(`pairAt`)과 「caret을 품는 가장 안쪽 쌍」(`enclosing`)을 답한다.
//! 어느 괄호를 고르는가(뒤 먼저)·감싸는 쌍으로 물러서는가·점프가 어디로 가는가는 아래 함수들이 정한다.
//!
//! `Index`는 토큰의 byte 범위를 그대로 쓴다. `Plain`은 ASCII 괄호 여섯만 세므로 UTF-8 연속 byte(`0x80`–`0xBF`)와 겹치지 않는다.
const std = @import("std");
const bracket_colors = @import("bracket_colors.zig");

/// 괄호 한 쌍 — 두 괄호의 문서 절대 byte(`open < close`)와 각각의 byte 길이. `${`처럼 여러 글자도 하나의 괄호다.
pub const Pair = struct { open: u32, close: u32, open_len: u8 = 1, close_len: u8 = 1 };

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

/// **커서 여럿의 점프**(§3.9c) — `positions[i]` 의 도착을 `out[i]` 에(갈 데가 없으면 `null`). 답은 `jumpTarget` 을 커서마다 부른 것과 같다.
/// ③ 다음 여는 괄호가 필요한 자리만 정렬해 묻고(`nextOpenMany`), 결과를 원래 커서 순서로 돌려놓는다.
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
    const on_close = at >= p.close and at <= @as(usize, p.close) + p.close_len;
    return if (on_close) p.open else p.close;
}

/// 색 판정(`bracket_colors.resolve`)이 만든 짝으로 강조·점프를 찾는다. 새 짝을 만들지 않는다.
///
/// 문서가 바뀔 때 한 번 O(괄호 수)로 만든다. 각 괄호 뒤의 감싸는 쌍과 다음 여는 괄호를 기억하므로,
/// caret 하나의 조회는 위치 이진 탐색 O(log 괄호 수)다. 커서마다 문서 전체를 다시 훑지 않는다.
pub const Index = struct {
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct {
        partner: u32,
        enclosing_after: u32,
        next_open: u32,
    };

    pub fn deinit(self: *Index, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
        self.* = .{};
    }

    /// `tokens`와 `partners`는 같은 `resolve` 실행의 결과여야 한다. 토큰은 겹치지 않는 위치 오름차순이다.
    pub fn rebuild(self: *Index, allocator: std.mem.Allocator, tokens: []const bracket_colors.Token, partners: []const u32) error{OutOfMemory}!void {
        std.debug.assert(partners.len >= tokens.len and tokens.len < bracket_colors.ignored);
        try self.entries.resize(allocator, tokens.len);
        var enclosing: u32 = bracket_colors.none;
        for (tokens, self.entries.items, 0..) |t, *entry, i| {
            std.debug.assert(t.len > 0);
            if (i > 0) std.debug.assert(@as(usize, tokens[i - 1].start) + tokens[i - 1].len <= t.start);
            const p = partners[i];
            if (p < tokens.len) {
                if (t.open) {
                    enclosing = @intCast(i);
                } else {
                    // 짝의 여는 괄호 바로 전 상태가 바깥 쌍이다. 중간의 짝 없는 괄호는 감싸는 쌍이 아니다.
                    enclosing = if (p > 0) self.entries.items[p - 1].enclosing_after else bracket_colors.none;
                }
            }
            entry.* = .{ .partner = p, .enclosing_after = enclosing, .next_open = bracket_colors.none };
        }
        var next: u32 = bracket_colors.none;
        var i = tokens.len;
        while (i > 0) {
            i -= 1;
            // 안 닫힌 여는 괄호도 점프 후보지만 깊이 가드로 글자가 된 괄호는 후보가 아니다.
            if (tokens[i].open and partners[i] != bracket_colors.ignored) next = @intCast(i);
            self.entries.items[i].next_open = next;
        }
    }

    /// 빌드에 쓴 토큰을 빌려 쓴다. 출처를 쓰는 동안 토큰·인덱스를 고치거나 해제하면 안 된다.
    pub fn source(self: *const Index, tokens: []const bracket_colors.Token) Source {
        std.debug.assert(tokens.len == self.entries.items.len);
        return .{ .tokens = tokens, .entries = self.entries.items };
    }

    pub const Source = struct {
        tokens: []const bracket_colors.Token,
        entries: []const Entry,

        /// 시작이 `pos` 이상인 첫 토큰. 없으면 길이를 돌려준다.
        fn lowerBound(self: Source, pos: usize) usize {
            var lo: usize = 0;
            var hi = self.tokens.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (self.tokens[mid].start < pos) lo = mid + 1 else hi = mid;
            }
            return lo;
        }

        fn pair(self: Source, i: usize) ?Pair {
            const p = self.entries[i].partner;
            if (p >= self.tokens.len) return null;
            const o = self.tokens[if (self.tokens[i].open) i else p];
            const c = self.tokens[if (self.tokens[i].open) p else i];
            return .{ .open = o.start, .close = c.start, .open_len = o.len, .close_len = c.len };
        }

        /// 토큰 범위의 모든 byte가 같은 괄호다. `${`의 `$`와 `{`는 같은 짝을 가리킨다.
        pub fn pairAt(self: Source, pos: usize) ?Pair {
            var i = self.lowerBound(pos);
            if (i == self.tokens.len or self.tokens[i].start != pos) {
                if (i == 0) return null;
                i -= 1;
            }
            const t = self.tokens[i];
            if (pos - t.start >= t.len) return null;
            return self.pair(i);
        }

        /// `open < pos < close + close_len`인 가장 안쪽 쌍. 여러 byte 닫는 괄호의 안쪽도 그 쌍 안이다.
        pub fn enclosing(self: Source, pos: usize) ?Pair {
            const i = self.lowerBound(pos);
            if (i == 0) return null;
            const prev = self.tokens[i - 1];
            if (!prev.open and pos - prev.start < prev.len) {
                if (self.pair(i - 1)) |p| return p;
            }
            const p = self.entries[i - 1].enclosing_after;
            return if (p < self.tokens.len) self.pair(p) else null;
        }

        /// caret을 포함하는 여는 괄호가 있으면 그것, 아니면 뒤의 첫 여는 괄호. 토큰의 끝은 포함하지 않는다.
        pub fn nextOpen(self: Source, pos: usize) ?usize {
            const i = self.lowerBound(pos);
            if (i > 0) {
                const prev = self.tokens[i - 1];
                if (prev.open and pos - prev.start < prev.len and self.entries[i - 1].partner != bracket_colors.ignored) return prev.start;
            }
            if (i == self.tokens.len) return null;
            const p = self.entries[i].next_open;
            return if (p < self.tokens.len) self.tokens[p].start else null;
        }

        /// 커서 수 × log(괄호 수). 문서의 같은 형제들을 커서마다 처음부터 걷지 않는다.
        pub fn nextOpenMany(self: Source, positions: []const u32, out: []?u32) void {
            std.debug.assert(positions.len == out.len);
            for (positions, out) |pos, *target| target.* = if (self.nextOpen(pos)) |p| @intCast(p) else null;
        }
    };
};

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

/// `[lo, hi)` 안의 **글자 훑기**(§3.9c) — 같은 종류만 깊이로 센다. 문법 없는 문서의 `Plain`이 쓴다.
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
    // 글자 훑기는 감싸는 쌍도 다음 괄호도 찾지 않는다 — 문자열 안의 괄호를 구분할 수 없다.
    try testing.expectEqual(@as(?usize, null), J.j("(a b)", 2));
    try testing.expectEqual(@as(?usize, null), J.j("x (a)", 0));
}

// 색 판정이 남긴 짝을 매번 처음부터 훑는 비교자. 제품 인덱스의 이전/다음 링크를 쓰지 않는다.
const ResolvedOracle = struct {
    tokens: []const bracket_colors.Token,
    partners: []const u32,

    fn pair(self: ResolvedOracle, i: usize) ?Pair {
        const p = self.partners[i];
        if (p >= self.tokens.len) return null;
        const o = self.tokens[if (self.tokens[i].open) i else p];
        const c = self.tokens[if (self.tokens[i].open) p else i];
        return .{ .open = o.start, .close = c.start, .open_len = o.len, .close_len = c.len };
    }

    pub fn pairAt(self: ResolvedOracle, pos: usize) ?Pair {
        for (self.tokens, 0..) |t, i| {
            if (pos >= t.start and pos - t.start < t.len) return self.pair(i);
        }
        return null;
    }

    pub fn enclosing(self: ResolvedOracle, pos: usize) ?Pair {
        var result: ?Pair = null;
        for (self.tokens, 0..) |t, i| {
            if (!t.open) continue;
            const p = self.pair(i) orelse continue;
            if (p.open < pos and pos < @as(usize, p.close) + p.close_len) result = p;
        }
        return result;
    }

    pub fn nextOpen(self: ResolvedOracle, pos: usize) ?usize {
        for (self.tokens, self.partners) |t, p| {
            if (t.open and p != bracket_colors.ignored and @as(usize, t.start) + t.len > pos) return t.start;
        }
        return null;
    }
};

fn compareResolvedIndex(tokens: []const bracket_colors.Token, len: usize) !void {
    const a = testing.allocator;
    const info = try a.alloc(bracket_colors.Info, tokens.len);
    defer a.free(info);
    const partners = try a.alloc(u32, tokens.len);
    defer a.free(partners);
    const stack = try a.alloc(u32, tokens.len);
    defer a.free(stack);
    bracket_colors.resolve(tokens, false, info, partners, stack);
    const oracle: ResolvedOracle = .{ .tokens = tokens, .partners = partners };
    var index: Index = .{};
    defer index.deinit(a);
    try index.rebuild(a, tokens, partners);
    const src = index.source(tokens);
    // 괄호 안, 바로 전후, 괄호 사이, 문서 끝 밖을 모두 비교한다.
    for (0..len + 3) |pos| {
        try testing.expectEqual(oracle.pairAt(pos), src.pairAt(pos));
        try testing.expectEqual(oracle.enclosing(pos), src.enclosing(pos));
        try testing.expectEqual(oracle.nextOpen(pos), src.nextOpen(pos));
        try testing.expectEqual(jumpTarget(oracle, len, pos), jumpTarget(src, len, pos));
        for ([_]Mode{ .never, .near, .always }) |mode| {
            try testing.expectEqual(forHighlight(oracle, len, pos, mode), forHighlight(src, len, pos, mode));
        }
    }
    // 정렬되지 않은 192개 caret — 다음 괄호가 필요한 자리와 짝에 닿은 자리를 섞는다.
    var positions: [192]usize = undefined;
    var targets: [positions.len]?usize = undefined;
    for (&positions, 0..) |*pos, i| pos.* = (positions.len - i) * 17 % (len + 3);
    try jumpTargets(src, len, &positions, &targets, a);
    for (positions, targets) |pos, got| try testing.expectEqual(jumpTarget(oracle, len, pos), got);
    // 재사용한 인덱스가 예전 문서의 짝을 남기지 않는다.
    try index.rebuild(a, &.{}, &.{});
    try testing.expectEqual(@as(?Pair, null), index.source(&.{}).pairAt(0));
    try testing.expectEqual(@as(?Pair, null), index.source(&.{}).enclosing(10));
    try testing.expectEqual(@as(?usize, null), index.source(&.{}).nextOpen(0));
}

test "BRI1 색과 점프가 같은 짝 — 어긋난 중첩, 색칠하지 않는 쌍, 여러 byte 괄호" {
    const toks = [_]bracket_colors.Token{
        .{ .start = 1, .close_kind = 0, .open = true }, // (
        .{ .start = 2, .close_kind = 2, .open = true }, // { — 뒤의 )가 이 여는 괄호를 버린다
        .{ .start = 3, .close_kind = 0, .open = false }, // )
        .{ .start = 4, .close_kind = 2, .open = false }, // } — 짝이 없다
        .{ .start = 7, .len = 2, .close_kind = 2, .open = true, .colorized = false }, // ${
        .{ .start = 12, .len = 3, .close_kind = 2, .open = false }, // 여러 byte 닫는 괄호도 범위 전체가 닿는다
        .{ .start = 17, .close_kind = 1, .open = true }, // 짝 없는 [ 도 다음 여는 괄호다
    };
    try compareResolvedIndex(&toks, 18);
    const partners = [_]u32{ 2, bracket_colors.none, 0, bracket_colors.none, 5, 4, bracket_colors.none };
    var index: Index = .{};
    defer index.deinit(testing.allocator);
    try index.rebuild(testing.allocator, &toks, &partners);
    const src = index.source(&toks);
    try testing.expectEqual(@as(?Pair, null), src.pairAt(2));
    try testing.expectEqual(@as(?Pair, null), src.pairAt(4));
    const dollar: ?Pair = .{ .open = 7, .close = 12, .open_len = 2, .close_len = 3 };
    for (7..9) |pos| try testing.expectEqual(dollar, src.pairAt(pos));
    for (7..10) |pos| try testing.expectEqual(@as(?usize, 12), touchJump(src, 18, pos));
    for (12..16) |pos| try testing.expectEqual(@as(?usize, 7), touchJump(src, 18, pos));
    try testing.expectEqual(@as(?usize, 17), src.nextOpen(15));
}

test "BRI2 실제 색 판정의 깊이 가드는 점프에서도 글자 — 짝 없는 여는 괄호와 구분" {
    var toks: [bracket_colors.max_depth + 2]bracket_colors.Token = undefined;
    for (&toks, 0..) |*t, i| t.* = .{ .start = @intCast(i * 2), .close_kind = 0, .open = true };
    try compareResolvedIndex(&toks, toks.len * 2);
}

test "BRI3 임의의 뒤섞인 괄호 문서 모든 caret — 선형 비교자와 같은 강조와 다중 점프" {
    var random = std.Random.DefaultPrng.init(0xB4AC_4E75);
    const rng = random.random();
    var toks: [80]bracket_colors.Token = undefined;
    for (0..32) |_| {
        var end: u32 = 0;
        for (&toks) |*t| {
            t.* = .{
                .start = end + rng.uintLessThan(u32, 4),
                .len = 1 + rng.uintLessThan(u8, 3),
                .close_kind = rng.uintLessThan(u8, 3),
                .open = rng.boolean(),
                .colorized = rng.boolean(),
            };
            end = t.start + t.len;
        }
        try compareResolvedIndex(&toks, end);
    }
}

test "BRI4 여러 byte 괄호 안의 caret — Monaco 0.56 실측의 다음 괄호와 감싸는 쌍" {
    // 실측 `x ${`에서 offset 2와 3의 점프는 2, offset 4는 갈 곳이 없다.
    const unmatched = [_]bracket_colors.Token{.{ .start = 2, .len = 2, .close_kind = 2, .open = true }};
    try compareResolvedIndex(&unmatched, 4);
    var index: Index = .{};
    defer index.deinit(testing.allocator);
    try index.rebuild(testing.allocator, &unmatched, &.{bracket_colors.none});
    const src = index.source(&unmatched);
    try testing.expectEqual(@as(?usize, 2), jumpTarget(src, 4, 2));
    try testing.expectEqual(@as(?usize, 2), jumpTarget(src, 4, 3));
    try testing.expectEqual(@as(?usize, null), jumpTarget(src, 4, 4));

    // 실측 `x begin z end`에서 감싸는 쌍은 offset 3..12, 닫는 괄호 끝인 13은 쌍 밖이다.
    const words = [_]bracket_colors.Token{
        .{ .start = 2, .len = 5, .close_kind = 0, .open = true },
        .{ .start = 10, .len = 3, .close_kind = 0, .open = false },
    };
    try compareResolvedIndex(&words, 13);
    try index.rebuild(testing.allocator, &words, &.{ 1, 0 });
    const word_src = index.source(&words);
    const expected: ?Pair = .{ .open = 2, .open_len = 5, .close = 10, .close_len = 3 };
    for (3..13) |pos| try testing.expectEqual(expected, word_src.enclosing(pos));
    try testing.expectEqual(@as(?Pair, null), word_src.enclosing(13));
}

test "BRI5 완성된 색 판정 출처 — 닿은 쌍, 감싸는 쌍, 다음 여는 괄호 순서와 강조 모드" {
    const text = "f(\"(\", x) (";
    // 문자열 안의 '('는 인식 목록에 없다. 뒤의 '('는 짝이 없어도 다음 괄호 후보다.
    const tokens = [_]bracket_colors.Token{
        .{ .start = 1, .close_kind = 0, .open = true },
        .{ .start = 8, .close_kind = 0, .open = false },
        .{ .start = 10, .close_kind = 0, .open = true },
    };
    var info: [tokens.len]bracket_colors.Info = undefined;
    var partners: [tokens.len]u32 = undefined;
    var stack: [tokens.len]u32 = undefined;
    bracket_colors.resolve(&tokens, false, &info, &partners, &stack);
    var index: Index = .{};
    defer index.deinit(testing.allocator);
    try index.rebuild(testing.allocator, &tokens, &partners);
    const src = index.source(&tokens);
    try testing.expectEqual(@as(?Pair, null), src.pairAt(3));
    try testing.expectEqual(pr(1, 8), src.pairAt(8));
    // 감싸는 쌍이 뒤의 여는 괄호보다 먼저, 닿은 닫는 괄호에서는 여는 쪽으로 돌아간다.
    try testing.expectEqual(@as(?usize, 10), src.nextOpen(7));
    try testing.expectEqual(@as(?usize, 8), jumpTarget(src, text.len, 7));
    try testing.expectEqual(@as(?usize, null), touchJump(src, text.len, 7));
    try testing.expectEqual(@as(?usize, 1), touchJump(src, text.len, 9));
    try testing.expectEqual(@as(?usize, 1), jumpTarget(src, text.len, 0));
    try testing.expectEqual(@as(?usize, 10), jumpTarget(src, text.len, 10));
    try testing.expectEqual(@as(?usize, null), jumpTarget(src, text.len, 11));
    try testing.expectEqual(@as(?Pair, null), forHighlight(src, text.len, 7, .near));
    try testing.expectEqual(pr(1, 8), forHighlight(src, text.len, 7, .always));
    try testing.expectEqual(@as(?Pair, null), forHighlight(src, text.len, 7, .never));
    try testing.expectEqual(pr(1, 8), forHighlight(src, text.len, 2, .near));
    try testing.expectEqual(@as(?Pair, null), forHighlight(src, text.len, 2, .never));
    const positions = [_]usize{ 10, 7, 0, 11, 9, 10 };
    var targets: [positions.len]?usize = undefined;
    try jumpTargets(src, text.len, &positions, &targets, testing.allocator);
    try testing.expectEqualSlices(?usize, &.{ 10, 8, 1, null, 1, 10 }, &targets);
}
