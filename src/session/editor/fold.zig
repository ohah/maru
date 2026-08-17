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
const builtin = @import("builtin"); // 타깃 분기 — 아래 `monotonicUs`가 Windows에서 POSIX를 안 부른다

/// 접을 수 있는 한 범위. **줄 단위 반열림이 아니다** — `head`는 보이고 `[first_hidden, last_hidden]`이
/// 접었을 때 숨는 구간이다. 화면에 남는 줄과 숨는 줄을 호출자가 헷갈리지 않게 이름으로 가른다.
pub const Range = struct {
    /// 접어도 보이는 줄(화살표가 이 줄에 선다).
    head: u32,
    /// 접으면 숨는 첫 줄. 항상 `head + 1`이지만 계산 결과를 그대로 들고 있는 편이 읽기 쉽다.
    first_hidden: u32,
    /// 접으면 숨는 마지막 줄(포함).
    last_hidden: u32,
    /// **중첩 레벨**(1부터). 문서 맨 바깥 블록이 1이고, 그 안에 든 블록이 2다.
    ///
    /// **들여쓰기 폭이 아니다.** 공백 4칸이든 2칸이든 탭이든 "몇 겹 안쪽인가"는 같아야 한다 —
    /// 레벨 접기(VSCode `editor.foldLevelN`)가 묻는 것이 그것이고, 폭으로 세면 들여쓰기 규약이
    /// 다른 파일마다 같은 명령이 다른 곳을 접는다. 훑기가 이미 열린 블록을 스택으로 들고 있으므로
    /// 그 **스택 깊이**가 곧 이 값이다.
    level: u16,

    pub fn hiddenCount(self: Range) u32 {
        return self.last_hidden - self.first_hidden + 1;
    }
};

/// 그 줄의 **선행 공백 폭**(열). 탭은 탭스톱까지 나아가고, **공백·탭이 아닌 것이 나오면 거기서
/// 끝난다**.
///
/// **"화면에서 보이는 깊이"가 아니다.** 초판 주석이 그렇게 적었는데 그 표현은 탭 폭을 설명하려던
/// 것이었고, CR·NBSP 같은 경우에 **반대 결론을 유도한다** — 렌더는 CR을 1칸, NBSP를 `<U+00A0>`
/// 8칸으로 그리므로 "보이는 깊이"를 따르면 그것들도 들여쓰기에 넣어야 한다. 접힘이 알아야 하는 것은
/// 화면 시작 열이 아니라 **선행 공백의 깊이**이고, 탭이 포함되는 이유도 "보여서"가 아니라 **탭이
/// 공백이기 때문**이다. 규칙을 하나로 못박는다(적대적 검증 2026-08-17이 두 서술의 충돌을 잡았다).
///
/// **§3.8과도 그쪽이 맞다** — NBSP·전각 공백·폭 0 공백은 hazard로 표기되어 드러나는 문자다. 그것을
/// 들여쓰기로 세면 **보이지 않는 문자가 접힘 구조를 바꾼다**(그 절이 막으려는 것).
///
/// **CR도 여기서 멈춘다.** 초판은 `\r`만 건너뛰었는데(CRLF 잔여로 봤다) 두 가지가 틀렸다 — 줄에
/// 넘어오는 텍스트는 이미 줄 끝 문자가 빠져 있고(`open.lineText`의 `contentEnd`), 줄 **안**의 CR은
/// §3.8이 말하는 **내용**이다. 게다가 렌더는 CR을 **1칸**으로 센다(실측) — 건너뛰면 화면과 한 칸
/// 어긋난다. "공백·탭 외에는 멈춘다"는 위 규칙 하나만 남긴다.
///
/// **빈 줄(공백만 있는 줄 포함)은 `null`이다** — 깊이가 0이 아니라 "깊이가 없다"이다. 0으로 치면
/// 함수 사이 빈 줄마다 범위가 끊겨 접힘이 쓸모없어진다.
pub fn indentOf(line: []const u8, tab_width: u16) ?u32 {
    const stop: u32 = if (tab_width == 0) 1 else tab_width;
    var col: u32 = 0;
    for (line) |c| switch (c) {
        ' ' => col += 1,
        '\t' => col = ((col / stop) + 1) * stop,
        else => return col, // 공백·탭이 아니면 거기서 들여쓰기가 끝난다
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
                // **레벨은 스택 자리 + 1이다** — 이 블록을 품은 조상 수가 곧 `depth`다.
                if (lc > e.head) sink.push(.{ .head = @intCast(e.head), .first_hidden = @intCast(e.head + 1), .last_hidden = @intCast(lc), .level = @intCast(depth + 1) });
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
            if (lc > e.head) sink.push(.{ .head = @intCast(e.head), .first_hidden = @intCast(e.head + 1), .last_hidden = @intCast(lc), .level = @intCast(depth + 1) });
        }
    }
}

/// 화면에서 **숨는 줄 구간**(양끝 포함). 접힌 범위들을 합쳐 얻는다 — 중첩된 것을 각각 들고 있으면
/// 렌더가 같은 줄을 여러 번 판정한다.
pub const Span = struct { first: u32, last: u32 };

/// 접힌 머리 줄들(`collapsed`)로부터 숨는 구간을 만든다. **문서 순서로 나오고 겹치지 않는다.**
///
/// **왜 구간인가**: 렌더가 줄마다 "이 줄 숨나?"를 물으면 O(줄 × 범위)다. 구간을 한 번 만들어 두면
/// 줄을 훑으며 커서 하나로 판정한다 — O(줄 + 구간).
///
/// **중첩은 합친다.** 바깥과 안쪽을 둘 다 접었으면 바깥이 안쪽을 덮으므로 한 구간이다. 안 합치면
/// 같은 줄이 두 구간에 들어가 렌더가 두 번 건너뛴다.
///
/// **`collapsed`는 오름차순·중복 없음**이다(머리 줄 번호 집합). 범위도 문서 순서라 한 번에 훑는다.
///
/// `collapsed`에 범위가 없는 머리가 섞여 있어도 무시한다 — 문서가 바뀌어 범위가 사라졌는데 상태가
/// 남아 있는 경우다(§4.1f: 소스는 나중에 비동기라 상태와 범위가 잠시 어긋날 수 있다).
pub fn hiddenSpans(ranges: []const Range, collapsed: []const u32, out: []Span) []Span {
    // **`collapsed`는 오름차순이어야 한다.** 둘 다 문서 순서이므로 한 번에 나란히 훑으면 되는데,
    // 어기면 접힌 것을 **조용히 빠뜨린다**. 초판은 머리마다 목록을 훑어 전체 접기에서 O(n²)였다 —
    // 실측 2,000블록 1.6ms · 4,000블록 6.3ms(두 배마다 4배). ReleaseFast에서는 사라지는 검사다.
    if (std.debug.runtime_safety and collapsed.len > 1) {
        for (collapsed[1..], 0..) |v, i| std.debug.assert(v > collapsed[i]);
    }
    var n: usize = 0;
    var c: usize = 0;
    for (ranges) |r| {
        while (c < collapsed.len and collapsed[c] < r.head) c += 1;
        if (c >= collapsed.len or collapsed[c] != r.head) continue;
        if (n > 0 and r.first_hidden <= out[n - 1].last + 1) {
            // 앞 구간과 이어지거나 겹친다 — 늘린다(중첩·연속 접힘).
            out[n - 1].last = @max(out[n - 1].last, r.last_hidden);
            continue;
        }
        if (n >= out.len) break; // 저장소가 모자라면 거기까지만(§3.8)
        out[n] = .{ .first = r.first_hidden, .last = r.last_hidden };
        n += 1;
    }
    return out[0..n];
}

/// 그 줄이 숨는가. **구간을 훑는 쪽이 빠르지만**, 한 줄만 물어보는 자리(gutter 화살표 판정 등)를 위해
/// 둔다 — 구간 수가 적어 선형 탐색으로 충분하다.
pub fn isHidden(spans: []const Span, line: u32) bool {
    for (spans) |s| {
        if (line < s.first) return false; // 문서 순서라 더 볼 것이 없다
        if (line <= s.last) return true;
    }
    return false;
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

test "레벨은 몇 겹 안쪽인가다 — 들여쓰기 폭이 아니다" {
    // 레벨 접기(VSCode `editor.foldLevelN`)가 묻는 것은 **중첩 겹수**다. 폭으로 세면 같은 명령이
    // 들여쓰기 규약마다 다른 곳을 접는다 — 아래 두 문서는 폭이 4칸과 2칸으로 다르지만 구조가 같다.
    const wide = [_][]const u8{
        "class A:",
        "    def m():",
        "        if x:",
        "            y = 1",
        "            z = 2",
    };
    const narrow = [_][]const u8{
        "class A:",
        "  def m():",
        "    if x:",
        "      y = 1",
        "      z = 2",
    };
    for ([_][]const []const u8{ &wide, &narrow }) |lines| {
        var buf: [8]Range = undefined;
        const rs = compute(lines, 4, &buf);
        try testing.expectEqual(@as(usize, 3), rs.len);
        try testing.expectEqual(@as(u16, 1), rs[0].level); // class
        try testing.expectEqual(@as(u16, 2), rs[1].level); // def
        try testing.expectEqual(@as(u16, 3), rs[2].level); // if
    }
}

test "형제 블록은 같은 레벨이다 — 순서가 아니라 겹수다" {
    const lines = [_][]const u8{
        "a:",
        "  1",
        "b:",
        "  2",
        "  c:",
        "    3",
    };
    var buf: [8]Range = undefined;
    const rs = compute(&lines, 4, &buf);
    try testing.expectEqual(@as(usize, 3), rs.len);
    try testing.expectEqual(@as(u16, 1), rs[0].level); // a
    try testing.expectEqual(@as(u16, 1), rs[1].level); // b — a의 형제
    try testing.expectEqual(@as(u16, 2), rs[2].level); // c — b 안
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
///
/// **Windows 타깃에서는 0을 낸다 — 분기가 comptime이라 POSIX 경로가 아예 컴파일되지 않는다.**
/// 이 모듈은 **L2 중립층**이라 `check-targets`가 `x86_64-windows`로도 컴파일하는데, 그 타깃에는
/// `std.c.timespec`이 없어(zero-bit `void`) 함수가 통째로 깨진다 — CI가 실제로 그렇게 막았다
/// (2026-08-18). 로컬 `mise run check`에는 `check-targets`가 없어 여기서 못 걸렀다.
///
/// **0을 내도 판정이 뒤집히지 않는다**: 아래 측정 테스트들이 시간으로 하는 일은 재앙 감지선
/// (`expect(t1 - t0 < …)`)뿐이고, 그 선은 0에서 늘 통과한다. 측정 자체는 개발 머신(POSIX)에서 한다.
fn monotonicUs() u64 {
    if (builtin.os.tag == .windows) {
        return 0;
    } else {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1000;
    }
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

test "적대적: 한 번 훑기가 옛 규칙과 같은 답을 낸다 — 무작위 대조" {
    // 알고리즘을 통째로 바꿨다(줄마다 앞 훑기 → 스택 한 번 훑기). **빠르면서 틀리면 최악**이므로,
    // 느리지만 규칙이 눈에 보이는 판정자를 테스트 안에 두고 무작위로 대조한다.
    var prng = std.Random.DefaultPrng.init(0xBEEF_F01D);
    const rnd = prng.random();
    const vocab = [_][]const u8{ "x", "  x", "    x", "      x", "\tx", "", "   " };

    var round: usize = 0;
    while (round < 2000) : (round += 1) {
        var storage: [24][]const u8 = undefined;
        const n = rnd.uintLessThan(usize, storage.len);
        for (0..n) |i| storage[i] = vocab[rnd.uintLessThan(usize, vocab.len)];
        const lines = storage[0..n];

        var fast: [32]Range = undefined;
        const got = compute(lines, 4, &fast);

        // 판정자: 줄마다 앞으로 훑어 "더 깊은 연속 구간"을 찾는다(초판 규칙 그대로).
        var want: [32]Range = undefined;
        var wn: usize = 0;
        for (lines, 0..) |line, i| {
            const head = indentOf(line, 4) orelse continue;
            var last_content: ?usize = null;
            var j = i + 1;
            while (j < lines.len) : (j += 1) {
                const d = indentOf(lines[j], 4) orelse continue;
                if (d <= head) break;
                last_content = j;
            }
            const end = last_content orelse continue;
            want[wn] = .{ .head = @intCast(i), .first_hidden = @intCast(i + 1), .last_hidden = @intCast(end), .level = 1 };
            wn += 1;
        }

        // **레벨은 조상 수 + 1이다** — 판정자는 "나를 품는 범위가 몇 개인가"를 직접 센다(느리지만
        // 규칙이 눈에 보인다). 훑기 쪽은 스택 깊이로 같은 값을 내야 한다.
        for (want[0..wn], 0..) |*w, k| {
            var ancestors: u16 = 0;
            for (want[0..wn], 0..) |o, m| {
                if (m == k) continue;
                if (o.head < w.head and o.last_hidden >= w.last_hidden) ancestors += 1;
            }
            w.level = ancestors + 1;
        }

        try testing.expectEqual(wn, got.len);
        for (got, want[0..wn]) |g, w| {
            try testing.expectEqual(w.head, g.head);
            try testing.expectEqual(w.first_hidden, g.first_hidden);
            try testing.expectEqual(w.last_hidden, g.last_hidden);
            try testing.expectEqual(w.level, g.level);
        }
    }
}

test "공백·탭이 아니면 거기서 들여쓰기가 끝난다 — CR도 내용이다" {
    // 초판은 `\r`만 건너뛰어 화면과 한 칸 어긋났다(렌더는 CR을 1칸으로 센다 — 실측).
    try testing.expectEqual(@as(?u32, 2), indentOf("  x", 4));
    try testing.expectEqual(@as(?u32, 0), indentOf("\rx", 4)); // CR에서 멈춘다
    try testing.expectEqual(@as(?u32, 2), indentOf("  \r x", 4)); // 공백 둘 뒤 CR에서 멈춘다
    try testing.expectEqual(@as(?u32, null), indentOf("   ", 4)); // 공백만 = 빈 줄
    try testing.expectEqual(@as(?u32, null), indentOf("", 4));
    try testing.expectEqual(@as(?u32, 4), indentOf("\tx", 4)); // 탭은 탭스톱까지
    try testing.expectEqual(@as(?u32, 4), indentOf("  \tx", 4)); // 공백 둘 뒤 탭 → 다음 스톱
    // **탭 폭 0은 1로 본다**(0으로 안 나눈다) — 그러면 탭이 다음 1의 배수, 즉 한 칸 나아간다.
    // 처음엔 2로 적었는데 그건 "탭이 0칸"이라는 기대였고 틀렸다(코드가 맞았다).
    try testing.expectEqual(@as(?u32, 3), indentOf("  \tx", 0));
}

test "비표준 공백은 들여쓰기가 아니다 — §3.8이 표기로 드러내는 것들" {
    // NBSP·전각 공백 등은 **보기에만 공백**이고 §3.8이 `<U+00A0>` 표기로 드러낸다. 들여쓰기로 세면
    // 화면(표기 8칸)과 계산(1칸)이 갈리고, 더 나쁘게는 **보이지 않는 문자로 접힘 구조가 바뀐다** —
    // 그게 §3.8이 막으려는 것이다. 여기서 멈추는 것이 맞다.
    try testing.expectEqual(@as(?u32, 0), indentOf("\u{00A0}x", 4)); // NBSP
    try testing.expectEqual(@as(?u32, 0), indentOf("\u{3000}x", 4)); // 전각 공백
    try testing.expectEqual(@as(?u32, 2), indentOf("  \u{00A0}x", 4)); // 진짜 공백 둘 뒤에서 멈춘다
    try testing.expectEqual(@as(?u32, 0), indentOf("\u{200B}x", 4)); // 폭 0 공백

    // **빈 줄로 착각하지 않는다** — 내용이 있는 줄이다(깊이 0).
    try testing.expect(indentOf("\u{00A0}", 4) != null);
}

test "[측정] 아주 긴 들여쓰기 한 줄" {
    // `indentOf`는 접두사를 훑는다. 공백 수백만 개짜리 줄에서 그 비용과 `u32` 범위를 확인한다.
    const alloc = testing.allocator;
    const n = 4 << 20; // 4 MiB
    const line = try alloc.alloc(u8, n + 1);
    defer alloc.free(line);
    @memset(line[0..n], ' ');
    line[n] = 'x';

    const t0 = monotonicUs();
    const d = indentOf(line, 4);
    const t1 = monotonicUs();
    std.debug.print("\n[측정] {d}MiB 공백 들여쓰기: 깊이={?d}, {d}µs\n", .{ n >> 20, d, t1 - t0 });
    try testing.expectEqual(@as(?u32, n), d); // u32에 들어간다
    try testing.expect(t1 - t0 < 200_000); // 재앙 감지선
}

test "접힌 범위가 숨는 구간이 된다" {
    const lines = [_][]const u8{ "a:", "  1", "  2", "b:", "  3" };
    var rbuf: [8]Range = undefined;
    const rs = compute(&lines, 4, &rbuf);
    var sbuf: [8]Span = undefined;

    try testing.expectEqual(@as(usize, 0), hiddenSpans(rs, &.{}, &sbuf).len); // 아무것도 안 접었다

    const one = hiddenSpans(rs, &.{0}, &sbuf);
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqual(@as(u32, 1), one[0].first);
    try testing.expectEqual(@as(u32, 2), one[0].last);
    try testing.expect(isHidden(one, 1) and isHidden(one, 2));
    try testing.expect(!isHidden(one, 0) and !isHidden(one, 3));
}

test "중첩을 둘 다 접으면 한 구간으로 합친다 — 같은 줄을 두 번 건너뛰면 안 된다" {
    const lines = [_][]const u8{ "class A:", "    def m():", "        x = 1", "        y = 2" };
    var rbuf: [8]Range = undefined;
    const rs = compute(&lines, 4, &rbuf);
    try testing.expectEqual(@as(usize, 2), rs.len);

    var sbuf: [8]Span = undefined;
    const both = hiddenSpans(rs, &.{ 0, 1 }, &sbuf);
    try testing.expectEqual(@as(usize, 1), both.len); // 바깥이 안쪽을 덮는다
    try testing.expectEqual(@as(u32, 1), both[0].first);
    try testing.expectEqual(@as(u32, 3), both[0].last);
}

test "이어붙은 접힘도 한 구간이다 — 사이에 보이는 줄이 없다" {
    const lines = [_][]const u8{ "a:", "  1", "b:", "  2" };
    var rbuf: [8]Range = undefined;
    const rs = compute(&lines, 4, &rbuf);
    var sbuf: [8]Span = undefined;
    const s = hiddenSpans(rs, &.{ 0, 2 }, &sbuf);
    // 1은 숨고 2(머리)는 보이므로 **합쳐지면 안 된다**.
    try testing.expectEqual(@as(usize, 2), s.len);
    try testing.expect(!isHidden(s, 2));
}

test "범위가 사라진 머리가 상태에 남아 있어도 무시한다" {
    const lines = [_][]const u8{ "a:", "  1" };
    var rbuf: [8]Range = undefined;
    const rs = compute(&lines, 4, &rbuf);
    var sbuf: [8]Span = undefined;
    const s = hiddenSpans(rs, &.{ 0, 99 }, &sbuf); // 99는 범위가 없다
    try testing.expectEqual(@as(usize, 1), s.len);
}

test "[측정] 전체 접기 — 큰 문서에서 숨는 구간 만들기" {
    // §4가 **전체 접기**를 요구한다. 그때 `collapsed`가 모든 머리라, 머리마다 목록을 훑으면 O(n²)다.
    const alloc = testing.allocator;
    for ([_]usize{ 2000, 4000 }) |blocks| {
        const n = blocks * 2;
        const lines = try alloc.alloc([]const u8, n);
        defer alloc.free(lines);
        for (0..blocks) |b| {
            lines[b * 2] = "head:";
            lines[b * 2 + 1] = "  body";
        }
        const rbuf = try alloc.alloc(Range, n);
        defer alloc.free(rbuf);
        const rs = compute(lines, 4, rbuf);

        const collapsed = try alloc.alloc(u32, rs.len);
        defer alloc.free(collapsed);
        for (rs, 0..) |r, i| collapsed[i] = r.head;

        const sbuf = try alloc.alloc(Span, rs.len);
        defer alloc.free(sbuf);
        const t0 = monotonicUs();
        const spans = hiddenSpans(rs, collapsed, sbuf);
        const t1 = monotonicUs();
        std.debug.print("\n[측정] {d}블록 전체 접기: {d}구간, {d}µs\n", .{ blocks, spans.len, t1 - t0 });
        try testing.expect(t1 - t0 < 100_000);
    }
}
