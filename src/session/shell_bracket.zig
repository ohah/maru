//! 셸 구간(bracket) — 에이전트의 셸 도구가 **돌고 있던 시간**을 턴 단위로 든다(계획 AT3b-1).
//!
//! 순수 층이다(L2, I/O 없음·할당 없음). 시각은 호출자가 넣는다 — 이 층은 «언제» 를 모르고 «순서와
//! 규율» 만 안다. 계약의 단일 출처는 [docs/agent-turn-changes.md](../../docs/agent-turn-changes.md) §4.4 와
//! [계획 AT3b](../../docs/plans/agent-turn-changes.md)다.
//!
//! **무엇을 답하나**: 「이 턴에서 에이전트의 셸이 돌던 구간들은 언제였나」. 원래 소비자로 두었던 AT3b-3(시간 창
//! 폴백 — 구간 안에 `ctime` 이 떨어진 파일을 «셸이 고쳤다(추정)» 로 올리기)은 **2026-09-21 AT3d 에서 폐기했다**:
//! 그 창은 추정이고(계약 §8-10) 확신은 provider 의 diff(Claude `bashEditDiff`, AT3b-2)뿐이라 Codex 의 셸 편집은 `·`
//! 로 남긴다. 이 구간은 지금 **셸 호출 수**(고지 줄, `Turn.shell_calls`)와 「구간이 닫혔나」 판정에 쓰인다. 구간은
//! **턴 단위 합집합**으로 쓴다 — 어느 명령의 소행인지는 묻지 않는다(계획 ⑷). 그래서 겹친 구간은 무해하고, 여기서
//! 합치지도 않는다.
//!
//! **구간의 양끝은 훅 이벤트다**: `PreToolUse(Bash)` 가 열고 **같은 `tool_use_id`** 의
//! `PostToolUse`/`PostToolUseFailure` 가 닫는다. «다음 `Pre` 가 끝» 을 쓰지 않는다 — 병렬 호출에서 깨진다
//! (계약 A21). 열린 id 집합이 비어 있지 않은 동안이 «셸이 도는 중» 이다.
//!
//! **시각의 규율 — 놓치는 쪽이 아니라 더 잡는 쪽으로 틀린다.** 훅 payload 에는 시각이 없고(훅 셸은 bash 3.2 라
//! `$EPOCHREALTIME` 도 없다 — 2026-09-19 실측) 우리가 아는 시각은 **poll 이 읽은 때**(500 ms 주기)뿐이다.
//! 그래서 시작을 아래로 넉넉히 잡는다: claude 는 `duration_ms` 를 실으므로 `min(Pre 관측, Post 관측 − 길이)`,
//! 거기서 poll 주기만큼 더 뺀다. 그 대가(구간 첫 0.5초의 사용자 편집이 섞일 수 있다)는 계약 §8 의 한계로
//! 적었다 — 반대로 틀리면 명령 첫 0.5초의 쓰기가 `ctime < 시작` 으로 **조용히 빠진다.**
//!
//! **배경 호출은 턴 끝까지 연다.** `run_in_background` 의 `Post` 는 띄운 순간(0.030 s) 오므로 거기서 닫으면
//! 그 뒤의 쓰기가 전부 구간 밖이다(셸 호출의 5.1%). 스스로 배경화한 명령(`… &`, 0.8%)은 플래그가 없어
//! 못 가른다 — 명령 문자열을 파싱하지 않는다(계획 ⑷) — 그 쓰기는 `·` 로 남는다.
//!
//! **상한을 넘기면 «확정하지 않는다».** 자리가 모자라 담지 못한 구간이 하나라도 있으면 `overflow` 가 서고,
//! 그 턴의 구간은 귀속 근거로 쓰지 않는다(계약 §6.1 「확실히 알 수 없으면 말하지 않는다」). 조용히 잘라
//! 일부만 들면 그 턴의 `✎` 가 **적게** 뜨는데, 그것은 「안 고쳤다」로 읽힌다.

const std = @import("std");
const event = @import("agent_hook_event.zig");

/// 짝짓기 키의 고정 버퍼. 파서 상수와 같은 값이다 — 훅이 상한 초과 payload 에서 id 를 살릴 때도 이 길이로
/// 자르므로(`agent_hook_command`), 세 곳이 한 값을 본다.
pub const max_id_len: usize = event.max_tool_use_id_len;

/// 동시에 열려 있을 수 있는 구간 수. 병렬 도구 호출 + 턴 끝까지 열어 두는 배경 호출의 합이다. 실측 최대
/// 병렬 호출은 한 자리 수이고 배경 호출은 턴당 몇 개다. 넘기면 `overflow`.
pub const max_open: usize = 8;

/// 한 턴이 드는 닫힌 구간 수. 트랜스크립트 기준 턴당 셸 호출은 중앙값 한 자리·상위 1% 가 수십이다.
/// 넘기면 `overflow` — 그 턴은 귀속 근거로 쓰지 않는다.
pub const max_intervals: usize = 48;

/// 닫힌 구간 하나. wall-clock ms(파일 `ctime` 과 비교해야 하므로 monotonic 이 아니다).
pub const Interval = struct {
    start_ms: u64,
    end_ms: u64,

    /// 이 시각이 구간 안에 있나(양끝 포함).
    pub fn contains(self: Interval, ms: u64) bool {
        return ms >= self.start_ms and ms <= self.end_ms;
    }

    /// 두 구간이 겹치나(양끝 포함).
    pub fn overlaps(self: Interval, other: Interval) bool {
        return self.start_ms <= other.end_ms and other.start_ms <= self.end_ms;
    }
};

const Open = struct {
    used: bool = false,
    id: [max_id_len]u8 = undefined,
    id_len: usize = 0,
    /// `Pre` 를 관측한 시각.
    opened_ms: u64 = 0,
    /// `run_in_background` — `Post` 로 닫지 않고 턴 끝까지 연다.
    background: bool = false,

    fn key(self: *const Open) []const u8 {
        return self.id[0..self.id_len];
    }
};

/// 왜 닫히지 않았나 — `close` 의 답. 통계와 테스트가 갈라 본다.
pub const Close = enum {
    /// 짝을 찾아 닫았다(구간이 하나 늘었다).
    closed,
    /// 배경 호출이라 **일부러 안 닫았다** — 턴 끝까지 열린다.
    kept_background,
    /// 열린 짝이 없다. backlog·회전본에서 `Pre` 를 건너뛰었거나, 상한에 밀려 못 열었거나, 훅이 id 를
    /// 잃었다(상한 초과 payload 에서 검증을 못 지난 id). 무시한다 — 모르는 것을 지어내지 않는다.
    unmatched,
};

/// 한 턴의 구간들. `turn_capture.Turn` 이 하나 든다.
pub const Brackets = struct {
    open: [max_open]Open = @splat(.{}),
    intervals: [max_intervals]Interval = undefined,
    len: usize = 0,
    /// 자리가 모자라 담지 못한 것이 있었다 → 이 턴의 구간은 **확정하지 않는다.**
    overflow: bool = false,
    /// 짝 없는 `Post` 수. 화면에 안 나간다 — 로그·테스트가 본다.
    unmatched: u32 = 0,

    /// `PreToolUse(Bash)` — 구간을 연다. 같은 id 가 이미 열려 있으면 아무것도 하지 않는다(중복 이벤트).
    /// id 가 비거나 상한을 넘으면 열지 않고 `overflow` 를 세운다 — 짝지을 수 없는 구간은 닫을 수도 없다.
    pub fn openBracket(self: *Brackets, id: []const u8, now_ms: u64, background: bool) void {
        if (id.len == 0 or id.len > max_id_len) {
            self.overflow = true;
            return;
        }
        var free_slot: ?*Open = null;
        for (&self.open) |*o| {
            if (o.used) {
                if (std.mem.eql(u8, o.key(), id)) return;
            } else if (free_slot == null) free_slot = o;
        }
        const slot = free_slot orelse {
            self.overflow = true;
            return;
        };
        @memcpy(slot.id[0..id.len], id);
        slot.id_len = id.len;
        slot.opened_ms = now_ms;
        slot.background = background;
        slot.used = true;
    }

    /// `PostToolUse`/`PostToolUseFailure` — 같은 id 의 구간을 닫는다.
    ///
    /// `duration_ms` 가 있으면(claude) 시작을 `min(Pre 관측, now − 길이)` 로 되돌리고, 어느 쪽이든
    /// `slack_ms`(poll 주기)만큼 더 앞당긴다 — 위 «놓치는 쪽이 아니라 더 잡는 쪽» 규율.
    ///
    /// ⚠️ **되돌리기에는 아래 한계가 있다**(적대적 검증 4회차). `Pre` 는 실제로 일어난 **뒤에** 관측되므로
    /// 실제 시작은 `Pre 관측 − slack` 보다 이르지 않다. 그러므로 옳은 `duration` 이면 `now − 길이` 도 그 아래로
    /// 못 내려간다 — 내려가면 값이 틀린 것이다(provider 결함·시계 점프). 그때 그 값을 믿으면 구간이 **epoch
    /// 까지** 벌어져 그 턴의 모든 파일이 `✎` 가 된다. 그래서 `now − 길이` 를 `[Pre 관측 − slack, Pre 관측]`
    /// 안으로 잘라 넣는다 — 길이가 시작을 옮길 수 있는 폭은 최대 slack 하나다.
    pub fn closeBracket(self: *Brackets, id: []const u8, now_ms: u64, duration_ms: ?u64, slack_ms: u64) Close {
        const slot = self.find(id) orelse {
            self.unmatched +|= 1;
            return .unmatched;
        };
        if (slot.background) return .kept_background;
        var base = slot.opened_ms;
        if (duration_ms) |d| base = @max(@min(base, now_ms -| d), slot.opened_ms -| slack_ms);
        self.push(.{ .start_ms = base -| slack_ms, .end_ms = @max(now_ms, base) });
        slot.* = .{};
        return .closed;
    }

    /// 턴 경계 — 열린 것을 **전부** 닫는다(배경 호출 포함). `Post` 도 `PostToolUseFailure` 도 안 오는
    /// 길이 있다(승인 거부·중단·크래시) — 턴이 끝났는데 열린 채 두면 다음 턴의 시간까지 삼킨다.
    pub fn sealAll(self: *Brackets, now_ms: u64, slack_ms: u64) void {
        for (&self.open) |*o| {
            if (!o.used) continue;
            self.push(.{ .start_ms = o.opened_ms -| slack_ms, .end_ms = @max(now_ms, o.opened_ms) });
            o.* = .{};
        }
    }

    /// 지금 셸이 도는 중인가(열린 구간이 하나라도 있나).
    pub fn busy(self: *const Brackets) bool {
        for (&self.open) |*o| {
            if (o.used) return true;
        }
        return false;
    }

    /// 닫힌 구간들(봉인 뒤에는 이것이 전부다).
    pub fn sealed(self: *const Brackets) []const Interval {
        return self.intervals[0..self.len];
    }

    /// 이 시각이 어느 닫힌 구간 안에 있나. `overflow` 면 **언제나 거짓** — 확정하지 않는다.
    pub fn contains(self: *const Brackets, ms: u64) bool {
        if (self.overflow) return false;
        for (self.sealed()) |iv| {
            if (iv.contains(ms)) return true;
        }
        return false;
    }

    /// 다른 턴(다른 세션)의 구간과 겹치는 것이 있나 — 계약 §8-2 「동시 실행 구간은 확정하지 않는다」의 재료.
    pub fn overlapsAny(self: *const Brackets, other: *const Brackets) bool {
        for (self.sealed()) |a| {
            for (other.sealed()) |b| {
                if (a.overlaps(b)) return true;
            }
        }
        return false;
    }

    fn find(self: *Brackets, id: []const u8) ?*Open {
        if (id.len == 0) return null;
        for (&self.open) |*o| {
            if (o.used and std.mem.eql(u8, o.key(), id)) return o;
        }
        return null;
    }

    fn push(self: *Brackets, iv: Interval) void {
        if (self.len >= max_intervals) {
            self.overflow = true;
            return;
        }
        self.intervals[self.len] = iv;
        self.len += 1;
    }
};

const testing = std.testing;

test "Pre 가 열고 같은 id 의 Post 가 닫는다 — 구간은 관측 시각에서 poll 주기만큼 앞당겨진다" {
    var b: Brackets = .{};
    b.openBracket("toolu_a", 1000, false);
    try testing.expect(b.busy());
    try testing.expectEqual(Close.closed, b.closeBracket("toolu_a", 5000, null, 500));
    try testing.expect(!b.busy());
    try testing.expectEqual(@as(usize, 1), b.sealed().len);
    // 시작은 Pre 관측(1000)에서 slack(500)을 뺀 500, 끝은 Post 관측 5000.
    try testing.expectEqual(@as(u64, 500), b.sealed()[0].start_ms);
    try testing.expectEqual(@as(u64, 5000), b.sealed()[0].end_ms);
    try testing.expect(b.contains(500));
    try testing.expect(b.contains(5000));
    try testing.expect(!b.contains(499));
    try testing.expect(!b.contains(5001));
}

test "duration 이 있으면 시작을 «Post − 길이» 까지 되돌린다 — Pre 관측이 늦었을 때 놓치지 않게" {
    // Pre 를 poll 이 늦게 봤다(실제 시작 2000, 관측 2400). Post 관측 6000, 길이 4100 → 실제 시작 ≈ 1900.
    var b: Brackets = .{};
    b.openBracket("t", 2400, false);
    try testing.expectEqual(Close.closed, b.closeBracket("t", 6000, 4100, 500));
    // min(2400, 6000−4100=1900) − 500 = 1400.
    try testing.expectEqual(@as(u64, 1400), b.sealed()[0].start_ms);
    // 반대로 길이가 짧으면(배경 아닌 짧은 명령) Pre 관측이 더 이르므로 그쪽이 이긴다.
    var c: Brackets = .{};
    c.openBracket("u", 1000, false);
    try testing.expectEqual(Close.closed, c.closeBracket("u", 1500, 30, 500));
    try testing.expectEqual(@as(u64, 500), c.sealed()[0].start_ms);
    // 포화 산술 — 0 아래로 내려가지 않는다.
    var d: Brackets = .{};
    d.openBracket("v", 100, false);
    try testing.expectEqual(Close.closed, d.closeBracket("v", 200, 900, 500));
    try testing.expectEqual(@as(u64, 0), d.sealed()[0].start_ms);
}

test "터무니없는 duration 은 시작을 slack 하나 이상 못 옮긴다 — 구간이 epoch 까지 벌어지지 않는다" {
    // Pre 관측 100_000, Post 관측 101_000 인데 길이가 «하루» 라고 한다(provider 결함·시계 점프).
    var b: Brackets = .{};
    b.openBracket("t", 100_000, false);
    try testing.expectEqual(Close.closed, b.closeBracket("t", 101_000, 86_400_000, 500));
    // 믿었다면 0 이었을 것이다. 잘라 넣으면 `Pre 관측 − slack(99_500)` 이 base, 거기서 slack 을 한 번 더 뺀 99_000.
    try testing.expectEqual(@as(u64, 99_000), b.sealed()[0].start_ms);
    try testing.expect(!b.contains(98_999));
    try testing.expect(b.contains(99_000));
    // 포화 최대값도 같다.
    var c: Brackets = .{};
    c.openBracket("u", 100_000, false);
    try testing.expectEqual(Close.closed, c.closeBracket("u", 101_000, std.math.maxInt(u64), 500));
    try testing.expectEqual(@as(u64, 99_000), c.sealed()[0].start_ms);
    // 그러나 **그 안의** 되돌리기는 여전히 산다(위 테스트의 1400 이 그것이다).
}

test "무작위 순서에서도 불변식이 선다 — 열린 수 ≤ 상한, 구간 끝 ≥ 시작, overflow 면 contains 거짓" {
    var prng = std.Random.DefaultPrng.init(0x5eed_a73b);
    const rnd = prng.random();
    var round: usize = 0;
    while (round < 200) : (round += 1) {
        var b: Brackets = .{};
        var now: u64 = 1_000_000;
        var step: usize = 0;
        const steps = rnd.intRangeAtMost(usize, 1, 120);
        while (step < steps) : (step += 1) {
            now += rnd.intRangeAtMost(u64, 0, 3000);
            var id_buf: [8]u8 = undefined;
            const id = std.fmt.bufPrint(&id_buf, "i{d}", .{rnd.intRangeAtMost(u8, 0, 11)}) catch unreachable;
            switch (rnd.intRangeAtMost(u8, 0, 3)) {
                0, 1 => b.openBracket(id, now, rnd.boolean()),
                2 => _ = b.closeBracket(id, now, if (rnd.boolean()) rnd.intRangeAtMost(u64, 0, 5000) else null, 500),
                else => b.sealAll(now, 500),
            }
            // 열린 수는 상한 안이다.
            var open_n: usize = 0;
            for (&b.open) |*o| {
                if (o.used) open_n += 1;
            }
            try testing.expect(open_n <= max_open);
            try testing.expect(b.len <= max_intervals);
            for (b.sealed()) |iv| {
                try testing.expect(iv.end_ms >= iv.start_ms);
                // 구간은 «지금» 을 넘지 않는다(미래를 말하지 않는다).
                try testing.expect(iv.end_ms <= now);
            }
            try testing.expectEqual(open_n > 0, b.busy());
            if (b.overflow) try testing.expect(!b.contains(now));
        }
        b.sealAll(now, 500);
        try testing.expect(!b.busy());
    }
}

test "배경 호출은 Post 로 닫히지 않고 턴 끝까지 연다" {
    var b: Brackets = .{};
    b.openBracket("bg", 1000, true);
    // 띄운 순간 오는 Post(0.030 s 뒤) — 닫지 않는다.
    try testing.expectEqual(Close.kept_background, b.closeBracket("bg", 1030, 30, 500));
    try testing.expect(b.busy());
    try testing.expectEqual(@as(usize, 0), b.sealed().len);
    // 턴 끝이 닫는다 — 그때까지의 시간 전부가 구간이다.
    b.sealAll(9000, 500);
    try testing.expect(!b.busy());
    try testing.expectEqual(@as(usize, 1), b.sealed().len);
    try testing.expectEqual(@as(u64, 500), b.sealed()[0].start_ms);
    try testing.expectEqual(@as(u64, 9000), b.sealed()[0].end_ms);
}

test "턴 끝은 열린 것을 전부 닫는다 — Post 가 안 오는 길(거부·중단·크래시)" {
    var b: Brackets = .{};
    b.openBracket("a", 1000, false);
    b.openBracket("b", 2000, false);
    b.sealAll(3000, 0);
    try testing.expect(!b.busy());
    try testing.expectEqual(@as(usize, 2), b.sealed().len);
    // 끝이 시작보다 앞서지 않는다(시계가 뒤로 가도).
    var c: Brackets = .{};
    c.openBracket("z", 5000, false);
    c.sealAll(4000, 0);
    try testing.expect(c.sealed()[0].end_ms >= c.sealed()[0].start_ms);
}

test "짝 없는 Post 는 무시하고 센다 — backlog·회전본·id 유실 뒤" {
    var b: Brackets = .{};
    try testing.expectEqual(Close.unmatched, b.closeBracket("ghost", 1000, null, 0));
    try testing.expectEqual(Close.unmatched, b.closeBracket("", 1000, null, 0));
    try testing.expectEqual(@as(u32, 2), b.unmatched);
    try testing.expectEqual(@as(usize, 0), b.sealed().len);
    try testing.expect(!b.overflow);
}

test "병렬 호출 — 겹친 구간은 각각 남고 합치지 않는다(귀속은 합집합이라 무해하다)" {
    var b: Brackets = .{};
    b.openBracket("p1", 1000, false);
    b.openBracket("p2", 1200, false);
    try testing.expectEqual(Close.closed, b.closeBracket("p2", 1500, null, 0));
    try testing.expect(b.busy()); // p1 이 아직 열려 있다
    try testing.expectEqual(Close.closed, b.closeBracket("p1", 3000, null, 0));
    try testing.expectEqual(@as(usize, 2), b.sealed().len);
    try testing.expect(b.contains(1100)); // p1 만
    try testing.expect(b.contains(1300)); // 둘 다
    try testing.expect(b.contains(2000)); // p1 만
    try testing.expect(!b.contains(3001));
}

test "같은 id 를 두 번 열면 한 번이다 — 중복 이벤트가 구간을 둘로 만들지 않는다" {
    var b: Brackets = .{};
    b.openBracket("dup", 1000, false);
    b.openBracket("dup", 1500, false);
    try testing.expectEqual(Close.closed, b.closeBracket("dup", 2000, null, 0));
    try testing.expectEqual(@as(usize, 1), b.sealed().len);
    try testing.expectEqual(@as(u64, 1000), b.sealed()[0].start_ms); // 첫 관측이 남는다
    try testing.expectEqual(Close.unmatched, b.closeBracket("dup", 2100, null, 0));
}

test "상한을 넘기면 확정하지 않는다 — contains 가 언제나 거짓이 된다" {
    // 열린 자리 상한.
    var b: Brackets = .{};
    var i: usize = 0;
    while (i <= max_open) : (i += 1) {
        var id_buf: [8]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "o{d}", .{i}) catch unreachable;
        b.openBracket(id, 1000, false);
    }
    try testing.expect(b.overflow);
    b.sealAll(2000, 0);
    try testing.expect(!b.contains(1500)); // 구간은 있지만 확정하지 않는다
    try testing.expectEqual(@as(usize, max_open), b.sealed().len);

    // 닫힌 구간 상한.
    var c: Brackets = .{};
    var n: usize = 0;
    while (n <= max_intervals) : (n += 1) {
        c.openBracket("x", 1000, false);
        _ = c.closeBracket("x", 1100, null, 0);
    }
    try testing.expect(c.overflow);
    try testing.expectEqual(@as(usize, max_intervals), c.sealed().len);
    try testing.expect(!c.contains(1050));

    // id 상한 — 잘라서 담지 않고 열지 않는다(잘린 id 는 남의 것과 거짓으로 짝지어진다).
    var d: Brackets = .{};
    const long = "x" ** (max_id_len + 1);
    d.openBracket(long, 1000, false);
    try testing.expect(d.overflow);
    try testing.expect(!d.busy());
}

test "다른 턴의 구간과 겹치는지 답한다 — 동시 실행 구간의 재료" {
    var a: Brackets = .{};
    a.openBracket("a", 1000, false);
    _ = a.closeBracket("a", 2000, null, 0);
    var b: Brackets = .{};
    b.openBracket("b", 1500, false);
    _ = b.closeBracket("b", 2500, null, 0);
    var c: Brackets = .{};
    c.openBracket("c", 2001, false);
    _ = c.closeBracket("c", 3000, null, 0);
    try testing.expect(a.overlapsAny(&b));
    try testing.expect(b.overlapsAny(&a));
    try testing.expect(!a.overlapsAny(&c));
    // 양끝 포함 — 같은 ms 에서 만나면 겹친다(포함 규칙과 일관).
    var e: Brackets = .{};
    e.openBracket("e", 2000, false);
    _ = e.closeBracket("e", 2100, null, 0);
    try testing.expect(a.overlapsAny(&e));
}

test "고정 버퍼의 상한이 파서·훅과 같은 값이다" {
    try testing.expectEqual(event.max_tool_use_id_len, max_id_len);
    // 실측 모양이 들어간다.
    var b: Brackets = .{};
    b.openBracket("exec-c7898e4a-0bc2-4b77-8091-90ef775316d9", 1, false);
    b.openBracket("toolu_01GxMwqMfHbwqq1dbuxDCwFB", 1, false);
    try testing.expect(!b.overflow);
}
