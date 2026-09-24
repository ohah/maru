//! 괄호 쌍 색 — 문서 전체 괄호 목록에서 **짝 · 단계 · 무효**를 정한다([시각 매핑](../../../docs/native-editor-visual-mapping.md) §5.1d).
//!
//! 규칙은 VS Code 의 괄호 파서(`bracketPairsTree/parser.ts`)와 색 수집(`bracketPairsTree.ts` `collectBrackets`) 그대로다 — 스택과 같다:
//! 여는 괄호는 쌓는다. 닫는 괄호는 스택 안에 **그것으로 닫을 수 있는 여는 괄호가 있으면** 그 위의 여는 괄호들을 「짝 없음」으로 내리고 그것과
//! 짝을 짓는다 — 없으면 「튀는 닫는 괄호」. 문서 끝에 남은 여는 괄호도 짝 없음. **짝 없음 · 튀는 괄호가 무효**다. 단계는 **바깥의 색칠 쌍 수**다.
//!
//! **여는 괄호의 유효 여부는 문서 뒤쪽에 달려 있다**(`f(x` 는 뒤에 `)` 가 없어야 무효) — 그래서 입력은 창이 아니라 **문서 전체** 목록이고, 두 번
//! 훑는다: ① 짝 맞추기 ② 단계 매기기(색칠 여부가 ①의 결과 — 짝 없는 여는 괄호는 색칠 쌍이 아니어도 색을 받는다 — 에 달려서).
//!
//! 무엇이 괄호인가(문자열·주석 거르기, 언어별 괄호 문자열)는 여기서 모른다 — 호출자가 목록을 만든다.
const std = @import("std");

/// 이 깊이(열린 괄호 수)에서 새로 여는 괄호는 **글자**다 — VS Code 파서의 깊이 가드(`level > 300`, 한 겹에 둘씩 센다). monaco 0.56 실측:
/// `(`×151 이면 151 번째가 괄호에서 빠지고 그 짝이던 `)` 하나가 튀는 괄호가 된다.
pub const max_depth: usize = 150;

/// 문서의 괄호 하나. 목록은 **위치 오름차순**이다.
pub const Token = struct {
    /// 칠하는 byte 범위의 시작.
    start: u32,
    /// 칠하는 byte 수 — 대개 1, JavaScript 의 `${` 는 2.
    len: u8 = 1,
    /// 짝을 맞추는 **닫는 괄호의 종류**. 여는 괄호면 기대하는 닫는 괄호, 닫는 괄호면 자기 — `}` 하나를 `{` 와 `${` 가 같이 쓴다.
    close_kind: u8,
    /// **여는 괄호 문자열의 종류**(독립 풀의 단계를 가른다 — VS Code 는 여는 괄호의 글자로 센다). 닫는 괄호면 뜻이 없다.
    open_kind: u8 = 0,
    open: bool,
    /// 이 여는 괄호의 쌍이 **색칠 쌍**인가(`colorizedBracketPairs`). 닫는 괄호면 뜻이 없다.
    colorized: bool = true,
};

/// 괄호 하나의 판정.
pub const Info = struct {
    /// 칠하는가 — 무효이거나, 색칠 쌍의 괄호.
    colored: bool = false,
    invalid: bool = false,
    /// 단계(0 부터). 독립 풀이면 **같은 여는 괄호끼리** 센다. 무효면 뜻이 없다(색이 하나다).
    level: u16 = 0,
};

/// 종류 수의 상한(독립 풀의 칸).
pub const max_kinds: usize = 8;

const none = std.math.maxInt(u32);

/// `tokens` 의 판정을 `out` 에 쓴다(길이가 같아야 한다). `partner`·`stack` 은 호출자가 주는 작업 칸(각각 `tokens.len` 이상).
pub fn resolve(tokens: []const Token, independent: bool, out: []Info, partner: []u32, stack: []u32) void {
    std.debug.assert(out.len == tokens.len and partner.len >= tokens.len and stack.len >= tokens.len);
    // ① 짝 맞추기. `partner[i]` = 짝의 자리(없으면 `none`). 깊이 가드로 글자가 된 여는 괄호는 `ignored` 로 적는다(`out[i].colored` 는 거짓 그대로).
    var sp: usize = 0;
    for (tokens, 0..) |t, i| {
        out[i] = .{};
        partner[i] = none;
        if (t.open) {
            if (sp >= max_depth) {
                partner[i] = ignored;
                continue;
            }
            stack[sp] = @intCast(i);
            sp += 1;
            continue;
        }
        // 닫는 괄호 — 위에서부터 닫을 수 있는 여는 괄호를 찾는다. 그 위의 것들은 짝 없음으로 내린다(`partner` 는 `none` 그대로).
        var k = sp;
        while (k > 0) {
            k -= 1;
            const o = stack[k];
            if (tokens[o].close_kind == t.close_kind) {
                partner[o] = @intCast(i);
                partner[i] = o;
                sp = k;
                break;
            }
        }
    }

    // ② 단계. 스택에는 열린 여는 괄호, `cur` 은 그중 **색을 받는** 것의 수(종류별은 `per_kind`).
    var cur: u16 = 0;
    var per_kind = [_]u16{0} ** max_kinds;
    sp = 0;
    for (tokens, 0..) |t, i| {
        if (t.open) {
            if (partner[i] == ignored) continue;
            // 짝 없는 여는 괄호는 색칠 쌍이 아니어도 색을 받는다(`collectBrackets`: `!node.closingBracket` 이면 `colorize`).
            const incomplete = partner[i] == none;
            const colored = incomplete or t.colorized;
            if (colored) {
                const kind = @min(t.open_kind, max_kinds - 1);
                out[i] = .{ .colored = true, .invalid = incomplete, .level = if (independent) per_kind[kind] else cur };
                cur += 1;
                per_kind[kind] += 1;
            }
            stack[sp] = @intCast(i);
            sp += 1;
            continue;
        }
        const p = partner[i];
        if (p == none) {
            // 튀는 닫는 괄호 — 늘 칠한다(빨강). 단계는 뜻이 없다.
            out[i] = .{ .colored = true, .invalid = true };
            continue;
        }
        // 짝까지 내린다 — 그 위의 짝 없는 여는 괄호들이 먼저 닫힌다.
        while (sp > 0) {
            sp -= 1;
            const o = stack[sp];
            if (out[o].colored) {
                cur -= 1;
                per_kind[@min(tokens[o].open_kind, max_kinds - 1)] -= 1;
            }
            if (o == p) break;
        }
        if (out[p].colored) out[i] = .{ .colored = true, .level = out[p].level };
    }
}

/// 깊이 가드로 글자가 된 여는 괄호의 표시(① → ②).
const ignored = none - 1;

// ── 판정자 ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// 판정자용 글자 훑기 — `()[]{}` 와 `${`(가장 긴 것 먼저). 닫는 종류: `)`0 `]`1 `}`2 · 여는 종류: `(`0 `[`1 `{`2 `${`3.
fn scanForTest(text: []const u8, colorize_dollar: bool, out: []Token) []Token {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        const tok: ?Token = switch (ch) {
            '$' => if (i + 1 < text.len and text[i + 1] == '{') .{ .start = @intCast(i), .len = 2, .close_kind = 2, .open_kind = 3, .open = true, .colorized = colorize_dollar } else null,
            '(' => .{ .start = @intCast(i), .close_kind = 0, .open_kind = 0, .open = true },
            '[' => .{ .start = @intCast(i), .close_kind = 1, .open_kind = 1, .open = true },
            '{' => .{ .start = @intCast(i), .close_kind = 2, .open_kind = 2, .open = true },
            ')' => .{ .start = @intCast(i), .close_kind = 0, .open = false },
            ']' => .{ .start = @intCast(i), .close_kind = 1, .open = false },
            '}' => .{ .start = @intCast(i), .close_kind = 2, .open = false },
            else => null,
        };
        if (tok) |t| {
            out[n] = t;
            n += 1;
            i += t.len - 1;
        }
    }
    return out[0..n];
}

const Resolved = struct {
    tokens: []Token,
    info: []Info,
    fn deinit(self: Resolved, a: std.mem.Allocator) void {
        a.free(self.tokens);
        a.free(self.info);
    }
};

fn resolveText(a: std.mem.Allocator, text: []const u8, colorize_dollar: bool, independent: bool) !Resolved {
    const buf = try a.alloc(Token, text.len + 1);
    errdefer a.free(buf);
    const toks = scanForTest(text, colorize_dollar, buf);
    const info = try a.alloc(Info, toks.len);
    errdefer a.free(info);
    const partner = try a.alloc(u32, toks.len);
    defer a.free(partner);
    const stack = try a.alloc(u32, toks.len);
    defer a.free(stack);
    resolve(toks, independent, info, partner, stack);
    return .{ .tokens = buf, .info = info };
}

test "BPC1 짝 · 단계 · 무효 — VS Code 스택 그대로 (§5.1d, monaco 0.56 실측 사례)" {
    const a = testing.allocator;
    const Want = struct { at: u32, level: u16 = 0, invalid: bool = false };
    const Case = struct { text: []const u8, want: []const Want };
    const cases = [_]Case{
        // 종류와 무관하게 바깥 쌍의 수
        .{ .text = "a(b[c{d}e]f)g", .want = &.{ .{ .at = 1 }, .{ .at = 3, .level = 1 }, .{ .at = 5, .level = 2 }, .{ .at = 7, .level = 2 }, .{ .at = 9, .level = 1 }, .{ .at = 11 } } },
        // 닫는 괄호가 바깥 짝을 닫으면 그 사이의 여는 괄호는 짝 없음 · 뒤따르는 `}` 는 튀는 괄호
        .{ .text = "({)}", .want = &.{ .{ .at = 0 }, .{ .at = 1, .invalid = true }, .{ .at = 2 }, .{ .at = 3, .invalid = true } } },
        .{ .text = "f(x", .want = &.{.{ .at = 1, .invalid = true }} },
        .{ .text = "x)", .want = &.{.{ .at = 1, .invalid = true }} },
        .{ .text = "(]", .want = &.{ .{ .at = 0, .invalid = true }, .{ .at = 1, .invalid = true } } },
        // 짝 없는 여는 괄호도 안쪽 단계를 올린다
        .{ .text = "{[(]}", .want = &.{ .{ .at = 0 }, .{ .at = 1, .level = 1 }, .{ .at = 2, .level = 2, .invalid = true }, .{ .at = 3, .level = 1 }, .{ .at = 4 } } },
    };
    for (cases) |c| {
        errdefer std.debug.print("BPC1 {s}\n", .{c.text});
        const r = try resolveText(a, c.text, true, false);
        defer r.deinit(a);
        var got: usize = 0;
        for (r.tokens[0..r.info.len], r.info) |t, inf| {
            if (!inf.colored) continue;
            try testing.expect(got < c.want.len);
            const w = c.want[got];
            try testing.expectEqual(w.at, t.start);
            try testing.expectEqual(w.invalid, inf.invalid);
            if (!inf.invalid) try testing.expectEqual(w.level, inf.level);
            got += 1;
        }
        try testing.expectEqual(c.want.len, got);
    }
}

test "BPC2 VS Code 와 대조 — monaco 0.56 이 낸 판 224 개(괄호 6,016 · 무효 2,048)와 괄호마다 같다 (§5.1d)" {
    // 무작위 괄호열 · `${` 를 칠하는 언어와 안 칠하는 언어(TS 는 `colorizedBracketPairs` 에서 뺀다) · 독립 풀 켬/끔 · 150 을 넘는 중첩. 뽑은 자리:
    // scratchpad `monaco/bpc_oracle.mjs`(1,652 판 전체도 로컬에서 불일치 0 — 대조가 살아 있는지: 「짝 없는 여는 괄호는 색칠 쌍이 아니어도 칠한다」를
    // 빼면 608 판, 깊이 가드를 151 로 옮기면 12 판이 갈렸다).
    const a = testing.allocator;
    const C = struct { t: []const u8, d: bool, i: bool, b: []const [3]i32 };
    const Doc = struct { source: []const u8, cases: []const C };
    const parsed = try std.json.parseFromSlice(Doc, a, @embedFile("testdata/bracket_colors_monaco.json"), .{});
    defer parsed.deinit();
    var brackets: usize = 0;
    for (parsed.value.cases) |c| {
        errdefer std.debug.print("BPC2 dollar={} indep={} text={s}\n", .{ c.d, c.i, c.t[0..@min(c.t.len, 80)] });
        const r = try resolveText(a, c.t, c.d, c.i);
        defer r.deinit(a);
        var got: usize = 0;
        for (r.tokens[0..r.info.len], r.info) |t, inf| {
            if (!inf.colored) continue;
            try testing.expect(got < c.b.len);
            const w = c.b[got];
            try testing.expectEqual(w[0], @as(i32, @intCast(t.start)));
            try testing.expectEqual(w[1], @as(i32, t.len));
            try testing.expectEqual(w[2] < 0, inf.invalid);
            if (!inf.invalid) try testing.expectEqual(w[2], @as(i32, inf.level));
            got += 1;
        }
        try testing.expectEqual(c.b.len, got);
        brackets += got;
    }
    try testing.expectEqual(@as(usize, 6016), brackets);
}
