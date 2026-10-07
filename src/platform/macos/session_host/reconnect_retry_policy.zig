//! 재접속 job 을 **언제 다시 시도하나**(std-only leaf).
//!
//! ## 왜 있나
//!
//! 2026-10-04 23:43 과 2026-10-07 20:37 — 둘 다 덮개를 닫아 잠든 사이 RPC 읽기가 시간 초과로 poison 됐고, 재접속
//! job 이 딱 한 번 시도한 뒤 `connect_failed:deadline_exceeded` 로 끝났다. host 는 살아서 `poll` 에 앉아 있었는데 앱은
//! 앱을 다시 띄울 때까지 붙지 않았다. 원인은 둘이었다.
//!
//! 1. `deadline_exceeded` 가 **종결**이었다 — `retry_later` 만 다시 넣었다.
//! 2. 다시 넣어도 **처음 받은 5 초 데드라인**을 그대로 끌고 갔다 — 그래서 `retry_later` 도 결국 그 5 초가 지나면
//!    `deadline_exceeded` 로 바뀌어 끝났다. poison 은 연결마다 첫 번만 admission 을 만들므로 그 뒤 새 job 은 없다.
//!
//! 잠자기·DarkWake 처럼 **잠깐** 응답이 늦은 것을 영구 실패로 굳힌 셈이다. 영구 실패는 `host_gone`(host 프로세스가
//! 사라졌다는 긍정적 증거, `host_connect.FailureReason.host_gone`) 하나뿐이다.
//!
//! ## 정책
//!
//! - 다시 넣을 때마다 데드라인을 **새로** 준다: `now + 접속 예산 + 대기`.
//! - 대기는 1 초에서 두 배씩, 30 초에서 멈춘다. 매 frame 재시도가 돌지 않게 하는 상한이자, host 가 정말 오래 멈춘 경우
//!   30 초마다 한 번 두드리는 비용이다.
//! - 연결에 성공하면 대기를 처음으로 되돌린다.
//! - **시간 초과**(`deadline_exceeded` — 잠자기·DarkWake·응답 지연)는 횟수 제한 없이 다시 건다. host 는 살아 있을
//!   가능성이 높고, 포기하면 앱을 다시 띄우기 전까지 안 붙는다.
//! - **그 밖의 실패**(`retry_later` — manifest 없음·버전 불일치·채택 실패 등)는 연속 `max_other_failures` 번까지만 다시
//!   걸고 그다음은 예전처럼 끝낸다. 재접속 worker 의 host 연결(`host_connect` 의 기존 host 경로)은 manifest 가 없어도 `host_gone` 이
//!   아니라 `invalid_manifest` 를 내므로, 상한이 없으면 정말 사라진 host 를 30 초마다 영원히 두드린다. 예전에는 모든
//!   재시도가 첫 5 초 데드라인을 나눠 써서 이 상한이 저절로 있었다 — 데드라인을 새로 주면서 그 상한을 명시로 옮긴 것이다.
//!
//! 시계는 `std.Io.Clock.awake`(잠자기 동안 안 흐름)라 덮개를 닫아 둔 시간은 대기·데드라인 어느 쪽도 깎지 않는다.
//! 이 파일은 값만 계산한다 — job 을 다시 넣는 배선은 `reconnect_product_coordinator.zig` 의 `settleLogicalCompletion`.

const std = @import("std");

pub const initial_backoff_ns: u64 = 1 * std.time.ns_per_s;
pub const max_backoff_ns: u64 = 30 * std.time.ns_per_s;
/// 시간 초과가 아닌 실패를 연속 몇 번까지 다시 거나. 6 번이면 대기 합이 1+2+4+8+16+30 = 61 초다.
pub const max_other_failures: u32 = 6;

pub const Failure = enum { timeout, other };

/// `retries` 번째(1 부터) 재시도 앞의 대기. 0 은 「아직 실패 안 함」이라 대기 없음.
pub fn backoffNs(retries: u32) u64 {
    if (retries == 0) return 0;
    const shift: u6 = @intCast(@min(retries - 1, 63));
    const scaled = std.math.shlExact(u64, initial_backoff_ns, shift) catch return max_backoff_ns;
    return @min(scaled, max_backoff_ns);
}

pub const Retry = struct {
    /// 이 시각(awake ns) 전에는 worker 에 넘기지 않는다.
    not_before_ns: i128,
    /// 다시 넣는 job 의 새 데드라인 — 대기가 끝난 뒤에도 접속 예산 전체가 남는다.
    absolute_deadline_ns: u64,
    backoff_ns: u64,
};

pub fn schedule(now_ns: i128, connect_budget_ns: i128, retries: u32) Retry {
    const backoff = backoffNs(retries);
    const not_before = now_ns + backoff;
    const deadline = not_before + @max(connect_budget_ns, 1);
    return .{
        .not_before_ns = not_before,
        .absolute_deadline_ns = @intCast(std.math.clamp(deadline, 1, std.math.maxInt(u64))),
        .backoff_ns = backoff,
    };
}

/// host 마다 연속 재시도 횟수. 연결이 붙거나 다른 host 로 넘어가면 처음부터 센다.
///
/// host 하나만 기억한다 — 정상 상태에서 host 는 하나다. 둘이 번갈아 실패하면 서로의 횟수를 지워 대기가 1 초에
/// 머물지만, 그래도 매 frame 재시도는 아니다.
pub const Streak = struct {
    host_id: u128 = 0,
    retries: u32 = 0,
    other_failures: u32 = 0,

    /// 이번 실패를 세고 다음 재시도의 순번(1 부터)을 돌려준다. `null` 이면 그만둔다 — 그때는 횟수도 비워, 같은 host 의
    /// 다음 incident 가 처음부터 시작한다.
    pub fn fail(self: *Streak, host_id: u128, kind: Failure) ?u32 {
        if (self.host_id != host_id) self.* = .{ .host_id = host_id };
        if (kind == .other) {
            self.other_failures +|= 1;
            if (self.other_failures > max_other_failures) {
                self.* = .{};
                return null;
            }
        }
        self.retries +|= 1;
        return self.retries;
    }

    /// 연결이 붙었거나 재시도 없이 끝났다(`host_gone`·Quit) — 그 host 의 다음 incident 는 처음부터.
    pub fn reset(self: *Streak, host_id: u128) void {
        if (self.host_id == host_id) self.* = .{};
    }
};

test "재접속 재시도 정책: 대기는 1 초에서 두 배씩 늘고 30 초에서 멈춘다" {
    try std.testing.expectEqual(@as(u64, 0), backoffNs(0));
    try std.testing.expectEqual(1 * std.time.ns_per_s, backoffNs(1));
    try std.testing.expectEqual(2 * std.time.ns_per_s, backoffNs(2));
    try std.testing.expectEqual(16 * std.time.ns_per_s, backoffNs(5));
    try std.testing.expectEqual(max_backoff_ns, backoffNs(6));
    try std.testing.expectEqual(max_backoff_ns, backoffNs(64));
    try std.testing.expectEqual(max_backoff_ns, backoffNs(std.math.maxInt(u32)));
}

// 2026-10-07 사고의 핵심: 다시 넣은 job 이 낡은 데드라인을 끌고 가면 연결도 안 해 보고 끝난다.
// 새 데드라인은 **대기가 끝난 시점부터** 접속 예산 전체가 남아야 한다.
test "재접속 재시도 정책: 새 데드라인은 대기가 끝난 뒤에도 접속 예산 전체를 남긴다" {
    const budget: i128 = 5 * std.time.ns_per_s;
    const now: i128 = 1_000 * std.time.ns_per_s;
    const first = schedule(now, budget, 1);
    try std.testing.expectEqual(now + std.time.ns_per_s, first.not_before_ns);
    try std.testing.expectEqual(@as(u64, @intCast(first.not_before_ns + budget)), first.absolute_deadline_ns);
    try std.testing.expect(@as(i128, first.absolute_deadline_ns) > now + budget);

    const later = schedule(now, budget, 10);
    try std.testing.expectEqual(now + max_backoff_ns, later.not_before_ns);
    try std.testing.expectEqual(@as(u64, @intCast(now + max_backoff_ns + budget)), later.absolute_deadline_ns);

    // 시계 원점 근처·이상한 예산에서도 0(무효 데드라인)을 내지 않는다.
    try std.testing.expect(schedule(0, 0, 0).absolute_deadline_ns >= 1);
}

test "재접속 재시도 정책: 연속 횟수는 host 마다 세고 성공하면 처음으로 돌아간다" {
    var streak: Streak = .{};
    try std.testing.expectEqual(@as(?u32, 1), streak.fail(7, .timeout));
    try std.testing.expectEqual(@as(?u32, 2), streak.fail(7, .other));
    try std.testing.expectEqual(@as(?u32, 3), streak.fail(7, .timeout));
    // 다른 host 의 리셋은 이 host 의 횟수를 지우지 않는다.
    streak.reset(9);
    try std.testing.expectEqual(@as(?u32, 4), streak.fail(7, .timeout));
    streak.reset(7);
    try std.testing.expectEqual(@as(?u32, 1), streak.fail(7, .timeout));
    // 다른 host 로 넘어가면 처음부터.
    try std.testing.expectEqual(@as(?u32, 1), streak.fail(9, .timeout));
}

// 2026-10-07 사고는 시간 초과였다 — 몇 번이든 다시 건다. 반대로 manifest 가 없는 host 는 `invalid_manifest`(→ other)로
// 와서, 상한이 없으면 사라진 host 를 영원히 두드린다.
test "재접속 재시도 정책: 시간 초과는 끝없이, 그 밖의 실패는 연속 상한까지만 다시 건다" {
    var streak: Streak = .{};
    for (0..1000) |_| try std.testing.expect(streak.fail(7, .timeout) != null);

    streak = .{};
    for (0..max_other_failures) |_| {
        try std.testing.expect(streak.fail(7, .other) != null);
        // 시간 초과가 끼어도 그 밖의 실패 횟수는 지워지지 않는다.
        _ = streak.fail(7, .timeout);
    }
    try std.testing.expectEqual(@as(?u32, null), streak.fail(7, .other));
    // 그만둔 뒤 같은 host 의 다음 incident 는 처음부터.
    try std.testing.expectEqual(@as(?u32, 1), streak.fail(7, .other));
}
