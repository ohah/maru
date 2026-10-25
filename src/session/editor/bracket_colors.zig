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

/// 짝이 없는 괄호. 색·강조·점프는 이 동일한 짝 판정을 함께 읽는다.
pub const none = std.math.maxInt(u32);

const builtin = @import("builtin");
var resolution_calls: if (builtin.is_test) std.atomic.Value(u64) else void = if (builtin.is_test) .init(0) else {};

/// 빠른 경로 표시 대신 실제 전체 판정 호출을 검사한다. 제품 바이너리에는 저장소가 없다.
pub fn resolutionCountForTest() u64 {
    if (!builtin.is_test) @compileError("test-only resolution counter");
    return resolution_calls.load(.monotonic);
}

/// `tokens` 의 판정을 `out` 에 쓴다(길이가 같아야 한다). `partner`·`stack` 은 호출자가 주는 작업 칸(각각 `tokens.len` 이상).
pub fn resolve(tokens: []const Token, independent: bool, out: []Info, partner: []u32, stack: []u32) void {
    if (builtin.is_test) _ = resolution_calls.fetchAdd(1, .monotonic);
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
    var per_kind = @as([max_kinds]u16, @splat(0));
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

/// 이 길이(UTF-16 단위) 이상인 줄의 괄호는 없다 — VS Code 는 그런 줄을 토큰화하지 않고(`editor.maxTokenizationLineLength` 기본 20,000 ·
/// `TokenizationSupportWithLineLimit`), 토큰화 안 된 줄은 「균형 괄호」 표시가 없어 괄호도 없다. 한 줄로 줄인(minified) 파일이 온통 칠해지지 않는
/// 까닭이 이것이다.
pub const max_tokenized_line: usize = 20_000;

/// 긴 줄 제외를 전체 판정과 좌표 재사용이 함께 읽는다. 현재 원문을 기준으로 판단한다.
pub const LineFilter = struct {
    source: []const u8,
    line_start: usize = 0,
    line_end: usize = 0,
    long: bool = false,

    pub fn includes(self: *LineFilter, t: Token) bool {
        if (t.start >= self.line_end or t.start < self.line_start) {
            self.line_start = if (std.mem.lastIndexOfScalar(u8, self.source[0..t.start], '\n')) |nl| nl + 1 else 0;
            self.line_end = if (std.mem.indexOfScalarPos(u8, self.source, t.start, '\n')) |nl| nl else self.source.len;
            // 줄바꿈을 제외한 UTF-16 길이라는 기존 정책을 두 경로에 동일하게 적용한다.
            if (self.line_end > self.line_start and self.source[self.line_end - 1] == '\r') self.line_end -= 1;
            self.long = utf16Len(self.source[self.line_start..self.line_end]) >= max_tokenized_line;
        }
        return !self.long;
    }
};

/// 긴 줄(`max_tokenized_line` 이상)에 든 괄호를 뺀다 — 제자리에서 당기고 남은 길이를 돌려준다. `tokens` 는 위치 오름차순이고 `source` 는 그 문서다.
pub fn dropLongLines(tokens: []Token, source: []const u8) usize {
    var filter: LineFilter = .{ .source = source };
    var w: usize = 0;
    for (tokens) |t| {
        if (!filter.includes(t)) continue;
        tokens[w] = t;
        w += 1;
    }
    return w;
}

/// 짝·단계·탐색 인덱스는 위치가 아닌 토큰의 구조와 순서에만 의존한다.
/// 모든 입력을 확인한 뒤 좌표만 게시해, 뒤늦은 불일치가 이전 결과를 반쯤 바꾸지 못하게 한다.
/// scratch는 기존 판정의 두 작업 칸이며 finish 전에는 임시 좌표만 바뀐다.
pub const Reposition = struct {
    tokens: []Token,
    scratch: []u32,
    filter: LineFilter,
    expected: usize,
    consumed: usize = 0,
    matched: usize = 0,
    /// 참이 되면 종료해도 된다. 전체 입력 소비는 재사용에 성공할 때만 필요하다.
    failed: bool,

    pub fn init(tokens: []Token, scratch: []u32, source: []const u8, expected: usize, previous_pool: bool, current_pool: bool) Reposition {
        return .{ .tokens = tokens, .scratch = scratch, .filter = .{ .source = source }, .expected = expected, .failed = previous_pool != current_pool or scratch.len / 2 < tokens.len };
    }

    /// 배열 길이가 다른 미완성 판정은 재사용하지 않는다.
    pub fn requireLengths(self: *Reposition, info_len: usize, navigation_len: usize) void {
        self.failed = self.failed or info_len != self.tokens.len or navigation_len != self.tokens.len;
    }

    pub fn feed(self: *Reposition, t: Token) void {
        self.consumed += 1;
        if (self.failed or !self.filter.includes(t)) return;
        if (self.matched >= self.tokens.len) {
            self.failed = true;
            return;
        }
        const old = self.tokens[self.matched];
        if (old.open != t.open or old.open_kind != t.open_kind or old.close_kind != t.close_kind or old.colorized != t.colorized) {
            self.failed = true;
            return;
        }
        self.scratch[self.matched] = t.start;
        self.scratch[self.tokens.len + self.matched] = t.len;
        self.matched += 1;
    }

    pub fn finish(self: *Reposition) bool {
        if (self.failed or self.consumed != self.expected or self.matched != self.tokens.len) return false;
        for (self.tokens, 0..) |*t, i| {
            t.start = self.scratch[i];
            t.len = @intCast(self.scratch[self.tokens.len + i]);
        }
        return true;
    }
};

/// UTF-16 단위 길이 — byte 가 상한보다 짧으면 셀 것도 없다(UTF-16 단위 ≤ byte).
fn utf16Len(line: []const u8) usize {
    if (line.len < max_tokenized_line) return line.len;
    var n: usize = 0;
    for (line) |b| {
        if (b & 0xC0 == 0x80) continue; // 이어짐 byte
        n += if (b >= 0xF0) 2 else 1; // 4 byte 글자는 서로게이트 둘
    }
    return n;
}

/// 깊이 가드로 글자가 된 여는 괄호의 표시(① → ②).
pub const ignored = none - 1;

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

// 두 번째 입력의 마지막 토큰에서 실패해도 이전 좌표와 판정은 보존돼야 한다.
test "bracket reposition late mismatch and incomplete input preserve all coordinates" {
    var previous = [_]Token{ .{ .start = 0, .open = true, .close_kind = 0 }, .{ .start = 2, .open = false, .close_kind = 0 } };
    const saved = previous;
    var scratch: [4]u32 = undefined;
    var trial = Reposition.init(&previous, &scratch, "x(])", 2, false, false);
    trial.feed(.{ .start = 1, .open = true, .close_kind = 0 });
    try testing.expect(!trial.failed);
    trial.feed(.{ .start = 2, .open = false, .close_kind = 1 });
    try testing.expect(trial.failed);
    try testing.expect(!trial.finish());
    try testing.expectEqualDeep(saved, previous);
    trial = Reposition.init(&previous, &scratch, "x(a)", 2, false, false);
    trial.feed(.{ .start = 1, .open = true, .close_kind = 0 });
    try testing.expect(!trial.finish());
    try testing.expectEqualDeep(saved, previous);
    trial = Reposition.init(&previous, &scratch, "x(a)", 2, false, false);
    trial.feed(.{ .start = 1, .open = true, .close_kind = 0 });
    trial.feed(.{ .start = 3, .open = false, .close_kind = 0 });
    try testing.expect(trial.finish());
    try testing.expectEqual(@as(u32, 1), previous[0].start);
    try testing.expectEqual(@as(u32, 3), previous[1].start);
    var original = saved;
    trial = Reposition.init(&original, &scratch, "x(a))", 3, false, false);
    trial.feed(.{ .start = 1, .open = true, .close_kind = 0 });
    trial.feed(.{ .start = 3, .open = false, .close_kind = 0 });
    trial.feed(.{ .start = 4, .open = false, .close_kind = 0 });
    try testing.expect(!trial.finish());
    try testing.expectEqualDeep(saved, original);
}

test "bracket reposition rejects pool structural attributes and short scratch" {
    const original = [_]Token{.{ .start = 0, .open = true, .close_kind = 0 }};
    var scratch: [2]u32 = undefined;
    for (0..8) |mutation| {
        var previous = original;
        var input = original[0];
        switch (mutation) {
            0 => input.open = false,
            1 => input.open_kind = 1,
            2 => input.close_kind = 1,
            3 => input.colorized = false,
            else => {},
        }
        var trial = Reposition.init(&previous, if (mutation == 5) scratch[0..1] else &scratch, "(", 1, false, mutation == 4);
        trial.requireLengths(if (mutation == 6) 0 else 1, if (mutation == 7) 0 else 1);
        trial.feed(input);
        try testing.expect(!trial.finish());
        try testing.expectEqualDeep(original, previous);
    }
}

test "bracket reposition uses current Unicode CRLF long line filter" {
    const a = testing.allocator;
    const text = try a.alloc(u8, max_tokenized_line * 4 + 8);
    defer a.free(text);
    // 한 UTF-16 단위인 한글을 19,997개 두어 단순 byte 길이로 잘못 제외하지 못하게 한다.
    var n: usize = 0;
    for (0..max_tokenized_line - 3) |_| {
        @memcpy(text[n..][0..3], "한");
        n += 3;
    }
    text[n] = '(';
    text[n + 1] = ')';
    @memcpy(text[n + 2 ..][0..2], "\r\n");
    var previous = [_]Token{ .{ .start = 0, .open = true, .close_kind = 0 }, .{ .start = 1, .open = false, .close_kind = 0 } };
    var scratch: [4]u32 = undefined;
    var trial = Reposition.init(&previous, &scratch, text[0 .. n + 4], 2, false, false);
    trial.feed(.{ .start = @intCast(n), .open = true, .close_kind = 0 });
    trial.feed(.{ .start = @intCast(n + 1), .open = false, .close_kind = 0 });
    try testing.expect(trial.finish());
    const saved = previous;
    // 일반 글자 하나가 더 들어오면 정확히 20,000 UTF-16 단위가 돼 목록에서 빠진다.
    text[n + 2] = 'x';
    @memcpy(text[n + 3 ..][0..2], "\r\n");
    trial = Reposition.init(&previous, &scratch, text[0 .. n + 5], 2, false, false);
    trial.feed(saved[0]);
    trial.feed(saved[1]);
    try testing.expect(!trial.finish());
    try testing.expectEqualDeep(saved, previous);
    // 이전 목록도 비었다면 새 긴 줄의 제외 목록과 같아 안전하게 재사용한다.
    trial = Reposition.init(previous[0..0], scratch[0..0], text[0 .. n + 5], 2, false, false);
    trial.feed(saved[0]);
    trial.feed(saved[1]);
    try testing.expect(trial.finish());
    // 제외되던 줄이 짧아지면 비어 있던 목록으로는 재사용하지 않는다.
    trial = Reposition.init(previous[0..0], scratch[0..0], "()", 2, false, false);
    trial.feed(.{ .start = 0, .open = true, .close_kind = 0 });
    trial.feed(.{ .start = 1, .open = false, .close_kind = 0 });
    try testing.expect(!trial.finish());
    // 4-byte 문자는 UTF-16 두 단위다. 9,999개와 괄호 둘이면 정확히 상한이다.
    n = 0;
    for (0..9999) |_| {
        @memcpy(text[n..][0..4], "😀");
        n += 4;
    }
    text[n] = '(';
    text[n + 1] = ')';
    trial = Reposition.init(&previous, &scratch, text[0 .. n + 2], 2, false, false);
    trial.feed(.{ .start = @intCast(n), .open = true, .close_kind = 0 });
    trial.feed(.{ .start = @intCast(n + 1), .open = false, .close_kind = 0 });
    try testing.expect(!trial.finish());
}

test "bracket reposition full resolver oracle across malformed deep and multibyte brackets" {
    const cases = [_][]const u8{ "", "a(b[c{d}e]f)", "({)}", "(]", "${a{b}}", "((((((((a", ")]}" };
    var deep: [400]u8 = undefined;
    @memset(deep[0..200], '(');
    @memset(deep[200..], ')');
    for (0..cases.len + 1) |ci| {
        const text = if (ci < cases.len) cases[ci] else &deep;
        for ([_]bool{ false, true }) |pool| for ([_]bool{ false, true }) |colorized| {
            var tokens: [401]Token = undefined;
            const old = scanForTest(text, colorized, &tokens);
            var previous_info: [401]Info = undefined;
            var expected_info: [401]Info = undefined;
            var work: [802]u32 = undefined;
            resolve(old, pool, previous_info[0..old.len], work[0..old.len], work[old.len..][0..old.len]);
            var shifted: [401]Token = undefined;
            for (old, 0..) |t, i| {
                shifted[i] = t;
                shifted[i].start += @intCast(i + 2);
            }
            // 공백 문서는 긴 줄 필터에 충분한 유효 좌표를 제공한다. 종류·길이는 토큰 값이다.
            var source: [1000]u8 = @splat(' ');
            var trial = Reposition.init(old, &work, &source, old.len, pool, pool);
            for (shifted[0..old.len]) |t| trial.feed(t);
            try testing.expect(trial.finish());
            try testing.expectEqualDeep(shifted[0..old.len], old);
            resolve(old, pool, expected_info[0..old.len], work[0..old.len], work[old.len..][0..old.len]);
            try testing.expectEqualDeep(previous_info[0..old.len], expected_info[0..old.len]);
        };
    }
}
