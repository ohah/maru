//! N1.5 슬라이스 e — **짝이 된 줄 쌍 안의 문자 단위 차이**(docs/native-editor-ui.md §7).
//!
//! §3.5가 *"줄 전체에 옅은 색을 깔고 바뀐 글자만 진하게"*를 요구한다. 앞의 절반(줄 밴드)은 슬라이스
//! d가 했고, 여기가 뒤의 절반이다.
//!
//! **줄 대응을 바꾸지 않는다**(§7 경계 규칙). 두 층은 순서가 있다 — `diff.zig`가 어느 줄이 어느 줄과
//! 짝인지 정하고, **그 결과로 짝이 된 줄 안에서만** 이 모듈이 문자 차이를 본다. 그래서 입력이 문서가
//! 아니라 **줄 하나 쌍**이고, 비용도 문서가 아니라 줄에 붙는다.
//!
//! **무엇이 한 글자인지는 호출자가 정한다.** L2는 chrome을 모르는데(layering §), "한 글자"는 grapheme
//! cluster·표시 폭이라 그 어휘가 chrome에 있다(`text_layout.clusterEndAfter`). 그래서 이 모듈은
//! **토큰 경계를 받아** 그 위에서 최소 차이를 낸다 — 쪼개는 규칙은 위층, 차이는 여기.
//! 그 덕에 이모지 ZWJ 시퀀스를 반으로 자르는 일이 구조적으로 생기지 않는다.

const std = @import("std");
const diff = @import("diff.zig");

/// 한 글자(호출자가 정한 단위)의 줄 안 바이트 범위.
pub const Token = struct { start: u32, len: u32 };

/// 강조할 바이트 범위(그 줄 안). 붙어 있는 것들은 하나로 합쳐 낸다 — 글자마다 op을 내면 한 줄에
/// 수십 개가 생기고, 화면에서는 어차피 이어진 한 덩어리로 보인다.
pub const Span = struct { start: u32, len: u32 };

pub const Result = struct {
    left: []Span,
    right: []Span,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.left);
        allocator.free(self.right);
        self.* = .{ .left = &.{}, .right = &.{} };
    }
};

pub const Options = struct {
    /// 이만큼을 넘는 줄은 건너뛴다(`null` 반환). §3.8이 초장문 줄을 축소하는 것과 같은 이유다 —
    /// 한 줄이 수천 글자면 문자 단위 강조가 **읽는 데 도움이 안 되고**(온통 얼룩이 된다) 비용만 든다.
    max_tokens: usize = 512,
};

/// 두 줄의 문자 차이. **강조할 것이 없으면 `null`이다** — 호출자가 "없음"과 "빈 배열"을 구분할 필요가
/// 없게(둘 다 안 그린다) 하나로 접는다.
///
/// **다음 경우는 계산하지 않는다.**
/// - 한쪽이 비었다(순수 추가·삭제) — 줄 전체가 이미 밴드로 칠해져 있고, 그 위에 글자까지 진하게 하면
///   같은 사실을 두 번 말하면서 대비만 떨어진다.
/// - 너무 길다(`max_tokens`) — 위 옵션 주석.
/// - 공통 부분이 없다 — 줄 전체가 바뀐 것이라 위와 같다.
pub fn compute(
    allocator: std.mem.Allocator,
    left_tokens: []const Token,
    left_line: []const u8,
    right_tokens: []const Token,
    right_line: []const u8,
    opts: Options,
) error{OutOfMemory}!?Result {
    if (left_tokens.len == 0 or right_tokens.len == 0) return null;
    if (left_tokens.len > opts.max_tokens or right_tokens.len > opts.max_tokens) return null;

    // 토큰을 문자열 배열로 옮겨 **줄 대응과 같은 differ**에 태운다. 최소 편집이라는 성질이 그대로
    // 필요하고(덜 강조하면 놓치고, 더 강조하면 얼룩이 된다), 그것을 두 번 구현할 이유가 없다.
    const left_text = try allocator.alloc([]const u8, left_tokens.len);
    defer allocator.free(left_text);
    const right_text = try allocator.alloc([]const u8, right_tokens.len);
    defer allocator.free(right_text);
    for (left_tokens, 0..) |t, i| left_text[i] = sliceOf(left_line, t);
    for (right_tokens, 0..) |t, i| right_text[i] = sliceOf(right_line, t);

    var view = try diff.compute(allocator, left_text, right_text, .{});
    defer if (view == .compare) view.compare.deinit(allocator);
    switch (view) {
        // 같은 줄이면 강조할 것이 없다(줄 대응이 이 둘을 짝지었다면 밴드도 없다).
        .unchanged => return null,
        // 상한에 걸렸거나 읽을 수 없다 — 강조 없이 밴드만 남는다(틀린 강조보다 낫다).
        .loading, .unavailable => return null,
        .compare => {},
    }

    var left_spans: std.ArrayList(Span) = .empty;
    errdefer left_spans.deinit(allocator);
    var right_spans: std.ArrayList(Span) = .empty;
    errdefer right_spans.deinit(allocator);

    // 행을 훑으며 각 쪽의 토큰을 순서대로 소비한다. **포인터 산술을 쓰지 않는다** — 행의 text는 입력을
    // 빌리므로 주소로 되돌릴 수도 있지만, 그 방식은 빈 행(filler)에서 성립하지 않고 계약을 흐린다.
    var li: usize = 0;
    var ri: usize = 0;
    var common: usize = 0;
    for (view.compare.left, view.compare.right) |lrow, rrow| {
        switch (lrow.kind) {
            .context => {
                common += 1;
                li += 1;
            },
            .removed => {
                try appendMerged(allocator, &left_spans, left_tokens[li]);
                li += 1;
            },
            .filler => {},
            .added => unreachable, // 왼쪽에 추가는 없다(differ 계약)
        }
        switch (rrow.kind) {
            .context => ri += 1,
            .added => {
                try appendMerged(allocator, &right_spans, right_tokens[ri]);
                ri += 1;
            },
            .filler => {},
            .removed => unreachable,
        }
    }

    // **공통 글자가 하나도 없으면 강조하지 않는다.** 줄이 통째로 바뀐 것이고, 그때 모든 글자를 진하게
    // 하면 밴드와 같은 말을 두 번 하면서 대비만 떨어진다.
    if (common == 0) {
        left_spans.deinit(allocator);
        right_spans.deinit(allocator);
        return null;
    }

    const left_out = try left_spans.toOwnedSlice(allocator);
    errdefer allocator.free(left_out);
    const right_out = try right_spans.toOwnedSlice(allocator);
    return .{ .left = left_out, .right = right_out };
}

fn sliceOf(line: []const u8, t: Token) []const u8 {
    const start = @min(t.start, line.len);
    const end = @min(start + t.len, line.len);
    return line[start..end];
}

/// 직전 span과 **바이트가 맞닿아 있으면** 늘리고, 아니면 새로 연다.
fn appendMerged(allocator: std.mem.Allocator, out: *std.ArrayList(Span), t: Token) error{OutOfMemory}!void {
    if (out.items.len > 0) {
        const last = &out.items[out.items.len - 1];
        if (last.start + last.len == t.start) {
            last.len += t.len;
            return;
        }
    }
    try out.append(allocator, .{ .start = t.start, .len = t.len });
}

/// 바이트 문자열을 **코드포인트 경계**로 자른 토큰들. 테스트와, 클러스터 분절이 필요 없는 호출자를 위한
/// 편의 함수다. **화면에 그리는 호출자는 이것을 쓰지 않는다** — 이모지 ZWJ 시퀀스가 반으로 잘린다.
pub fn codepointTokens(allocator: std.mem.Allocator, line: []const u8) error{OutOfMemory}![]Token {
    var out: std.ArrayList(Token) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < line.len) {
        const len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        const step = @min(len, line.len - i);
        try out.append(allocator, .{ .start = @intCast(i), .len = @intCast(step) });
        i += step;
    }
    return out.toOwnedSlice(allocator);
}

const testing = std.testing;

/// 테스트 편의: 코드포인트 토큰으로 두 줄을 비교한다.
fn computeStrings(allocator: std.mem.Allocator, left: []const u8, right: []const u8) !?Result {
    const lt = try codepointTokens(allocator, left);
    defer allocator.free(lt);
    const rt = try codepointTokens(allocator, right);
    defer allocator.free(rt);
    return compute(allocator, lt, left, rt, right, .{});
}

fn expectSpans(result: ?Result, line: []const u8, expected: []const []const u8, side: enum { left, right }) !void {
    const r = result orelse return error.NoSpans;
    const spans = switch (side) {
        .left => r.left,
        .right => r.right,
    };
    try testing.expectEqual(expected.len, spans.len);
    for (spans, expected) |s, want| {
        try testing.expectEqualStrings(want, line[s.start .. s.start + s.len]);
    }
}

test "바뀐 글자만 강조한다 — 같은 앞뒤는 놔둔다" {
    const allocator = testing.allocator;
    const left = "const a = 1;";
    const right = "const b = 1;";
    var r = (try computeStrings(allocator, left, right)) orelse return error.NoSpans;
    defer r.deinit(allocator);
    try expectSpans(r, left, &.{"a"}, .left);
    try expectSpans(r, right, &.{"b"}, .right);
}

test "붙어 있는 변경은 한 덩어리로 낸다 — 글자마다 내면 한 줄에 수십 개가 된다" {
    const allocator = testing.allocator;
    const left = "value = 1234;";
    const right = "value = 9876;";
    var r = (try computeStrings(allocator, left, right)) orelse return error.NoSpans;
    defer r.deinit(allocator);
    try expectSpans(r, left, &.{"1234"}, .left);
    try expectSpans(r, right, &.{"9876"}, .right);
}

test "떨어진 변경은 따로 낸다" {
    const allocator = testing.allocator;
    const left = "a=1 and b=2";
    const right = "a=9 and b=8";
    var r = (try computeStrings(allocator, left, right)) orelse return error.NoSpans;
    defer r.deinit(allocator);
    try expectSpans(r, left, &.{ "1", "2" }, .left);
    try expectSpans(r, right, &.{ "9", "8" }, .right);
}

test "한쪽만 늘어난 경우: 늘어난 쪽에만 강조가 선다" {
    const allocator = testing.allocator;
    const left = "log(a)";
    const right = "log(a, b)";
    var r = (try computeStrings(allocator, left, right)) orelse return error.NoSpans;
    defer r.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), r.left.len);
    try expectSpans(r, right, &.{", b"}, .right);
}

test "같은 줄이면 강조가 없다" {
    const allocator = testing.allocator;
    try testing.expect((try computeStrings(allocator, "same", "same")) == null);
}

test "공통 글자가 없으면 강조하지 않는다 — 밴드가 이미 그 사실을 말한다" {
    const allocator = testing.allocator;
    try testing.expect((try computeStrings(allocator, "abc", "xyz")) == null);
}

test "한쪽이 비면 **할당 전에** 접는다 — 추가된 줄마다 Myers를 돌리지 않는다" {
    // 결과만 보면 아래 `common == 0` 규칙도 같은 null을 내므로 두 경로를 구분할 수 없다(뮤턴트가
    // 그래서 살아남았다). 이 이른 반환의 이유는 **비용**이다 — diff에서 순수 추가·삭제는 가장 흔한
    // 모양이고, 그때마다 토큰 배열을 잡고 differ를 돌리면 줄 수만큼 헛일이 쌓인다.
    // 그래서 "한 번도 할당하지 않는다"로 판정한다.
    const lt = [_]Token{.{ .start = 0, .len = 1 }};
    try testing.expect((try compute(testing.failing_allocator, &.{}, "", &lt, "a", .{})) == null);
    try testing.expect((try compute(testing.failing_allocator, &lt, "a", &.{}, "", .{})) == null);
}

test "초장문 줄도 할당 전에 접는다" {
    var buf: [700]Token = undefined;
    for (&buf, 0..) |*t, i| t.* = .{ .start = @intCast(i), .len = 1 };
    const line = "a" ** 700;
    try testing.expect((try compute(testing.failing_allocator, &buf, line, &buf, line, .{})) == null);
}

test "초장문 줄은 건너뛴다 — 온통 얼룩이 되고 비용만 든다" {
    const allocator = testing.allocator;
    const long_a = "a" ** 600;
    const long_b = "b" ++ ("a" ** 599);
    const lt = try codepointTokens(allocator, long_a);
    defer allocator.free(lt);
    const rt = try codepointTokens(allocator, long_b);
    defer allocator.free(rt);
    try testing.expect((try compute(allocator, lt, long_a, rt, long_b, .{})) == null);
    // 상한을 올려 주면 계산된다(상한이 이유라는 것을 고정한다).
    var r = (try compute(allocator, lt, long_a, rt, long_b, .{ .max_tokens = 1024 })) orelse return error.NoSpans;
    defer r.deinit(allocator);
    try expectSpans(r, long_b, &.{"b"}, .right);
}

test "토큰 경계를 호출자가 정한다 — 클러스터를 반으로 자르지 않는다" {
    // 화면에 그리는 호출자는 grapheme cluster 경계를 준다(이 모듈은 그 규칙을 모른다). 여기서는
    // "네 바이트짜리 한 글자"를 토큰 하나로 주고, 그 안쪽이 절대 쪼개지지 않는 것을 본다.
    const allocator = testing.allocator;
    const left = "x😀y"; // 😀 = 4바이트
    const right = "x🙂y"; // 🙂 = 4바이트
    const lt = [_]Token{ .{ .start = 0, .len = 1 }, .{ .start = 1, .len = 4 }, .{ .start = 5, .len = 1 } };
    const rt = [_]Token{ .{ .start = 0, .len = 1 }, .{ .start = 1, .len = 4 }, .{ .start = 5, .len = 1 } };
    var r = (try compute(allocator, &lt, left, &rt, right, .{})) orelse return error.NoSpans;
    defer r.deinit(allocator);
    try expectSpans(r, left, &.{"😀"}, .left);
    try expectSpans(r, right, &.{"🙂"}, .right);
}

test "무작위 200쌍: 강조 범위가 줄 밖으로 안 나가고 겹치지 않는다" {
    // 범위가 줄을 넘으면 렌더가 남의 바이트를 읽고, 겹치면 같은 자리에 두 번 칠해져 알파가 어긋난다.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var prng = std.Random.DefaultPrng.init(0x1EAF);
    const rnd = prng.random();
    var case_i: usize = 0;
    while (case_i < 200) : (case_i += 1) {
        _ = arena.reset(.retain_capacity);
        const alloc = arena.allocator();
        const vocab = "abc ";
        const na = rnd.uintLessThan(usize, 24);
        const nb = rnd.uintLessThan(usize, 24);
        const a = try alloc.alloc(u8, na);
        const b = try alloc.alloc(u8, nb);
        for (a) |*c| c.* = vocab[rnd.uintLessThan(usize, vocab.len)];
        for (b) |*c| c.* = vocab[rnd.uintLessThan(usize, vocab.len)];
        const r = try computeStrings(alloc, a, b) orelse continue;
        for ([_][]const Span{ r.left, r.right }, [_][]const u8{ a, b }) |spans, line| {
            var prev_end: u32 = 0;
            for (spans) |s| {
                try testing.expect(s.len > 0);
                try testing.expect(s.start >= prev_end); // 겹치지 않고 순서대로다
                try testing.expect(s.start + s.len <= line.len); // 줄 밖으로 안 나간다
                prev_end = s.start + s.len;
            }
        }
    }
}

test "할당이 어디서 실패해도 새지 않는다 — 실패 지점을 전부 주입한다" {
    // `diff.zig`에서 이 방법이 실제 누수를 잡았다(복사는 성공하고 append가 OOM인 자리). 여기도
    // 토큰 배열 둘 + 결과 둘을 잡으므로 같은 모양이 생길 수 있다.
    const Case = struct {
        fn run(allocator: std.mem.Allocator, left: []const u8, right: []const u8) !void {
            const lt = try codepointTokens(allocator, left);
            defer allocator.free(lt);
            const rt = try codepointTokens(allocator, right);
            defer allocator.free(rt);
            var r = (try compute(allocator, lt, left, rt, right, .{})) orelse return;
            r.deinit(allocator);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Case.run, .{ "a=1 and b=2", "a=9 and b=8" });
}

test "표시 글자가 같으면 강조가 없다 — 끝 개행만 사라진 줄" {
    // §7이 정한 대로 줄 대응은 **줄 끝 문자를 포함해** 계산하므로, `"a"`와 `"a\n"`은 다른 줄이고
    // 밴드가 선다. 그런데 화면에 그릴 때는 줄 끝 문자를 떼므로 **보이는 글자는 같다** — 그때 강조할
    // 것은 없다. 여기에 억지로 무언가를 칠하면 "이 글자가 달라졌다"는 신호가 거짓이 된다.
    const allocator = testing.allocator;
    try testing.expect((try computeStrings(allocator, "a", "a")) == null);
}
