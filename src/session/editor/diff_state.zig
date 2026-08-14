//! N1.5 슬라이스 b — **요청 상태를 화면 네 상태로 옮기는 규칙**(docs/native-editor-ui.md §7).
//!
//! 백엔드는 "아직 안 왔다 / 실패했다 / 잘렸다 / 두 쪽이 왔다"만 말한다. 화면은 §7이 정한 네 상태
//! (읽는 중·보여 줄 수 없음(이유)·변경 없음·비교)로 말해야 한다. **그 사이의 판단을 여기 모은다** —
//! 순수 함수라 화면 없이 검사되고, 도크 목록과 본문이 같은 판정을 쓰게 된다.
//!
//! **왜 별도 모듈인가**: `diff.zig`는 두 줄 배열의 대응만 안다(git도 요청도 모른다). 요청의 시간·실패·
//! 잘림은 그 위층의 사실이다. 섞으면 대응 계산이 요청 수명주기를 알게 되어 둘 다 테스트하기 어려워진다.

const std = @import("std");
const diff = @import("diff.zig");

/// 백엔드가 지금까지 말한 것. app_session의 dock entry 플래그를 그대로 옮긴 모양이다.
pub const Feed = struct {
    /// 두 쪽 전문이 도착했다.
    ready: bool = false,
    /// 요청이 실패했다(git 없음·경로 없음·거절).
    failed: bool = false,
    /// 상한에서 잘린 내용이다. **온전한 파일처럼 그리지 않는다** — 잘린 뒤가 통째로 삭제된 것처럼 보인다.
    truncated: bool = false,
    /// 요청을 건 뒤 흐른 시간.
    waited_ms: u64 = 0,
};

/// **무한히 기다리지 않는다**(§7). CM6 구현이 쓰던 값 그대로다 — `120ms × 50회`(`web/src/diff-view.ts`).
/// 우리는 폴링 간격이 tick이라 회수 대신 총 시간으로 잰다(같은 6초).
pub const retry_window_ms: u64 = 120 * 50;

/// git이 바이너리로 판정하는 창. 앞쪽 이만큼에 NUL이 있으면 텍스트가 아니라고 본다(git `buffer_is_binary`와
/// 같은 규칙 — 그래야 목록이 "Binary files differ"라 말한 파일을 본문도 같게 판정한다).
pub const binary_probe_bytes: usize = 8000;

/// 이번 tick에 할 일.
pub const Step = union(enum) {
    /// 아직 기다린다. 화면은 "읽는 중"이다.
    wait,
    /// 두 쪽이 왔다 — 줄 대응을 계산해라.
    compare,
    /// 이유를 말하고 끝낸다.
    give_up: diff.Unavailable,
};

/// **순서가 규칙이다.** 실패가 먼저고, 그다음이 잘림, 그다음이 도착, 마지막이 시간 초과다.
///
/// - 실패한 요청은 아무리 기다려도 오지 않으므로 곧바로 접는다. `unknown`인 이유는 §7이 *"이유를
///   지어내지 않는다"*고 정했기 때문이다 — 거절 사유를 모르면 모른다고 말한다.
/// - **잘림은 도착보다 먼저 본다.** `ready`를 먼저 보면 잘린 내용으로 대응을 계산해 뒤쪽이 통째로
///   삭제된 것처럼 보인다(제품의 `diffSidesForSurface`도 같은 순서로 `error.TooLarge`를 낸다).
/// - 시간 초과는 **마지막**이다. 6초가 지난 순간 결과가 와 있으면 그것을 쓴다 — 기다린 값을 버릴 이유가 없다.
pub fn step(feed: Feed) Step {
    if (feed.failed) return .{ .give_up = .unknown };
    if (feed.ready and feed.truncated) return .{ .give_up = .too_large };
    if (feed.ready) return .compare;
    if (feed.waited_ms >= retry_window_ms) return .{ .give_up = .unknown };
    return .wait;
}

/// 텍스트가 아닌가. **한쪽만 바이너리여도 비교를 그리지 않는다** — 한쪽을 글자로 읽어 대응을 만들면
/// 의미 없는 줄 대응이 화면에 뜬다.
pub fn isBinary(bytes: []const u8) bool {
    const probe = bytes[0..@min(bytes.len, binary_probe_bytes)];
    return std.mem.indexOfScalar(u8, probe, 0) != null;
}

/// **줄 끝 문자를 줄에 포함해** 자른다. 이 선택이 목록(`git diff --numstat`)과의 일치를 좌우한다 —
/// 개행을 떼면 `"a\nb\n"`와 `"a\nb"`가 같은 배열이 되어 본문은 "변경 없음"인데 git은 `+1 -1`을 낸다.
/// CRLF도 같다(`\r`를 떼면 본문만 "변경 없음", git은 `+2 -2`). 표시할 때 떼는 것은 뷰의 몫이다.
///
/// 반환 슬라이스들은 **입력 버퍼를 빌린다**. 배열 자체는 호출자가 해제한다.
pub fn splitLines(allocator: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const []const u8 {
    if (text.len == 0) return &.{};
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (count += 1) {
        const nl = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse break;
        i = nl + 1;
    }
    // 마지막 개행 뒤에 글자가 남았으면 그것도 한 줄이다(끝 개행이 없는 파일).
    if (i < text.len) count += 1;

    const out = try allocator.alloc([]const u8, count);
    errdefer allocator.free(out);
    var idx: usize = 0;
    i = 0;
    while (idx < count) : (idx += 1) {
        const nl = std.mem.indexOfScalarPos(u8, text, i, '\n');
        const end = if (nl) |n| n + 1 else text.len;
        out[idx] = text[i..end];
        i = end;
    }
    return out;
}

const testing = std.testing;

test "실패는 곧바로 접는다 — 기다려도 오지 않는다" {
    try testing.expectEqual(Step{ .give_up = .unknown }, step(.{ .failed = true }));
    // 결과가 함께 와 있어도 실패가 이긴다(부분 결과를 정상처럼 그리지 않는다).
    try testing.expectEqual(Step{ .give_up = .unknown }, step(.{ .failed = true, .ready = true }));
}

test "잘림을 도착보다 먼저 본다 — 잘린 내용으로 대응을 계산하면 뒤가 통째로 삭제로 보인다" {
    try testing.expectEqual(Step{ .give_up = .too_large }, step(.{ .ready = true, .truncated = true }));
    // 순서가 뒤집히면 이 케이스가 `.compare`가 된다 — 그 뮤턴트를 죽이는 단언이다.
    try testing.expectEqual(Step.compare, step(.{ .ready = true }));
}

test "무한히 기다리지 않는다 — 6초가 재시도 창이다" {
    try testing.expectEqual(Step.wait, step(.{ .waited_ms = retry_window_ms - 1 }));
    try testing.expectEqual(Step{ .give_up = .unknown }, step(.{ .waited_ms = retry_window_ms }));
    // **시간 초과보다 도착이 먼저다.** 6초가 지난 순간 결과가 있으면 기다린 값을 버리지 않는다.
    try testing.expectEqual(Step.compare, step(.{ .ready = true, .waited_ms = retry_window_ms * 10 }));
}

test "NUL이 있으면 바이너리다 — 앞 8,000바이트만 본다(git과 같은 창)" {
    try testing.expect(!isBinary("보통 텍스트\n두 줄"));
    try testing.expect(isBinary("앞\x00뒤"));
    try testing.expect(!isBinary(""));
    // 창 **밖**의 NUL은 보지 않는다 — git이 그렇게 판정하므로 목록과 본문이 갈리지 않는다.
    var buf: [binary_probe_bytes + 16]u8 = undefined;
    @memset(&buf, 'a');
    buf[binary_probe_bytes + 4] = 0;
    try testing.expect(!isBinary(&buf));
    buf[binary_probe_bytes - 1] = 0;
    try testing.expect(isBinary(&buf));
}

test "줄 끝 문자를 줄에 포함해 자른다 — 목록과 어긋나지 않게 하는 선택이다" {
    const alloc = testing.allocator;
    {
        const lines = try splitLines(alloc, "a\nb\n");
        defer alloc.free(lines);
        try testing.expectEqual(@as(usize, 2), lines.len);
        try testing.expectEqualStrings("a\n", lines[0]);
        try testing.expectEqualStrings("b\n", lines[1]);
    }
    {
        // 끝 개행이 없다 — 마지막 줄이 위와 **다른 문자열**이어야 git의 `+1 -1`과 맞는다.
        const lines = try splitLines(alloc, "a\nb");
        defer alloc.free(lines);
        try testing.expectEqual(@as(usize, 2), lines.len);
        try testing.expectEqualStrings("b", lines[1]);
    }
    {
        const lines = try splitLines(alloc, "a\r\nb\r\n");
        defer alloc.free(lines);
        try testing.expectEqualStrings("a\r\n", lines[0]);
    }
    {
        // 빈 파일은 줄이 없다. "빈 줄 하나"로 세면 새 파일 비교에서 없는 줄이 한 줄 생긴다.
        const lines = try splitLines(alloc, "");
        defer alloc.free(lines);
        try testing.expectEqual(@as(usize, 0), lines.len);
    }
    {
        // 개행만 있는 파일은 **빈 줄 하나**다(그 줄의 내용이 개행이다).
        const lines = try splitLines(alloc, "\n");
        defer alloc.free(lines);
        try testing.expectEqual(@as(usize, 1), lines.len);
        try testing.expectEqualStrings("\n", lines[0]);
    }
}

test "자른 줄을 이으면 원문이다 — 무작위 200개" {
    // 한 바이트라도 흘리면 대응이 원문과 다른 것을 비교하게 된다. 되돌림으로 그것을 막는다.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var prng = std.Random.DefaultPrng.init(0x5P1);
    const rnd = prng.random();
    var case_i: usize = 0;
    while (case_i < 200) : (case_i += 1) {
        _ = arena.reset(.retain_capacity);
        const alloc = arena.allocator();
        const n = rnd.uintLessThan(usize, 64);
        const text = try alloc.alloc(u8, n);
        for (text) |*c| c.* = switch (rnd.uintLessThan(u8, 5)) {
            0 => '\n',
            1 => '\r',
            2 => 'a',
            3 => ' ',
            else => 'b',
        };
        const lines = try splitLines(alloc, text);
        var joined: std.ArrayList(u8) = .empty;
        for (lines) |l| try joined.appendSlice(alloc, l);
        try testing.expectEqualStrings(text, joined.items);
    }
}
