//! 붙여넣은 이미지의 **전송 전 스테이징** — 계약은
//! [docs/agent-image-marker-preview.md](../../docs/agent-image-marker-preview.md) §3·§4가 소유한다.
//!
//! **왜 이 모듈이 있나**: 사용자가 이미지를 붙여넣으면 TUI가 화면에 `[Image #N]` 글자를 그린다. 그 마커를
//! 눌렀을 때 무엇을 보여줄지 알려면 «N이 어느 그림인가» 를 우리가 들고 있어야 하는데, **그 PNG를 저장한
//! 것이 maru 자신이다**(`MaruAppHost.swift`의 clipboardImagePng → saveTempPng → sendPasteText). 그래서
//! 전송 전 프리뷰에는 트랜스크립트도 인덱스도 필요 없다 — 붙여넣는 순간 손에 쥔 것을 이어 두기만 하면 된다.
//!
//! **번호를 추측하지 않고 관찰한다.** provider마다 N의 의미가 다르고(Claude는 프로세스 누적, Codex는 입력창
//! 단위) **빈 번호가 재사용되지 않아**(`#1 #2` 중 뒤를 지우고 다시 붙이면 `#1 #3`) 순서로 세면 틀린다(§4.2).
//! 그래서 붙여넣기 직전 화면의 N 집합을 찍어 두고, 마커가 뜬 뒤 **새로 나타난 N**을 그 PNG에 묶는다.
//!
//! **플랫폼을 모른다.** `std`만 쓰고 파일을 열지 않는다 — 화면에서 긁은 텍스트와 PNG 바이트를 받는다.
//! 그래서 Linux 타깃으로도 컴파일·테스트된다.

const std = @import("std");

/// 마커 문자열. **두 provider가 같다**(실측 §10 — Claude 2.1.267 · Codex 0.154.0).
pub const marker_prefix = "[Image #";

/// `[Image #` 뒤에 올 수 있는 자릿수 상한. 실측 최대가 `#39`였고, 이보다 길면 마커가 아니라 본문이다.
/// `stripImageMarkers`(agent_image_context)가 `]` 위치로 같은 판정을 하는 것과 같은 규율.
pub const max_digits: usize = 6;

/// 화면 텍스트에서 찾은 마커 하나.
pub const Marker = struct {
    /// `[` 의 바이트 오프셋(입력 슬라이스 기준).
    start: usize,
    /// `]` **다음** 바이트 오프셋. `text[start..end]` 가 마커 전체다.
    end: usize,
    /// `#` 뒤의 십진수.
    n: u32,
};

/// 한 줄에서 마커를 **모두** 찾는다. 실측에서 `❯ [Image #1] [Image #2]` 처럼 나란히 오므로,
/// 첫 매치만 보고 끝내면 두 번째 이미지는 영영 못 연다(§3).
///
/// **이것은 후보만 낸다.** 마커에는 SGR이 없어(실측 §10) 사람이 타이핑한 같은 글자와 바이트가 동일하므로,
/// 「진짜 마커인가」는 `Staging.lookup`이 기록으로 정한다(§3.1).
pub fn scanLine(line: []const u8, out: *std.ArrayList(Marker), allocator: std.mem.Allocator) !void {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, line, i, marker_prefix)) |at| {
        const after = at + marker_prefix.len;
        if (parseDigitsAndClose(line, after)) |hit| {
            try out.append(allocator, .{ .start = at, .end = hit.end, .n = hit.n });
            i = hit.end;
        } else {
            i = after; // 숫자가 아니면 마커가 아니다 — 그 자리 다음부터 다시 찾는다
        }
    }
}

const DigitsHit = struct { n: u32, end: usize };

/// `[Image #` 바로 뒤부터 십진수와 `]` 를 읽는다. 숫자가 없거나 `]` 가 안 오면 마커가 아니다.
fn parseDigitsAndClose(line: []const u8, after_prefix: usize) ?DigitsHit {
    var j = after_prefix;
    var n: u32 = 0;
    var digits: usize = 0;
    while (j < line.len and line[j] >= '0' and line[j] <= '9') : (j += 1) {
        digits += 1;
        if (digits > max_digits) return null; // 본문이지 마커가 아니다
        n = n * 10 + (line[j] - '0');
    }
    if (digits == 0) return null;
    if (j >= line.len or line[j] != ']') return null;
    return .{ .n = n, .end = j + 1 };
}

/// 한 항목의 수명. **버리지 않고 옮긴다** — 전송은 「입력창 비우기」와 화면상 구분되지 않으므로(§4.2 A11),
/// 마커가 사라졌다고 픽셀을 놓으면 인덱스가 받기 전까지 그 이미지가 어디에도 없게 된다.
pub const Phase = enum {
    /// 입력창에 마커가 보인다.
    staged,
    /// 입력창에서 사라졌다(전송 또는 비우기). **픽셀을 계속 든다.**
    sent,
};

pub const Entry = struct {
    n: u32,
    phase: Phase = .staged,
    /// PNG 바이트. 이 모듈이 소유한다(`deinit`이 푼다).
    png: []u8,
    /// 오래된 것부터 거두기 위한 순번(단조 증가). 시계를 쓰지 않는다 — 순서만 필요하다.
    seq: u64,
};

/// 한 surface(=에이전트 프로세스 하나)의 스테이징.
///
/// **surface별이다.** 갤러리의 `agent_activity: State`는 세션에 하나이고 포커스 따라 내용이 바뀌는데,
/// 그 패턴을 베끼면 두 pane의 `#1`이 같은 칸을 다툰다 — N의 네임스페이스가 프로세스별이기 때문이다(§4.2).
pub const Staging = struct {
    entries: std.ArrayList(Entry) = .empty,
    next_seq: u64 = 0,
    /// 든 PNG 바이트 합.
    bytes: usize = 0,
    /// 상한. **개수가 아니라 바이트다** — 같은 그림을 두 번 붙여도 `saveTempPng`가 UUID로 새 파일을
    /// 만들어 접히지 않고(§4.2 A19), 스크린샷 한 장이 수십 MB라 개수로는 메모리가 안 묶인다.
    budget_bytes: usize = default_budget_bytes,

    pub const default_budget_bytes: usize = 64 * 1024 * 1024;

    pub fn deinit(self: *Staging, allocator: std.mem.Allocator) void {
        for (self.entries.items) |e| allocator.free(e.png);
        self.entries.deinit(allocator);
        self.* = .{};
    }

    /// 관찰로 확정된 항목을 넣는다. `png`의 소유권을 가져간다.
    ///
    /// 같은 N이 이미 있으면 **새 것으로 갈아치운다** — provider가 번호를 재사용하는 경우(Codex가 입력창을
    /// 비운 뒤 다시 `#1`부터)가 그 길이고, 옛 항목은 이미 `sent`라 화면에 없다.
    pub fn put(self: *Staging, allocator: std.mem.Allocator, n: u32, png: []u8) !void {
        if (self.indexOf(n)) |i| {
            const old = self.entries.items[i];
            self.bytes -= old.png.len;
            allocator.free(old.png);
            _ = self.entries.orderedRemove(i);
        }
        try self.entries.append(allocator, .{
            .n = n,
            .phase = .staged,
            .png = png,
            .seq = self.next_seq,
        });
        self.next_seq += 1;
        self.bytes += png.len;
        self.evictToBudget(allocator);
    }

    /// 예산을 넘으면 **오래된 `sent`부터** 놓는다. `staged`는 화면에 마커가 보이는 것이라 남긴다 —
    /// 그것을 거두면 눈앞의 마커가 안 열린다.
    fn evictToBudget(self: *Staging, allocator: std.mem.Allocator) void {
        while (self.bytes > self.budget_bytes) {
            var victim: ?usize = null;
            for (self.entries.items, 0..) |e, i| {
                if (e.phase != .sent) continue;
                if (victim == null or e.seq < self.entries.items[victim.?].seq) victim = i;
            }
            const i = victim orelse break; // 전부 staged면 더 거둘 것이 없다
            self.bytes -= self.entries.items[i].png.len;
            allocator.free(self.entries.items[i].png);
            _ = self.entries.orderedRemove(i);
        }
    }

    fn indexOf(self: *const Staging, n: u32) ?usize {
        for (self.entries.items, 0..) |e, i| if (e.n == n) return i;
        return null;
    }

    /// 「이 N이 우리 기록에 있는가」 — 화면의 마커가 진짜인지 정하는 유일한 출처(§3.1).
    pub fn lookup(self: *const Staging, n: u32) ?*const Entry {
        const i = self.indexOf(n) orelse return null;
        return &self.entries.items[i];
    }

    /// 화면에 지금 보이는 N 집합을 받아 상태를 맞춘다. 보이지 않는 `staged`는 `sent`로 **옮긴다**(버리지
    /// 않는다). 전송인지 비우기인지 구분할 방법이 없고, 구분할 필요도 없다 — 둘 다 픽셀은 계속 필요하다.
    pub fn syncVisible(self: *Staging, visible: []const u32) void {
        for (self.entries.items) |*e| {
            if (e.phase != .staged) continue;
            if (!containsN(visible, e.n)) e.phase = .sent;
        }
    }

    /// 인덱스가 같은 이미지를 받았다 — 이제 갤러리가 소유하므로 픽셀을 놓는다(§4.4).
    pub fn release(self: *Staging, allocator: std.mem.Allocator, n: u32) void {
        const i = self.indexOf(n) orelse return;
        self.bytes -= self.entries.items[i].png.len;
        allocator.free(self.entries.items[i].png);
        _ = self.entries.orderedRemove(i);
    }
};

fn containsN(haystack: []const u32, n: u32) bool {
    for (haystack) |x| if (x == n) return true;
    return false;
}

/// 붙여넣기 한 번의 관찰. 직전 N 집합을 들고 있다가, 마커가 뜬 뒤 **새로 나타난 N**을 고른다.
///
/// 실측: 마커는 **42 ms 안에** 뜨고, 간격 없이 두 장을 넣으면 `#2 #3`이 **한꺼번에** 나타난다(§10).
/// 그래서 새 N이 여럿일 수 있고, 그때는 **오름차순**으로 붙여넣은 큐에 대응시킨다.
pub const Observation = struct {
    before: std.ArrayList(u32) = .empty,

    pub fn deinit(self: *Observation, allocator: std.mem.Allocator) void {
        self.before.deinit(allocator);
        self.* = .{};
    }

    /// 붙여넣기 **직전** 화면의 N 집합을 찍는다.
    pub fn arm(self: *Observation, allocator: std.mem.Allocator, now_visible: []const u32) !void {
        self.before.clearRetainingCapacity();
        try self.before.appendSlice(allocator, now_visible);
    }

    /// 지금 화면의 N 집합에서 **새로 나타난 것**을 오름차순으로 돌려준다. 호출자가 `out`을 소유한다.
    pub fn fresh(
        self: *const Observation,
        allocator: std.mem.Allocator,
        now_visible: []const u32,
        out: *std.ArrayList(u32),
    ) !void {
        for (now_visible) |n| {
            if (containsN(self.before.items, n)) continue;
            if (containsN(out.items, n)) continue; // 같은 N이 화면에 두 번 보여도 한 번만
            try out.append(allocator, n);
        }
        std.mem.sort(u32, out.items, {}, std.sort.asc(u32));
    }
};

const testing = std.testing;

test "마커 스캔: 한 줄에 나란히 온 것을 모두 찾는다 (실측 `❯ [Image #1] [Image #2]`)" {
    var out: std.ArrayList(Marker) = .empty;
    defer out.deinit(testing.allocator);
    try scanLine("\u{276F} [Image #1] [Image #2]", &out, testing.allocator);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(@as(u32, 1), out.items[0].n);
    try testing.expectEqual(@as(u32, 2), out.items[1].n);
}

test "마커 스캔: 문장 뒤에 와도 찾는다 — 맨 앞으로 가정하면 놓친다(실측 `… 안 맞음 [Image #36]`)" {
    var out: std.ArrayList(Marker) = .empty;
    defer out.deinit(testing.allocator);
    try scanLine("왼쪽 워크스페이스는 맞는데 상단 pane은 안 맞음 [Image #36]", &out, testing.allocator);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(u32, 36), out.items[0].n);
}

test "마커 스캔: 숫자가 아니거나 `]` 가 없으면 마커가 아니다" {
    var out: std.ArrayList(Marker) = .empty;
    defer out.deinit(testing.allocator);
    try scanLine("[Image #abc] [Image #12 [Image #] [Image #7]", &out, testing.allocator);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(u32, 7), out.items[0].n);
}

test "마커 스캔: 자릿수가 과하면 본문으로 본다" {
    var out: std.ArrayList(Marker) = .empty;
    defer out.deinit(testing.allocator);
    try scanLine("[Image #1234567]", &out, testing.allocator);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

fn dupPng(bytes: []const u8) ![]u8 {
    return try testing.allocator.dupe(u8, bytes);
}

test "스테이징: 관찰한 N으로 찾는다. 기록에 없는 N은 열지 않는다 (§3.1)" {
    var s: Staging = .{};
    defer s.deinit(testing.allocator);
    try s.put(testing.allocator, 1, try dupPng("A"));
    try testing.expect(s.lookup(1) != null);
    try testing.expect(s.lookup(2) == null); // 화면에 글자로 쓰인 `[Image #2]` 는 우리 것이 아니다
}

test "스테이징: 빈 번호가 재사용되지 않아 `#1 #3` 이 와도 각자 맞는다 (§4.3 실측)" {
    var s: Staging = .{};
    defer s.deinit(testing.allocator);
    try s.put(testing.allocator, 1, try dupPng("A"));
    try s.put(testing.allocator, 2, try dupPng("B"));
    try s.put(testing.allocator, 3, try dupPng("C"));
    // `#2` 를 지우고 다시 붙인 상태 — 화면에는 `#1 #3` 만 보인다.
    s.syncVisible(&.{ 1, 3 });
    try testing.expectEqualStrings("A", s.lookup(1).?.png);
    try testing.expectEqualStrings("C", s.lookup(3).?.png);
    // 순서로 셌다면 «마지막 2개» = B·C 라 왼쪽이 남의 그림이 됐을 것이다.
    try testing.expectEqual(Phase.sent, s.lookup(2).?.phase);
}

test "스테이징: 전송으로 마커가 사라져도 픽셀을 든다 — 인덱스가 받기 전까지 (§4.2 A11)" {
    var s: Staging = .{};
    defer s.deinit(testing.allocator);
    try s.put(testing.allocator, 1, try dupPng("A"));
    s.syncVisible(&.{}); // Enter 로 보냈다(= C-u 로 비웠다와 화면상 같다)
    const e = s.lookup(1) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Phase.sent, e.phase);
    try testing.expectEqualStrings("A", e.png); // 아직 열 수 있다
    s.release(testing.allocator, 1); // 인덱스가 받았다
    try testing.expect(s.lookup(1) == null);
}

test "스테이징: 예산은 바이트로 묶고 `staged` 는 거두지 않는다" {
    var s: Staging = .{ .budget_bytes = 8 };
    defer s.deinit(testing.allocator);
    try s.put(testing.allocator, 1, try dupPng("AAAA"));
    try s.put(testing.allocator, 2, try dupPng("BBBB"));
    s.syncVisible(&.{2}); // #1 은 sent, #2 는 화면에 보인다
    try s.put(testing.allocator, 3, try dupPng("CCCC")); // 예산 초과 → 오래된 sent(#1)를 놓는다
    try testing.expect(s.lookup(1) == null);
    try testing.expect(s.lookup(2) != null); // staged 는 살아남는다
    try testing.expect(s.lookup(3) != null);
}

test "스테이징: 전부 staged 면 예산을 넘겨도 거두지 않는다 — 눈앞의 마커가 안 열리면 안 된다" {
    var s: Staging = .{ .budget_bytes = 4 };
    defer s.deinit(testing.allocator);
    try s.put(testing.allocator, 1, try dupPng("AAAA"));
    try s.put(testing.allocator, 2, try dupPng("BBBB"));
    try testing.expect(s.lookup(1) != null);
    try testing.expect(s.lookup(2) != null);
}

test "스테이징: 같은 N 이 다시 오면 갈아치운다 (Codex 가 입력창을 비운 뒤 다시 #1)" {
    var s: Staging = .{};
    defer s.deinit(testing.allocator);
    try s.put(testing.allocator, 1, try dupPng("OLD"));
    s.syncVisible(&.{});
    try s.put(testing.allocator, 1, try dupPng("NEW"));
    try testing.expectEqualStrings("NEW", s.lookup(1).?.png);
    try testing.expectEqual(@as(usize, 3), s.bytes); // 옛 것이 남아 있지 않다
}

test "관찰: 새로 나타난 N만 고른다 — Claude 가 #3 으로 건너뛰어도 맞는다" {
    var o: Observation = .{};
    defer o.deinit(testing.allocator);
    try o.arm(testing.allocator, &.{1});
    var fresh: std.ArrayList(u32) = .empty;
    defer fresh.deinit(testing.allocator);
    try o.fresh(testing.allocator, &.{ 1, 3 }, &fresh);
    try testing.expectEqual(@as(usize, 1), fresh.items.len);
    try testing.expectEqual(@as(u32, 3), fresh.items[0]);
}

test "관찰: 연속 붙여넣기로 둘이 한꺼번에 나타나면 오름차순으로 준다 (§10 실측)" {
    var o: Observation = .{};
    defer o.deinit(testing.allocator);
    try o.arm(testing.allocator, &.{1});
    var fresh: std.ArrayList(u32) = .empty;
    defer fresh.deinit(testing.allocator);
    try o.fresh(testing.allocator, &.{ 3, 1, 2 }, &fresh);
    try testing.expectEqual(@as(usize, 2), fresh.items.len);
    try testing.expectEqual(@as(u32, 2), fresh.items[0]);
    try testing.expectEqual(@as(u32, 3), fresh.items[1]);
}

test "관찰: 아무것도 안 나타나면 빈 목록 — 그 장은 기록하지 않는다(조용한 실패)" {
    var o: Observation = .{};
    defer o.deinit(testing.allocator);
    try o.arm(testing.allocator, &.{ 1, 2 });
    var fresh: std.ArrayList(u32) = .empty;
    defer fresh.deinit(testing.allocator);
    try o.fresh(testing.allocator, &.{ 1, 2 }, &fresh);
    try testing.expectEqual(@as(usize, 0), fresh.items.len);
}
