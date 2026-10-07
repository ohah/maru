//! 재접속 job 이 **어떻게 끝났는지** 앱 로그에 남기는 판정과 서식(std-only leaf).
//!
//! ## 왜 있나
//!
//! 2026-10-04 23:43 — 덮개를 닫아 잠든 사이 RPC 읽기가 시간 초과로 poison 됐고, 재접속 job 은 하나 생겼지만
//! (`reconnect turn idle: admissions=0 jobs=1`) 그 뒤 50분 동안 **한 줄도** 남지 않았다. job 은 `deadline_exceeded`·
//! `host_gone` 으로 끝나면 입장 결속만 풀고 조용히 사라지고, `retry_later` 로 다시 넣을 때도 아무것도 안 찍혔다. 그래서
//! 「첫 시도가 왜 실패했나」(호스트가 옛 연결을 아직 안 치워 거절했나, 다시 넣은 job 이 낡은 데드라인을 그대로
//! 끌고 가 연결도 안 해 보고 끝났나)를 가릴 수 없었다.
//!
//! 이 leaf 는 **동작을 바꾸지 않는다.** 재접속을 다시 걸고 데드라인을 갱신하는 정책은 `reconnect_retry_policy.zig`
//! 가 소유한다(2026-10-07 — 이 기록이 그 사고를 「첫 시도가 5 초 안에 연결을 못 마쳤다」로 판정했다). 여기는
//! 사고를 한 줄로 판정하게 하는 기록만 만든다:
//!
//! - `reconnect job ended: …` — 재시도 없이 입장을 정산하는 갈래(`host_gone`·`cancelled`·연속 상한을 넘긴 `retry_later`,
//!   그리고 연결은 됐지만 CR5 가 `retained_terminal` 로 끝난 것).
//! - `reconnect job requeued: …` — `retry_later`·`deadline_exceeded` 로 같은 신원을 새 데드라인과 대기로 다시 넣는
//!   갈래. 루프가 돌 수 있어 간격 상한을 둔다.
//! - `reconnect turn drained: …` — idle 진단이 (0,N) 을 찍은 뒤 job 이 사라져 (0,0) 이 된 순간. 예전에는 이 전이를
//!   찍지 않아 「job 이 아직 있나, 이미 끝났나」를 로그로 알 수 없었다.
//!
//! 모든 줄에 `stale_deadline` 을 싣는다: 워커가 연결을 **시도하기 전에** 이미 데드라인이 지나 있었는가. 참이면
//! 「다시 넣은 job 이 낡은 데드라인을 끌고 갔다」 가설의 직접 증거다.

const std = @import("std");

/// 한 번의 물리 시도가 어떻게 끝났는지. 워커가 `Completion` 에 싣고 메인 스레드가 읽는다(워커 스레드는 로그를
/// 찍지 않는다 — 서식은 메인의 정산 갈래 한 곳에서만 일어난다).
pub const AttemptDetail = enum(u8) {
    none,
    /// 연결 전에 이미 데드라인이 지나 있었다 — 소켓도 안 열었다.
    deadline_past_before_connect,
    /// 기존 host 연결(host_connect)이 실패를 돌려줬다. 구체 사유는 `reason` 이름으로 따로 싣는다.
    connect_failed,
    /// 연결은 됐지만 후보가 GUI 프로파일·catch-up barrier·host id 조건을 못 맞춰 버렸다.
    candidate_rejected,
    /// 연결된 후보를 backend 가 채택하지 못했다(`adoptReconnectCoordinatorCandidate`).
    adopt_busy,
    adopt_invalid_authority,
    adopt_failed,
    /// 취소(Quit·cancel 신호).
    cancelled,
};

/// 시도 하나의 기록. `reason` 은 정적 문자열(`@tagName`)만 담는다 — 소유권이 없다.
pub const Attempt = struct {
    detail: AttemptDetail = .none,
    reason: []const u8 = "-",
    /// 워커가 시도를 시작한 순간 기준 데드라인까지 남은 ms. 음수면 이미 지나 있었다(얼마나 지났는지).
    deadline_remaining_ms: i64 = 0,
    /// 시도 시작 시점 데드라인 측정이 있었는가. 없으면 `stale_deadline` 을 판정하지 않는다.
    measured: bool = false,

    pub fn staleDeadline(self: Attempt) bool {
        return self.detail == .deadline_past_before_connect or
            (self.measured and self.deadline_remaining_ms <= 0);
    }
};

/// 데드라인(awake 시계 ns)과 지금의 차이를 ms 로. 양수면 남은 시간, 음수면 지난 시간. 포화한다.
pub fn deadlineRemainingMs(deadline_ns: u64, now_ns: i128) i64 {
    const delta: i128 = @as(i128, deadline_ns) - now_ns;
    const ms = @divTrunc(delta, std.time.ns_per_ms);
    return @intCast(std.math.clamp(ms, std.math.minInt(i64), std.math.maxInt(i64)));
}

/// host 마다 「처음 입장한 시각·다시 넣은 횟수」. job 이 끝날 때 몇 번 돌았고 얼마나 걸렸는지를 싣는다.
/// 고정 8칸 — 꽉 차면 가장 오래된 칸을 덮는다(로그용이라 잃어도 동작에는 영향이 없다).
pub const Streaks = struct {
    pub const capacity = 8;
    const Entry = struct {
        host_id: u128 = 0,
        connection_generation: u64 = 0,
        first_ns: i128 = 0,
        requeues: u32 = 0,
    };
    entries: [capacity]Entry = [_]Entry{.{}} ** capacity,

    pub const Summary = struct {
        /// 물리 시도 횟수(첫 시도 + 다시 넣은 횟수). 입장 기록이 없으면 0.
        attempts: u32,
        /// 첫 입장부터 지금까지 ms. 입장 기록이 없으면 -1.
        age_ms: i64,
    };

    fn find(self: *Streaks, host_id: u128, connection_generation: u64) ?*Entry {
        for (&self.entries) |*e| {
            if (e.host_id == host_id and e.connection_generation == connection_generation and e.host_id != 0)
                return e;
        }
        return null;
    }

    /// 새 job 입장. 같은 (host, 연결 세대) 가 이미 있으면 그대로 둔다(다시 넣기는 `requeue` 가 센다).
    pub fn begin(self: *Streaks, host_id: u128, connection_generation: u64, now_ns: i128) void {
        if (host_id == 0) return;
        if (self.find(host_id, connection_generation) != null) return;
        var slot: *Entry = &self.entries[0];
        for (&self.entries) |*e| {
            if (e.host_id == 0) {
                slot = e;
                break;
            }
            if (e.first_ns < slot.first_ns) slot = e;
        }
        slot.* = .{ .host_id = host_id, .connection_generation = connection_generation, .first_ns = now_ns };
    }

    /// `retry_later` 로 다시 넣었다. 지금까지의 시도 횟수를 돌려준다(이번 것을 포함).
    pub fn requeue(self: *Streaks, host_id: u128, connection_generation: u64) u32 {
        const e = self.find(host_id, connection_generation) orelse return 0;
        e.requeues +|= 1;
        return e.requeues;
    }

    /// job 이 끝났다 — 요약을 돌려주고 칸을 비운다.
    pub fn end(self: *Streaks, host_id: u128, connection_generation: u64, now_ns: i128) Summary {
        const e = self.find(host_id, connection_generation) orelse return .{ .attempts = 0, .age_ms = -1 };
        const summary: Summary = .{
            .attempts = e.requeues +| 1,
            .age_ms = @intCast(std.math.clamp(@divTrunc(now_ns - e.first_ns, std.time.ns_per_ms), 0, std.math.maxInt(i64))),
        };
        e.* = .{};
        return summary;
    }
};

/// `retry_later` 다시 넣기 줄의 간격 상한. 루프가 돌아도 1초에 한 줄, 그 사이 삼킨 줄 수를 다음 줄에 싣는다.
pub const RateLimit = struct {
    pub const interval_ns: i128 = std.time.ns_per_s;
    last_ns: ?i128 = null,
    suppressed: u32 = 0,

    /// 찍어도 되면 그동안 삼킨 줄 수를 돌려주고, 아니면 null(삼킨 수를 하나 늘린다).
    pub fn admit(self: *RateLimit, now_ns: i128) ?u32 {
        if (self.last_ns) |last| {
            if (now_ns - last < interval_ns) {
                self.suppressed +|= 1;
                return null;
            }
        }
        self.last_ns = now_ns;
        const dropped = self.suppressed;
        self.suppressed = 0;
        return dropped;
    }
};

/// idle 진단의 전이. `turnOne` 이 진행 없이 끝날 때마다 불리므로 값이 **바뀔 때만** 무언가를 남긴다.
pub const IdleTransition = enum { none, idle, drained };

pub const IdleTracker = struct {
    admissions: ?u32 = null,
    jobs: ?usize = null,

    pub fn note(self: *IdleTracker, admissions: u32, jobs: usize) IdleTransition {
        const prev_admissions = self.admissions;
        const prev_jobs = self.jobs;
        if (prev_admissions == admissions and prev_jobs == jobs) return .none;
        self.admissions = admissions;
        self.jobs = jobs;
        if (admissions != 0 or jobs != 0) return .idle;
        // (0,0) — 평시는 남기지 않는다. 직전에 무언가 있었을 때만 「비었다」를 남긴다.
        const had_work = (prev_admissions orelse 0) != 0 or (prev_jobs orelse 0) != 0;
        return if (had_work) .drained else .none;
    }
};

pub const Ended = struct {
    host_id: u128,
    outcome: []const u8,
    attempt: Attempt,
    summary: Streaks.Summary,
    /// 정산 시점 기준 데드라인까지 남은 ms(음수면 지남).
    deadline_remaining_ms: i64,
};

pub fn writeEnded(w: *std.Io.Writer, e: Ended) std.Io.Writer.Error!void {
    try w.print(
        "reconnect job ended: host={x:0>32} outcome={s} reason={s}:{s} attempts={d} age_ms={d} deadline_remaining_ms={d} stale_deadline={}",
        .{
            e.host_id,
            e.outcome,
            @tagName(e.attempt.detail),
            e.attempt.reason,
            e.summary.attempts,
            e.summary.age_ms,
            e.deadline_remaining_ms,
            e.attempt.staleDeadline(),
        },
    );
}

pub const Requeued = struct {
    host_id: u128,
    /// 다시 넣게 만든 결과 — `retry_later` 또는(2026-10-07 부터) `deadline_exceeded`.
    outcome: []const u8,
    attempt: Attempt,
    attempts: u32,
    /// 다음 시도까지의 대기(`reconnect_retry_policy.backoffNs`). 이 줄이 이어지는데 값이 30000 에 붙어 있으면 host 가
    /// 오래 응답하지 않는 것이다.
    retry_in_ms: u64,
    deadline_remaining_ms: i64,
    suppressed: u32,
};

pub fn writeRequeued(w: *std.Io.Writer, r: Requeued) std.Io.Writer.Error!void {
    try w.print(
        "reconnect job requeued: host={x:0>32} outcome={s} reason={s}:{s} attempts={d} retry_in_ms={d} deadline_remaining_ms={d} stale_deadline={} suppressed={d}",
        .{
            r.host_id,
            r.outcome,
            @tagName(r.attempt.detail),
            r.attempt.reason,
            r.attempts,
            r.retry_in_ms,
            r.deadline_remaining_ms,
            r.attempt.staleDeadline(),
            r.suppressed,
        },
    );
}

pub fn writeDrained(w: *std.Io.Writer, prev_admissions: u32, prev_jobs: usize) std.Io.Writer.Error!void {
    try w.print("reconnect turn drained: admissions=0 jobs=0 (prev admissions={d} jobs={d})", .{ prev_admissions, prev_jobs });
}

// ---------------------------------------------------------------- tests

fn render(comptime f: anytype, args: anytype) ![]const u8 {
    const S = struct {
        var buf: [512]u8 = undefined;
    };
    var w: std.Io.Writer = .fixed(&S.buf);
    try @call(.auto, f, .{&w} ++ args);
    return w.buffered();
}

test "재접속 실패 로그: 데드라인 차이는 남으면 양수, 지났으면 음수, 포화한다" {
    try std.testing.expectEqual(@as(i64, 1500), deadlineRemainingMs(3_000_000_000, 1_500_000_000));
    try std.testing.expectEqual(@as(i64, -2000), deadlineRemainingMs(1_000_000_000, 3_000_000_000));
    try std.testing.expectEqual(@as(i64, 0), deadlineRemainingMs(5, 5));
    try std.testing.expectEqual(std.math.minInt(i64), deadlineRemainingMs(0, std.math.maxInt(i128)));
}

test "재접속 실패 로그: stale_deadline 은 연결 전 지남 또는 측정된 음수 잔여일 때만 참" {
    const cases = [_]struct { a: Attempt, want: bool }{
        .{ .a = .{ .detail = .deadline_past_before_connect }, .want = true },
        .{ .a = .{ .detail = .connect_failed, .measured = true, .deadline_remaining_ms = -1 }, .want = true },
        .{ .a = .{ .detail = .connect_failed, .measured = true, .deadline_remaining_ms = 0 }, .want = true },
        .{ .a = .{ .detail = .connect_failed, .measured = true, .deadline_remaining_ms = 4999 }, .want = false },
        // 측정이 없으면 0 을 「지남」으로 읽지 않는다.
        .{ .a = .{ .detail = .adopt_busy, .measured = false, .deadline_remaining_ms = 0 }, .want = false },
    };
    for (cases) |c| try std.testing.expectEqual(c.want, c.a.staleDeadline());
}

test "재접속 실패 로그: 시도 횟수와 경과는 같은 host·연결 세대로 묶이고, 끝나면 칸을 비운다" {
    var s: Streaks = .{};
    s.begin(7, 3, 1_000 * std.time.ns_per_ms);
    s.begin(7, 3, 9_000 * std.time.ns_per_ms); // 같은 job 의 재입장은 시작 시각을 바꾸지 않는다.
    try std.testing.expectEqual(@as(u32, 1), s.requeue(7, 3));
    try std.testing.expectEqual(@as(u32, 2), s.requeue(7, 3));
    try std.testing.expectEqual(@as(u32, 0), s.requeue(7, 4)); // 다른 연결 세대는 다른 job.
    const sum = s.end(7, 3, 6_500 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u32, 3), sum.attempts);
    try std.testing.expectEqual(@as(i64, 5_500), sum.age_ms);
    const gone = s.end(7, 3, 7_000 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u32, 0), gone.attempts);
    try std.testing.expectEqual(@as(i64, -1), gone.age_ms);
    // 꽉 차면 가장 오래된 칸을 덮는다.
    for (0..Streaks.capacity) |i| s.begin(100 + i, 1, @intCast(i));
    s.begin(999, 1, 50);
    try std.testing.expectEqual(@as(i64, -1), s.end(100, 1, 60).age_ms);
    try std.testing.expectEqual(@as(i64, 0), s.end(999, 1, 50).age_ms);
}

test "재접속 실패 로그: 다시 넣기 줄은 1초에 한 번, 삼킨 수를 다음 줄에 싣는다" {
    var r: RateLimit = .{};
    try std.testing.expectEqual(@as(?u32, 0), r.admit(0));
    try std.testing.expectEqual(@as(?u32, null), r.admit(100 * std.time.ns_per_ms));
    try std.testing.expectEqual(@as(?u32, null), r.admit(999 * std.time.ns_per_ms));
    try std.testing.expectEqual(@as(?u32, 2), r.admit(1_000 * std.time.ns_per_ms));
    try std.testing.expectEqual(@as(?u32, 0), r.admit(2_500 * std.time.ns_per_ms));
}

test "재접속 실패 로그: idle 진단은 바뀔 때만, (0,0) 은 직전에 일이 있었을 때만 drained" {
    var t: IdleTracker = .{};
    try std.testing.expectEqual(IdleTransition.none, t.note(0, 0)); // 시작 직후 평시.
    try std.testing.expectEqual(IdleTransition.idle, t.note(0, 1));
    try std.testing.expectEqual(IdleTransition.none, t.note(0, 1)); // 같은 값은 조용히.
    try std.testing.expectEqual(IdleTransition.drained, t.note(0, 0));
    try std.testing.expectEqual(IdleTransition.none, t.note(0, 0));
    try std.testing.expectEqual(IdleTransition.idle, t.note(2, 0));
    try std.testing.expectEqual(IdleTransition.drained, t.note(0, 0));
}

test "재접속 실패 로그: 줄 서식은 사고 판정에 필요한 칸을 모두 싣는다" {
    const host: u128 = 0x3c4386f58a7ddc5cd9fc12fdec618687;
    try std.testing.expectEqualStrings(
        "reconnect job ended: host=3c4386f58a7ddc5cd9fc12fdec618687 outcome=deadline_exceeded reason=deadline_past_before_connect:- attempts=2 age_ms=5300 deadline_remaining_ms=-300 stale_deadline=true",
        try render(writeEnded, .{Ended{
            .host_id = host,
            .outcome = "deadline_exceeded",
            .attempt = .{ .detail = .deadline_past_before_connect, .measured = true, .deadline_remaining_ms = -300 },
            .summary = .{ .attempts = 2, .age_ms = 5300 },
            .deadline_remaining_ms = -300,
        }}),
    );
    try std.testing.expectEqualStrings(
        "reconnect job requeued: host=3c4386f58a7ddc5cd9fc12fdec618687 outcome=deadline_exceeded reason=connect_failed:deadline_exceeded attempts=1 retry_in_ms=1000 deadline_remaining_ms=6000 stale_deadline=false suppressed=0",
        try render(writeRequeued, .{Requeued{
            .host_id = host,
            .outcome = "deadline_exceeded",
            .attempt = .{ .detail = .connect_failed, .reason = "deadline_exceeded", .measured = true, .deadline_remaining_ms = 4200 },
            .attempts = 1,
            .retry_in_ms = 1000,
            .deadline_remaining_ms = 6000,
            .suppressed = 0,
        }}),
    );
    try std.testing.expectEqualStrings(
        "reconnect turn drained: admissions=0 jobs=0 (prev admissions=0 jobs=1)",
        try render(writeDrained, .{ @as(u32, 0), @as(usize, 1) }),
    );
}
