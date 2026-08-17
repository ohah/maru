//! 접을 범위 — **들여쓰기 층**(native-editor-visual-mapping.md §4·§4.1f).
//!
//! §4가 접을 범위의 소스를 셋으로 층 지었다: **들여쓰기 → tree-sitter → LSP**. 이 모듈은 맨 아래
//! 층이고, *"언어도 grammar도 필요 없어 파서가 붙기 전부터 동작하고, grammar 없는 파일의 유일한
//! 소스"*다. 위 층이 오면 grammar 있는 파일에서만 덮이고 나머지(로그·설정·처음 보는 언어)에서는
//! 계속 이것이 쓰인다 — **대체가 아니라 바닥층**이다.
//!
//! **L2다** — chrome도 allocator 정책도 모른다. 줄 배열과 탭 폭만 받아 범위를 낸다. 호출자가 저장소를
//! 준다(`countRanges`로 개수를 먼저 물어보고 그만큼 잡는다).

const std = @import("std");

/// 접을 수 있는 한 범위. **줄 단위 반열림이 아니다** — `head`는 보이고 `[first_hidden, last_hidden]`이
/// 접었을 때 숨는 구간이다. 화면에 남는 줄과 숨는 줄을 호출자가 헷갈리지 않게 이름으로 가른다.
pub const Range = struct {
    /// 접어도 보이는 줄(화살표가 이 줄에 선다).
    head: u32,
    /// 접으면 숨는 첫 줄. 항상 `head + 1`이지만 계산 결과를 그대로 들고 있는 편이 읽기 쉽다.
    first_hidden: u32,
    /// 접으면 숨는 마지막 줄(포함).
    last_hidden: u32,

    pub fn hiddenCount(self: Range) u32 {
        return self.last_hidden - self.first_hidden + 1;
    }
};

/// 그 줄의 **표시 들여쓰기 깊이**(열). 탭은 탭 폭까지 나아간다 — 화면에서 보이는 깊이가 기준이다
/// (§4.2가 표시 폭을 단일 출처로 둔 것과 같은 규율). 공백·탭 외 문자가 나오면 멈춘다.
///
/// **빈 줄(공백만 있는 줄 포함)은 `null`이다** — 깊이가 0이 아니라 "깊이가 없다"이다. 0으로 치면
/// 함수 사이 빈 줄마다 범위가 끊겨 접힘이 쓸모없어진다.
pub fn indentOf(line: []const u8, tab_width: u16) ?u32 {
    const stop: u32 = if (tab_width == 0) 1 else tab_width;
    var col: u32 = 0;
    for (line) |c| switch (c) {
        ' ' => col += 1,
        '\t' => col = ((col / stop) + 1) * stop,
        '\r' => {}, // CRLF의 잔여는 내용이 아니다
        else => return col,
    };
    return null; // 끝까지 공백이었다 = 빈 줄
}

/// 들여쓰기로 접을 범위를 센다(저장소를 안 쓴다). `compute`에 넘길 배열 크기를 여기서 얻는다.
pub fn countRanges(lines: []const []const u8, tab_width: u16) usize {
    var counter = Counter{};
    walk(lines, tab_width, &counter);
    return counter.n;
}

/// 들여쓰기로 접을 범위를 만든다. `out`이 모자라면 **거기까지만** 채우고 그만큼을 돌려준다 —
/// §3.8의 축소 규율과 같다(못 그리는 것이 죽는 것보다 낫다).
/// **문서 순서로 낸다**(머리 줄 오름차순). 훑기는 안쪽 블록이 먼저 닫혀 안쪽부터 나오는데, 소비처
/// (gutter 화살표·레벨 단위 접기)는 문서 순서를 기대한다 — 순서를 계약으로 고정해 두 곳이 갈리지
/// 않게 한다. 범위 수는 줄 수보다 훨씬 적어 정렬 비용이 문제되지 않는다.
pub fn compute(lines: []const []const u8, tab_width: u16, out: []Range) []Range {
    var sink = Sink{ .out = out };
    walk(lines, tab_width, &sink);
    const rs = out[0..sink.n];
    std.mem.sort(Range, rs, {}, lessByHead);
    return rs;
}

fn lessByHead(_: void, a: Range, b: Range) bool {
    return a.head < b.head;
}

const Counter = struct {
    n: usize = 0,
    fn push(self: *Counter, _: Range) void {
        self.n += 1;
    }
};

const Sink = struct {
    out: []Range,
    n: usize = 0,
    fn push(self: *Sink, r: Range) void {
        if (self.n >= self.out.len) return;
        self.out[self.n] = r;
        self.n += 1;
    }
};

/// 한 번에 열 수 있는 **중첩 깊이 상한**(§3.8 "깊은 중첩"). 실제 코드는 10단계를 넘지 않는다 —
/// 64면 넉넉하고, 넘는 입력에서는 그 아래를 접지 않을 뿐 죽지 않는다.
///
/// **이 상한이 곧 저장소 상한이다.** 아래 훑기는 열린 블록을 스택으로 들고 있고 그 스택이 이 크기다.
pub const max_depth: usize = 64;

/// 규칙: **어떤 줄의 다음 줄이 더 깊게 들여써 있으면 그 줄이 머리**이고, 그 깊이보다 깊은 연속 구간이
/// 몸통이다. 빈 줄은 구간을 끊지 않되 **꼬리의 빈 줄은 범위에서 뺀다**(다음 블록 앞 여백까지 접히면
/// 화면이 이상해진다).
///
/// **한 번만 훑는다.** 초판은 줄마다 앞으로 다시 훑어 계단식 문서에서 **O(n³)**이었다 — 실측으로
/// 500줄 78ms · 1,000줄 610ms · **2,000줄 4.87초**(두 배마다 8배. 앞 훑기마다 들여쓰기 접두사를 다시
/// 세기 때문이다). 열린 블록을 스택으로 들면 줄마다 상수 번의 pop/push로 끝난다.
fn walk(lines: []const []const u8, tab_width: u16, sink: anytype) void {
    const Open = struct { indent: u32, head: usize };
    var stack: [max_depth]Open = undefined;
    var depth: usize = 0;
    var last_content: ?usize = null;

    for (lines, 0..) |line, i| {
        const d = indentOf(line, tab_width) orelse continue; // 빈 줄은 구간을 끊지 않는다

        // 이 줄과 같거나 얕은 블록은 여기서 닫힌다. **꼬리의 빈 줄이 빠지는 것**은 `last_content`가
        // 내용 줄만 기억하기 때문이다.
        while (depth > 0 and stack[depth - 1].indent >= d) {
            depth -= 1;
            const e = stack[depth];
            if (last_content) |lc| {
                if (lc > e.head) sink.push(.{ .head = @intCast(e.head), .first_hidden = @intCast(e.head + 1), .last_hidden = @intCast(lc) });
            }
        }

        // **상한을 넘으면 더 안 연다**(§3.8) — 그 아래는 접히지 않을 뿐 나머지는 그대로 동작한다.
        if (depth < stack.len) {
            stack[depth] = .{ .indent = d, .head = i };
            depth += 1;
        }
        last_content = i;
    }

    // 문서 끝에서 남은 블록을 닫는다.
    while (depth > 0) {
        depth -= 1;
        const e = stack[depth];
        if (last_content) |lc| {
            if (lc > e.head) sink.push(.{ .head = @intCast(e.head), .first_hidden = @intCast(e.head + 1), .last_hidden = @intCast(lc) });
        }
    }
}

const testing = std.testing;

test "더 깊게 들여쓴 연속 줄이 한 범위다" {
    const lines = [_][]const u8{
        "fn main() {",
        "    const a = 1;",
        "    const b = 2;",
        "}",
    };
    var buf: [8]Range = undefined;
    const rs = compute(&lines, 4, &buf);
    try testing.expectEqual(@as(usize, 1), rs.len);
    try testing.expectEqual(@as(u32, 0), rs[0].head);
    try testing.expectEqual(@as(u32, 1), rs[0].first_hidden);
    try testing.expectEqual(@as(u32, 2), rs[0].last_hidden); // `}`는 깊이가 같아 빠진다
}

test "빈 줄은 구간을 끊지 않는다 — 끊기면 함수 사이 빈 줄마다 접힘이 쪼개진다" {
    const lines = [_][]const u8{
        "def foo():",
        "    a = 1",
        "",
        "    b = 2",
        "c = 3",
    };
    var buf: [8]Range = undefined;
    const rs = compute(&lines, 4, &buf);
    try testing.expectEqual(@as(usize, 1), rs.len);
    try testing.expectEqual(@as(u32, 3), rs[0].last_hidden); // 빈 줄을 건너 3까지 이어진다
}

test "꼬리의 빈 줄은 범위에서 뺀다 — 다음 블록 앞 여백까지 접히면 안 된다" {
    const lines = [_][]const u8{
        "def foo():",
        "    a = 1",
        "",
        "",
        "def bar():",
    };
    var buf: [8]Range = undefined;
    const rs = compute(&lines, 4, &buf);
    try testing.expectEqual(@as(usize, 1), rs.len);
    try testing.expectEqual(@as(u32, 1), rs[0].last_hidden); // 2·3은 빈 줄이라 뺀다
}

test "머리 한 줄짜리는 범위가 아니다 — 접어도 줄어드는 것이 없다" {
    const lines = [_][]const u8{ "a", "b", "c" };
    var buf: [8]Range = undefined;
    try testing.expectEqual(@as(usize, 0), compute(&lines, 4, &buf).len);
}

test "중첩은 각각 범위가 된다" {
    const lines = [_][]const u8{
        "class A:",
        "    def m(self):",
        "        x = 1",
        "    def n(self):",
        "        y = 2",
    };
    var buf: [8]Range = undefined;
    const rs = compute(&lines, 4, &buf);
    try testing.expectEqual(@as(usize, 3), rs.len);
    try testing.expectEqual(@as(u32, 0), rs[0].head); // class 전체
    try testing.expectEqual(@as(u32, 4), rs[0].last_hidden);
    try testing.expectEqual(@as(u32, 1), rs[1].head); // 첫 메서드
    try testing.expectEqual(@as(u32, 2), rs[1].last_hidden);
    try testing.expectEqual(@as(u32, 3), rs[2].head); // 둘째 메서드
}

test "탭과 공백을 섞어도 화면 깊이로 비교한다" {
    // 탭 폭 4에서 `\t`(4열)가 공백 두 칸(2열)보다 깊다 — byte 수로 비교하면 반대로 나온다.
    const lines = [_][]const u8{ "  head", "\tdeeper", "  same" };
    var buf: [8]Range = undefined;
    const rs = compute(&lines, 4, &buf);
    try testing.expectEqual(@as(usize, 1), rs.len);
    try testing.expectEqual(@as(u32, 0), rs[0].head);
    try testing.expectEqual(@as(u32, 1), rs[0].last_hidden);
}

test "저장소가 모자라면 거기까지만 낸다 — 죽지 않는다(§3.8)" {
    const lines = [_][]const u8{ "a:", "  1", "b:", "  2", "c:", "  3" };
    try testing.expectEqual(@as(usize, 3), countRanges(&lines, 4));
    var buf: [2]Range = undefined;
    try testing.expectEqual(@as(usize, 2), compute(&lines, 4, &buf).len);
}

test "countRanges와 compute가 같은 수를 낸다 — 저장소를 그 값으로 잡는다" {
    var prng = std.Random.DefaultPrng.init(0xF01D);
    const rnd = prng.random();
    var round: usize = 0;
    while (round < 500) : (round += 1) {
        var storage: [40][]const u8 = undefined;
        const n = rnd.uintLessThan(usize, storage.len);
        for (0..n) |i| {
            const depth = rnd.uintLessThan(usize, 4);
            storage[i] = switch (depth) {
                0 => "x",
                1 => "  x",
                2 => "    x",
                else => "", // 빈 줄
            };
        }
        const lines = storage[0..n];
        var buf: [64]Range = undefined;
        try testing.expectEqual(countRanges(lines, 4), compute(lines, 4, &buf).len);
    }
}

test "빈 줄만 있는 문서에는 범위가 없다" {
    const lines = [_][]const u8{ "", "  ", "\t" };
    var buf: [4]Range = undefined;
    try testing.expectEqual(@as(usize, 0), compute(&lines, 4, &buf).len);
}

test "[측정] 계단식 깊은 중첩 — 한 번 훑기와 §3.8 상한" {
    // `walk`는 줄마다 앞으로 훑는다. 깊이가 계속 깊어지는 문서에서는 그 훑기가 매번 끝까지 가서
    // **줄 수의 제곱**이 된다. 계획서 잔여에 *"§3.8 깊은 중첩 상한"*이 있는데 지금 구현엔 상한이 없다.
    const alloc = testing.allocator;
    for ([_]usize{ 500, 1000, 2000 }) |n| {
        const store = try alloc.alloc([]u8, n);
        defer {
            for (store) |b| alloc.free(b);
            alloc.free(store);
        }
        const lines = try alloc.alloc([]const u8, n);
        defer alloc.free(lines);
        for (0..n) |i| {
            store[i] = try alloc.alloc(u8, i + 1);
            @memset(store[i][0..i], ' ');
            store[i][i] = 'x';
            lines[i] = store[i];
        }
        const t0 = monotonicUs();
        const c = countRanges(lines, 4);
        const t1 = monotonicUs();
        std.debug.print("\n[측정] 계단 {d}줄: {d}범위, {d}µs\n", .{ n, c, t1 - t0 });

        // **§3.8 상한이 실제로 잡는다** — 계단이 아무리 길어도 열리는 블록은 `max_depth`까지다.
        try testing.expectEqual(max_depth, c);
        // 고치기 전: 500줄 78ms · 1,000줄 610ms · **2,000줄 4.87초**(두 배마다 8배 = O(n³)).
        // 재앙 감지선이지 예산이 아니다 — 실측은 2,000줄에서 3.6ms다.
        try testing.expect(t1 - t0 < 200_000);
    }
}

/// 테스트 전용 단조 시계(µs). Zig 0.16 `std.time`에 `Timer`·`nanoTimestamp`가 없어 직접 부른다
/// (이 저장소의 `control_bridge.monotonicMs`와 같은 관례).
fn monotonicUs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1000;
}

test "중첩 상한을 넘으면 그 아래를 안 접을 뿐 나머지는 그대로다 (§3.8)" {
    // 상한을 넘는 입력에서 **죽거나 앞부분까지 잃으면** 안 된다. 얕은 블록은 그대로 접혀야 한다.
    const alloc = testing.allocator;
    const n = max_depth + 20;
    const store = try alloc.alloc([]u8, n);
    defer {
        for (store) |b| alloc.free(b);
        alloc.free(store);
    }
    const lines = try alloc.alloc([]const u8, n);
    defer alloc.free(lines);
    for (0..n) |i| {
        store[i] = try alloc.alloc(u8, i + 1);
        @memset(store[i][0..i], ' ');
        store[i][i] = 'x';
        lines[i] = store[i];
    }

    const buf = try alloc.alloc(Range, n);
    defer alloc.free(buf);
    const rs = compute(lines, 4, buf);
    try testing.expectEqual(max_depth, rs.len); // 상한까지만 연다
    try testing.expectEqual(@as(u32, 0), rs[0].head); // **맨 바깥은 살아 있다**
    try testing.expectEqual(@as(u32, @intCast(n - 1)), rs[0].last_hidden); // 끝까지 덮는다
    // 문서 순서다.
    for (rs[1..], 0..) |r, k| try testing.expect(r.head > rs[k].head);
}
